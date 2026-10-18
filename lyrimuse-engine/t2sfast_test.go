package main

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// toSimplifiedT2SReference 是改用子串查表、加 ASCII 快速路径之前的写法(逐个长度 string(runes[i:i+l])),只给下面对拍用。
func toSimplifiedT2SReference(s string) string {
	runes := []rune(s)
	var b strings.Builder
	i := 0
	for i < len(runes) {
		if runes[i] < utf8.RuneSelf {
			b.WriteRune(runes[i])
			i++
			continue
		}
		matched := false
		maxLen := t2sPhraseMaxLenByFirst[runes[i]]
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

// 子串查表、ASCII 快速路径跟原来逐字相同:纯 ASCII、繁体词组、混排、非法 UTF-8、异体字。
func TestToSimplifiedT2SMatchesReference(t *testing.T) {
	inputs := []string{
		"", "Michael Jackson|Man In The Mirror (Immortal Version)|Immortal", "abc 123 !?",
		"千紙鶴", "我懷念的", "孫燕姿", "回到未來", "乾隆皇帝在臺灣的時候", "著名的頭髮", "妳是我的唯一",
		"周杰倫 Jay Chou - 晴天 (Live)", "東京事變", "後來的我們", "鬱金香", "麵包與愛情",
		"\xff\xfe繁體\xc3", "a\x80b", "髮\xe9型", strings.Repeat("憂鬱的臺北", 50),
	}
	for word := range t2sPhraseMap {
		inputs = append(inputs, word, "x"+word+"y", word+word)
		if len(inputs) > 3000 {
			break
		}
	}
	for _, in := range inputs {
		if got, want := toSimplifiedT2S(in), toSimplifiedT2SReference(in); got != want {
			t.Errorf("toSimplifiedT2S(%q) = %q, want %q", in, got, want)
		}
	}
}

// normLoose 的记忆跟现算一致,满了整张清掉。
func TestNormLooseMemo(t *testing.T) {
	for _, in := range []string{"BLOOD ON THE DANCE FLOOR/ HIStory In The Mix", "千紙鶴", "Ｂｅｙｏｎｄ", "Café", ""} {
		first, again := normLoose(in), normLoose(in)
		if want := normLooseUncached(in); first != want || again != want {
			t.Errorf("normLoose(%q) = %q / %q, want %q", in, first, again, want)
		}
	}
	normLooseMemoMu.Lock()
	saved := normLooseMemo
	normLooseMemo = make(map[string]string, normLooseMemoMax)
	for i := 0; len(normLooseMemo) < normLooseMemoMax; i++ {
		normLooseMemo[strings.Repeat("k", 1)+string(rune(0x4e00+i))] = ""
	}
	normLooseMemoMu.Unlock()
	t.Cleanup(func() {
		normLooseMemoMu.Lock()
		normLooseMemo = saved
		normLooseMemoMu.Unlock()
	})
	normLoose("溢出之后")
	normLooseMemoMu.RLock()
	n := len(normLooseMemo)
	normLooseMemoMu.RUnlock()
	if n != 1 {
		t.Errorf("满了应整张清掉再记,现在 %d 条", n)
	}
}

// lyricsFileFold 的记忆跟现算一致(第二次起走记忆)。
func TestLyricsFileFoldMemo(t *testing.T) {
	for _, k := range []string{"A|Song|B", "陈奕迅|浮夸|U87", "AC/DC|Back In Black|Back In Black"} {
		want := strings.ToLower(sanitizeLyricsFilename(k))
		if first, again := lyricsFileFold(k), lyricsFileFold(k); first != want || again != want {
			t.Errorf("lyricsFileFold(%q) = %q / %q, want %q", k, first, again, want)
		}
	}
}
