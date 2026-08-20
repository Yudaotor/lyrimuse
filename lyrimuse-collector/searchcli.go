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
// Prints one JSON object line (NDJSON, via repeated json.Encoder.Encode calls on the
// same stdout — each call already appends its own newline) per update instead of a
// single array at the end: the first line lands as soon as the first source answers,
// each later line is the full best-known-so-far ranked list including whichever
// sources have answered by then (see fetchScoredLyricCandidatesStreaming's onUpdate
// comment for why it's the whole list every time, not just the newly-arrived source),
// and the last line printed is the final result. Each line is a searchLyricsUpdate —
// not a bare candidates array (2026-08-02 changed from bare array to this wrapper) —
// so the networkLooksDown signal can ride along with the candidates without a second,
// out-of-band channel. LyricsSearchService.swift reads stdout line by line as the
// process runs (not just at exit) and replaces its displayed list with each line's
// contents — that's the "陆陆续续出来" behavior instead of waiting for everything (or
// the 20s deadline) before showing anything. Never touches enrich-cache.json (that only
// happens if/when desktop-lyrics's existing EnrichCacheStore.saveEdit persists whichever
// candidate the user picks).
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
		// 同理,MusicBrainz 的歌手别名缓存也得自己加载一遍。2026-08-15 起
		// retryArtistIdentities 会在没查到可用候选时拿 canonical 名再搜一次,而
		// artistAliasPath 为空的话这份缓存既不读也不写 —— 每开一次"搜索候选歌词"
		// 弹窗都要重新打一次 MusicBrainz(它自己还有节流,直接体现为用户多等)。
		loadArtistAliasCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-artist-alias-cache.json"))
		// 同理,MB 主名那份也要读 —— 这条 CLI 每次都是新进程,不读的话每开一次弹窗都要
		// 重打一次 MusicBrainz,撞上限速(1 req/s 按 IP,而节流是进程内的)就等于这轮
		// 别名兜底整个失效:表现是"同一首歌第一遍搜 0 条、再搜一遍就有"。
		loadMBPrimaryNameCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-artist-primary-cache.json"))
	}

	// 跟 enrich.go 的 resolveTrackEnrichment 同一个理由:NetEase/QQ/酷狗/LRCLIB 的
	// 搜索索引是简体中文,本地 Apple Music 标签若是繁体(比如"周杰倫"),繁体原文直接
	// 发起搜索请求会查不到任何候选——这个 CLI 子命令是 desktop-lyrics"联网搜索候选
	// 歌词"功能唯一的数据来源,不经过 resolveTrackEnrichment,必须单独转换一遍,不能
	// 指望那边的修复覆盖到这里。
	sArtist, sTitle, sAlbum := toSimplified(*artist), toSimplified(*title), toSimplified(*album)
	enc := json.NewEncoder(os.Stdout)
	var appleTitle, appleAlbum string
	emit := func(_ neteaseInfo, results []scoredLyricCandidateResult, done, total int) {
		// networkLooksDown() 2026-08-02 补上——之前每行 stdout 只是候选数组本身,五个源
		// 都没查到时 desktop-lyrics 只能显示一句笼统的"都没找到",分不清是这首歌真的没有
		// 网络歌词,还是网络整体不通导致五个源的请求全部发不出去。见 networkobs.go 的
		// 注释,这里额外带上这个信号,让前端能区分这两种情况、给出不同的提示文案。
		update := searchLyricsUpdate{
			Candidates:       filterEnabledLyricSources(results),
			NetworkLooksDown: networkLooksDown(),
			SourcesDone:      done,
			SourcesTotal:     total,
			AppleTitle:       appleTitle,
			AppleAlbum:       appleAlbum,
		}
		for _, r := range results {
			if r.Instrumental {
				update.LrclibInstrumental = true
			}
		}
		if err := enc.Encode(update); err != nil {
			log.Fatalf("search-lyrics: encode results: %v", err)
		}
	}
	_, results := scoredLyricCandidatesStreaming(sArtist, sTitle, sAlbum, *duration, emit)
	// 苹果侧元数据:搜索里的 applecover goroutine 用同一组关键词查过、通常已写热
	// appleURLCache(同 key)。这里**只读缓存**——查无此歌时它不写缓存,真去查会在
	// "这轮搜索结束了"那行之前同步重跑一整轮 CN+US 搜索,把收尾挂住几秒(2026-08-12 审阅);
	// 这两个字段是给下一轮评测攒的数据,缺一次无妨,不值得让用户等。
	appleMatch := appleMusicMatchCachedOnly(sArtist, sTitle, sAlbum)
	appleTitle, appleAlbum = appleMatch.title, appleMatch.album
	// 保底再打印一次最终结果——通常这跟 emit 在最后一个源到达时已经打过的那一行内容
	// 完全一样(纯防御性的重复),唯一真正需要它的场景是:20 秒兜底超时在第一个源都还
	// 没回来时就已经触发(五个源全部异常缓慢),这种极端情况下循环里的 emit 一次都没
	// 被调用过,不能让 Swift 那边一行 stdout 都收不到、误判成"进程没有任何输出"。
	// 这一行代表"这轮搜索结束了",所以进度直接报满 —— 即便是 20 秒兜底超时提前收场,
	// 也不该让弹窗停在 3/5 让人以为还在查(真正"还在查"由进程是否退出决定,见 Swift 侧)。
	emit(neteaseInfo{}, results, enabledLyricSourceCount(), enabledLyricSourceCount())
}

