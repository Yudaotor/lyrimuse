// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
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
// 欧美/R&B 等曲目往往有收录——实测坐实：Musiq Soulchild《Time》网易云的歌词接口只返回
// 作词/作曲 credit 信息占位(无真正歌词正文)、QQ 音乐搜索直接找不到这首歌，LRCLIB 却有
// 完整的逐行歌词。只缓存"拿到有效逐行歌词"的结果，跟 qqLyric 的缓存策略一致。
var (
	lrclibMu    sync.Mutex
	lrclibCache = map[string]string{} // artist|title|album -> syncedLyrics
)

func lrclibLyric(artist, title, album string) string {
	if title == "" {
		return ""
	}
	key := artist + "|" + title + "|" + album
	lrclibMu.Lock()
	if v, ok := lrclibCache[key]; ok {
		lrclibMu.Unlock()
		return v
	}
	lrclibMu.Unlock()

	l := resolveLRCLIBLyric(artist, title, album)
	if l != "" {
		lrclibMu.Lock()
		lrclibCache[key] = l
		lrclibMu.Unlock()
	}
	return l
}

func resolveLRCLIBLyric(artist, title, album string) string {
	u := "https://lrclib.net/api/get?artist_name=" + neturl.QueryEscape(artist) +
		"&track_name=" + neturl.QueryEscape(title)
	if album != "" {
		u += "&album_name=" + neturl.QueryEscape(album)
	}
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return ""
	}
	// LRCLIB 的使用规范要求带上能标识调用方的 User-Agent。
	req.Header.Set("User-Agent", clientName+"/"+clientVersion+" (+https://github.com/Yudaotor/desktop-lyrics-suite)")
	// 实测坐实 lrclib.net 比网易云/QQ 音乐慢不少(观测 3.6~6.9s 不等),给足余量避免临界超时。
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "" // 404(未收录)或其它错误一律放弃,不重试;下次 enrich 短 TTL 到期自然再试
	}
	var out struct {
		Instrumental bool   `json:"instrumental"`
		SyncedLyrics string `json:"syncedLyrics"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return ""
	}
	if out.Instrumental || !isTimedLRC(out.SyncedLyrics) {
		return ""
	}
	return out.SyncedLyrics
}
