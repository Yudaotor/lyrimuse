package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---- 专辑名回填:播放器没报专辑名时问 Apple 目录这首歌出自哪张专辑(2026-09-08)----
//
// 起因:用户在 YouTube Music 里放王子(Prince)《Why You Wanna Treat Me So Bad?》的 **MV**,网页和上送都
// 没有专辑。两个来源都是空的:MediaSession 报的 album 就是空串;页面 byline 是「王子 • 501万次观看 • 5万 人赞」,
// 只有频道链接、没有 `browse/MPREb` 专辑链接(ytmusicAlbumPatch 无从补起)—— MV 在 YT Music 里是独立的
// 「视频」实体,不挂专辑,同专辑的音频版都带 album「Prince」。用户拍板作为**通用逻辑**加上:任何播放器,只要
// 报上来的专辑名为空,就按「署名 + 曲名 + 时长」去 Apple 目录反查(iTunes Search 公开接口,纯 HTTPS,不依赖
// 本机装 iTunes / Apple Music)。
//
// ⚠️ 回填的只是**呈现 / 上送**用的专辑(snapshot.AlbumHint → relay 网页、Last.fm album、LB release_name、
// 本地收听日志),**绝不进 enrich 缓存 key**:App 侧 EnrichCacheReader 按播放器报的 `artist|title|album` 查歌词,
// 这边若把 album 改掉,两边 key 对不上、App 拿不到词;广告判据 isAdBreak(Spotify 原生 album 为空即广告)、
// 专辑预取、会话 key 也继续看 Album 本身。见 snapshot.albumForUpload。
//
// 两段式:**取候选**一次、**挑**每拍。
//
//   - 取候选(fetchAppleAlbumHintCandidates,后台一次):「署名 曲名」和裸曲名两个查询 × CN / US 两个商店,
//     留下曲名归一后**完全相等**、iTunes 时长在 appleTitleSearchDurationTolerance(max(4s, 3%))内、专辑名非空
//     的结果;再用**一次** lookup(id 可以逗号串起来)把这些专辑的**专辑级发行日期**补上 —— iTunes Search 给的
//     `releaseDate` 是**歌**的首发日期(精选集里的老歌也标 1979),分不出原专辑和精选,专辑自己的日期才行
//     (实测 Prince「Prince」1979-10-19 vs「The Hits/The B-Sides」1993-09-13;Seal「Seal II」1994 vs
//     「Seal: Best 1991-2004」2004)。候选按 key 落盘,查空只记内存、最多试 appleAlbumHintMaxMisses 次 ——
//     但网络不通那一轮的空结果不算查空(fetchAppleAlbumHintCandidatesTracked / appleAlbumHintQueryConcluded)。主查询
//     零候选时把曲名按第一个破折号拆成「署名 - 曲名」再问一次(albumHintTitleSplit,搬运频道把歌手写进曲名的形态)。
//   - 挑(pickAppleAlbumHint,纯函数、单测钉着;每拍从缓存里重挑,零网络):署名分两档 —— 0 档:归一相等,或
//     拆开 credit 后一方是另一方的子集(「Prince」↔「Prince & The Revolution」);1 档:**歌词链路核实过的署名**
//     (lyricResolvedArtists:enrich 条目的 CanonicalArtist,或已采纳歌词决策里胜出候选所报的 artist ——
//     王子 那首 kugou 候选报「Prince」)。两档都不中的一律不采:实测裸按"跨文字系统就认"会把 周杰伦《七里香》
//     配到一位拉丁名艺人的「Jay - Piano Cover (Piano Version)」上 —— 同名同时长的翻唱 / 钢琴版比想象多,
//     必须要旁证。同档内按「非群星合辑 > 非 Single/EP > 非豪华/重制版 > 专辑发行日期最早 > Apple 顺序」:要
//     回答的是"这首歌出自哪张专辑",原始录音室专辑通常最早发行。
//
// 因为"挑"每拍都做,歌词晚几秒解析出来也没事:那一拍旁证到位,回填自然出现。代价是回填通常比换歌晚一到几拍,
// relay 靫去重 key 里的 `|a` 标记补推一次(relayAlbumHintSuffix),会话 meta 同曲期间跟着补(poller.handle)。
//
// 生命周期纪律同 prefetchAppleCatalogTrack:poll 主循环只读缓存,没命中就后台补取、本轮按现状走 —— poll 路径上
// 同步等对外 HTTP 会把网络抖动变成"进度卡住"。
const appleAlbumHintMaxMisses = 2

