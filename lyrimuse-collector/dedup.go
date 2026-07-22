// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"time"
)

// persistedTTLSet is a disk-backed set of unix-second timestamps ("uts"), used
// to de-duplicate against Last.fm scrobbles without a monotonic watermark
// (monotonic watermarks reject late/out-of-order scrobbles that arrive with an
// older timestamp than one already processed — a real failure mode when the
// phone-side scrobbler's background sync lags). Entries older than ttl are
// dropped on trim() so the set doesn't grow forever. forwarded/lfmMirrored in
// poller.go are the two instances (used to be two independent copies of this
// exact load/save/trim code — collapsed here since they're identical).
type persistedTTLSet struct {
	path string
	ttl  time.Duration
}

// load reads the set; the second return value is whether the file existed
// (callers use this to distinguish "first run, seed the window" from "resume").
func (s persistedTTLSet) load() (map[int64]bool, bool) {
	m := map[int64]bool{}
	if s.path == "" {
		return m, false
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return m, false
	}
	var arr []int64
	if json.Unmarshal(b, &arr) == nil {
		for _, u := range arr {
			m[u] = true
		}
	}
	return m, true
}

func (s persistedTTLSet) save(m map[int64]bool) {
	if s.path == "" {
		return
	}
	arr := make([]int64, 0, len(m))
	for u := range m {
		arr = append(arr, u)
	}
	data, err := json.Marshal(arr)
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, s.path); err != nil {
		log.Printf("save %s: %v", filepath.Base(s.path), err)
	}
}

// trim deletes entries older than ttl (relative to now) in place and reports
// whether anything was removed — callers combine this with their own
// "did I add anything this round" flag before deciding to persist, so a tick
// that both forwards a new entry and expires an old one still does one save.
func (s persistedTTLSet) trim(m map[int64]bool, now time.Time) bool {
	cutoff := now.Unix() - int64(s.ttl/time.Second)
	changed := false
	for u := range m {
		if u < cutoff {
			delete(m, u)
			changed = true
		}
	}
	return changed
}

// ---- Last.fm 桥接:已转发 uts 集合(替代单调水位线)----
// 单调水位线对"迟到/乱序"的 scrobble 不友好:Marvis 后台漏了、之后补同步的完成收听带旧
// 时间戳,会因 uts <= 水位线被永久跳过。改用"已转发 uts 集合"去重:只要某条没转发过就补,
// 不看时间顺序;集合落盘、只保留最近 forwardedTTL,防无限增长。默认兼容乱序/迟到,不靠手动回灌。
const forwardedTTL = 7 * 24 * time.Hour

var forwardedPath string

// lfmMirroredTTL/lfmMirroredPath:"已镜像到 Last.fm 的 uts" 集合,与 forwarded 同一
// 落盘/裁剪模式。防自环用:bridge 从 Last.fm 读到的新记录,若命中这个集合,说明是我们
// 自己刚写进去的 Mac 完成收听,不是真实 iPhone 收听,不能再转发回 LB(否则会被误标
// device=iphone 重复计入)。写入时机必须在发起镜像 HTTP 请求之前同步完成——即使请求
// 还在飞行中或最终失败,也不能让 bridge 有机会先看到这条记录、抢在标记前把它转发掉。
const lfmMirroredTTL = 7 * 24 * time.Hour

var lfmMirroredPath string

// 完成收听落库走 LB single 提交(带自身重试)+ Last.fm 镜像双路径覆盖,不走 relay
// /scrobble 端点(该端点连同本地重放队列已废弃下线,state-worker 侧路由同步移除)。
