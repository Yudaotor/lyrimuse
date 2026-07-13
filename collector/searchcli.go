package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
)

// runSearchLyricsCLI implements `collector search-lyrics -artist ... -title ...
// -album ... -duration ...`: a one-shot, no-persistent-server way for desktop-lyrics
// to let the user manually re-search lyric candidates for a specific song (its
// "歌词管理" window's "联网搜索候选歌词" feature). It reuses scoredLyricCandidates
// (enrich.go) — the exact same NetEase/QQ/酷狗/LRCLIB fetch-and-score logic the
// normal background auto-resolve path uses — so there is no second, drifting
// implementation of "how do we rank lyric sources" living in Swift. Prints the
// full ranked candidate list as JSON to stdout and exits; never touches
// enrich-cache.json (that only happens if/when desktop-lyrics's existing
// EnrichCacheStore.saveEdit persists whichever candidate the user picks).
func runSearchLyricsCLI(args []string) {
	fs := flag.NewFlagSet("search-lyrics", flag.ExitOnError)
	artist := fs.String("artist", "", "track artist")
	title := fs.String("title", "", "track title")
	album := fs.String("album", "", "track album")
	duration := fs.Float64("duration", 0, "track duration in seconds (for duration-match scoring)")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("search-lyrics: %v", err)
	}
	if *title == "" {
		fmt.Fprintln(os.Stderr, "search-lyrics: -title is required")
		os.Exit(2)
	}

	ne := neteaseLookup(*artist, *title, *album)
	results := scoredLyricCandidates(ne, *artist, *title, *album, *duration)
	if err := json.NewEncoder(os.Stdout).Encode(results); err != nil {
		log.Fatalf("search-lyrics: encode results: %v", err)
	}
}
