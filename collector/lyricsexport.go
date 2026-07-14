// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"os"
	"path/filepath"
	"strings"
)

// lyricsDir is set once in main.go alongside enrichPath. Empty means exports
// are disabled (e.g. flag not initialized yet, or path resolution failed).
var lyricsDir string

// exportLyricsFiles writes/updates a standalone .lrc file per entry that
// currently has lyrics, one level outside enrichCache. This function itself
// only ever writes/updates, never deletes — it's a full sweep over whatever
// is currently in enrichCache, so an entry that's gone (deleted) from the
// cache is simply absent from this sweep, not actively cleaned up here.
//
// 2026-07-14: deleting an entry via desktop-lyrics's 歌词管理 window USED TO
// leave the already-exported file untouched on disk (deliberately, at the
// time — the whole point was a durable archive independent of the cache
// entry's lifecycle). The user later found that reversal counterintuitive:
// deleting in 歌词管理 should really delete, not leave a copy the user
// doesn't know still exists. So EnrichCacheStore.delete() (Swift side) now
// separately removes the corresponding .lrc file itself, right after
// removing the cache entry — this Go-side sweep function was NOT changed to
// do that (it has no concept of "this key was just explicitly deleted" vs.
// "this key never existed"), the deletion-cleanup responsibility lives
// entirely in Swift. Content-identical files are skipped here (read-then-
// compare) so a full sweep on every save doesn't needlessly touch mtimes for
// the vast majority of unchanged entries.
func exportLyricsFiles() {
	if lyricsDir == "" {
		return
	}
	enrichMu.Lock()
	type job struct{ key, lyrics string }
	jobs := make([]job, 0, len(enrichCache))
	for key, e := range enrichCache {
		if e.Lyrics != "" {
			jobs = append(jobs, job{key, e.Lyrics})
		}
	}
	enrichMu.Unlock()
	if len(jobs) == 0 {
		return
	}
	if err := os.MkdirAll(lyricsDir, 0o755); err != nil {
		return
	}
	for _, j := range jobs {
		path := filepath.Join(lyricsDir, sanitizeLyricsFilename(j.key)+".lrc")
		if existing, err := os.ReadFile(path); err == nil && string(existing) == j.lyrics {
			continue
		}
		_ = os.WriteFile(path, []byte(j.lyrics), 0o644)
	}
}

// sanitizeLyricsFilename turns a "艺人|歌名|专辑" cache key into a safe,
// readable filename: "|" becomes " - ", then filesystem-unsafe characters are
// replaced with "_". Collisions (rare — e.g. two different albums having a
// same-named track with an empty album field on both) simply overwrite each
// other; not worth a disambiguation scheme for a personal archive folder.
func sanitizeLyricsFilename(key string) string {
	name := strings.ReplaceAll(key, "|", " - ")
	for _, c := range []string{"/", ":", "*", "?", "\"", "<", ">", "\\"} {
		name = strings.ReplaceAll(name, c, "_")
	}
	return strings.TrimSpace(name)
}
