package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsStaleRomaCandidate(t *testing.T) {
	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"有读音的日文歌", enrichEntry{Lyrics: bt("[00:01.00]君の名は"), LyricsRoma: bt("[00:01.00]kimi no na wa")}, true},
		{"有读音的中文歌", enrichEntry{Lyrics: bt("[00:01.00]我爱你"), LyricsRoma: bt("[00:01.00]wǒ ài nǐ")}, true},
		{"用户手改过", enrichEntry{Lyrics: bt("[00:01.00]君の名は"), LyricsRoma: bt("[00:01.00]kimi"), ManualLyrics: true}, false},
		{"粤语歌只认粤拼", enrichEntry{Lyrics: bt("[00:01.00]我愛你"), LyricsRoma: bt("[00:01.00]ngo5 oi3 nei5"), SongLanguage: songLanguageCantonese}, false},
		{"台语歌不标", enrichEntry{Lyrics: bt("[00:01.00]我愛你"), LyricsRoma: bt("[00:01.00]wǒ"), SongLanguage: songLanguageHokkien}, false},
		{"没有读音", enrichEntry{Lyrics: bt("[00:01.00]君の名は")}, false},
		{"纯英文", enrichEntry{Lyrics: bt("[00:01.00]hello"), LyricsRoma: bt("[00:01.00]hello")}, false},
	}
	for _, c := range cases {
		if got := isStaleRomaCandidate(c.e); got != c.want {
			t.Errorf("%s: isStaleRomaCandidate = %v, want %v", c.name, got, c.want)
		}
	}
}

func withStaleRomaFixture(t *testing.T, entries map[string]enrichEntry, regen func(lyrics, stored, kana string) (string, error)) {
	t.Helper()
	withTempLeanCache(t)
	savedRegen := staleRomaRegenerator
	savedState, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() {
		staleRomaRegenerator = savedRegen
		migrationState, migrationStatePath = savedState, savedPath
	})
	loadMigrationState(filepath.Join(t.TempDir(), "migrations.json"))
	enrichMu.Lock()
	for k, e := range entries {
		enrichCache[k] = e
	}
	enrichMu.Unlock()
	staleRomaRegenerator = regen
}

func runStaleRomaMigration() int {
	return migrateStaleGeneratedRoma(context.Background(), migrationScopeOf(migrationStaleGeneratedRoma, migrationStaleGeneratedRomaVersion))
}

// helper 判是过时的预生成才换;歌词源给的(helper 回空)、手改过的不动;全部问成记水位。
func TestMigrateStaleGeneratedRomaReplacesOnlyOurs(t *testing.T) {
	const ours, source, manual = "A|ours|X", "A|source|X", "A|manual|X"
	asked := 0
	withStaleRomaFixture(t, map[string]enrichEntry{
		ours:   {Lyrics: bt("[00:01.00]3つ数えて"), LyricsRoma: bt("[00:01.00]3 tsu kazoe te"), LyricsKana: "[kana:1かぞ]\n[00:00.00]3つ数えて"},
		source: {Lyrics: bt("[00:01.00]3つ数えて"), LyricsRoma: bt("[00:01.00]mittsu kazoete")},
		manual: {Lyrics: bt("[00:01.00]3つ数えて"), LyricsRoma: bt("[00:01.00]3 tsu"), ManualLyrics: true},
	}, func(lyrics, stored, kana string) (string, error) {
		asked++
		if stored == "[00:01.00]3 tsu kazoe te" {
			if kana != "[kana:1かぞ]\n[00:00.00]3つ数えて" {
				t.Errorf("重算要带上条目借来的假名标注,实得 %q", kana)
			}
			return "[00:01.00]mittsu kazoe te", nil
		}
		return "", nil
	})
	if n := runStaleRomaMigration(); n != 1 || asked != 2 {
		t.Fatalf("应问 2 条(手改过的不问)、换 1 条,实问 %d、换 %d", asked, n)
	}
	if got := enrichCache[ours].LyricsRoma; !got.EqualString("[00:01.00]mittsu kazoe te") {
		t.Errorf("过时的预生成应换成现算的,实得 %q", got)
	}
	if got := enrichCache[source].LyricsRoma; !got.EqualString("[00:01.00]mittsu kazoete") {
		t.Errorf("歌词源给的不动,实得 %q", got)
	}
	if !migrationDone(migrationStaleGeneratedRoma, migrationStaleGeneratedRomaVersion) {
		t.Error("全部问成、存成了应记水位")
	}
}

// helper 比引擎旧(不认 stale_roma,照常回一份):一条不换、不记水位,第一条就停。
func TestMigrateStaleGeneratedRomaStopsOnOldHelper(t *testing.T) {
	asked := 0
	withStaleRomaFixture(t, map[string]enrichEntry{
		"A|one|X": {Lyrics: bt("[00:01.00]君の名は"), LyricsRoma: bt("[00:01.00]kimi no na ha")},
		"A|two|X": {Lyrics: bt("[00:01.00]我爱你"), LyricsRoma: bt("[00:01.00]wo ai ni")},
	}, func(string, string, string) (string, error) {
		asked++
		return "", errStaleCheckUnsupported
	})
	if n := runStaleRomaMigration(); n != 0 || asked != 1 {
		t.Fatalf("应只问 1 条就停、一条不换,实问 %d、换 %d", asked, n)
	}
	if migrationDone(migrationStaleGeneratedRoma, migrationStaleGeneratedRomaVersion) {
		t.Error("没问成不该记水位")
	}
}

func TestStaleRomaFromReply(t *testing.T) {
	if roma, err := staleRomaFromReply(romanizeReply{OK: true, Roma: "[00:01.00]mittsu", StaleChecked: true}); roma != "[00:01.00]mittsu" || err != nil {
		t.Errorf("判过是过时的:交回新读音,实得 %q, %v", roma, err)
	}
	if roma, err := staleRomaFromReply(romanizeReply{OK: false, Reason: "not-stale"}); roma != "" || err != nil {
		t.Errorf("不是过时的:空串、不是错误,实得 %q, %v", roma, err)
	}
	if roma, err := staleRomaFromReply(romanizeReply{OK: true, Roma: "[00:01.00]x"}); roma != "" || !errors.Is(err, errStaleCheckUnsupported) {
		t.Errorf("没带 stale_checked:应报 errStaleCheckUnsupported,实得 %q, %v", roma, err)
	}
}

// 入参名、回包标记两边各写一份;迁移接在常驻进程启动里。
func TestStaleRomaHelperKeysAndWiring(t *testing.T) {
	src, err := os.ReadFile("../lyrimuse/Sources/lyrics-romanize/main.swift")
	if err != nil {
		t.Fatal(err)
	}
	for _, lit := range []string{`case staleRoma = "stale_roma"`, `case staleChecked = "stale_checked"`, `case kanaDonor = "kana_donor"`} {
		if !strings.Contains(string(src), lit) {
			t.Errorf("lyrics-romanize/main.swift 里找不到 %s,romanize.go 的 romanizeRequest / romanizeReply 要同步", lit)
		}
	}
	mainSrc, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(mainSrc), "startStaleGeneratedRomaMigration(ctx)") {
		t.Error("main.go 没接 startStaleGeneratedRomaMigration")
	}
}
