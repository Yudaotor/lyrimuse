// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
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
// 开头一行作词/作曲 credit 信息被打了个孤立时间戳,其余全是无时间戳纯文本(实测坐实:
// Musiq Soulchild《Babygirl》/《Religious》都是这种情况——前者只有 [Verse 1] 这类
// 段落标签、后者只有开头 credit 行带一个孤立的 [00:00.00-1]时间戳,单看"字符串里有没有
// 方括号"完全区分不出来这两种和真正的逐行 LRC,导致这两首歌被当成"有歌词"缓存进去,
// 但网页侧解析不出任何一行真正带时间戳的歌词,歌词区域自然什么都不显示)。要求至少
// 3 行、且过半的行真的带 [mm:ss.xx] 格式时间戳,才认为是可用的逐行 LRC。
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
// 但解析出来的'原文'歌词却大半是中文"这种明显文不对题的情况——实测坐实:Musiq
// Soulchild《Bestfriend》网易云的 lrc(原文)字段本身 71% 是中文、tlyric(翻译)也是
// 中文,应该是上传者把翻译当原文传错了。本地标签本身就是中文时不适用这条判断(中文
// 歌配中文"原文"歌词完全正常，不该被当成异常拦下来)。
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

// isCreditOnlyLRC 判断这份"通过了 isTimedLRC"的歌词是不是只有作词/作曲等 credit 信息、
// 没有真正的歌词正文——实测坐实:网易云有时把整首歌的"歌词"就只填了几行 credit,每行都
// 单独带时间戳(能通过 isTimedLRC 那条"过半行数带时间戳"的检测),但去掉 credit 行之后
// 剩不下几行真正在唱的词(Religious 那次就是这种情况)。去掉时间戳和 credit 行之后,
// 剩余非空行少于 3 行就判定为"只有 credit,没有正文"。
func isCreditOnlyLRC(lrc string) bool {
	lines := strings.Split(lrc, "\n")
	nonCredit := 0
	for _, l := range lines {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(l, ""))
		if text == "" || creditLineRe.MatchString(text) {
			continue
		}
		nonCredit++
	}
	return nonCredit < 3
}

// lastLRCTimestampSecs 取 LRC 里最后一个 [mm:ss.xx] 时间戳、换算成秒。frac 部分可能是
// 两位(百分之几秒)或三位(毫秒),按其实际代表的小数位数换算,不假设固定是哪一种。
func lastLRCTimestampSecs(lrc string) (float64, bool) {
	matches := lrcTimestampCaptureRe.FindAllStringSubmatch(lrc, -1)
	if len(matches) == 0 {
		return 0, false
	}
	m := matches[len(matches)-1]
	mm, _ := strconv.Atoi(m[1])
	ss, _ := strconv.Atoi(m[2])
	frac, _ := strconv.Atoi(m[3])
	fracSecs := float64(frac) / math.Pow(10, float64(len(m[3])))
	return float64(mm*60+ss) + fracSecs, true
}

// lyricCandidate 是某个歌词源解析出的一份候选结果,连同来源标记。
type lyricCandidate struct {
	source string // "netease" | "qq" | "kugou" | "lrclib"
	lyrics string
}

// lyricEndingCorroborationToleranceSecs 是判定"多个独立源的歌词末尾时间戳互相印证"的
// 容差。实测标定:宇多田ヒカル《気分じゃないの》(真实数据,只是尾奏长)三源末尾互相只差
// 0.2~1.5s;Something 那次网易云被 George Harrison 内容污染的候选,跟酷狗真实 Musiq
// 版本的末尾相差约 19.6s——两者差出一个数量级,5s 足够宽容跨源转写的细微时间差,又足够
// 严格不会让内容对不上的候选蒙混过关。
const lyricEndingCorroborationToleranceSecs = 5.0

