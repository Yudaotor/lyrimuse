package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"log/slog"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// ---- Last.fm 待重发队列 ----
//
// 一次收听写 Last.fm 失败后,本地收听日志会留痕(recordFailedMirror),但要等用户手动「补提交」才补得回。这里把
// 其中**确定没写进去**的那部分(请求没发出去、或服务端明确没收:限流、凭据失效等)原样存下来,后台隔一阵重发。
// 判据跟补提交同一套(lastfmResendSafe):不确定有没有写进去的(超时、连接中断、11/16)不进队列,照旧隔离,
// 重复一条比漏一条贵得多。
//
// 跟补提交共用收听日志里的回执:重发成功写 "s"(markBackfilled),补提交就不会再交;重发前先看这一条是不是已经
// 被补提交交过或被隔离("s" / "q"),是就直接移出。
//
// 队列只在后台 goroutine 里读写文件,不碰 poller 的任何字段;当前的 Last.fm 写入器经 lfmRetryTarget 拿
// (主循环换 p.lfm 时同步更新),不能直接读 p.lfm。

const (
	lfmRetryInterval = 5 * time.Minute // 两轮重发之间隔多久
	lfmRetryMaxItems = 1000            // 保险丝:再多就丢最老的
)

// lfmRetryItem 是一条等着重发的收听,字段就是当初 track.scrobble 的参数(歌手是上送时的写法,不是播放器原样)。
type lfmRetryItem struct {
	// User:入队时那把授权的账号(lastfmScrobbler.user)。重发时账号对不上就丢掉。
	User      string  `json:"user"`
	Timestamp int64   `json:"timestamp"`
	Artist    string  `json:"artist"`
	Title     string  `json:"title"`
	Album     string  `json:"album,omitempty"`
	Duration  float64 `json:"duration,omitempty"`
	NotAudio  bool    `json:"not_audio,omitempty"`
	QueuedAt  int64   `json:"queued_at"`
}

// key 是去重口径:时间戳 + 曲名,跟 lfmMirrored(按时间戳)同样粒度。
func (it lfmRetryItem) key() string {
	return strconv.FormatInt(it.Timestamp, 10) + "|" + it.Title
}

var (
	lfmRetryPath string
	lfmRetryMu   sync.Mutex
	// lfmRetryTarget:当前的 Last.fm 写入器。主循环给 p.lfm 赋值的两处(启动、配置热重读)必须同步 Store。
	lfmRetryTarget atomic.Pointer[lastfmScrobbler]
)

func loadLfmRetryLocked() []lfmRetryItem {
	if lfmRetryPath == "" {
		return nil
	}
	data, err := os.ReadFile(lfmRetryPath)
	if err != nil {
		return nil
	}
	var items []lfmRetryItem
	if json.Unmarshal(data, &items) != nil {
		slog.Warn("lastfm retry: queue file unreadable, ignoring", "path", lfmRetryPath)
		return nil
	}
	return items
}

// dropLfmRetryTimestamps 把这些时间戳从重发队列里拿掉(delete-listen 用:用户在待补清单里删掉的收听,
// 不能再被后台重发交上去)。返回拿掉几条。常驻进程那边的重发在交之前还会再核一次收听日志(见 lfmRetryHooks.logged),
// 两道一起挡住「这边刚删、那边这一轮已经读进内存」的窗口。
func dropLfmRetryTimestamps(drop map[int64]bool) int {
	lfmRetryMu.Lock()
	defer lfmRetryMu.Unlock()
	items := loadLfmRetryLocked()
	kept := items[:0]
	for _, it := range items {
		if !drop[it.Timestamp] {
			kept = append(kept, it)
		}
	}
	removed := len(items) - len(kept)
	if removed > 0 {
		saveLfmRetryLocked(kept)
	}
	return removed
}

// lfmRetryQueuedTimestamps 重发队列里此刻排着的收听时间戳。补提交发送前拿它排除(见 stillPendingForBackfill);
// 补提交是另一个进程,读的是同一份文件。
func lfmRetryQueuedTimestamps() []int64 {
	lfmRetryMu.Lock()
	items := loadLfmRetryLocked()
	lfmRetryMu.Unlock()
	out := make([]int64, 0, len(items))
	for _, it := range items {
		out = append(out, it.Timestamp)
	}
	return out
}

func saveLfmRetryLocked(items []lfmRetryItem) {
	if lfmRetryPath == "" {
		return
	}
	if len(items) == 0 {
		_ = os.Remove(lfmRetryPath)
		return
	}
	data, err := json.Marshal(items)
	if err != nil {
		return
	}
	if err := writeFileAtomic(lfmRetryPath, data); err != nil {
		slog.Error("lastfm retry: save failed", "err", err)
	}
}

