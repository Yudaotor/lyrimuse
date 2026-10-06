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
