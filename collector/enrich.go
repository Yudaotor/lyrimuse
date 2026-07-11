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
	TS              int64  `json:"ts"`
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
func trackEnrichment(artist, title, album string) map[string]string {
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
		if now-e.TS < ttl {
			enrichMu.Unlock()
			return e.fields() // 新鲜命中,直接返回
		}
	}
	// 未命中或已过期:后台解析(按 key 去重),不阻塞 poll 循环。有旧值先返回旧值、无则空;
	// 解析完写缓存并经 enrichNotify 触发一次重推,封面/歌词随后补上(见 resolveEnrichAsync)。
	if !enrichInflight[key] {
		enrichInflight[key] = true
		go resolveEnrichAsync(key, artist, title, album)
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
// (enrichInflight 去重)。各外部请求自带 4~6s 超时,故本 goroutine 有界、进程退出即止。
func resolveEnrichAsync(key, artist, title, album string) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	e := resolveTrackEnrichment(artist, title, album)
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

func resolveTrackEnrichment(artist, title, album string) enrichEntry {
	var e enrichEntry
	// 网易云:封面(国内可加载,苹果 mzstatic 国内已无 CDN)+ 单曲链接 + 带轴歌词,一次搜索出。
	ne := neteaseLookup(artist, title, album)
	e.CoverURL = ne.Cover
	e.NeteaseURL = ne.SongURL
	e.CanonicalArtist = ne.Artist
	if e.CoverURL == "" {
		// 网易云官方曲库缺失该艺人(版权下架,如周杰伦)时,pick() 已经拒绝了仿冒号候选、
		// 宁可返回空也不给错误封面(实测坐实:见 artistMatches 注释)。退回 QQ 音乐找同一
		// 首歌的官方版封面,双重校验歌手名(搜索结果+详情接口各查一次)避免 QQ 侧的仿冒
		// 号也蒙混过关。
		qqCover, qqArtist := qqCoverFallback(artist, title)
		e.CoverURL = qqCover
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
	// 歌词:网易云优先(连带翻译/罗马音/逐字)，没有则用已解析出的 QQ songmid 兜底
	// (两家曲库不同；QQ 只给逐行原文，无翻译/罗马音/逐字)。两家都没有才试 LRCLIB
	// (见 lrclib.go 顶部注释)——三档都拿不到才是真的没有。
	if ne.Lyrics != "" {
		e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC = ne.Lyrics, ne.Trans, ne.Roma, ne.YRC
	} else if mid := qqMidFromURL(e.QQURL); mid != "" {
		e.Lyrics = qqLyric(mid)
	}
	if e.Lyrics == "" {
		e.Lyrics = lrclibLyric(artist, title, album)
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
