package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// 歌词文件夹里改过的一条:同步开着时按手改处理,同一首歌的其他写法跟上;同步关着、从快照恢复时只改这一条。
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
				"A|Song|One":   {Song: "s_000000000001", Lyrics: auto, LyricsSource: "qq"},
				"A|Song|Two":   {Song: "s_000000000001", Lyrics: auto, LyricsSource: "qq"},
				"A|Song|Three": {Song: "s_000000000001", SongShare: 1, Lyrics: songShareLRC("other"), LyricsSource: "kugou"},
				"B|Other|One":  {Song: "s_000000000002", Lyrics: auto, LyricsSource: "qq"},
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
			if !strings.Contains(one.Lyrics, "mine") {
				t.Fatalf("改过的文件要读进来: %q", one.Lyrics)
			}
			if one.ManualLyrics != c.synced {
				t.Errorf("同步开着才按手改处理: manual=%v", one.ManualLyrics)
			}
			for _, k := range []string{"A|Song|Two", "A|Song|Three"} {
				got, _ := cacheEntry(t, k)
				if follows := got.Lyrics == one.Lyrics && got.LyricsEntityOrigin == "A|Song|One"; follows != c.synced {
					t.Errorf("%s 跟上手改: %v (%+v)", k, follows, got)
				}
			}
			if got, _ := cacheEntry(t, "B|Other|One"); got.Lyrics != auto {
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
