// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"math"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

var lrcTimestampRe = regexp.MustCompile(`\[\d{1,2}:\d{2}[.:]\d{1,3}\]`)
var lrcTimestampCaptureRe = regexp.MustCompile(`\[(\d{1,2}):(\d{2})[.:](\d{1,3})\]`)

// isTimedLRC reports whether s is genuinely逐行加了时间戳的 LRC 歌词，而不是网易云/
// QQ 音乐偶尔返回的"纯文本歌词"——后者可能带 [Verse 1]/[Chorus] 这类段落标签,或者只有
// 开头一行作词/作曲 credit 信息被打了个孤立时间戳,其余全是无时间戳纯文本,单看"字符串
// 里有没有方括号"区分不出这两者。要求至少 3 行、且过半的行真的带 [mm:ss.xx] 格式时间戳,
// 才认为是可用的逐行 LRC。
func isTimedLRC(s string) bool {
	if s == "" || len(s) >= 20000 {
		return false
	}
	lines := strings.Split(s, "\n")
	timedLines := 0
	for _, l := range lines {
		if lrcTimestampRe.MatchString(l) {
			timedLines++
		}
	}
	return timedLines >= 3 && timedLines*2 >= len(lines)
}

// cjkRatio 是去掉时间戳标签后,歌词正文里中日韩表意文字(\p{Han})占非空白字符的比例。
func cjkRatio(s string) float64 {
	stripped := lrcTimestampRe.ReplaceAllString(s, "")
	total, cjk := 0, 0
	for _, r := range stripped {
		if unicode.IsSpace(r) {
			continue
		}
		total++
		if unicode.Is(unicode.Han, r) {
			cjk++
		}
	}
	if total == 0 {
		return 0
	}
	return float64(cjk) / float64(total)
}

// isProbablyWrongLanguageLyrics 判断"本地标签明明是非中文(歌手名+歌名都不含中文),
// 但解析出来的'原文'歌词却大半是中文"这种明显文不对题的情况——通常是上传者把翻译当
// 原文传错了。本地标签本身就是中文时不适用这条判断(中文歌配中文"原文"歌词完全正常，
// 不该被当成异常拦下来)。
//
// ⚠️ 两道豁免都是 2026-08-28 补的,起因是同一个真实案例但对症的信号不一样:
// 用户报「搜索候选歌词」把方大同《南音》的正确候选判成"语言跟这首歌对不上"——Apple
// Music 本地标签罗马化写成 artist="Khalil Fong" / title="Nanyin",两者都不含汉字。
// 这首歌本来就是中文歌,只是标签用了罗马化/英文转写,localArtist/localTitle 天生测不出
// "这首歌是不是中文歌",只能测出"标签写法用的是什么字符集"。
//
//   - candidateArtist:候选源自己确认匹配到的那位歌手的名字(qq/kugou/lrclib 等报的是
//     各源曲库里的写法,候选进打分之前已经过了各源自己的歌手身份闸,见第 09 章"歌手闸
//     三档")。它本身含汉字,说明候选源认得这位歌手的中文名,这条候选大概率是"这位歌手
//     的中文歌"而不是"传错语言的翻译"。⚠️ 这道豁免对方大同这个真实案例本身**没有**
//     生效——LRCLIB 索引这首歌的元数据同样是罗马化写法("Khalil Fong"/"Nanyin"),它没有
//     中文数据可给,candidateArtist 也是拉丁字母。留着这道豁免是因为它能覆盖另一类更
//     常见的场景:候选来自 qq/kugou/netease 这类天然用中文曲库索引的源,即使本地标签是
//     罗马化写法,它们报出来的歌手名往往就是中文。
//   - knownArtistAlias(localArtist):手工登记表(下面 artistAliasTable)里如果恰好
//     登记了这个罗马化写法对应哪个中文名,就不该让语言闸凭字符集猜错语言——方大同这个
//     案例当时(2026-08-28)就是这么救回来的。⚠️ 2026-08-31 起"Khalil Fong"→"方大同"
//     这条已经从表里删掉了(下面 resolvedArtistCJKHint 这道通用豁免已经能查到,不需要
//     手工登记),表现在只剩两条通用机制都覆盖不了的真实残留案例(见 artistAliasTable
//     头注)——这道豁免的存在意义没变,只是覆盖面从"手工登记过的几十个"缩到了"这两个"。
//   - resolvedArtistCJKHint(localArtist):2026-08-30 补,通用替代——那英《微笑着离去》
//     真实案例:本地标签罗马化成"Na Ying",LRCLIB 报的 candidateArtist 同样是罗马化
//     写法,手工表也没登记(不是每个知名歌手都恰好被人工录入过),真实的中文歌词被误判
//     拒收。手工表不该靠"一个个补"来堵这类缺口——canonicalArtistViaMusicBrainz/
//     musicBrainzArtistAliases 这两条 resolve 流程里本来就在跑的通用 MusicBrainz 查询,
//     只要为了别的目的(CanonicalArtist 解析/retryArtistIdentities 别名重试)查过这位
//     歌手一次,答案就已经缓存在 artistAliasCache/mbPrimaryNameCache 里,这里直接
//     只读窥探(不主动发起新请求,不把这个纯函数变成隐性网络调用),命中就跟手工表
//     同等对待。覆盖面从"手工登记过的几十个"变成"MusicBrainz 认识、且本次 resolve
//     链路里其它步骤已经查过的所有歌手"。
//
// 三道豁免任一成立即可,都基于 cjkRatio 恒等式:空字符串(旧调用点/测试没传
// candidateArtist,或者 localArtist 不在表里/缓存里)的 cjkRatio 恒为 0,不触发豁免,
// 行为跟改动前逐字节一致。
func isProbablyWrongLanguageLyrics(localArtist, localTitle, candidateArtist, lyrics string) bool {
	if cjkRatio(localArtist) > 0 || cjkRatio(localTitle) > 0 {
		return false
	}
	if cjkRatio(candidateArtist) > 0 || cjkRatio(knownArtistAlias(localArtist)) > 0 ||
		cjkRatio(resolvedArtistCJKHint(localArtist)) > 0 {
		return false
	}
	return cjkRatio(lyrics) > 0.5
}

// creditLineRe 匹配"作词/作曲/编曲/制作人/演唱/混音/录音: xxx"或英文对应写法开头的行——
// 要求出现在行首(去掉时间戳、trim 空白之后),不匹配"作词"这类词恰好出现在正文歌词句子
// 中间的情况(那种情况极罕见,但宁可放过也不误杀真歌词)。
var creditLineRe = regexp.MustCompile(`(?i)^(作词|作曲|编曲|制作人|演唱|混音|录音|lyrics by|composed by|written by|produced by|arranged by)\s*[:：]`)

// genericHanCreditLineRe 是 creditLineRe 的结构化补充——2026-08-04 实测坐实:网易云对
// 纯音乐/配乐类曲目偶尔会把完整制作人员名单当"歌词"返回,每行都带真实时间戳(能通过
// isTimedLRC),但角色名(指挥/混音师/贝斯/中提琴/吉他/大提琴/母带工程师……)远超
// creditLineRe 手工枚举的那几个词,枚举法天然堵不完。改成认"短中文标签+冒号+人名"这个
// 结构本身——不管标签具体是什么词,只要是 1~8 个汉字紧跟冒号,大概率就是"角色: 姓名"这种
// 职员表格式,不是真正在唱的歌词正文(真歌词句子极少长这个形状)。故意只匹配汉字标签(不
// 含数字/字母),避免误伤"1、2、3："这类真歌词里可能出现的编号或场景标签。
var genericHanCreditLineRe = regexp.MustCompile(`^\p{Han}{1,8}[:：]`)

// isCreditLine 判断去掉时间戳/trim 过的一行文本是不是"角色: 人名"这种职员表格式——
// creditLineRe(手工枚举的中英文关键词)和 genericHanCreditLineRe(结构化兜底)两条规则
// 任一命中即算,理由分别见各自的注释。
func isCreditLine(text string) bool {
	return creditLineRe.MatchString(text) || genericHanCreditLineRe.MatchString(text)
}

// neteaseInstrumentalPlaceholderMarker 是网易云对纯音乐曲目自己给出的固定占位文案(常
// 跟在完整制作人员名单里、同样带着时间戳)——命中即可高置信度判定"这整份不是真歌词",
// 不需要再逐行数 credit 行,比 isCreditLine 的结构化判断更直接、误判空间更小。
const neteaseInstrumentalPlaceholderMarker = "纯音乐"

// isCreditOnlyLRC 判断这份"通过了 isTimedLRC"的歌词是不是只有作词/作曲等 credit 信息、
// 没有真正的歌词正文——网易云有时把整首歌的"歌词"就只填了几行 credit,每行都单独带
// 时间戳(能通过 isTimedLRC 那条"过半行数带时间戳"的检测),但去掉 credit 行之后剩不下
// 几行真正在唱的词。去掉时间戳和 credit 行之后,剩余非空行少于 3 行就判定为"只有
// credit,没有正文"。
func isCreditOnlyLRC(lrc string) bool {
	if strings.Contains(lrc, neteaseInstrumentalPlaceholderMarker) {
		return true
	}
	// 演唱者标签行不算 credit(2026-08-23,见 lyricspeaker.go):一首每句都带「男：/女：」
	// 行内前缀的对唱歌,逐行看每一行都命中结构正则,不豁免就会被整份判废。
	speakers := lyricSpeakerLabels(lrc)
	nonCredit := 0
	for _, l := range splitLyricLines(lrc) {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(l, ""))
		if text == "" || isCreditLineWithSpeakers(text, speakers) {
			continue
		}
		nonCredit++
	}
	return nonCredit < 3
}

// lastLRCTimestampSecs 取 LRC 里最后一个"真的带歌词正文"的 [mm:ss.xx] 时间戳、换算成
// 秒——不能简单取整份文本里最后一个时间戳:有些 LRC 会在真正唱完之后再补一行空白时间戳
// 单独标记"这首歌到这里才算完"(常见于给尾奏占位),这种行没有对应的歌词正文,选它当
// "最后一句歌词的时间"纯属巧合对上时长,不能算数(2026-07-30 实测坐实:某候选正是靠着
// 这样一行空白尾行,巧合命中时长评分的最高档,反而反超了末尾真的有歌词、但差了几个百分
// 点的候选)。逐行从后往前找,跳过"去掉时间戳后剩余文本为空"的行。frac 部分可能是两位
// (百分之几秒)或三位(毫秒),按其实际代表的小数位数换算,不假设固定是哪一种。
func lastLRCTimestampSecs(lrc string) (float64, bool) {
	lines := strings.Split(lrc, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		matches := lrcTimestampCaptureRe.FindAllStringSubmatch(lines[i], -1)
		if len(matches) == 0 {
			continue
		}
		if strings.TrimSpace(lrcTimestampRe.ReplaceAllString(lines[i], "")) == "" {
			continue
		}
		m := matches[len(matches)-1]
		mm, _ := strconv.Atoi(m[1])
		ss, _ := strconv.Atoi(m[2])
		frac, _ := strconv.Atoi(m[3])
		fracSecs := float64(frac) / math.Pow(10, float64(len(m[3])))
		return float64(mm*60+ss) + fracSecs, true
	}
	return 0, false
}

// lyricCandidate 是某个歌词源解析出的一份候选结果,连同来源标记。
type lyricCandidate struct {
	source        string // "netease" | "qq" | "kugou" | "musixmatch" | "lrclib" | "amll" | "lyricfind"
	lyrics        string
	wordTimingYRC string // 该候选归一化成 YRCParser 语法后的逐字数据,没有则空串(netease/qq/kugou 都可能有,lrclib 恒无)
	hasWordTiming bool   // = wordTimingYRC != "",构造候选时直接算好,见 enrich.go
	// timelineRemap:行级时间轴被重挂到逐字轴上时留下的"旧毫秒→新毫秒"映射(见
	// lyricstimeline.go)。译文/罗马音的时间戳是照原文 LRC 抄的,附着到冠军上时要用
	// 这份映射一起搬过去,否则相对正文错位。没重挂过就是 nil。
	timelineRemap map[int]int
	// hasUsableTranslation/hasUsableRomanization:这份候选自带**可用的**增值内容(社区
	// 译文语言与目标语言一致且时间轴/覆盖率过闸、罗马音配日文形态歌词)。在候选构造时由
	// usableValueAdd 算好(那里能拿到 features 里的目标语言),打分函数保持纯函数。v3 起
	// 参与打分(译文+50/罗马音+30):同质候选间带可用增值内容者优先——这不是来源先验
	// (那个 2026-08-09 被消融实验删掉了),是关于这份候选本身的内容事实。
	hasUsableTranslation  bool
	hasUsableRomanization bool
	// sourceReportedDurationSecs:源自己声明的这首歌时长(秒),0=该源没给。2026-08-12 起
	// 透传(qq interval/kugou duration/lrclib duration/netease duration);2026-08-22 起
	// **参与打分**——它是"源报版本同一性"的干净信号(不被长尾奏带偏),消融评测的结论见
	// sourceDurationMismatchPenalty 的注释。
	sourceReportedDurationSecs float64
	// title/artist/album/cover 是这个源实际匹配到的歌名/歌手/专辑/封面,给"搜索候选歌词"
	// 弹窗展示("这个候选到底对应哪首歌/哪个版本")。不同源可能匹配到同一首歌的不同版本
	// (不同专辑/live/合集),各自如实展示,不做跨源统一。
	//
	// 2026-08-05 起 title **参与打分**:只用来判"版本限定词对不对得上"(见
	// versionTagsMismatch)。改动前它完全不参与,而 scoreLyricCandidate 的其余信号
	// (时长吻合度/有无逐字/来源/行数)对"同一首歌的两个不同录音"几乎无区分力——同一首歌的
	// demo/original version/live 版时长接近、歌词字面还一样,于是自报标题明明写着
	// "(Original Version)" 的候选也能压过标题完全吻合的候选(实测坐实:Michael Jackson
	// 的 "Blue Gangsta" 被匹配成酷狗的 "Blue Gangsta (Original Version)",播放时展示的
	// 第一句就是 "Michael Jackson - Blue Gangsta(Original Version)",时间轴也是原始版
	// 那一套)。
	title, artist, album, cover string
	// language:这个候选自己源上报的语种,目前只解决"这是不是粤语"这一个问题——
	// songLanguageCantonese("yue")/songLanguageMandarin("cmn")之一,源没给或给了
	// 无法识别的值一律留空。跟 sourceReportedDurationSecs 同一个模式:纯透传、由
	// 各源的解析代码在构造候选时算好(QQ 用 fcg_play_single_song.fcg 的 language
	// 数字字段,酷狗用 api/v3/search/song 的 trans_param.language 字符串字段),
	// netease/musixmatch/lrclib/amll/lyricfind 都没有这个信号,恒为空。
	// 不参与打分——只作为 enrichEntry.SongLanguage 的来源,给粤拼罗马音生成用。
	language string
	// plainTextOnly:2026-08-30 加,见 lrclibResult.plainOnly 头注——true 时 lyrics 装的是
	// **没有时间戳**的纯文本,不是能拿 isTimedLRC 正常判定的东西。scoreLyricCandidateDetailed
	// 看到这个标记会跳过"不是带时间戳的歌词就判废"那条通用闸,改判一个专门写明"仅纯文本"
	// 的理由——但分数依旧钉死在 -1,不会被 pickLyricCandidate/自动路径当成可用候选。
	plainTextOnly bool
}

// songLanguageCantonese/songLanguageMandarin:lyricCandidate.language 与
// enrichEntry.SongLanguage 共用的取值,只覆盖"是不是粤语"这一个问题,不是通用语种
// 字段(通用语种判断是 Romanizer.LyricScript 已经在管的事)。
const (
	songLanguageCantonese = "yue"
	songLanguageMandarin  = "cmn"
)

// lyricEndingCorroborationToleranceSecs 是判定"多个独立源的歌词末尾时间戳互相印证"的
// 容差。真正同一份内容的末尾时间戳跨源转写通常只差 1~2s,内容被串了的候选往往差出
// 一个数量级(十几秒以上),5s 足够宽容跨源转写的细微差异,又足够严格不会让内容对不上
// 的候选蒙混过关。
const lyricEndingCorroborationToleranceSecs = 5.0

// durationFitTolerance:歌词末句时间戳跟曲目时长差多少以内算"吻合"。
//
// 卡得比较紧:内容被污染/串错版本的候选,跟真实但前奏/尾奏较长的正确候选,时长偏差有时
// 只差几个百分点——阈值定太松会放过污染候选,定太紧会错杀真实但尾奏长的候选。
const durationFitTolerance = 0.25

// durationFits 是"这份歌词的长度跟这首歌对得上吗"的**唯一**判据。
//
// corroboratedEndings 和 scoreLyricCandidateDetailed 必须共用它:前者靠"有没有任何一条
// 候选吻合"决定要不要发印证豁免,后者靠它决定走哪一档。两边一旦各写一份、日后漂移,就会
// 出现"因为有人吻合所以不发豁免、但那个人自己又没走吻合档"这种两头落空。
func durationFits(lastSecs, durationSecs float64) bool {
	if durationSecs <= 0 {
		return false
	}
	// 歌词末尾**超过**曲目时长,是标错而不是"吻合得好":那几句在实际播放中根本到不了。
	// 留 lyricOvershootToleranceSecs 秒容差给收尾渐弱/取整这类正常误差。
	if lastSecs > durationSecs+lyricOvershootToleranceSecs {
		return false
	}
	return math.Abs(lastSecs-durationSecs)/durationSecs <= durationFitTolerance
}

// corroboratedEndings 返回"末尾时间戳被至少一个别的源印证"的来源集合。多个互相独立的
// 歌词源末尾落在几乎同一个时间点,是"这些内容描述的是同一份真实歌词"的强证据——比单纯
// "跟完整曲目时长差多少"更可靠:有些歌曲本身带很长的纯音乐尾奏,没有任何源把它转写进
// 歌词也完全正常,若只按时长差距判断会被误杀;而内容确实被串到别的曲目/版本的候选,
// 不会凑巧跟别的源落在同一个时间点上。
//
// ⚠️ 但"互相独立"这个前提是有条件的,2026-08-09 实测抓到它翻车:
// "Valentina (feat. Rick Ross) [Bonus]"(237s)——QQ 和酷狗都抓到了**普通版**(都停在
// 2:23),于是互相"印证"成功、各拿 +100 豁免掉时长惩罚,而真正抓到 bonus 版、末句 3:46
// 几乎正好压着曲长的 LRCLIB 反倒分数低一截,冠军判给了 QQ。根子在于:各源拿的是同一个
// 搜索词,搜歪的时候会被**一起**带到同一个错版本上,这时候"两个源一致"根本不是独立证据。
//
// 判别办法:真·长尾奏的歌,**所有**源都会提前结束(没人转写那段纯音乐);而抓错版本的
// 局面里,总有某个源的末句是跟得上曲长的 —— 它的存在直接证伪了"这首歌的歌词本来就早
// 早结束"。所以只要**batch 里有任何一条候选的时长是吻合的**,就不再给任何人发豁免:
// 那条吻合的候选本身走 ratio<=durationFitTolerance 那一档,不需要豁免;剩下那些差一大截
// 的,该扣就扣。
func corroboratedEndings(candidates []lyricCandidate, durationSecs float64) map[string]bool {
	type ending struct {
		source string
		secs   float64
	}
	var endings []ending
	for _, c := range candidates {
		if secs, ok := lastLRCTimestampSecs(c.lyrics); ok {
			endings = append(endings, ending{c.source, secs})
		}
	}
	if durationSecs > 0 {
		for _, e := range endings {
			if durationFits(e.secs, durationSecs) {
				return map[string]bool{}
			}
		}
	}
	corroborated := map[string]bool{}
	for i := range endings {
		for j := range endings {
			if i == j || endings[i].source == endings[j].source {
				continue
			}
			if math.Abs(endings[i].secs-endings[j].secs) <= lyricEndingCorroborationToleranceSecs {
				corroborated[endings[i].source] = true
			}
		}
	}
	return corroborated
}

// scoreLyricCandidate 给一份候选歌词打分,越高越可信;返回负数表示直接判定无效——不管
// 别的候选分数多低,都不能选一份未通过基本校验的候选。三层基本校验(时间戳密度/语言/
// 是否只有credit)都通过后,依次看:
//  1. 歌词末尾时间戳跟真实曲目时长是否吻合——最能识破同名曲被误关联成另一版本/另一首
//     歌。差超过 25% 且没有别的源印证,直接判定无效,不是扣分——时长对不上通常就是串了
//     别的曲目/版本，留着只会增加"矮子里拔将军选中一个不确定对不对的候选"的风险。但如果
//     corroborated 为真(见 corroboratedEndings),说明别的独立源也在同一时间点结束,这是
//     比"跟完整时长差多少"更直接的正确性证据,不再判定无效。
//  2. 是否带逐字(yrc)时间轴:没有逐字时间轴的话,悬浮窗/网页只能整行高亮,观感明显不如
//     逐字扫过,故权重较高(400)。2026-08-07 起这一档**高于**时长匹配的封顶(300):逐字
//     是歌词质量的直接证据,时长吻合只是间接代理,后者还会被前奏/尾奏系统性带偏,不该
//     压过前者(理由和实测例子见下面时长那段注释)。
//  3. 来源优先级:网易云能带翻译/罗马音这类其它源没有的增值内容,同等时长可信度下优先
//     选它，其次QQ,再其次酷狗/Musixmatch/LRCLIB——避免"纯按行数比大小"让内容切分方式
//     恰好更碎的源意外挤掉本来完全合格、还带增值内容的网易云结果。Musixmatch 排在酷狗
//     之后、LRCLIB 之前:它是非官方逆向接口(不如酷狗这个已用了很久的既有源稳定),但
//     能带逐字时间轴+可选语言译文,比只有纯逐行歌词的 LRCLIB 更有信息量。
//  4. 内容行数只做非常次要的参考(封顶,避免行数虚高的候选靠行数堆分反超时长/来源都更
//     可信的候选)。
//
// lyricOvershootToleranceSecs:歌词末尾时间戳允许比曲目时长多出多少秒仍算"没超"。
// 收尾渐弱、时长取整这类正常误差通常在两三秒内,5 秒足够宽松;再多就是标错了。
const lyricOvershootToleranceSecs = 5.0

