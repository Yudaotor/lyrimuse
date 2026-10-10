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

// 隔离条目的核对:补交(用户点的那一下)开头,按时间戳逐条去 Last.fm 查还隔离着的收听(「发出去了但不知道结果」)。
// 那边已经有 → 补记回执 "s";确认没有、而且隔离过了 backfillReleaseAfter → 写 "r" 解除隔离,这一趟跟着补交。
// 不在后台自动跑。见 12 章决策 67。

// backfillReleaseAfter:隔离不到这么久的不解除。刚落库的 scrobble 要过几分钟才出现在 user.getRecentTracks 里,
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

// reconcileQuarantined 核对隔离着的收听,返回补记了回执的条数和解除隔离的条数。查询出错(限流、网络)或写盘失败
// 就停下,剩下的照旧隔离,下次补交再查。
func reconcileQuarantined(ctx context.Context, s *lastfmScrobbler, now time.Time) (recovered, released int) {
	qs := quarantinedBackfillListens(now)
	if len(qs) == 0 {
		return 0, 0
	}
	if s.user == "" {
		log.Printf("backfill: %d quarantined listen(s) left unchecked: no Last.fm username", len(qs))
		return 0, 0
	}
	log.Printf("backfill: checking %d quarantined listen(s) against Last.fm", len(qs))
	for i, q := range qs {
		if i > 0 {
			select {
			case <-time.After(backfillLookupPause):
			case <-ctx.Done():
				return recovered, released
			}
		}
		found, err := s.lastfmHasScrobbleAt(ctx, q.line.UTS)
		if err != nil {
			warnf("backfill: quarantine check stopped, %d left as they are: %v", len(qs)-i, err)
			return recovered, released
		}
		switch {
		case found:
			if err := markBackfilledChecked(q.line.UTS); err != nil {
				warnf("backfill: quarantine check stopped, receipt could not be written: %v", err)
				return recovered, released
			}
			recovered++
		case now.Unix()-q.quarantinedAt >= int64(backfillReleaseAfter/time.Second):
			if err := markReleasedChecked(q.line.UTS); err != nil {
				warnf("backfill: quarantine check stopped, release could not be written: %v", err)
				return recovered, released
			}
			released++
		}
	}
	log.Printf("backfill: quarantine check — %d already on Last.fm, %d released for resubmission", recovered, released)
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
