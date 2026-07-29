package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

// runSearchLyricsCLI implements `collector search-lyrics -artist ... -title ...
// -album ... -duration ...`: a one-shot, no-persistent-server way for desktop-lyrics
// to let the user manually re-search lyric candidates for a specific song (its
// "歌词管理" window's "联网搜索候选歌词" feature). It reuses scoredLyricCandidatesStreaming
// (enrich.go) — the exact same NetEase/QQ/酷狗/Musixmatch/LRCLIB fetch-and-score logic the
// normal background auto-resolve path uses — so there is no second, drifting
// implementation of "how do we rank lyric sources" living in Swift.
//
// Prints one JSON array line (NDJSON, via repeated json.Encoder.Encode calls on the
// same stdout — each call already appends its own newline) per update instead of a
// single array at the end: the first line lands as soon as the first source answers,
// each later line is the full best-known-so-far ranked list including whichever
// sources have answered by then (see fetchScoredLyricCandidatesStreaming's onUpdate
// comment for why it's the whole list every time, not just the newly-arrived source),
// and the last line printed is the final result. LyricsSearchService.swift reads stdout line
// by line as the process runs (not just at exit) and replaces its displayed list with
// each line's contents — that's the "陆陆续续出来" behavior instead of waiting for
// everything (or the 20s deadline) before showing anything. Never touches
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

	// main() 的正常启动流程会在这之后才 loadFeatureFlags(...),但这条 CLI 子命令走的是
	// os.Args[1]=="search-lyrics" 的提前分支、马上 return,永远不会执行到那一行——
	// features 这个包级变量在这里还是零值(LyricsSources 是 nil map)。手动搜索要遵循
	// "歌词"设置里的"歌词来源"开关,所以这里必须按跟 main() 完全一致的默认路径规则自己
	// 加载一遍,不然下面过滤时 nil map 对任何 key 取值都是 false,会把五个源全部误判成
	// "没启用"、直接返回空列表。
	home, err := os.UserHomeDir()
	if err == nil {
		cfgPath := filepath.Join(home, ".config", clientName, "config.json")
		features = loadFeatureFlags(filepath.Join(filepath.Dir(cfgPath), clientName+"-features.json"))
	}

	// 跟 enrich.go 的 resolveTrackEnrichment 同一个理由:NetEase/QQ/酷狗/LRCLIB 的
	// 搜索索引是简体中文,本地 Apple Music 标签若是繁体(比如"周杰倫"),繁体原文直接
	// 发起搜索请求会查不到任何候选——这个 CLI 子命令是 desktop-lyrics"联网搜索候选
	// 歌词"功能唯一的数据来源,不经过 resolveTrackEnrichment,必须单独转换一遍,不能
	// 指望那边的修复覆盖到这里。
	sArtist, sTitle, sAlbum := toSimplified(*artist), toSimplified(*title), toSimplified(*album)
	enc := json.NewEncoder(os.Stdout)
	emit := func(_ neteaseInfo, results []scoredLyricCandidateResult) {
		if err := enc.Encode(filterEnabledLyricSources(results)); err != nil {
			log.Fatalf("search-lyrics: encode results: %v", err)
		}
	}
	_, results := scoredLyricCandidatesStreaming(sArtist, sTitle, sAlbum, *duration, emit)
	// 保底再打印一次最终结果——通常这跟 emit 在最后一个源到达时已经打过的那一行内容
	// 完全一样(纯防御性的重复),唯一真正需要它的场景是:20 秒兜底超时在第一个源都还
	// 没回来时就已经触发(五个源全部异常缓慢),这种极端情况下循环里的 emit 一次都没
	// 被调用过,不能让 Swift 那边一行 stdout 都收不到、误判成"进程没有任何输出"。
	emit(neteaseInfo{}, results)
}

// filterEnabledLyricSources drops candidates from sources the user disabled via
// the "歌词"设置's "歌词来源" toggles (features.LyricsSources) — mirrors
// pickLyricCandidate's filtering for the automatic resolve path, so manual search
// and automatic resolve now agree on which sources are in play. Falls back to
// returning everything unfiltered only if features.LyricsSources somehow ended up
// empty (should not happen in practice — loadFeatureFlags always resolves it to
// all-four-enabled when unset, see resolveLyricsSources — this is just a safety
// net against showing zero candidates instead of trusting a genuinely-empty map).
func filterEnabledLyricSources(results []scoredLyricCandidateResult) []scoredLyricCandidateResult {
	if len(features.LyricsSources) == 0 {
		return results
	}
	filtered := make([]scoredLyricCandidateResult, 0, len(results))
	for _, r := range results {
		if features.LyricsSources[r.Source] {
			filtered = append(filtered, r)
		}
	}
	return filtered
}
