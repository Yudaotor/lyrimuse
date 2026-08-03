// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

type lbClient struct {
	root    string
	token   string
	hc      *http.Client
	dryRun  bool
	alerter *alerter
}

type lbTrackMeta struct {
	ArtistName     string         `json:"artist_name"`
	TrackName      string         `json:"track_name"`
	ReleaseName    string         `json:"release_name,omitempty"`
	AdditionalInfo map[string]any `json:"additional_info,omitempty"`
}

func lbMeta(s snapshot) lbTrackMeta {
	info := map[string]any{
		"media_player":              mediaPlayerLabel(s.Bundle), // 按当前选定的本地播放器如实报告,见该函数注释
		"source":                    "mac",                      // 播放来源:mac 本地;桥接的 iPhone 由 bridge 覆盖为 iphone(连带覆盖 media_player,见 poller.go 两处 "source"]="iphone" 附近)
		"submission_client":         clientName,
		"submission_client_version": clientVersion,
	}
	if s.Duration > 0 {
		info["duration_ms"] = int64(s.Duration * 1000)
	}
	// 进度条锚点：发布采集器自跟踪的 Position + AnchorTS(=提交时刻)，网页据
	// progress_ms + (now - progress_ts) * playback_rate 只外推很短一段(到下次刷新)。
	// 不用 media-control 的 timestamp——它连播时冻结、跨休眠会漂，外推会跑超前。
	if !s.AnchorTS.IsZero() {
		// 以 playing 为语义真相：切歌加载瞬间 media-control 会短暂报 playing=true 但
		// playbackRate=0，此时应按播放(1)计；仅 playing=false 才是真正暂停(0)。
		rate := s.Rate
		if s.Playing && rate == 0 {
			rate = 1
		} else if !s.Playing {
			rate = 0
		}
		info["progress_ms"] = int64(s.Position * 1000)
		info["progress_ts"] = s.AnchorTS.UnixMilli()
		info["playback_rate"] = rate
	}
	// 封面/主色/各平台链接/歌词只跟 歌手|歌名|专辑 有关、且稳定不变，解析代价不小
	// (多次外部搜索 + 封面主色解码)。统一缓存并落盘，同一首歌重播/重启后都不再重解析。
	enr := trackEnrichment(s.Artist, s.Title, s.Album, s.Bundle, s.Duration)
	for _, k := range []string{"cover_url", "accent_color", "netease_url", "apple_music_url", "qq_music_url", "spotify_url", "cover_source", "lyrics_source"} {
		if v := enr[k]; v != "" {
			info[k] = v
		}
	}
	// 歌词受 LB「单条 listen ≤ 10240 字节」硬上限约束：按 原文>翻译>罗马音>逐字 优先级加入，
	// 累计超预算就丢后面的(逐字最大、最先被丢)——否则整条会被 LB 400 拒(含桥接的 iPhone 记录)。
	budget := lyricBudgetBytes
	for _, k := range []string{"lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc"} {
		if v := enr[k]; v != "" && len(v) <= budget {
			info[k] = v
			budget -= len(v)
		}
	}
	// 歌手名统一:能从网易云/QQ 音乐核实到官方写法就用那个(见 enrichEntry.CanonicalArtist
	// 注释),否则原样用本地(Apple Music)标签——避免同一个人因为设备/曲库来源不同,在历史
	// 记录里时而中文时而英文、时而全大写(如 PRINCE/Prince、David Tao/陶喆)。
	artistName := s.Artist
	if ca := enr["canonical_artist"]; ca != "" {
		artistName = ca
	}
	return lbTrackMeta{
		ArtistName:     artistName,
		TrackName:      s.Title,
		ReleaseName:    s.Album,
		AdditionalInfo: info,
	}
}

var errListenRejected = errors.New("listen rejected by server (4xx, non-retryable)")

// submit posts one listen. listenType is "playing_now" or "single"; listenedAt
// is only used for "single". LB(德国) is intermittently slow/down: playing_now
// fails fast (the next refresh re-sends within playingNowRefresh), while a
// "single" — a completed listen, losing which drops a scrobble for good — is
// retried a few times with backoff. A 4xx (non-429) is our own bad request, so
// it is never retried. LB is only the worker's fallback source now, so submit
// no longer drives alerts — the relay /push does (see run).
func (c *lbClient) submit(ctx context.Context, listenType string, listenedAt int64, meta lbTrackMeta) error {
	if listenType == "single" {
		// 歌词只用于“正在播放”的同步显示；历史/完成收听不展示，剥掉全部歌词字段——既省
		// listens?count=100 历史请求体积，也避免逐字 yrc 让单条超 LB 10KB 上限被 400 拒。
		for _, k := range []string{"lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc"} {
			delete(meta.AdditionalInfo, k)
		}
	}
	item := map[string]any{"track_metadata": meta}
	if listenType == "single" {
		item["listened_at"] = listenedAt
	}
	body, err := json.Marshal(map[string]any{
		"listen_type": listenType,
		"payload":     []any{item},
	})
	if err != nil {
		return fmt.Errorf("marshal %s: %w", listenType, err)
	}
	if c.dryRun {
		log.Printf("[dry-run] would POST %s: %s", listenType, body)
		return nil
	}
	if c.token == "" {
		// 没配置 token——main.go 启动时已经打过一次提示,这里静默跳过,不逐条打日志刷屏。
		return nil
	}

	tries, perTry := 1, playingNowTimeout
	if listenType == "single" {
		tries, perTry = singleMaxTries, singleTimeout
	}
	var lastErr error
	for attempt := 0; attempt < tries; attempt++ {
		if attempt > 0 { // 退避重试：500ms, 1s, ...
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(500<<(attempt-1)) * time.Millisecond):
			}
		}
		status, err := c.submitOnce(ctx, body, perTry)
		if err == nil {
			return nil
		}
		if status >= 400 && status < 500 && status != http.StatusTooManyRequests {
			return fmt.Errorf("post %s: %v: %w", listenType, err, errListenRejected)
		}
		lastErr = fmt.Errorf("post %s: %w", listenType, err)
	}
	return lastErr
}

// submitOnce does one submit-listens POST with its own timeout. It returns the
// HTTP status (0 on transport error) and a non-nil error on any non-200 outcome.
func (c *lbClient) submitOnce(ctx context.Context, body []byte, timeout time.Duration) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.root+"/1/submit-listens", bytes.NewReader(body))
	if err != nil {
		return 0, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Token "+c.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return resp.StatusCode, fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 512))
	return http.StatusOK, nil
}
