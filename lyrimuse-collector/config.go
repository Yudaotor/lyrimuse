// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"os"
)

type config struct {
	Token     string   `json:"listenbrainz_token"`
	User      string   `json:"listenbrainz_user,omitempty"`
	APIRoot   string   `json:"api_root,omitempty"`
	BundleIDs []string `json:"bundle_ids,omitempty"`
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
	// 推送提醒目的地：LB 连不上或读不到播放状态持续异常时推一条告警,每周听歌小结也走
	// 这个通道。NotificationPlatform 选平台("bark"默认/"dingtalk"/"wecom"/"discord"/
	// "feishu"/"serverchan"),NotificationWebhookURL 是对应平台的 webhook 地址,留空
	// 则不推。
	//
	// 这个字段最早只支持 Bark、就叫 BarkURL,JSON key 也是 bark_url——加了平台选择
	// 之后没有把 on-disk key 一起改名(改 key 要处理旧配置迁移,这里 Go 字段名换成
	// 通用的 NotificationWebhookURL 就已经足够反映"不只是 Bark 专属"这件事,JSON tag
	// 留着旧名字不影响任何人,还省了一次没必要的迁移)。
	NotificationPlatform   string `json:"notification_platform,omitempty"`
	NotificationWebhookURL string `json:"bark_url,omitempty"`
	// DingtalkSignSecret/FeishuSignSecret 只有对应平台的机器人开了"加签"安全设置时
	// 才需要填;留空则按未加签处理(钉钉要求机器人安全设置改成"自定义关键词"或不做
	// 校验;飞书不加签也能收到消息,只是少一层来源校验)。两个平台的签名算法本身不同
	// (细节见 notify.go 的 dingtalkSignedURL/feishuSign 注释),分开两个字段存,切换
	// 平台时不会互相污染。
	DingtalkSignSecret string `json:"dingtalk_sign_secret,omitempty"`
	FeishuSignSecret   string `json:"feishu_sign_secret,omitempty"`
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
	if cfg.NotificationPlatform == "" {
		// 旧配置文件没有这个字段(是这次新加的),默认按最早唯一支持过的 Bark 处理,
		// 不需要用户重新选一遍。
		cfg.NotificationPlatform = "bark"
	}
	return cfg, nil
}
