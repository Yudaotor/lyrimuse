// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"strings"
	"unicode"
)

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
