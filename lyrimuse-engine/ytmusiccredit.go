package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"
)

// YouTube Music 按 videoId 登记的署名、歌名与专辑,两种用法、按两种界面语言问:
//   - 英文界面下的原名:Kaset 跟着用户的界面语言请求 YouTube Music,中文界面下一部分西方歌手报成本地化译名
//     (「菲尔·科林斯」),各歌词源都按原名(Phil Collins)收录,第一轮一个候选都拿不到。有 videoId 时(Kaset 经播放状态 /
//     待播队列带来,不在播放现场的重搜从缓存里存过的歌曲页取,挂在 ctx 上)按英文界面问一次 next,拿它登记的署名当换名
//     重搜的一个候选(retryArtistIdentities)。
//   - 界面语言下的专辑(ytmusicDisplayLanguage):专辑名也会本地化(同一张专辑中文界面是「未来」、英文界面是
//     「Wonderland」),界面专辑位、上送、选封面都按 Kaset 自己显示的那种语言取。
// 每种语言、每个 videoId 的结论记在内存里,问成了就不再问;没问成(网络、地区限制)不记,下次再问。

type youTubeMusicVideoIDKey struct{}

// withYouTubeMusicVideoID 给 ctx 挂上这首的 videoId。空串原样返回。
func withYouTubeMusicVideoID(ctx context.Context, videoID string) context.Context {
	if videoID == "" {
		return ctx
	}
	return context.WithValue(ctx, youTubeMusicVideoIDKey{}, videoID)
}

func youTubeMusicVideoIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(youTubeMusicVideoIDKey{}).(string)
	return id
}

// withCachedYouTubeMusicVideoIDLocked:ctx 上还没有 videoId 时,用这首缓存里存过的 YouTube Music 歌曲页补上。
// 重播时补空、补空扫描、全量扫库、手动重试都不在 Kaset 的播放现场,videoId 只能从缓存里取。调用方持有 enrichMu。
func withCachedYouTubeMusicVideoIDLocked(ctx context.Context, key string) context.Context {
	if youTubeMusicVideoIDFrom(ctx) != "" {
		return ctx
	}
	return withYouTubeMusicVideoID(ctx, youtubeMusicVideoIDOfURL(enrichCache[key].YouTubeMusicURL))
}

// youtubeMusicVideoIDOfURL:歌曲页里的 videoId。不是 youtubeMusicWatchURL 拼得出来的形状返回空。
func youtubeMusicVideoIDOfURL(u string) string {
	id := strings.TrimPrefix(u, "https://music.youtube.com/watch?v=")
	if id == "" || youtubeMusicWatchURL(id) != u {
		return ""
	}
	return id
}

type ytmusicCredit struct {
	artist, title, album string
	// videoType:YouTube Music 给这一版标的类型(MUSIC_VIDEO_TYPE_ATV 音轨 / _OMV 官方 MV / _UGC 用户上传……)。
	videoType string
	// durationSecs:这一版的时长(lengthText),没有为 0。
	durationSecs float64
	// albumBrowseID:专辑页的 id(browseId),同专辑预取拉曲目表用(kasetalbumprefetch.go)。
	albumBrowseID string
	// cover:这一版的缩略图(最大的那张换成原图地址,见 ytmusicOriginalThumbnail),音轨版本的是专辑封面。
	cover string
}

var (
	ytmusicCreditMu sync.Mutex
	// ytmusicCreditCache:按 ytmusicCreditKey(界面语言, videoId) 记下的登记信息。
	ytmusicCreditCache = map[string]ytmusicCredit{}
)

// ytmusicCreditKey:同一个 videoId 在不同界面语言下登记的写法不一样(署名、专辑名都会本地化),分开记。
func ytmusicCreditKey(hl, videoID string) string {
	return hl + "|" + videoID
}

// ytmusicEnglishCredit:这个 videoId 在 YouTube Music 英文界面下登记的署名、歌名与专辑。问不到返回空。
func ytmusicEnglishCredit(ctx context.Context, videoID string) ytmusicCredit {
	return ytmusicListedTrack(ctx, videoID, "en")
}

// ytmusicListedTrack:这个 videoId 在 YouTube Music 上按 hl 那种界面语言登记的署名、歌名与专辑。问不到返回空。
func ytmusicListedTrack(ctx context.Context, videoID, hl string) ytmusicCredit {
	if youtubeMusicWatchURL(videoID) == "" {
		return ytmusicCredit{}
	}
	key := ytmusicCreditKey(hl, videoID)
	ytmusicCreditMu.Lock()
	c, ok := ytmusicCreditCache[key]
	ytmusicCreditMu.Unlock()
	if ok {
		return c
	}
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	if client, ok := body["context"].(map[string]any)["client"].(map[string]any); ok {
		client["hl"] = hl
	}
	body["videoId"] = videoID
	body["isAudioOnly"] = true
	raw, err := ytmusicPost(ctx, "next", body, ytmusicCachedVisitorID())
	if err != nil || len(raw) == 0 {
		return ytmusicCredit{}
	}
	c = ytmusicCreditFromNext(raw, videoID)
	ytmusicCreditMu.Lock()
	ytmusicCreditCache[key] = c
	ytmusicCreditMu.Unlock()
	return c
}

