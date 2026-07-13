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
	"sync"
	"time"
)

// enrichEntry is the cached, per-track resolved metadata (all fields stable for
// a given 歌手|歌名|专辑). Persisted to disk so a song isn't re-resolved on every
// play or after a collector restart. TS (unix秒) drives a TTL re-resolve so
// transient failures self-heal and later-added lyrics get picked up.
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
	// ManualLyrics 标记这条歌词是用户在 desktop-lyrics 的"歌词管理"窗口里手动纠正过的——
	// 一旦置真,trackEnrichment 的 TTL 自动刷新永久跳过这一条,防止 30 天后被后台自动
	// 重新解析悄悄冲掉手动编辑的内容。只有用户在管理窗口里显式"删除此缓存"才会连同这个
	// 标记一起清掉,重新进入正常的自动解析流程。
	ManualLyrics bool  `json:"manual_lyrics,omitempty"`
	TS           int64 `json:"ts"`
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

const (
	enrichCacheMax = 3000
	enrichCacheTTL = 30 * 24 * time.Hour
	// 任一关键字段(封面主色/Apple/QQ 链接)缺失(多为对应平台限流/抽风导致的临时失败)时
	// 用很短的 TTL,让下次播放几分钟内就重试补上,而不是把残缺条目钉死 30 天。
	enrichCacheTTLNoCover = 10 * time.Minute
)

var (
	enrichMu       sync.Mutex
	enrichCache    = map[string]enrichEntry{}
	enrichPath     string // 落盘路径；空则只用内存不持久化
	enrichDirty    bool
	enrichInflight = map[string]bool{} // 正在后台解析的 key,去重防止重复解析
	enrichNotify   chan struct{}       // 后台解析完成→通知 poll 立刻重推;run() 里初始化
)

// trackEnrichment returns the cached per-track fields, resolving (and persisting)
// them on a miss or once past the TTL. Safe for concurrent callers (poll+bridge).
// durationSecs(曲目真实时长,秒)只作为解析时的校验输入,不参与缓存 key——同一首歌哪怕
// 每次报的时长有几百毫秒抖动也应该命中同一份缓存。ManualLyrics 的条目永远视为新鲜、
// 永不触发后台重新解析——否则 resolveEnrichAsync 会用一份全新 enrichEntry 整条替换掉
// enrichCache[key],连同用户手动纠正的歌词和 ManualLyrics 标记本身一起悄悄冲掉。
func trackEnrichment(artist, title, album string, durationSecs float64) map[string]string {
	if title == "" {
		return nil
	}
	key := artist + "|" + title + "|" + album
	now := time.Now().Unix()
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if ok {
		ttl := int64(enrichCacheTTL / time.Second)
		// 网易云(封面/主色)、Apple Music、QQ 音乐三路解析各自独立请求、可能各自单独因
		// 限流/超时失败;只要有一路"该有却没拿到"就用短 TTL 尽快重试,而不是被主色这一路
		// 的成败代表全部,把另外两路的残缺结果也钉死 30 天。
		if e.AccentColor == "" || e.AppleURL == "" || e.QQURL == "" || e.NeteaseURL == "" {
			ttl = int64(enrichCacheTTLNoCover / time.Second)
		}
		if e.ManualLyrics || now-e.TS < ttl {
			enrichMu.Unlock()
			return e.fields() // 新鲜命中(或手动修正过、永久视为新鲜),直接返回
		}
	}
	// 未命中或已过期:后台解析(按 key 去重),不阻塞 poll 循环。有旧值先返回旧值、无则空;
	// 解析完写缓存并经 enrichNotify 触发一次重推,封面/歌词随后补上(见 resolveEnrichAsync)。
	if !enrichInflight[key] {
		enrichInflight[key] = true
		go resolveEnrichAsync(key, artist, title, album, durationSecs)
	}
	var stale map[string]string
	if ok {
		stale = e.fields()
	}
	enrichMu.Unlock()
	return stale
}