// corroboratedEndings 返回"末尾时间戳被至少一个别的源印证"的来源集合。多个互相独立的
// 歌词源末尾落在几乎同一个时间点,是"这些内容描述的是同一份真实歌词"的强证据——比单纯
// "跟完整曲目时长差多少"更可靠:有些歌曲本身带很长的纯音乐尾奏,没有任何源把它转写进
// 歌词也完全正常(気分じゃないの 实测坐实:真实时长 448s,网易云/酷狗/LRCLIB 三源全部
// 独立在 305~307s 处结束,却因为跟完整时长差了 32% 被旧的纯时长阈值误杀);而内容确实
// 被串到别的曲目/版本的候选,不会凑巧跟别的源落在同一个时间点上。
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
//     歌(实测坐实:Something 那次,网易云给的内容末尾时间戳跟真实时长差了近 29%,内容
//     被串了)。差超过 25% 且没有别的源印证,直接判定无效,不是扣分——时长对不上通常
//     就是串了别的曲目/版本，留着只会增加"矮子里拔将军选中一个不确定对不对的候选"的
//     风险。但如果 corroborated 为真(见 corroboratedEndings),说明别的独立源也在同一
//     时间点结束,这是比"跟完整时长差多少"更直接的正确性证据,不再判定无效。
//  2. 来源优先级:网易云能带翻译/罗马音/逐字这类其它源没有的增值内容,同等时长可信度下
//     优先选它，其次QQ,再其次酷狗/LRCLIB——避免"纯按行数比大小"让内容切分方式恰好更
//     碎的源意外挤掉本来完全合格、还带增值内容的网易云结果(实测坐实:Darling Nikki
//     网易云版本本来自带翻译/逐字,如果单纯比行数会被行数更多但没有增值内容的 LRCLIB
//     顶替掉)。
//  3. 内容行数只做非常次要的参考(封顶,避免行数虚高的候选靠行数堆分反超时长/来源都更
//     可信的候选)。
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
		// 阈值实测坐实(Something 那次):网易云被 George Harrison credit 污染的错误内容,
		// 末尾时间戳跟真实时长差了 28.7%;而酷狗那份验证过是真正 Musiq Soulchild 原文
		// 内容(不提 George Harrison)的候选,只是因为歌曲本身前奏/尾奏较长导致差了
		// 22.3%——两者差距只有 6 个百分点,卡在 0.25 才能两边都分对(既拦住确凿污染的
		// 网易云候选,又不错杀真实但有较长纯音乐尾奏的酷狗候选)。
		ratio := math.Abs(last-durationSecs) / durationSecs
		switch {
		case ratio <= 0.03:
			score += 1000
		case ratio <= 0.08:
			score += 600
		case ratio <= 0.25:
			score += 200
		case corroborated:
			score += 100 // 时长差超阈值,但有别的独立源印证末尾时间点,信任交叉印证而非时长
		default:
			return -1 // 时长明显对不上,又没有别的源印证,大概率串了别的曲目/版本
		}
	}
	switch c.source {
	case "netease":
		score += 50
	case "qq":
		score += 30
	case "kugou":
		score += 20
	case "lrclib":
		score += 10
	}
	lines := len(strings.Split(c.lyrics, "\n"))
	if lines > 200 {
		lines = 200
	}
	score += lines
	return score
}

