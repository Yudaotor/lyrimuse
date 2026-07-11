// Command feishu-bot maintains a Feishu long-connection (WebSocket) client that
// answers url.preview.get callbacks with an "Apple Music now playing" card.
//
// It reads the current track from ListenBrainz (fed by the collector) and
// returns an inline preview. Album art is uploaded to Feishu on demand and
// cached per track; if the app has no image permission yet, it degrades to a
// text-only card.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	lark "github.com/larksuite/oapi-sdk-go/v3"
	larkcore "github.com/larksuite/oapi-sdk-go/v3/core"
	"github.com/larksuite/oapi-sdk-go/v3/event/dispatcher"
	"github.com/larksuite/oapi-sdk-go/v3/event/dispatcher/callback"
	larkim "github.com/larksuite/oapi-sdk-go/v3/service/im/v1"
	larkws "github.com/larksuite/oapi-sdk-go/v3/ws"
)

type config struct {
	AppID     string `json:"feishu_app_id"`
	AppSecret string `json:"feishu_app_secret"`
	LBUser    string `json:"listenbrainz_user"`
	LBAPI     string `json:"lb_api,omitempty"`
	UploadArt *bool  `json:"upload_art,omitempty"` // set false to force text-only
	// RelayURL(可选)：自建 state-worker 地址(如 https://np.yudaotor.me)。配置后优先读它的
	// /now(已经是国内可达、带封面的归一化数据),失败才退回直连 LB+iTunes(旧行为)。留空
	// 就是旧行为——这个 bot 之前完全绕开 state-worker,独立直连 LB 和 iTunes,等于把
	// "国内访问加速"这个 state-worker 存在的意义又重新踩了一遍坑。
	RelayURL string `json:"state_relay_url,omitempty"`
}

func loadConfig(path string) (*config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	cfg := &config{}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if cfg.AppID == "" || cfg.AppSecret == "" {
		return nil, errors.New("feishu_app_id / feishu_app_secret required")
	}
	if cfg.LBUser == "" {
		return nil, errors.New("listenbrainz_user required")
	}
	if cfg.LBAPI == "" {
		cfg.LBAPI = "https://api.listenbrainz.org"
	}
	return cfg, nil
}

type snapshot struct {
	Title, Artist, Album string
	Playing              bool
}

type nowPlayingBot struct {
	cfg      *config
	lark     *lark.Client
	hc       *http.Client
	mu       sync.Mutex
	artKey   map[string]string        // "artist|title" -> feishu image_key
	inflight map[string]chan struct{} // 正在解析中的 "artist|title" -> 完成时关闭通知等待者;见 imageKey
}

func (b *nowPlayingBot) handleURLPreview(ctx context.Context, ev *callback.URLPreviewGetEvent) (*callback.URLPreviewGetResponse, error) {
	host, url := "", ""
	if ev.Event != nil {
		host = ev.Event.Host
		if ev.Event.Context != nil {
			url = ev.Event.Context.URL
		}
	}
	snap, artworkURL, err := b.nowPlaying(ctx)
	if err != nil {
		log.Printf("nowPlaying error: %v", err)
	}
	inline := b.buildInline(ctx, snap, artworkURL)
	log.Printf("callback url.preview.get host=%q url=%q -> title=%q", host, url, inline.I18nTitle["zh_cn"])
	return &callback.URLPreviewGetResponse{Inline: inline}, nil
}

// buildInline 拼预览卡片。artworkURL 是 nowPlaying() 已经拿到的封面(relay 命中时才有,
// 否则是空串)，传给 imageKey() 省一次 iTunes 兜底查询。
func (b *nowPlayingBot) buildInline(ctx context.Context, snap *snapshot, artworkURL string) *callback.Inline {
	if snap == nil || snap.Title == "" {
		return &callback.Inline{I18nTitle: map[string]string{"zh_cn": "🎧 这会儿没在听歌"}}
	}
	prefix := "🎧 上次播放"
	if snap.Playing {
		prefix = "♪ 正在播放"
	}
	title := fmt.Sprintf("%s｜%s — %s", prefix, snap.Title, snap.Artist)
	inline := &callback.Inline{I18nTitle: map[string]string{"zh_cn": title}}
	if b.cfg.UploadArt == nil || *b.cfg.UploadArt {
		if key := b.imageKey(ctx, snap, artworkURL); key != "" {
			inline.ImageKey = key
		}
	}
	return inline
}

// ---- ListenBrainz ---------------------------------------------------------