// lastfmResendSafe:这次失败之后原样重发会不会造成重复。只有确定没写进去才安全:
// 服务端看过内容并拒收的(accepted=0)重发没意义;应用层错误看 mayHaveStored;其余只认「请求没离开本机」。
func lastfmResendSafe(err error) bool {
	var ignored *lastfmIgnoredError
	if errors.As(err, &ignored) {
		return false
	}
	var apiErr *lastfmAPIError
	if errors.As(err, &apiErr) {
		return !apiErr.mayHaveStored()
	}
	return provablyNeverSent(err)
}

// enqueueLastfmRetryIfSafe 在写 Last.fm 失败的地方调:只有 lastfmResendSafe 的才记。同一条已在队列里就不重复记。
// 可以从 mirrorAsync 的 goroutine 里调(只碰自带锁的队列文件)。
func enqueueLastfmRetryIfSafe(err error, it lfmRetryItem) {
	if it.Timestamp <= 0 || !lastfmResendSafe(err) {
		return
	}
	lfmRetryMu.Lock()
	defer lfmRetryMu.Unlock()
	items := loadLfmRetryLocked()
	for _, cur := range items {
		if cur.key() == it.key() {
			return
		}
	}
	it.QueuedAt = time.Now().Unix()
	items = append(items, it)
	if len(items) > lfmRetryMaxItems {
		items = items[len(items)-lfmRetryMaxItems:]
	}
	saveLfmRetryLocked(items)
	log.Printf("lastfm retry: queued %q - %q (timestamp=%d), %d waiting", it.Artist, it.Title, it.Timestamp, len(items))
}

// lfmRetrySubmitter 是重发时用的提交函数(生产是 lastfmScrobbler.scrobble,测试注入假的)。
type lfmRetrySubmitter func(ctx context.Context, it lfmRetryItem) error

// lfmRetryHooks 是重发一轮要碰的收听日志操作,测试换成假的。
type lfmRetryHooks struct {
	// handled:这个时间戳在收听日志里已经有回执或被隔离("s" / "q")。
	handled func() map[int64]bool
	// submitted:重发成功,写回执(markBackfilledChecked)。返回写盘错误。
	submitted func(ts int64) error
	// quarantine:重发时撞上「不确定有没有写进去」,隔离、不再自动重发(markQuarantined)。
	quarantine func(ts int64)
	// logged:收听日志里还留着收听行("l")的时间戳;第二个返回值 = 收听日志在用。为 nil 时不查(单测)。
	// 进队列的每一条都先经 recordFailedMirror 写过 "l",这一行不在了只能是用户在待补清单里删掉了它
	// (delete-listen 按整个时间戳删)—— 那条就不该再交上去。
	logged func() (map[int64]bool, bool)
}

func defaultLfmRetryHooks() lfmRetryHooks {
	return lfmRetryHooks{
		handled: func() map[int64]bool {
			out := map[int64]bool{}
			for _, l := range readListenLog() {
				if (l.T == "s" || l.T == "q") && l.UTS > 0 {
					out[l.UTS] = true
				}
			}
			return out
		},
		submitted:  markBackfilledChecked,
		quarantine: markQuarantined,
		logged: func() (map[int64]bool, bool) {
			listenLogMu.Lock()
			inUse := listenLogPath != ""
			listenLogMu.Unlock()
			out := map[int64]bool{}
			for _, l := range readListenLog() {
				if l.T == "l" && l.UTS > 0 {
					out[l.UTS] = true
				}
			}
			return out, inUse
		},
	}
}

