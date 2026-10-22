package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"
)

// 推送提醒页「预览」用的真实报告:App 在「测一下」那条请求通道里发 {"id","preview":"daily"|"weekly"}(notifytest.go),
// 这里按真推送同一套取数、补充(数据源、每类列几名都读当前设置),把标题和那份数写进 notifyPreviewResultPath,App 按 id 找。
//   - 日报:今天零点到现在;今天还没听就取昨天一整天。
//   - 周报:最近一个已经结束的周(Last.fm 源是它的图表周,ListenBrainz 源是上周一到这周一)。
//
// 取不到时写明原因(没连账号、这一期没听、取数失败),App 退回测试数据。取一次要十几秒(新听的歌手要翻账号全部歌手),
// 同一期的结果留 digestPreviewTTL,来回切平台、开关预览不重取。只读,不碰推送水位、不推送。

const (
	digestPreviewTTL       = 10 * time.Minute
	digestPreviewTimeout   = 90 * time.Second
	digestPreviewResultMax = 6
)

// 取不到真实数据的原因。
const (
	digestPreviewNoAccount = "no_account" // Last.fm、ListenBrainz 都没连
	digestPreviewEmpty     = "empty"      // 这一期没有收听记录
	digestPreviewFetch     = "fetch"      // 取数出错(网络、接口)
)

type digestPreviewResult struct {
	ID     string       `json:"id"`
	Kind   string       `json:"kind"`
	OK     bool         `json:"ok"`
	Reason string       `json:"reason,omitempty"`
	Title  string       `json:"title,omitempty"`
	Digest *digestStats `json:"digest,omitempty"`
	At     int64        `json:"at"`
}

type digestPreviewResultFile struct {
	Results []digestPreviewResult `json:"results"` // 旧的在前
}

var (
	notifyPreviewResultPath string
	digestPreviewMu         sync.Mutex
	// digestPreviewCache:键是 kind + 数据源 + 每类列几名 + 这一期的起点,见 digestPreviewKey。
	digestPreviewCache = map[string]digestPreviewResult{}
)

// runDigestPreview 算一份预览、写结果。在 notifytest 的请求通道上另起 goroutine 跑。
func runDigestPreview(req notifyTestRequest) {
	ctx, cancel := context.WithTimeout(context.Background(), digestPreviewTimeout)
	defer cancel()
	res := computeDigestPreview(ctx, liveConfig(), req.Preview, time.Now())
	res.ID, res.At = req.ID, time.Now().Unix()
	slog.Info("notify preview: done", "kind", res.Kind, "ok", res.OK, "reason", res.Reason)
	writeDigestPreviewResult(res)
}

