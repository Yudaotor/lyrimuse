package main

import (
	"hash/fnv"
	"math"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// 歌曲实体里拿歌词当证据、当否决用的那几样:正文剥法、三元组匹配(E2)、用词重合度、时间轴平移。
//
// 正文剥法与三元组匹配跟 App 侧 EnrichTitleAliases(lyricsBody / lyricsTokens / lyricsMatch)同一口径、同一组阈值,
// 只有一处不同:引擎没有 NFKC,全角转半角只折全角 ASCII 那一段(songWidthFold),标点本来就丢掉,
// 剩下的兼容字符(合字、带圈数字)不折。

const (
	// songLyricsSimilarityMin:三元组 Jaccard 的下限。
	songLyricsSimilarityMin = 0.6
	// songLyricsContainmentMin / songLyricsContainmentMinShingles:按包含度认时,较短一份至少这么多个不同的三元组,
	// 其中至少这个比例出现在另一份里。一份比另一份多出整段(夹带的逐句译文、开头的对白)时 Jaccard 被拉低,包含度不受影响。
	songLyricsContainmentMin         = 0.8
	songLyricsContainmentMinShingles = 64
	// songLyricsMinTokens:剥完至少这么多词元才参与比对(过场曲、只有署名行的不比)。
	songLyricsMinTokens = 24
	// songLyricsTrustToleranceSecs:播放器时长跟所配歌词的时长差得多,说明配到了别的歌的词,这份歌词不可信。
	songLyricsTrustToleranceSecs = 3.0
	// songE2DurationToleranceSecs / songE2PreciseToleranceSecs:E2 的时长闸按精度分档:任一侧是整秒时 0.6 秒,
	// 两侧都是毫秒级时 0.05 秒。配错词的两首歌时长天然接近,同一份录音的播放器时长却几乎相等。
	songE2DurationToleranceSecs = 0.6
	songE2PreciseToleranceSecs  = 0.05

	// songLyricsDifferentWordsMax:两份正文用词重合低于它,算不是同一套词。
	songLyricsDifferentWordsMax = 0.5
	// songLyricsSameWordsMin:用词重合不低于它,才去比时间轴。
	songLyricsSameWordsMin = 0.8
	// songLyricsShiftMaxSecs / songLyricsSpreadMaxSecs:同一套词按行对上后,整体平移超过前者或行间离散超过后者,
	// 算同一套词的另一版录音(Demo、带前奏版、Live)。
	songLyricsShiftMaxSecs  = 2.0
	songLyricsSpreadMaxSecs = 1.0
)

var (
	songLyricsTagRe     = regexp.MustCompile(`\[[^\]]*\]`)
	songLyricsWordTagRe = regexp.MustCompile(`<[^>]*>`)
)

// songWidthFold:全角 ASCII(U+FF01–U+FF5E)转半角,全角空格转空格。
func songWidthFold(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 0xFF01 && r <= 0xFF5E:
			return r - 0xFEE0
		case r == '\u3000':
			return ' '
		}
		return r
	}, s)
}

// songHanLike:汉字与假名。跟 App 侧 CharacterSet.hanLike 同一口径。
func songHanLike(r rune) bool {
	return unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) || unicode.Is(unicode.Katakana, r)
}

// songLyricsBody:LRC → 可比对的正文。去掉 `[…]` 时间戳 / 头标签、`<…>` 逐字标签、行首的演唱者标签、署名行,
// 全角转半角 + 繁简 + 小写,只留字母数字与汉字;拉丁字母、数字之间的分隔换成一个空格,汉字之间什么都不留。
func songLyricsBody(lrc string) string {
	speakers := lyricSpeakerLabels(lrc)
	var b strings.Builder
	for _, raw := range strings.FieldsFunc(lrc, func(r rune) bool { return r == '\n' || r == '\r' }) {
		line := strings.TrimSpace(songLyricsWordTagRe.ReplaceAllString(songLyricsTagRe.ReplaceAllString(raw, ""), ""))
		if line == "" {
			continue
		}
		if label, rest, ok := lyricSplitLabel(line); ok && speakers[label] {
			line = strings.TrimSpace(rest)
			if line == "" {
				continue
			}
		}
		if isCreditLine(line) {
			continue
		}
		norm := strings.ToLower(toSimplified(songWidthFold(line)))
		var out []rune
		pendingBreak := false
		for _, r := range norm {
			if unicode.IsLetter(r) || unicode.IsDigit(r) {
				if pendingBreak && len(out) > 0 && !songHanLike(out[len(out)-1]) && !songHanLike(r) {
					out = append(out, ' ')
				}
				out = append(out, r)
				pendingBreak = false
				continue
			}
			pendingBreak = len(out) > 0
		}
		if len(out) == 0 {
			continue
		}
		b.WriteString(string(out))
		b.WriteByte(' ')
	}
	return b.String()
}