// albumHintCandidate 是一条"曲名 + 时长对得上"的 Apple 目录候选,落盘后每拍重挑。
type albumHintCandidate struct {
	Artist string `json:"artist"`
	// TitleArtist:这条候选的署名旁证来自**曲名破折号前段**(搬运频道形态,见 albumHintTitleSplit),取候选时已核过
	// Apple 署名与它 0 档相符;挑的时候凭它当 0 档,不再要求跟播放器那格署名(频道名)相等。主查询有候选时恒为空。
	TitleArtist string `json:"title_artist,omitempty"`
	// CollectionArtist:专辑级署名,iTunes 只在它跟曲目署名不同时才给(群星合辑 / 别人专辑里客串)。
	CollectionArtist string `json:"collection_artist,omitempty"`
	Album            string `json:"album"`
	CollectionID     int64  `json:"collection_id,omitempty"`
	// TrackRelease:iTunes Search 给的 releaseDate —— 是**歌**的首发日期,只作兜底排序。
	TrackRelease string `json:"track_release,omitempty"`
	// AlbumRelease:lookup 到的**专辑**发行日期(ISO 8601,字符串序即时间序)。
	AlbumRelease string `json:"album_release,omitempty"`
	// Order:Apple 返回顺序,最后的平手项。
	Order int `json:"order"`
}

var (
	appleAlbumHintMu       sync.Mutex
	appleAlbumHintCache    = map[string][]albumHintCandidate{} // key → 候选,只存非空的
	appleAlbumHintPath     string                              // 空 = 只用内存(单测 / 一次性子命令)
	appleAlbumHintDirty    bool
	appleAlbumHintInflight = map[string]bool{}
	appleAlbumHintMisses   = map[string]int{}
	appleAlbumHintLogged   = map[string]string{} // key → 已打过日志的挑选结果,同一首只记一行
)

// appleAlbumHintKey:署名|曲名|整秒时长,刻意不 normLoose —— 缓存里存的是原始标签对应的候选。
func appleAlbumHintKey(artist, title string, durationSecs float64) string {
	return strings.TrimSpace(artist) + "|" + strings.TrimSpace(title) + "|" + fmt.Sprintf("%.0f", durationSecs)
}

// appleAlbumHintEligible:值不值得为这条播放去问。署名 / 曲名缺一不问;时长缺或短于
// appleTitleSearchMinDurationSecs 不问(几十秒的 Intro / Outro 最容易撞同名,理由见 applecatalog.go)。
func appleAlbumHintEligible(artist, title string, durationSecs float64) bool {
	return strings.TrimSpace(artist) != "" && strings.TrimSpace(title) != "" &&
		durationSecs >= appleTitleSearchMinDurationSecs
}

// loadAppleAlbumHintCache/saveAppleAlbumHintCache:跟 loadAppleCatalogCache 同一套(整份 map + 临时文件原子改名)。
func loadAppleAlbumHintCache(path string) {
	appleAlbumHintMu.Lock()
	appleAlbumHintPath = path
	appleAlbumHintMu.Unlock()
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string][]albumHintCandidate
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		appleAlbumHintMu.Lock()
		appleAlbumHintCache = m
		appleAlbumHintMu.Unlock()
		log.Printf("cache: loaded %d Apple album-hint candidate sets from %s", len(m), path)
	}
}