// lyricsScoringVersion 是下面这套打分规则的版本号。
//
// **改动 scoreLyricCandidate 的任何一档权重/判定,都必须把这个数 +1。** 缓存是"解析一次
// 永久保留",每条记着自己是按哪一版规则选出来的(enrichEntry.LyricsScoringVersion);
// 版本落后的条目会在这首歌下次被播放时后台重搜一轮、按新规则重选(见 needsLyricsRescore)。
// 忘了 +1 的后果不是报错而是静默失效:新规则只对以后从没听过的歌生效,已经听过的那批
// 永远停在旧选择上 —— 2026-08-07 改权重时正是这样,用户那首歌缓存里还挂着按旧规则选出来
// 的 Musixmatch。
//
// v2(2026-08-07):时长档封顶从 +1000 压到 +300(不再压过逐字时间轴的 +400);歌词结尾
// 超出曲目时长 5 秒以上的候选直接判无效。v1 = 这个字段还不存在时写入的所有条目。
//
// v3(2026-08-12):四个新维度 + overshoot 独立档,全部经 201 首真实库内曲目的反事实消融
// 坐实(联合 61 翻盘/5 纠错/0 回归/6 首手选金标签无损,评测器见 simeval_test.go):
//   - 专辑亲和(+150/+75/+40,只加不减):跨源层终于看专辑,精选集候选不再与原专辑平权;
//   - 跨源正文共识(+250/+150):五份歌词全文互证,替代只比末尾时间戳一个标量;
//   - 标题吻合梯度(+120/+60/+30):精确同名不再与"剥括号才相等"平权;
//   - 增值内容决胜(译文+50/罗马音+30,带资格闸):同质候选间带可用增值内容者优先;
//   - overshoot 独立档(−700):歌词末句超过曲长 5s 是物理矛盾,不再吃跨源印证豁免。
//
// v5(2026-08-27):wordTimingOverride——逐字时间轴的 +400 是决定性因素、且另一个真实候选
// 的标题吻合分更高时,撤销这份 +400(不是下调权重本身,是窄口子只在 titleMatch 也站在
// 亚军那边时触发)。依据是对 1818 首真实曲库(861 条完整解析记录)的反事实消融:wordTiming
// 是决定性因素的案例有 240 个(27.9%),其中标题吻合分同时也站在亚军那边的只有 2 个
// (0.83%,且两个都是真实版本误配,titleMatch 这条判据 0 误报)——用户报的方大同《公园》
// Timeless演唱会 vs 专场现场案是其中一个。见 applyWordTimingTitleOverride 的注释。
//
// v6(2026-08-28):isProbablyWrongLanguageLyrics 补两道豁免(候选源自己确认的
// candidateArtist 含汉字、或 knownArtistAlias(localArtist) 查到中文名),修的是"歌手
// 用罗马化艺名+本地标签也是罗马化写法"这一类被误杀——用户报的方大同《南音》(本地标签
// artist="Khalil Fong" title="Nanyin",两者都不含汉字)是真实案例:候选正文是这首歌真正
// 的中文歌词,却被 v5 及更早版本判成"语言跟这首歌对不上"一票否决(Score -1),永远进不了
// 自动解析的候选池。见 isProbablyWrongLanguageLyrics 的注释。
//
// v7(2026-09-01):liveAlbumConflict——「两场不同演唱会」判据(-600,与 versionTags 同级)。
// 用户报的陈奕迅《Shall We Dance (Live)》/《活着多好 (Live)》案:本地专辑《The Easy Ride
// 演唱会 (Live)》,酷狗那份挂在《Get A Life (Live)》——**另一场巡演**,两场都收录了这首歌
// 的现场版,标题吻合分打平(都逐字相等)、专辑亲和分也打平(都只够到 +40 档),错的那份靠
// 逐字时间轴(Shall We Dance)或时长吻合更紧(活着多好)赢——两首歌赢在不同的项上,说明
// 病根不在任何一个权重数字,而是**versionTagsMismatch 在"两边都是 Live"时静默**(限定词
// 集合相等),没有任何判据能说出"这是另一场演出"。同日先试过三个方向都被真实库回放否决:
// ①冠军专辑证据弱时撤销逐字/时长加分(47~150 个决策翻盘,绝大多数是再版/精选辑噪音);
// ②奖励自报时长精确匹配(阈值越紧翻盘越多,70→358,变成"唯一凑巧报出逼近值的候选"抽奖);
// ③抬高专辑词元档分值(安全区间(≤60)翻不了盘,能翻盘的分位(≥94)破坏"精确>子串>词元"
// 的证据秩序)。三次失败的共同点:都在拿"专辑对不上"当负证据,违反"专辑对不上是零证据"
// 的既有原则。v7 的判据不同:要求**双方都做出明确的身份声明且互相矛盾**——本地专辑名
// 自己带 live 标记(录音室专辑名对"是哪场演出"没有发言权,Queen《The Game (Deluxe)》的
// bonus 现场曲配《Queen Rock Montreal》是同一场演出,不许误伤)、候选也是现场录音、两边
// 专辑名剥掉歌手名(防"周杰伦地表最强演唱会"vs"地表最强演唱会"的前缀粘连假冲突)和
// live/演唱会类通用词之后**各自还有身份词、且完全不相交**——这时才是"两场不同命名的
// 演出"的矛盾证据,不是"字符串没对上"的零证据。全库 2339 条真实决策回放:命中 29 个
// 候选、涉及 24 首歌,逐条人工核对全部是真的另一场演出(Get A Life/2003演唱会/无与伦比
// 2004/The One/超时代/Timeless演唱会/中国新歌声...),冠军改变 8 首、全部改对方向,
// 0 误伤。见 liveAlbumIdentityConflict 的注释。
//
// v8(2026-09-01):versionTags 的窄豁免 + 网易云 pick 的时长锚定档(陈奕迅《孤独探戈
// (Live)》案,同一张 Easy Ride 专辑的第三类形态)。正确版本在网易云库里**存在**
// (「孤独探戈(Acoustic Piano)(Live)」,专辑对、自报时长与本地逐位吻合),但被两道闸
// 联手挡死:①netease pick 的"精确同名档优先"让三条错场次的精确同名(Get A Life/
// Third Encounter/拉阔压轴)压过这条剥括号才同名的正确版本,pick 又完全不看时长;
// ②即便召回,"(Acoustic Piano)"这节本地曲名没有的限定词会吃 versionTags -600,照样
// 输给错场次候选。两处配套修(缺一都会更糟——只修 pick 不豁免,正确候选带着 -600 反而
// 让录音室版夺冠):打分层豁免见 sameRecordingDespiteVersionTags(四道门:时长≤1% +
// 专辑亲和 + 候选不缺本地限定词 + 多出的词全在 acoustic 家族白名单;全库回放现存 433 个
// 吃 -600 的候选 0 豁免 0 翻盘,零误伤),pick 锚定档见 netease.go pick() 头注。
//
// v9(2026-09-01):两处针对**中文平台命名形态**的修正(周杰伦《The One 周杰伦演唱会》案,
// 用户报"QQ 搜出来的是录音室版"——检索层的修复在 qq.go 的专辑维度路线,不需要 bump;
// 这两处是它牵出的打分层配套):
// ①albumTokens 在拉丁↔CJK 交界处分词:QQ 把专辑写成"The One演唱会"(不留空格),原来
//   "one演唱会"粘成一个词元、与本地"The One 周杰伦演唱会"零共享词、albumScore=0,同一张
//   专辑被判毫无亲和——与已有的"2011Live"数字↔字母交界分词同一性质,见 albumTokens 注释。
// ②versionTags 两道闸(versionTagsMismatch/sameRecordingDespiteVersionTags)改用
//   recordingVersionTags:专辑名带中文现场标记(演唱会/现场/音乐会)时视同声明了 "live"。
//   QQ 给现场专辑曲目起名不带"(Live)"、live 身份只写在专辑名上且不加括号,原来这类正确
//   候选吃 -600;对称地,本地专辑是"XX演唱会"而候选是干净录音室版时,现在能判出版本
//   不符(原来两边限定词集合都是空、闸门静默)。只认中文标记不认拉丁词元的理由见
//   recordingVersionTags 注释。全库 2360 条真实决策回放(旧逻辑副本与存档 parity 0):
//   23 首受影响,唯一 1 处冠军改变是蔡健雅《达尔文》从录音室 kugou(srcDur 265 vs 本地
//   308,差 14%)翻到 My Space 现场对版 netease(srcDur 308.04 逐位吻合)——改对;其余
//   全是"-600 平反"(地表最强 7 首 QQ 候选)或"新判出录音室冒充"(冠军均不变),0 误伤。
//   回放里抓到并已修掉的两类边界:专辑名括号里的描述文案不算标记(韦礼安《女孩》案,
//   推导只看 stripParens 后的专辑名);候选是同一张专辑的截短拼法时不苛求它也推导出
//   live(蔡健雅《依赖》案,见 sameRecordingDespiteVersionTags 第③门注释)。
// v10(2026-09-02):修掉"标题反查泛搜"那条兜底的两处判据缺陷(泛搜结果不再整份 30 条
// 交给纯时长判据、只取前 5 名;排歧义守卫从浮点精确相等改成 0.5s 真实余量)。详见
// netease.go 的 retryTitleFromArtistSearchMaxRank / bestAlbumTrackAmbiguityMarginSecs。
//
// ⚠️ **这次提版本号本身就是修复的一部分,不是走个形式**:被写坏的条目(实测用户库里
// 至少一条——DAOKO×米津玄師《打上花火》整屏显示的是《春雷》的歌词)只有在
// needsLyricsRescore 放行时才会被重选,而那道闸的判据正是
// `e.LyricsScoringVersion >= lyricsScoringVersion`。停在 9 的话,已经按 v9 打过分的
// 114 条(2026-09-02 实测,占有歌词条目的 3.5%)永远不会被重访,错的会一直错着。
//
// 提到 10 之后仍然救不回来的两类,如实记在这里:重打分次数已达 lyricsRescoreMaxAttempts
// 的(实测 6 条)、以及 ManualLyrics 手动锁定的(实测 6 条,这类是**刻意**跳过的)。
//
// v11(2026-09-02):lyricConsensusBody 跳过 `[kana:…]`/`[ti:…]`/`[offset:…]` 这类无时间戳
// 的元数据标签行(isLRCMetaTagLine)。起因:QQ 的 `[kana:]` 假名标注行接进整行歌词
// (qq.go attachKanaLine)后,E2E 实测《Lemon》的 QQ 候选从 1407 掉到 1158——一行 1700+
// 字符的假名把正文 3-gram 相似度拖到 0.55 阈值以下、250 分共识没了,冠军会因此换成酷狗。
// 这条规则对酷狗自带 `[kana:]` 的日文歌其实一直成立,只是没被注意。提版本号让已按 v10
// 打过分的条目重新裁决(重算用的是决策留痕里的存量候选,不联网)。
const lyricsScoringVersion = 11

// scoreTerm 是打分里的一项。只带**机器可读的类型**和分值,文案交给界面本地化 ——
// App 有中英两套界面,从这里吐中文字符串会让英文用户看到一串中文。
//
// 加它是为了让"搜索候选歌词"弹窗能把分数摊开给人看:一个 742 或者一个 -1 单独摆着,
// 没人知道它是怎么来的、更不知道 -1 到底是"被排除了"还是"分数很低"。
type scoreTerm struct {
	Kind   string `json:"kind"`
	Points int    `json:"points"`
}

// 加分项。
const (
	scoreTermDuration     = "duration"     // 末尾时间戳跟曲长吻合的程度
	scoreTermCorroborated = "corroborated" // 时长对不上,但别的源印证了同一个结束点
	scoreTermWordTiming   = "wordTiming"   // 带逐字时间轴
	scoreTermNativeSource = "nativeSource" // 跟当前播放器同源
	scoreTermSource       = "source"       // 来源本身的可靠度
	scoreTermLines        = "lines"        // 行数(封顶 200)
	scoreTermVersionTags  = "versionTags"  // 版本限定词对不上,重扣
	scoreTermDurationOff  = "durationOff"  // 时长明显对不上,重扣(以前是直接判 -1)
	// v3 新增(2026-08-12):
	scoreTermDurationOvershoot = "durationOvershoot" // 歌词末句超过曲长 5s(物理矛盾),重扣
	scoreTermAlbum             = "album"             // 候选自报专辑与本地专辑的亲和(只加不减)
	scoreTermTitleMatch        = "titleMatch"        // 标题吻合梯度(精确/仅括号差/双语)
	scoreTermConsensus         = "consensus"         // 跨源正文共识(与其它源的歌词内容互证)
	scoreTermTranslation       = "translation"       // 自带可用的目标语言译文
	scoreTermRoma              = "romanization"      // 日文形态歌词自带罗马音
	// v4 新增(2026-08-22):
	scoreTermSourceDurationOff = "sourceDurationOff" // 源自报曲长与本地明显不符 = 另一次录音
	// v5 新增(2026-08-27):
	scoreTermWordTimingOverride = "wordTimingOverride" // 标题吻合度更高的候选存在时,撤销逐字加分
	// v7 新增(2026-09-01):
	scoreTermLiveAlbumConflict = "liveAlbumConflict" // 本地和候选是两场不同命名的演出(现场专辑身份词矛盾),重扣
)

// lyricScoreTermKinds 是**会出现在 score_terms 里**的全部 kind。存在的唯一理由是给
// scoretermlabel_test.go 那个「Swift 侧必须有中文译名」的守卫测试当清单用 ——
// 跟 lyricsDecisionPaths() 是同一个路子、同一个教训:2026-08-21 加 manual-rematch 时
// Go 这边新写了一条 path、忘了补 Swift 译名,界面上直接印了个英文串给用户看;
// 2026-08-22 加 sourceDurationOff 时**照样又漏了一次**(那边 default 是 `return kind`),
// 所以这一类也得钉死。新增打分项时把常量加进这个清单,忘了补译名就直接红。
func lyricScoreTermKinds() []string {
	return []string{
		scoreTermDuration, scoreTermCorroborated, scoreTermWordTiming,
		scoreTermNativeSource, scoreTermLines, scoreTermVersionTags,
		scoreTermDurationOff, scoreTermDurationOvershoot, scoreTermAlbum,
		scoreTermTitleMatch, scoreTermConsensus, scoreTermTranslation,
		scoreTermRoma, scoreTermSourceDurationOff, scoreTermWordTimingOverride,
		scoreTermLiveAlbumConflict,
	}
}

// durationMismatchPenalty:时长明显对不上时扣多少。
//
// 2026-08-09 之前这是直接判 -1(一票否决)。实测推翻了它:被判 -1 的候选里 83%(5/6)
// 内容其实跟多数派完全一致 —— 它们是对的词,只是尾奏长、或者版本时长标注有出入。同一批
// 样本里还有 4 首歌是「有候选但全被判 -1」,最后一条歌词都没有。
//
// 改成重扣之后语义变成「比没有强,但比任何时长对得上的都差」:500 分足以让它输给任何一条
// 正常候选(时长吻合那一项本身就值 100~300,再加逐字/行数),但在它是唯一一条、或者它就是
// 共识内容时仍能胜出。
//
// 代价说清楚:真正串错版本的候选(这道闸门当初就是为它设的)现在会在「只有它一条」时被
// 选中,也就是「宁可显示错的,不要没有」。数据支持这个取舍 —— 误杀是 5:1,但它确实是个取舍。
const durationMismatchPenalty = 500

// sourceDurationMismatchPenalty / sourceDurationMismatchTolerance:候选**自报的曲目时长**
// 跟本地明显对不上时扣多少。
//
// ⚠️ 跟上面那一项量的**不是同一样东西**,别混为一谈:
//   - durationMismatchPenalty 量的是「LRC 末句时间戳 vs 曲长」,是个**代理**指标,被前奏/
//     尾奏系统性带偏(尾奏越长,越是完整正确的歌词越"不吻合");
//   - 这一项量的是两个**曲目时长**的直接比对,回答的是「这份歌词挂在哪一次录音上」。
//
// 2026-08-22 落地的实测依据(用户报「Stranger in Moscow (Tee's In-House Club Mix) 配了
// 正常版歌词」):本地是 414.32s 的俱乐部混音,冠军 qq 那条自报 **344s**(偏 17%)——它自己
// 的元数据就写着"我是另一次录音",而代理指标反而给了它 +147(它的 LRC 末句在 335s、偏 19%,
// 落在 25% 容差内);真正对版的酷狗混音版末句在 304.9s、偏 26.4%,**刚好越线吃 -500**。
// 也就是说错的那份在时长项上赢了对的那份,纯粹因为 335 比 304.9 离 414 近一点 —— 这个代理
// 在带长尾奏的混音/加长版上就是噪声,而直接测量一直躺在同一条决策记录里没人用
// (sourceReportedDurationSecs 自 2026-08-12 起就在透传,注释写着"先攒评测数据")。
//
// **只扣分、不加分**,这是消融实验选出来的:对 202 条真实缓存条目里 34 条可评样本
// (有 ≥2 个候选 + 至少一个源自报了时长)跑参数网格 ——
//
//	只扣 -400 @>12% → 冠军变化 **1** 处;只扣 -400 @>15%/>20% → 0 处;
//	只加 +300 @<=2% → 2 处;加分+扣分 → 2 处。
//
// 唯一那处变化是同专辑的「Earth Song」(本地 475.55s 的 Hani's Club Experience 混音),
// 老冠军是 405s 的正常版、新冠军是对版专辑那条 475s 的混音版 —— **改对了**,是同一个 bug
// 的兄弟案例。加分档多出来的那处(Morphine)则是中性偏坏:musixmatch 那条专辑名逐字对上、
// 只因为没自报时长就被有自报时长的 qq/kugou 挤掉,还可能连带丢掉译文。所以不加分。
//
// 阈值 12% 复用 enrich.go:wrongDuration 那条既有口径(「差超 12% 就当作给另一个版本选的」),
// 分母同样取两者中较大的那个,不新造一个数。
//
// ⚠️ 2026-09-01 用陈奕迅《活着多好 (Live)》案复查过一遍"收窄阈值是不是就安全了"——
// 结论是**收窄阈值不是变安全,是变更危险**。诊断脚本(反事实回放全部 3198 条真实
// 缓存条目、其中 2261 条带 duration_secs)对比几档"只加分"方案的冠军改变数:
//
//	<=2%   +300(2026-08-22 那次原方案,当时 34 个可评样本只测出 2 处):现在的库上是 70 处
//	<=0.5% +300:141 处;<=0.5% +80:77 处;<=0.1% +80:318 处;<=0.02% +80:358 处
//
// 阈值越紧、翻盘越多,不是越少——原因是阈值一放宽,同一轮里往往好几个候选都够得着,
// 加分对排序不构成额外区分度;阈值一收紧,反而变成"这一轮里唯一凑巧报出一个逼近值的
// 候选"独得一份加分,基本等于按运气抽奖决定冠军。也就是说这条"只扣不加"的设计决策
// 不是当年样本量太小侥幸躲过的问题,收窄阈值这个方向本身就是死路,不用再试第二次。
const (
	sourceDurationMismatchPenalty   = 400
	sourceDurationMismatchTolerance = 0.12
)

// 直接判定为"不可用"(分数 -1)的原因。这几种不是"分低",是压根不能用。
const (
	scoreRejectNotTimed        = "rejectNotTimed"        // 不是带时间戳的逐行歌词
	scoreRejectWrongLanguage   = "rejectWrongLanguage"   // 语言明显对不上
	scoreRejectCreditOnly      = "rejectCreditOnly"      // 整份只有署名行,没有正文
	scoreRejectNoLastTimestamp = "rejectNoLastTimestamp" // 提不出最后一个时间戳
	// 2026-08-09 起不再产生:时长不符改成重扣(scoreTermDurationOff),不再一票否决。
	// 常量留着是因为缓存/界面可能还遇得到老数据。
	scoreRejectDurationMismatch = "rejectDurationMismatch"
	// scoreRejectPlainTextOnly:2026-08-30 加——跟 scoreRejectNotTimed 是**同一类症状
	// (没有时间戳)、不同的原因**:那个是"这份数据本该带时间戳、只是解析失败/源本身残缺",
	// 这个是"这个源明确说了这首歌就只有纯文本,压根不存在带时间戳的版本"(见
	// lyricCandidate.plainTextOnly 头注)。分开一个专门的理由,是为了让"搜索候选歌词"
	// 弹窗能给出不一样的提示文案("仅纯文本,不能同步显示"而不是含糊的"没有时间戳")——
	// 分数依旧是 -1,跟 scoreRejectNotTimed 一样绝不会被自动路径选中。
	scoreRejectPlainTextOnly = "rejectPlainTextOnly"
)

