package main

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// config.json 在常驻进程里热重读:设置页改了账号凭据、推送、状态中继,collector 不用重启。
//
// 做法与 features()(featuresreload.go)一致:一份原子快照,每 configReloadInterval 最多探一次盘,
// mtime 或 size 变了才重读。liveConfig() 给出的 *config 是只读快照,调用方不许改它的字段。
//
// 读取方分两类,新加读点时照这个分:
//   - poller 主循环每一拍经 syncLiveConfig 换上新快照,顺带重建推送通道与 Last.fm 镜像写入。
//     p.cfg / p.lfm / p.lb.alerter 因此只在主循环 goroutine 上读写,别在别的 goroutine 里碰它们。
//   - 其它 goroutine(LB 提交、封面补传)经 liveConfig() 或 artworkRelayTarget() 这类访问函数现读。
//
// 边界:
//  1. 坏文件不覆盖好配置。整份 JSON 语法坏了(比如读到半截)就保留当前快照;单个字段格式不对,
//     照 loadConfig 的口径只跳过那个字段。文件被删掉也保留当前快照。
//  2. CLI 子命令不热重读:它们不登记路径,liveConfig() 返回 nil,各处退回自己手里那份 cfg。
const configReloadInterval = 1 * time.Second

var (
	configSnapshot  atomic.Pointer[config]
	configPath      atomic.Pointer[string]
	configCheckedAt atomic.Int64 // 上次探盘的时刻(UnixNano)
	configMTime     atomic.Int64
	configSize      atomic.Int64
	// configReloadMu 串行化"重读 + 应用改动",两个 goroutine 同时撞上文件变化时只应用一次。
	configReloadMu sync.Mutex
)

// liveConfig 取这一刻生效的 config.json 快照;没登记路径(CLI 子命令、测试)时返回 nil。
func liveConfig() *config {
	maybeReloadConfig()
	return configSnapshot.Load()
}

// setLiveConfig 登记 config.json 的位置和启动时读到的那份配置,并把文件当下的 mtime/size 作为基线。
// 只有常驻进程调用。path 为空时撤销登记(测试收尾用)。
func setLiveConfig(path string, cfg *config) {
	if path == "" {
		configPath.Store(nil)
		configSnapshot.Store(nil)
		return
	}
	p := path
	configSnapshot.Store(cfg)
	configPath.Store(&p)
	configCheckedAt.Store(time.Now().UnixNano())
	configMTime.Store(0)
	configSize.Store(0)
	if st, err := os.Stat(path); err == nil {
		configMTime.Store(st.ModTime().UnixNano())
		configSize.Store(st.Size())
	}
}

