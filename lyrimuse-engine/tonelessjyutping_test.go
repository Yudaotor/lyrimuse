package main

import (
	"os"
	"strings"
	"testing"
)

const tonelessCantoneseLyrics = "[00:01.00]我爱你\n[00:03.50]我哋今日好开心\n[00:06.00]唔使惊"

// 网易云给粤语歌的那种:粤拼拼法、一个声调数字都没有。
const tonelessCantoneseRoma = "[00:01.00]ngo oi nei\n[00:03.50]ngo dei gam jat hou hoi sam\n[00:06.00]m sai geng"

func TestLacksJyutpingTones(t *testing.T) {
	for _, c := range []struct {
		name string
		roma string
		want bool
	}{
		{"源给的不带声调", tonelessCantoneseRoma, true},
		{"非标准拼法、不带声调", "[00:03.000]zv coeng : wong gun zong\n[00:05.000]lam bi yiu zoi zei gan yv fai di", true},
		{"带声调", "[00:01.00]ngo5 oi3 nei5\n[00:03.50]ngo5 dei6 gam1 jat6 hou2 hoi1 sam1", false},
		{"带声调、夹着英文", "[00:01.00]baby pink ngo5 oi3 nei5 hou2 noi6\n[00:02.00]i love you so much", false},
		{"太短判不准", "[00:17.48]ba soeng hao tong", false},
		{"空", "", false},
	} {
		if got := lacksJyutpingTones(c.roma); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
	if lacksJyutpingTones(jyutpingLRC(tonelessCantoneseLyrics)) {
		t.Error("引擎生成的粤拼不该判成没标声调")
	}
}

func TestDropUnusableCantoneseRomaRegeneratesTones(t *testing.T) {
	e := enrichEntry{Lyrics: bt(tonelessCantoneseLyrics), LyricsRoma: bt(tonelessCantoneseRoma), SongLanguage: songLanguageCantonese}
	e.dropUnusableCantoneseRoma()
	e.maybeGenerateJyutpingRoma()
	if e.LyricsRoma.IsZero() || lacksJyutpingTones(e.LyricsRoma.String()) {
		t.Fatalf("没标声调的应当换成带声调的粤拼: %q", e.LyricsRoma)
	}
	manual := enrichEntry{Lyrics: bt(tonelessCantoneseLyrics), LyricsRoma: bt(tonelessCantoneseRoma),
		SongLanguage: songLanguageCantonese, ManualLyrics: true}
	manual.dropUnusableCantoneseRoma()
	if !manual.LyricsRoma.EqualString(tonelessCantoneseRoma) {
		t.Error("手改过的不动")
	}
	cmn := enrichEntry{Lyrics: bt(tonelessCantoneseLyrics), LyricsRoma: bt(tonelessCantoneseRoma), SongLanguage: songLanguageMandarin}
	cmn.dropUnusableCantoneseRoma()
	if !cmn.LyricsRoma.EqualString(tonelessCantoneseRoma) {
		t.Error("不是粤语歌不动")
	}
}

func TestMigrateTonelessCantoneseRoma(t *testing.T) {
	toned := jyutpingLRC(tonelessCantoneseLyrics)
	withEnrichCache(t, map[string]enrichEntry{
		"a|没标声调|": {Lyrics: bt(tonelessCantoneseLyrics), LyricsRoma: bt(tonelessCantoneseRoma), SongLanguage: songLanguageCantonese},
		"b|手改|":   {Lyrics: bt(tonelessCantoneseLyrics), LyricsRoma: bt(tonelessCantoneseRoma), SongLanguage: songLanguageCantonese, ManualLyrics: true},
		"c|带声调|":  {Lyrics: bt(tonelessCantoneseLyrics), LyricsRoma: bt("[00:01.00]mine5 mine5 mine5 mine5 mine5 mine5 mine5 mine5"), SongLanguage: songLanguageCantonese},
		"d|普通话|":  {Lyrics: bt(tonelessCantoneseLyrics), LyricsRoma: bt(tonelessCantoneseRoma), SongLanguage: songLanguageMandarin},
		"e|转不出|":  {Lyrics: bt("[00:01.00]Hello hello hello\n[00:02.00]Goodbye goodbye"), LyricsRoma: bt(tonelessCantoneseRoma), SongLanguage: songLanguageCantonese},
	})
	migrateTonelessCantoneseRoma()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if got := enrichCache["a|没标声调|"].LyricsRoma; !got.EqualString(toned) {
		t.Errorf("没标声调的换成引擎生成的粤拼: %q", got)
	}
	if got := enrichCache["b|手改|"].LyricsRoma; !got.EqualString(tonelessCantoneseRoma) {
		t.Errorf("手改过的不动: %q", got)
	}
	if got := enrichCache["c|带声调|"].LyricsRoma; !strings.HasPrefix(got.String(), "[00:01.00]mine5") {
		t.Errorf("带声调的不动: %q", got)
	}
	if got := enrichCache["d|普通话|"].LyricsRoma; !got.EqualString(tonelessCantoneseRoma) {
		t.Errorf("不是粤语歌不动: %q", got)
	}
	if got := enrichCache["e|转不出|"].LyricsRoma; !got.EqualString(tonelessCantoneseRoma) {
		t.Errorf("粤拼生成不出来时留着源那份,不换成空的: %q", got)
	}
}

func TestTonelessCantoneseRomaIsWired(t *testing.T) {
	data, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `startupStep("migrateTonelessCantoneseRoma", migrateTonelessCantoneseRoma)`) {
		t.Error("main.go 没接存量迁移")
	}
}