// ytmusicDisplayLanguage:按界面语言问 YouTube Music 时的 hl(见 ytmusicLanguageFor)。
func ytmusicDisplayLanguage() string {
	return ytmusicLanguageFor(features().SystemLanguage)
}

// ytmusicLanguageFor:系统语言(AppleLocale 下划线前那段转小写)换成 YouTube Music 的 hl,跟 Kaset 默认跟随系统时同一套:
// 中文按书写系统分 zh-Hans / zh-Hant(只有 zh 时按简体),别的取语言代码,读不到是 en。纯函数,单测覆盖。
func ytmusicLanguageFor(system string) string {
	s := strings.ToLower(strings.TrimSpace(system))
	switch {
	case s == "":
		return "en"
	case strings.HasPrefix(s, "zh-hant"):
		return "zh-Hant"
	case s == "zh" || strings.HasPrefix(s, "zh-"):
		return "zh-Hans"
	}
	if i := strings.IndexAny(s, "-_"); i > 0 {
		s = s[:i]
	}
	return s
}

// ytmusicCreditFromNext 从 next 的应答里摘出这个 videoId 那一条(playlistPanelVideoRenderer)的歌名、署名行
// (longBylineText)第一段 —— ` • ` 之前那些,多位歌手连同中间的连接词原样拼起来 —— 和署名行里链到专辑页的那一段
// (ytmusicCreditAlbumRun)。找不到返回空。纯函数,单测覆盖。
func ytmusicCreditFromNext(raw []byte, videoID string) ytmusicCredit {
	var root any
	if json.Unmarshal(raw, &root) != nil {
		return ytmusicCredit{}
	}
	var out ytmusicCredit
	ytmusicWalkJSON(root, func(m map[string]any) {
		r, ok := m["playlistPanelVideoRenderer"].(map[string]any)
		if !ok || out.title != "" || r["videoId"] != videoID {
			return
		}
		out.title = strings.TrimSpace(ytmusicCreditRunsText(r["title"], false))
		out.artist = strings.TrimSpace(ytmusicCreditRunsText(r["longBylineText"], true))
		album, albumBrowseID := ytmusicCreditAlbumRun(r["longBylineText"])
		out.album, out.albumBrowseID = strings.TrimSpace(album), albumBrowseID
		out.videoType = ytmusicCreditVideoType(r["navigationEndpoint"])
		out.durationSecs = ytmusicParseDurationText(ytmusicCreditRunsText(r["lengthText"], false))
		out.cover = ytmusicCreditThumbnail(r["thumbnail"])
	})
	return out
}

// ytmusicCreditVideoType:播放入口(watchEndpoint)上标的视频类型。
func ytmusicCreditVideoType(node any) string {
	nav, _ := node.(map[string]any)
	watch, _ := nav["watchEndpoint"].(map[string]any)
	configs, _ := watch["watchEndpointMusicSupportedConfigs"].(map[string]any)
	music, _ := configs["watchEndpointMusicConfig"].(map[string]any)
	t, _ := music["musicVideoType"].(string)
	return t
}

// ytmusicCreditThumbnail:缩略图列表(从小到大排)里最后一张,换成原图地址。
func ytmusicCreditThumbnail(node any) string {
	m, _ := node.(map[string]any)
	list, _ := m["thumbnails"].([]any)
	var u string
	for _, t := range list {
		th, _ := t.(map[string]any)
		if s, _ := th["url"].(string); s != "" {
			u = s
		}
	}
	return ytmusicOriginalThumbnail(u)
}

// ytmusicCreditAlbumRun:署名行里链到专辑页(MUSIC_PAGE_TYPE_ALBUM)的那一段,连同专辑页的 id。音轨版本才有,MV / 视频
// 那一段是播放量。
func ytmusicCreditAlbumRun(node any) (string, string) {
	m, _ := node.(map[string]any)
	runs, _ := m["runs"].([]any)
	for _, run := range runs {
		r, _ := run.(map[string]any)
		nav, _ := r["navigationEndpoint"].(map[string]any)
		browse, _ := nav["browseEndpoint"].(map[string]any)
		configs, _ := browse["browseEndpointContextSupportedConfigs"].(map[string]any)
		music, _ := configs["browseEndpointContextMusicConfig"].(map[string]any)
		if music["pageType"] == "MUSIC_PAGE_TYPE_ALBUM" {
			text, _ := r["text"].(string)
			id, _ := browse["browseId"].(string)
			return text, id
		}
	}
	return "", ""
}

// ytmusicCreditRetryAfter:后台没问成(网络、地区限制)之后,同一个 videoId 隔多久再问。
const ytmusicCreditRetryAfter = time.Minute

// ytmusicCreditFetchTimeout:后台问一次的上限。
const ytmusicCreditFetchTimeout = 15 * time.Second