// lbListensResponse is the shape of both /playing-now and /listens?count=N —
// only the three fields this bot actually displays (title/artist/album; no
// additional_info, unlike state-worker/web.js's much richer LB normalization,
// see README "内部子系统" 一节).
type lbListensResponse struct {
	Payload struct {
		Listens []struct {
			TrackMetadata struct {
				TrackName   string `json:"track_name"`
				ArtistName  string `json:"artist_name"`
				ReleaseName string `json:"release_name"`
			} `json:"track_metadata"`
		} `json:"listens"`
	} `json:"payload"`
}

// relayNowResponse 是 state-worker /now 的响应形状(见 state-worker/src/index.js
// fromLB()/relayState()),这里只取用得到的字段。
type relayNowResponse struct {
	OK      bool   `json:"ok"`
	Empty   bool   `json:"empty"`
	Title   string `json:"title"`
	Artist  string `json:"artist"`
	Album   string `json:"album"`
	Playing bool   `json:"playing"`
	Artwork string `json:"artwork"`
}

// nowPlaying 返回当前(或最近一次)播放快照，以及一个可能为空的封面 URL(relay 命中时
// 才有)。优先读自建 state-worker 的 /now(国内可达、已经归一化好),失败才退回直连
// LB+iTunes(nowPlayingDirect,旧行为)——没配 RelayURL 就直接走旧行为。
func (b *nowPlayingBot) nowPlaying(ctx context.Context) (*snapshot, string, error) {
	if b.cfg.RelayURL != "" {
		var r relayNowResponse
		if err := b.getJSON(ctx, strings.TrimRight(b.cfg.RelayURL, "/")+"/now", &r); err != nil {
			log.Printf("relay /now failed, falling back to direct LB: %v", err)
		} else if r.Empty || r.Title == "" {
			return nil, "", nil // 真的没在听,不是错误,不用退回直连
		} else {
			return &snapshot{Title: r.Title, Artist: r.Artist, Album: r.Album, Playing: r.Playing}, r.Artwork, nil
		}
	}
	snap, err := b.nowPlayingDirect(ctx)
	return snap, "", err
}

func (b *nowPlayingBot) nowPlayingDirect(ctx context.Context) (*snapshot, error) {
	base := b.cfg.LBAPI + "/1/user/" + b.cfg.LBUser
	var pn lbListensResponse
	if err := b.getJSON(ctx, base+"/playing-now", &pn); err != nil {
		return nil, err
	}
	if len(pn.Payload.Listens) > 0 {
		m := pn.Payload.Listens[0].TrackMetadata
		return &snapshot{Title: m.TrackName, Artist: m.ArtistName, Album: m.ReleaseName, Playing: true}, nil
	}
	var re lbListensResponse
	if err := b.getJSON(ctx, base+"/listens?count=1", &re); err != nil {
		return nil, err
	}
	if len(re.Payload.Listens) > 0 {
		m := re.Payload.Listens[0].TrackMetadata
		return &snapshot{Title: m.TrackName, Artist: m.ArtistName, Album: m.ReleaseName}, nil
	}
	return nil, nil
}

// ---- album art -> feishu image_key ----------------------------------------

// imageKey 返回歌曲封面对应的飞书 image_key，命中缓存直接返回。同一首"还没解析过"的
// 新歌被多个并发请求同时命中时，只有一个真正去下载+上传，其余排队等它做完直接复用
// 结果——修复之前完全没有并发去重、同一首新歌被多人几乎同时预览就各自触发一遍下载/
// 上传的问题。artworkURL 是调用方(nowPlaying 经 relay)已经拿到的封面，非空时跳过
// iTunes 兜底查询。
func (b *nowPlayingBot) imageKey(ctx context.Context, snap *snapshot, artworkURL string) string {
	cacheKey := snap.Artist + "|" + snap.Title
	b.mu.Lock()
	if k, ok := b.artKey[cacheKey]; ok {
		b.mu.Unlock()
		return k
	}
	if ch, ok := b.inflight[cacheKey]; ok {
		b.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			return ""
		}
		// 醒来后只再查一次缓存:那一轮解析成功才会有值,失败就跟它一样返回空——不在
		// 这里重新发起一次新的解析。否则解析失败时,所有等待者会各自重试一遍下载/
		// 上传,完全抵消掉这个函数本来要去掉的重复请求(下次独立的 imageKey 调用仍会
		// 正常重试,不受影响)。
		b.mu.Lock()
		k := b.artKey[cacheKey]
		b.mu.Unlock()
		return k
	}
	ch := make(chan struct{})
	b.inflight[cacheKey] = ch
	b.mu.Unlock()

	key := b.resolveImageKey(ctx, snap, artworkURL)
	if key != "" {
		b.mu.Lock()
		b.artKey[cacheKey] = key
		b.mu.Unlock()
	}
	b.mu.Lock()
	delete(b.inflight, cacheKey)
	b.mu.Unlock()
	close(ch)
	return key
}

