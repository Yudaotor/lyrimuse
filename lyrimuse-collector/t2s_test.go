package main

import (
	"sort"
	"strings"
	"testing"
	"unicode/utf8"
)

// 固定样本回归测试——覆盖 toSimplifiedT2S 几个容易被改坏的规则点。等价性本身(相对
// gocc.OpenCC("t2s") 逐条比对全部 4189+273 条词典数据)已经在切换时验证过一次,不必
// 每次跑测试都拉一份已经移除的第三方依赖重新对拍。
func TestToSimplifiedT2S(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"我們是工農子弟兵", "我们是工农子弟兵"},
		// "乾脆"整词在 TSPhrases 里,长度 2,优先于把"乾""脆"各自当单字查表——
		// 验证"最长匹配优先于单字匹配"这条规则没有被拆散实现搞反。
		{"乾脆說得清楚點", "干脆说得清楚点"},
		// "情有獨鍾"是 TSPhrases 里的 4 字词组,比拆成两个 2 字词组或 4 个单字都长,
		// 必须整体命中。
		{"情有獨鍾", "情有独钟"},
		// "乾隆年間"整个是 TSPhrases 里的专有名词词条(清朝年号,"乾"保留不转),优先于
		// 把"乾"当单字查表——如果被拆成"乾"+"隆"+"年"+"間"分别转换会错误地变成
		// "干隆年间"。
		{"乾隆年間", "乾隆年间"},
		// 没有更长词组命中时才退到单字表:"乾"在 TSCharacters 里有多个候选
		// ("干"/"乾"),取第一个候选"干";"燥"繁简同形,词典没登记,原样保留。
		{"乾燥", "干燥"},
		// 中英文数字/emoji混排,词典没有的字符原样保留,不能被误伤。
		{"周杰倫的歌詞ABC123😀", "周杰伦的歌词ABC123😀"},
		// 词典完全没有的字符原样返回(不是清空/报错)。
		{"hello world 123", "hello world 123"},
	}
	for _, c := range cases {
		if got := toSimplifiedT2S(c.in); got != c.want {
			t.Errorf("toSimplifiedT2S(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// toSimplifiedT2SFullWindow 是按首字限定词组窗口之前的写法:每个位置一律从全表最长词组往下试。
// 只给下面的对拍用。
func toSimplifiedT2SFullWindow(s string) string {
	runes := []rune(s)
	var b strings.Builder
	i := 0
	for i < len(runes) {
		matched := false
		maxLen := t2sMaxPhraseLen
		if remain := len(runes) - i; remain < maxLen {
			maxLen = remain
		}
		for l := maxLen; l >= 2; l-- {
			if repl, ok := t2sPhraseMap[string(runes[i:i+l])]; ok {
				b.WriteString(repl)
				i += l
				matched = true
				break
			}
		}
		if matched {
			continue
		}
		r := runes[i]
		if repl, ok := t2sCharMap[string(r)]; ok {
			b.WriteString(repl)
		} else if std, ok := hanVariantMap[r]; ok {
			b.WriteRune(std)
		} else {
			b.WriteRune(r)
		}
		i++
	}
	return b.String()
}

// 按首字限定窗口 + ASCII 直通,结果必须跟一律试全表最长逐字相同。用词典自己的全部词条
// (单独、首尾夹 ASCII、两两相接)对拍,覆盖「词组套词组」「词组被 ASCII 打断」这些边界。
func TestToSimplifiedT2SMatchesFullWindow(t *testing.T) {
	for k := range t2sCharMap {
		if r, _ := utf8.DecodeRuneInString(k); r < utf8.RuneSelf {
			t.Fatalf("单字表里有 ASCII 条目 %q,ASCII 直通不再安全", k)
		}
	}
	for r := range hanVariantMap {
		if r < utf8.RuneSelf {
			t.Fatalf("异体字表里有 ASCII 条目 %q,ASCII 直通不再安全", r)
		}
	}
	phrases := make([]string, 0, len(t2sPhraseMap))
	for k := range t2sPhraseMap {
		phrases = append(phrases, k)
	}
	sort.Strings(phrases)
	chars := make([]string, 0, len(t2sCharMap))
	for k := range t2sCharMap {
		chars = append(chars, k)
	}
	sort.Strings(chars)
	var inputs []string
	for i, p := range phrases {
		next := phrases[(i+1)%len(phrases)]
		c := chars[i%len(chars)]
		inputs = append(inputs, p, "a"+p+"b", p+next, c+p, p+c+next, "Jay|"+p+" (Live)|"+next)
	}
	for _, in := range inputs {
		if got, want := toSimplifiedT2S(in), toSimplifiedT2SFullWindow(in); got != want {
			t.Fatalf("toSimplifiedT2S(%q) = %q, 全窗口写法 %q", in, got, want)
		}
	}
}