func saveAppleAlbumHintCache() {
	appleAlbumHintMu.Lock()
	if !appleAlbumHintDirty || appleAlbumHintPath == "" {
		appleAlbumHintMu.Unlock()
		return
	}
	data, err := json.Marshal(appleAlbumHintCache)
	appleAlbumHintDirty = false
	path := appleAlbumHintPath
	appleAlbumHintMu.Unlock()
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
	}
}

// appleAlbumHint 给 poll 主循环用:候选已缓存就当场挑一个回来(可能为空 —— 旁证还没到),没查过就后台补一次、
// 本轮先按现状走。resolvedArtists 是歌词链路核实过的署名(lyricResolvedArtists),挑 1 档候选时用。
func appleAlbumHint(ctx context.Context, artist, title string, durationSecs float64, resolvedArtists []string) string {
	if !appleAlbumHintEligible(artist, title, durationSecs) {
		return ""
	}
	key := appleAlbumHintKey(artist, title, durationSecs)
	appleAlbumHintMu.Lock()
	if cands, ok := appleAlbumHintCache[key]; ok {
		appleAlbumHintMu.Unlock()
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	}
	if appleAlbumHintInflight[key] || appleAlbumHintMisses[key] >= appleAlbumHintMaxMisses {
		appleAlbumHintMu.Unlock()
		return ""
	}
	appleAlbumHintInflight[key] = true
	appleAlbumHintMu.Unlock()
	go func() {
		cands, concluded := fetchAppleAlbumHintCandidatesTracked(ctx, artist, title, durationSecs)
		storeAppleAlbumHintResult(key, cands, concluded)
	}()
	return ""
}

// appleAlbumHintSyncWait:后台解析路径等 poll 主循环刚发起的那次候选查询最多等这么久(两个查询 × 两个商店 +
// 一次 lookup,实测 1~3 秒);超时就自己查一次。
const appleAlbumHintSyncWait = 8 * time.Second

// appleAlbumHintSync 给**后台**解析路径用(resolveTrackEnrichment / backfillPeripheralFields / recheck-cover CLI,
// 2026-09-08 晚加,给封面解析当专辑名,见 03 章决策 16):候选没缓存就当场查、查完再挑,不像 appleAlbumHint 那样
// 丢给后台"本轮先按现状走" —— 这些调用方本来就在 goroutine 里等九个歌词源,多等 Apple 一两秒没人看见;而封面
// 选源这一步一旦过去就不会再来(王子那首 MV 首次解析时没有专辑名可用,Apple 第一条合集封面就此冻结了一天)。
// 后台那次还在飞就等它,不重复发同一份请求。
//
// ⚠️ 会阻塞、且内部取 appleAlbumHintMu:绝不能在 poll 主循环里调,也不能在持有 enrichMu 时调。
func appleAlbumHintSync(ctx context.Context, artist, title string, durationSecs float64, resolvedArtists []string) string {
	if !appleAlbumHintEligible(artist, title, durationSecs) {
		return ""
	}
	key := appleAlbumHintKey(artist, title, durationSecs)
	deadline := time.Now().Add(appleAlbumHintSyncWait)
	for {
		appleAlbumHintMu.Lock()
		if cands, ok := appleAlbumHintCache[key]; ok {
			appleAlbumHintMu.Unlock()
			return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
		}
		if !appleAlbumHintInflight[key] {
			if appleAlbumHintMisses[key] >= appleAlbumHintMaxMisses {
				appleAlbumHintMu.Unlock()
				return ""
			}
			appleAlbumHintInflight[key] = true
			appleAlbumHintMu.Unlock()
			cands, concluded := fetchAppleAlbumHintCandidatesTracked(ctx, artist, title, durationSecs)
			storeAppleAlbumHintResult(key, cands, concluded)
			if len(cands) == 0 {
				return ""
			}
			return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
		}
		appleAlbumHintMu.Unlock()
		if ctx.Err() != nil || time.Now().After(deadline) {
			return ""
		}
		select {
		case <-ctx.Done():
			return ""
		case <-time.After(200 * time.Millisecond):
		}
	}
}

