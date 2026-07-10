// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
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
	st := map[string]any{
		"ok": true, "playing": playing, "current": current,
		// artist 用 meta.ArtistName(可能已被网易云/QQ 音乐核实的官方写法覆盖,统一大小写/
		// 中英文——见 lbMeta),不用 s.Artist 原始标签,让"正在播放"卡片和历史列表用同一版本。
		"title": meta.TrackName, "artist": meta.ArtistName, "album": meta.ReleaseName,
		"artwork": ai["cover_url"], "accent": ai["accent_color"], "device": device,
		"lyrics": ai["lyrics"], "lyricsTr": ai["lyrics_tr"], "lyricsRoma": ai["lyrics_roma"], "lyricsYRC": ai["lyrics_yrc"],
		"links":      map[string]any{"apple": ai["apple_music_url"], "qq": ai["qq_music_url"], "netease": ai["netease_url"], "spotify": ai["spotify_url"]},
		"durationMs": ai["duration_ms"], "progressMs": ai["progress_ms"], "progressTs": ai["progress_ts"], "rate": ai["playback_rate"],
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
	resp, err := http.DefaultClient.Do(req)
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
