package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// collector → App 的 Last.fm「最近记录」feed(2026-09-03)。
//
// 背景:App 的 Last.fm 统计页此前自己每 110 秒直连 `user.getrecenttracks` 拉一次最近记录
// (外加两个只为取 @attr.total 的计数请求),而这个 collector 为了 iPhone 桥接**本来就每
// 15 秒拉一次同一个接口**——同一份数据两个进程各拉各的,App 那边还走的是慢链路(本机实测
// App 侧 URLSession 走系统代理 p50 1.2 s、16% 超时;这边 Go 直连 p50 0.4 s、~1% 失败)。
// 现在每次成功拉取都把结果落成这个文件,App 按 mtime 监听(形制照抄 lyrimuse-lastfm-status.json
// 那条通道,见 LastfmMirrorStatus.swift),最近记录 / 正在播放 / 总 scrobble 数从此在 App 侧
// **零请求**,新鲜度 ≤ 一个拉取周期。
//
// 三条约定:
//   - 写失败只记日志。它是通知通道,不是正确性依赖:App 读不到就退回自己轮询(旧行为)。
//   - **内容没变不重写**(见 shouldWriteLastfmFeed):App 那边按 mtime 判断要不要重新解码,
//     每 15 秒白写一遍等于让它每 15 秒白解一遍;但**至少每 feedHeartbeat 写一次**——不然
//     空闲几小时后 mtime 一直不动,App 分不清"没新内容"和"collector 早挂了",只能保守地
//     退回轮询。
//   - 原子写(临时文件 + rename):App 可能正好在读,不能让它读到半截 JSON。
var lastfmFeedPath string

// feedHeartbeat:内容没变时最长隔多久也要重写一次(让 mtime 保持"活着")。App 侧
// 判 feed 健康的阈值(LastfmRecentFeed.freshWindow)必须**大于**这个值 + 最慢拉取周期。
const feedHeartbeat = 60 * time.Second

// feed 拉取节奏(2026-09-03 起自适应,替代原来固定的 lastfmPollInterval=15s):
//   - 有人在听(本机在放、或 feed 里最近 feedActivityWindow 内有 now-playing / 新 scrobble)
//     → feedIntervalActive(15 s),跟原桥接一样快,红点/新行 ≤15 s 到位;
//   - 完全空闲 → feedIntervalIdle(60 s):这时 Last.fm 上不会有任何新东西,拉得再快也只是
//     白发请求。手机一开播,最多 60 s 后进入活跃节奏。
//
// 桥接(iPhone→LB 转发)沿用同一个节奏:空闲时 60 s 才发现手机开播,对"转发已完成的收听"
// 这件事毫无影响(bridgeMaxListenAge 是 3 天)。
const (
	feedIntervalActive = 15 * time.Second
	feedIntervalIdle   = 60 * time.Second
	feedActivityWindow = 10 * time.Minute
)

// lastfmFeedInterval 决定下一次拉取要隔多久。纯函数,单测钉住。
func lastfmFeedInterval(localPlaying bool, lastActivity, now time.Time) time.Duration {
	if localPlaying {
		return feedIntervalActive
	}
	if !lastActivity.IsZero() && now.Sub(lastActivity) < feedActivityWindow {
		return feedIntervalActive
	}
	return feedIntervalIdle
}

// lastfmFeedActivityAt 从一页拉取结果里判断"最近一次活动"是什么时候:有 now-playing 就是
// 现在;否则是最新一条 scrobble 的时刻(可能已经很久以前,由调用方按窗口判断)。零值 = 没有
// 任何记录。
func lastfmFeedActivityAt(page lastfmRecentPage, fetchedAt time.Time) time.Time {
	if page.NowPlaying != nil {
		return fetchedAt
	}
	if len(page.Done) > 0 && page.Done[0].UTS > 0 {
		return time.Unix(page.Done[0].UTS, 0)
	}
	return time.Time{}
}

// lastfmFeedNudgeAt:主动要求"提前拉一次"的时刻(unix 纳秒;0 = 没有)。
//
// 唯一的写入方是 Last.fm 镜像 scrobble 成功那一刻(mirrorScrobbleTracked 的 goroutine):
// 我们自己刚往 Last.fm 写进一条,几秒后拉 feed 就能让 App 把"上一首"摆进列表——不用等
// 下一个 15 s 周期,更不用 App 自己去发请求。放 atomic 是因为写入发生在 goroutine 里,
// 而 poller 的字段只允许主循环碰(见 poller.go 顶部不变量);主循环在 bridge() 里读它。
var lastfmFeedNudgeAt atomic.Int64