// storeAppleAlbumHintResult 把一次候选查询的结果记进缓存,并清掉在途标记。空结果只在 concluded(见
// appleAlbumHintQueryConcluded)时记一次 miss:网络不通那一轮查出来的空不是证据,只清在途、下次照常再问。
// appleAlbumHint(后台)/ appleAlbumHintSync(当场)两条路共用,保证 inflight / misses / dirty 三个状态只有一种写法。
func storeAppleAlbumHintResult(key string, cands []albumHintCandidate, concluded bool) {
	appleAlbumHintMu.Lock()
	delete(appleAlbumHintInflight, key)
	if len(cands) == 0 {
		if concluded {
			appleAlbumHintMisses[key]++
		}
	} else {
		appleAlbumHintCache[key] = cands
		appleAlbumHintDirty = true
	}
	appleAlbumHintMu.Unlock()
	if len(cands) > 0 {
		saveAppleAlbumHintCache()
	}
}

// pickAppleAlbumHintLogged:挑一个并把结果记一行日志(同一首同一结果只记一次,旁证晚到换了结果再记一次)。
// cands 是缓存里那份切片,存进去之后没人原地改,不持锁读是安全的。
func pickAppleAlbumHintLogged(key string, cands []albumHintCandidate, artist, title string, durationSecs float64, resolvedArtists []string) string {
	album := pickAppleAlbumHint(cands, artist, resolvedArtists)
	if album == "" {
		return ""
	}
	appleAlbumHintMu.Lock()
	logged := appleAlbumHintLogged[key] == album
	if !logged {
		appleAlbumHintLogged[key] = album
	}
	appleAlbumHintMu.Unlock()
	if !logged {
		log.Printf("album hint: %q - %q (%.0fs) -> %q (apple catalog, %d candidates)", artist, title, durationSecs, album, len(cands))
	}
	return album
}

// coverAlbumForTrack:封面复查 / 换封面判定用的专辑名(2026-09-08 晚,用户报王子那首 MV「用的是合集封面,不应该是
// 另外一个吗」,见 03 章决策 16)—— 播放器报了专辑就是它;没报就用 Apple 目录回填的那个(只读缓存、不等网络,没命中
// 就后台补一次、这一轮按空处理)。回填名只进**挑选过程**(Apple 匹配打分 / 网易云 vs Apple 对版 / QQ、同专辑邻居两道
// guard / coverSwapAllowed / coverNeedsHintCheck),**绝不落盘成 cover_album**:那个字段是"归属已核实"的凭据(App 侧
// 越过 Last.fm 自带图、collector 侧不再复查都靠它,见 03 章决策 13 的 ⚠️),而回填是按曲名 + 时长猜的,合集 / 重录版
// 撞车不是小概率,猜错一次就两边一起骗过、且永不自愈。
//
// ⚠️ 内部经 lyricResolvedArtists 取 enrichMu:持有 enrichMu 时不能调(trackEnrichment 要在取锁之前算好)。
func coverAlbumForTrack(ctx context.Context, artist, title, album string, durationSecs float64) string {
	if album != "" {
		return album
	}
	return appleAlbumHint(ctx, artist, title, durationSecs, lyricResolvedArtists(artist, title, album))
}

// coverAlbumCorroboration 是首次解析那一刻能凑到的署名旁证:缓存里已有的(lyricResolvedArtists,首次解析时通常还没有)
// + 这一轮 MusicBrainz 统一名 + 这一轮歌词胜出候选报的署名(王子那首:kugou 候选报「Prince」,正是靠它把 Apple 目录里
// 的「Prince」认下来)。
func coverAlbumCorroboration(artist, title, album, canonical string, picked *scoredLyricCandidateResult) []string {
	out := lyricResolvedArtists(artist, title, album)
	if strings.TrimSpace(canonical) != "" {
		out = append(out, canonical)
	}
	if picked != nil && strings.TrimSpace(picked.Artist) != "" {
		out = append(out, picked.Artist)
	}
	return out
}