var (
	// ytmusicCreditPending:正在后台问的(按 ytmusicCreditKey);ytmusicCreditFailedAt:后台没问成的时刻。都在
	// ytmusicCreditMu 里读写。
	ytmusicCreditPending  = map[string]bool{}
	ytmusicCreditFailedAt = map[string]time.Time{}
)

// ytmusicListedCachedOrFetch:按 hl 那种界面语言记下的结论有就给(ok=true);没有就后台问一次(同一种语言、同一个
// videoId 同时只问一次,没问成隔 ytmusicCreditRetryAfter 再问),这一回 ok=false。不是 videoId 形状的直接给空(ok=true)。
// 轮询每拍都来问,不能在这里同步联网。
func ytmusicListedCachedOrFetch(videoID, hl string) (ytmusicCredit, bool) {
	if youtubeMusicWatchURL(videoID) == "" {
		return ytmusicCredit{}, true
	}
	key := ytmusicCreditKey(hl, videoID)
	ytmusicCreditMu.Lock()
	defer ytmusicCreditMu.Unlock()
	if c, ok := ytmusicCreditCache[key]; ok {
		return c, true
	}
	if ytmusicCreditPending[key] || time.Since(ytmusicCreditFailedAt[key]) < ytmusicCreditRetryAfter {
		return ytmusicCredit{}, false
	}
	ytmusicCreditPending[key] = true
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), ytmusicCreditFetchTimeout)
		defer cancel()
		ytmusicListedTrack(ctx, videoID, hl)
		ytmusicCreditMu.Lock()
		defer ytmusicCreditMu.Unlock()
		delete(ytmusicCreditPending, key)
		if _, ok := ytmusicCreditCache[key]; !ok {
			ytmusicCreditFailedAt[key] = time.Now()
		}
	}()
	return ytmusicCredit{}, false
}

// ytmusicListedTrackSettled:同 ytmusicListedTrack(会联网),另外告诉调用方问成没有。不是 videoId 形状的给空(ok=true)。
func ytmusicListedTrackSettled(ctx context.Context, videoID, hl string) (ytmusicCredit, bool) {
	if youtubeMusicWatchURL(videoID) == "" {
		return ytmusicCredit{}, true
	}
	c := ytmusicListedTrack(ctx, videoID, hl)
	ytmusicCreditMu.Lock()
	_, ok := ytmusicCreditCache[ytmusicCreditKey(hl, videoID)]
	ytmusicCreditMu.Unlock()
	return c, ok
}

// ytmusicVideoTypePodcastEpisode:YouTube Music 给播客单集标的视频类型。
const ytmusicVideoTypePodcastEpisode = "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"

// kasetPodcastEpisodePoll:kasetPodcastEpisode 等后台那一次问完时,隔多久看一眼。
const kasetPodcastEpisodePoll = 50 * time.Millisecond

// kasetPodcastEpisode:这个 videoId 在 YouTube Music 上登记成播客单集。按界面语言取登记,跟轮询判专辑共用同一份记录和
// 同一套规矩(ytmusicListedCachedOrFetch:同一条同时只问一次,没问成隔 ytmusicCreditRetryAfter 再问);后台正在问的
// 等它问完,最多等 ytmusicCreditFetchTimeout。问不成当不是。会阻塞,别在轮询路径上调。
func kasetPodcastEpisode(videoID string) bool {
	hl := ytmusicDisplayLanguage()
	deadline := time.Now().Add(ytmusicCreditFetchTimeout)
	for {
		c, ok := ytmusicListedCachedOrFetch(videoID, hl)
		if ok {
			return c.videoType == ytmusicVideoTypePodcastEpisode
		}
		if !ytmusicCreditAsking(hl, videoID) || time.Now().After(deadline) {
			return false
		}
		time.Sleep(kasetPodcastEpisodePoll)
	}
}

// ytmusicCreditAsking:这一种界面语言、这个 videoId 的登记正在后台问。
func ytmusicCreditAsking(hl, videoID string) bool {
	ytmusicCreditMu.Lock()
	defer ytmusicCreditMu.Unlock()
	return ytmusicCreditPending[ytmusicCreditKey(hl, videoID)]
}

// kasetPodcastEpisodeCached:同 kasetPodcastEpisode,只看记下的(没记过就后台去问,这一回当不是)。轮询路径用。
func kasetPodcastEpisodeCached(videoID string) bool {
	c, ok := ytmusicListedCachedOrFetch(videoID, ytmusicDisplayLanguage())
	return ok && c.videoType == ytmusicVideoTypePodcastEpisode
}

// ytmusicCreditRunsText:一段 InnerTube 文字({"runs":[{"text":…},…]})拼成一串;firstField 时到第一个 ` • ` 为止。
func ytmusicCreditRunsText(node any, firstField bool) string {
	m, _ := node.(map[string]any)
	runs, _ := m["runs"].([]any)
	var b strings.Builder
	for _, run := range runs {
		r, _ := run.(map[string]any)
		text, _ := r["text"].(string)
		if firstField && strings.TrimSpace(text) == "•" {
			break
		}
		b.WriteString(text)
	}
	return b.String()
}
