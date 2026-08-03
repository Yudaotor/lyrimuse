// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"net/http"
	neturl "net/url"
	"sync"
	"time"
)

// lrclibLyric 是网易云/QQ 音乐都没能给出逐行歌词时的第三档兜底。LRCLIB(lrclib.net)
// 是免费、无需 key 的开源逐行 LRC 歌词库，对网易云/QQ 音乐这类中文平台曲库覆盖偏弱的
// 欧美/R&B 等曲目往往有收录。只缓存"拿到有效逐行歌词"的结果，跟 qqLyric 的缓存策略一致。
// lrclibResult.title/artist/album 是 LRCLIB 收录的这首歌的 trackName/artistName/
// albumName——纯粹给"搜索候选歌词"弹窗展示用,不参与任何匹配/打分逻辑,取自 /api/get
// 响应本身(本来就已经查到,只是原来只挑了 syncedLyrics 就把其余字段丢了)。LRCLIB 的
// API 没有封面图字段,这个来源永远给不出封面,不是没查、是压根不存在。
type lrclibResult struct {
	lyrics, title, artist, album string
}

var (
	lrclibMu    sync.Mutex
	lrclibCache = map[string]lrclibResult{} // artist|title|album -> result
)

func lrclibLyric(artist, title, album string) lrclibResult {
	if title == "" {
		return lrclibResult{}
	}
	key := artist + "|" + title + "|" + album
	lrclibMu.Lock()
	if v, ok := lrclibCache[key]; ok {
		lrclibMu.Unlock()
		return v
	}
	lrclibMu.Unlock()

	r := resolveLRCLIBLyric(artist, title, album)
	if r.lyrics != "" {
		lrclibMu.Lock()
		lrclibCache[key] = r
		lrclibMu.Unlock()
	}
	return r
}

func resolveLRCLIBLyric(artist, title, album string) lrclibResult {
	u := "https://lrclib.net/api/get?artist_name=" + neturl.QueryEscape(artist) +
		"&track_name=" + neturl.QueryEscape(title)
	if album != "" {
		u += "&album_name=" + neturl.QueryEscape(album)
	}
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return lrclibResult{}
	}
	// LRCLIB 的使用规范要求带上能标识调用方的 User-Agent。
	req.Header.Set("User-Agent", clientName+"/"+clientVersion+" (+https://github.com/Yudaotor/desktop-lyrics-suite)")
	// lrclib.net 比网易云/QQ 音乐慢不少,给足余量避免临界超时。
	resp, err := doHTTPTracked(&http.Client{Timeout: 10 * time.Second}, req)
	if err != nil {
		return lrclibResult{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return lrclibResult{} // 404(未收录)或其它错误一律放弃,不重试;下次 enrich 短 TTL 到期自然再试
	}
	var out struct {
		Instrumental bool   `json:"instrumental"`
		SyncedLyrics string `json:"syncedLyrics"`
		TrackName    string `json:"trackName"`
		ArtistName   string `json:"artistName"`
		AlbumName    string `json:"albumName"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return lrclibResult{}
	}
	if out.Instrumental || !isTimedLRC(out.SyncedLyrics) {
		return lrclibResult{}
	}
	return lrclibResult{lyrics: out.SyncedLyrics, title: out.TrackName, artist: out.ArtistName, album: out.AlbumName}
}
