package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// 歌词文件夹里改过的一条:同步开着时按手改处理,同一个共享组的写法跟上(别的共享组不跟,18 章决策 58);同步关着、从快照恢复时
// 只改这一条。
func TestImportedEditSyncsToSong(t *testing.T) {
	for _, c := range []struct {
		name    string
		sharing bool
		restore bool
		synced  bool
	}{
		{"同步开着", true, false, true},
		{"同步关着", false, false, false},
		{"从快照恢复", true, true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			auto := songShareLRC("auto")
			setUpSongShareTest(t, map[string]enrichEntry{
				"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
				"A|Song|Two":   {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
				"A|Song|Three": {Song: "s_000000000001", SongShare: 1, Lyrics: bt(songShareLRC("other")), LyricsSource: "kugou"},
				"B|Other|One":  {Song: "s_000000000002", Lyrics: bt(auto), LyricsSource: "qq"},
			}, c.sharing)
			dir := withLyricsFileStateEnv(t)
			exportLyricsFiles()
			resetLyricsFileStateForTest()
			path := filepath.Join(dir, sanitizeLyricsFilename("A|Song|One")+".lrc")
			orig, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			edited := strings.Replace(string(orig), "auto", "mine", 1)
			if edited == string(orig) {
				t.Fatal("没改到正文")
			}
			if err := os.WriteFile(path, []byte(edited), 0o644); err != nil {
				t.Fatal(err)
			}
			future := time.Now().Add(time.Minute)
			_ = os.Chtimes(path, future, future)
			if c.restore {
				enrichMu.Lock()
				lyricsImportRestoreAll = true
				enrichMu.Unlock()
			}
			enrichMu.Lock()
			stamp := enrichEditStampLocked()
			enrichMu.Unlock()
			keys := importLyricsFromFiles()
			enrichMu.Lock()
			twoEdited := enrichEditedSinceLocked("A|Song|Two", stamp)
			enrichMu.Unlock()
			if twoEdited != c.synced {
				t.Errorf("跟着改了的要让在飞的后台任务作废: %v", twoEdited)
			}
			one, _ := cacheEntry(t, "A|Song|One")
			if !strings.Contains(one.Lyrics.String(), "mine") {
				t.Fatalf("改过的文件要读进来: %q", one.Lyrics)
			}
			if one.ManualLyrics != c.synced {
				t.Errorf("同步开着才按手改处理: manual=%v", one.ManualLyrics)
			}
			if got, _ := cacheEntry(t, "A|Song|Two"); (got.Lyrics.Equal(one.Lyrics) && got.LyricsEntityOrigin == "A|Song|One") != c.synced {
				t.Errorf("同一个共享组跟上手改: %+v", got)
			}
			if got, _ := cacheEntry(t, "A|Song|Three"); !got.Lyrics.EqualString(songShareLRC("other")) || got.LyricsEntityOrigin != "" {
				t.Errorf("别的共享组不跟: %+v", got)
			}
			if got, _ := cacheEntry(t, "B|Other|One"); !got.Lyrics.EqualString(auto) {
				t.Errorf("别的歌不动: %q", got.Lyrics)
			}
			if c.synced && !slices.Contains(keys, "A|Song|Two") {
				t.Errorf("跟着改了的要报出来(之后导出、补迁移): %v", keys)
			}
			if c.synced && !hasPre("A|Song|Two") {
				t.Error("跟着改之前留底")
			}
		})
	}
}

// 状态记录作废(记录丢了、记的是别的文件夹)时,文件夹里跟缓存不一样的文件只改这一条,不按手改同步到整首歌。
func TestImportWithoutFileStateDoesNotSync(t *testing.T) {
	for _, c := range []struct {
		name  string
		spoil func(t *testing.T, statePath string)
	}{
		{"记录丢了", func(t *testing.T, p string) {
			if err := os.Remove(p); err != nil {
				t.Fatal(err)
			}
		}},
		{"记录是别的文件夹的", func(t *testing.T, p string) {
			if err := os.WriteFile(p, []byte(`{"dir":"/elsewhere","files":{}}`), 0o600); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			auto := songShareLRC("auto")
			setUpSongShareTest(t, map[string]enrichEntry{
				"A|Song|One": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
				"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
			}, true)
			dir := withLyricsFileStateEnv(t)
			exportLyricsFiles()
			c.spoil(t, lyricsFileStatePath())
			resetLyricsFileStateForTest()
			path := filepath.Join(dir, sanitizeLyricsFilename("A|Song|One")+".lrc")
			orig, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(strings.Replace(string(orig), "auto", "mine", 1)), 0o644); err != nil {
				t.Fatal(err)
			}
			importLyricsFromFiles()
			one, _ := cacheEntry(t, "A|Song|One")
			if !strings.Contains(one.Lyrics.String(), "mine") || one.ManualLyrics {
				t.Errorf("文件照旧赢、但不算手改: manual=%v %q", one.ManualLyrics, one.Lyrics)
			}
			if two, _ := cacheEntry(t, "A|Song|Two"); !two.Lyrics.EqualString(auto) || two.LyricsEntityOrigin != "" || hasPre("A|Song|Two") {
				t.Errorf("同一首歌的其他写法不动: %+v pre=%v", two, hasPre("A|Song|Two"))
			}
		})
	}
}

