// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"math"
	"regexp"
	"strconv"
	"strings"
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
func isProbablyWrongLanguageLyrics(localArtist, localTitle, lyrics string) bool {
	if cjkRatio(localArtist) > 0 || cjkRatio(localTitle) > 0 {
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
	lines := strings.Split(lrc, "\n")
	nonCredit := 0
	for _, l := range lines {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(l, ""))
		if text == "" || isCreditLine(text) {
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
	source        string // "netease" | "qq" | "kugou" | "musixmatch" | "lrclib"
	lyrics        string
	wordTimingYRC string // 该候选归一化成 YRCParser 语法后的逐字数据,没有则空串(netease/qq/kugou 都可能有,lrclib 恒无)
	hasWordTiming bool   // = wordTimingYRC != "",构造候选时直接算好,见 enrich.go
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
}

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
const lyricsScoringVersion = 4

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
		scoreTermRoma, scoreTermSourceDurationOff,
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
)

// nativeLyricSource 是「当前播放器自家的歌词源」("qq"/"netease"),main() 按
// features.Player 设一次;识别不出(Apple Music / Spotify / auto)就留空,不加分。
//
// 跟 features 同款的包级变量而不是打分函数的参数:打分函数已经有 7 个参数,再加一个
// 会让每个调用点都得关心一件跟它无关的事。测试里直接赋值即可。
var nativeLyricSource string

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
	if !isTimedLRC(c.lyrics) {
		return reject(scoreRejectNotTimed)
	}
	if isProbablyWrongLanguageLyrics(localArtist, localTitle, c.lyrics) {
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
	if nativeLyricSource != "" && c.source == nativeLyricSource {
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
	// 理由见 versionTagsMismatch。
	if versionTagsMismatch(localTitle, localAlbum, c.title, c.album) {
		add(scoreTermVersionTags, -versionMismatchPenalty)
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
func artistCreditParts(s string) []string {
	var parts []string
	for _, p := range strings.FieldsFunc(strings.TrimSpace(strings.ToLower(s)), isArtistCreditSep) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	return parts
}

// isArtistCreditSep 是"多人合credit"字符串的分隔符集合,artistCreditParts/
// firstCreditedArtist 共用同一份,避免两处各自维护一份分隔符列表、以后加分隔符漏改一处。
func isArtistCreditSep(r rune) bool {
	return r == '/' || r == '、' || r == '&' || r == ',' || r == '，'
}

// firstCreditedArtist 把"多人合credit"字符串(如"Prince & The Revolution"、
// "陶喆、卢广仲")按 artistCreditParts 同一套分隔符拆开,取第一位——歌手统计类场景(见
// topartists.go 的 mergeAliasedArtists)要求这类合唱/feat.credit 全部算到"第一个人"
// 头上,不单独占一个歌手名额。只有真正切出 ≥2 段才当作合唱处理,跟 artistCreditParts
// 同一个理由(防止"周杰伦、"这种只有一个人、结尾恰好带分隔符的写法被误判成合唱)。返回
// 原始大小写/原始文字(不像 artistCreditParts 那样统一转小写——那是给"判断是否同一个人"
// 这一步比较用的,这里要的是展示用的原始名字)。
func firstCreditedArtist(s string) string {
	trimmed := strings.TrimSpace(s)
	var parts []string
	for _, p := range strings.FieldsFunc(trimmed, isArtistCreditSep) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) >= 2 {
		return parts[0]
	}
	return trimmed
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
func artistMatches(a, b string) bool {
	na, nb := strings.TrimSpace(strings.ToLower(a)), strings.TrimSpace(strings.ToLower(b))
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
// 写法只切出 1 段,永远进不了交集档;段与段之间仍是字节相等(小写/去空白后),不做
// normLoose/子串,"周杰伦-" 冒充 "周杰伦" 的老洞不会被重新打开。
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

// artistAliasTable 是极小的、手工登记的"已知英文/罗马化艺名 → 本库常用中文名"
// 对照表，只兜底 NetEase/QQ 的跨服务自动匹配天生够不到的两类情况：①合唱/feat.曲目里
// NetEase 把曲目记成多位歌手、本地标签只留主唱一人的英文名，title/album 文本对不上，
// nameOnlyMatch 那套"跨服务强匹配"救不了；②Last.fm 桥接转发的收听，本地标签是歌手的
// 英文/罗马化艺名，但 NetEase/QQ 只按中文舞台名索引，英文名查不到任何候选，连封面都
// 解析不出来。这不是算法能推导的东西(不像 toSimplified 繁简转换有规律可循)，只能手工
// 登记这个人自己公开、确凿无疑的艺名，覆盖不到的组合原样保留，不会比现状更差。
var artistAliasTable = map[string]string{
	"david tao":  "陶喆",
	"jason chan": "陈柏宇",
	"kun":        "蔡徐坤",
	"dean ting":  "丁世光",
	"crowd lu":   "卢广仲",
	// 2026-08-18 批量补充:用户逐条核对 Last.fm Top100 导出坐实的同人异名(值是本库
	// 常用名,不一定是中文——Utada 的常用名就是日文)。这些同时喂三处:歌词检索的
	// 别名重试(retryArtistIdentities)、canonical_artist 兜底、Top 歌手榜归并
	// (artistMergeNameKey/artistMergeDisplayName)。MusicBrainz 身份解析
	// (resolveArtistIdentityMB)是这类问题的通用防线,这张表兜住它查不到/被
	// country 门槛挡掉的确证个案(如曲婉婷 country=CA)。
	"leah dou":    "窦靖童",
	"soft lipa":   "蛋堡",
	"diana wang":  "王诗安",
	"a si":        "阿肆",
	"eve ai":      "艾怡良",
	"nicky lee":   "李玖哲",
	"utada":       "宇多田ヒカル",
	"wanting":     "曲婉婷",
	"ronghao li":  "李荣浩",
	"matt lv":     "吕彦良",
	"pei-yu hung": "洪佩瑜",
	"lexie liu":   "刘柏辛",
	// 第二轮(同日,MB 通用层解析不到中文名的确证补充——不在 MusicBrainz 或没登记中文别名)。
	"sodagreen":      "苏打绿",
	"zhang yu sheng": "张雨生",
	// 第三轮(同日,专辑导出核对时发现这两个英文艺名也真实出现在库的歌手标签里)。
	"khalil fong": "方大同",
	"jay chou":    "周杰伦",
	// 第四轮(同日,歌曲导出核对):宇多田三写法并存,英文名和中文名都折到日文常用名。
	"hikaru utada": "宇多田ヒカル",
	"宇多田光":         "宇多田ヒカル",
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
// 顺序是人工 > 自动:手写表登记的是这个人自己公开、确凿无疑的艺名;MusicBrainz 是自动
// 查询,覆盖面大得多但偶有噪声。两者都拿到时先试人工那条。
//
// 成本几乎为零:MusicBrainz 那次查询本来就会发生(resolveTrackEnrichment 里紧接着就调),
// 只是被挪早了,而且它按歌手永久缓存,那边随后再调就是一次 map 读。
func retryArtistIdentities(artist string) []string {
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
	add(knownArtistAlias(artist))
	add(canonicalArtistViaMusicBrainz(artist))
	// 第三条(2026-08-20):MB 上这位歌手的**主名**。前两条都是"中文名"取向 —— 手工表
	// 登记的是中文常用名,canonical 那条只在中文圈艺人身上出结果 —— 而"本名 ↔ 艺名"
	// (Abel Tesfaye ↔ The Weeknd)跟中文毫无关系,以前整个类别没人管。
	// 排在最后:它是纯自动推断,让人工登记和跨服务核实过的结果先试。
	add(musicBrainzPrimaryArtistName(artist))
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

// albumTokens 除了在非字母数字处断词,还在"数字→字母"/"字母→数字"的交界处断词——中文
// 演唱会专辑名常见"2011Live"/"2020巡演"这种年份和后缀之间不留空格的写法,原来整段被
// strings.FieldsFunc 当成一个词,导致跟本地(通常是英文、年份和单词之间有空格)标签的
// "2011"+"live"两个独立词对不上、白白丢掉本该有的匹配分,容易在多个候选打平时选错。
// 拆开后能对上"2011"+"live"这两个独立词,分数明显领先,不再靠运气打平。
func albumTokens(s string) map[string]bool {
	out := map[string]bool{}
	s = strings.ToLower(s)
	var cur []rune
	const (
		kindNone = iota
		kindDigit
		kindLetter
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
		switch {
		case unicode.IsDigit(r):
			if prevKind == kindLetter {
				flush()
			}
			cur = append(cur, r)
			prevKind = kindDigit
		case unicode.IsLetter(r):
			if prevKind == kindDigit {
				flush()
			}
			cur = append(cur, r)
			prevKind = kindLetter
		default:
			flush()
			prevKind = kindNone
		}
	}
	flush()
	return out
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
}

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
func versionTagsMismatch(localTitle, localAlbum, candidateTitle, candidateAlbum string) bool {
	if strings.TrimSpace(candidateTitle) == "" && strings.TrimSpace(candidateAlbum) == "" {
		return false
	}
	local, cand := versionTagsIn(localTitle, localAlbum), versionTagsIn(candidateTitle, candidateAlbum)
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

// versionMismatchPenalty 要足够大到"永远压不过标题吻合的候选":时长项最高 1000、逐字项
// 400,600 分足以让原本领先几十分的错版本候选彻底掉到最后。扣完不让它变成负分(负分会被
// pickLyricCandidate 直接丢弃),而是留 1 分—— 实在只有这一个候选时,有总比没有好。
const versionMismatchPenalty = 600

// lyricTitleAccepted 是**五个源共用**的唯一一条「这条候选的曲名算不算这首歌」判定。
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

// lyricConsensusBody 把一份 LRC 归一成"可跨源比对的正文":逐行去时间戳、丢署名行与
// 空行,每行 normLoose 后拼接。给 contentConsensusPeers 的 3-gram 比对用。
func lyricConsensusBody(lyrics string) string {
	var b strings.Builder
	for _, line := range strings.Split(lyrics, "\n") {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" || isCreditLine(text) {
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
		if !isTimedLRC(c.lyrics) ||
			isProbablyWrongLanguageLyrics(localArtist, localTitle, c.lyrics) ||
			isCreditOnlyLRC(c.lyrics) {
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
// distinctRecordingVersionTags 全部是纯拉丁词,按非字母数字切词后比对连续词序列即可。
//
// ⚠️ 只给这个 v3 新 helper 用。titleVersionTags(versionTagsMismatch 那条 −600 的存量路径)
// 保持原样:它的行为已被 201 首反事实评测背书,改它等于动一个没评测过的维度。
func segmentVersionTags(seg string) map[string]bool {
	toks := strings.FieldsFunc(strings.ToLower(seg), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	out := map[string]bool{}
	for _, tag := range distinctRecordingVersionTags {
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
	return out
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