// normLoose lowercases and drops everything but letters/digits (keeps CJK), so
// "BLOOD ON THE DANCE FLOOR/ HIStory In The Mix" and "Blood On the Dance Floor:
// HIStory In the Mix" compare equal when matching albums across services.
func normLoose(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
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
// 本身就是可疑的仿冒特征(实测坐实:网易云真实返回过艺人字段就是独立一条"周杰伦、"的
// 仿冒条目),调用方按"len<2 就当成单一人名"处理,不能被这种情况悄悄吃掉。
func artistCreditParts(s string) []string {
	isSep := func(r rune) bool { return r == '/' || r == '、' || r == '&' || r == ',' || r == '，' }
	var parts []string
	for _, p := range strings.FieldsFunc(strings.TrimSpace(strings.ToLower(s)), isSep) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	return parts
}

// artistMatches reports whether two artist names refer to the same person/act.
// Unlike looseContains (fine for titles/albums, where stripping punctuation and
// loose containment is desirable), artist IDENTITY must not be checked with
// normLoose+Contains: normLoose strips all punctuation, so an impersonator
// account like "周杰伦-" or "周杰伦." normalizes identical to "周杰伦" and would
// wrongly pass as the genuine artist — and even without normLoose, plain
// substring containment still lets "周杰伦" match as a prefix of "周杰伦-".
// Real-world case that surfaced this (实测坐实): Jay Chou's catalog is pulled
// from NetEase entirely, so searches only return impersonator accounts riding
// on a near-identical name; the old check let them through and the wrong
// impersonator's cover got cached and reused across several real songs.
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
// 对照表，只兜底 NetEase/QQ 的跨服务自动匹配天生够不到的情况——两条已实测坐实的场景：
// ①合唱/feat.曲目里 NetEase 把该曲目记成多位歌手(如"陶喆、卢广仲")，本地(Apple
// Music)标签只留了主唱一人的英文名(如"David Tao")，且专辑名网易云也是中文写法，
// title/album 都对不上文本，nameOnlyMatch 那套"跨服务强匹配"救不了(陶喆《那个女孩
// (feat.卢广仲)》等)；②iPhone 经 Last.fm 桥接转发的收听，NetEase/QQ 搜索直接拿
// 英文艺名(如"Jason Chan"/"Kun"/"Dean Ting")去查完全查无这首歌——两家平台索引的
// 是这些歌手的中文舞台名，英文名不在可搜索的别名范围内，连封面都解析不出来(陈柏宇
// 《你瞒我瞒》/蔡徐坤《Jasmine》/丁世光《情话》等)。这不是算法能推导的东西(不像
// toSimplified 繁简转换有规律可循)，只能手工登记这个人自己公开、确凿无疑的艺名，
// 覆盖不到的组合原样保留，不会比现状更差。
var artistAliasTable = map[string]string{
	"david tao":  "陶喆",
	"jason chan": "陈柏宇",
	"kun":        "蔡徐坤",
	"dean ting":  "丁世光",
}

// knownArtistAlias 只在 NetEase/QQ 都没能给出 canonical_artist 时,由
// resolveTrackEnrichment 作最后一道兜底调用——优先级低于跨服务实时核实的结果。
func knownArtistAlias(artist string) string {
	return artistAliasTable[strings.ToLower(strings.TrimSpace(artist))]
}

// neteaseImpersonatorRiddenArtists 是版权已从网易云整体下架、曲库里只剩仿冒号的艺人
// 名单(实测坐实,2026-07-11):这类艺人任何"标题+专辑名精确匹配"的候选，先天就该是
// 仿冒号——真人官方版本根本不在库里，不存在"两者都对上但恰好不是官方"的中间地带。
// nameOnlyMatch()"歌手名字面对不上也认"这条规则的前提是"信任跨服务强匹配大概率可信"，
// 对这类艺人不成立,会直接把仿冒号的署名当成核实过的官方名(实测:周杰伦《爱在西元前》
// 网易云唯一一条标题+专辑名精确匹配的候选，署名是自建小号"Jinhua Jue"，头像还是默认图)。
// 只需要极少数确凿知名的名字,新的按实际踩坑追加即可。
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

// toSimplified 把繁体字逐字转成对应简体字(表里没有的字原样保留,不认识就不动,绝不出错)。
// 只给 resolveNeteaseInfo 里的 nameOnlyMatch(统一歌手名用)本地比较前调用,不改
// normLoose/albumScore/pick() 本身——那条判定链路管封面/歌词选谁,已经为防仿冒号反复
// 加固过,不该因为繁简这个不相关的问题被牵动。
// 实测坐实:同一张专辑,本地(Apple Music)标签里繁简写法都出现过(如「太美麗」/「太美丽」、
// 「危險世界」/「危险世界」)，哪怕只差一个字，字符级比较也会判定成两个完全不相关的专辑名，
// 沿用 normLoose 的英文字符集思路(逐字符规整)覆盖不到这个场景。这张表只覆盖歌名/专辑名/
// 歌手名常见字，不追求覆盖全部生僻字——识别不出的字原样保留是安全的(退回到"跟没转换一样"，
// 不会比现状更差)。
// 每个 key/value 都必须是恰好一个字符的 rune 字面量(Go 语法限制),所以表里只放单字,
// 靠 toSimplified 逐字符扫描来拼出整词的效果——不需要、也不能放多字词条。
var t2sTable = map[rune]rune{
	'愛': '爱', '樂': '乐', '國': '国', '們': '们', '時': '时', '間': '间', '這': '这', '說': '说',
	'話': '话', '誰': '谁', '個': '个', '為': '为', '讓': '让', '過': '过', '沒': '没', '從': '从',
	'對': '对', '還': '还', '覺': '觉', '幾': '几', '開': '开', '關': '关', '樣': '样', '麼': '么',
	'現': '现', '見': '见', '聽': '听', '買': '买', '賣': '卖', '車': '车', '馬': '马', '鳥': '鸟',
	'魚': '鱼', '飯': '饭', '錢': '钱', '醜': '丑', '麗': '丽', '憂': '忧', '鬱': '郁', '龍': '龙',
	'風': '风', '島': '岛', '導': '导', '劇': '剧', '藝': '艺', '術': '术', '樹': '树', '葉': '叶',
	'陽': '阳', '陰': '阴', '電': '电', '語': '语', '詞': '词', '記': '记', '憶': '忆', '戀': '恋',
	'傷': '伤', '溫': '温', '淚': '泪', '夢': '梦', '別': '别', '離': '离', '遠': '远', '傳': '传',
	'統': '统', '藍': '蓝', '紅': '红', '綠': '绿', '黃': '黄', '顏': '颜', '禮': '礼', '歷': '历',
	'曆': '历', '陸': '陆', '亂': '乱', '滿': '满', '謎': '谜', '悶': '闷', '寧': '宁', '寫': '写',
	'讀': '读', '飛': '飞', '進': '进', '輕': '轻', '長': '长', '興': '兴', '雲': '云', '學': '学',
	'區': '区', '團': '团', '應': '应', '願': '愿', '寶': '宝', '寵': '宠', '獨': '独', '單': '单',
	'難': '难', '謝': '谢', '慣': '惯', '確': '确', '認': '认', '識': '识', '險': '险', '謊': '谎',
	'騙': '骗', '約': '约', '擁': '拥', '燦': '灿', '爛': '烂', '經': '经', '腦': '脑', '頭': '头',
	'臉': '脸', '髮': '发', '發': '发', '聲': '声', '響': '响', '選': '选', '決': '决', '堅': '坚',
	'強': '强', '軟': '软', '氣': '气', '圍': '围', '圓': '圆', '點': '点', '優': '优', '總': '总',
	'雖': '虽', '卻': '却', '實': '实', '絕': '绝', '掙': '挣', '奮': '奋', '鬥': '斗', '執': '执',
	'著': '着', '結': '结', '續': '续', '複': '复', '純': '纯', '虛': '虚', '裝': '装', '偽': '伪',
	'謹': '谨', '裡': '里', '裏': '里', '妳': '你', '牠': '它', '贊': '赞', '讚': '赞', '鍾': '钟',
	'鐘': '钟', '韓': '韩', '灣': '湾', '臺': '台', '織': '织', '殭': '僵',
}

// toSimplified 逐字符查表转换,表外字符原样保留(见上方注释:安全默认,查不到就不变)。
func toSimplified(s string) string {
	var b strings.Builder
	for _, r := range s {
		if v, ok := t2sTable[r]; ok {
			b.WriteRune(v)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// albumStop are filler words ignored when comparing album names by shared tokens.
var albumStop = map[string]bool{
	"the": true, "a": true, "an": true, "and": true, "of": true, "in": true, "on": true,
	"at": true, "to": true, "for": true, "with": true, "book": true, "vol": true,
	"volume": true, "disc": true, "cd": true, "edition": true, "deluxe": true,
	"remastered": true, "part": true, "pt": true, "feat": true, "ft": true,
	"i": true, "ii": true, "iii": true, "iv": true,
}

func albumTokens(s string) map[string]bool {
	out := map[string]bool{}
	for _, t := range strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		if len([]rune(t)) <= 1 || albumStop[t] {
			continue
		}
		out[t] = true
	}
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
	// 被更晚出现的重发版顶替(实测坐实:Prince "1999" 曾被错配成 Super Deluxe 版封面)。
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
func titleMatches(name, title string) bool {
	if looseContains(name, title) {
		return true
	}
	cn, ct := stripParens(name), stripParens(title)
	return cn != "" && ct != "" && looseContains(cn, ct)
}
