// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"net/http"
	"strings"
	"time"
)

// relayState converts a snapshot (+ playing/device/listenedAt) into the exact
// JSON shape the web reads from the state relay's /now (same shape the worker's
// LB-fallback produces). Reuses lbMeta so all the enrichment (cover/accent/
// lyrics/links/progress) is computed once and not duplicated.
// relayState 构造推给网页的当前状态。current 显式区分两种"listenedAt 缺失"语义,
// 网页据此决定要不要跟本地缓存的"最近一次正在播放"比新旧:
//   - current=true:  Mac/iPhone 此刻活跃的曲目(哪怕暂停),是"当下真相",永远直接显示;
//   - current=false: 纯历史的"上次播放"(用户已退出播放器),可能滞后,才需跟缓存比较。
//
// 不这样显式区分的话,"暂停中的活跃曲目"因为没有 listenedAt(语义上合理:它不是一条完成
// 收听记录)会被网页误判成"数据不可信",从而被本地缓存里几天前的旧记录顶替显示。
func relayState(s snapshot, playing bool, device string, listenedAt int64, current bool) map[string]any {
	meta := lbMeta(s)
	ai := meta.AdditionalInfo
	if device == "" {
		if v, _ := ai["source"].(string); v != "" {
			device = v
		}
	}
	// 歌词字段不能从 ai(=lbMeta 的 AdditionalInfo)里取——那份数据已经按 ListenBrainz
	// 单条 listen ≤10240 字节的硬上限裁剪过(lb.go 的 budget 循环,按 原文>翻译>罗马音>
	// 逐字 优先级加入,超预算的字段整个丢弃、逐字数据体积最大最先被丢),这个预算是
	// LB API 自己的限制,状态中继/网页并不受它约束。这里改为直接从 trackEnrichment
	// 现拿一份未裁剪的完整歌词字段——enrichCache 在 lbMeta 内部已经解析过一次,这里
	// 只是再查一次内存缓存,没有额外网络开销。
	// isNewTrack 传 false,理由同 lb.go 那处同名调用——这里也只是再查一次内存缓存。
	enr := trackEnrichment(s.Artist, s.Title, s.Album, s.Bundle, s.Duration, false)
	st := map[string]any{
		"ok": true, "playing": playing, "current": current,
		// artist 用 meta.ArtistName(可能已被网易云/QQ 音乐核实的官方写法覆盖,统一大小写/
		// 中英文——见 lbMeta),不用 s.Artist 原始标签,让"正在播放"卡片和历史列表用同一版本。
		"title": meta.TrackName, "artist": meta.ArtistName, "album": meta.ReleaseName,
		// artwork 已经在 lbMeta 里过了 webSafeCoverURL 那道闸(见 lb.go 那处注释):
		// 设备直送封面在缓存里是 file:// 本地路径,这里拿到的是中继上的 https 地址,
		// 或者干脆是空串。**这里不该再看到 file://** —— 真看到了就是那道闸漏了。
		"artwork": ai["cover_url"], "accent": ai["accent_color"], "device": device,
		"lyrics": enr["lyrics"], "lyricsTr": enr["lyrics_tr"], "lyricsRoma": enr["lyrics_roma"], "lyricsYRC": enr["lyrics_yrc"],
		// 封面/歌词实际来自哪个平台("netease"/"qq"/"lrclib"/"amll"…),供网页页脚如实展示。
		"coverSource": ai["cover_source"], "lyricsSource": ai["lyrics_source"],
		// 这条 listen 实际是哪个播放器放的("Apple Music (macOS)"/"QQ Music (macOS)"/
		// "NetEase Cloud Music (macOS)"/"Spotify (macOS)"/"Apple Music (iOS)",见
		// mediaPlayerLabel)。网页页脚原来写死 "Apple Music",用 QQ 音乐/网易云听歌时
		// 那一行是错的。这个值早就在 additional_info 里交给 ListenBrainz 了,只是没往
		// 中继这条路径带。
		"mediaPlayer": ai["media_player"],
		"links":       map[string]any{"apple": ai["apple_music_url"], "qq": ai["qq_music_url"], "netease": ai["netease_url"], "spotify": ai["spotify_url"]},
		"durationMs":  ai["duration_ms"], "progressMs": ai["progress_ms"], "progressTs": ai["progress_ts"], "rate": ai["playback_rate"],
	}
	if listenedAt > 0 {
		st["listenedAt"] = listenedAt
	}
	return st
}

// postRelay POSTs a JSON body to the state relay (path "/push"), authenticated
// with the shared token. No-op if the relay isn't configured.
func postRelay(ctx context.Context, cfg *config, path string, payload any) error {
	if cfg.StateRelayURL == "" {
		return nil
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(cfg.StateRelayURL, "/")+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-token", cfg.StateRelayToken)
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("relay %s: status %d", path, resp.StatusCode)
	}
	return nil
}
