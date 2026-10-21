package main

import "testing"

// 「 - 」后面的限定词改成括号写法之后共用的歌名闸认得出;限定词仍在,版本闸照样判。
func TestDashTailAsBracket(t *testing.T) {
	for in, want := range map[string]string{
		"Wild Child - Album Version":          "Wild Child (Album Version)",
		"如今 - 录音室版本":                          "如今 (录音室版本)",
		"Interlude - Twisted Elegance - Live": "Interlude - Twisted Elegance (Live)",
		"  Sorry  ":                           "Sorry",
		"- Album Version":                     "- Album Version",
		"Wild Child - ":                       "Wild Child -",
	} {
		if got := dashTailAsBracket(in); got != want {
			t.Errorf("dashTailAsBracket(%q) = %q, want %q", in, got, want)
		}
	}
	if !lyricTitleAccepted(dashTailAsBracket("right where you left me - bonus track"), "right where you left me") {
		t.Error("改写后应当过歌名闸")
	}
	if !versionTagsMismatch("Sorry", "", dashTailAsBracket("Sorry - Live"), "") {
		t.Error("改写后 Live 仍应被版本闸认出")
	}
}

func TestDashTailHead(t *testing.T) {
	for in, want := range map[string]string{
		"什么歌 - 电影<捉妖记2>主题曲":                   "什么歌",
		"Interlude - Twisted Elegance - Live": "Interlude - Twisted Elegance",
		"Sorry":                               "",
		"- Album Version":                     "",
		"Wild Child - ":                       "",
	} {
		if got := dashTailHead(in); got != want {
			t.Errorf("dashTailHead(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestWithoutPromoTitleTail(t *testing.T) {
	for in, want := range map[string]string{
		"什麼歌 - 電影<捉妖記2>主題曲":            "什麼歌",
		"翅膀 - 我可能不會愛你片尾曲":              "翅膀",
		"親密愛人 - 《梅艷芳ANITA》電影宣傳曲":       "親密愛人",
		"說分手的人也會難過 - 影集《接招吧！製作人》單元曲":   "說分手的人也會難過",
		"此刻永遠 - 中文版 - 電影《那張照片裡的我們》主題曲": "此刻永遠 - 中文版",
		// 尾段只有标志词本身、带版本词、不是宣传语:原样
		"愛情 - 插曲":                 "愛情 - 插曲",
		"晴天 - 演唱會主題曲 (Live)":      "晴天 - 演唱會主題曲 (Live)",
		"Sorry - Live":            "Sorry - Live",
		"Musiq Soulchild - Buddy": "Musiq Soulchild - Buddy",
		"主題曲":                     "主題曲",
		"":                        "",
	} {
		if got := withoutPromoTitleTail(in); got != want {
			t.Errorf("withoutPromoTitleTail(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDashVersionTailAsBracket(t *testing.T) {
	for in, want := range map[string]string{
		"漂向北方 - Live at 13th KKBOX Music Awards": "漂向北方 (Live at 13th KKBOX Music Awards)",
		"揪你出去玩 (feat. 謝和弦) - Unplugged 花絮版":      "揪你出去玩 (feat. 謝和弦) (Unplugged 花絮版)",
		"Bad - 2012 Remaster":                    "Bad (2012 Remaster)",
		"Boyfriend - Acoustic Version":           "Boyfriend (Acoustic Version)",
		"Hello - Goodbye":                        "Hello - Goodbye",
		"蘇州河 - 慕容雪":                              "蘇州河 - 慕容雪",
		"Sorry":                                  "Sorry",
	} {
		if got := dashVersionTailAsBracket(in); got != want {
			t.Errorf("dashVersionTailAsBracket(%q) = %q, want %q", in, got, want)
		}
	}
}

// 本地把版本限定词写在「 - 」后面、候选写在括号里或不写:歌名闸跟两边都写括号时一样放行,版本差异照旧归版本闸;
// 尾段不是限定词的、候选一侧的尾段不放宽。
func TestLyricTitleAcceptsDashVersionTail(t *testing.T) {
	for _, c := range []struct {
		candidate, local string
		want             bool
	}{
		{"漂向北方 (Live)", "漂向北方 - Live at 13th KKBOX Music Awards", true},
		{"漂向北方", "漂向北方 - Live at 13th KKBOX Music Awards", true},
		{"Bad - Live at Wembley", "Bad (Live)", false}, // 候选一侧的尾段归各源自己改写
		{"Bad", "Bad - 2012 Remaster", true},
		{"Hello", "Hello - Goodbye", false},
		{"Hello (Live)", "Hello - Goodbye", false},
		{"漂向北方 (Live)", "漂流 - Live at 13th KKBOX Music Awards", false},
	} {
		if got := lyricTitleAccepted(c.candidate, c.local); got != c.want {
			t.Errorf("lyricTitleAccepted(%q, %q) = %v, want %v", c.candidate, c.local, got, c.want)
		}
	}
	if !versionTagsMismatch("漂向北方 - Live at 13th KKBOX Music Awards", "", "漂向北方", "") {
		t.Error("本地是现场版、候选不是,版本闸照样认出")
	}
}