// coverNeedsHintCheck:播放器没报专辑、Apple 目录回填出了专辑名,而现有封面**明确属于另一张专辑**时,值得按回填专辑
// 重选一次封面(走 backfillPeripheralFields,受同一套 5 次上限 + 10 分钟节流)。判据是 albumScore == 0 而不是
// coverNeedsAlbumCheck 那条 < 200:回填的是我们猜的名字、cover_album 是来源报的真名,写法差异(「1999」vs
// 「1999 (2019 Remaster)」)不值得白重试 5 轮。只看 netease / apple 两档 —— 它们的 cover_album 是来源自己报的;
// qq 从不报专辑名、device 的身份不靠文字,都判不了。
func coverNeedsHintCheck(e enrichEntry, album, hint string) bool {
	if album != "" || hint == "" || e.CoverURL == "" || e.CoverAlbum == "" {
		return false
	}
	if e.CoverSource != "netease" && e.CoverSource != "apple" {
		return false
	}
	return albumScore(e.CoverAlbum, hint) == 0
}

// fetchAppleAlbumHintCandidates 打 iTunes Search(两个查询 × 两个商店,合并去重),再用一次 lookup 补专辑级发行日期。
func fetchAppleAlbumHintCandidates(ctx context.Context, artist, title string, durationSecs float64) []albumHintCandidate {
	var results []itunesResult
	for _, q := range []string{strings.TrimSpace(artist + " " + title), title} {
		for _, country := range []string{"CN", "US"} {
			results = append(results, itunesSearch(ctx, neturl.QueryEscape(q), country)...)
		}
	}
	cands := albumHintCandidatesFromResults(results, title, durationSecs)
	if len(cands) == 0 {
		// 搬运频道形态兜底:署名位是频道名、歌手写在曲名破折号前面,见 albumHintTitleSplit。只发「前段 后段」一个查询。
		if titleArtist, song, ok := albumHintTitleSplit(title); ok {
			var alt []itunesResult
			q := neturl.QueryEscape(titleArtist + " " + song)
			for _, country := range []string{"CN", "US"} {
				alt = append(alt, itunesSearch(ctx, q, country)...)
			}
			cands = albumHintCandidatesFromTitleSplit(alt, titleArtist, song, durationSecs)
		}
	}
	if len(cands) == 0 {
		return nil
	}
	var ids []int64
	seen := map[int64]bool{}
	for _, c := range cands {
		if c.CollectionID != 0 && !seen[c.CollectionID] {
			seen[c.CollectionID] = true
			ids = append(ids, c.CollectionID)
		}
	}
	releases := itunesLookupCollectionReleaseDates(ctx, ids, "US")
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}
	return cands
}

// fetchAppleAlbumHintCandidatesTracked 在 fetchAppleAlbumHintCandidates 外面包一轮网络观察(networkobs.go 的
// beginNetworkRound),多回答一个问题:这次的空结果算不算数(2026-09-09,Rocky 查《One Last Kiss》首播无词时发现直连
// DNS 挂过 36 秒,顺带暴露这里的同款问题)。itunesSearch 把 DNS 失败 / 超时 / ctx 取消统统吞成空切片,原来一律记
// miss,appleAlbumHintMaxMisses=2 之后这首歌的专辑回填就在进程生命周期内永久关闭 —— 网络抖两下,王子那首 MV 的
// 封面又会退回「Apple 第一条合集」那个 03 章决策 16 刚修掉的形态。
//
// concluded 为 false 时调用方只清在途标记、不记 miss,下次换到这首歌照常再问。
func fetchAppleAlbumHintCandidatesTracked(ctx context.Context, artist, title string, durationSecs float64) (cands []albumHintCandidate, concluded bool) {
	end := beginNetworkRound()
	cands = fetchAppleAlbumHintCandidates(ctx, artist, title, durationSecs)
	attempts, failures := end()
	return cands, appleAlbumHintQueryConcluded(len(cands), attempts, failures)
}