// processLfmRetry 按入队顺序重发一轮,返回送达的条数。处置跟补提交同一套口径:
//   - 成功:写回执,移出;
//   - 服务端拒收内容(accepted=0)、或别的确定没落库又重发也没用的应用层错误:移出;
//   - 撞上可能已落库的(11/16、超时、连接中断):隔离后移出,不再自动重发;
//   - 请求没发出去、限流(29)、凭据失效(4/9/10/26):这一轮停下,整队留到下一轮;
//   - 超过补提交的时间窗(backfillMaxAge,Last.fm 不收更老的时间戳)、已被补提交交过 / 隔离、
//     或入队时的账号不是现在这个(user,换过账号):移出。
func processLfmRetry(ctx context.Context, now time.Time, user string, submit lfmRetrySubmitter, hooks lfmRetryHooks) int {
	lfmRetryMu.Lock()
	items := loadLfmRetryLocked()
	lfmRetryMu.Unlock()
	if len(items) == 0 {
		return 0
	}
	handled := hooks.handled()
	var logged map[int64]bool
	checkLogged := false
	if hooks.logged != nil {
		logged, checkLogged = hooks.logged()
	}
	cutoff := now.Add(-backfillMaxAge).Unix()
	done := map[string]bool{}
	sent := 0
	for _, it := range items {
		if ctx.Err() != nil {
			break
		}
		if it.Timestamp < cutoff || handled[it.Timestamp] {
			done[it.key()] = true
			continue
		}
		if it.User != user {
			done[it.key()] = true
			log.Printf("lastfm retry: dropping %q - %q queued for another account", it.Artist, it.Title)
			continue
		}
		if checkLogged && !logged[it.Timestamp] {
			done[it.key()] = true
			log.Printf("lastfm retry: dropping %q - %q, deleted from the local listen log", it.Artist, it.Title)
			continue
		}
		err := submit(ctx, it)
		if err == nil {
			done[it.key()] = true
			sent++
			if werr := hooks.submitted(it.Timestamp); werr != nil {
				// Last.fm 已经收下,回执却写不进收听日志:这一条在日志里还是「待补」。移出队列(留着的话下一轮
				// 自动再交一遍),补一条隔离标记挡住补提交;这一轮停手 —— 接着交的每一条都会是同样的处境。
				hooks.quarantine(it.Timestamp)
				slog.Error("lastfm retry: scrobbled but the receipt could not be written, stopping this round",
					"err", werr, "artist", it.Artist, "title", it.Title)
				break
			}
			log.Printf("lastfm retry: scrobbled %q - %q (timestamp=%d)", it.Artist, it.Title, it.Timestamp)
			continue
		}
		var ignored *lastfmIgnoredError
		var apiErr *lastfmAPIError
		switch {
		case errors.As(err, &ignored):
			done[it.key()] = true
			log.Printf("lastfm retry: dropping ignored scrobble %q - %q: %v", it.Artist, it.Title, err)
			continue
		case errors.As(err, &apiErr) && apiErr.mayHaveStored():
			hooks.quarantine(it.Timestamp)
			done[it.key()] = true
			log.Printf("lastfm retry: quarantining %q - %q, may have been stored: %v", it.Artist, it.Title, err)
			continue
		case errors.As(err, &apiErr) && !apiErr.fatal() && apiErr.Code != 29:
			done[it.key()] = true
			log.Printf("lastfm retry: dropping %q - %q, rejected: %v", it.Artist, it.Title, err)
			continue
		case apiErr == nil && !provablyNeverSent(err):
			hooks.quarantine(it.Timestamp)
			done[it.key()] = true
			log.Printf("lastfm retry: quarantining %q - %q, no reply: %v", it.Artist, it.Title, err)
			continue
		}
		slog.Info("lastfm retry: still failing, will try again later", "err", err, "waiting", len(items)-len(done))
		break
	}
	if len(done) == 0 {
		return sent
	}
	// 重新读一遍再删:重发这段时间又可能有新条目入队。
	lfmRetryMu.Lock()
	defer lfmRetryMu.Unlock()
	cur := loadLfmRetryLocked()
	kept := cur[:0]
	for _, it := range cur {
		if !done[it.key()] {
			kept = append(kept, it)
		}
	}
	saveLfmRetryLocked(kept)
	return sent
}

// startLfmRetryLoop 后台常驻:每 lfmRetryInterval 重发一轮。没配 Last.fm 写入、或凭据已判死时整轮跳过,
// 重新授权(主循环换了新的写入器)之后自然接着重发。
func startLfmRetryLoop(ctx context.Context) {
	t := time.NewTicker(lfmRetryInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s := lfmRetryTarget.Load()
			if s == nil || s.dead.Load() {
				continue
			}
			if processLfmRetry(ctx, time.Now(), s.user, func(ctx context.Context, it lfmRetryItem) error {
				rctx, cancel := context.WithTimeout(ctx, mirrorTimeout())
				defer cancel()
				err := s.scrobble(withCatalogDurationUnknown(rctx, it.NotAudio), it.Artist, it.Title, it.Album, it.Timestamp, it.Duration)
				disableLastfmOnFatal(s, err, time.Now())
				return err
			}, defaultLfmRetryHooks()) > 0 {
				requestLastfmFeedRefresh(5 * time.Second)
			}
		}
	}
}

// disableLastfmOnFatal:重发撞上凭据错误时照活路径那套熔断(mirrorAsync):判死就停写、落状态文件(App 红标 + 系统通知)。
// 不这样的话用户没在放歌时,只有重发在每 5 分钟拿一把死掉的凭据白打请求。
func disableLastfmOnFatal(s *lastfmScrobbler, err error, now time.Time) {
	var apiErr *lastfmAPIError
	if errors.As(err, &apiErr) && s.shouldDisable(apiErr, now) && s.dead.CompareAndSwap(false, true) {
		warnf("lastfm mirror DISABLED: %v (fatal credential error; reconnect the account in Lyrimuse settings to resume)", apiErr)
		writeLastfmMirrorStatus(apiErr)
	}
}
