package main

import (
	"os"
	"strings"
	"testing"
)

func TestTranslationTitleHead(t *testing.T) {
	cases := []struct{ artist, title, want string }{
		{"Tatsuya Kitani", "青のすみか - Where Our Blue Is", "青のすみか"},
		{"KOBUKURO", "桜 - Sakura", "桜"},
		{"KOBUKURO", "蕾(つぼみ) - tsubomi", "蕾(つぼみ)"},
		{"米津玄師", "とまれみよ - Stop Look Both Ways", "とまれみよ"},
		{"某歌手", "晴天 - Sunny Day", "晴天"},
		// 前一段带拉丁字母、就是歌手名
		{"Seventeen", "호시 (HOSHI) - STAY", ""},
		{"米津玄師", "米津玄師 - Lemon", ""},
		// 后一段是版本、序曲、出处,或带数字、中日韩文字
		{"陶喆", "鬼 - Overture", ""},
		{"某歌手", "晴天 - Live", ""},
		{"某歌手", "晴天 - Acoustic Version", ""},
		{"某歌手", "晴天 - Remastered 2011", ""},
		{"某歌手", "晴天 - Love 2", ""},
		{"某歌手", "晴天 - Unplugged", ""},
		{"某歌手", "晴天 - from the series Arcane", ""},
		{"某歌手", "此刻永遠 - 中文版", ""},
		{"某歌手", "Stay - 牡蛎之歌", ""},
		// 没有「 - 」
		{"某歌手", "青のすみか", ""},
		{"某歌手", "", ""},
	}
	for _, c := range cases {
		if got := translationTitleHead(c.artist, c.title); got != c.want {
			t.Errorf("translationTitleHead(%q, %q) = %q, want %q", c.artist, c.title, got, c.want)
		}
	}
}

func TestArtistTitleTailHead(t *testing.T) {
	cases := []struct{ artist, title, want string }{
		{"中島みゆき", "地上の星 / 中島みゆき", "地上の星"},
		{"Aimer", "Ref:rain / Aimer", "Ref:rain"},
		// 后一段不是播放器报的歌手:串烧、合作
		{"某歌手", "晴天 / 七里香", ""},
		{"中島みゆき", "地上の星 / ヘッドライト・テールライト", ""},
		{"", "地上の星 / 中島みゆき", ""},
		{"中島みゆき", "地上の星", ""},
	}
	for _, c := range cases {
		if got := artistTitleTailHead(c.artist, c.title); got != c.want {
			t.Errorf("artistTitleTailHead(%q, %q) = %q, want %q", c.artist, c.title, got, c.want)
		}
	}
	if got := titleVariantFor("Tatsuya Kitani", "青のすみか - Where Our Blue Is"); got != "青のすみか" {
		t.Errorf("titleVariantFor 译名写法 = %q", got)
	}
	if got := titleVariantFor("中島みゆき", "地上の星 / 中島みゆき"); got != "地上の星" {
		t.Errorf("titleVariantFor 歌手写法 = %q", got)
	}
}

// 接线:标题反查 / 原产地曲名之后、按 ISRC 补取之前跑曲名变体轮。
func TestTitleVariantRoundIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	needle := "\t}\n\t// 还缺着的源换一种曲名写法再问一次,见 titleVariantRound。\n\tne, results = titleVariantRound(ctx, artist, title, album, durationSecs, ne, results, onUpdate)\n\t// 按 ISRC 补取"
	if !strings.Contains(string(b), needle) {
		t.Errorf("enrich.go 缺 %q", needle)
	}
	v, err := os.ReadFile("titlevariant.go")
	if err != nil {
		t.Fatal(err)
	}
	if n := "withLyricQueryReason(withLyricSourceOnly(ctx, only), lyricQueryReasonTitleVariant)"; !strings.Contains(string(v), n) {
		t.Errorf("titlevariant.go 缺 %q:只问缺着的源", n)
	}
}