// appleAlbumHintQueryConcluded:一次候选查询的结果能不能下结论。有候选自然算;空结果只在「至少一个请求真的到了
// 对面、对面回了话」时才算「Apple 目录里没有」—— 复用 lyricsRoundConfirmsNoResult 那条判据,不另起口径:四个
// Search 全是传输层失败(断网 / DNS 挂 / ctx 已取消),或者一个请求都没发出去,都不构成证据。
// 并发混入别的 goroutine 的成功只会让空结果更容易被判成算数,即退回改前的行为,方向上不会更差。
func appleAlbumHintQueryConcluded(n int, attempts, failures int32) bool {
	return n > 0 || lyricsRoundConfirmsNoResult(attempts, failures)
}

// albumHintCandidatesFromResults 是取候选那一步的过滤,纯函数、可单测:曲名归一相等 + 时长在容差内 + 专辑名 /
// 署名非空;按「署名|专辑」去重(CN / US 两个商店会各回一份)。Order 记 Apple 返回顺序。
func albumHintCandidatesFromResults(results []itunesResult, title string, durationSecs float64) []albumHintCandidate {
	want := normLoose(title)
	if want == "" || durationSecs < appleTitleSearchMinDurationSecs {
		return nil
	}
	tolerance := appleTitleSearchDurationTolerance(durationSecs)
	var out []albumHintCandidate
	seen := map[string]bool{}
	for _, r := range results {
		if normLoose(r.TrackName) != want {
			continue
		}
		if r.TrackTimeMillis <= 0 || math.Abs(r.TrackTimeMillis/1000-durationSecs) > tolerance {
			continue
		}
		album, who := cleanMediaTag(r.CollectionName), cleanMediaTag(r.ArtistName)
		if album == "" || who == "" {
			continue
		}
		dk := normLoose(who) + "|" + normLoose(album)
		if seen[dk] {
			continue
		}
		seen[dk] = true
		out = append(out, albumHintCandidate{
			Artist: who, CollectionArtist: cleanMediaTag(r.CollectionArtistName), Album: album,
			CollectionID: r.CollectionID, TrackRelease: r.ReleaseDate, Order: len(out),
		})
	}
	return out
}

// albumHintTitleSplit:搬运频道形态的身份兜底(2026-09-11,用户问「为什么当前这首 YT Music 的歌没有专辑上送」)。
//
// 现场:Safari 播 YT Music 里「音樂頑童」频道上传的《Musiq Soulchild - Buddy (Official Video)》,media-control 的 artist
// 位是频道名、真正的歌手写在曲名破折号前面。主查询按「署名 曲名」和裸曲名问 Apple,候选又要求曲名归一**完全相等**,
// 「musiqsoulchildbuddyofficialvideo」永远不等于「buddy」,零候选;就算有候选,署名 0 档拿频道名比、1 档要歌词旁证
// (这类条目歌词多半也解析不出来),一样过不去。
//
// 兜底:先用 normEnrichTitle 剥掉结尾的「(Official Video)」「[HD]」这类非版本括号(版本标记如「(Live)」按它的规则保留),
// 再在**第一个**破折号分隔(" - " / " – " / " — ")处拆成「前段 = 署名、后段 = 曲名」;两段任一归一后为空就不拆。
// 只有主查询零候选时才走(fetchAppleAlbumHintCandidates),所以「Song - Remastered」这种被拆错的歌名最多多花两个请求、
// 不会多出错候选:候选还要 Apple 署名与前段 0 档相符(albumHintCandidatesFromTitleSplit)。官方频道的 MV 标题
// 「Prince - 1999 (Official Music Video)」同样受益:前段跟播放器署名相等,后段才是 Apple 认得的曲名。
// 时长容差不放宽:该 MV 231.4s 对录音室版 223.8s 超出 max(4s, 3%),仍会被挡,是否放宽另议。
func albumHintTitleSplit(title string) (artist, song string, ok bool) {
	clean := normEnrichTitle(title)
	best, sepLen := -1, 0
	for _, sep := range []string{" - ", " – ", " — "} {
		if i := strings.Index(clean, sep); i >= 0 && (best < 0 || i < best) {
			best, sepLen = i, len(sep)
		}
	}
	if best < 0 {
		return "", "", false
	}
	artist, song = strings.TrimSpace(clean[:best]), strings.TrimSpace(clean[best+sepLen:])
	if normLoose(artist) == "" || normLoose(song) == "" {
		return "", "", false
	}
	return artist, song, true
}

