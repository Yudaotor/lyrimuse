// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"os"
	"os/exec"
)

type config struct {
	Token            string   `json:"listenbrainz_token"`
	User             string   `json:"listenbrainz_user,omitempty"`
	APIRoot          string   `json:"api_root,omitempty"`
	MediaControlPath string   `json:"media_control_path,omitempty"`
	BundleIDs        []string `json:"bundle_ids,omitempty"`
	// 自建状态中继(Cloudflare Worker+KV,取代 LB 作网页主数据源)。留空则不推。
	// StateRelayURL 形如 https://np.yudaotor.me;/push 写当前状态。历史现在完全走
	// state-worker 的 /history 端点读 LB 合并,采集器不再往这里写 /scrobble(旧端点
	// 早已下线,见 state-worker/src/index.js 顶部注释)。
	StateRelayURL   string `json:"state_relay_url,omitempty"`
	StateRelayToken string `json:"state_relay_token,omitempty"`
	// Last.fm 桥接：Mac 本地没在放时，把 iPhone(经 FastScrobbler→Last.fm)的
	// "正在播放"转发进 LB，让网页也显示手机上的播放。两者留空则不启用桥接。
	LastfmUser   string `json:"lastfm_user,omitempty"`
	LastfmAPIKey string `json:"lastfm_api_key,omitempty"`
	// Last.fm 镜像写入(独立于上面的桥接读取):把 Mac 播放也写进 Last.fm,让 Last.fm
	// 上留一份完整历史(不含 iPhone——那些数据本来就来自 Last.fm,镜像回去会自环)。
	// 三者都非空才启用。凭证经一次性网页 OAuth 式授权换取,session key 永久有效。
	LastfmScrobbleAPIKey     string `json:"lastfm_scrobble_api_key,omitempty"`
	LastfmScrobbleSecret     string `json:"lastfm_scrobble_secret,omitempty"`
	LastfmScrobbleSessionKey string `json:"lastfm_scrobble_session_key,omitempty"`
	// Bark 推送端点(base URL, https://api.day.app/<key>)：LB 连不上或读不到播放
	// 状态持续异常时推手机告警。留空则不告警。
	BarkURL string `json:"bark_url,omitempty"`
}

func loadConfig(path string) (*config, error) {
	cfg := &config{}
	data, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(data, cfg); err != nil {
			return nil, fmt.Errorf("parse config %s: %w", path, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	if v := os.Getenv("LISTENBRAINZ_TOKEN"); v != "" {
		cfg.Token = v
	}
	if cfg.APIRoot == "" {
		cfg.APIRoot = "https://api.listenbrainz.org"
	}
	if len(cfg.BundleIDs) == 0 {
		cfg.BundleIDs = []string{"com.apple.Music"}
	}
	if cfg.MediaControlPath == "" {
		if p, err := exec.LookPath("media-control"); err == nil {
			cfg.MediaControlPath = p
		} else {
			cfg.MediaControlPath = "/opt/homebrew/bin/media-control"
		}
	}
	return cfg, nil
}
