package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"sort"
	"time"
)

// 隔离条目的核对:常驻进程的重发循环每轮先跑一次(startLfmRetryLoop),按时间戳逐条去 Last.fm 查隔离够久的收听
// (「发出去了但不知道结果」)。那边已经有 → 补记回执 "s";确认没有 → 排进重发队列、写 "r" 解除隔离,紧接着的那一轮
// 重发把它交上去。补交命令不碰隔离条目,只补没连 Last.fm 时记下的收听。见 12 章决策 69。

// backfillReleaseAfter:隔离不到这么久的不查。刚落库的 scrobble 要过几分钟才出现在 user.getRecentTracks 里,
// 查早了会把已经落库的当成没有、再交一遍。
const backfillReleaseAfter = 15 * time.Minute

// backfillLookupPause:逐条查之间的间隔(Last.fm 条款不许持续每秒多次调用)。变量只为单测能调成 0。
var backfillLookupPause = time.Second

// quarantinedListen 是一条还隔离着的收听;quarantinedAt 是隔离那一行的写盘时刻。
type quarantinedListen struct {
	line          listenLogLine
	quarantinedAt int64
}

// quarantinedBackfillListens:还隔离着、没有回执、在回溯窗口内、按当前开关仍算一次收听的,按 uts 升序。
func quarantinedBackfillListens(now time.Time) []quarantinedListen {
	f := foldListenLog(readListenLog())
	cutoff := now.Add(-backfillMaxAge).Unix()
	var out []quarantinedListen
	for uts, at := range f.quarantined {
		l, ok := f.listens[uts]
		if !ok || f.submitted[uts] || uts < cutoff || tooShortToScrobble(l.DUR) {
			continue
		}
		out = append(out, quarantinedListen{line: l, quarantinedAt: at})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].line.UTS < out[j].line.UTS })
	return out
}

// markReleasedChecked 追加一条解除隔离("r"):核对过 Last.fm 上确实没有这一条。写不进去就还是隔离着,下次再核对。
func markReleasedChecked(uts int64) error {
	return appendListenLogLine(listenLogLine{
		T: "r", V: listenLogSchemaVersion, UTS: uts, AT: time.Now().Unix(),
	})
}

// reconcileQuarantined 核对隔离够久的收听,返回补记了回执的条数和排进重发队列的条数。查询出错(限流、网络)或写盘
// 失败就停下,剩下的照旧隔离,下一轮再查。
//
// 解除的顺序是先入队、再写 "r":中间这段时间它在收听日志里还隔离着,补交命令(另一个进程)不会交它;写完 "r" 之后它
// 排在重发队列里,补交同样跳过(stillPendingForBackfill)。反过来写,中间那段时间它就是一条普通的待补收听。重发在
// 同一个 goroutine 里、排在这之后跑,看到的已经是写过 "r" 的日志。
func reconcileQuarantined(ctx context.Context, s *lastfmScrobbler, now time.Time) (recovered, released int) {
	var due []quarantinedListen
	for _, q := range quarantinedBackfillListens(now) {
		if now.Unix()-q.quarantinedAt >= int64(backfillReleaseAfter/time.Second) {
			due = append(due, q)
		}
	}
	if len(due) == 0 {
		return 0, 0
	}
	if s.user == "" {
		log.Printf("lastfm retry: %d quarantined listen(s) left unchecked: no Last.fm username", len(due))
		return 0, 0
	}
	log.Printf("lastfm retry: checking %d quarantined listen(s) against Last.fm", len(due))
	for i, q := range due {
		if i > 0 {
			select {
			case <-time.After(backfillLookupPause):
			case <-ctx.Done():
				return recovered, released
			}
		}
		found, err := s.lastfmHasScrobbleAt(ctx, q.line.UTS)
		if err != nil {
			warnf("lastfm retry: quarantine check stopped, %d left as they are: %v", len(due)-i, err)
			return recovered, released
		}
		if found {
			if err := markBackfilledChecked(q.line.UTS); err != nil {
				warnf("lastfm retry: quarantine check stopped, receipt could not be written: %v", err)
				return recovered, released
			}
			recovered++
			continue
		}
		// 歌手、专辑用收听日志里的原样标签,写法在重发时取(scrobble 里的 resolveScrobbleTags),跟补交同一个口径。
		enqueueLastfmRetry(lfmRetryItem{User: s.user, Timestamp: q.line.UTS, Artist: q.line.AR, Title: q.line.TI,
			Album: q.line.AL, Duration: q.line.DUR})
		if err := markReleasedChecked(q.line.UTS); err != nil {
			warnf("lastfm retry: quarantine check stopped, release could not be written: %v", err)
			return recovered, released
		}
		released++
	}
	log.Printf("lastfm retry: quarantine check — %d already on Last.fm, %d queued for resubmission", recovered, released)
	return recovered, released
}

// lastfmHasScrobbleAt:这个账号在 Last.fm 上有没有时间戳正好是 uts 的 scrobble。只认时间戳:提交时发的就是 uts,
// 而歌手、歌名可能被 Last.fm 改写过。user.getRecentTracks 不需要签名,用只读那把 key(没有就用写的那把)。
func (s *lastfmScrobbler) lastfmHasScrobbleAt(ctx context.Context, uts int64) (bool, error) {
	key := s.apiKey
	if s.catalog != nil && s.catalog.apiKey != "" {
		key = s.catalog.apiKey
	}
	u := fmt.Sprintf(
		"https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=%s&api_key=%s&format=json&limit=50&from=%d&to=%d",
		neturl.QueryEscape(s.user), neturl.QueryEscape(key), uts-1, uts+1)
	ctx, cancel := context.WithTimeout(ctx, backfillRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("User-Agent", clientName)
	resp, err := doHTTPTracked(s.hc, req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return false, err
	}
	page, err := parseLastfmRecent(body)
	var apiErr *lastfmAPIError
	if errors.As(err, &apiErr) {
		return false, err
	}
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("user.getrecenttracks: status %d", resp.StatusCode)
	}
	if err != nil {
		return false, err
	}
	for _, t := range page.Done {
		if t.UTS == uts {
			return true, nil
		}
	}
	return false, nil
}
