package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsLegacyKoreanRomaCandidate(t *testing.T) {
	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"有罗马音的韩文歌", enrichEntry{Lyrics: "[00:01.00]사랑해", LyricsRoma: "[00:01.00]salanghae"}, true},
		{"用户手改过", enrichEntry{Lyrics: "[00:01.00]사랑해", LyricsRoma: "[00:01.00]salanghae", ManualLyrics: true}, false},
		{"没有罗马音", enrichEntry{Lyrics: "[00:01.00]사랑해"}, false},
		{"正文没有谚文", enrichEntry{Lyrics: "[00:01.00]君の名は", LyricsRoma: "[00:01.00]kimi no na wa"}, false},
		{"没有正文", enrichEntry{LyricsRoma: "[00:01.00]salanghae"}, false},
	}
	for _, c := range cases {
		if got := isLegacyKoreanRomaCandidate(c.e); got != c.want {
			t.Errorf("%s: isLegacyKoreanRomaCandidate = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestLegacyRomaFromReply(t *testing.T) {
	if roma, err := legacyRomaFromReply(romanizeReply{OK: true, Roma: "[00:01.00]saranghae", LegacyChecked: true}); roma != "[00:01.00]saranghae" || err != nil {
		t.Errorf("判过是旧版:应交回新罗马音,实得 %q, %v", roma, err)
	}
	if roma, err := legacyRomaFromReply(romanizeReply{OK: false, Reason: "not-legacy"}); roma != "" || err != nil {
		t.Errorf("不是旧版:空串、不是错误,实得 %q, %v", roma, err)
	}
	// 比引擎旧的 helper 不认 legacy_korean_roma,照常回一份罗马音:不能拿它去换歌词源给的读音。
	if roma, err := legacyRomaFromReply(romanizeReply{OK: true, Roma: "[00:01.00]salanghae"}); roma != "" || !errors.Is(err, errLegacyCheckUnsupported) {
		t.Errorf("没带 legacy_checked:应报 errLegacyCheckUnsupported,实得 %q, %v", roma, err)
	}
}

// 入参名、回包标记在 Go 和 lyrics-romanize 两边各写一份,改一边另一边就静默失配(迁移永远判「helper 没判」)。
func TestLyricsRomanizeHelperKeysMatchSwift(t *testing.T) {
	src, err := os.ReadFile("../lyrimuse/Sources/lyrics-romanize/main.swift")
	if err != nil {
		t.Fatal(err)
	}
	for _, lit := range []string{`case legacyKoreanRoma = "legacy_korean_roma"`, `case legacyChecked = "legacy_checked"`} {
		if !strings.Contains(string(src), lit) {
			t.Errorf("lyrics-romanize/main.swift 里找不到 %s —— 改了键名,romanize.go 的 romanizeRequest / romanizeReply 要同步", lit)
		}
	}
}

// withLegacyKoreanRomaFixture 换成临时缓存(保存真写到临时目录)、换掉 helper 和水位文件,测完还原。
func withLegacyKoreanRomaFixture(t *testing.T, entries map[string]enrichEntry,
	regen func(lyrics, stored string) (string, error)) {
	t.Helper()
	withTempLeanCache(t)
	savedRegen := legacyKoreanRomaRegenerator
	savedState, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() {
		legacyKoreanRomaRegenerator = savedRegen
		migrationState, migrationStatePath = savedState, savedPath
	})
	loadMigrationState(filepath.Join(t.TempDir(), "migrations.json"))
	enrichMu.Lock()
	for k, e := range entries {
		enrichCache[k] = e
	}
	enrichMu.Unlock()
	legacyKoreanRomaRegenerator = regen
}

func runLegacyKoreanRomaMigration(ctx context.Context) int {
	return migrateLegacyKoreanRoma(ctx, migrationScopeOf(migrationLegacyKoreanRoma, migrationLegacyKoreanRomaVersion))
}

func legacyKoreanRomaMarked() bool {
	return migrationDone(migrationLegacyKoreanRoma, migrationLegacyKoreanRomaVersion)
}

func TestMigrateLegacyKoreanRomaReplacesOnlyOurs(t *testing.T) {
	const ours, source, edited, manual = "A|ours|X", "A|source|X", "A|edited|X", "A|manual|X"
	asked := 0
	withLegacyKoreanRomaFixture(t, map[string]enrichEntry{
		ours:   {Lyrics: "[00:01.00]사랑해", LyricsRoma: "[00:01.00]salanghae"},
		source: {Lyrics: "[00:01.00]사랑해", LyricsRoma: "[00:01.00]sa rang hae"},
		edited: {Lyrics: "[00:01.00]같이", LyricsRoma: "[00:01.00]gat-i"},
		manual: {Lyrics: "[00:01.00]사랑해\n[00:02.00]같이", LyricsRoma: "[00:01.00]salanghae\n[00:02.00]ga chi", ManualLyrics: true},
	}, func(lyrics, stored string) (string, error) {
		asked++
		switch stored {
		case "[00:01.00]salanghae":
			return "[00:01.00]saranghae", nil
		case "[00:01.00]gat-i":
			// helper 跑着的时候这一条被手改了:写回时要放弃,不能拿算好的盖掉。
			enrichMu.Lock()
			e := enrichCache[edited]
			e.LyricsRoma = "[00:01.00]ga chi"
			enrichCache[edited] = e
			enrichMu.Unlock()
			return "[00:01.00]gachi", nil
		}
		return "", nil
	})

	if n := runLegacyKoreanRomaMigration(context.Background()); n != 1 || asked != 3 {
		t.Fatalf("应问 3 条(手改过的那条不问)、换 1 条,实问 %d、换 %d", asked, n)
	}
	if got := enrichCache[ours].LyricsRoma; got != "[00:01.00]saranghae" {
		t.Errorf("我们旧版生成的那份应换成按读音的,实得 %q", got)
	}
	if got := enrichCache[source].LyricsRoma; got != "[00:01.00]sa rang hae" {
		t.Errorf("歌词源给的不动,实得 %q", got)
	}
	if got := enrichCache[edited].LyricsRoma; got != "[00:01.00]ga chi" {
		t.Errorf("期间被改过的不动,实得 %q", got)
	}
	if got := enrichCache[manual].LyricsRoma; got != "[00:01.00]salanghae\n[00:02.00]ga chi" {
		t.Errorf("用户手改过的整条不动,实得 %q", got)
	}
	if !legacyKoreanRomaMarked() {
		t.Error("全部问成、存成了应记水位")
	}
}

// helper 找不到、或比引擎旧(不认 legacy_korean_roma):一条都不换、不记水位,而且第一条失败就停,不再一条条白问。
func TestMigrateLegacyKoreanRomaStopsOnUnusableHelper(t *testing.T) {
	for _, helperErr := range []error{errRomanizeHelperMissing, errLegacyCheckUnsupported} {
		asked := 0
		withLegacyKoreanRomaFixture(t, map[string]enrichEntry{
			"A|one|X": {Lyrics: "[00:01.00]사랑해", LyricsRoma: "[00:01.00]sa rang hae"},
			"A|two|X": {Lyrics: "[00:01.00]같이", LyricsRoma: "[00:01.00]ga chi"},
		}, func(string, string) (string, error) {
			asked++
			return "", helperErr
		})
		if n := runLegacyKoreanRomaMigration(context.Background()); n != 0 || asked != 1 {
			t.Errorf("%v: 应问 1 条就停、一条不换,实问 %d、换 %d", helperErr, asked, n)
		}
		if enrichCache["A|one|X"].LyricsRoma != "[00:01.00]sa rang hae" || enrichCache["A|two|X"].LyricsRoma != "[00:01.00]ga chi" {
			t.Errorf("%v: 原样保留", helperErr)
		}
		if legacyKoreanRomaMarked() {
			t.Errorf("%v: 不能记水位,否则装好 helper 之后也不会再跑", helperErr)
		}
	}
}

// 换完没存成:换好的留在内存里等下一次保存,水位不记(进程在存成之前没了,下次启动再核一遍)。
func TestMigrateLegacyKoreanRomaKeepsWatermarkWhenSaveFails(t *testing.T) {
	const key = "A|ours|X"
	withLegacyKoreanRomaFixture(t, map[string]enrichEntry{
		key: {Lyrics: "[00:01.00]사랑해", LyricsRoma: "[00:01.00]salanghae"},
	}, func(string, string) (string, error) { return "[00:01.00]saranghae", nil })
	ro := t.TempDir()
	if err := os.Chmod(ro, 0o500); err != nil { // 只读目录:临时文件建不出来
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(ro, 0o700) })
	enrichMu.Lock()
	enrichPath = filepath.Join(ro, "cache.json")
	enrichMu.Unlock()

	if n := runLegacyKoreanRomaMigration(context.Background()); n != 1 {
		t.Fatalf("内存里照常换,实换 %d", n)
	}
	enrichMu.Lock()
	roma, dirty := enrichCache[key].LyricsRoma, enrichDirty
	enrichMu.Unlock()
	if roma != "[00:01.00]saranghae" || !dirty {
		t.Errorf("换好的留在内存里、脏标记在,等下一次保存:roma=%q dirty=%v", roma, dirty)
	}
	if legacyKoreanRomaMarked() {
		t.Error("没存成不能记水位")
	}
}

func TestMigrateLegacyKoreanRomaStopsOnCancel(t *testing.T) {
	asked := 0
	withLegacyKoreanRomaFixture(t, map[string]enrichEntry{
		"A|ours|X": {Lyrics: "[00:01.00]사랑해", LyricsRoma: "[00:01.00]salanghae"},
	}, func(string, string) (string, error) {
		asked++
		return "", errors.New("unreachable")
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	runLegacyKoreanRomaMigration(ctx)
	if asked != 0 || legacyKoreanRomaMarked() {
		t.Errorf("收到退出信号就停、不记水位,实问 %d 条", asked)
	}
}
