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
	"sync"
	"time"
)

type lbClient struct {
	root    string
	token   string
	hc      *http.Client
	dryRun  bool
	alerter *alerter

	// 429 的跨调用退避(2026-08-25 实测坐实的缺口)。submit() 内部的 tries/退避(见下)
	// 只管**一次调用内**的几次重试,治不了"LB 持续 429 几个小时"这种情况——poller.go
	// 有 4 个调用点(Mac 原生 single/playing_now、桥接 iPhone single/playing_now)各自
	// 独立按自己的节奏(桥接 15s 一轮、Mac 侧每次 poll tick ~5s 只要歌还在放就重试)发起
	// 新一轮 submit,互相不知道对方也在被拒,合起来对一个持续故障的服务器反而是在加压。
	// 这里加一个所有调用点共用的冷却期:一次调用耗尽全部 tries 仍以 429 收尾就指数升级
	// 冷却,直到有一次成功才清零——冷却期内**直接跳过网络请求**,不是排队等,因为这不是
	// "发太快"的问题(单条调用链路本身请求率很低),是"这个服务持续不可用,该少烦它"。
	mu             sync.Mutex
	cooldownUntil  time.Time
	consecutive429 int
}

// lbCooldownSchedule:第 N 次"一整轮调用全部以 429 收尾"后的冷却时长(N 从 1 起)。
// 超出表长就封顶在最后一档,不会无限增长到"几乎永远不重试"。
var lbCooldownSchedule = []time.Duration{
	30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute,
}

// coolingDown 返回冷却是否还没过——过了才允许真的发一次网络请求。
func (c *lbClient) coolingDown() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return time.Now().Before(c.cooldownUntil)
}

// noteOutcome 记录一次 submit 调用(耗尽全部 tries 后)的最终结果,推进/清零冷却状态。
// 只应该在"这一整轮调用的最后一次尝试"之后调一次——单次调用内部只要有一次成功就直接
// 在那里 return,根本不会走到这里。
func (c *lbClient) noteOutcome(success bool, lastStatus int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if success {
		c.consecutive429 = 0
		c.cooldownUntil = time.Time{}
		return
	}
	if lastStatus != http.StatusTooManyRequests {
		// 非 429 的失败(超时/5xx/网络错误):不升级 429 专用的冷却——那是另一类问题,
		// 用 429 的退避去惩罚它治不了,也不该让"网络抖了一下"连累后面正常的请求。
		return
	}
	c.consecutive429++
	idx := c.consecutive429 - 1
	if idx >= len(lbCooldownSchedule) {
		idx = len(lbCooldownSchedule) - 1
	}
	c.cooldownUntil = time.Now().Add(lbCooldownSchedule[idx])
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
	// isNewTrack 传 false:这里只是再查一次已经解析好的缓存(或触发首次解析),不是
	// poller.go handle() 那种"刚确认是新曲目"的现场时刻。
	enr := trackEnrichment(s.Artist, s.Title, s.Album, s.Bundle, s.Duration, false)
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
	// 歌手/歌名/专辑一律**原样上送播放器报的标签**,不做任何替换。
	//
	// ⚠️ 2026-08-31 改。这里原来会用 canonical_artist(网易云/QQ/MusicBrainz 查到的
	// "官方写法")**替换掉**播放器的标签,理由是"避免同一个人时而中文时而英文"。撤销
	// 它的依据有三条:
	//
	//  1. **Last.fm 官方明确反对**。scrobbling 指南里这句话出现了两次(逐字):
	//     "Do not use the corrections returned by the now playing service as input
	//      for the scrobble request, unless they have been explicitly approved by
	//      the user."
	//     连 Last.fm **自己**权威纠正库返回的结果都不许自动套用,而我们套的是网易云/QQ。
	//     它自家的 autocorrect 开关也已被标为 legacy、官方推荐值是"不要应用纠正"。
	//  2. **业界惯例一致**。调研 9 个开源 scrobbler(Web Scrobbler / Pano / Navidrome /
	//     Maloja / rescrobbled / mpdscribble / mpdas / Koito / multi-scrobbler),
	//     默认做"外部查询改名"的是 **0 个**;唯一有这能力的 multi-scrobbler 是 opt-in、
	//     要填联系邮箱、文档还警告 free text search 是 "unconstrained"。
	//     (Pano 反而拿 MusicBrainz 名单当 allowlist **保护**合唱串不被切,方向相反。)
	//  3. **实测有真错**。本机 2514 条缓存审计:194 条被改写,其中
	//     `USA for Africa`→`Xtc Planet`、`LBI利比`→`Safehse` 明确错误。而写进 Last.fm
	//     公共 artist 页的东西基本收不回来(纠错库已冻结)。
	//
	// 归一没有被放弃,只是挪了位置:**显示/统计层**照旧合并(App 侧 PlayCountFold.
	// canonicalArtist / artistMergeNameKey 那套本来就在做,且是独立实现),上送层只负责
	// 如实记录"播放器当时报的是什么"。
	//
	// canonical_artist 字段本身**保留**——它还在给「歌词管理」窗口当展示名
	// (EnrichCacheStore.swift),只是不再参与上送。
	//
	// ⚠️ ListenBrainz 支持 additional_info.artist_mbids(数组)来表达"这是谁"而不改
	// 显示串,那是这条路的正解;暂未接,因为现有缓存对**原始串**的 mbid 覆盖率只有 16%
	// (那份缓存的键是归一后的名字,给榜单用的)。Last.fm 侧则根本没有艺人 mbid 字段
	// (它的 mbid 参数是 **Track** ID),所以对 Last.fm 而言"原样上送"就是唯一正解。
	return lbTrackMeta{
		ArtistName:     s.Artist,
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
	if c.coolingDown() {
		// 冷却未过:不发出任何网络请求。这个 error 刻意**不**包 errListenRejected——
		// 调用方(poller.go 四个调用点)把 errListenRejected 当"LB 确实不收这条,别再试"
		// (桥接那处甚至会把它计入去重集合、永久跳过);冷却中的跳过是"这条还没试,
		// 下一轮再试",必须走调用方现有的"瞬时失败"分支,不能被当成永久拒绝而漏计。
		return fmt.Errorf("post %s: skipped, ListenBrainz still cooling down after repeated 429", listenType)
	}

	tries, perTry := 1, playingNowTimeout
	if listenType == "single" {
		tries, perTry = singleMaxTries, singleTimeout
	}
	var lastErr error
	var lastStatus int
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
			c.noteOutcome(true, status)
			return nil
		}
		lastStatus = status
		if status >= 400 && status < 500 && status != http.StatusTooManyRequests {
			return fmt.Errorf("post %s: %v: %w", listenType, err, errListenRejected)
		}
		lastErr = fmt.Errorf("post %s: %w", listenType, err)
	}
	c.noteOutcome(false, lastStatus)
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
	resp, err := doHTTPTracked(c.hc, req)
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