// resolveEnrichAsync 在后台解析一首歌的富信息(封面/主色/链接/歌词),写入缓存并通知
// poll 循环重推。由 trackEnrichment 在缓存未命中时启动;同一 key 同时只有一个在跑
// (enrichInflight 去重)。各外部请求自带 4~10s 超时,故本 goroutine 有界、进程退出即止。
func resolveEnrichAsync(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	e := resolveTrackEnrichment(artist, title, album, durationSecs)
	e.TS = time.Now().Unix()
	// 只缓存"解析到东西"的结果;全空(可能网络抽风)不缓存,下次再试,别把偶发失败钉死。
	if e.CoverURL == "" && e.Lyrics == "" && e.AppleURL == "" && e.QQURL == "" && e.NeteaseURL == "" {
		return
	}
	enrichMu.Lock()
	if _, exists := enrichCache[key]; !exists && len(enrichCache) >= enrichCacheMax {
		// 满了:淘汰 TS 最旧的一条,腾位给新歌(否则装满后新歌永不缓存、每次重解析)。
		oldestKey, oldestTS, first := "", int64(0), true
		for k, v := range enrichCache {
			if first || v.TS < oldestTS {
				oldestKey, oldestTS, first = k, v.TS, false
			}
		}
		if oldestKey != "" {
			delete(enrichCache, oldestKey)
		}
	}
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	// 非阻塞通知 poll 立刻重推(带上刚解析好的封面/歌词);没人在听就跳过。
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
	// 很高(用户拍板:反正只查一次、存下来，没问题)。网易云的 ne.Lyrics 前面已经同步
	// 拿到了,另外三个源各自独立请求(尤其 LRCLIB 实测比网易云/QQ 慢不少,见 lrclib.go),
	// 并发查、不要串行等——串行的话总耗时是四家相加,新歌首次解析要等好几秒才出歌词;
	// 并发的话总耗时约等于最慢那家,不会比原来"只查一家"慢太多。每个候选都过
	// scoreLyricCandidate 统一打分(时间戳密度/语言合理性/是否只有credit信息/跟真实
	// 时长是否吻合),取最高分的候选;所有候选都不合格就是真的没有。网易云额外带翻译/
	// 罗马音/逐字,只有网易云胜出时才会一并采用。
	var qqLyr, kugouLyr, lrclibLyr string
	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		if mid := qqMidFromURL(e.QQURL); mid != "" {
			qqLyr = qqLyric(mid)
		}
	}()
	go func() {
		defer wg.Done()
		kugouLyr = kugouLyric(artist, title, durationSecs)
	}()
	go func() {
		defer wg.Done()
		lrclibLyr = lrclibLyric(artist, title, album)
	}()
	wg.Wait()

	var candidates []lyricCandidate
	if ne.Lyrics != "" {
		// hasWordTiming 只标记"这份候选本身带不带得到逐字时间轴",目前只有网易云可能有——
		// 见 scoreLyricCandidate 注释第2点,这项会拿到明显的加分。
		candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.Lyrics, hasWordTiming: ne.YRC != ""})
	}
	if qqLyr != "" {
		candidates = append(candidates, lyricCandidate{source: "qq", lyrics: qqLyr})
	}
	if kugouLyr != "" {
		candidates = append(candidates, lyricCandidate{source: "kugou", lyrics: kugouLyr})
	}
	if lrclibLyr != "" {
		candidates = append(candidates, lyricCandidate{source: "lrclib", lyrics: lrclibLyr})
	}
	corroborated := corroboratedEndings(candidates)
	bestScore := -1
	for _, c := range candidates {
		sc := scoreLyricCandidate(artist, title, durationSecs, c, corroborated[c.source])
		if sc < 0 || sc <= bestScore {
			continue
		}
		bestScore = sc
		e.Lyrics = c.lyrics
		e.LyricsSource = c.source
	}
	if e.LyricsSource == "netease" {
		e.LyricsTr, e.LyricsRoma, e.LyricsYRC = ne.Trans, ne.Roma, ne.YRC
	}
	return e
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
