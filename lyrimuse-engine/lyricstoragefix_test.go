package main

import (
	"path/filepath"
	"testing"
)

func withTempMigrationState(t *testing.T) {
	t.Helper()
	migrationStateMu.Lock()
	saved, savedPath := migrationState, migrationStatePath
	savedRecheck, savedRecheckKeys := migrationRecheck, migrationRecheckKeys
	migrationStateMu.Unlock()
	t.Cleanup(func() {
		migrationStateMu.Lock()
		migrationState, migrationStatePath = saved, savedPath
		migrationRecheck, migrationRecheckKeys = savedRecheck, savedRecheckKeys
		migrationStateMu.Unlock()
	})
	loadMigrationState(filepath.Join(t.TempDir(), "migrations.json"))
}

// 实体解码:非法码位解出替换字符的原样留着。
func TestDecodeLyricEntitiesKeepsInvalidCodePoints(t *testing.T) {
	cases := map[string]string{
		"a&#0;b":       "a&#0;b",
		"a&#xD800;b":   "a&#xD800;b",
		"they&apos;re": "they're",
		"&#xFFFD;":     "&#xFFFD;",
	}
	for in, want := range cases {
		if got := decodeLyricEntities(in); got != want {
			t.Errorf("decodeLyricEntities(%q) = %q, want %q", in, got, want)
		}
	}
}

// 实体迁移第一遍就把多层转义解到底;水位作废(恢复备份、切换歌词目录)之后全库重跑,解过的正文不再变。
func TestMigrateLyricEntitiesStableAcrossInvalidation(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	enrichMu.Lock()
	enrichPath = ""
	enrichCache["a|t|b"] = enrichEntry{Lyrics: "[00:01.00]they&amp;apos;re"}
	enrichMu.Unlock()
	migrateLyricEntities()
	if got := enrichCache["a|t|b"].Lyrics; got != "[00:01.00]they're" {
		t.Fatalf("第一遍解到底: %q", got)
	}
	invalidateMigrationState("test")
	migrateLyricEntities()
	if got := enrichCache["a|t|b"].Lyrics; got != "[00:01.00]they're" {
		t.Fatalf("水位作废之后重跑,正文不再变: %q", got)
	}
}

// QRC 残缺词条:原地修得好的修,修完还剩两数字词条的清掉逐字等重取;手改的、校准过的不动。
func TestMigrateQRCLeftoverTokensDropsUnrecoverable(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	savedPins := lyricsPinsPath
	lyricsPinsPath = ""
	t.Cleanup(func() { lyricsPinsPath = savedPins })
	fixable := "[0,1000](0,500,0)Say(500,200,0) ((700,100)"
	broken := "[0,1000][(10632,5159,0)Verse 1](15791,14119)"
	good := "[0,1000](0,500,0)Hi"
	kana := "[kana:(0,100)あ]\n[0,1000](0,500,0)Hi"
	enrichMu.Lock()
	enrichPath = ""
	enrichCache["a|fix|b"] = enrichEntry{Lyrics: "x", LyricsYRC: fixable}
	enrichCache["a|broken|b"] = enrichEntry{Lyrics: "x", LyricsYRC: broken, LyricsBG: "bg"}
	enrichCache["a|manual|b"] = enrichEntry{Lyrics: "x", LyricsYRC: broken, ManualLyrics: true}
	enrichCache["a|good|b"] = enrichEntry{Lyrics: "x", LyricsYRC: good}
	enrichCache["a|kana|b"] = enrichEntry{Lyrics: "x", LyricsYRC: kana}
	enrichMu.Unlock()
	migrateQRCLeftoverTokens()
	if got := enrichCache["a|fix|b"].LyricsYRC; yrcHasTwoNumberTokens(got) || got == fixable {
		t.Errorf("修得好的应当修好: %q", got)
	}
	if e := enrichCache["a|broken|b"]; e.LyricsYRC != "" || e.LyricsBG != "" {
		t.Errorf("修不好的应当清掉逐字和背景人声: %+v", e)
	}
	if enrichCache["a|manual|b"].LyricsYRC != broken {
		t.Error("手改过的不动")
	}
	if enrichCache["a|good|b"].LyricsYRC != good || enrichCache["a|kana|b"].LyricsYRC != kana {
		t.Error("正常的逐字、假名标注行不动")
	}
}