// computeDigestPreview 选这一期、取数、补「多三样」。同一期在 digestPreviewTTL 内直接给上次的结果。
func computeDigestPreview(ctx context.Context, cfg *config, kind string, now time.Time) digestPreviewResult {
	res := digestPreviewResult{Kind: kind}
	if cfg == nil {
		res.Reason = digestPreviewNoAccount
		return res
	}
	lastfmConfigured := cfg.LastfmUser != "" && cfg.lastfmBridgeAPIKey() != ""
	lbConfigured := cfg.User != "" && cfg.Token != ""
	pref := features().DailyDigestSource
	if kind == "weekly" {
		pref = features().WeeklyDigestSource
	}
	source := resolveDigestSource(pref, lastfmConfigured, lbConfigured)
	if source == "" {
		res.Reason = digestPreviewNoAccount
		return res
	}
	env := digestEnv{ctx: ctx, cfg: cfg, lbRoot: cfg.APIRoot}
	fetch := func(from, to int64) (digestStats, error) {
		if source == digestSourceLastfm {
			return lastfmDigestStats(ctx, cfg.LastfmUser, cfg.lastfmBridgeAPIKey(), from, to)
		}
		return listenbrainzDigestStats(ctx, cfg.APIRoot, cfg.User, from, to)
	}

	type candidate struct {
		from, to time.Time
		title    string
		period   digestPeriod
	}
	var cands []candidate
	switch kind {
	case "daily":
		midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
		yesterday := midnight.AddDate(0, 0, -1)
		today := candidate{midnight, now, fmt.Sprintf("🎧 今日听歌报告（%s）", now.Format("01-02")), dailyDigestPeriod(midnight, now)}
		prev := candidate{yesterday, midnight, fmt.Sprintf("🎧 昨日听歌报告（%s）", yesterday.Format("01-02")), dailyDigestPeriod(yesterday, midnight)}
		// 跟真推送选同一种:推送时间在中午以后推当天,先看今天;在中午以前推前一天,先看昨天(dailyDigestTarget)。
		cands = []candidate{today, prev}
		if digestPushMinutes() < digestPushSameDayFrom {
			cands = []candidate{prev, today}
		}
	case "weekly":
		from, to, err := lastFinishedDigestWeek(ctx, cfg, source, now)
		if err != nil {
			res.Reason = digestPreviewFetch
			return res
		}
		cands = []candidate{{time.Unix(from, 0), time.Unix(to, 0), weeklyDigestTitle(source, from, to), weeklyDigestPeriod(from, to)}}
	default:
		res.Reason = digestPreviewFetch
		return res
	}

	for _, c := range cands {
		key := fmt.Sprintf("%s|%s|%d|%d", kind, source, digestTopN(), c.from.Unix())
		digestPreviewMu.Lock()
		hit, ok := digestPreviewCache[key]
		digestPreviewMu.Unlock()
		if ok && now.Sub(time.Unix(hit.At, 0)) < digestPreviewTTL {
			return hit
		}
		stats, err := fetch(c.from.Unix(), c.to.Unix())
		if err != nil {
			res.Reason = digestPreviewFetch
			return res
		}
		if stats.TotalPlays == 0 {
			continue // 日报:这一天没听,看另一天
		}
		addDigestExtras(env, source, c.period, &stats, now)
		res.OK, res.Title, res.Digest, res.At = true, c.title, &stats, now.Unix()
		// 缓存里只留要显示的那些:原始收听、榜单原始行(ListenBrainz 周报最多几千条)用完就不要了。键带着这一期的
		// 起点,每天都会多一条,写的时候顺手删掉过期的,常驻进程里不越攒越多。
		kept := *res.Digest
		kept.listens, kept.chartTracks, kept.chartArtists = nil, nil, nil
		cached := res
		cached.Digest = &kept
		digestPreviewMu.Lock()
		for k, v := range digestPreviewCache {
			if now.Sub(time.Unix(v.At, 0)) >= digestPreviewTTL {
				delete(digestPreviewCache, k)
			}
		}
		digestPreviewCache[key] = cached
		digestPreviewMu.Unlock()
		return res
	}
	res.Reason = digestPreviewEmpty
	return res
}

// lastFinishedDigestWeek:最近一个已经结束的周。Last.fm 源取它图表周列表里最后一个已收官的,ListenBrainz 源是上周一到这周一,
// 跟 weeklyDigest 选的是同一周(那边是「刚收官就推」,这里是「最近推过 / 该推的那一周」)。
func lastFinishedDigestWeek(ctx context.Context, cfg *config, source string, now time.Time) (from, to int64, err error) {
	if source != digestSourceLastfm {
		monday := mostRecentMonday(now)
		return monday.AddDate(0, 0, -7).Unix(), monday.Unix(), nil
	}
	weeks, err := lastfmWeeklyChartList(ctx, cfg.LastfmUser, cfg.lastfmBridgeAPIKey())
	if err != nil {
		return 0, 0, err
	}
	for i := len(weeks) - 1; i >= 0; i-- {
		if weeks[i].To <= now.Unix() {
			return weeks[i].From, weeks[i].To, nil
		}
	}
	return 0, 0, fmt.Errorf("no finished chart week")
}

func writeDigestPreviewResult(res digestPreviewResult) {
	if notifyPreviewResultPath == "" {
		return
	}
	notifyTestResultMu.Lock()
	defer notifyTestResultMu.Unlock()
	var f digestPreviewResultFile
	if b, err := os.ReadFile(notifyPreviewResultPath); err == nil {
		_ = json.Unmarshal(b, &f)
	} else {
		noteFileErr("read", notifyPreviewResultPath, err)
	}
	f.Results = append(f.Results, res)
	if n := len(f.Results); n > digestPreviewResultMax {
		f.Results = f.Results[n-digestPreviewResultMax:]
	}
	b, err := json.Marshal(f)
	if err != nil {
		return
	}
	_ = writeFileAtomic(notifyPreviewResultPath, b)
}
