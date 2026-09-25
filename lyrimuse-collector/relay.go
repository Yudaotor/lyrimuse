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
	neturl "net/url"
	"strings"
	"time"
)

// webRelayURL 是"网页状态中继有没有配"的进程级镜像(取自 cfg.StateRelayURL)。
// 只为网页服务的前置计算据此整体跳过 —— 没配中继,算出来的东西没有任何消费者。
// 目前唯一的消费点是封面主色(dominantColor,见 enrich.go 两处调用与
// needsPeripheralBackfill 的 missing 判定)。
//
// **刻意跟 artworkRelayURL 分成两个变量**,尽管两者都来自 cfg.StateRelayURL:
// 那个管"设备封面要不要上传托管到中继"(还要配套 artworkRelayToken),这个只管
// "要不要算给网页看的东西"。子命令(recheck-cover)需要后者、不需要前者——
// 共用一个变量会逼它为了拿到取色而连带打开封面上传。
var webRelayURL string

func webRelayConfigured() bool {
	stateRelayMu.RLock()
	defer stateRelayMu.RUnlock()
	return webRelayURL != ""
}

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
	// 跟 lb.go 那处走同一个入口(桥接来的只查缓存,见 enrichmentFor)——这里也只是再查一次内存缓存。
	enr := enrichmentFor(s)
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

// lastListenSeed 是启动时从 ListenBrainz 取回的最近一条收听,经 lastListenSeedCh 送回主循环。
type lastListenSeed struct {
	track      snapshot
	listenedAt int64
	device     string
}

// seedLastListen 在后台取 ListenBrainz 最近一条收听,给「上次播放」补上初值。
//
// 「上次播放」(p.lastListen)只活在内存里,collector 一重启(改设置、装机、崩溃被拉起都会)就空了。
// 这时没在放歌的话,推给中继的是 {"empty":true}:飞书预览照实说「这会儿没在听歌」、网页新访客看到
// 「还没有收听记录」(实测 3742 次预览里 419 次是这样)。取不到就算了,跟原来一样推空。
func seedLastListen(ctx context.Context, root, user string, out chan<- lastListenSeed) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	u := strings.TrimRight(root, "/") + "/1/user/" + neturl.PathEscape(user) + "/listens?count=1"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	var body struct {
		Payload struct {
			Listens []struct {
				ListenedAt    int64 `json:"listened_at"`
				TrackMetadata struct {
					TrackName      string         `json:"track_name"`
					ArtistName     string         `json:"artist_name"`
					ReleaseName    string         `json:"release_name"`
					AdditionalInfo map[string]any `json:"additional_info"`
				} `json:"track_metadata"`
			} `json:"listens"`
		} `json:"payload"`
	}
	if json.NewDecoder(resp.Body).Decode(&body) != nil || len(body.Payload.Listens) == 0 {
		return
	}
	l := body.Payload.Listens[0]
	m := l.TrackMetadata
	if m.TrackName == "" || m.ArtistName == "" {
		return
	}
	device, _ := m.AdditionalInfo["source"].(string)
	seed := lastListenSeed{
		track:      snapshot{Title: m.TrackName, Artist: m.ArtistName, Album: m.ReleaseName},
		listenedAt: l.ListenedAt,
		device:     device,
	}
	select {
	case out <- seed:
	case <-ctx.Done():
	}
}