// searchLyricsUpdate 是 search-lyrics 每行 stdout 输出的实际结构——2026-08-02 从裸
// candidates 数组改成这个包一层的对象,好让 networkLooksDown 这个信号跟候选列表一起
// 传给 Swift 那边,不用另开一条带外的信息通道。字段名用大写导出是 encoding/json
// 序列化的要求,LyricsSearchService.swift 那边按同样的字段名(小写开头,Swift 惯例)
// 解码。
type searchLyricsUpdate struct {
	Candidates       []scoredLyricCandidateResult `json:"candidates"`
	NetworkLooksDown bool                         `json:"networkLooksDown"`
	// 歌词源的完成进度,给弹窗显示 (X/Y)——语义见 lyricSearchUpdateFunc 的注释。
	SourcesDone  int `json:"sourcesDone"`
	SourcesTotal int `json:"sourcesTotal"`
	// 2026-08-12 起的透传字段,给下一轮打分维度评测攒数据(Swift 端不认识就忽略,无影响):
	// AppleTitle/AppleAlbum:iTunes(第六方,不与五歌词源共享曲库)匹配到的歌名/专辑名,
	// 只在最终那行输出上带(拿的是搜索过程中 applecover goroutine 已写热的同 key 缓存,
	// 不多打网络);LrclibInstrumental:lrclib 明确说这首歌是纯音乐(独立字段,不再只靠
	// Score:-1 哨兵行传递,消费端能与普通 reject 可靠区分)。
	AppleTitle         string `json:"appleTitle,omitempty"`
	AppleAlbum         string `json:"appleAlbum,omitempty"`
	LrclibInstrumental bool   `json:"lrclibInstrumental,omitempty"`
}

// filterEnabledLyricSources drops candidates from sources the user disabled via
// the "歌词"设置's "歌词来源" toggles (features.LyricsSources) — mirrors
// pickLyricCandidate's filtering for the automatic resolve path, so manual search
// and automatic resolve now agree on which sources are in play. Falls back to
// returning everything unfiltered only if features.LyricsSources somehow ended up
// empty (should not happen in practice — loadFeatureFlags always resolves it to
// all-four-enabled when unset, see resolveLyricsSources — this is just a safety
// net against showing zero candidates instead of trusting a genuinely-empty map).
//
// 顺带把 Instrumental 标记条目也过滤掉(2026-08-03 补上)——那不是一条真的候选歌词,
// 是"lrclib 说这首歌是纯音乐"这个信号借 scored 列表搭车传出来的(见
// scoredLyricCandidateResult.Instrumental 定义处的注释),"歌词管理"的手动搜索弹窗
// 只该看到真正可以点选采用的候选,不该多出一行歌词是空的、点了也没用的候选。
func filterEnabledLyricSources(results []scoredLyricCandidateResult) []scoredLyricCandidateResult {
	filtered := make([]scoredLyricCandidateResult, 0, len(results))
	for _, r := range results {
		if r.Instrumental {
			continue
		}
		if len(features.LyricsSources) > 0 && !features.LyricsSources[r.Source] {
			continue
		}
		filtered = append(filtered, r)
	}
	return filtered
}
