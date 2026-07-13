// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	neturl "net/url"
	"os"
	"sort"
	"sync"
	"time"
)

// enrichEntry is a track's resolved metadata, persisted permanently once
// resolved (歌手|歌名|专辑 key) — there is no cache/TTL concept for the
// identity fields (Lyrics/CoverURL/CanonicalArtist/等): once a song is
// listened to and resolved, its data lives on local disk until the user
// explicitly deletes it via desktop-lyrics 的"歌词管理"窗口 (which clears the
// whole entry, letting the next play resolve fresh). TS is only used to
// throttle the one thing that still self-heals automatically — see
// needsPeripheralBackfill.
type enrichEntry struct {
	CoverURL    string `json:"cover_url,omitempty"`
	AccentColor string `json:"accent_color,omitempty"`
	NeteaseURL  string `json:"netease_url,omitempty"`
	AppleURL    string `json:"apple_music_url,omitempty"`
	QQURL       string `json:"qq_music_url,omitempty"`
	SpotifyURL  string `json:"spotify_url,omitempty"`
	Lyrics      string `json:"lyrics,omitempty"`
	LyricsTr    string `json:"lyrics_tr,omitempty"`   // 中文翻译(逐行 LRC)
	LyricsRoma  string `json:"lyrics_roma,omitempty"` // 罗马音(日文歌，逐行 LRC)
	LyricsYRC   string `json:"lyrics_yrc,omitempty"`  // 逐字(词级，网易云 yrc 格式)
	// CanonicalArtist 是网易云/QQ 音乐曲库核实过的官方歌手名(仅单一歌手时才有值)，
	// 用来把同一歌手在历史记录里时而中文时而英文、时而全大写的写法统一成一个版本
	// (如 PRINCE/Prince 统一成 Prince、David Tao/陶喆 统一成 陶喆——中文平台曲库通常
	// 就是这么标的，天然贴合"能识别就用中文名"的诉求，不需要额外维护中英文对照表)。
	// 识别不出时留空，lbMeta 原样使用本地(Apple Music)标签，不瞎猜。
	CanonicalArtist string `json:"canonical_artist,omitempty"`
	// CoverSource/LyricsSource 记录封面/歌词实际来自哪个平台("netease"/"qq"/"lrclib"),
	// 供网页页脚如实展示(而不是写死"来自网易云"——封面/歌词各自可能来自不同平台,或者
	// 干脆哪个平台都没有)。
	CoverSource  string `json:"cover_source,omitempty"`
	LyricsSource string `json:"lyrics_source,omitempty"`
	// ManualLyrics 标记这条歌词是用户在 desktop-lyrics 的"歌词管理"窗口里手动纠正/采纳
	// 过的——纯粹是给 UI 显示"人工修正"徽章用的溯源标记,不再影响任何自动刷新逻辑(已经
	// 没有自动刷新了,所有条目都是解析一次永久生效)。
	ManualLyrics bool `json:"manual_lyrics,omitempty"`
	// TS 只用来给"外围字段缺失时的短时重试"计时(见 needsPeripheralBackfill),不再是
	// "多久没刷新就整条过期重新解析"的依据、也不再驱动任何淘汰逻辑。
	TS int64 `json:"ts"`
}

func (e enrichEntry) fields() map[string]string {
	m := map[string]string{}
	put := func(k, v string) {
		if v != "" {
			m[k] = v
		}
	}
	put("cover_url", e.CoverURL)
	put("accent_color", e.AccentColor)
	put("netease_url", e.NeteaseURL)
	put("apple_music_url", e.AppleURL)
	put("qq_music_url", e.QQURL)
	put("spotify_url", e.SpotifyURL)
	put("lyrics", e.Lyrics)
	put("lyrics_tr", e.LyricsTr)
	put("lyrics_roma", e.LyricsRoma)
	put("lyrics_yrc", e.LyricsYRC)
	put("canonical_artist", e.CanonicalArtist)
	put("cover_source", e.CoverSource)
	put("lyrics_source", e.LyricsSource)
	return m
}

// enrichPeripheralRetryInterval 是唯一还保留的自动重试节流——网易云(封面/主色)、
// Apple Music、QQ 音乐三路外围链接各自独立请求,可能因限流/超时单独失败;只要有一路
// "该有却没拿到"就每隔这么久重试补一次,而不是永久卡在残缺状态。不影响歌词/封面来源
// 等身份字段——那些一旦解析出结果就不再自动变动,见 backfillPeripheralFields。
const enrichPeripheralRetryInterval = 10 * time.Minute