func maybeReloadConfig() {
	pp := configPath.Load()
	if pp == nil || *pp == "" {
		return
	}
	now := time.Now().UnixNano()
	last := configCheckedAt.Load()
	if now-last < int64(configReloadInterval) {
		return
	}
	if !configCheckedAt.CompareAndSwap(last, now) {
		return
	}
	st, err := os.Stat(*pp)
	if err != nil {
		return // 读不到(被换名的那一瞬间、被删掉):保留当前快照
	}
	mtime, size := st.ModTime().UnixNano(), st.Size()
	if mtime == configMTime.Load() && size == configSize.Load() {
		return
	}
	configReloadMu.Lock()
	defer configReloadMu.Unlock()
	if mtime == configMTime.Load() && size == configSize.Load() {
		return // 另一个 goroutine 刚应用过这一版
	}
	configMTime.Store(mtime)
	configSize.Store(size)
	data, err := os.ReadFile(*pp)
	if err != nil {
		log.Printf("config: %s changed but is unreadable (%v), keeping the settings currently in effect", *pp, err)
		return
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(data, &probe); err != nil {
		// mtime 已经推进:同一份坏文件不必每秒重试,等它下次真被改写。
		log.Printf("config: %s changed but is not valid JSON (%v), keeping the settings currently in effect", *pp, err)
		return
	}
	next := configFromBytes(data)
	for _, issue := range next.loadIssues {
		log.Printf("config: %s", issue)
	}
	prev := configSnapshot.Load()
	configSnapshot.Store(next)
	applyConfigChange(prev, next)
}

// applyConfigChange 处理那些不在读点上现读、要在换快照时顺手做掉的事。推送通道和 Last.fm 镜像写入
// 由 poller 主循环自己换(syncLiveConfig),不在这里。
func applyConfigChange(prev, next *config) {
	applyLogLevel(next.LogLevel)
	if prev == nil || prev.StateRelayURL != next.StateRelayURL || prev.StateRelayToken != next.StateRelayToken {
		switchStateRelay(next.StateRelayURL, next.StateRelayToken)
	}
	log.Printf("config: reloaded without a restart changed=%s", strings.Join(changedConfigKeys(prev, next), ","))
}

// changedConfigKeys 列出两份配置之间变了的 JSON 键名(只有键名,不含值:值里有凭据)。
func changedConfigKeys(prev, next *config) []string {
	fields := func(c *config) map[string]json.RawMessage {
		out := map[string]json.RawMessage{}
		if c == nil {
			return out
		}
		b, err := json.Marshal(c)
		if err == nil {
			_ = json.Unmarshal(b, &out)
		}
		return out
	}
	a, b := fields(prev), fields(next)
	var changed []string
	for k, v := range b {
		if !bytes.Equal(a[k], v) {
			changed = append(changed, k)
		}
	}
	for k := range a {
		if _, ok := b[k]; !ok {
			changed = append(changed, k)
		}
	}
	sort.Strings(changed)
	return changed
}

// syncLiveConfig 在 poller 主循环上换上最新的 config.json 快照,并按需重建推送通道和 Last.fm 镜像写入。
// 没登记热重读(测试、CLI)时什么都不做,poller 用构造时给的那份。
func (p *poller) syncLiveConfig() {
	next := liveConfig()
	if next == nil {
		return
	}
	if next != p.cfg {
		prev := p.cfg
		p.cfg = next
		if p.lb != nil && (prev == nil || notifyTarget(prev) != notifyTarget(next)) {
			p.lb.alerter = alerterFromConfig(next)
		}
	}
	// Last.fm 镜像写入还吃 features.json 的 lastfm_mirror_scrobble 开关,所以每拍都比一次,不只在
	// config.json 变了的时候。
	if want := lastfmScrobblerKeyOf(p.cfg); want != p.lfmKey {
		p.lfmKey = want
		p.lfm = lastfmScrobblerIfEnabled(p.cfg)
		log.Printf("config: lastfm mirror writer rebuilt enabled=%v", p.lfm != nil)
	}
}

// notifyTarget 是推送通道用到的全部配置字段,任一变了就要重建 alerter。
type notifyTargetFields struct {
	platform, url, dingtalkSecret, feishuSecret, telegramChatID string
}

func notifyTarget(c *config) notifyTargetFields {
	return notifyTargetFields{c.NotificationPlatform, c.NotificationWebhookURL, c.DingtalkSignSecret, c.FeishuSignSecret, c.TelegramChatID}
}

func alerterFromConfig(c *config) *alerter {
	return newAlerter(c.NotificationPlatform, c.NotificationWebhookURL, c.DingtalkSignSecret, c.FeishuSignSecret, c.TelegramChatID)
}

// lastfmScrobblerKey 是 lastfmScrobblerIfEnabled 的全部输入。相同就沿用现有的 writer:它身上有
// 「凭据已判死」这类状态,凭据没换时不该被一次无关的保存清掉。
type lastfmScrobblerKey struct {
	enabled                bool
	apiKey, secret, sk, ro string
}

func lastfmScrobblerKeyOf(c *config) lastfmScrobblerKey {
	if c == nil {
		return lastfmScrobblerKey{}
	}
	return lastfmScrobblerKey{
		enabled: features().LastfmMirrorScrobble,
		apiKey:  c.LastfmScrobbleAPIKey, secret: c.LastfmScrobbleSecret, sk: c.LastfmScrobbleSessionKey,
		ro: c.lastfmBridgeAPIKey(),
	}
}
