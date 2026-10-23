package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
)

const thaiLine = "[00:01.00]วันที่เขาอ่านเธอไม่ละสายตา"

func TestHasWorldReadingScript(t *testing.T) {
	cases := []struct {
		name   string
		lyrics string
		want   bool
	}{
		{"泰文", thaiLine, true},
		{"俄语", "[00:01.00]Ты танцуешь, будто сумасшедшая", true},
		{"希腊语", "[00:01.00]Στάζει φωτιά στα χείλη το αντίο", true},
		{"天城文", "[00:01.00]सीने में दिल ये धड़कता हुआ", true},
		{"孟加拉文", "[00:01.00]আমি তোমারে সঁপেছি প্রাণ", true},
		{"马拉雅拉姆文", "[00:01.00]നടക്കടാ അങ്ങോട്ട് പോകാം", true},
		{"英文歌里一个希腊字母当装饰", "[00:01.00]Ω love you baby tonight", false},
		{"阿拉伯字母只用源自带的", "[00:01.00]إنت حبيبي وانت عمري يا حبيبي يا حبيبي", false},
		{"纯英文", "[00:01.00]I'll be there for you", false},
	}
	for _, c := range cases {
		if got := hasWorldReadingScript(c.lyrics); got != c.want {
			t.Errorf("%s: hasWorldReadingScript = %v, want %v", c.name, got, c.want)
		}
	}
	e := enrichEntry{Lyrics: bt(thaiLine)}
	if !e.shouldGenerateHelperRoma() {
		t.Error("没有读音的泰语歌解析时应交给 helper 出读音")
	}
	e.LyricsRoma = bt("[00:01.00]wan thi")
	if e.shouldGenerateHelperRoma() {
		t.Error("已有读音的泰语歌不覆盖")
	}
}

func TestIsWorldRomaCandidate(t *testing.T) {
	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"没有读音的泰语歌", enrichEntry{Lyrics: bt(thaiLine)}, true},
		{"已有读音", enrichEntry{Lyrics: bt(thaiLine), LyricsRoma: bt("[00:01.00]wan")}, false},
		{"用户手改过", enrichEntry{Lyrics: bt(thaiLine), ManualLyrics: true}, false},
		{"粤语歌", enrichEntry{Lyrics: bt(thaiLine), SongLanguage: songLanguageCantonese}, false},
		{"日文歌(归另外两道迁移)", enrichEntry{Lyrics: bt("[00:01.00]君の名は")}, false},
		{"没有正文", enrichEntry{}, false},
	}
	for _, c := range cases {
		if got := isWorldRomaCandidate(c.e); got != c.want {
			t.Errorf("%s: isWorldRomaCandidate = %v, want %v", c.name, got, c.want)
		}
	}
}

func withWorldRomaFixture(t *testing.T, entries map[string]enrichEntry, gen func(lyrics, kana string) (string, error)) {
	t.Helper()
	withTempLeanCache(t)
	saved := worldRomaGenerator
	savedState, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() {
		worldRomaGenerator = saved
		migrationState, migrationStatePath = savedState, savedPath
	})
	loadMigrationState(filepath.Join(t.TempDir(), "migrations.json"))
	enrichMu.Lock()
	for k, e := range entries {
		enrichCache[k] = e
	}
	enrichMu.Unlock()
	worldRomaGenerator = gen
}

func runWorldRomaBackfill() int {
	return backfillWorldRoma(context.Background(), migrationScopeOf(migrationWorldRoma, migrationWorldRomaVersion))
}

// 没有读音的补上;已有读音的、手改过的不问;helper 回空(这首没什么可注音的)不写;全部问成记水位。
func TestBackfillWorldRomaFillsMissing(t *testing.T) {
	const thai, kept, manual, nothing = "A|thai|X", "A|kept|X", "A|manual|X", "A|nothing|X"
	asked := 0
	withWorldRomaFixture(t, map[string]enrichEntry{
		thai:    {Lyrics: bt(thaiLine)},
		kept:    {Lyrics: bt(thaiLine), LyricsRoma: bt("[00:01.00]source")},
		manual:  {Lyrics: bt(thaiLine), ManualLyrics: true},
		nothing: {Lyrics: bt("[00:01.00]Ты танцуешь, будто сумасшедшая")},
	}, func(lyrics, kana string) (string, error) {
		asked++
		if lyrics == thaiLine {
			return "[00:01.00]wan thi khao an thoe mai la saita", nil
		}
		return "", nil
	})
	if n := runWorldRomaBackfill(); n != 1 || asked != 2 {
		t.Fatalf("应问 2 条(已有读音、手改过的不问)、补 1 条,实问 %d、补 %d", asked, n)
	}
	if got := enrichCache[thai].LyricsRoma; !got.EqualString("[00:01.00]wan thi khao an thoe mai la saita") {
		t.Errorf("没有读音的应补上,实得 %q", got)
	}
	if got := enrichCache[kept].LyricsRoma; !got.EqualString("[00:01.00]source") {
		t.Errorf("已有读音的不动,实得 %q", got)
	}
	if !enrichCache[nothing].LyricsRoma.IsZero() {
		t.Error("helper 回空的不写")
	}
	if !migrationDone(migrationWorldRoma, migrationWorldRomaVersion) {
		t.Error("全部问成、存成了应记水位")
	}
}