var (
	enrichMu       sync.Mutex
	enrichCache    = map[string]enrichEntry{}
	enrichPath     string // 落盘路径；空则只用内存不持久化
	enrichDirty    bool
	enrichInflight = map[string]bool{} // 正在后台解析的 key,去重防止重复解析
	enrichNotify   chan struct{}       // 后台解析完成→通知 poll 立刻重推;run() 里初始化
)

// trackEnrichment returns a track's resolved fields, resolving (and persisting
// permanently) them on first sight. Safe for concurrent callers (poll+bridge).
// durationSecs(曲目真实时长,秒)只作为解析时的校验输入,不参与缓存 key——同一首歌哪怕
// 每次报的时长有几百毫秒抖动也应该命中同一份记录。已经解析过的条目永远直接返回,不会
// 自动整条重新解析——只有 needsPeripheralBackfill 命中时,会在后台补一次缺失的外围
// 字段(不碰歌词/封面来源等身份字段)。
func trackEnrichment(artist, title, album string, durationSecs float64) map[string]string {
	if title == "" {
		return nil
	}
	key := artist + "|" + title + "|" + album
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if ok {
		if needsPeripheralBackfill(e) && !enrichInflight[key] {
			enrichInflight[key] = true
			go backfillPeripheralFields(key, artist, title, album, durationSecs)
		}
		enrichMu.Unlock()
		return e.fields()
	}
	// 从没见过这首歌:首次解析(按 key 去重),不阻塞 poll 循环。
	if !enrichInflight[key] {
		enrichInflight[key] = true
		go resolveEnrichAsync(key, artist, title, album, durationSecs)
	}
	enrichMu.Unlock()
	return nil
}

// needsPeripheralBackfill 判断是否要补一次外围字段(主色/Apple/QQ/网易云链接)——这几路
// 各自独立请求,可能因限流/超时单独失败,漏了哪个就该重试哪个,不代表歌词/封面本身有问题。
// 用 TS 节流,避免同一首歌每次 poll(几秒一次)都重新发一遍网络请求。
func needsPeripheralBackfill(e enrichEntry) bool {
	missing := e.AccentColor == "" || e.AppleURL == "" || e.QQURL == "" || e.NeteaseURL == ""
	if !missing {
		return false
	}
	return time.Now().Unix()-e.TS >= int64(enrichPeripheralRetryInterval/time.Second)
}

// resolveEnrichAsync 首次解析一首歌的完整信息(封面/主色/链接/歌词),写入并永久保留,
// 直到用户在"歌词管理"里显式删除这条。由 trackEnrichment 在从没见过这个 key 时启动;
// 同一 key 同时只有一个在跑(enrichInflight 去重)。各外部请求自带 4~10s 超时,故本
// goroutine 有界、进程退出即止。
func resolveEnrichAsync(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	e := resolveTrackEnrichment(artist, title, album, durationSecs)
	e.TS = time.Now().Unix()
	// 只保留"解析到东西"的结果;全空(可能网络抽风)不写入,下次再试,别把偶发失败钉死。
	if e.CoverURL == "" && e.Lyrics == "" && e.AppleURL == "" && e.QQURL == "" && e.NeteaseURL == "" {
		return
	}
	enrichMu.Lock()
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	exportLyricsFiles() // 见 lyricsexport.go——刚解析出的新歌词额外导出成独立文件
	// 非阻塞通知 poll 立刻重推(带上刚解析好的封面/歌词);没人在听就跳过。
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
}

// backfillPeripheralFields 只补外围链接(Apple/QQ/网易云/主色),绝不动歌词/封面来源/
// 人工修正标记等身份字段——这些一旦解析出结果就永久生效,不该被这条自愈路径悄悄改掉。
func backfillPeripheralFields(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	fresh := resolveTrackEnrichment(artist, title, album, durationSecs)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		// 补的这段时间里,这条被用户在"歌词管理"里删掉了——不要把它复活回去。
		enrichMu.Unlock()
		return
	}
	e.CoverURL, e.CoverSource, e.AccentColor = fresh.CoverURL, fresh.CoverSource, fresh.AccentColor
	e.AppleURL, e.QQURL, e.SpotifyURL, e.NeteaseURL = fresh.AppleURL, fresh.QQURL, fresh.SpotifyURL, fresh.NeteaseURL
	if e.CanonicalArtist == "" {
		e.CanonicalArtist = fresh.CanonicalArtist
	}
	e.TS = time.Now().Unix() // 推进节流时间戳,不管这次补没补全,10 分钟内不再重试
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
}