func (b *nowPlayingBot) resolveImageKey(ctx context.Context, snap *snapshot, artworkURL string) string {
	if artworkURL == "" {
		artworkURL = b.artworkURL(ctx, snap) // relay 没给封面(或没配置 relay)时退回 iTunes 直连兜底
	}
	if artworkURL == "" {
		return ""
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, artworkURL, nil)
	resp, err := b.hc.Do(req)
	if err != nil {
		log.Printf("download art: %v", err)
		return ""
	}
	defer resp.Body.Close()
	imgBytes, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return ""
	}

	createReq := larkim.NewCreateImageReqBuilder().
		Body(larkim.NewCreateImageReqBodyBuilder().
			ImageType(larkim.CreateImageImageTypeMessage).
			Image(bytes.NewReader(imgBytes)).
			Build()).
		Build()
	createResp, err := b.lark.Im.Image.Create(ctx, createReq)
	if err != nil {
		log.Printf("upload image: %v", err)
		return ""
	}
	if !createResp.Success() {
		log.Printf("upload image failed: code=%d msg=%s", createResp.Code, createResp.Msg)
		return ""
	}
	if createResp.Data != nil && createResp.Data.ImageKey != nil {
		return *createResp.Data.ImageKey
	}
	return ""
}

func (b *nowPlayingBot) artworkURL(ctx context.Context, snap *snapshot) string {
	var out struct {
		Results []struct {
			ArtworkURL100 string `json:"artworkUrl100"`
		} `json:"results"`
	}
	u := "https://itunes.apple.com/search?media=music&entity=song&limit=1&term=" +
		urlQueryEscape(snap.Artist+" "+snap.Title)
	if err := b.getJSON(ctx, u, &out); err != nil {
		log.Printf("itunes artwork search failed for %q - %q: %v", snap.Artist, snap.Title, err)
		return ""
	}
	if len(out.Results) == 0 {
		return ""
	}
	url100 := out.Results[0].ArtworkURL100
	if url100 == "" {
		return ""
	}
	return replaceLast(url100, "100x100bb", "600x600bb")
}

// ---- helpers --------------------------------------------------------------

func (b *nowPlayingBot) getJSON(ctx context.Context, url string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := b.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s -> %d", url, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

func urlQueryEscape(s string) string {
	var buf bytes.Buffer
	for _, r := range []byte(s) {
		if r == ' ' {
			buf.WriteByte('+')
		} else if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			buf.WriteByte(r)
		} else {
			fmt.Fprintf(&buf, "%%%02X", r)
		}
	}
	return buf.String()
}

func replaceLast(s, old, new string) string {
	i := bytesLastIndex(s, old)
	if i < 0 {
		return s
	}
	return s[:i] + new + s[i+len(old):]
}

func bytesLastIndex(s, sub string) int {
	for i := len(s) - len(sub); i >= 0; i-- {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func main() {
	log.SetFlags(log.LstdFlags)
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("home dir: %v", err)
	}
	cfgPath := filepath.Join(home, ".config", "applemusic-nowplaying", "feishu.json")
	if len(os.Args) > 1 {
		cfgPath = os.Args[1]
	}
	cfg, err := loadConfig(cfgPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	bot := &nowPlayingBot{
		cfg:      cfg,
		lark:     lark.NewClient(cfg.AppID, cfg.AppSecret),
		hc:       &http.Client{Timeout: 4 * time.Second},
		artKey:   map[string]string{},
		inflight: map[string]chan struct{}{},
	}

	handler := dispatcher.NewEventDispatcher("", "").
		OnP2CardURLPreviewGet(bot.handleURLPreview)

	cli := larkws.NewClient(cfg.AppID, cfg.AppSecret,
		larkws.WithEventHandler(handler),
		larkws.WithLogLevel(larkcore.LogLevelInfo),
	)

	log.Printf("feishu-bot starting (app=%s, lb_user=%s)", cfg.AppID, cfg.LBUser)
	if err := cli.Start(context.Background()); err != nil {
		log.Fatalf("ws client stopped: %v", err)
	}
}