// nativeLyricSources 是「**这一刻正在播的那个播放器**自家的歌词源」("qq"/"netease"/
// "kugou")。正在播的播放器没有原生歌词源(Apple Music / Spotify)或者认不出来时是空集,
// 谁都不加分。
//
// 集合形状是历史遗留(单选年代是单个字符串,2026-09-01 多选时改成集合),实际最多只有
// 一个成员 —— 一次只可能有一个播放器在放。留着集合形状是为了不动 scoreLyricCandidate
// 和 nativeMissedOut 两处的读法。
//
// ⚠️ **2026-09-02 修的真实 bug:输入从「用户勾选了哪些播放器」换成「现在在放的是哪个」。**
// 此前它是 `resolveNativeLyricSources(features.Players)`,也就是**设置里勾了哪些播放器**。
// 2026-09-01 加多选时那个函数的注释写着「选了多个播放器时,同源加权理应对它们各自的原生源
// 都生效,不能只挑其中一个」—— 这句话对**别的**按播放器分叉的功能成立,对这一项不成立:
// 它的立论是「时间轴对着同一份音频母版」(见下面 scoreLyricCandidateDetailed 里那段),
// 那是**正在播的那个播放器**的属性,跟"我允许哪些播放器"没有关系。
//
// 用户报的形状:六个播放器全勾(apple_music/auto/kugou/netease/qq/spotify),于是
// nativeLyricSources = {kugou, netease, qq},**三个源同时拿 +250**;而他实际在用
// Apple Music 听(np:lastPlayerBundleID = com.apple.Music),按定义**一条都不该给**。
// 后果有两层:①「解析决策」面板上「这个源就是你正在用的播放器」对三个源都是假话;
// ② 这一项的**区分力被自己抵消**——三个中文源都 +250,它没法在三者之间区分,只剩
// "系统性地把它们抬到 Musixmatch / LRCLIB 之上"这一个效果。
//
// 跟 features 同款的包级变量而不是打分函数的参数:打分函数已经有 7 个参数,再加一个
// 会让每个调用点都得关心一件跟它无关的事。⚠️ 但它现在是**运行期按曲目变的**(换播放器
// 就变),不再是启动时设一次的常量,所以读写都要过下面那把锁;测试里直接赋值仍然可以
// (单 goroutine)。
var (
	nativeLyricSourcesMu sync.RWMutex
	nativeLyricSources   map[string]bool
)

// setNativeLyricSourcesForPlayer 按**正在播的** bundle id 设置同源加权的目标。
// 常驻端每首歌进 trackEnrichment 时调一次;search-lyrics 子命令按 -player 参数调一次。
func setNativeLyricSourcesForPlayer(bundleID string) {
	src := playerNativeLyricSource(playerForBundleID(bundleID))
	nativeLyricSourcesMu.Lock()
	defer nativeLyricSourcesMu.Unlock()
	if src == "" {
		nativeLyricSources = nil
		return
	}
	if len(nativeLyricSources) == 1 && nativeLyricSources[src] {
		return // 没变,不重建 map
	}
	nativeLyricSources = map[string]bool{src: true}
}

// isNativeLyricSource / hasNativeLyricSource 是读侧的唯一入口 —— 直接索引那个 map 会跟
// setNativeLyricSourcesForPlayer 抢(换歌和上一首的兜底轮可能同时在跑)。
func isNativeLyricSource(src string) bool {
	nativeLyricSourcesMu.RLock()
	defer nativeLyricSourcesMu.RUnlock()
	return nativeLyricSources[src]
}

func hasNativeLyricSource() bool {
	nativeLyricSourcesMu.RLock()
	defer nativeLyricSourcesMu.RUnlock()
	return len(nativeLyricSources) > 0
}

// playerForBundleID 是 playerBundleID(system.go)的逆向:把播放器上报的 bundle id 映射
// 回播放器常量,认不出就返回空串。
//
// ⚠️ **不能拿 playerBundleID 反推**:那个函数的 default 分支把一切未知都映射成 Apple
// Music(对它的用途是对的 —— 调用方已经先排除了 playerAuto),反过来用会把任何不认识的
// bundle id 都当成 Apple Music。这里认不出必须是"不知道",不是"就当是 Apple Music"。
func playerForBundleID(bundleID string) string {
	switch bundleID {
	case appleMusicBundleID:
		return playerAppleMusic
	case qqMusicBundleID:
		return playerQQMusic
	case neteaseMusicBundleID:
		return playerNetease
	case spotifyBundleID:
		return playerSpotify
	case kugouMusicBundleID:
		return playerKugou
	default:
		return ""
	}
}

// playerNativeLyricSource 把播放器映射成它自家的歌词源。
//
// Apple Music / Spotify 不在此列 —— 它们**不是**这套里的歌词源(我们从没从它们那儿抓过
// 歌词),没有"同源"可言。auto 同理:识别不出用户在用哪个播放器,就不该瞎猜。
func playerNativeLyricSource(player string) string {
	switch player {
	case playerQQMusic:
		return "qq"
	case playerNetease:
		return "netease"
	case playerKugou:
		// 酷狗**本来就是**这个项目的五个歌词源之一(kugou.go),所以接入播放器顺带把同源
		// 加权也接上了:用酷狗听歌时优先选酷狗自己的歌词,时间轴跟它的音频母版对得上。
		return "kugou"
	default:
		return ""
	}
}

func scoreLyricCandidate(
	localArtist, localTitle, localAlbum string, durationSecs float64,
	c lyricCandidate, corroborated bool, consensusPeers int,
) int {
	score, _ := scoreLyricCandidateDetailed(localArtist, localTitle, localAlbum, durationSecs, c, corroborated, consensusPeers)
	return score
}

// scoreLyricCandidateDetailed 跟 scoreLyricCandidate 是同一套逻辑,只是额外把每一项摊出来。
// 分数被判 -1 时返回的那一项就是原因(Points 为 0),调用方据此告诉用户"为什么这条不能用"。
func scoreLyricCandidateDetailed(
	localArtist, localTitle, localAlbum string, durationSecs float64,
	c lyricCandidate, corroborated bool, consensusPeers int,
) (int, []scoreTerm) {
	reject := func(kind string) (int, []scoreTerm) {
		return -1, []scoreTerm{{Kind: kind}}
	}
	// plainTextOnly 先判:这份 lyrics 本来就没有时间戳(源明确说了只有纯文本),不该走
	// isTimedLRC 那条"疑似解析失败"的判定——理由不同,给用户看的解释也该不同(见
	// scoreRejectPlainTextOnly 头注)。两条路都在这一步截停、分数都是 -1,后面的
	// isCreditOnlyLRC/语言判定等都不会再跑到——纯文本一样可能整份只是署名信息,但那属于
	// "搜索候选歌词"弹窗自己判断要不要展示的事,不需要靠这里的打分再筛一遍。
	if c.plainTextOnly {
		return reject(scoreRejectPlainTextOnly)
	}
	if !isTimedLRC(c.lyrics) {
		return reject(scoreRejectNotTimed)
	}
	// consensusPeers>=1 兜底:2026-08-30 真实bug(Gareth.T《before you》= 网易云/QQ/酷狗/
	// LRCLIB 一致收录的《遇上你之前的我》,四个源全被语言闸判废)。isProbablyWrongLanguageLyrics
	// 现有的两道豁免(candidateArtist 含汉字 / knownArtistAlias 手工表)都基于"能不能确认
	// 这位歌手是中文歌手"——但 Gareth.T 是真实存在、只是从没起过中文艺名的粤语歌手,
	// MusicBrainz 上也查不到中文别名(artist-alias-cache.json 里"Gareth.T"就是查过、确认
	// 没有的空字符串),两道豁免都吃不到,表也没法手工登记(这类冷门/独立歌手数量上不封顶)。
	// 这里补第三道更通用的豁免:contentConsensusPeers 在这一步之前就已经统一算好了(不受
	// 这个语言闸影响),如果**至少一个独立源**的正文跟这条候选高度一致(3-gram 内容比对,
	// 不是同一次抓取、不会互相"抄"出假一致),那就是比"标签用什么字符集"直接得多的证据——
	// 四个互不相干的平台不可能一起搜到同一份内容却全是"传错语言的翻译"。跟别的豁免同一个
	// 精神:能不能确认"这条候选就是这首歌"比"歌手名写的是什么文字"更本质。
	if consensusPeers < 1 && isProbablyWrongLanguageLyrics(localArtist, localTitle, c.artist, c.lyrics) {
		return reject(scoreRejectWrongLanguage)
	}
	if isCreditOnlyLRC(c.lyrics) {
		return reject(scoreRejectCreditOnly)
	}
	score := 0
	var terms []scoreTerm
	add := func(kind string, points int) {
		if points == 0 {
			return
		}
		score += points
		terms = append(terms, scoreTerm{Kind: kind, Points: points})
	}
	if durationSecs > 0 {
		last, ok := lastLRCTimestampSecs(c.lyrics)
		if !ok {
			return reject(scoreRejectNoLastTimestamp) // 通过了 isTimedLRC 却提不出时间戳,理论上不该发生
		}
		ratio := math.Abs(last-durationSecs) / durationSecs
		switch {
		case durationFits(last, durationSecs):
			// 连续衰减,而不是硬分档——原来 3%/8%/25% 三级硬边界会让"差一点点"的候选
			// 骤然掉一整档。⚠️ 2026-08-07 把封顶从 1000 压到 300:时长吻合只是正确性的
			// **间接代理**,而且被前奏/尾奏系统性带偏(尾奏越长,越是完整正确的歌词越
			// "不吻合");逐字时间轴则是歌词质量的**直接**证据。
			add(scoreTermDuration, 100+int(200*(1-ratio/durationFitTolerance)))
		case last > durationSecs+lyricOvershootToleranceSecs:
			// v3:overshoot 独立档。歌词末句比歌曲结束还晚 5s 以上是**物理矛盾**(那几句
			// 在实际播放中根本到不了)——欠覆盖有"长尾奏没人转写"这个合法成因,超长没有,
			// 它几乎总是"完整版歌词配了精简版曲目"。所以罚得比 durationOff 更重,且**不给**
			// 跨源印证豁免:两个源一起抓到同一个错版本恰恰是印证的已知翻车形态(Valentina)。
			add(scoreTermDurationOvershoot, -700)
		case corroborated:
			// 时长差超阈值,但有别的独立源印证末尾时间点。⚠️ 只有在**没有任何一条候选
			// 时长吻合**时才可能走到这里,见 corroboratedEndings 里那段注释。
			add(scoreTermCorroborated, 100)
		default:
			// 不再一票否决,见 durationMismatchPenalty 的注释。
			add(scoreTermDurationOff, -durationMismatchPenalty)
		}
	}
	// 源自报曲长这一项**独立于**上面那一档:上面判的是"这份歌词的时间轴铺得够不够长"
	// (代理),这里判的是"这份歌词挂在哪一次录音上"(直接测量)。两者都成立时会叠加扣分,
	// 这是有意的 —— 那种候选既没铺满又自报是别的录音,证据是相互印证的,不是重复计罚。
	// 源没自报时长(0)一律不扣:没有证据不等于反面证据。
	if durationSecs > 0 && c.sourceReportedDurationSecs > 0 {
		larger := math.Max(c.sourceReportedDurationSecs, durationSecs)
		if math.Abs(c.sourceReportedDurationSecs-durationSecs)/larger > sourceDurationMismatchTolerance {
			add(scoreTermSourceDurationOff, -sourceDurationMismatchPenalty)
		}
	}
	if c.hasWordTiming {
		add(scoreTermWordTiming, 400) // 跟"一档时长差距"同量级,让带逐字时间轴的候选能逆转
	}
	if isNativeLyricSource(c.source) {
		// 跟当前播放器同源的歌词加分。
		//
		// 理由是**时间轴**,不是内容质量:同一个平台的歌词是对着同一个音频母版对的轴,
		// 时间戳天然吻合;跨平台的版本差异(前奏长短、母带版本)正是"整句慢半个字"的来源。
		// 2026-08-15 实测:用户放着 QQ 音乐听周杰伦《太阳之子》,这套打分给他配了酷狗那份
		// (酷狗有逐字 +400 直接压过 QQ),整行比 QQ 自己的歌词界面慢半个字左右。
		//
		// ⚠️ 这**不是**在把 2026-08-09 删掉的那个"按来源加 10~50 分"改头换面加回来。
		// 那一个是**静态**来源偏好(网易云一律加分),跟用户在放什么无关;这一个是**动态**的
		// (放 QQ 音乐才偏向 QQ)。更要紧的是两者衡量的维度不同:那次消融实验的判据是
		// 「跨源内容一致性」,测的是歌词**文本**对不对,而这一项修的是**时间轴对不对齐音频**
		// —— 那次实验根本没测过这个维度,它的结论(0 次变对/6 次变错)管不到这里。
		//
		// 权重取 250 而不是 400:压不过逐字时间轴那一档是**故意的**。同源只说明"轴大概率
		// 更准",不说明歌词本身完整正确 —— 给到 400 就会让一份行数残缺的同源歌词赢过完整
		// 的跨源歌词,那正是 08-09 那次翻车的形态。250 的作用是在质量接近时扭转结果,
		// 不是碾压质量差距。
		add(scoreTermNativeSource, 250)
	}
	// ⚠️ 这里曾经按来源加 10~50 分。2026-08-09 实测把它删掉了 —— 250 首抽样、751 条候选、
	// 以「跨源内容一致性」为准的消融实验结论:
	//
	//   它改变了 69/206 首歌的冠军,其中 0 次让结果变对、6 次让结果变错。
	//   去掉之后准确率 93% → 96%。
	//
	// 而且它并不是「平手时的决胜项」——冠亚军分差中位只有 22 分、74% 的歌 ≤40 分,正好落在
	// 它的跨度里,也就是说它在大多数歌里都是决定性的。它排的是我们对来源的先入之见,不是
	// 关于这一份歌词的任何证据(引入它的那次提交连一行理由都没写,排序只是照抄了改造前的
	// 顺序回退次序)。
	//
	// 完全同分时的先后交给**稳定排序 + 候选构造顺序**(见 scoredLyricCandidates 里
	// candidates 的追加次序),不再用分数假装那是质量判断。
	lines := len(strings.Split(c.lyrics, "\n"))
	if lines > 200 {
		lines = 200
	}
	add(scoreTermLines, lines)
	// 版本限定词对不上 → 重扣。理由见 versionMismatchPenalty。判定同时看歌名和**专辑名**,
	// 理由见 versionTagsMismatch。v8 加一道窄豁免:时长逐位吻合+专辑亲和+多出的限定词
	// 只是演奏方式(acoustic 家族)时,是同一次录音的命名差异,不是版本差异 —— 见
	// sameRecordingDespiteVersionTags(全库回放:现存 433 个吃 -600 的候选 0 个被豁免,
	// 0 翻盘;它只对"源平台标注了演奏方式、本地曲名没标"这一类新召回的候选生效)。
	if versionTagsMismatch(localTitle, localAlbum, c.title, c.album) &&
		!sameRecordingDespiteVersionTags(localTitle, localAlbum, durationSecs, c.title, c.album, c.sourceReportedDurationSecs) {
		add(scoreTermVersionTags, -versionMismatchPenalty)
	}
	// v7:两场不同命名的演出 → 同级重扣。versionTagsMismatch 在「两边都是 Live」时限定词
	// 集合相等、必然静默,这一档接住它够不到的那半边。判据和四道防误伤的门见
	// liveAlbumIdentityConflict 的注释。
	if liveAlbumIdentityConflict(localArtist, localAlbum, c.title, c.album) {
		add(scoreTermLiveAlbumConflict, -liveAlbumConflictPenalty)
	}
	// ---- v3 新维度(2026-08-12,分值全部来自 201 首反事实消融,见 lyricsScoringVersion 注释) ----
	// 专辑亲和:只加不减——专辑名缺失/对不上是"零证据",不是负证据(中英互译专辑名、
	// single 发行 vs 专辑收录都是合法的"对不上");各源内部挑歌时算过的专辑锁定,在这里
	// 终于反映到跨源排序上。复用 albumScore 的档位(normLoose 相等=200/词元子集=100/…)。
	if strings.TrimSpace(localAlbum) != "" && strings.TrimSpace(c.album) != "" {
		switch s := albumScore(c.album, localAlbum); {
		case s >= 200:
			add(scoreTermAlbum, 150)
		case s >= 100:
			add(scoreTermAlbum, 75)
		case s >= 1:
			add(scoreTermAlbum, 40)
		}
	}
	// 标题吻合梯度:②层的 lyricTitleAccepted 是道布尔门,过了门"精确同名"与"剥括号后
	// 才相等"在打分层完全平权——18 词版本表之外的限定词(sped up/TV size)全靠它区分。
	if p := titleMatchTierPoints(c.title, localTitle); p > 0 {
		add(scoreTermTitleMatch, p)
	}
	// 跨源正文共识:与其它源的歌词**内容**互证(3-gram Jaccard),比 corroboratedEndings
	// 只比末尾时间戳一个标量强得多——串到别的歌/版本的候选不会凑巧和别的源正文一致。
	// peers 由 contentConsensusPeers 在整批候选上统一算好传入(带防搜歪共伴的时长闸)。
	switch {
	case consensusPeers >= 2:
		add(scoreTermConsensus, 250)
	case consensusPeers == 1:
		add(scoreTermConsensus, 150)
	}
	// 增值内容决胜:见 lyricCandidate.hasUsableTranslation 的注释。
	if c.hasUsableTranslation {
		add(scoreTermTranslation, 50)
	}
	if c.hasUsableRomanization {
		add(scoreTermRoma, 30)
	}
	// 扣完统一夹到 1:负分会被 pickLyricCandidate 当成「不可用」直接丢弃,而这两种重扣
	// 表达的是「差」,不是「不能用」。夹到同一个 1 意味着几条都被重扣的候选会同分,先后
	// 由稳定排序按构造顺序决定 —— 可接受:走到这一步说明它们没有一条是像样的。
	if score < 1 {
		score = 1
	}
	return score, terms
}

// scoreTermPoints 从一份候选的 score_terms 里取某一项的分值,没有就是 0。给
// applyWordTimingTitleOverride 这类"打完分之后再看一眼某一项give了多少"的后处理用。
func scoreTermPoints(terms []scoreTerm, kind string) int {
	for _, t := range terms {
		if t.Kind == kind {
			return t.Points
		}
	}
	return 0
}

// applyWordTimingTitleOverride 是 v5(2026-08-27)新增的收尾一步:全部候选打完分、
// **排序之前**,检查"逐字时间轴的 +400 是不是唯一让这个候选赢的理由,而另一个候选的
// 标题明显更吻合"。
//
// 起因是用户报的真实误配案例(方大同《公园 (Live版)》,收在专辑「大事发声·录音棚现场:
// 方大同专场」):酷狗那份歌词标题是「公园 (Live)」、专辑是「Timeless演唱会」——是**另一场
// 演出**的逐字版本,时间轴是按那场演出对的轴,套在这次实际播放的录音上大概率跟不上字;
// 网易云那份标题「公园 (Live版)」跟查询词逐字相同、专辑也部分对得上,但没有逐字数据,
// 单靠 674 分打不过酷狗的 944 分,而两者的分差几乎全部来自 wordTiming 那 400 分
// (170+64+60+250=544 vs 169+60+75+120+250=674,酷狗只靠 +400 才反超)。
//
// 400 分本身**不该**下调:拿真实曲库(1818 首,861 条完整解析记录)做过反事实消融,
// wordTiming 是决定性因素(去掉它冠军就换人)的案例有 240 个,占全部决策的 27.9%——
// 权重很重,broad 调低会牵连其中绝大多数本来选对的案例(al 那 118 个"专辑分反而支持
// 亚军"的案例,抽查后基本是"(Explicit)" 这类标签差异的噪音,不是真的选错版本)。但
// **标题吻合分也站在亚军那边**的只有 2 个(0.83%),而且两个都是货真价实的版本误配
// (这首歌,以及一首迈克尔·杰克逊单曲版 vs 原声带完整版混进来的案例),titleMatch 在
// 这两例里 0 误报——所以窄口子开在 titleMatch 上,不碰 wordTiming 权重本身,也不影响
// 另外 238 个案例。
//
// 判据三条同时成立才触发,缺一不可:①当前冠军(排除一票否决/纯音乐标记)带 wordTiming
// 加分;②去掉这份 +400 之后,会有另一个真实候选反超;③那个候选的 titleMatch 分严格
// 高于冠军。命中就把冠军的 wordTiming 加分**整段撤销**(不是打折、不是直接判它无效)——
// 跟 overshoot 那档「物理矛盾不吃跨源印证豁免」是同一个道理:标题都对不上号,逐字时间轴
// 转写得再细也不能证明这是同一次录音,继续拿它压过标题更吻合的候选说不通。
func applyWordTimingTitleOverride(results []scoredLyricCandidateResult) {
	winnerIdx := -1
	for i := range results {
		if results[i].Score < 0 {
			continue
		}
		if winnerIdx == -1 || results[i].Score > results[winnerIdx].Score {
			winnerIdx = i
		}
	}
	if winnerIdx == -1 {
		return
	}
	winner := &results[winnerIdx]
	wtPoints := scoreTermPoints(winner.ScoreTerms, scoreTermWordTiming)
	if wtPoints <= 0 {
		return
	}
	scoreWithoutWT := winner.Score - wtPoints

	runnerUpIdx := -1
	for i := range results {
		if i == winnerIdx || results[i].Score < 0 || results[i].Score <= scoreWithoutWT {
			continue
		}
		if runnerUpIdx == -1 || results[i].Score > results[runnerUpIdx].Score {
			runnerUpIdx = i
		}
	}
	if runnerUpIdx == -1 {
		return // 去掉 wordTiming 冠军仍然是冠军,不需要动它
	}
	runnerUp := &results[runnerUpIdx]
	if scoreTermPoints(runnerUp.ScoreTerms, scoreTermTitleMatch) <= scoreTermPoints(winner.ScoreTerms, scoreTermTitleMatch) {
		return // 标题吻合度没有站在亚军那边,不该由这条规则接管
	}

	winner.Score -= wtPoints
	if winner.Score < 1 {
		winner.Score = 1 // 跟 scoreLyricCandidateDetailed 末尾同一条夹底纪律
	}
	winner.ScoreTerms = append(winner.ScoreTerms, scoreTerm{Kind: scoreTermWordTimingOverride, Points: -wtPoints})
}