// albumHintCandidatesFromTitleSplit:拆出来的身份取候选 —— 在 albumHintCandidatesFromResults 的三道门(曲名归一相等 /
// 时长容差 / 专辑署名非空)之上再加一道:Apple 署名必须与曲名前段 0 档相符(归一相等或 credit 子集),并把前段记进
// TitleArtist 落盘,挑的时候凭它当 0 档。播放器那格署名(频道名)在这条路上不参与比对。
func albumHintCandidatesFromTitleSplit(results []itunesResult, titleArtist, song string, durationSecs float64) []albumHintCandidate {
	var out []albumHintCandidate
	for _, c := range albumHintCandidatesFromResults(results, song, durationSecs) {
		if albumHintArtistTier(titleArtist, c.Artist, nil) != 0 {
			continue
		}
		c.TitleArtist = titleArtist
		out = append(out, c)
	}
	return out
}

// itunesLookupCollectionReleaseDates:一次 lookup 拿一批专辑的发行日期(id 逗号串起来,iTunes 允许最多 200 个)。
// 失败返回 nil,调用方退回曲目级日期排序。
func itunesLookupCollectionReleaseDates(ctx context.Context, ids []int64, country string) map[int64]string {
	if len(ids) == 0 {
		return nil
	}
	parts := make([]string, 0, len(ids))
	for _, id := range ids {
		parts = append(parts, fmt.Sprint(id))
	}
	u := "https://itunes.apple.com/lookup?country=" + country + "&id=" + strings.Join(parts, ",")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []struct {
			WrapperType  string `json:"wrapperType"`
			CollectionID int64  `json:"collectionId"`
			ReleaseDate  string `json:"releaseDate"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	m := map[int64]string{}
	for _, r := range out.Results {
		if r.WrapperType == "collection" && r.CollectionID != 0 && r.ReleaseDate != "" {
			m[r.CollectionID] = r.ReleaseDate
		}
	}
	return m
}

// pickAppleAlbumHint 从候选里挑一张,纯函数。判据见头注。
func pickAppleAlbumHint(cands []albumHintCandidate, artist string, resolvedArtists []string) string {
	resolved := map[string]bool{}
	for _, a := range resolvedArtists {
		if n := normLoose(a); n != "" {
			resolved[n] = true
		}
	}
	type scored struct {
		c       albumHintCandidate
		rank    int
		release string
	}
	var accepted []scored
	for _, c := range cands {
		tier := albumHintArtistTier(artist, c.Artist, resolved)
		if tier < 0 && c.TitleArtist != "" && albumHintArtistTier(c.TitleArtist, c.Artist, nil) == 0 {
			tier = 0 // 署名旁证来自曲名破折号前段(搬运频道形态),取候选时已核过,见 albumHintCandidatesFromTitleSplit
		}
		if tier < 0 {
			continue
		}
		rank := tier * 10
		if c.CollectionArtist != "" && normLoose(c.CollectionArtist) != normLoose(c.Artist) {
			rank += 4 // 专辑署名跟曲目署名不是一个人:群星合辑 / 别人的专辑里客串
		}
		if albumHintIsSingleOrEP(c.Album) {
			rank += 2
		}
		if albumHintHasEditionQualifier(c.Album) {
			rank++
		}
		release := c.AlbumRelease
		if release == "" {
			release = c.TrackRelease
		}
		accepted = append(accepted, scored{c: c, rank: rank, release: release})
	}
	if len(accepted) == 0 {
		return ""
	}
	sort.SliceStable(accepted, func(a, b int) bool {
		if accepted[a].rank != accepted[b].rank {
			return accepted[a].rank < accepted[b].rank
		}
		ra, rb := accepted[a].release, accepted[b].release
		if ra != rb {
			if ra == "" {
				return false
			}
			if rb == "" {
				return true
			}
			return ra < rb
		}
		return accepted[a].c.Order < accepted[b].c.Order
	})
	return accepted[0].c.Album
}

// albumHintArtistTier:0 = 署名本身对得上(归一相等 / credit 子集,含繁简折叠);1 = 歌词链路核实过的署名
// (跨文字系统只认这条旁证);-1 = 不采。
func albumHintArtistTier(local, candidate string, resolved map[string]bool) int {
	l, c := normLoose(local), normLoose(candidate)
	if l == "" || c == "" {
		return -1
	}
	if l == c {
		return 0
	}
	lp, cp := artistCreditParts(local), artistCreditParts(candidate)
	if len(lp) > 0 && len(cp) > 0 && (creditPartsSubset(lp, cp) || creditPartsSubset(cp, lp)) {
		return 0
	}
	if resolved[c] {
		return 1
	}
	return -1
}

// creditPartsSubset:a 里的每个署名都在 b 里(按 normLoose 比)。
func creditPartsSubset(a, b []string) bool {
	set := map[string]bool{}
	for _, p := range b {
		set[normLoose(p)] = true
	}
	for _, p := range a {
		if !set[normLoose(p)] {
			return false
		}
	}
	return true
}

// albumHintIsSingleOrEP:Apple 给单曲 / EP 的专辑名统一带「 - Single」「 - EP」后缀(各商店一致,不随界面语言变)。
func albumHintIsSingleOrEP(album string) bool {
	a := strings.ToLower(strings.TrimSpace(album))
	return strings.HasSuffix(a, " - single") || strings.HasSuffix(a, " - ep")
}

// albumHintHasEditionQualifier:「(Deluxe Edition)」「(2018 Remaster)」「(豪华版)」这类再版 / 加料版,只作
// 平手时的减分项 —— 同一张专辑的原版和豪华版都对上时,取名字最朴素的那张。
func albumHintHasEditionQualifier(album string) bool {
	a := strings.ToLower(album)
	for _, m := range []string{"deluxe", "edition", "remaster", "expanded", "anniversary", "bonus", "reissue", "豪华", "纪念版", "复刻"} {
		if strings.Contains(a, m) {
			return true
		}
	}
	return false
}

// lyricResolvedArtists:歌词链路核实过的"这首歌到底是谁的",给 pickAppleAlbumHint 的 1 档当旁证。两处来源:
//   - enrich 条目的 CanonicalArtist(网易云 / QQ 曲库核实过的官方歌手名);
//   - 已采纳的歌词决策(LyricsDecisionApplied)里**胜出候选**所报的 artist(王子 那首:kugou 候选报「Prince」)。
//
// 只读内存里的 enrich 缓存、不发请求;条目还没解析出来就返回空 —— appleAlbumHint 每拍重挑,晚几秒到也没事。
func lyricResolvedArtists(artist, title, album string) []string {
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		if alt, found := canonicalEnrichKey(key); found {
			e, ok = enrichCache[alt]
		}
	}
	enrichMu.Unlock()
	if !ok {
		return nil
	}
	var out []string
	if e.CanonicalArtist != "" {
		out = append(out, e.CanonicalArtist)
	}
	if d := e.LyricsDecisionApplied; d != nil && d.Winner != "" {
		for _, c := range d.Candidates {
			if c.Source == d.Winner && strings.TrimSpace(c.Artist) != "" {
				out = append(out, c.Artist)
				break
			}
		}
	}
	return out
}
