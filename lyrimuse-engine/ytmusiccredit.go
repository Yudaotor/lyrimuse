package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"
)

// YouTube Music 按 videoId 登记的原名(英文界面)。Kaset 跟着用户的界面语言请求 YouTube Music,中文界面下一部分西方歌手
// 报成本地化译名(「菲尔·科林斯」),各歌词源都按原名(Phil Collins)收录,第一轮一个候选都拿不到。有 videoId 时(Kaset
// 经播放状态 / 待播队列带来,不在播放现场的重搜从缓存里存过的歌曲页取,挂在 ctx 上)按英文界面问一次 next,拿它登记的署名当换名重搜的一个候选(retryArtistIdentities)。
// 同一个 videoId 的结论记在内存里,问成了就不再问;没问成(网络、地区限制)不记,下次再问。

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

type ytmusicCredit struct{ artist, title, album string }

var (
	ytmusicCreditMu    sync.Mutex
	ytmusicCreditCache = map[string]ytmusicCredit{}
)

// ytmusicEnglishCredit:这个 videoId 在 YouTube Music 英文界面下登记的署名、歌名与专辑。问不到返回空。
func ytmusicEnglishCredit(ctx context.Context, videoID string) ytmusicCredit {
	if youtubeMusicWatchURL(videoID) == "" {
		return ytmusicCredit{}
	}
	ytmusicCreditMu.Lock()
	c, ok := ytmusicCreditCache[videoID]
	ytmusicCreditMu.Unlock()
	if ok {
		return c
	}
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	if client, ok := body["context"].(map[string]any)["client"].(map[string]any); ok {
		client["hl"] = "en"
	}
	body["videoId"] = videoID
	body["isAudioOnly"] = true
	raw, err := ytmusicPost(ctx, "next", body, ytmusicCachedVisitorID())
	if err != nil || len(raw) == 0 {
		return ytmusicCredit{}
	}
	c = ytmusicCreditFromNext(raw, videoID)
	ytmusicCreditMu.Lock()
	ytmusicCreditCache[videoID] = c
	ytmusicCreditMu.Unlock()
	return c
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
		out.album = strings.TrimSpace(ytmusicCreditAlbumRun(r["longBylineText"]))
	})
	return out
}

// ytmusicCreditAlbumRun:署名行里链到专辑页(MUSIC_PAGE_TYPE_ALBUM)的那一段。音轨版本才有,MV / 视频那一段是播放量。
func ytmusicCreditAlbumRun(node any) string {
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
			return text
		}
	}
	return ""
}

// ytmusicCreditRetryAfter:后台没问成(网络、地区限制)之后,同一个 videoId 隔多久再问。
const ytmusicCreditRetryAfter = time.Minute

// ytmusicCreditFetchTimeout:后台问一次的上限。
const ytmusicCreditFetchTimeout = 15 * time.Second

var (
	// ytmusicCreditPending:正在后台问的 videoId;ytmusicCreditFailedAt:后台没问成的时刻。都在 ytmusicCreditMu 里读写。
	ytmusicCreditPending  = map[string]bool{}
	ytmusicCreditFailedAt = map[string]time.Time{}
)

// ytmusicCreditCachedOrFetch:记下的结论有就给;没有就后台问一次(同一个 videoId 同时只问一次,没问成隔
// ytmusicCreditRetryAfter 再问),这一回先给空。轮询每拍都来问,不能在这里同步联网。
func ytmusicCreditCachedOrFetch(videoID string) ytmusicCredit {
	if youtubeMusicWatchURL(videoID) == "" {
		return ytmusicCredit{}
	}
	ytmusicCreditMu.Lock()
	defer ytmusicCreditMu.Unlock()
	if c, ok := ytmusicCreditCache[videoID]; ok {
		return c
	}
	if ytmusicCreditPending[videoID] || time.Since(ytmusicCreditFailedAt[videoID]) < ytmusicCreditRetryAfter {
		return ytmusicCredit{}
	}
	ytmusicCreditPending[videoID] = true
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), ytmusicCreditFetchTimeout)
		defer cancel()
		ytmusicEnglishCredit(ctx, videoID)
		ytmusicCreditMu.Lock()
		defer ytmusicCreditMu.Unlock()
		delete(ytmusicCreditPending, videoID)
		if _, ok := ytmusicCreditCache[videoID]; !ok {
			ytmusicCreditFailedAt[videoID] = time.Now()
		}
	}()
	return ytmusicCredit{}
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