// 状态记录作废时,文件夹里一条同步副本的文件正是同步之前那份(留底里的):不导入,随后的全量导出按缓存重写。
// 记录有效时同一个文件照旧当成用户改过。
func TestImportSkipsFilesPredatingSongShare(t *testing.T) {
	for _, c := range []struct {
		name    string
		trusted bool
		seed    string
	}{
		{"记录作废", false, "old"},
		{"记录有效", true, "old"},
		{"记录作废、文件不是留底那份", false, "else"},
	} {
		t.Run(c.name, func(t *testing.T) {
			auto, old := songShareLRC("auto"), songShareLRC("old")
			setUpSongShareTest(t, map[string]enrichEntry{
				"A|Song|One": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
				"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
			}, true)
			if _, err := writeSongSharePre("A|Song|Two", enrichEntry{Lyrics: bt(old), LyricsSource: "kugou"}, songOffsetFingerprint(auto, ""), time.Unix(6_000_000, 0)); err != nil {
				t.Fatal(err)
			}
			dir := withLyricsFileStateEnv(t)
			exportLyricsFiles()
			if !c.trusted {
				if err := os.Remove(lyricsFileStatePath()); err != nil {
					t.Fatal(err)
				}
			}
			resetLyricsFileStateForTest()
			path := filepath.Join(dir, sanitizeLyricsFilename("A|Song|Two")+".lrc")
			orig, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			body := songShareLRC(c.seed)
			stale := strings.Replace(string(orig), auto, body, 1)
			if stale == string(orig) {
				t.Fatal("没换成旧正文")
			}
			if err := os.WriteFile(path, []byte(stale), 0o644); err != nil {
				t.Fatal(err)
			}
			future := time.Now().Add(time.Minute)
			_ = os.Chtimes(path, future, future)
			keys := importLyricsFromFiles()
			two, _ := cacheEntry(t, "A|Song|Two")
			if c.trusted {
				if !two.Lyrics.EqualString(old) || !two.ManualLyrics {
					t.Errorf("记录有效时照旧按用户改过处理: manual=%v %q", two.ManualLyrics, two.Lyrics)
				}
				return
			}
			if body != old {
				if !two.Lyrics.EqualString(body) || two.ManualLyrics {
					t.Errorf("跟留底对不上的照旧导入、只改这一条: manual=%v %q", two.ManualLyrics, two.Lyrics)
				}
				return
			}
			if !two.Lyrics.EqualString(auto) || slices.Contains(keys, "A|Song|Two") {
				t.Errorf("旧文件不导入: %q keys=%v", two.Lyrics, keys)
			}
			if one, _ := cacheEntry(t, "A|Song|One"); !one.Lyrics.EqualString(auto) {
				t.Errorf("别的写法不动: %q", one.Lyrics)
			}
			exportLyricsFiles()
			if got, _ := os.ReadFile(path); !strings.Contains(string(got), auto) {
				t.Errorf("导出按缓存重写: %q", got)
			}
		})
	}
}

// 记录丢了的那次启动做完全量导出,记录就描述这个文件夹了:之后再导入(从快照恢复之外)照旧按用户改过同步。
// 切到另一个没有记录的文件夹,又回到作废;切回来读到盘上的记录,照旧有效。
func TestLyricsFileStateTrustAfterExport(t *testing.T) {
	auto := songShareLRC("auto")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
		"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
	}, true)
	dir := withLyricsFileStateEnv(t)
	if lyricsFileStateEnabled(dir); lyricsFileStateTrustedFor(dir) {
		t.Fatal("还没有记录时不算有效")
	}
	exportLyricsFiles()
	if !lyricsFileStateTrustedFor(dir) {
		t.Fatal("全量导出之后记录有效")
	}
	name := sanitizeLyricsFilename("A|Song|One") + ".lrc"
	orig, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(t.TempDir(), "lyrics2")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(other, name), []byte(strings.Replace(string(orig), "auto", "mine", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFromDir(other)
	if two, _ := cacheEntry(t, "A|Song|Two"); !two.Lyrics.EqualString(auto) {
		t.Errorf("新文件夹没有记录,不同步: %q", two.Lyrics)
	}
	if lyricsFileStateEnabled(dir); !lyricsFileStateTrustedFor(dir) {
		t.Error("换回原文件夹,盘上有它的记录,照旧有效")
	}
}