func resolveTrackEnrichment(artist, title, album string, durationSecs float64) enrichEntry {
	var e enrichEntry
	// 网易云:封面(国内可加载,苹果 mzstatic 国内已无 CDN)+ 单曲链接 + 带轴歌词,一次搜索出。
	ne := neteaseLookup(artist, title, album)
	e.CoverURL = ne.Cover
	if e.CoverURL != "" {
		e.CoverSource = "netease"
	}
	e.NeteaseURL = ne.SongURL
	e.CanonicalArtist = ne.Artist
	if e.CoverURL == "" {
		// 网易云官方曲库缺失该艺人(版权下架,如周杰伦)时,pick() 已经拒绝了仿冒号候选、
		// 宁可返回空也不给错误封面(实测坐实:见 artistMatches 注释)。退回 QQ 音乐找同一
		// 首歌的官方版封面,双重校验歌手名(搜索结果+详情接口各查一次)避免 QQ 侧的仿冒
		// 号也蒙混过关。
		qqCover, qqArtist := qqCoverFallback(artist, title)
		e.CoverURL = qqCover
		if e.CoverURL != "" {
			e.CoverSource = "qq"
		}
		if e.CanonicalArtist == "" {
			e.CanonicalArtist = qqArtist
		}
	}
	if e.CanonicalArtist == "" {
		// NetEase/QQ 的跨服务匹配都没能给出统一歌手名(常见于 title/album 本身就跨语言
		// 对不上文本的 feat. 曲目,见 artistAliasTable 注释)——用手工登记的已知艺名表兜底。
		e.CanonicalArtist = knownArtistAlias(artist)
	}
	if e.CoverURL != "" {
		// 封面主色调,供网页按专辑动态配色(浏览器读跨域封面像素会被 CORS 挡,故服务端算)。
		e.AccentColor = dominantColor(e.CoverURL)
	}
	// 各平台单曲跳转链接。Apple Music 中国区优先(iTunes Search)、QQ 经 smartbox、Spotify 搜索链接。
	e.AppleURL = appleMusicURL(artist, title, album)
	e.QQURL = qqMusicURL(artist, title, album)
	if title != "" {
		e.SpotifyURL = "https://open.spotify.com/search/" + neturl.QueryEscape(artist+" "+title)
	}
	// 歌词:网易云/QQ音乐/酷狗/LRCLIB 四个源全部查一遍,不是查到第一个能用的就停——一首歌
	// 只在缓存未命中时解析一次,后续都直接读缓存,四个源都查一遍换来更可信的结果性价比
	// 很高(用户拍板:反正只查一次、存下来，没问题)。取分数最高的候选;所有候选都不合格
	// 就是真的没有。取分/并发细节见 scoredLyricCandidates(同一份逻辑也供 desktop-lyrics
	// 的"重新搜索候选歌词"手动纠正功能复用,搜索用的 CLI 子命令见 searchcli.go)。
	scored := scoredLyricCandidates(ne, artist, title, album, durationSecs)
	bestScore := -1
	for _, r := range scored {
		if r.Score < 0 || r.Score <= bestScore {
			continue
		}
		bestScore = r.Score
		e.Lyrics = r.Lyrics
		e.LyricsSource = r.Source
		e.LyricsTr, e.LyricsRoma, e.LyricsYRC = r.LyricsTr, r.LyricsRoma, r.LyricsYRC
	}
	return e
}

// scoredLyricCandidateResult is one scored lyric candidate — exported shape (JSON
// tags) so it doubles as the `collector search-lyrics` CLI subcommand's stdout
// format for desktop-lyrics's manual "重新搜索候选歌词" picker.
type scoredLyricCandidateResult struct {
	Source        string `json:"source"`
	Lyrics        string `json:"lyrics"`
	LyricsTr      string `json:"lyrics_tr,omitempty"`
	LyricsRoma    string `json:"lyrics_roma,omitempty"`
	LyricsYRC     string `json:"lyrics_yrc,omitempty"`
	HasWordTiming bool   `json:"has_word_timing"`
	Score         int    `json:"score"`
}