// songLyricsTokens:剥好的正文切词元。汉字 / 假名一个字一个,拉丁字母 / 数字一段连续串一个。
func songLyricsTokens(body string) []string {
	var out []string
	var latin []rune
	flush := func() {
		if len(latin) > 0 {
			out = append(out, string(latin))
			latin = latin[:0]
		}
	}
	for _, r := range body {
		switch {
		case r == ' ':
			flush()
		case songHanLike(r):
			flush()
			out = append(out, string(r))
		default:
			latin = append(latin, r)
		}
	}
	flush()
	return out
}

// songHashSet:词元或三元组按 64 位哈希存的集合(全库几千份正文,存字符串太占内存;撞车的概率可以不计)。
type songHashSet map[uint64]struct{}

func songHash(parts ...string) uint64 {
	h := fnv.New64a()
	for i, p := range parts {
		if i > 0 {
			h.Write([]byte{0x1f})
		}
		h.Write([]byte(p))
	}
	return h.Sum64()
}

// songShingles:词元三元组集合。不满三个词元时整串算一个。
func songShingles(tokens []string) songHashSet {
	out := songHashSet{}
	if len(tokens) < 3 {
		if len(tokens) > 0 {
			out[songHash(tokens...)] = struct{}{}
		}
		return out
	}
	for i := 0; i+3 <= len(tokens); i++ {
		out[songHash(tokens[i], tokens[i+1], tokens[i+2])] = struct{}{}
	}
	return out
}

// songWordSet:词元集合。
func songWordSet(tokens []string) songHashSet {
	out := make(songHashSet, len(tokens))
	for _, t := range tokens {
		out[songHash(t)] = struct{}{}
	}
	return out
}

// songLyricsMatch:两份正文的三元组集合是不是同一首歌的词:Jaccard 过 songLyricsSimilarityMin;或较短一份至少
// songLyricsContainmentMinShingles 个不同的三元组、其中至少 songLyricsContainmentMin 出现在另一份里。
func songLyricsMatch(a, b songHashSet) bool {
	shared := 0
	for g := range a {
		if _, ok := b[g]; ok {
			shared++
		}
	}
	union := len(a) + len(b) - shared
	if union == 0 {
		return false
	}
	if float64(shared)/float64(union) >= songLyricsSimilarityMin {
		return true
	}
	smaller := min(len(a), len(b))
	return smaller >= songLyricsContainmentMinShingles && float64(shared)/float64(smaller) >= songLyricsContainmentMin
}

// songWordOverlap:两份正文的用词重合度:共有的词元种数 / 较少一份的词元种数。
func songWordOverlap(a, b songHashSet) float64 {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	shared := 0
	for w := range a {
		if _, ok := b[w]; ok {
			shared++
		}
	}
	return float64(shared) / float64(min(len(a), len(b)))
}

// songDurationsClose:E2 的时长闸。
func songDurationsClose(a, b float64) bool {
	if a <= 0 || b <= 0 {
		return false
	}
	tol := songE2PreciseToleranceSecs
	if songIntegralSecs(a) || songIntegralSecs(b) {
		tol = songE2DurationToleranceSecs
	}
	return math.Abs(a-b) <= tol
}

func songIntegralSecs(v float64) bool { return math.Abs(v-math.Round(v)) < 1e-6 }

// songOneCharVariant:同一种文字的两个写法族键只在等长且恰好一个字不同时才让 E2 连(你 / 妳、刚 / 钢)。
func songOneCharVariant(a, b string) bool {
	x, y := []rune(a), []rune(b)
	if len(x) != len(y) || len(x) < 2 {
		return false
	}
	diff := 0
	for i := range x {
		if x[i] != y[i] {
			diff++
			if diff > 1 {
				return false
			}
		}
	}
	return diff == 1
}

// songTimelineShift:两份同一套词的显示时间轴按正文配对后的整体平移(中位数)与行间离散(相对中位数的中位绝对偏差),
// 单位秒。配上的行数不到 timelineOffsetMinMatched 时 ok 为 false。
func songTimelineShift(a, b []timelineLine) (shift, spread float64, ok bool) {
	an := make([]string, len(a))
	for i, l := range a {
		an[i] = l.norm
	}
	bn := make([]string, len(b))
	for i, l := range b {
		bn[i] = l.norm
	}
	var d []int
	for i, j := range timelineLCSAlign(an, bn) {
		if j >= 0 {
			d = append(d, a[i].ms-b[j].ms)
		}
	}
	if len(d) < timelineOffsetMinMatched {
		return 0, 0, false
	}
	med := songMedianInt(d)
	dev := make([]int, len(d))
	for i, x := range d {
		dev[i] = x - med
		if dev[i] < 0 {
			dev[i] = -dev[i]
		}
	}
	return float64(med) / 1000, float64(songMedianInt(dev)) / 1000, true
}

func songMedianInt(xs []int) int {
	s := append([]int(nil), xs...)
	sort.Ints(s)
	return s[len(s)/2]
}

// songLastLineSecs:显示时间轴最后一句的时刻(秒),没有返回 0。显示时间轴不含空行和署名行,结尾的空行时间戳不算。
func songLastLineSecs(lines []timelineLine) float64 {
	if len(lines) == 0 {
		return 0
	}
	return float64(lines[len(lines)-1].ms) / 1000
}
