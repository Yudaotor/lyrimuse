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

// corroboratedEndings 返回"末尾时间戳被至少一个别的源印证"的来源集合。多个互相独立的
// 歌词源末尾落在几乎同一个时间点,是"这些内容描述的是同一份真实歌词"的强证据——比单纯
// "跟完整曲目时长差多少"更可靠:有些歌曲本身带很长的纯音乐尾奏,没有任何源把它转写进
// 歌词也完全正常,若只按时长差距判断会被误杀;而内容确实被串到别的曲目/版本的候选,
// 不会凑巧跟别的源落在同一个时间点上。
func corroboratedEndings(candidates []lyricCandidate) map[string]bool {
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
const lyricsScoringVersion = 2

func scoreLyricCandidate(localArtist, localTitle string, durationSecs float64, c lyricCandidate, corroborated bool) int {
	if !isTimedLRC(c.lyrics) {
		return -1
	}
	if isProbablyWrongLanguageLyrics(localArtist, localTitle, c.lyrics) {
		return -1
	}
	if isCreditOnlyLRC(c.lyrics) {
		return -1
	}
	score := 0
	if durationSecs > 0 {
		last, ok := lastLRCTimestampSecs(c.lyrics)
		if !ok {
			return -1 // 通过了 isTimedLRC 却提不出最后一个时间戳,理论上不该发生,保守判定无效
		}
		// 0.25 这个阈值卡得比较紧:内容被污染/串错版本的候选跟真实但前奏/尾奏较长的
		// 正确候选,时长偏差有时只差几个百分点,阈值定太松会放过污染候选,定太紧会
		// 错杀真实但尾奏长的候选。
		ratio := math.Abs(last-durationSecs) / durationSecs
		// 歌词末尾**超过**曲目时长,是标错而不是"吻合得好":那几句在实际播放中根本到不了。
		// 现在的 ratio 取的是绝对值,把"早结束"和"晚结束"当同一回事,于是一份标歪到超出
		// 曲长的候选反而能拿满档。2026-08-07 实测坐实:赵雷《我们的时光》(全长 270.8s,
		// 尾奏很长、正常歌词 168s 就唱完了)——qq/酷狗那两份 52 行带逐字的完整版本因为
		// 差 38% 只拿到 corroborated 兜底的 100 分,而 Musixmatch 一份 32 行、没逐字、
		// 末尾标到 284.2s(比整首歌还长 13 秒)的版本差 5%、拿到 962 分,直接胜出。
		// 留 5 秒容差给收尾渐弱/取整这类正常误差。
		overshot := last > durationSecs+lyricOvershootToleranceSecs
		switch {
		case ratio <= 0.25 && !overshot:
			// 连续衰减,而不是硬分档——原来 3%/8%/25% 三级硬边界会让"差一点点"的候选
			// 骤然掉一整档(2026-07-30 实测坐实:某候选末尾时间戳只是恰好比 8% 这道槛
			// 多差了 0.32 个百分点,就从 600 分直接跌到 200 分,反被时长证据其实更弱、
			// 只是巧合压线拿到高档的另一个候选反超)。
			//
			// ⚠️ 2026-08-07 把封顶从 1000 压到 300:时长吻合只是正确性的**间接代理**,
			// 而且被前奏/尾奏系统性带偏(尾奏越长,越是完整正确的歌词越"不吻合");逐字
			// 时间轴则是歌词质量的**直接**证据。原来这一档最高 1000、逐字只有 400,等于
			// 让间接代理压过直接证据 —— 上面那首《我们的时光》就是这么选错的。压到 300
			// 之后,同一场景下 qq(100+400+30+52=582)稳稳压过 Musixmatch(≈307)。
			// 仍然保持"0% 差距最高、线性降到 25% 差距时的 100 分",跟下面 corroborated
			// 那档在边界处平滑衔接,不会在 25% 这个点上制造新的悬崖。
			score += 100 + int(200*(1-ratio/0.25))
		case corroborated:
			score += 100 // 时长差超阈值,但有别的独立源印证末尾时间点,信任交叉印证而非时长
		default:
			return -1 // 时长明显对不上,又没有别的源印证,大概率串了别的曲目/版本
		}
	}
	if c.hasWordTiming {
		score += 400 // 见函数注释第2点:跟"一档时长差距"同量级,让带逐字时间轴的候选在
		// "只差一档时长吻合度"的常见场景里能逆转,但撬不动两档以上的时长证据差距。
	}
	switch c.source {
	case "netease":
		score += 50
	case "qq":
		score += 30
	case "kugou":
		score += 20
	case "musixmatch":
		score += 15
	case "lrclib":
		score += 10
	}
	lines := len(strings.Split(c.lyrics, "\n"))
	if lines > 200 {
		lines = 200
	}
	score += lines
	// 版本限定词对不上 → 重扣。放在最后、扣完再夹到 1,理由见 versionMismatchPenalty。
	if versionTagsMismatch(localTitle, c.title) {
		score -= versionMismatchPenalty
		if score < 1 {
			score = 1
		}
	}
	return score
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
	for _, r := range strings.ToLower(toSimplified(s)) {
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
	}
	if pb := artistCreditParts(nb); len(pb) >= 2 {
		for _, part := range pb {
			if part == na {
				return true
			}
		}
	}
	return false
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
// 也故意只收多词短语或歧义极小的单词:单独一个 "edit"/"mix"/"version" 太容易命中正常
// 曲目名,所以只认 "radio edit"/"extended"/"original version" 这类完整说法。
var distinctRecordingVersionTags = []string{
	"demo", "original version", "album version", "single version",
	"live", "unplugged", "acoustic", "instrumental", "karaoke",
	"remix", "extended", "radio edit", "alternate", "alternative version",
	"rehearsal", "reprise", "a cappella", "acapella",
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

// versionTagsMismatch 判断"候选自报的歌名"跟"本地正在播的歌名"在版本限定词上是否对不上。
// 双向判定:本地是正式版而候选是 demo/live(会展示错版本的时间轴),以及本地是 demo 而候选
// 是正式版(同理),都算不匹配。
//
// candidateTitle 为空(某些源不回报歌名)时一律判不匹配为 false —— 没有证据就不扣分,
// 不能因为源的元数据缺失就把它的歌词判死。
func versionTagsMismatch(localTitle, candidateTitle string) bool {
	if strings.TrimSpace(candidateTitle) == "" {
		return false
	}
	local, cand := titleVersionTags(localTitle), titleVersionTags(candidateTitle)
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

// versionMismatchPenalty 要足够大到"永远压不过标题吻合的候选":时长项最高 1000、逐字项
// 400,600 分足以让原本领先几十分的错版本候选彻底掉到最后。扣完不让它变成负分(负分会被
// pickLyricCandidate 直接丢弃),而是留 1 分—— 实在只有这一个候选时,有总比没有好。
const versionMismatchPenalty = 600

func titleMatches(name, title string) bool {
	if looseContains(name, title) {
		return true
	}
	cn, ct := stripParens(name), stripParens(title)
	return cn != "" && ct != "" && looseContains(cn, ct)
}
