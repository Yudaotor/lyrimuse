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
