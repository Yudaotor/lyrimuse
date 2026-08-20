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
	// "正在播放"转发进 LB，让网页也显示手机上的播放。LastfmUser 留空则不启用桥接;
	// 只读用的 API Key 现在跟下面的 LastfmScrobbleAPIKey 是同一套凭据(见
	// lastfmBridgeAPIKey())——LastfmAPIKey 是合并前的独立只读 Key 字段,只为了让
	// 2026-07-29 之前就配好桥接的老用户不用重新操作而继续读取,新配置不会再写入它。
	LastfmUser   string `json:"lastfm_user,omitempty"`
	LastfmAPIKey string `json:"lastfm_api_key,omitempty"`
	// Last.fm 镜像写入(独立于上面的桥接读取):把 Mac 播放也写进 Last.fm,让 Last.fm
	// 上留一份完整历史(不含 iPhone——那些数据本来就来自 Last.fm,镜像回去会自环)。
	// 三者都非空才启用镜像写入。凭证经一次性网页 OAuth 式授权换取,session key 永久
	// 有效。这套 API Key+Secret 同时也是桥接读取用的凭据(见 lastfmBridgeAPIKey())——
	// Last.fm 的只读方法不需要签名,同一对 key+secret 不必分成两套。
	LastfmScrobbleAPIKey     string `json:"lastfm_scrobble_api_key,omitempty"`
	LastfmScrobbleSecret     string `json:"lastfm_scrobble_secret,omitempty"`
	LastfmScrobbleSessionKey string `json:"lastfm_scrobble_session_key,omitempty"`
	// 推送提醒目的地：LB 连不上或读不到播放状态持续异常时推一条告警,每周听歌小结也走
	// 这个通道。NotificationPlatform 选平台("bark"默认/"dingtalk"/"wecom"/"discord"/
	// "feishu"/"serverchan"),NotificationWebhookURL 是对应平台的 webhook 地址,留空
	// 则不推。
	//
	// 字段名 NotificationWebhookURL 与 JSON tag bark_url 不一致是有意保留:这个字段
	// 最早只支持 Bark,加了平台选择后为避免旧配置迁移成本,没有把 on-disk key 一并
	// 改名——Go 字段名换成通用名字就已经足够反映"不只是 Bark 专属"。
	NotificationPlatform   string `json:"notification_platform,omitempty"`
	NotificationWebhookURL string `json:"bark_url,omitempty"`
	// DingtalkSignSecret/FeishuSignSecret 只有对应平台的机器人开了"加签"安全设置时
	// 才需要填;留空则按未加签处理(钉钉要求机器人安全设置改成"自定义关键词"或不做
	// 校验;飞书不加签也能收到消息,只是少一层来源校验)。两个平台的签名算法本身不同
	// (细节见 notify.go 的 dingtalkSignedURL/feishuSign 注释),分开两个字段存,切换
	// 平台时不会互相污染。
	DingtalkSignSecret string `json:"dingtalk_sign_secret,omitempty"`
	FeishuSignSecret   string `json:"feishu_sign_secret,omitempty"`

	// 这次加载中被跳过的字段,给调用方打日志用。小写不导出,json 包不会碰它——
	// Go 侧从来只读 config.json、不写回(写入方是 Swift 那边的 ConfigStore)。
	loadIssues []string
}

// lastfmBridgeAPIKey 解析桥接/听歌报告/Top10 歌手统计这几个只读 Last.fm 调用该用
// 哪把 Key:优先用合并后的 Scrobble API Key(账号授权那一步填的同一套凭据,只读接口
// 不需要签名,直接复用);LastfmScrobbleAPIKey 为空时兜底老字段 LastfmAPIKey,兼容
// 2026-07-29 合并之前就配好桥接、从没碰过账号授权那一步的老用户,不需要他们重新操作。
func (c *config) lastfmBridgeAPIKey() string {
	if c.LastfmScrobbleAPIKey != "" {
		return c.LastfmScrobbleAPIKey
	}
	return c.LastfmAPIKey
}

// loadConfig 读配置。**除了文件真的读不出来,它不会因为内容有问题而失败**。
//
// 原来这里是一次严格的 json.Unmarshal,任何一个字段类型写错(手改配置、旧版本写下的
// 老格式、导入了别的机器的配置)都会让 main.go 的 log.Fatalf 把进程打死;而 collector
// 挂的是 KeepAlive 的 LaunchAgent,于是变成起来就死的崩溃循环。代价完全不成比例:
// 采集播放状态、解析歌词、写本地缓存这些**核心功能一个字段都不需要**(main.go 里那句
// "no listenbrainz_token configured ... still work" 说的就是这件事),坏掉的往往只是
// 一个通知 webhook。一个字段的格式问题不该让悬浮歌词整个不显示。
//
// 所以改成逐字段解:能认的认下来,认不下来的记进 loadIssues 交给调用方打日志。
func loadConfig(path string) (*config, error) {
	cfg := &config{}
	data, err := os.ReadFile(path)
	if err == nil {
		cfg.loadIssues = decodeConfigPerField(data, cfg)
	} else if !errors.Is(err, os.ErrNotExist) {
		// 只有这一种情况仍然是硬失败:文件在那儿但读不了(权限/IO),这跟"内容有问题"
		// 不同——它意味着我们对配置一无所知,而且重试很可能还是这个结果。
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
	// 把这份配置里的凭据登记进日志脱敏表。放在 loadConfig 里而不是各个调用方那边:
	// 每个子命令都会自己 loadConfig,登记在这里就一个都漏不掉(见 logscrub.go)。
	rememberConfigSecrets(cfg)
	return cfg, nil
}

// decodeConfigPerField 把每个顶层 key 单独解一遍,一个字段的格式问题只影响它自己。
// 返回被跳过的字段说明(不含字段值——配置里有 token/secret/session key,这些串一个字
// 都不该出现在日志里)。
//
// 单独解的做法是"把这个 key 重新包成只含它的一份 JSON,再 Unmarshal 进 cfg 的副本",
// 而不是用反射按 tag 找字段:让 encoding/json 自己去做 key→字段 的映射,大小写规则、
// 内嵌类型、omitempty 这些全都跟一次性解出来时**完全一致**,不会因为手写映射而产生
// 第二套语义。副本成功了才写回 cfg,失败的那次不会留下半解析的痕迹。
func decodeConfigPerField(data []byte, cfg *config) []string {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		// 整份文件的 JSON 语法就是坏的(少个括号、逗号),没有任何字段边界可言,一个也
		// 救不回来。仍然不失败:带着默认值继续跑,采集/歌词/缓存照常。
		return []string{fmt.Sprintf("整个配置文件解析失败(%v),本次按默认值运行", err)}
	}
	var issues []string
	for key, rawVal := range raw {
		single, err := json.Marshal(map[string]json.RawMessage{key: rawVal})
		if err != nil {
			issues = append(issues, fmt.Sprintf("%q: %v", key, err))
			continue
		}
		probe := *cfg
		if err := json.Unmarshal(single, &probe); err != nil {
			issues = append(issues, fmt.Sprintf("%q 格式不对,已跳过(%v)", key, err))
			continue
		}
		*cfg = probe
	}
	return issues
}
