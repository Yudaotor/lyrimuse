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
	"time"
)

// ---- ListenBrainz 待重发队列 ----
//
// Mac 本机的一次收听提交给 ListenBrainz 失败时,歌还在放就每拍重试;可一旦会话已经结束(换歌、放完),
// 就再没有人重试它了,这条收听从此只在 Last.fm 上有。这里把那种「会话已结束、又不是 LB 明确拒收」的
// 失败连同原样的载荷存下来,后台隔一阵重发,成功才移出。
//
// 重发安全:LB 按「用户 + 时间戳 + 曲名」去重,同一时间戳同一首歌只存一条。所以上次其实已经送达、
// 只是回执超时的那种,重发也不会多出一条——前提是载荷原样重发,时间戳和曲名一个字不动。
//
// 队列文件跟着收听一起写,不走 features 开关:它只在 LB 那一路失败时才有内容,常态为空。

const (
	lbRetryInterval = 5 * time.Minute // 两轮重发之间隔多久
	lbRetryMaxItems = 1000            // 保险丝:再多就丢最老的(正常一年也攒不到这么多)
)

// lbRetryItem 是一条等着重发的完成收听。Meta 就是当初 submit 的那份载荷。
type lbRetryItem struct {
	ListenedAt int64       `json:"listened_at"`
	Meta       lbTrackMeta `json:"meta"`
	QueuedAt   int64       `json:"queued_at"`
}

// key 是去重口径,跟 LB 一致:时间戳 + 曲名。
func (it lbRetryItem) key() string {
	return strconv.FormatInt(it.ListenedAt, 10) + "|" + it.Meta.TrackName
}

var (
	lbRetryPath string
	lbRetryMu   sync.Mutex
)

func loadLBRetryLocked() []lbRetryItem {
	if lbRetryPath == "" {
		return nil
	}
	data, err := os.ReadFile(lbRetryPath)
	if err != nil {
		return nil
	}
	var items []lbRetryItem
	if json.Unmarshal(data, &items) != nil {
		slog.Warn("lb retry: queue file unreadable, ignoring", "path", lbRetryPath)
		return nil
	}
	return items
}

func saveLBRetryLocked(items []lbRetryItem) {
	if lbRetryPath == "" {
		return
	}
	if len(items) == 0 {
		_ = os.Remove(lbRetryPath)
		return
	}
	data, err := json.Marshal(items)
	if err != nil {
		return
	}
	if err := writeFileAtomic(lbRetryPath, data); err != nil {
		slog.Error("lb retry: save failed", "err", err)
	}
}

// enqueueLBRetry 记下一条要重发的收听。同一时间戳同一首歌已经在队列里就不重复记。
func enqueueLBRetry(listenedAt int64, meta lbTrackMeta) {
	if listenedAt <= 0 {
		return
	}
	lbRetryMu.Lock()
	defer lbRetryMu.Unlock()
	items := loadLBRetryLocked()
	for _, it := range items {
		if it.key() == (lbRetryItem{ListenedAt: listenedAt, Meta: meta}).key() {
			return
		}
	}
	items = append(items, lbRetryItem{ListenedAt: listenedAt, Meta: meta, QueuedAt: time.Now().Unix()})
	if len(items) > lbRetryMaxItems {
		items = items[len(items)-lbRetryMaxItems:]
	}
	saveLBRetryLocked(items)
	log.Printf("lb retry: queued %q - %q (listened_at=%d), %d waiting", meta.ArtistName, meta.TrackName, listenedAt, len(items))
}

// lbRetrySubmitter 是重发时用的提交函数(生产是 lbClient.submit,测试注入假的)。
type lbRetrySubmitter func(ctx context.Context, listenedAt int64, meta lbTrackMeta) error

// processLBRetry 按入队顺序重发一轮:成功或被 LB 明确拒收(4xx,重发多少次都一样)就移出,
// 瞬时失败就停下、留到下一轮。返回这一轮送达的条数。
func processLBRetry(ctx context.Context, submit lbRetrySubmitter) int {
	lbRetryMu.Lock()
	items := loadLBRetryLocked()
	lbRetryMu.Unlock()
	if len(items) == 0 {
		return 0
	}
	done := map[string]bool{}
	sent := 0
	for _, it := range items {
		if ctx.Err() != nil {
			break
		}
		err := submit(ctx, it.ListenedAt, it.Meta)
		if err == nil {
			done[it.key()] = true
			sent++
			log.Printf("lb retry: listen recorded %q - %q (listened_at=%d)", it.Meta.ArtistName, it.Meta.TrackName, it.ListenedAt)
			continue
		}
		if errors.Is(err, errListenRejected) {
			done[it.key()] = true
			log.Printf("lb retry: dropping rejected listen %q - %q: %v", it.Meta.ArtistName, it.Meta.TrackName, err)
			continue
		}
		slog.Info("lb retry: still failing, will try again later", "err", err, "waiting", len(items)-len(done))
		break
	}
	if len(done) == 0 {
		return 0
	}
	// 重新读一遍再删:重发这段时间主循环可能又追加了新条目。
	lbRetryMu.Lock()
	defer lbRetryMu.Unlock()
	cur := loadLBRetryLocked()
	kept := cur[:0]
	for _, it := range cur {
		if !done[it.key()] {
			kept = append(kept, it)
		}
	}
	saveLBRetryLocked(kept)
	return sent
}

// startLBRetryLoop 后台常驻:启动后先等一轮,之后每 lbRetryInterval 重发一次。LB 还在 429 冷却时
// submit 自己会直接跳过(返回瞬时错误),这里不用另外判断。
func startLBRetryLoop(ctx context.Context, lb *lbClient) {
	t := time.NewTicker(lbRetryInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			processLBRetry(ctx, func(ctx context.Context, listenedAt int64, meta lbTrackMeta) error {
				return lb.submit(ctx, "single", listenedAt, meta)
			})
		}
	}
}
