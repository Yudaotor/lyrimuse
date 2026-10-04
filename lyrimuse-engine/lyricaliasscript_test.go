package main

import (
	"os"
	"strings"
	"testing"
)

func TestLyricAliasScriptUsable(t *testing.T) {
	for _, c := range []struct {
		alias, original string
		want            bool
	}{
		{"Taylur Swift", "Taylor Swift", true},
		{"Teýlor Swift", "Taylor Swift", true},
		{"テイラー・スウィフト", "Taylor Swift", true},
		{"泰勒·斯威夫特", "Taylor Swift", true},
		{"테일러 스위프트", "Taylor Swift", true},
		{"Jay Chou", "周杰伦", true},
		{"O(+>", "Prince", true},
		{"Тейлор Свифт", "Taylor Swift", false},
		{"Τέιλορ Σουίφτ", "Taylor Swift", false},
		{"Թեյլոր Սվիֆթ", "Taylor Swift", false},
		{"टेलर स्विफ्ट", "Taylor Swift", false},
		{"เทย์เลอร์ สวิฟต์", "Taylor Swift", false},
		// 原署名自己就是西里尔文:同文字的别名照收。
		{"Виктор Цой", "Кино", true},
		{"Kino", "Кино", true},
	} {
		if got := lyricAliasScriptUsable(c.alias, c.original); got != c.want {
			t.Errorf("lyricAliasScriptUsable(%q, %q) = %v, want %v", c.alias, c.original, got, c.want)
		}
	}
}

func TestOrderMBAliasesForRetry(t *testing.T) {
	got := orderMBAliasesForRetry([]string{
		"Dr. Taylor Alison Swift", "Taylur Swift", "Тейлор Свифт", "Teýlor Swift", "テイラー・スウィフト", "泰勒丝", "테일러 스위프트",
	}, "Taylor Swift")
	want := []string{"Dr. Taylor Alison Swift", "テイラー・スウィフト", "泰勒丝", "테일러 스위프트", "Taylur Swift", "Teýlor Swift"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got %v\nwant %v", got, want)
	}
	// 第一个(主名)不管文字系统都留在最前。
	// (输入跟真实的一样不含原名自己,见 mbAliasCandidatesForRetry。)
	got = orderMBAliasesForRetry([]string{"Кино", "Виктор Цой"}, "Kino")
	if strings.Join(got, "|") != "Кино" {
		t.Fatalf("got %v", got)
	}
	if got := orderMBAliasesForRetry(nil, "x"); got != nil {
		t.Fatalf("空列表: %v", got)
	}
}

// 接线守卫:MusicBrainz 别名按文字系统过滤(第一个一律收);补缺席源的别名轮有上限。
func TestAliasRoundBudgetIsWired(t *testing.T) {
	for file, needles := range map[string][]string{
		"match.go": {"range orderMBAliasesForRetry(musicBrainzArtistAliases(ctx, artist), artist) {"},
		"enrich.go": {
			"for i, alt := range altIdentities {",
			"if !rescue && !romaRetry && i >= lyricAliasMissingMaxTries {",
		},
	} {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, n := range needles {
			if !strings.Contains(string(data), n) {
				t.Errorf("%s 缺 %q", file, n)
			}
		}
	}
}