// normLoose lowercases and drops everything but letters/digits (keeps CJK), so
// "BLOOD ON THE DANCE FLOOR/ HIStory In The Mix" and "Blood On the Dance Floor:
// HIStory In the Mix" compare equal when matching albums across services.
// 顺带先过一遍 toSimplified——候选的标题/专辑字段有时是简体、本地 Apple Music 标签是
// 繁体,逐字符比较会误判成两首不相关的歌。直接下沉到 normLoose 本身,而不是在每个调用点
// (titleMatches/albumScore 等)各自补一遍,统一受益。toSimplified 认不出的字符原样
// 保留,不会让不相关的名字被错误判定成相关,也不影响下游防仿冒号判定(那部分靠歌手名/
// 专辑名核实,繁简转换只影响字符形式)。
func normLoose(s string) string {
	var b strings.Builder
	// 变音折叠跟 toSimplified 同一个下沉位置、同一个理由:在这里做一次,全部源的匹配
	// 同时受益,而不是让每个调用点各自记得处理(见 fold.go)。
	for _, r := range foldDiacritics(strings.ToLower(toSimplified(s))) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// looseContains reports whether two names refer to the same title/album after
// normalization (equal, or one contains the other — handles "(Radio Edit)",
// ":" vs "/", case, spacing). Used to disambiguate same-song-many-albums.
func looseContains(a, b string) bool {
	na, nb := normLoose(a), normLoose(b)
	if na == "" || nb == "" {
		return false
	}
	return na == nb || strings.Contains(na, nb) || strings.Contains(nb, na)
}

// artistCreditParts splits a "多人合credit"字符串(如"Prince & The Revolution"、
// "陶喆、卢广仲")按 逗号/斜杠/顿号/& 拆成各自的人名,裁剪空白后丢弃空段。只有真正切出
// ≥2 段(说明分隔符确实在分隔两个人名)才算数——像"周杰伦、"这种切完只剩 1 段的,分隔符
// 本身就是可疑的仿冒特征(网易云出现过艺人字段就是独立一条"周杰伦、"的仿冒条目),
// 调用方按"len<2 就当成单一人名"处理,不能被这种情况悄悄吃掉。
// 顺带先过一遍 toSimplified,理由跟 normLoose 完全一样——候选的艺人字段有时是简体、
// 有的源(如 YouTube Music/LyricFind)给的是繁体,不折算就会把同一个人判成两个人
// (2026-08-25 实测坐实:"周杰伦"查不到候选,因为召回的正确结果署名"周杰倫")。下沉到
// 这个函数本身而不是在每个调用点各自补,是因为 artistCreditParts 本来就已经在这里做了
// 一次 ToLower——同一个理由、同一个下沉位置。只转字符形式,不做 normLoose 那样的标点
// 剥离,不影响下面的防仿冒判定(尾随分隔符等仍然原样保留)。
func artistCreditParts(s string) []string {
	var parts []string
	for _, p := range strings.FieldsFunc(strings.TrimSpace(strings.ToLower(toSimplified(normalizeArtistCreditHanAnd(s)))), isArtistCreditSep) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	return parts
}

// normalizeArtistCreditHanAnd 把"Khalil Fong和Fiona Sit"这类写法里,夹在两个拉丁字母
// 之间的中文"和"换成"&"，换算之后复用现成的 isArtistCreditSep/isArtistCreditPrimarySep,
// 不需要把"和"直接加进那两个分隔符字符集。
//
// 2026-08-30 真实bug(方大同 & Fiona Sit《Four Tour》案,「搜索候选歌词」弹窗"七个源都
// 没找到"):同一首歌在库里有两份标签——"Khalil Fong & Fiona Sit"(能拆开,首歌手变体轮
// 正常触发,已经解析成功)和"Khalil Fong和Fiona Sit"(拆不开,变体轮从未触发,一直没
// 解析出来)。原因是"和"压根不在 isArtistCreditSep/isArtistCreditPrimarySep 认的分隔符
// 集合里(只有 `/、&,，`),整串被当成一个谁都不认识的艺人名。
//
// ⚠️ 不能直接把 '和' 塞进那两个分隔符字符集:那两个字符集里的成员全是纯标点,几乎不可能
// 出现在真实人名/乐队名内部;"和"是常见汉字,真实存在"李和平"这类名字本身就含"和"的情况,
// 不加限制地把它当分隔符会把这类名字切碎——这正是 isArtistCreditSep 头注记录的那次真实
// 教训(分隔符加错,播放记录写去了无关歌手名下,Last.fm 上删不掉)想要避免重演的那类错误。
// 最初(2026-08-30)收紧成"仅当两侧都紧邻 ASCII 字母时才算连接词",精确对应"中文'和'
// 连接两个拉丁书写艺人名"这一种写法。
//
// 2026-08-31 补第二档——两侧都是中文时也可能是连接词。真实bug:陶喆《再見你好嗎》专辑
// 第8首"那個女孩(feat. 盧廣仲)",本地标签联合署名成"陶喆和盧廣仲",没有一个歌词源是
// 按这个联合写法索引的(各自写的是"陶喆、卢广仲"或单独"陶喆")——「搜索候选歌词」弹窗
// 八个源全部搜不到,而单独查"陶喆"四个源立刻找到、分数都在800+。ASCII 那道判据在这里
// 用不上("陶喆"/"盧廣仲"都是中文),但同样不能像最初那版一样对中文"和"不加区分——
// "李和平"仍然是真实存在的人名。判据是:"和"两侧各自紧邻的**连续中文字符段**长度都
// ≥2(遇到分隔符/另一个"和"/非中文字符就停,不跨段计数)——复用 slashHeadPlausible 判
// "这段够不够格当一个名字"的同一条阈值(中文 ≥2 字),"陶喆"(2字)、"盧廣仲"(3字)双双
// 达标,"李和平"拆成"李"/"平"各 1 字,双双不达标,原样保留。跟 ASCII 那档一样是启发式,
// 不保证零误判(理论上存在"XX和YY"恰好是同一个人名字的情况),但比"两侧是中文就一律切"
// 安全得多,而且用的是这个仓库里已经在用、已经有测试的同一条"像不像名字"判据,不是新发明
// 一条没验证过的规则。
//
// 按 rune 逐个独立判断(不是用正则整串替换):正则整串替换会在连续多个"和"时漏掉一半
// (替换会"消耗"掉共享的那个字母,导致"A和B和C"只切出"A&B和C")；逐 rune 判断时每个
// "和"只看它自己左右紧邻的字符/字符段,不受相邻替换影响,"A和B和C"三段都能正确切开。
func normalizeArtistCreditHanAnd(s string) string {
	runes := []rune(s)
	hasHanAnd := false
	for _, r := range runes {
		if r == '和' {
			hasHanAnd = true
			break
		}
	}
	if !hasHanAnd {
		return s // 绝大多数调用不含"和",不值得为此分配一次 []rune + Builder。
	}
	var b strings.Builder
	b.Grow(len(s))
	for i, r := range runes {
		if r == '和' && i > 0 && i < len(runes)-1 &&
			((isASCIILetter(runes[i-1]) && isASCIILetter(runes[i+1])) ||
				(hanRunLenBefore(runes, i) >= 2 && hanRunLenAfter(runes, i) >= 2)) {
			b.WriteByte('&')
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// hanRunLenBefore/hanRunLenAfter 数"和"紧邻的那一侧,连续中文字符段有多长——遇到
// "和"自己、isArtistCreditSep 认的分隔符、或者任何非中文字符,立刻停止计数(不跨段、
// 不跨字符集混排,宁可少数也不多数)。跟 slashHeadPlausible 判"够不够格当一个名字"用
// 同一条阈值(见 normalizeArtistCreditHanAnd 头注),这里直接数长度而不是切出子串再调用
// 那个函数——数出来的本来就是纯中文段,不需要再判一次 hasHan。
func hanRunLenBefore(runes []rune, i int) int {
	n := 0
	for j := i - 1; j >= 0; j-- {
		r := runes[j]
		if r == '和' || isArtistCreditSep(r) || !unicode.Is(unicode.Han, r) {
			break
		}
		n++
	}
	return n
}

func hanRunLenAfter(runes []rune, i int) int {
	n := 0
	for j := i + 1; j < len(runes); j++ {
		r := runes[j]
		if r == '和' || isArtistCreditSep(r) || !unicode.Is(unicode.Han, r) {
			break
		}
		n++
	}
	return n
}

func isASCIILetter(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

// isArtistCreditSep 是"多人合credit"字符串的分隔符集合。
//
// ⚠️ **只有 artistCreditParts 用它**。原注释写的是"artistCreditParts/firstCreditedArtist
// 共用同一份,避免以后加分隔符漏改一处"—— 那是错的(2026-08-30 核实):取第一位艺人的
// firstCreditedArtist 走的是下面的 isArtistCreditPrimarySep + firstSlashCredit,从不调
// 本函数,两处需求相反、早已分家(理由见下一个函数的注释)。
//
// 这条错注释的危害恰好是它声称要防的那件事:**加分隔符时必须两处都改**,而照原文会以为
// 改一处就自动跟进。2026-08-23 那次"只修一半"——无害的显示侧修了、不可逆的写侧没修——
// 把 4 次播放写到了无关歌手 `K` 名下,而 scrobble 落进 Last.fm 基本删不掉。中文"和"这次
// 没有直接加进这个字符集,见 normalizeArtistCreditHanAnd 头注——那条注释里"两处都要改"
// 的教训在这里换了个形式适用:两个分隔符函数都调用点都必须先过 normalizeArtistCreditHanAnd
// 预处理,漏了哪一个都会导致同一首歌在"拆得开"和"拆不开"之间行为不一致。
func isArtistCreditSep(r rune) bool {
	return r == '/' || r == '、' || r == '&' || r == ',' || r == '，'
}

// isArtistCreditPrimarySep 是"取第一位艺人"时的**主分隔符档**。刻意**不含 `/`** ——
// 理由见 slashHeadPlausible。跟 isArtistCreditSep 分成两个函数而不是共用一份:那一份是
// 给 artistCreditParts(判断"是否同一个人")用的,它把 K/DA 切开是**有意的**,靠
// artistCreditRunMatches 再把连续段拼回去(见 artistcreditrun_test.go)。两处需求相反,
// 硬共用一份才是坑的来源。
func isArtistCreditPrimarySep(r rune) bool {
	return r == '、' || r == '&' || r == ',' || r == '，'
}

// firstCreditedField 按 sep 切,只有真切出 ≥2 段才算"这是个合credit 串"。
func firstCreditedField(s string, sep func(rune) bool) (string, bool) {
	var parts []string
	for _, p := range strings.FieldsFunc(s, sep) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) >= 2 {
		return parts[0], true
	}
	return "", false
}

// slashHeadPlausible 判断"只有 `/` 一个分隔符时,切出来的头部像不像一个真的艺人名"。
//
// `/` 是双面刃:网易云式合 credit 常写成 `陶喆/卢广仲`(该切),而 `K/DA`、`AC/DC` 里的
// 斜杠是名字自带的(切了就把一个人劈成「K」「AC」)。判据用长度,按书写系统分档:含汉字的
// 两个字就是完整名字,纯拉丁两个字母几乎只可能是缩写的前半截,要求 ≥3。判不准时**不切**
// —— 少归并一次只是维持现状,切错是往 Last.fm 写错数据、不可逆。
//
// ⚠️ 与 Swift 侧 LyrimuseCore/Models/ArtistCredit.swift 的 slashHeadIsPlausible
// **必须逐字同规则**,两边一起改。2026-08-23 修的正是"只修了一半"造成的事故:那道守卫
// 2026-08-20 只加在 Swift 侧(只管显示),而 Go 侧这条路径才是真正改写
// scrobble 歌手名的写侧 —— 实测把 `K/DA/Madison Beer/i-dle/Jaira Burns` 折成了 `K`,
// 4 次播放记到了 Last.fm 上一个**真实存在的无关歌手**「K」(10.8 万听众)名下,而 K/DA
// 名下 0 次。Last.fm 的纠错库已冻结,这种写错全局补不回来。
func slashHeadPlausible(head string) bool {
	if head == "" {
		return false
	}
	hasHan := false
	for _, r := range head {
		if r >= 0x4E00 && r <= 0x9FFF {
			hasHan = true
			break
		}
	}
	min := 3
	if hasHan {
		min = 2
	}
	return utf8.RuneCountInString(head) >= min
}

// firstCreditedArtist 把"多人合credit"字符串(如"Prince & The Revolution"、
// "陶喆、卢广仲")拆开取第一位——歌手统计类场景(见 topartists.go 的 mergeAliasedArtists)
// 要求这类合唱/feat.credit 全部算到"第一个人"头上,不单独占一个歌手名额。只有真正切出
// ≥2 段才当作合唱处理(防止"周杰伦、"这种只有一个人、结尾恰好带分隔符的写法被误判成合唱)。
// 返回原始大小写/原始文字(不像 artistCreditParts 那样统一转小写——那是给"判断是否同一个
// 人"这一步比较用的,这里要的是展示用的原始名字)。
//
// 分两档切,顺序本身就是守卫:`K/DA, Madison Beer & i-dle` 先撞上逗号,切出来的是完整的
// 「K/DA」;只有全串一个逗号/顿号/& 都没有时才退到 `/` 档,且要过 slashHeadPlausible。
func firstCreditedArtist(s string) string {
	trimmed := strings.TrimSpace(s)
	// normalizeArtistCreditHanAnd 头注里"两处都要改"的第二处。喂给 firstCreditedField/
	// firstSlashCredit 的是替换过"和"的版本,但不影响"返回原始大小写/原始文字"这条既有
	// 约定:被替换的"和"字符本身就是分隔符、不会出现在切出来的头部段落里,头部段落的其余
	// 字符跟 trimmed 逐字相同。
	normalized := normalizeArtistCreditHanAnd(trimmed)
	if head, ok := firstCreditedField(normalized, isArtistCreditPrimarySep); ok {
		return head
	}
	if head, ok := firstSlashCredit(normalized); ok {
		return head
	}
	return trimmed
}

// firstSlashCredit 处理"全串只有 `/` 一种分隔符"的情况。
//
// 光靠"头部判不准就整串不切"是**不够**的:`K/DA/Madison Beer/i-dle/Jaira Burns` 确实
// 是个合credit 串,第一位是 `K/DA` —— 整串不切会让它跟榜上的 `K/DA` 条目合不到一起
// (topartistsdisplay_test 那两条正是这个期望:30 + 12 要并成 42、显示 `K/DA`)。
// 所以头部判不准时**往后再吃一段**再判:`K` ✗ → `K/DA` ✓。
//
// 吃到整串仍不成立 = 整串大概本来就是一个名字(`AC/DC`),返回不切。
//
// 已知取舍:全是单字母段的名字(`M/A/R/R/S` 这种)会被切成 `M/A`。这类写法极罕见(真名
// 通常用竖线),而反过来"一律不切"会牺牲掉 K/DA 这类主流情况;判据本来就是启发式,宁可
// 在罕见形态上退化,也不要在常见形态上劈错。
func firstSlashCredit(s string) (string, bool) {
	var parts []string
	for _, p := range strings.FieldsFunc(s, func(r rune) bool { return r == '/' }) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) < 2 {
		return "", false
	}
	head := parts[0]
	for i := 1; i < len(parts); i++ {
		if slashHeadPlausible(head) {
			return head, true
		}
		head += "/" + parts[i]
	}
	return "", false
}

// artistMatches reports whether two artist names refer to the same person/act.
// Unlike looseContains (fine for titles/albums, where stripping punctuation and
// loose containment is desirable), artist IDENTITY must not be checked with
// normLoose+Contains: normLoose strips all punctuation, so an impersonator
// account like "周杰伦-" or "周杰伦." normalizes identical to "周杰伦" and would
// wrongly pass as the genuine artist — and even without normLoose, plain
// substring containment still lets "周杰伦" match as a prefix of "周杰伦-".
// This requires each comma/slash/顿号/&-separated part of either name to be
// byte-for-byte equal (case-folded, trimmed) to the other — good enough for
// legitimate cross-service formatting noise (spacing, multi-artist credit
// order) without accepting a name that merely starts with/contains the real one.
//
// na/nb 先过一遍 toSimplified 再小写——跟 normLoose 同一个理由、同一个函数复用
// (2026-08-25 实测坐实:YouTube Music/LyricFind 给的艺人字段是繁体"周杰倫",本地查询是
// 简体"周杰伦",不折算就判成两个不同的人,一条确认有效的候选被整条拒收)。只转字符形式,
// 不做 normLoose 那样的标点剥离,防仿冒精度不受影响——"周杰伦-"折算后仍是"周杰伦-",
// 跟"周杰伦"依旧不相等。
func artistMatches(a, b string) bool {
	na, nb := strings.TrimSpace(strings.ToLower(toSimplified(a))), strings.TrimSpace(strings.ToLower(toSimplified(b)))
	if na == "" || nb == "" {
		return false
	}
	if na == nb {
		return true
	}
	if pa := artistCreditParts(na); len(pa) >= 2 {
		for _, part := range pa {
			if part == nb {
				return true
			}
		}
		// 逐段相等之外再放一档:连续若干段拼回去也算(人名自身含分隔符的情况),
		// 见 artistCreditRunMatches。
		if artistCreditRunMatches(na, nb) {
			return true
		}
	}
	if pb := artistCreditParts(nb); len(pb) >= 2 {
		for _, part := range pb {
			if part == na {
				return true
			}
		}
		if artistCreditRunMatches(nb, na) {
			return true
		}
	}
	// 去括号别名兜底(2026-08-26,「聪明不聪明」实测坐实):YouTube Music 给的艺人字段是
	// "丁世光(Dean Ting)"——主名字后面括号里跟一个外文别名/罗马字/艺名,本地标签只有
	// "丁世光",逐段比较(上面两档)永远对不上,因为这整串根本没有 artistCreditParts 认的
	// 分隔符、切不开。lyricTitleAccepted 早就对标题做同样的事(stripParens 再比),这里补
	// 上艺人这边对应的同一条规则。
	//
	// 只在去括号后**确实变了**且**非空**才递归比一次,防止无括号输入原地死循环(stripParens
	// 对无括号串是恒等函数)。不会重新打开防仿冒的老洞:仿冒特征是"尾随分隔符切不出第二段"
	// (如"周杰伦-"/"周杰伦、"),跟括号别名是两种形状——括号内容是同一个人的补充说明(外文名/
	// 罗马字),不是伪装成另一个人的诱饵;这正是括号在 lyricTitleAccepted 里已经被同等信任的
	// 理由,这里只是把同一份信任延伸到艺人名。
	if sa := stripParens(na); sa != na && sa != "" && artistMatches(sa, nb) {
		return true
	}
	if sb := stripParens(nb); sb != nb && sb != "" && artistMatches(na, sb) {
		return true
	}
	return false
}

// artistCreditRunMatches reports whether needle 作为**分隔符界定的连续片段**出现在 hay
// 里。两个参数都要求调用方已经归一化(小写、去首尾空白)。
//
// 为什么需要它:artistCreditParts 按分隔符把合credit 串切段,而 `/` 既是常见分隔符、
// 又可能是**人名自身的一部分**(K/DA、AC/DC)。"K/DA/Madison Beer/(G)I-DLE/Jaira Burns"
// 切出来是 ["k" "da" "madison beer" "(g)i-dle" "jaira burns"] —— `"k/da"` 永远不是其中
// 任何一段,于是 artistMatches("K/DA", 那一串) 是 false:**真正的歌手过不了闸,而一个
// 根本不存在的"K"反而能过**。
//
// 2026-08-17 用户报的现象就是这个:「联网搜索候选歌词」用播放器给的完整歌手串只搜到
// 两条候选,把歌手手工截短成 "K/DA" 之后变成三条 —— Musixmatch 的采纳条件里有
// artistMatches(它返回的 artist_name 正是 "K/DA"),哪怕 API 把正确那条返回了也会被
// 原地拒掉;而且 netease/lrclib 两条本来就找得到的候选也因为歌手项没拿到分、各低了整
// 100 分,导致 app 退而用了没有逐字时间轴的那份。
//
// 把"连续若干段拼回去"也算一种匹配就补上了这个洞:`k/da` 正是 [k, da] 这两段按原分隔符
// 拼回去的结果,也就是 hay 里一个分隔符界定的片段。
//
// ⚠️ 判据**不能**退化成任意子串匹配:那样 "an" 会命中 "anna"、"da" 会命中 "dave"。
// 要求命中处两侧要么是字符串边界、要么(跳过空白之后)紧邻一个分隔符 —— 这正是
// "整段或整几段"的含义。
//
// ⚠️ 调用方必须保留 `len(parts) >= 2` 那道守卫,不能把这个函数单独拿出来用:
// artistMatches("周杰伦", "周杰伦、") 现在是 false,而那是**故意的** —— 网易云出现过
// 艺人字段就是 "周杰伦、" 的仿冒条目,尾随分隔符本身就是仿冒特征(见 artistCreditParts
// 和 neteaseImpersonatorRiddenArtists 的注释)。少了那道守卫,这条防线会被顺手拆掉。
func artistCreditRunMatches(hay, needle string) bool {
	if hay == "" || needle == "" || len(needle) > len(hay) {
		return false
	}
	for off := 0; off+len(needle) <= len(hay); {
		i := strings.Index(hay[off:], needle)
		if i < 0 {
			return false
		}
		i += off
		if artistCreditBoundaryBefore(hay[:i]) && artistCreditBoundaryAfter(hay[i+len(needle):]) {
			return true
		}
		off = i + 1
	}
	return false
}

// artistCreditBoundaryBefore:命中处左侧要么只剩空白(等于字符串开头),要么最后一个
// 非空白字符是分隔符。空白本身**不算**边界 —— 否则 "the" 会命中 "the revolution"。
func artistCreditBoundaryBefore(s string) bool {
	s = strings.TrimRight(s, " \t")
	if s == "" {
		return true
	}
	r, _ := utf8.DecodeLastRuneInString(s)
	return isArtistCreditSep(r)
}

// artistCreditBoundaryAfter:同上,方向相反。
func artistCreditBoundaryAfter(s string) bool {
	s = strings.TrimLeft(s, " \t")
	if s == "" {
		return true
	}
	r, _ := utf8.DecodeRuneInString(s)
	return isArtistCreditSep(r)
}

// lyricSourceArtistMatches 是**歌词源候选采纳闸**专用的歌手匹配:在 artistMatches 之上
// 多放一档"两侧都是多人合credit 时,拆段后有任意一段相等即通过"。
//
// 为什么需要它(2026-08-20,「wherever u r」实测坐实):本地标签 "UMI & 金泰亨" 查酷狗,
// 服务端召回其实是成功的——正主排第 1、署名 "UMI、V"——却被 artistMatches 原地拒掉:
// 它只做"一方的段 == 另一方整串"和连续段拼回,两侧**各自**拆段后的交集(umi 明明两边
// 都有)永远不被比较;连纯英文 "UMI & V" 对 "UMI、V" 都过不了(分隔符不同,整串不等、
// 段对整串也不等)。跨服务的合唱署名本来就会换分隔符、换合作者的语言写法(V ↔ 金泰亨),
// 要求整串对上等于要求两边曲库用同一套署名习惯。
//
// 只用在歌词候选的采纳闸(kugou/qq strict 档/lrclib search/musixmatch),**不替换**
// artistMatches 本身——后者还服务于身份判定/防仿冒(nameOnlyMatch、canonical 统一
// 拼写),那些场景放宽会扩大仿冒面。防仿冒守卫在这里同样保留:交集档要求**两侧都**
// 真正切出 ≥2 段(artistCreditParts 的 len<2 约定),"周杰伦、"这种尾随分隔符的仿冒
// 写法只切出 1 段,永远进不了交集档;段与段之间仍是字节相等(小写/去空白/toSimplified
// 折算繁简后),不做 normLoose 那样的标点剥离/子串,"周杰伦-" 冒充 "周杰伦" 的老洞不会
// 被重新打开。
func lyricSourceArtistMatches(candidate, query string) bool {
	if artistMatches(candidate, query) {
		return true
	}
	pc, pq := artistCreditParts(candidate), artistCreditParts(query)
	if len(pc) < 2 || len(pq) < 2 {
		return false
	}
	for _, c := range pc {
		for _, q := range pq {
			if c == q {
				return true
			}
		}
	}
	return false
}

const (
	// lyricRecordingTriangleDurationTolerance:三角验证对时长吻合度的要求(1%)。
	// 比打分层的 durationFitTolerance(25%)严 25 倍,因为量的根本不是同一样东西:
	// 打分层量"LRC 末句时间戳 vs 曲长"(被前奏/尾奏/返场系统性带偏,必须宽松),这里量
	// 两边**各自自报的曲目时长**——同一次录音跨平台只会差在取整。实测本案例
	// 119.213(Apple) vs 119.21(网易云/酷狗),ratio 0.0000252。
	lyricRecordingTriangleDurationTolerance = 0.01
	// lyricRecordingTriangleAlbumWidthRatio:专辑名只是"宽松包含"(albumScore=100)而非
	// 逐字相等时,额外要求候选专辑名归一后的长度不低于本地专辑名的这个比例。
	// 为什么需要:albumScore 的包含档对**短通用串**几乎免检——实测同一批酷狗搜索结果里
	// 「炸小肉丸 / album="周杰伦" / 62s」也拿到 100 分(「周杰伦」正好是「周杰伦地表最强
	// 世界巡回演唱会live」的子串),真正挡住它的只有时长那一条。加这道长度可比性要求,
	// 把"抄一个短热词当专辑名"排除掉,别让整条防线单靠时长撑着。
	lyricRecordingTriangleAlbumWidthRatio = 0.6
)

// lyricRecordingTriangleMatches 是歌手闸之外的**第二条歌词候选采纳依据**:歌手名跨平台
// 对不上,但"标题逐字同名 + 专辑对得上 + 时长紧密吻合"三者同时成立时,判定为同一次录音。
//
// 为什么需要它(2026-08-22 实测坐实):歌手署名的跨平台分歧不止"换分隔符 / 换合作者语言
// 写法"那两类(它们已由 lyricSourceArtistMatches 的段集交集档吃掉),还有一类是**同一个人
// 的不同称呼**——艺名↔本名、乐队名↔成员名,而且中文署名经常连分隔符都没有。案例:Apple
// Music 把《周杰伦地表最强世界巡回演唱会 (Live)》第 14 首「枫+退后+搁浅 (Live)」署名成
// 「南拳妈妈弹头」(乐队名和成员名直接粘在一起),而网易云/QQ/酷狗三家都署名「宋健彰」
// (弹头的本名)。artistCreditParts 对这两串都只切出 1 段(isArtistCreditSep 只认
// / 、 & , ，五个字符,这里一个都没有),段集交集档的 len>=2 前置条件不成立;
// artistAliasTable 没这条;MusicBrainz 那两条路(中文别名 / 主名)实测都返回空。
// 于是三个**明明有这首歌**的源全部在闸门原地把正主拒掉,整首歌零候选——酷狗那条更是
// 已经排在搜索结果第 1 位、时长 119 与本地逐位吻合、还带 YRC 逐字。
//
// 为什么这不是把 netease pick() 当年刻意删掉的 byAlbum 兜底装回来:那条被删的理由是
// "专辑名字段能被仿冒号无成本抄成任意值"(见 netease.go:resolveNeteaseInfo 里 pick 的
// 注释)。这里多要两样仿冒号抄不动的东西——
//   - **时长**必须落在 1% 以内。专辑名是一个可以随手填的字符串,时长是音频本身的属性;
//   - 标题必须**逐字同名**,不接受 lyricTitleAccepted 的剥括号档/双语档(那两档本身就是
//     放宽,跟"歌手名不可信"叠加就是双重放宽)。
//
// 并且这条档位**只放行歌词候选,绝不放行身份/封面** —— 沿用 2026-08-22
// withholdImpersonatorRiddenIdentity 那次确立的分层:歌词按曲目挂在各家的歌词库上,跟
// "这条曲目记录是谁传的"是两回事;而歌词候选另有一整套跟来源无关的防线(标题闸 +
// 版本限定词 -600 + 时长 -700/-500 + 语言闸 + creditOnly 闸 + 跨源共识),错版本在打分层
// 就会掉下去。
//
// ⚠️ 绝不可用于 netease 的 pick() / nameOnlyMatch / qqCoverFallback —— 那三处判的是
// **身份**(封面给谁、canonical_artist 写谁、链接指向谁),在那里放宽等于直接采信仿冒号的
// 署名,正是当年删掉 byAlbum 兜底要防的东西。
//
// ⚠️ 也不参与打分:artist 从来不是 scoreLyricCandidateDetailed 的输入项(14 个 scoreTerm
// 里没有歌手项),所以放宽歌手闸不需要 lyricsScoringVersion +1。
func lyricRecordingTriangleMatches(candTitle, candAlbum string, candDurationSecs float64,
	localTitle, localAlbum string, localDurationSecs float64) bool {
	// ① 标题:逐字同名。
	nct, nlt := normLoose(candTitle), normLoose(localTitle)
	if nct == "" || nlt == "" || nct != nlt {
		return false
	}
	// ② 时长:两边都得有,且差在容差内。这是仿冒号抄不动的那一样,整条防线的主力。
	if candDurationSecs <= 0 || localDurationSecs <= 0 {
		return false
	}
	if math.Abs(candDurationSecs-localDurationSecs)/localDurationSecs > lyricRecordingTriangleDurationTolerance {
		return false
	}
	// ③ 专辑:本地没有专辑标签就无从判断"对不对版",一律不给这条档位(跟
	// preferAppleCoverOverNetease 里"本地没有专辑标签时这条例外一律不生效"同一个理由)。
	if strings.TrimSpace(candAlbum) == "" || strings.TrimSpace(localAlbum) == "" {
		return false
	}
	switch sc := albumScore(candAlbum, localAlbum); {
	case sc >= 200: // 归一后逐字相等,最强证据
	case sc >= 100: // 宽松包含 → 追加长度可比性要求
		// ⚠️ 必须**双向**比(2026-08-22 对抗性复核订正)。原来写的是
		// `nca < ratio*nla`,只约束了「本地 ⊇ 候选」那半边;一旦是「候选 ⊇ 本地」
		// (nca ≥ nla),判据恒真、一件东西都拦不掉 —— 而那半边恰恰是巡演/合辑/精选/Live
		// 专辑那一整类。实测:本地专辑 "Editorial"(9 rune)对候选
		// "one-man tour 2021-2022 -Editorial-@さいたまスーパーアリーナ"(62 rune)宽度比 6.9,
		// 老写法照过,于是三角档拒掉了对版的单曲行、选中了巡演 Live 专辑那一行。
		// 改成 min/max 之后两个方向同一把尺子。
		nca, nla := utf8.RuneCountInString(normLoose(candAlbum)), utf8.RuneCountInString(normLoose(localAlbum))
		lo, hi := min(nca, nla), max(nca, nla)
		if hi == 0 || float64(lo) < lyricRecordingTriangleAlbumWidthRatio*float64(hi) {
			return false
		}
	default: // 只有 albumTokens 重叠(<100)不够格
		return false
	}
	// ④ 版本限定词冲突(live/demo/remix 等)一律否决:这条档位专治"同一次录音、署名写法
	// 不同",不是拿来跨版本认亲的。
	return !versionTagsMismatch(localTitle, localAlbum, candTitle, candAlbum)
}

// featCreditSepRe 匹配歌手串里词级的 feat 类分隔("feat."/"feat"/"ft."/"ft"/
// "featuring",大小写不敏感,可带一个左括号)。只收这几个词:它们作为艺名成分几乎
// 不存在,而 "with"/"x" 都是真实艺名的常见组成部分(Sleeping With Sirens、Charli xcx),
// 收进来会把单一乐队名错砍成半截。⚠️ 这套词级切分**只用于生成检索变体**
// (lyricPrimaryQueryArtist),不并入 isArtistCreditSep——那份 rune 级分隔符集被
// artistMatches/防仿冒判定共用,动它会改变身份判定语义。
var featCreditSepRe = regexp.MustCompile(`(?i)\s*[(（]?\s*\b(?:feat\.|feat\b|ft\.|ft\b|featuring\b)`)

// lyricPrimaryQueryArtist 从多人合credit 的歌手串里取出首歌手,作为歌词检索的**查询
// 变体**(不是身份改写)。不是多人合credit(切不出第二段、也没有 feat 类分隔)时返回
// 空串,表示没有变体可言。返回值只该用来发检索请求和过各源的采纳闸,**绝不能**回写
// canonical_artist / 展示字段——把 "A & B" 缩窄成 "A" 正是 2026-07-10 那次回归
// (project_nowplaying_canonical_artist_multi_credit_regression)的形态。
//
// 为什么值得存在(2026-08-20 实测):LRCLIB 的 artist_name 是服务端结构化匹配,
// "UMI & 金泰亨" 直接 404,"UMI" 就能回 20 条;网易云对不同歌手串会选中不同版本的
// 条目。闸门层的坑由 lyricSourceArtistMatches 补,召回层的坑只能换检索词。
func lyricPrimaryQueryArtist(artist string) string {
	trimmed := strings.TrimSpace(artist)
	if trimmed == "" {
		return ""
	}
	base := trimmed
	if loc := featCreditSepRe.FindStringIndex(base); loc != nil {
		base = strings.TrimSpace(base[:loc[0]])
	}
	primary := strings.TrimSpace(firstCreditedArtist(base))
	// primary 为空(整串就是 "FT Island" 这类被 feat 词误伤的名字被砍空)或跟原串
	// 规整后没差别(本来就是单人)都算"没有变体",宁可不试也不发一个错的检索词。
	if primary == "" || normLoose(primary) == normLoose(trimmed) {
		return ""
	}
	return primary
}

// artistAliasTable 曾经是"已知英文/罗马化艺名 → 本库常用中文名"的手工对照表,2026-08-18
// 到 08-30 之间从 5 条批量扩到过 23 条(用户逐条核对 Last.fm Top100 导出坐实的同人异名)。
//
// ⚠️ 2026-08-31 缩到只剩下面六条真实残留案例。起因是用户当面质疑"怎么还在维护手工表,
// 不能通用处理吗"——逐条拿掉表、用通用机制(canonicalArtistViaMusicBrainz/
// cachedQQArtistCanonicalName,见 resolveGenericArtistCanonicalName 头注)重新查了一遍
// 原来 23 条,结果:
//   - 17 条通用机制能查到且结果正确,直接删表交给通用机制处理。
//   - 剩下这 6 条,两条通用机制(MusicBrainz + QQ)有的查不到/帮不上,有的更危险——
//     会**直接给出错误答案**(david tao 一度被 MusicBrainz 排到一个无关的德国音乐人
//     头上,不过那条本身返回空、QQ 能正常接手;真正会让 resolveGenericArtistCanonicalName
//     提前止步于错误答案的是 lexie liu 和 wanting,见各自条目注释)——只能继续手工登记,
//     而且这张表必须排在通用机制**前面**查,不能只当兜底:
var artistAliasTable = map[string]string{
	// 洪佩瑜是相对小众的歌手,MusicBrainz 搜不到、QQ 歌手搜索建议对"Pei-yu Hung"/
	// "Pei Yu Hung"这几种写法也都是空结果——不是查错,是两边索引都没有这个人。
	"pei-yu hung": "洪佩瑜",
	// 这条不是"罗马化→中文"问题,是同一个日本歌手两种**都合法**的汉字/片假名写法要折成
	// 项目里统一用的那个:QQ 的歌手搜索建议原样把"宇多田光"这四个字弹回来,不会主动
	// 帮忙换成"宇多田ヒカル"(项目里唱片/曲目标签实际用的写法)——这本来就不是"查一个
	// 不认识的名字",通用查询天然不适用。
	"宇多田光": "宇多田ヒカル",
	// ⚠️ 危险案例,不是"查不到"这么简单:QQ 歌手搜索建议对"Wanting"给出的第一条是
	// "婉婷"——查证过是**另一个人**(QQ 上一位跟"婉婷/杨炆"合唱的无关歌手),真正的
	// 曲婉婷反而是第二条。qqArtistCanonicalName 只信第一条建议(理由见其头注,躲另一个
	// 更危险的反例),所以这条必须靠手工表**在通用机制之前**拦下来,否则会把错误答案
	// 当成确定结果。
	"wanting": "曲婉婷",
	// "utada"/"hikaru utada" 这两种写法 MusicBrainz 的 canonicalArtistViaMusicBrainz 都
	// 查不到——country=JP,不在 chineseSpeakingCountries 白名单里(这道门槛是
	// 2026-08-05 那个 Michael Jackson 真实bug修的,不能为了这一个人放松,见
	// pickChineseAlias 头注)。musicBrainzArtistAliases(retryArtistIdentities 用的那条
	// 更宽松的查询)倒是查得到完整别名列表,但那份返回值没有 country/locale 信息,不能
	// 直接拿来当展示名用(会重新引入 Michael Jackson 那个bug,见
	// resolveGenericArtistCanonicalName 头注)。QQ 音乐这边,"Hikaru Utada"第一条建议是
	// "Utada"本身(不含汉字,查不到),"utada"独立查也是同样结果。两种写法都要手工登记。
	"utada":        "宇多田ヒカル",
	"hikaru utada": "宇多田ヒカル",
	// ⚠️ 危险案例,跟"wanting"同一类问题但**发生在更前面的一步**:
	// canonicalArtistViaMusicBrainz("Lexie Liu") 直接返回非空的"刘昱妤"——跟刘柏辛完全
	// 是两个人(MB 对这个查询词的身份识别本身查错了,不是置信度不够查不到)。
	// resolveGenericArtistCanonicalName 一旦 MusicBrainz 给出非空结果就直接采纳、不会
	// 再往下试 QQ(QQ 那边其实查得到正确的"刘柏辛Lexie"),所以这条也必须靠手工表在
	// MusicBrainz 之前拦下来。
	"lexie liu": "刘柏辛",
}

// hanOnlyPortion 从"英文名+中文名"拼接的混合标签(如"Gary 曹格")里,抽出连续汉字段里
// 最长的一段,当作这个人真正的中文名来试。
//
// 只在整串**同时含有拉丁字母和汉字**时才生效——纯中文的合唱串(比如"陶喆和盧廣仲")不
// 归这条管,那是"和/、/&这类连接词"问题,已经由 normalizeArtistCreditHanAnd 处理;这里
// 处理的是不同的问题:同一个人的名字被英文昵称/艺名和中文本名拼在一起,不是两个人被
// 连接词接在一起。取最长连续汉字段而不是"第一段"或"整串汉字"——万一将来遇到"英文A 中文B
// 英文C 中文D"这种更复杂的拼法,最长的那一段通常就是真正的本名(短的更可能是修饰词,
// 比如英文名本身音译出来的零星汉字)。长度需要 ≥2(复用 slashHeadPlausible 同一条
// "像不像名字"阈值)才认为是一个名字,单字(比如英文名恰好音译出一个汉字)不算数。
func hanOnlyPortion(s string) string {
	hasASCII, hasHan := false, false
	for _, r := range s {
		if isASCIILetter(r) {
			hasASCII = true
		}
		if unicode.Is(unicode.Han, r) {
			hasHan = true
		}
	}
	if !hasASCII || !hasHan {
		return ""
	}
	runes := []rune(s)
	bestStart, bestLen := -1, 0
	curStart, curLen := -1, 0
	flush := func() {
		if curLen > bestLen {
			bestStart, bestLen = curStart, curLen
		}
		curLen = 0
	}
	for i, r := range runes {
		if unicode.Is(unicode.Han, r) {
			if curLen == 0 {
				curStart = i
			}
			curLen++
		} else {
			flush()
		}
	}
	flush()
	if bestLen < 2 {
		return ""
	}
	return string(runes[bestStart : bestStart+bestLen])
}

// retryArtistIdentities 给出"第一轮没查到可用候选时,还值得换个名字再搜一遍"的歌手名,
// 按可信度排序、去重、不含原名。
//
// 2026-08-15 加。在此之前重试只认 artistAliasTable 那 5 条手工登记 —— 而
// canonicalArtistViaMusicBrainz 早就在为每个非中文歌手查 MusicBrainz 的中文名了,查到的
// 结果却只写进 CanonicalArtist 这个展示字段,**从不回喂检索**(全仓唯一调用点是
// enrich.go 里那一处赋值)。也就是说:我们手上明明有"这位歌手在中文曲库里叫什么",却还是
// 拿英文名去网易云/QQ 搜,搜不到就算了。
//
// ⚠️ 2026-08-30 起不再额外查 knownArtistAlias(artistAliasTable 那张手工表)。退休
// 理由:它在这里只是"方大同 ↔ Khalil Fong"这类问题的**单向**(英文 → 常用名)手工
// 补丁,而 musicBrainzArtistAliases(下面这条)双向通用、对任何歌手都生效(实测验证
// 过,不是推断),这张表在这条路径上纯属冗余。
//
// 2026-08-31 补充第三条(cachedQQArtistCanonicalName):MusicBrainz 两条路径合起来仍有
// 真实缺口——查不到(李荣浩/窦靖童等十余位)或者查错成另一个同名艺人(david tao 被排到
// 一个无关的德国音乐人头上、lexie liu 被认成"刘昱妤")。QQ 音乐自己的歌手搜索建议对
// "罗马化名字→中文艺人"这个场景本来就是量身做的,实测同一批人绝大多数都能查对,包括
// 上面两个 MusicBrainz 查错人的案例——加上它之后,artistAliasTable 这张手工表在
// canonical_artist 展示名解析链路(resolveTrackEnrichment)和 Top 歌手榜身份归并两处
// 也不再需要,已经改成统一走 resolveGenericArtistCanonicalName(musicbrainz.go),表
// 本身缩到只剩两条通用机制都覆盖不了的真实残留案例,见 artistAliasTable 头注。
//
// 退休/改用通用机制的代价:对这批歌手,重试第一次会比查表多打几次真实网络请求(以前是
// 零延迟查表)。musicBrainzArtistAliases/cachedQQArtistCanonicalName 各自按歌手持久化
// 缓存(mbPrimaryNameCache/qqArtistNameCache,查到即落盘、跨进程重启依然命中),所以
// 这个代价只在**每台机器第一次**真正撞上这位歌手时付一次,此后是零网络请求——包括
// "歌词管理"手动搜索这种每次都是全新进程的场景。
func retryArtistIdentities(ctx context.Context, artist string) []string {
	seen := map[string]bool{normLoose(artist): true} // 原名不必再搜一遍
	var out []string
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" {
			return
		}
		k := normLoose(s)
		if seen[k] {
			return
		}
		seen[k] = true
		out = append(out, s)
	}
	// 第零条(2026-08-31 加,纯本地字符串操作、不发网络请求,排最前面):"英文名+中文名"
	// 拼接的混合标签(如 Apple Music 常见的"Gary 曹格")——真实bug:曹格《Superman》专辑
	// "妳是我的寶貝",本地标签"Gary 曹格"八个源全部搜不到;单独查"曹格"四个源立刻命中,
	// 分数都在 1100+。这类标签是"一个人的英文名+中文名拼在一起",不是"和/、/&这类合唱
	// 连接词"(那些已经由 normalizeArtistCreditHanAnd 处理),歌词源通常只按纯中文名或
	// 纯英文艺名索引,两种都不认这种拼接写法。见 hanOnlyPortion 头注。
	add(hanOnlyPortion(artist))
	add(canonicalArtistViaMusicBrainz(ctx, artist))
	// 第二条(2026-08-20 加,2026-08-30 从"只给一个主名"扩成"给全部已登记写法"):
	// MB 上这位歌手的其它写法。第一条是"中文名"取向 —— 只在中文圈艺人身上出结果 ——
	// 而"本名 ↔ 艺名"(Abel Tesfaye ↔ The Weeknd)、"国际艺名 ↔ 中文常用名反过来查"
	// (方大同 ↔ Khalil Fong)跟中文与否无关,靠这条通用查询兜底,不需要事先手工登记——
	// 见 musicBrainzArtistAliases 头注,里面详细写了方大同这个真实案例踩过的坑(搜到的
	// "主名"字面上跟本地标签相同不代表没有别的候选)。
	for _, alt := range musicBrainzArtistAliases(ctx, artist) {
		add(alt)
	}
	// 第三条(2026-08-31 加):QQ 音乐自己的歌手搜索建议(cachedQQArtistCanonicalName,
	// 见其头注)——覆盖前两条 MusicBrainz 路径查不到、或者查错成另一个同名艺人的场景
	// (david tao/lexie liu 实测案例)。
	add(cachedQQArtistCanonicalName(artist))
	return out
}

// knownArtistAlias 只在 NetEase/QQ 都没能给出 canonical_artist 时,由
// resolveTrackEnrichment 作最后一道兜底调用——优先级低于跨服务实时核实的结果。
func knownArtistAlias(artist string) string {
	return artistAliasTable[strings.ToLower(strings.TrimSpace(artist))]
}

// neteaseImpersonatorRiddenArtists 是版权已从网易云整体下架、曲库里只剩仿冒号的艺人
// 名单：这类艺人任何"标题+专辑名精确匹配"的候选，先天就该是仿冒号——真人官方版本根本
// 不在库里，不存在"两者都对上但恰好不是官方"的中间地带。nameOnlyMatch()"歌手名字面
// 对不上也认"这条规则的前提是"信任跨服务强匹配大概率可信"，对这类艺人不成立,会直接
// 把仿冒号的署名当成核实过的官方名。只需要极少数确凿知名的名字,新的按实际踩坑追加即可。
var neteaseImpersonatorRiddenArtists = map[string]bool{
	"周杰伦": true,
	"周杰倫": true,
}

// isNeteaseImpersonatorRidden reports whether artist is a known "copyright
// pulled from NetEase entirely, catalog is 100% impersonators" case — see
// neteaseImpersonatorRiddenArtists 注释。
func isNeteaseImpersonatorRidden(artist string) bool {
	return neteaseImpersonatorRiddenArtists[strings.TrimSpace(artist)]
}

// toSimplified 把繁体字/词转成简体——用于统一搜索关键词/本地比较字符串的书写形式,不是
// 唯一权威判定(繁简本身不影响身份判定,查不到就原样返回,是安全默认)。
//
// 用 OpenCC 官方词库(单字+多字词组两级,见 t2s.go)而不是手工维护的单字对照表,是因为
// 后者覆盖面依赖"撞见一个字才补一个字"的被动积累,容易漏转导致搜索关键词转换等于没转换、
// 五个源全部搜不到候选。实现细节(词典解析/最长前缀匹配算法)见 t2s.go 顶部注释——那里
// 曾经是通过 github.com/liuzl/gocc 引入的,因为它间接依赖的 cedar-go 是 GPL-2.0-only、
// 跟本项目 GPLv3 许可证不兼容,换成了自带同一份 OpenCC 词典数据的零依赖实现。
func toSimplified(s string) string {
	return toSimplifiedT2S(s)
}

// albumStop are filler words ignored when comparing album names by shared tokens.
var albumStop = map[string]bool{
	"the": true, "a": true, "an": true, "and": true, "of": true, "in": true, "on": true,
	"at": true, "to": true, "for": true, "with": true, "book": true, "vol": true,
	"volume": true, "disc": true, "cd": true, "edition": true, "deluxe": true,
	"remastered": true, "part": true, "pt": true, "feat": true, "ft": true,
	"i": true, "ii": true, "iii": true, "iv": true,
}

// albumTokens 除了在非字母数字处断词,还在"数字↔字母"和"拉丁字母↔CJK"的交界处断词——
// 中文演唱会专辑名常见"2011Live"/"2020巡演"这种年份和后缀之间不留空格的写法,原来整段被
// strings.FieldsFunc 当成一个词,导致跟本地(通常是英文、年份和单词之间有空格)标签的
// "2011"+"live"两个独立词对不上、白白丢掉本该有的匹配分,容易在多个候选打平时选错。
// 拆开后能对上"2011"+"live"这两个独立词,分数明显领先,不再靠运气打平。
//
// 拉丁↔CJK 交界断词是 v9 加的(2026-09-01,周杰伦《The One 周杰伦演唱会》案):QQ 音乐把
// 这张专辑写成"The One演唱会"——One 和 演唱会 之间不留空格,unicode.IsLetter 对汉字为真,
// 原来整段粘成一个词元"one演唱会",跟本地标签的"one"+"周杰伦演唱会"零共享词、
// albumScore=0,同一张专辑被判成"毫无亲和"。中文平台的专辑名里拉丁词与中文后缀粘连是
// 常态,这个交界跟"2011Live"的数字↔字母交界是同一性质。⚠️ CJK **内部**仍不分词
// (汉字之间没有词边界信号,"周杰伦演唱会"照旧是一个词元),所以 cjkLiveAlbumMarkers
// 的子串匹配仍然必要,见那边注释。
func albumTokens(s string) map[string]bool {
	out := map[string]bool{}
	s = strings.ToLower(s)
	var cur []rune
	const (
		kindNone = iota
		kindDigit
		kindLatin
		kindCJK
	)
	prevKind := kindNone
	flush := func() {
		if len(cur) > 1 {
			t := string(cur)
			if !albumStop[t] {
				out[t] = true
			}
		}
		cur = cur[:0]
	}
	for _, r := range s {
		k := kindNone
		switch {
		case unicode.IsDigit(r):
			k = kindDigit
		case unicode.IsLetter(r):
			if isCJKRune(r) {
				k = kindCJK
			} else {
				k = kindLatin
			}
		}
		if k == kindNone {
			flush()
			prevKind = kindNone
			continue
		}
		if prevKind != kindNone && prevKind != k {
			flush()
		}
		cur = append(cur, r)
		prevKind = k
	}
	flush()
	return out
}

// isCJKRune:albumTokens 分词用的"这是不是 CJK 字符"。只收汉字和日文假名/韩文谚文这几个
// 明确"跟拉丁词粘连时必然是两个词"的文字系统,不试图穷举所有非拉丁文字——西里尔/希腊等
// 字母系统跟拉丁粘连的专辑名没实测见过,不做没有依据的推广。
func isCJKRune(r rune) bool {
	return unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) ||
		unicode.Is(unicode.Katakana, r) || unicode.Is(unicode.Hangul, r)
}