// 找不到 helper:第一条就停、一条不补、不记水位(下次启动再补),不能当成「这首没什么可注音的」。
func TestBackfillWorldRomaStopsWithoutHelper(t *testing.T) {
	asked := 0
	withWorldRomaFixture(t, map[string]enrichEntry{
		"A|one|X": {Lyrics: bt(thaiLine)},
		"A|two|X": {Lyrics: bt("[00:01.00]Ты танцуешь, будто сумасшедшая")},
	}, func(string, string) (string, error) {
		asked++
		return "", errRomanizeHelperMissing
	})
	if n := runWorldRomaBackfill(); n != 0 || asked != 1 {
		t.Fatalf("应只问 1 条就停、一条不补,实问 %d、补 %d", asked, n)
	}
	if migrationDone(migrationWorldRoma, migrationWorldRomaVersion) {
		t.Error("没问成不该记水位")
	}
}

// 问 helper 的途中条目被改了(重评分换了正文、别处补了读音):写回时不动。
func TestBackfillWorldRomaSkipsChangedEntries(t *testing.T) {
	const key = "A|thai|X"
	withWorldRomaFixture(t, map[string]enrichEntry{key: {Lyrics: bt(thaiLine)}}, func(string, string) (string, error) {
		enrichMu.Lock()
		e := enrichCache[key]
		e.LyricsRoma = bt("[00:01.00]filled elsewhere")
		enrichCache[key] = e
		enrichMu.Unlock()
		return "[00:01.00]wan thi", nil
	})
	if n := runWorldRomaBackfill(); n != 0 {
		t.Fatalf("期间被别处补了读音的不该再写,实补 %d", n)
	}
	if got := enrichCache[key].LyricsRoma; !got.EqualString("[00:01.00]filled elsewhere") {
		t.Errorf("别处补的读音不该被盖掉,实得 %q", got)
	}
}

// 真的那个生成函数:找不到 helper 要报错(迁移据此不记水位),不能像解析时那样静默当成「这首没什么可注音的」。
func TestWorldRomaGeneratorReportsMissingHelper(t *testing.T) {
	saved := lyricsRomanizeBin
	t.Cleanup(func() { lyricsRomanizeBin = saved })
	lyricsRomanizeBin = func() (string, error) { return filepath.Join(t.TempDir(), "lyrics-romanize"), nil }
	if _, err := worldRomaGenerator(thaiLine, ""); !errors.Is(err, errRomanizeHelperMissing) {
		t.Errorf("找不到 helper 应报 errRomanizeHelperMissing,实得 %v", err)
	}
}

func TestWorldRomaFromReply(t *testing.T) {
	if roma, err := worldRomaFromReply(romanizeReply{OK: true, Roma: "[00:01.00]x", WorldReadings: migrationWorldRomaVersion}); roma != "[00:01.00]x" || err != nil {
		t.Errorf("新 helper 出了读音:交回,实得 %q, %v", roma, err)
	}
	if roma, err := worldRomaFromReply(romanizeReply{OK: false, Reason: "no-romanization", WorldReadings: migrationWorldRomaVersion}); roma != "" || err != nil {
		t.Errorf("新 helper 说没什么可注音的:空串、不是错误,实得 %q, %v", roma, err)
	}
	if _, err := worldRomaFromReply(romanizeReply{OK: false, Reason: "no-romanization"}); !errors.Is(err, errWorldReadingsUnsupported) {
		t.Errorf("旧 helper(不带 world_readings)应报 errWorldReadingsUnsupported,实得 %v", err)
	}
	old := romanizeReply{OK: false, Reason: "no-romanization", WorldReadings: migrationWorldRomaVersion - 1}
	if _, err := worldRomaFromReply(old); !errors.Is(err, errWorldReadingsUnsupported) {
		t.Errorf("world_readings 比引擎旧(还不会出新加的文字)应报 errWorldReadingsUnsupported,实得 %v", err)
	}
}

// helper 比引擎旧:第一条就停、一条不补、不记水位(换上新 helper 后下次启动再补)。
func TestBackfillWorldRomaStopsOnOldHelper(t *testing.T) {
	asked := 0
	withWorldRomaFixture(t, map[string]enrichEntry{
		"A|one|X": {Lyrics: bt(thaiLine)},
		"A|two|X": {Lyrics: bt("[00:01.00]Ты танцуешь, будто сумасшедшая")},
	}, func(string, string) (string, error) {
		asked++
		return "", errWorldReadingsUnsupported
	})
	if n := runWorldRomaBackfill(); n != 0 || asked != 1 {
		t.Fatalf("应只问 1 条就停、一条不补,实问 %d、补 %d", asked, n)
	}
	if migrationDone(migrationWorldRoma, migrationWorldRomaVersion) {
		t.Error("旧 helper 时不该记水位")
	}
}