// scoredLyricCandidates fetches qq/kugou/lrclib concurrently (netease's ne is
// passed in already-resolved — resolveTrackEnrichment fetched it for cover/URL
// purposes anyway, so this never issues a second netease request), scores every
// candidate via scoreLyricCandidate, and returns all of them sorted best-first
// (not just the winner) — this is the one place both the auto-resolve path
// (resolveTrackEnrichment, above) and the on-demand `search-lyrics` CLI subcommand
// (searchcli.go) gather/score candidates, so there is exactly one implementation
// of "how do we rank lyric sources" in the whole project.
func scoredLyricCandidates(ne neteaseInfo, artist, title, album string, durationSecs float64) []scoredLyricCandidateResult {
	qqURL := qqMusicURL(artist, title, album)
	qqMid := qqMidFromURL(qqURL)
	var qqLyr, qqYRC, kugouLyr, kugouYRC, lrclibLyr string
	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		if qqMid != "" {
			qqLyr = qqLyric(qqMid)
			// 逐字(QRC)是完全独立的一套接口/密钥,自己失败不影响上面整行歌词——
			// 见 qq.go 顶部注释。
			qqYRC = qqQRCLyric(qqMid, artist, title, album, durationSecs)
		}
	}()
	go func() {
		defer wg.Done()
		r := kugouLyric(artist, title, durationSecs)
		kugouLyr, kugouYRC = r.lrc, r.yrc
	}()
	go func() {
		defer wg.Done()
		lrclibLyr = lrclibLyric(artist, title, album)
	}()
	wg.Wait()

	var candidates []lyricCandidate
	if ne.Lyrics != "" {
		candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.Lyrics, wordTimingYRC: ne.YRC, hasWordTiming: ne.YRC != ""})
	}
	if qqLyr != "" {
		candidates = append(candidates, lyricCandidate{source: "qq", lyrics: qqLyr, wordTimingYRC: qqYRC, hasWordTiming: qqYRC != ""})
	}
	if kugouLyr != "" {
		candidates = append(candidates, lyricCandidate{source: "kugou", lyrics: kugouLyr, wordTimingYRC: kugouYRC, hasWordTiming: kugouYRC != ""})
	}
	if lrclibLyr != "" {
		candidates = append(candidates, lyricCandidate{source: "lrclib", lyrics: lrclibLyr})
	}
	corroborated := corroboratedEndings(candidates)

	results := make([]scoredLyricCandidateResult, 0, len(candidates))
	for _, c := range candidates {
		r := scoredLyricCandidateResult{
			Source:        c.source,
			Lyrics:        c.lyrics,
			LyricsYRC:     c.wordTimingYRC,
			HasWordTiming: c.hasWordTiming,
			Score:         scoreLyricCandidate(artist, title, durationSecs, c, corroborated[c.source]),
		}
		if c.source == "netease" {
			// 翻译/罗马音目前只有网易云会给(QQ/酷狗这次只接了逐字,不接翻译/罗马音,
			// 见计划"刻意不做的")。
			r.LyricsTr, r.LyricsRoma = ne.Trans, ne.Roma
		}
		results = append(results, r)
	}
	sort.Slice(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	return results
}

// loadEnrichCache reads the persisted enrichment cache (best-effort) and sets the
// path future saves write to. Call once at startup.
func loadEnrichCache(path string) {
	enrichPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]enrichEntry
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		enrichMu.Lock()
		enrichCache = m
		enrichMu.Unlock()
		log.Printf("loaded %d cached track enrichments from %s", len(m), path)
	}
}

// saveEnrichCache atomically writes the cache when dirty (temp file + rename).
func saveEnrichCache() {
	enrichMu.Lock()
	if !enrichDirty || enrichPath == "" {
		enrichMu.Unlock()
		return
	}
	data, err := json.Marshal(enrichCache)
	enrichDirty = false
	enrichMu.Unlock()
	if err != nil {
		return
	}
	tmp := enrichPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, enrichPath); err != nil {
		log.Printf("save enrich cache: %v", err)
	}
}