// albumScore rates how well candidate matches the target album. 100 = substring
// match; otherwise the count of shared significant tokens. Bridges cross-platform
// naming (e.g. "HIStory Continues" vs "HIStory: Past, Present and Future, Book I"
// share "history"). 0 = unrelated (compilations like "The Indispensable Collection").
func albumScore(candidate, target string) int {
	if candidate == "" || target == "" {
		return 0
	}
	// 完全相等(200)必须严格高于宽松包含(100):对短专辑名(如"1999")尤其关键——几乎
	// 任何同名重发/纪念版("1999 (Super Deluxe Edition)"等)都会被 looseContains 判定
	// 为"包含"、拿到 100 分,若跟真正的原版专辑同分,谁先出现在候选里就赢,原版反而可能
	// 被更晚出现的重发版顶替。
	nc, nt := normLoose(candidate), normLoose(target)
	if nc == nt {
		return 200
	}
	if strings.Contains(nc, nt) || strings.Contains(nt, nc) {
		return 100
	}
	ct, tt := albumTokens(candidate), albumTokens(target)
	n := 0
	for t := range tt {
		if ct[t] {
			n++
		}
	}
	return n
}

// stripParens removes (...) / [...] groups (and collapses spaces). Track titles
// carry noisy suffixes like "(with Akon)", "[feat. X]", "(Radio Edit)" that hurt
// NetEase search recall and exact-name matching; the bare title matches better.
func stripParens(s string) string {
	var b strings.Builder
	depth := 0
	for _, r := range s {
		switch r {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			if depth > 0 {
				depth--
			}
		default:
			if depth == 0 {
				b.WriteRune(r)
			}
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

// searchTitleVariants 返回「拿哪些曲名去各歌词源搜」的尝试序列。调用方按顺序试,先命中
// 先返回;标题本来就没括号(或整串都在括号里、剥完是空)时只有一条,不做无谓的重复请求。
//
// 顺序取决于**括号里装的是什么**,这是 2026-08-09 一整轮实测定下来的:
//
//	① 括号里是"另一次录音"的限定词(live/demo/original version/single version…,
//	   titleVersionTags 认的就是这些)→ **原样标题优先**。这类括号不是噪音、是身份的
//	   一部分:去掉它搜回来的是另一版录音,歌词字面可能一模一样,时间轴却是另一套。
//	   实测把裸标题无条件提前之后,"Billie Jean (Single Version)" 的酷狗候选从 806 分
//	   掉到 207(拿回普通版,被 versionMismatchPenalty 那 600 分打下去),
//	   "Blue Gangsta (Original Version)" 从 611 掉到 10。
//	② 其余(remaster/deluxe/feat./bonus/Taylor's Version… —— 同一次录音的不同发行,
//	   **故意不在** distinctRecordingVersionTags 里,见那边注释)→ **裸标题优先**。
//	   这一档才是收益来源,见下面两条实测。
//
// 另一种写法始终保留作**兜底**,只在前一条一无所获时才发第二次请求,所以两个方向的
// 收益都拿得到:
//   - 裸标题的必要性(四首歌逐源探测):QQ 音乐 smartbox 的 key 里只要带括号就**返回
//     0 条**,一条不回 —— 凡是本地标题带 "(Remastered 2014)"/"(Single Version)" 后缀
//     的歌,QQ 这一源整个失效,而且返回空跟"QQ 没收录"长得一模一样;酷狗则**返回 10 条
//     但全是该歌手的热门歌**、目标曲根本不在里面(搜 "宇多田ヒカル Automatic
//     (Remastered 2014)" 回的是 Come Back To Me / One Last Kiss / Beautiful World),
//     它不返回空,所以从外面完全看不出来搜砸了。
//   - 原样标题的必要性:LRCLIB 搜 "Automatic (Remastered 2014)" 直接回两条同名重制版,
//     搜 "Automatic" 回的 20 条全是普通版。
//
// ⚠️ 搜回来的候选照旧要过 lyricTitleAccepted 那一关,判定用的始终是**本地原样标题**。
// 放宽的只是"拿什么去搜",不是"什么算匹配" —— 换了搜索词不会让另一个版本混进来。
// ⚠️ 2026-08-17 起去装饰有**两种**形态(去括号 + 去结构性前缀,见
// stripStructuralTitlePrefix),不再只有去括号一种。两者都只是"拿什么去搜",判定照旧
// 走 lyricTitleAccepted。刻意**不**把两种去装饰叠起来再多加一个变体:那是没有实测依据的
// 推测,而每多一个变体就是每个源在"一无所获"那条路上多打一次请求 —— 按这个仓库一贯的
// 做法,等真踩到 "Medley: X (Remastered)" 这种形状再加。
func searchTitleVariants(title string) []string {
	// 去装饰的形态,去重、丢掉跟原样标题相同的。
	var stripped []string
	seen := map[string]bool{title: true}
	add := func(s string) {
		if s == "" || seen[s] {
			return
		}
		seen[s] = true
		stripped = append(stripped, s)
	}
	add(stripStructuralTitlePrefix(title))
	add(stripParens(title))

	if len(stripped) == 0 {
		return []string{title}
	}
	if len(titleVersionTags(title)) > 0 {
		return append([]string{title}, stripped...)
	}
	return append(stripped, title)
}

// structuralTitlePrefixes 是曲目名前面那种**结构性标签**:Apple Music 这类平台会给串烧/
// 间奏曲加上 "Medley: " / "Interlude: " 前缀,而歌词源的曲库里通常只有裸曲名。
//
// 2026-08-17 实测(用户报「这首歌找不到歌词」):D'Angelo 的 Voodoo 专辑里那首,Apple
// Music 报的标题是 "Medley: Greatdayndamornin' / Booty",而各源曲库里就叫
// "Greatdayndamornin'/Booty"。带前缀去搜 **五个源全部 0 条**;去掉前缀(歌手和专辑一个字
// 不动)**五个源全部命中**,最高分 1270。
//
// 白名单而不是"冒号前面一律砍掉":后者会把 "Foo: Bar" 这种本来就带冒号的正常曲名切掉半截,
// 跟另一首叫 "Bar" 的歌混为一谈。跟这个仓库里 distinctRecordingVersionTags /
// neteaseImpersonatorRiddenArtists 一个路子 —— 只收歧义极小的,新的按实际踩坑追加。
var structuralTitlePrefixes = []string{"medley", "interlude"}

// stripStructuralTitlePrefix 去掉 "Medley: " 这类结构性前缀,不认识的前缀原样返回。
// 要求冒号前面的那一段**整体**等于白名单里的词(所以 "Medleys: X" 不算),避免把正常
// 曲名切掉。
func stripStructuralTitlePrefix(title string) string {
	i := strings.Index(title, ":")
	if i <= 0 {
		return title
	}
	label := strings.ToLower(strings.TrimSpace(title[:i]))
	for _, p := range structuralTitlePrefixes {
		if label == p {
			return strings.TrimSpace(title[i+1:])
		}
	}
	return title
}

// titleMatches reports whether a NetEase result name refers to the same song as
// the played title, comparing both full and paren-stripped forms (so
// "Hold My Hand" matches "Hold My Hand (Duet with Akon)").
// distinctRecordingVersionTags 是"意味着这是另一次录音"的版本限定词——命中它们的候选,
// 歌词字面可能跟正式版一模一样,但时间轴是另一套,拿来对齐播放位置必然错。
//
// 故意**不**收 remaster/remastered/deluxe/bonus/explicit/clean/mono/stereo/anniversary
// 这一类:它们指的是同一次录音的不同发行/母带,时间轴基本一致,拿来用没问题,收进来只会
// 制造大量假不匹配(本地标签和各源标签在这类后缀上本来就经常不一致)。
//
// 也故意只收多词短语或歧义极小的单词:单独一个 "edit"/"mix"/"version"/"dub"/"club" 太
// 容易命中正常曲目名,所以只认 "radio edit"/"extended"/"club mix" 这类完整说法。
//
// ⚠️ 「club」这个裸词有一个**实测过的**反例,别手滑加进来:同一张专辑上的「Earth Song」,
// 本地标题就叫 "Earth Song"(Apple 没给它任何混音标记)、抽不出限定词,而正确候选是
// "Earth Song (Hani's club experience)"。收了裸「club」的话,正确的那条反而会被判成
// 「本地没标记 / 候选有标记」的版本不符,吃 -600 —— 把唯一对的答案打下去。
var distinctRecordingVersionTags = []string{
	"demo", "original version", "album version", "single version",
	"live", "unplugged", "acoustic", "instrumental", "karaoke",
	"remix", "extended", "radio edit", "alternate", "alternative version",
	"rehearsal", "reprise", "a cappella", "acapella",
	// 2026-08-22 补的「…mix」家族(用户报「Stranger in Moscow (Tee's In-House Club Mix)
	// 配了正常版的歌词」)。这些是舞曲混音的标准叫法,跟 remix 是一回事、只是不带 re-。
	// 词表漏掉它们的后果是**两处**、不是一处:titleVersionTags 抽不出限定词,于是
	// ①searchTitleVariants 走「裸标题优先」——酷狗第一条查询 "Michael Jackson Stranger
	// in Moscow" 拿回正常版、通过校验就 break,而**排在第 1 位的混音版原样条目从没被看到**;
	// ②versionTagsMismatch 判两边都是空集、-600 不触发,正常版稳稳留在榜首。
	"club mix", "radio mix", "house mix", "dub mix", "dance mix", "vocal mix", "club edit",
	// 2026-08-26 补中文版本限定词(实测坐实:「周杰伦 - 蜗牛 (伴奏)」查 lyricfind,YouTube
	// Music 召回的是正常演唱版,versionTagsMismatch 因为词表只认英文、判两边都是空集、
	// 该扣的 -600 没触发,伴奏版被当成正常版收了)。这个词表此前全是拉丁词,任何本地标签用
	// 中文标注"另一次录音"的场景对全部七个源一视同仁地失效——不是 lyricfind 专属,只是被
	// 它先撞上。只收歧义低、在标题括号/破折号位置里基本只作版本限定词讲的词(跟上面拉丁词
	// 一样的收词标准),不收"翻唱"/"改编版"这类含义太宽、容易连累正常标题的词。
	"现场", "不插电", "伴奏", "纯音乐", "清唱", "混音", "加长版", "阿卡贝拉", "排练",
	// 2026-08-27 补粤语/国语限定词:同名"(粵語)"/"(國語)"两版是真的两次不同录音
	// (跟 HanScript.swift 里 PlayCountVariants 对"(國)"/"(粵)"刻意不合并播放次数的
	// 判断同一个理由),此前词表完全没收,versionTagsMismatch 认不出这类标签、
	// 国语版歌词可能被错配给粤语音轨(反之亦然)。normLoose 内部先过 toSimplified
	// (见 normLoose 注释),繁体"粵語/國語"会被折成简体再比对,这里只需列简体。
	"粤语", "国语", "cantonese", "mandarin",
}

// djRemixTagPattern 认"DJ+任意名字+版"这个模式(阿若/阿树/阿罗/阿喜/糖糖/小阿龙/胧驿/
// 王小龙/凯西……这些都是不同 DJ 各自的艺名,列不完,不能像上面那样按固定字符串收进
// distinctRecordingVersionTags,只能按模式认)。
//
// 2026-08-31 加 kuwo 时全库扫描实测坐实:酷我上有多个 DJ 把周杰伦/王力宏/林俊杰/方大同/
// 孙燕姿等一大批歌手的热门曲目重新混音上传成"歌名 (DJ 阿若版)"这类命名,candidateArtist
// 字段仍然写的是原唱歌手名——扫描出的 125 首"命中"里有 94 首(75%)其实是靠这个漏洞才
// 顶着原唱名义混进候选列表,不是真的搜到了原版。
//
// ⚠️ DJ 名字不能只认中文:第一版用 [\p{Han}0-9.]*,实测漏了"稻香 (完整版|DJ Ray版)"
// ——"Ray"是拉丁字母,不在那个字符类里,导致这条候选完全没被认出带 DJ 标记,原样通过。
// 改用 \p{L}(任意 Unicode 字母,中文/拉丁/其它文字都算)才能不管 DJ 艺名用什么文字都认得出。
var djRemixTagPattern = regexp.MustCompile(`(?i)dj[\p{L}0-9.]*版`)

// djRemixVersionTag 是 titleVersionTags/segmentVersionTags 命中 djRemixTagPattern 时
// 写进版本限定词集合的规范化 key——双方各自认出同一个 key,versionTagsMismatch 的集合
// 比较才能生效(本地没有 DJ 标记、候选有,两边集合大小不等,判定不匹配)。
const djRemixVersionTag = "dj混音"

// titleVersionTags 抽出歌名里的版本限定词。**只在"限定词该出现的位置"里找**——括号/方括号
// 里的段落,以及最后一个 " - " 之后的段落。不能对整个歌名做子串匹配:那样 "Live and Let
// Die" 会被当成 live 版、"Demolition" 会命中 demo,全是假阳性。
func titleVersionTags(title string) map[string]bool {
	segs := parentheticalSegments(title)
	// "Song - Live at Wembley" 这种把限定词写在破折号后面的写法也认。用最后一个 " - ",
	// 因为歌名本身含破折号的情况下,限定词总在最右边那一段。
	if i := strings.LastIndex(title, " - "); i >= 0 {
		segs = append(segs, title[i+3:])
	}
	out := map[string]bool{}
	for _, seg := range segs {
		n := normLoose(seg)
		if n == "" {
			continue
		}
		for _, tag := range distinctRecordingVersionTags {
			if strings.Contains(n, normLoose(tag)) {
				out[tag] = true
			}
		}
		if djRemixTagPattern.MatchString(n) {
			out[djRemixVersionTag] = true
		}
	}
	return out
}

// parentheticalSegments 返回歌名里每一段括号内的内容(圆括号/方括号/花括号,支持嵌套时
// 取最外层整段)。跟 stripParens 是一对:那个丢掉括号内容,这个只要括号内容。
func parentheticalSegments(s string) []string {
	var out []string
	var cur strings.Builder
	depth := 0
	for _, r := range s {
		switch r {
		case '(', '[', '{':
			depth++
			if depth == 1 {
				cur.Reset()
				continue
			}
		case ')', ']', '}':
			if depth > 0 {
				depth--
				if depth == 0 {
					out = append(out, cur.String())
					continue
				}
			}
		}
		if depth > 0 {
			cur.WriteRune(r)
		}
	}
	// 括号没闭合(标签写得不规范)时把已经攒下的那段也算上,不白丢
	if depth > 0 && cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

// versionTagsMismatch 判断候选跟本地正在播的这首在版本限定词上是否对不上。
// 双向判定:本地是正式版而候选是 demo/live(会展示错版本的时间轴),以及本地是 demo 而候选
// 是正式版(同理),都算不匹配。
//
// **歌名和专辑名一起看**。2026-08-10 实测坐实这一点非做不可:PRINCE 的 "1999"
// (本地专辑 The Hits/The B-Sides)匹配到了 Musixmatch 的一条现场版,而那条候选的
// **歌名就是干净的 "1999"**,"Live" 藏在它的专辑名里
// ("Nude Tour, 1990 (Remastered, Live On Broadcasting)")——只看歌名的话这道闸门
// 一点反应都没有,那条现场版拿着 768 分(逐字 +400、时长 +283、行数 +85)稳居第一,
// 把专辑真正对得上的 LRCLIB 那条(368 分)压在下面。
//
// 两边都是"歌名 ∪ 专辑名"取并集再比,而不是歌名对歌名、专辑对专辑:限定词写在哪个字段
// 里各源习惯不同(本地写 "1999 (Live)"、某源写在专辑上),按字段分别比会把这种纯粹的
// 位置差异误判成版本不符。
//
// 候选的歌名和专辑名都为空(某些源不回报元数据)时一律判不匹配为 false —— 没有证据就
// 不扣分,不能因为源的元数据缺失就把它的歌词判死。
//
// v9 起限定词集合来自 recordingVersionTags(不再直接用 versionTagsIn):专辑名带中文
// 现场标记(演唱会/现场/音乐会)视同声明了 "live",双向对称——见 recordingVersionTags 注释。
func versionTagsMismatch(localTitle, localAlbum, candidateTitle, candidateAlbum string) bool {
	if strings.TrimSpace(candidateTitle) == "" && strings.TrimSpace(candidateAlbum) == "" {
		return false
	}
	local, cand := recordingVersionTags(localTitle, localAlbum), recordingVersionTags(candidateTitle, candidateAlbum)
	if len(local) != len(cand) {
		return true
	}
	for tag := range local {
		if !cand[tag] {
			return true
		}
	}
	return false
}

// versionTagsIn 把若干个字段(歌名/专辑名)里的版本限定词并成一个集合。
// 每个字段各自走 titleVersionTags 的"只在限定词该出现的位置里找"规则(括号段、最后一个
// " - " 之后),所以专辑名里不带括号的普通词不会被误当成限定词。
func versionTagsIn(fields ...string) map[string]bool {
	out := map[string]bool{}
	for _, f := range fields {
		for tag := range titleVersionTags(f) {
			out[tag] = true
		}
	}
	return out
}

// recordingVersionTags 是 versionTagsMismatch / sameRecordingDespiteVersionTags 两道闸
// 实际使用的"这一边声明了哪些版本限定词"集合:versionTagsIn(歌名+专辑名的括号段) 之外,
// v9 起再认一种形态——**专辑名带中文现场标记**(演唱会/现场/音乐会,子串匹配,见
// albumHasCJKLiveMarker)时补一个 "live"。
//
// 起因(2026-09-01,周杰伦《龙拳 (Live)》案):QQ 音乐给 The One 演唱会里的曲目起名就叫
// "龙拳"(不带任何括号),live 身份**只写在专辑名"The One演唱会"上**——而 titleVersionTags
// 只在括号段/" - "尾段里找限定词,这张专辑名没有括号,于是这条候选的限定词集合是空、
// 本地("龙拳 (Live)")是 {live},被判 -600。中文平台的现场专辑普遍用"XX演唱会"命名而
// 不加括号,这是系统性的命名形态差异,不是版本差异。
//
// **只认中文标记、刻意不认拉丁 "live" 词元**:albumHasLiveMarker 那张表里的拉丁词
// (live/concert/tour)在正常专辑名里就会出现(《Live and Let Die》《In Concert》是
// 录音室发行的合法名字),按词元认会把这类本地专辑打成 {live}、反过来对一切录音室候选
// 扣 -600;而"演唱会/现场/音乐会"在专辑名里几乎不做别的用途。跟 cjkLiveAlbumMarkers
// 选择只收无歧义词是同一个原则。
//
// **推导只看 stripParens 之后的专辑名**:括号里的中文常是描述性长文本而不是专辑身份——
// 全库回放抓到的真实误伤:韦礼安《女孩》的 lrclib 候选专辑名
// "女孩 (2015 韦礼安 《放开那女孩》 小巨蛋演唱会求爱主题曲/电视剧…) - single" 是张录音室
// single,"演唱会"只出现在括号里的介绍文案里。括号里若真写了版本声明(如 "(Live)"),
// versionTagsIn 的限定词表本来就管,不需要这层推导。
func recordingVersionTags(title, album string) map[string]bool {
	out := versionTagsIn(title, album)
	if !out["live"] && albumHasCJKLiveMarker(stripParens(album)) {
		out["live"] = true
	}
	return out
}

// versionMismatchPenalty 要足够大到"永远压不过标题吻合的候选":时长项最高 1000、逐字项
// 400,600 分足以让原本领先几十分的错版本候选彻底掉到最后。扣完不让它变成负分(负分会被
// pickLyricCandidate 直接丢弃),而是留 1 分—— 实在只有这一个候选时,有总比没有好。
const versionMismatchPenalty = 600

// sameRecordingExtraTagWhitelist:候选比本地**多出**的版本限定词里,哪些描述的是
// "同一场演出怎么演的"而不是"另一次录音"。只收 acoustic 家族:一场演唱会的钢琴/不插电
// 演绎,源平台可能标注"(Acoustic Piano)"而 Apple 曲名不标,这是**命名差异**;而
// 伴奏/instrumental/粤语/国语/demo/remix 这些词,即便时长逐位吻合也是**另一次录音**
// (伴奏版时长常与原曲完全相同;粤语/国语两版同一伴奏、时长几乎一样 —— 恰恰是
// versionTagsMismatch 存在的理由),永不豁免。
var sameRecordingExtraTagWhitelist = map[string]bool{
	"acoustic": true, "unplugged": true, "不插电": true,
}

// sameRecordingDespiteVersionTags 判定"版本限定词对不上,但其余证据坐实这就是同一次
// 录音"。第 14 条三角判据(标题+专辑+时长 ≤1%)的推广:那次只挂在 kugou 的歌手闸上,
// 这里回答的是它的姊妹问题 —— 限定词的**命名不对称**(源平台标了演奏方式、本地曲名没标)
// 该不该当版本差异罚 -600。
//
// 起因(2026-09-01,用户报「陈奕迅《孤独探戈 (Live)》匹配错了」):本地专辑
// 《The Easy Ride 演唱会 (Live)》,网易云库里**有**正确版本
// 「孤独探戈(Acoustic Piano)(Live)」(专辑 The Easy Ride Live 陈奕迅演唱会,自报时长
// 215.4s 与本地 215.373s 逐位吻合 —— 同一次录音的铁证),但它比本地曲名多一节
// "(Acoustic Piano)",versionTagsMismatch 判两边限定词集合不等、-600 —— 即便召回也
// 打不过错场次/录音室版的候选。这场演出本来就是钢琴伴奏演绎,"acoustic"描述的是
// **这场演出本身**,不是另一个版本;Apple 只是没把这层写进曲名。
//
// 四道门全过才豁免:①双方都自报了时长且相差 ≤1%(与第 14 条同一档 —— 比打分层那个
// 25% 严 25 倍,同一次录音跨平台只差在取整);②专辑有亲和(albumScore ≥1,两边都非空);
// ③候选**不缺**本地已有的任何限定词(本地标 Live 候选没标 → 时长再吻合也可能是录音室版,
// 不豁免);④候选**多出**的限定词全部在 sameRecordingExtraTagWhitelist 里(见上)。
func sameRecordingDespiteVersionTags(
	localTitle, localAlbum string, localDurationSecs float64,
	candTitle, candAlbum string, candDurationSecs float64,
) bool {
	if localDurationSecs <= 0 || candDurationSecs <= 0 {
		return false
	}
	larger := math.Max(localDurationSecs, candDurationSecs)
	if math.Abs(localDurationSecs-candDurationSecs)/larger > 0.01 {
		return false
	}
	if albumScore(candAlbum, localAlbum) < 1 {
		return false
	}
	// 第③门的 local 侧刻意用**括号级**集合(versionTagsIn),不含 v9 的专辑推导 live:
	// 真正写在本地曲名/专辑括号里的声明,候选必须有;而本地靠专辑名"演唱会"字样推导出的
	// live,候选的**截短拼法**推导不出来是拼法问题不是版本声明——全库回放的真实误伤:
	// 蔡健雅《依赖》本地专辑《My Space 演唱會紀念盤》,kugou/QQ 把同一张写成"My Space"
	// (自报时长 179 vs 本地 179.52 逐位吻合、专辑 substring 亲和),若苛求候选也推导出
	// live,这批同场对版全数吃 -600。第①②门(时长≤1% + 专辑亲和)已经把"这就是同一张"
	// 钉住了。第④门的两侧仍用完整集合(recordingVersionTags):候选**多出**的 live 推导
	// (录音室本地 vs "XX演唱会"合集候选)不在白名单里,照样不豁免——那一类里混着真现场版,
	// 时长吻合不足以为它作保(见 docs/features/09 第 34 条周大侠案的记录)。
	localParen := versionTagsIn(localTitle, localAlbum)
	local := recordingVersionTags(localTitle, localAlbum)
	cand := recordingVersionTags(candTitle, candAlbum)
	for tag := range localParen {
		if !cand[tag] {
			return false
		}
	}
	for tag := range cand {
		if !local[tag] && !sameRecordingExtraTagWhitelist[tag] {
			return false
		}
	}
	return true
}

// liveAlbumConflictPenalty:liveAlbumIdentityConflict 命中时扣多少。取跟 versionTags
// 同一档的 600——它们是同一性质的证据(「这份歌词挂在另一次录音上」),只是抓的形态不同:
// versionTagsMismatch 抓「一边 Live 一边录音室」,这条抓「两边都是 Live、但是两场不同的
// 演出」。600 也是实测出的必要量级:陈奕迅《Shall We Dance (Live)》案冠亚分差 419
// (逐字 +400 是大头)、《活着多好 (Live)》案 53(时长吻合差),要一档能同时压过这两种
// 组合的扣分,和 versionTags 对齐是最不引入新数字的选择。
const liveAlbumConflictPenalty = 600

// liveAlbumMarkerTokens / cjkLiveAlbumMarkers:专辑名里「说明这是现场录音」的通用词。
// 它们只描述录音形态,不携带「是哪场演出」的身份信息,所以在 liveAlbumIdentityConflict
// 里两用:①判定一张专辑是不是现场专辑(gate);②从身份词集合里剔除(两张现场专辑共享一个
// "live"/"演唱会"不构成任何同一性证据——陈奕迅《Get A Life (Live)》跟《The Easy Ride
// 演唱会 (Live)》唯一的共享词元就是"live")。
var liveAlbumMarkerTokens = map[string]bool{
	"live": true, "concert": true, "tour": true,
	"现场": true, "演唱会": true, "音乐会": true, "演出": true, "巡演": true, "巡回": true,
}

// cjkLiveAlbumMarkers 是上面那张表里需要按**子串**匹配的中文词:albumTokens 对 CJK
// **内部**不分词(汉字之间没有词边界信号,"录音棚现场"/"周杰伦演唱会"整段是一个词元),
// 粘连词元里的标记词只能靠子串认。(v9 起拉丁↔CJK 交界会分词,"Timeless演唱会"这类
// 混排粘连已经能拆出独立的"演唱会"词元,但纯中文粘连仍然只有子串一条路。)拉丁词
// **不做**子串匹配——"Alive"/"Deliver" 含 "live",子串判会把录音室专辑误判成现场专辑。
var cjkLiveAlbumMarkers = []string{"现场", "演唱会", "音乐会"}

// albumHasLiveMarker:这个专辑名自己是否声明了「我是现场录音」。
func albumHasLiveMarker(album string) bool {
	for t := range albumTokens(toSimplified(album)) {
		if liveAlbumMarkerTokens[t] {
			return true
		}
	}
	return albumHasCJKLiveMarker(album)
}

// albumHasCJKLiveMarker:专辑名是否带**中文**现场标记(演唱会/现场/音乐会,子串匹配)。
// 从 albumHasLiveMarker 里拆出来单独成名,是因为 recordingVersionTags 只认这一半——
// 拉丁 live/concert/tour 词元对"这是现场录音"的把握不够(见 recordingVersionTags 注释),
// 而 liveAlbumIdentityConflict 的 gate 用整个 albumHasLiveMarker(那边有另外三道门兜着,
// 宽一点安全)。
func albumHasCJKLiveMarker(album string) bool {
	for t := range albumTokens(toSimplified(album)) {
		for _, m := range cjkLiveAlbumMarkers {
			if strings.Contains(t, m) {
				return true
			}
		}
	}
	return false
}

// albumIdentityTokens:专辑名的**身份词**集合——剥掉歌手名(防「周杰伦地表最强世界巡回
// 演唱会」vs「地表最强世界巡回演唱会」这种同一场演出只差歌手名前缀粘连的假冲突;歌手名
// 出现在自己任何一张专辑名里都不携带区分信息)、再剔除 live/演唱会类通用词之后剩下的词元。
func albumIdentityTokens(artist, album string) map[string]bool {
	a := strings.ToLower(toSimplified(album))
	if ar := strings.ToLower(strings.TrimSpace(toSimplified(artist))); ar != "" {
		a = strings.ReplaceAll(a, ar, " ")
	}
	out := map[string]bool{}
	for t := range albumTokens(a) {
		if !liveAlbumMarkerTokens[t] {
			out[t] = true
		}
	}
	return out
}

// liveAlbumIdentityConflict 判定「本地和候选是两场**不同命名的演出**」——versionTagsMismatch
// 够不到的一类:两边都带 live 标记时限定词集合相等,那道闸静默,而同一个艺人的多场演唱会
// 都收录同一首歌的现场版是华语歌手的常态(陈奕迅《Shall We Dance》至少上过 The Easy Ride
// 和 Get A Life 两场的专辑),错配的后果和错配录音室版一样:时间轴是另一场演出的。
//
// 这**不违反**「专辑对不上是零证据」的既有原则(albumScore 只加不减、v3 起就写明中英互译
// 专辑名/single 发行/精选集都是合法的"对不上")——那条原则针对的是「字符串没对上=没有信息」,
// 而这里要求的是**双方都做出了明确的身份声明且声明互相矛盾**,四道门缺一不可:
//
//	① 本地**专辑名自己**带 live 标记(不能只靠歌名括号里的 Live):录音室专辑的专辑名对
//	   「是哪场演出」没有发言权——Queen《The Game (Deluxe Edition)》的 bonus 现场曲配上
//	   《Queen Rock Montreal》是**同一场**蒙特利尔演出,全库回放坐实这一档必须挡(3 条
//	   Queen 假阳性全靠这道门排除);
//	② 候选也是现场录音(歌名/专辑名带 live/现场,或专辑名带标记词元):候选是录音室版时
//	   归 versionTagsMismatch 管,两道闸恰好互补、不重叠;
//	③ 两边专辑名剥掉歌手名和 live 类通用词后**各自还有身份词**(全是通用词的一边等于没有
//	   做身份声明,构不成矛盾);
//	④ 两个身份词集合**完全不相交**(共享哪怕一个词元——年份、场馆、巡演名——都当同一场
//	   演出的不同写法放过:方大同《15 (Live in Hong Kong 2011)》vs 网易云《15 香港演唱会
//	   (2011Live)》共享 "15"/"2011",是同一场的中英命名,全库回放里这类真实配对全部安全)。
//
// 全库 2339 条真实决策回放(2026-09-01):命中 29 个候选、涉及 24 首歌,逐条人工核对
// 全部是真的另一场演出,0 误伤;冠军改变 8 首全部改对。判据对事不对源——网易云自己
// 匹配错场次时(《孤独探戈》它给的也是 Get A Life)同样被扣。
func liveAlbumIdentityConflict(localArtist, localAlbum, candTitle, candAlbum string) bool {
	if strings.TrimSpace(localAlbum) == "" || strings.TrimSpace(candAlbum) == "" {
		return false
	}
	if !albumHasLiveMarker(localAlbum) {
		return false
	}
	candTags := versionTagsIn(candTitle, candAlbum)
	if !candTags["live"] && !candTags["现场"] && !albumHasLiveMarker(candAlbum) {
		return false
	}
	lt := albumIdentityTokens(localArtist, localAlbum)
	ct := albumIdentityTokens(localArtist, candAlbum)
	if len(lt) == 0 || len(ct) == 0 {
		return false
	}
	for t := range ct {
		if lt[t] {
			return false
		}
	}
	return true
}

// lyricTitleAccepted 是**七个源共用**的唯一一条「这条候选的曲名算不算这首歌」判定。
// 只认三种:
//
//	① 归一化后完全相等;
//	② 双方各自去掉括号段之后相等 —— 歌词源的曲名常常没有本地那串 "(Remastered 2014)"/
//	   "(feat. X)" 后缀,不给这条退路的话很多歌一条候选都匹配不到;
//	③ 双语标题:一边是另一边的前缀,共同前缀含汉字、多出的尾巴全是拉丁字母 ——
//	   QQ/酷狗给中文歌普遍缀英文别名("起源" vs "起源 Origin",2026-08-11 实测这首歌
//	   两个源都因此被拦,五源只剩两条候选)。见 bilingualTitleEqual。
//
// **绝不认任意的双向子串包含**。那是 2026-08-09 之前 kugou/QQ/Musixmatch/netease 的
// 做法,是个定时炸弹:"Real Love" 本来就是 "Real Love Baby" 的子串,查 "love" 能命中
// 同歌手的 "Real Love",时长又常在容差内,于是把另一首歌的歌词当成这一首。lrclib 早就
// 因为这个单独收紧过(见 lrclib.go 里那段注释),现在统一到这里。
//
// 收紧的代价实测为**零**:250 首全量候选数据里,「旧规则(子串)认、新规则不认」的候选
// 一条都没有 —— 那个分支从来没有真正起过作用,只是在攒风险。
//
// ⚠️ 这只管"接不接受这个候选",不管"拿什么去搜"(那是 searchTitleVariants 的事)。
// 判定对象**始终是本地原样标题**,跟这条候选是用哪个搜索词搜到的无关。
//
// 真正的"版本差异"(live/demo/original version 这类另一次录音)不在这里拦,由
// versionTagsMismatch + versionMismatchPenalty 单独负责 —— 那一层按"是不是另一次录音"
// 判,比"括号里的字对不对得上"准得多。
//
// 历史:这里曾经有一个「歌名匹配:忽略括号/严格」的用户设置。2026-08-09 实测后删除
//
//	——严格档让 18% 的歌完全拿不到歌词、可用源数从 3.78 腰斩到 1.98,而用独立于打分的
//	时长吻合度做代理,29 首胜出者不同的歌里"忽略档更贴 7 / 严格档更贴 4 / 打平 18",
//	噪声级别、测不出质量收益。它承诺的保护本来就由上面说的版本限定词那一层提供。
func lyricTitleAccepted(candidateTitle, localTitle string) bool {
	nc, nl := normLoose(candidateTitle), normLoose(localTitle)
	if nc == "" || nl == "" {
		return false
	}
	if nc == nl {
		return true
	}
	sc, sl := normLoose(stripParens(candidateTitle)), normLoose(stripParens(localTitle))
	if sc != "" && sl != "" && sc == sl {
		return true
	}
	// ④ 结构性前缀:本地标签给串烧/间奏曲加了 "Medley: " 这类前缀,歌词源曲库里是裸曲名
	// (见 stripStructuralTitlePrefix 的实测记录)。
	//
	// ⚠️ 这一条**没有**违反上面那句"绝不认任意的双向子串包含":去掉一个白名单里的结构性
	// 前缀之后做的仍然是**相等**判定,不是包含。"Real Love" 依旧不会命中 "Real Love Baby"
	// —— 那两个串谁都没有这种前缀,砍不掉任何东西,相等判定照旧不成立。
	fc := normLoose(stripStructuralTitlePrefix(stripParens(candidateTitle)))
	fl := normLoose(stripStructuralTitlePrefix(stripParens(localTitle)))
	if fc != "" && fl != "" && fc == fl {
		return true
	}
	// ③ 双语标题(去括号后的形态上比,让「起源 Origin (Live)」这类叠加形态也能走到这里;
	// live 之类的版本差异照旧由 versionTagsMismatch 那一层单独处理)
	return bilingualTitleEqual(sc, sl) || bilingualTitleEqual(nc, nl)
}

// ---- v3 打分维度的支撑 helper(2026-08-12) ----

// lrcMetaTagPrefixRe 认 `[ti:`/`[ar:`/`[al:`/`[by:`/`[offset:`/`[kana:` 这类字母键的 LRC 标签
// 行开头;时间戳 `[00:01.00]` 是数字开头,不会命中。
var lrcMetaTagPrefixRe = regexp.MustCompile(`^\[[A-Za-z_]+:`)

// isLRCMetaTagLine 判一行是不是整行都是 LRC 元数据标签(`[键:值]`,无时间戳)。只在整行以
// `]` 收尾时才算,避免把"[kana:…]"之外任何带正文的行误判掉。
func isLRCMetaTagLine(line string) bool {
	trimmed := strings.TrimSpace(line)
	return strings.HasSuffix(trimmed, "]") && lrcMetaTagPrefixRe.MatchString(trimmed)
}

// lyricConsensusBody 把一份 LRC 归一成"可跨源比对的正文":逐行去时间戳、丢署名行、
// 元数据标签行与空行,每行 normLoose 后拼接。给 contentConsensusPeers 的 3-gram 比对用。
func lyricConsensusBody(lyrics string) string {
	// 演唱者标签行留下(2026-08-23,见 lyricspeaker.go),但只留**冒号后的正文** ——
	// 跨源比对要的是"唱了什么",标签本身是这一份的格式细节,别的源没有它。
	// 不这么做的话:《好好说再见》53 行里 40 行「男：/女：」被整行摘掉,剩 13 行去跟
	// 网易云那份完整的 53 行比 3-gram,相似度垫底、拿不到 150~250 分的共识分,而冠亚军
	// 分差中位只有 22 分 —— 于是带对唱标注的那一版在选源时被系统性淘汰。
	speakers := lyricSpeakerLabels(lyrics)
	var b strings.Builder
	for _, line := range splitLyricLines(lyrics) {
		// v11:`[kana:…]`/`[ti:…]`/`[offset:…]` 这类无时间戳的元数据标签行不是"唱了什么",
		// 跳过。起因见 lyricsScoringVersion 的 v11 注释:QQ 的假名标注行(1700+ 字符的假名)
		// 一进整行歌词就把《Lemon》QQ 候选的 3-gram 相似度拖到阈值以下、丢了 250 分共识。
		if isLRCMetaTagLine(line) {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		if label, rest, ok := lyricSplitLabel(text); ok && speakers[label] {
			// 独占一行的标记(rest 为空)对正文没有贡献,跳过。
			if rest != "" {
				b.WriteString(normLoose(rest))
			}
			continue
		}
		if isCreditLine(text) {
			continue
		}
		b.WriteString(normLoose(text))
	}
	return b.String()
}

// lyricGram3Set 返回字符 3-gram 集合。用 3-gram 而不是行集合:对各源的行切分差异鲁棒
// (同一句被切成一行还是两行不影响字符层面的重叠)。
func lyricGram3Set(s string) map[string]struct{} {
	rs := []rune(s)
	out := make(map[string]struct{}, len(rs))
	for i := 0; i+3 <= len(rs); i++ {
		out[string(rs[i:i+3])] = struct{}{}
	}
	return out
}

func gramJaccard(a, b map[string]struct{}) float64 {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	small, big := a, b
	if len(small) > len(big) {
		small, big = big, small
	}
	inter := 0
	for g := range small {
		if _, ok := big[g]; ok {
			inter++
		}
	}
	union := len(a) + len(b) - inter
	if union == 0 {
		return 0
	}
	return float64(inter) / float64(union)
}

// 跨源正文共识的参数。0.55:同一份真实歌词跨源转写(标点/空行/繁简差异)的相似度
// 通常 >0.7,串了版本/曲目的通常 <0.3,0.55 居中带余量。30 字符下限挡"正文短到
// 什么都能撞上"的退化比对。
const (
	lyricConsensusSimThreshold = 0.55
	lyricConsensusMinBodyRunes = 30
)

// contentConsensusPeers 对整批候选统一计算"每个源的正文被几个**其它源**印证"。
// 打分侧按 peers>=2 → +250 / ==1 → +150 给分。
//
// 防搜歪共伴闸(与 corroboratedEndings 同一课题、同一哲学):durationSecs>0 且批内
// 存在时长吻合的候选时,自身时长不吻合的候选**领不到**共识分(它可以继续为别人作证,
// 但自己不领)——QQ 和酷狗一起被同一个搜索词带到同一个错版本上时,它们的正文当然一致,
// "一致"在这种局面下不是独立证据;而那条时长吻合的候选的存在,直接证伪了"这首歌的
// 歌词本来就长这样"。
//
// 参与比对的候选先过与打分同款的基本校验(时间戳密度/语言/纯署名),正文归一后不足
// lyricConsensusMinBodyRunes 字符的不参与(既不领分也不为别人作证)。
func contentConsensusPeers(localArtist, localTitle string, candidates []lyricCandidate, durationSecs float64) map[string]int {
	if len(candidates) < 2 {
		return map[string]int{} // 一条候选无从互证,省掉整批 3-gram 构建
	}
	type member struct {
		source  string
		grams   map[string]struct{}
		last    float64
		hasLast bool
	}
	members := make([]member, 0, len(candidates))
	// anyFits 在**全量**候选上统计,跟 corroboratedEndings 保持同一口径:一条"时长吻合
	// 但会被打分 reject"的候选,照样证伪了"这首歌的歌词本来就早早结束",两套互证机制
	// 不该对同一批输入一个开闸一个关闸(2026-08-12 审阅)。
	anyFits := false
	for _, c := range candidates {
		if durationSecs > 0 {
			if last, ok := lastLRCTimestampSecs(c.lyrics); ok && durationFits(last, durationSecs) {
				anyFits = true
			}
		}
	}
	for _, c := range candidates {
		// ⚠️ 2026-08-30 真实bug修复的一部分:这里**不再**把 isProbablyWrongLanguageLyrics
		// 也算进排除条件——那样会跟 scoreLyricCandidateDetailed 新增的
		// "consensusPeers>=1 时豁免语言闸"互相咬死:如果判定语言不对就先被排除出统计,
		// 永远不可能有 consensusPeers>=1,豁免条件永远打不开(见那边的头注,Gareth.T
		// 《before you》= 网易云/QQ/酷狗/LRCLIB 一致收录的《遇上你之前的我》案)。这里要
		// 回答的问题是"内容跟别的源像不像",跟"歌手标签用什么文字"是两件事——继续保留
		// isTimedLRC/isCreditOnlyLRC 这两条(没时间戳/只有职员表的内容本来就没法参与
		// 有意义的 3-gram 比对,这两条不构成循环依赖)。
		if !isTimedLRC(c.lyrics) || isCreditOnlyLRC(c.lyrics) {
			continue
		}
		last, hasLast := lastLRCTimestampSecs(c.lyrics)
		var grams map[string]struct{}
		if body := lyricConsensusBody(c.lyrics); len([]rune(body)) >= lyricConsensusMinBodyRunes {
			grams = lyricGram3Set(body)
		}
		members = append(members, member{c.source, grams, last, hasLast})
	}
	peers := map[string]int{}
	for i := range members {
		if members[i].grams == nil {
			continue
		}
		n := 0
		for j := range members {
			if i == j || members[j].source == members[i].source || members[j].grams == nil {
				continue
			}
			if gramJaccard(members[i].grams, members[j].grams) >= lyricConsensusSimThreshold {
				n++
			}
		}
		peers[members[i].source] = n
	}
	if durationSecs > 0 {
		for i := range members {
			if !members[i].hasLast {
				continue
			}
			fits := durationFits(members[i].last, durationSecs)
			// ① 批内有人时长吻合时,自身不吻合的候选领不到共识分(防搜歪共伴,见上面注释)。
			// ② overshoot 的候选**任何情况下**都领不到:v3 认定"歌词比歌曲还长"是物理
			//    矛盾,那一档刻意不吃跨源印证豁免(见 scoreTermDurationOvershoot 处的注释);
			//    而两个源被同一个搜索词一起带到同一个错的完整版时,恰恰是全员 overshoot、
			//    没人 fits、①闸不触发的局面——正是印证机制该收手的地方(2026-08-12 审阅)。
			if (anyFits && !fits) || members[i].last > durationSecs+lyricOvershootToleranceSecs {
				peers[members[i].source] = 0
			}
		}
	}
	return peers
}

// titleMatchTierPoints 把标题吻合从布尔门升级成梯度分:精确同名 +120 > 仅括号差异 +60
// > 中英双语同名 +30 > 对不上 0(0 不是惩罚——"验的标题≠取的歌词"的标的漂移形态未在
// 样本坐实前,负档是死代码兼潜在误伤源,见 2026-08-12 评测目录的裁剪记录)。
// 括号里没有版本词(纯噪音括号,如 feat. 名单)时升回精确档——只看**括号段**,不能用
// titleVersionTags(它连 dash 尾段一起抽,两侧 dash 尾段带相同版本词时会把本该精确的
// 压在括号档)。
func titleMatchTierPoints(candidateTitle, localTitle string) int {
	nct, nlt := normLoose(candidateTitle), normLoose(localTitle)
	if nct == "" || nlt == "" {
		return 0
	}
	if nct == nlt {
		return 120
	}
	sc, sl := normLoose(stripParens(candidateTitle)), normLoose(stripParens(localTitle))
	if sc != "" && sl != "" && sc == sl {
		if len(parenOnlyVersionTags(candidateTitle)) == 0 && len(parenOnlyVersionTags(localTitle)) == 0 {
			return 120
		}
		return 60
	}
	if bilingualTitleEqual(sc, sl) || bilingualTitleEqual(nct, nlt) {
		return 30
	}
	return 0
}

// parenOnlyVersionTags 只从括号段抽版本限定词(不含 titleVersionTags 的 dash 尾段扩展),
// 语义区别见 titleMatchTierPoints 注释。
func parenOnlyVersionTags(title string) map[string]bool {
	out := map[string]bool{}
	for _, seg := range parentheticalSegments(title) {
		for tag := range segmentVersionTags(seg) {
			out[tag] = true
		}
	}
	return out
}

// segmentVersionTags 在一个段落里找版本限定词,按**词**匹配而不是子串匹配。
//
// 子串匹配在这里是实打实的坑:normLoose 会把空格标点全挤掉,"feat. Oliver Tree" 变成
// "featolivertree" —— 里面凭空出现 "live";"feat. Demons" → "featdemons" 命中 "demo"
// (2026-08-12 审阅实测)。而 feat. 名单恰恰是 titleMatchTierPoints 最该判成"纯噪音括号、
// 升回精确档"的形态,子串匹配把这个升档逻辑对着它自己的主场用例关掉了。
// distinctRecordingVersionTags 里的拉丁词按非字母数字切词后比对连续词序列即可。
//
// 2026-08-26 加中文限定词后,上面这套"切词比对"对它们不成立——中文没有空格分词,
// "伴奏版"整段会被切成**一个**词元(伴/奏/版都是 unicode.IsLetter),永远不会等于
// 词表里裸的"伴奏",词序列比对对中文限定词恒假阴性。中文场景不存在"feat. Oliver Tree"
// 那类去空格后偶然拼出别的词的坑(那是拉丁词专属——中文词本来就没有词间空格可去),
// 所以中文限定词退回子串匹配是安全的,做法上跟 titleVersionTags 完全一致。按 tag 是否
// 含非 ASCII 字符分流,拉丁词的词序列算法原样不动。
func segmentVersionTags(seg string) map[string]bool {
	toks := strings.FieldsFunc(strings.ToLower(seg), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	joined := strings.Join(toks, "")
	out := map[string]bool{}
	for _, tag := range distinctRecordingVersionTags {
		if !isASCIITag(tag) {
			if strings.Contains(joined, tag) {
				out[tag] = true
			}
			continue
		}
		tagToks := strings.Fields(tag)
		for i := 0; i+len(tagToks) <= len(toks); i++ {
			match := true
			for j, tt := range tagToks {
				if toks[i+j] != tt {
					match = false
					break
				}
			}
			if match {
				out[tag] = true
				break
			}
		}
	}
	if djRemixTagPattern.MatchString(joined) {
		out[djRemixVersionTag] = true
	}
	return out
}

// isASCIITag 判断一个版本限定词是不是纯 ASCII(拉丁词表 vs 2026-08-26 加的中文词表,
// segmentVersionTags 两套算法的分流依据)。
func isASCIITag(tag string) bool {
	for _, r := range tag {
		if r > unicode.MaxASCII {
			return false
		}
	}
	return true
}

// timedNonEmptyLRCLines:带时间戳且去戳后非空的行数(译文覆盖率判定用)。
func timedNonEmptyLRCLines(lrc string) int {
	n := 0
	for _, line := range strings.Split(lrc, "\n") {
		if !lrcTimestampRe.MatchString(line) {
			continue
		}
		if strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, "")) != "" {
			n++
		}
	}
	return n
}

// kanaRatio:去戳正文中平/片假名字符占非空白字符的比例。判"这首歌是日文形态"用
// (罗马音只对日文歌词有增值)。
func kanaRatio(s string) float64 {
	stripped := lrcTimestampRe.ReplaceAllString(s, "")
	total, kana := 0, 0
	for _, r := range stripped {
		if unicode.IsSpace(r) {
			continue
		}
		total++
		if (r >= 0x3041 && r <= 0x309F) || (r >= 0x30A0 && r <= 0x30FF) {
			kana++
		}
	}
	if total == 0 {
		return 0
	}
	return float64(kana) / float64(total)
}

// usableValueAdd 判一份候选的增值内容是否**可用**(可用才配 +50/+30,防"有就加分"变成
// 来源先验借尸还魂):
//   - 译文:语言前缀匹配目标语言(zh 匹配 zh-hans)、本身是带时间戳的逐行 LRC、行数
//     覆盖原文过半(机翻兜底/残缺译文不算);目标语言是中文时,原文本身就是中文的歌
//     不需要中文译文(cjkRatio>0.5 不给分)。
//   - 罗马音:本身带时间轴,且原文歌词是日文形态(kanaRatio>0.05)——给英文歌配的
//     "罗马音"没有增值。
func usableValueAdd(lyrics, tr, trLang, roma, targetLang string) (usableTr, usableRoma bool) {
	// 语言比对只看主语言子标签(zh-hans / zh-Hant / zh 视为同一种):网易云的社区译文
	// 固定记 "zh",用户的目标语言却可能配成 "zh-hans",单向 HasPrefix 会把它判成语言
	// 不符、白白丢掉这条决胜分(2026-08-12 审阅)。
	baseLang := func(s string) string {
		if i := strings.IndexAny(s, "-_"); i >= 0 {
			s = s[:i]
		}
		return strings.ToLower(strings.TrimSpace(s))
	}
	// "原文已经是中文,不需要中文译文" 这道闸要排除日文:cjkRatio 只数汉字,而日文汉字
	// 同属 Han,汉字密集的日文歌(文语/演歌)会被误判成中文原文,恰恰丢掉这个维度最有
	// 价值的场景(日文歌 + 网易云中文对照)。用假名占比把日文形态摘出来(2026-08-12 审阅)。
	looksChineseOriginal := cjkRatio(lyrics) > 0.5 && kanaRatio(lyrics) <= 0.05
	if tr != "" && targetLang != "" &&
		baseLang(trLang) != "" && baseLang(trLang) == baseLang(targetLang) &&
		isTimedLRC(tr) &&
		2*timedNonEmptyLRCLines(tr) >= timedNonEmptyLRCLines(lyrics) &&
		!(baseLang(targetLang) == "zh" && looksChineseOriginal) {
		usableTr = true
	}
	if roma != "" && isTimedLRC(roma) && kanaRatio(lyrics) > 0.05 {
		usableRoma = true
	}
	return
}

// bilingualTitleEqual 判两个 normLoose 之后的标题是不是「同名的中英双语写法」:
// 短的是长的前缀,短的含汉字,长的多出的尾巴**全是拉丁字母**。
//
// 三个约束各挡一类误伤:
//   - 「前缀含汉字」:纯英文歌不适用 —— "Love" vs "Love Song" 是两首歌,不能因为
//     后者以前者开头就算同一首(这正是 2026-08-09 删掉的"双向子串包含"的定时炸弹,
//     这条规则只对中文标题+英文别名这个特定形态开口子);
//   - 「尾巴全是字母」:数字不算 —— "起源" vs "起源2" 是两首歌;
//   - 「前缀关系」而不是子串:英文别名只会缀在后面,不会插在中间。
func bilingualTitleEqual(a, b string) bool {
	short, long := a, b
	if len(short) > len(long) {
		short, long = long, short
	}
	if short == "" || len(short) == len(long) || !strings.HasPrefix(long, short) {
		return false
	}
	if !containsHan(short) {
		return false
	}
	for _, r := range long[len(short):] {
		if r < 'a' || r > 'z' {
			return false
		}
	}
	return true
}

// wordTimingCoverageFloor 是"这份逐字数据算不算数"的下限:YRC 覆盖到的最后时刻,至少要
// 达到整行歌词最后时刻的这个比例。
//
// 为什么需要这道闸:2026-08-16 修 QQ 的 QRC 截断 bug 时发现,**残缺的逐字数据在系统里
// 长得跟完整的一模一样** —— 只要 YRC 非空,hasWordTiming 就是真、打分照拿逐字加权
// (scoreLyricCandidate 给 +400),而且 enrich 里"已经有逐字就不再重试"那条也会认它。
// 于是一份只覆盖前 19% 的残片,既挤掉了别的源、又不会被自愈,用户看到的是"标着有逐字,
// 前半段有效果后面突然没了"。
//
// 阈值 0.5 是照实测数据定的:扫过本机 136 条有逐字的缓存条目,被截断那条覆盖 19.1%,
// 而**正常**条目最低的一条是 85.4%(netease,差在 LRC 末尾的空行/署名行上),中间隔着
// 一大段空白,取 0.5 两边都不擦边。
const wordTimingCoverageFloor = 0.5

// usableWordTiming 判断一份逐字数据是不是完整到可以拿来用。
//
// 拿不准就放行(返回 true):任一侧缺时间戳时无从比较,而误杀一份好的逐字比放过一份残片
// 更亏 —— 逐字是这套打分里最值钱的东西。
func usableWordTiming(lyrics, yrc string) bool {
	if yrc == "" {
		return false
	}
	lrcEnd := lastLRCTimestampMs(lyrics)
	yrcEnd := lastYRCTimestampMs(yrc)
	if lrcEnd <= 0 || yrcEnd <= 0 {
		return true
	}
	return float64(yrcEnd) >= float64(lrcEnd)*wordTimingCoverageFloor
}

// usableYRC 是 usableWordTiming 的取值版:残缺就当没有,别把残片带进候选。
// 留着残片的话它照样会被写进缓存、导出成 .yrc 文件,渲染时前半段有逐字后半段没有。
func usableYRC(lyrics, yrc string) string {
	if !usableWordTiming(lyrics, yrc) {
		return ""
	}
	return yrc
}

// lastLRCTimestampMs 返回整行歌词里最后一个时间戳(毫秒)。
func lastLRCTimestampMs(lyrics string) int {
	best := 0
	for _, line := range strings.Split(lyrics, "\n") {
		m := lrcLineTimeRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		mm, _ := strconv.Atoi(m[1])
		ss, _ := strconv.Atoi(m[2])
		frac, _ := strconv.Atoi(m[3])
		ms := (mm*60+ss)*1000 + frac*10
		if len(m[3]) == 3 {
			ms = (mm*60+ss)*1000 + frac
		}
		if ms > best {
			best = ms
		}
	}
	return best
}

// lastYRCTimestampMs 返回逐字数据里最后一行的结束时刻(行首 [起始,时长])。
func lastYRCTimestampMs(yrc string) int {
	best := 0
	for _, line := range strings.Split(yrc, "\n") {
		m := yrcLineTimeRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		start, _ := strconv.Atoi(m[1])
		dur, _ := strconv.Atoi(m[2])
		if start+dur > best {
			best = start + dur
		}
	}
	return best
}

var (
	lrcLineTimeRegex = regexp.MustCompile(`^\[(\d+):(\d+)[.:](\d+)\]`)
	yrcLineTimeRegex = regexp.MustCompile(`^\[(\d+),(\d+)\]`)
)
