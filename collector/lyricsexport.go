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

// exportLyricsFiles writes/updates a standalone .lrc file per cached song that
// currently has lyrics, one level outside enrichCache's own lifecycle — the
// 30-day TTL refresh, the 3000-entry eviction, and manual deletes in
// desktop-lyrics's 歌词管理 all only ever touch enrichCache/enrich-cache.json,
// never these exported files. Only ever writes/updates, never deletes: even
// if a cache entry is later evicted, re-resolved differently, or explicitly
// deleted by the user, whatever was exported here stays on disk untouched,
// which is the entire point — a durable local archive the user can browse in
// Finder, independent of the cache's own churn. Content-identical files are
// skipped (read-then-compare) so a full sweep on every save doesn't needlessly
// touch mtimes for the vast majority of unchanged entries.
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