// requestLastfmFeedRefresh 让 bridge() 在 after 之后尽快拉一次(不早于 after:Last.fm 把
// 刚收到的 scrobble 并进 recenttracks 需要一两秒,立刻拉多半还看不到)。
func requestLastfmFeedRefresh(after time.Duration) {
	target := time.Now().Add(after).UnixNano()
	for {
		cur := lastfmFeedNudgeAt.Load()
		if cur != 0 && cur <= target {
			return // 已经有一个更早的待办,不推后
		}
		if lastfmFeedNudgeAt.CompareAndSwap(cur, target) {
			return
		}
	}
}

// lastfmFeedNudgeDue 报告是否有到期的"提前拉一次"请求,有则消费掉。
func lastfmFeedNudgeDue(now time.Time) bool {
	t := lastfmFeedNudgeAt.Load()
	if t == 0 || now.UnixNano() < t {
		return false
	}
	return lastfmFeedNudgeAt.CompareAndSwap(t, 0)
}

type lastfmFeedTrack struct {
	Artist string `json:"artist"`
	Title  string `json:"title"`
	Album  string `json:"album,omitempty"`
	Image  string `json:"image,omitempty"`
	UTS    int64  `json:"uts,omitempty"` // now-playing 行没有
}

// lastfmFeedFile 是落盘的形状。字段名 App 侧 LastfmRecentFeed.swift 逐字对应,改一边必须改另一边。
type lastfmFeedFile struct {
	Username   string            `json:"username"`
	FetchedAt  int64             `json:"fetchedAt"` // unix 秒,这次拉取成功的时刻
	Total      int               `json:"total"`     // @attr.total = 账号总 scrobble 数
	NowPlaying *lastfmFeedTrack  `json:"nowPlaying,omitempty"`
	Tracks     []lastfmFeedTrack `json:"tracks"` // 已完成的,新→旧,≤50 条
}

func feedTrack(t lastfmTrack) lastfmFeedTrack {
	return lastfmFeedTrack{Artist: t.Artist, Title: t.Title, Album: t.Album, Image: t.Image, UTS: t.UTS}
}

// lastfmFeedContentKey 把"会影响 App 显示"的部分压成一个字符串,给"内容没变就不重写"用。
// 刻意不含 fetchedAt(否则每次都不同)。now-playing 的身份、总数、每条 scrobble 的 uts 都进去;
// image/album 不进——它们跟着 uts 走,同一条记录不会变图。
func lastfmFeedContentKey(page lastfmRecentPage) string {
	var b strings.Builder
	b.WriteString(strconv.Itoa(page.Total))
	b.WriteByte('|')
	if page.NowPlaying != nil {
		b.WriteString(page.NowPlaying.Artist)
		b.WriteByte(0x1f)
		b.WriteString(page.NowPlaying.Title)
	}
	for _, t := range page.Done {
		b.WriteByte('|')
		b.WriteString(strconv.FormatInt(t.UTS, 10))
	}
	return b.String()
}

// shouldWriteLastfmFeed:内容变了就写;没变则只在距上次写入 ≥ feedHeartbeat 时写一次心跳。
func shouldWriteLastfmFeed(prevKey, curKey string, lastWrite, now time.Time) bool {
	if curKey != prevKey {
		return true
	}
	return lastWrite.IsZero() || now.Sub(lastWrite) >= feedHeartbeat
}

var (
	lastfmFeedLastKey   string
	lastfmFeedLastWrite time.Time
)

// writeLastfmRecentFeed 把一次成功的拉取落成 feed 文件。只在 poll 主循环里调
// (applyBridgeResult),上面两个"上次写了什么/何时"的变量因此不需要锁。
func writeLastfmRecentFeed(user string, page lastfmRecentPage, fetchedAt time.Time) {
	if lastfmFeedPath == "" || user == "" {
		return
	}
	key := lastfmFeedContentKey(page)
	if !shouldWriteLastfmFeed(lastfmFeedLastKey, key, lastfmFeedLastWrite, fetchedAt) {
		return
	}
	f := lastfmFeedFile{
		Username:  user,
		FetchedAt: fetchedAt.Unix(),
		Total:     page.Total,
		Tracks:    make([]lastfmFeedTrack, 0, len(page.Done)),
	}
	if page.NowPlaying != nil {
		np := feedTrack(*page.NowPlaying)
		f.NowPlaying = &np
	}
	for _, t := range page.Done {
		f.Tracks = append(f.Tracks, feedTrack(t))
	}
	data, err := json.Marshal(f)
	if err != nil {
		return
	}
	// 临时文件 + rename:App 可能正在读。临时文件放同目录,rename 才是同一文件系统内的原子操作。
	tmp := filepath.Join(filepath.Dir(lastfmFeedPath), "."+filepath.Base(lastfmFeedPath)+".tmp")
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		log.Printf("lastfm feed: write temp failed: %v", err)
		return
	}
	if err := os.Rename(tmp, lastfmFeedPath); err != nil {
		log.Printf("lastfm feed: rename failed: %v", err)
		os.Remove(tmp)
		return
	}
	lastfmFeedLastKey = key
	lastfmFeedLastWrite = fetchedAt
}
