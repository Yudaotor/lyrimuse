package main

import (
	_ "embed"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// composeNFC 把字符串转成 Unicode NFC(规范分解 → 按组合类重排 → 规范组合)。
//
// 播放器报的标签偶尔是分解形式:Spotify 给过「Sa + U+0304 + n-Z」(屏幕上跟「Sān-Z」一模一样)、
// 片假名「ク + U+3099」。App 侧 Swift 的 String 比较按规范等价,查缓存照样命中;引擎这边按字节比,
// 歌词源回的都是组合形式,歌手 / 歌名闸一律判不上,整轮一条候选都留不下,缓存 key 也跟组合形式那条分成
// 两条。所以在 cleanMediaTag(缓存 key 的基础)和 toSimplified(搜索词与比对的入口)两处统一转一次。
// 见 09 章决策 112。
//
// 数据表 dictionary/NFC.txt 由 scripts/gen-nfc-table.swift 从 Foundation 导出:Swift 侧 cleanTag 用
// precomposedStringWithCanonicalMapping,两侧逐码点对拍(keyparitysweep_test.go),必须是同一份数据。
// 引擎零依赖,不引 golang.org/x/text(理由见 fold.go 头注)。
//
// 快路径:没有落在快速检查区间里的码点(U+0300 以下一律不在)就原样返回,不解析数据表、不分配。
//
// 两处跟 Foundation 的实际行为走、不按 UAX #15 的字面(逐码点对拍抓到的,Swift 侧是 Foundation):
//   - 韩文:已经组好的音节不拆开,也不跟后面的收音字母再组合(「가」+ U+11A8 原样保留);只有这一轮由
//     初声 + 中声现组出来的音节才接着收收音。
//   - 分解结果以组合符开头的字(藏文 U+0F73 / U+0F75 / U+0F81 这类)自成一段重排,不跟前面的组合符混排。

//go:embed dictionary/NFC.txt
var nfcTableText string

type nfcTables struct {
	ccc     map[rune]uint8
	decomp  map[rune][]rune
	compose map[[2]rune]rune
	quick   [][2]rune // 按起点排好序、互不重叠
}

var (
	nfcOnce sync.Once
	nfcData nfcTables
)

func loadNFCTables() {
	t := nfcTables{ccc: map[rune]uint8{}, decomp: map[rune][]rune{}, compose: map[[2]rune]rune{}}
	parse := func(s string) rune {
		v, err := strconv.ParseUint(s, 16, 32)
		if err != nil {
			panic("NFC.txt: bad code point " + s)
		}
		return rune(v)
	}
	for _, line := range strings.Split(nfcTableText, "\n") {
		f := strings.Fields(line)
		if len(f) == 0 || strings.HasPrefix(f[0], "#") {
			continue
		}
		switch f[0] {
		case "c":
			n, _ := strconv.Atoi(f[2])
			t.ccc[parse(f[1])] = uint8(n)
		case "d":
			d := make([]rune, 0, len(f)-2)
			for _, x := range f[2:] {
				d = append(d, parse(x))
			}
			t.decomp[parse(f[1])] = d
		case "p":
			t.compose[[2]rune{parse(f[1]), parse(f[2])}] = parse(f[3])
		case "q":
			t.quick = append(t.quick, [2]rune{parse(f[1]), parse(f[2])})
		}
	}
	sort.Slice(t.quick, func(i, j int) bool { return t.quick[i][0] < t.quick[j][0] })
	nfcData = t
}

// nfcQuickHit:这个码点要不要进慢路径。调用方已经排除了 U+0300 以下。
func nfcQuickHit(r rune) bool {
	q := nfcData.quick
	i := sort.Search(len(q), func(i int) bool { return q[i][1] >= r })
	return i < len(q) && q[i][0] <= r
}

const (
	hangulSBase  = 0xAC00
	hangulLBase  = 0x1100
	hangulVBase  = 0x1161
	hangulTBase  = 0x11A7
	hangulLCount = 19
	hangulVCount = 21
	hangulTCount = 28
)

func composeNFC(s string) string {
	slow := false
	for _, r := range s {
		if r >= 0x300 {
			nfcOnce.Do(loadNFCTables)
			if nfcQuickHit(r) {
				slow = true
				break
			}
		}
	}
	if !slow {
		return s
	}
	// 1. 完整规范分解(韩文音节不拆,见头注)。barrier[i] = 重排不能越过 buf[i] 之前那条边界。
	buf := make([]rune, 0, len(s))
	var barrier map[int]bool
	for _, r := range s {
		if d, ok := nfcData.decomp[r]; ok {
			if nfcData.ccc[d[0]] != 0 {
				if barrier == nil {
					barrier = map[int]bool{}
				}
				barrier[len(buf)] = true
			}
			buf = append(buf, d...)
			continue
		}
		buf = append(buf, r)
	}
	// 2. 规范重排:每段连续的非零组合类码点按组合类稳定排序(遇到边界另起一段,见头注)。
	for i := 0; i < len(buf); {
		if nfcData.ccc[buf[i]] == 0 {
			i++
			continue
		}
		j := i + 1
		for j < len(buf) && nfcData.ccc[buf[j]] != 0 && !barrier[j] {
			j++
		}
		seg := buf[i:j]
		sort.SliceStable(seg, func(a, b int) bool { return nfcData.ccc[seg[a]] < nfcData.ccc[seg[b]] })
		i = j
	}
	// 3. 规范组合:跟最近的起始码点组合,中间隔着组合类不小于自己的码点(或另一个起始码点)就算被挡住。
	out := make([]rune, 0, len(buf))
	starter, lastCC := -1, 0
	starterFromLV := false // 这个起始码点是不是这一轮由初声 + 中声现组出来的韩文音节
	for _, r := range buf {
		cc := int(nfcData.ccc[r])
		if starter >= 0 && (len(out)-1 == starter || (lastCC != 0 && lastCC < cc)) {
			if c, lv, ok := nfcComposePair(out[starter], r, starterFromLV); ok {
				out[starter] = c
				starterFromLV = lv
				continue
			}
		}
		if cc == 0 {
			starter = len(out)
			starterFromLV = false
		}
		lastCC = cc
		out = append(out, r)
	}
	return string(out)
}

// nfcComposePair:a + b 能不能组成一个码点。第二个返回值 = 组出来的是不是只有初声 + 中声的韩文音节
// (下一个收音字母只能接在这种音节上,见头注)。
func nfcComposePair(a, b rune, aFromLV bool) (rune, bool, bool) {
	if a >= hangulLBase && a < hangulLBase+hangulLCount && b >= hangulVBase && b < hangulVBase+hangulVCount {
		return hangulSBase + ((a-hangulLBase)*hangulVCount+(b-hangulVBase))*hangulTCount, true, true
	}
	if aFromLV && b > hangulTBase && b < hangulTBase+hangulTCount {
		return a + (b - hangulTBase), false, true
	}
	c, ok := nfcData.compose[[2]rune{a, b}]
	return c, false, ok
}
