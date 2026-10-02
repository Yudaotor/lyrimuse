package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 歌词源的按天统计:每个源在现查里被问了几次、交出候选几次、胜出几次、因熔断被跳过几次,以及按「同类源」
// 条件算的命中率。落盘时顺带算出每个源的摘要和判定,给设置页「歌词来源」卡和 healthcheck 用。判定规则
// 与阈值的依据见 09 章决策 147。
//
// 只认 first-resolve / refill / upgrade 三条现查路径:批量重打分不一定发新请求,别把它数进来。只有常驻
// 进程记(startLyricSourceStats 在 run 里调);一次性子命令走同一段解析代码时这里是空操作,两个进程同写
// 这份文件会互相覆盖。
//
// 命中率只在「同一类曲库里另有至少两家给了候选」的那几次里算,不跟这个源自己的历史比。

const (
	lyricSourceStatsFileName = "lyrimuse-lyric-source-stats.json"
	// lyricSourceStatsKeepDays:保留多少天。判定最多往回看 17 天(3 天窗口 + 14 天基线),多留是给排查用。
	lyricSourceStatsKeepDays = 60
	// lyricSourceStatsFlushEvery:多久落一次盘。没有新数据时每小时也重写一次,让摘要跟着日期滚动。
	lyricSourceStatsFlushEvery = time.Minute
	lyricSourceStatsRefreshAge = time.Hour
	// lyricSourceStatsStaleAfter:摘要多久没更新算停了。App 侧 LyricSourceHealth.staleAfter 是同一个数,两处一起改。
	lyricSourceStatsStaleAfter = 48 * time.Hour
	lyricSourceStatsDayLayout  = "2006-01-02"
)

// 判定阈值,数字的来历见 09 章决策 147。
const (
	// 几乎不给词:3 天窗口里同类条件命中率低于这个值。
	lyricSourceBarelyRate      = 0.10
	lyricSourceBarelyMinRounds = 50
	// 比平时少一大截:低于基线(此前 14 天每天命中率的中位数)的这个比例。
	lyricSourceBelowUsualRatio     = 0.6
	lyricSourceBelowUsualMinRounds = 100
	lyricSourceBelowUsualMinBase   = 0.2
	lyricSourceBaselineDays        = 14
	lyricSourceBaselineMinRounds   = 30
	lyricSourceBaselineMinDays     = 3
	// 大部分时间在冷却:2 天窗口里被跳过的轮数超过这个比例。
	lyricSourceCoolingRatio     = 0.5
	lyricSourceCoolingMinRounds = 20
	// 同时有这么多个源因为网络错误在冷却,算「网络到不了」,不算源坏了。
	lyricSourceNetworkMinSources = 2
)

// 判定结果(写进摘要的 alert 字段,App 侧 LyricSourceHealth.Alert 是同一套取值)。
const (
	lyricSourceAlertBarely     = "barely"
	lyricSourceAlertBelowUsual = "below_usual"
	lyricSourceAlertCooling    = "cooling"
	lyricSourceAlertNetwork    = "network"
)

// lyricSourcePeerGroups:同类曲库。amll 按平台 ID 直取、覆盖面本来就窄,不进任何一组;
// 播放器本地缓存那几路(isPlayerLocalLyricSource)不是歌词源,整个不统计。
var lyricSourcePeerGroups = [][]string{
	{"netease", "qq", "kugou", "kuwo", "migu", "soda"},
	{"lrclib", "musixmatch", "lyricfind", "deezer", "applemusic"},
}

func lyricSourcePeerGroup(source string) []string {
	for _, g := range lyricSourcePeerGroups {
		for _, s := range g {
			if s == source {
				return g
			}
		}
	}
	return nil
}

// lyricSourceDayCounts:一个源一天的计数。asked = 开着、这一轮问了它;skipped = 开着但因熔断冷却 / 限流
// 没问(两者互斥,合起来是这个源开着的现查轮数)。peer_rounds / peer_hits 只在问了它的轮里数。
type lyricSourceDayCounts struct {
	Asked      int `json:"asked,omitempty"`
	Skipped    int `json:"skipped,omitempty"`
	Responded  int `json:"responded,omitempty"`
	Usable     int `json:"usable,omitempty"`
	Won        int `json:"won,omitempty"`
	PeerRounds int `json:"peer_rounds,omitempty"`
	PeerHits   int `json:"peer_hits,omitempty"`
	// Trips:熔断跳闸次数,按原因(sourcebreaker.go 的 lyricSourceCooldownReason*)。
	Trips map[string]int `json:"trips,omitempty"`
}

type lyricSourceStatsDay struct {
	Rounds  int                              `json:"rounds"`
	Sources map[string]*lyricSourceDayCounts `json:"sources"`
}

func (d *lyricSourceStatsDay) counts(source string) *lyricSourceDayCounts {
	if d.Sources == nil {
		d.Sources = map[string]*lyricSourceDayCounts{}
	}
	c := d.Sources[source]
	if c == nil {
		c = &lyricSourceDayCounts{}
		d.Sources[source] = c
	}
	return c
}

// lyricSourceStatsSummary:一个源的摘要,落盘时现算。App 只读这一段。
type lyricSourceStatsSummary struct {
	Source  string `json:"source"`
	Enabled bool   `json:"enabled"`
	// 近 7 天:这个源开着的现查轮数(问了 + 被跳过)、交出候选的轮数、胜出的轮数。
	Rounds    int `json:"rounds"`
	Responded int `json:"responded"`
	Won       int `json:"won"`
	// Alert:空 = 没有异常。其余字段是给说明文字用的数字。
	Alert        string   `json:"alert,omitempty"`
	PeerRate     float64  `json:"peer_rate,omitempty"`
	PeerRounds   int      `json:"peer_rounds,omitempty"`
	UsualRate    float64  `json:"usual_rate,omitempty"`
	SkipRate     float64  `json:"skip_rate,omitempty"`
	NetworkPeers []string `json:"network_peers,omitempty"`
}

type lyricSourceStatsFile struct {
	UpdatedAt int64                           `json:"updated_at"`
	Days      map[string]*lyricSourceStatsDay `json:"days"`
	Summary   []lyricSourceStatsSummary       `json:"summary"`
}

// lyricSourceRoundOutcome:一轮现查里各源的结局。enabled 是这一轮该问的源(开着、而且配置上用得了)。
type lyricSourceRoundOutcome struct {
	enabled   []string
	skipped   map[string]bool
	responded map[string]bool
	usable    map[string]bool
	winner    string
}

// addLyricSourceRound 把一轮结局加进当天的计数。纯函数,单测直接覆盖。
func addLyricSourceRound(day *lyricSourceStatsDay, o lyricSourceRoundOutcome) {
	day.Rounds++
	for _, src := range o.enabled {
		c := day.counts(src)
		if o.skipped[src] {
			c.Skipped++
			continue
		}
		c.Asked++
		if o.responded[src] {
			c.Responded++
		}
		if o.usable[src] {
			c.Usable++
		}
		if o.winner == src {
			c.Won++
		}
		peers := 0
		for _, p := range lyricSourcePeerGroup(src) {
			if p != src && o.responded[p] {
				peers++
			}
		}
		if peers >= 2 {
			c.PeerRounds++
			if o.responded[src] {
				c.PeerHits++
			}
		}
	}
}

// lyricSourceOutcomeFromDecision 从一份决策记录拼出这一轮的结局。enabled 判这个源开没开,eligible 判
// 配置上用不用得了(Apple Music 没连账号时不发请求、恒为空,数进来就是误报)。
func lyricSourceOutcomeFromDecision(d *lyricsDecision, enabled, eligible func(string) bool) lyricSourceRoundOutcome {
	o := lyricSourceRoundOutcome{
		skipped:   map[string]bool{},
		responded: map[string]bool{},
		usable:    map[string]bool{},
		winner:    d.Winner,
	}
	for _, s := range d.SourcesSkipped {
		o.skipped[s] = true
	}
	for _, s := range d.SourcesResponded {
		o.responded[s] = true
	}
	for _, c := range d.Candidates {
		o.responded[c.Source] = true
		if c.Score >= 0 {
			o.usable[c.Source] = true
		}
	}
	for _, s := range lyricSourceNames {
		if isPlayerLocalLyricSource(s) || !enabled(s) || !eligible(s) {
			continue
		}
		o.enabled = append(o.enabled, s)
	}
	return o
}

// lyricSourceStatsEligible:这个源配置上用不用得了。只有 Apple Music 要用户先连账号。
func lyricSourceStatsEligible(source string) bool {
	if source == "applemusic" {
		return applemusicConnected()
	}
	return true
}

func lyricSourceStatsCountsPath(path string) bool {
	switch path {
	case lyricsDecisionPathFirstResolve, lyricsDecisionPathRefill, lyricsDecisionPathUpgrade:
		return true
	}
	return false
}

// ---- 判定 ----

type lyricSourceWindow struct {
	asked, skipped, peerRounds, peerHits int
	trips                                map[string]int
}

func sumLyricSourceWindow(days map[string]*lyricSourceStatsDay, source string, keys []string) lyricSourceWindow {
	w := lyricSourceWindow{trips: map[string]int{}}
	for _, k := range keys {
		d := days[k]
		if d == nil || d.Sources[source] == nil {
			continue
		}
		c := d.Sources[source]
		w.asked += c.Asked
		w.skipped += c.Skipped
		w.peerRounds += c.PeerRounds
		w.peerHits += c.PeerHits
		for r, n := range c.Trips {
			w.trips[r] += n
		}
	}
	return w
}

// lyricSourceDayKeys:从 today 往回数 n 天(含 today)的日期键,最早的在前。offset 天之前开始数。
func lyricSourceDayKeys(today time.Time, offset, n int) []string {
	out := make([]string, 0, n)
	for i := offset + n - 1; i >= offset; i-- {
		out = append(out, today.AddDate(0, 0, -i).Format(lyricSourceStatsDayLayout))
	}
	return out
}

func roundRate(v float64) float64 { return math.Round(v*1000) / 1000 }

// summarizeLyricSourceStats 算每个源的摘要和判定。纯函数,单测拿回放数据覆盖。
//
// 优先级:冷却 / 网络 > 几乎不给词 > 比平时少。冷却时这个源大部分轮没被问,命中率的分母本来就小,
// 说「几乎不给词」会把原因说错。
func summarizeLyricSourceStats(days map[string]*lyricSourceStatsDay, today time.Time, enabled func(string) bool) []lyricSourceStatsSummary {
	last7 := lyricSourceDayKeys(today, 0, 7)
	last3 := lyricSourceDayKeys(today, 0, 3)
	last2 := lyricSourceDayKeys(today, 0, 2)
	base := lyricSourceDayKeys(today, 3, lyricSourceBaselineDays)

	var out []lyricSourceStatsSummary
	coolingNetwork := map[string]bool{}
	for _, src := range lyricSourceNames {
		if isPlayerLocalLyricSource(src) {
			continue
		}
		s := lyricSourceStatsSummary{Source: src, Enabled: enabled(src)}
		for _, k := range last7 {
			if d := days[k]; d != nil && d.Sources[src] != nil {
				c := d.Sources[src]
				s.Rounds += c.Asked + c.Skipped
				s.Responded += c.Responded
				s.Won += c.Won
			}
		}
		if lyricSourcePeerGroup(src) != nil {
			cool := sumLyricSourceWindow(days, src, last2)
			win := sumLyricSourceWindow(days, src, last3)
			total := cool.asked + cool.skipped
			switch {
			case total >= lyricSourceCoolingMinRounds && float64(cool.skipped) > lyricSourceCoolingRatio*float64(total):
				s.Alert = lyricSourceAlertCooling
				s.SkipRate = roundRate(float64(cool.skipped) / float64(total))
				network := cool.trips[lyricSourceCooldownReasonNetwork]
				if network > 0 && network >= cool.trips[lyricSourceCooldownReasonServerError]+cool.trips[lyricSourceCooldownReasonRateLimited] {
					coolingNetwork[src] = true
				}
			case win.peerRounds >= lyricSourceBarelyMinRounds && float64(win.peerHits) < lyricSourceBarelyRate*float64(win.peerRounds):
				s.Alert = lyricSourceAlertBarely
				s.PeerRate = roundRate(float64(win.peerHits) / float64(win.peerRounds))
				s.PeerRounds = win.peerRounds
			case win.peerRounds >= lyricSourceBelowUsualMinRounds:
				usual, ok := lyricSourceBaseline(days, src, base)
				rate := float64(win.peerHits) / float64(win.peerRounds)
				if ok && usual >= lyricSourceBelowUsualMinBase && rate < lyricSourceBelowUsualRatio*usual {
					s.Alert = lyricSourceAlertBelowUsual
					s.PeerRate = roundRate(rate)
					s.PeerRounds = win.peerRounds
					s.UsualRate = roundRate(usual)
				}
			}
		}
		out = append(out, s)
	}
	if len(coolingNetwork) >= lyricSourceNetworkMinSources {
		for i := range out {
			if !coolingNetwork[out[i].Source] {
				continue
			}
			out[i].Alert = lyricSourceAlertNetwork
			for _, s := range lyricSourceNames {
				if s != out[i].Source && coolingNetwork[s] {
					out[i].NetworkPeers = append(out[i].NetworkPeers, s)
				}
			}
		}
	}
	return out
}

// lyricSourceBaseline:基线 = keys 那几天里样本够的每天命中率的中位数;够格的天数不足时 ok=false。
func lyricSourceBaseline(days map[string]*lyricSourceStatsDay, source string, keys []string) (float64, bool) {
	var rates []float64
	for _, k := range keys {
		d := days[k]
		if d == nil || d.Sources[source] == nil {
			continue
		}
		c := d.Sources[source]
		if c.PeerRounds >= lyricSourceBaselineMinRounds {
			rates = append(rates, float64(c.PeerHits)/float64(c.PeerRounds))
		}
	}
	if len(rates) < lyricSourceBaselineMinDays {
		return 0, false
	}
	sort.Float64s(rates)
	mid := len(rates) / 2
	if len(rates)%2 == 1 {
		return rates[mid], true
	}
	return (rates[mid-1] + rates[mid]) / 2, true
}

// pruneLyricSourceStats 删掉 today 往前 keep 天以外的日子。
func pruneLyricSourceStats(days map[string]*lyricSourceStatsDay, today time.Time, keep int) {
	oldest := today.AddDate(0, 0, -(keep - 1)).Format(lyricSourceStatsDayLayout)
	for k := range days {
		if k < oldest {
			delete(days, k)
		}
	}
}

// ---- 常驻进程里的那一份 ----

type lyricSourceStats struct {
	mu       sync.Mutex
	path     string
	now      func() time.Time
	data     lyricSourceStatsFile
	dirty    bool
	lastSave time.Time
}

var lyricSourceStatsShared atomic.Pointer[lyricSourceStats]

func loadLyricSourceStats(path string, now func() time.Time) *lyricSourceStats {
	s := &lyricSourceStats{path: path, now: now}
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, &s.data); err != nil {
			log.Printf("lyric source stats: %s unreadable, starting over: %v", path, err)
			s.data = lyricSourceStatsFile{}
		}
	}
	if s.data.Days == nil {
		s.data.Days = map[string]*lyricSourceStatsDay{}
	}
	return s
}

// startLyricSourceStats:常驻进程启动时调一次。读回旧数据、立刻按今天重算一次摘要(日期变了,旧摘要里的
// 判定可能已经过期),之后定时落盘,退出前再落一次。
func startLyricSourceStats(ctx context.Context) {
	path := configFilePath(lyricSourceStatsFileName)
	if path == lyricSourceStatsFileName {
		return
	}
	s := loadLyricSourceStats(path, time.Now)
	lyricSourceStatsShared.Store(s)
	s.save()
	go func() {
		t := time.NewTicker(lyricSourceStatsFlushEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				s.save()
				return
			case <-t.C:
				s.saveIfNeeded()
			}
		}
	}()
}

// noteLyricSourceDecision:一轮决策定下来时记一笔(traceLyricsDecision 开头调)。不是现查、或者不在常驻
// 进程里时是空操作。
func noteLyricSourceDecision(d *lyricsDecision) {
	s := lyricSourceStatsShared.Load()
	if s == nil || d == nil || !lyricSourceStatsCountsPath(d.Path) {
		return
	}
	o := lyricSourceOutcomeFromDecision(d, lyricSourceEnabled, lyricSourceStatsEligible)
	s.mu.Lock()
	defer s.mu.Unlock()
	addLyricSourceRound(s.today(), o)
	s.dirty = true
}

// noteLyricSourceTrip:熔断跳闸时记一笔原因(sourcebreaker.go 跳闸处调)。
func noteLyricSourceTrip(source, reason string) {
	s := lyricSourceStatsShared.Load()
	if s == nil || source == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.today().counts(source)
	if c.Trips == nil {
		c.Trips = map[string]int{}
	}
	c.Trips[reason]++
	s.dirty = true
}

// today:调用方持锁。
func (s *lyricSourceStats) today() *lyricSourceStatsDay {
	k := s.now().Format(lyricSourceStatsDayLayout)
	d := s.data.Days[k]
	if d == nil {
		d = &lyricSourceStatsDay{}
		s.data.Days[k] = d
	}
	return d
}

func (s *lyricSourceStats) saveIfNeeded() {
	s.mu.Lock()
	need := s.dirty || s.now().Sub(s.lastSave) >= lyricSourceStatsRefreshAge
	s.mu.Unlock()
	if need {
		s.save()
	}
}

func (s *lyricSourceStats) save() {
	// 开关在锁外取:noteLyricSourceTrip 是熔断器持着自己的锁调进来的,持 s.mu 时别再调 features 这类外部函数。
	on := map[string]bool{}
	for _, src := range lyricSourceNames {
		on[src] = lyricSourceEnabled(src)
	}
	s.mu.Lock()
	now := s.now()
	pruneLyricSourceStats(s.data.Days, now, lyricSourceStatsKeepDays)
	s.data.Summary = summarizeLyricSourceStats(s.data.Days, now, func(src string) bool { return on[src] })
	s.data.UpdatedAt = now.Unix()
	b, err := json.Marshal(s.data)
	s.dirty = false
	s.lastSave = now
	s.mu.Unlock()
	if err != nil {
		log.Printf("lyric source stats: marshal: %v", err)
		return
	}
	if err := writeFileAtomic(s.path, b); err != nil {
		log.Printf("lyric source stats: write %s: %v", s.path, err)
	}
}

// readLyricSourceStatsFile:healthcheck 读常驻进程写下的那份。读不到返回 nil。
func readLyricSourceStatsFile() *lyricSourceStatsFile {
	b, err := os.ReadFile(configFilePath(lyricSourceStatsFileName))
	if err != nil {
		return nil
	}
	var f lyricSourceStatsFile
	if json.Unmarshal(b, &f) != nil {
		return nil
	}
	return &f
}

// ---- healthcheck 那几行 ----

// lyricSourceStatsHealthItems:healthcheck 里「歌词源近况」。f 是常驻进程写下的统计(readLyricSourceStatsFile):
// 一行近 7 天各源的给出候选率 / 胜出率,每个有异常的源再单列一行警告。只出 warn,不出 fail ——
// 统计说的是这几天的趋势,不是「这一刻歌词出不来」。
func lyricSourceStatsHealthItems(f *lyricSourceStatsFile, now time.Time) []healthCheckItem {
	if f == nil || len(f.Summary) == 0 {
		return []healthCheckItem{{Name: "歌词源近况", Status: healthWarn, Detail: "还没有统计(常驻进程在播放时查过歌词之后才有)"}}
	}
	var parts []string
	var items []healthCheckItem
	for _, s := range f.Summary {
		if !s.Enabled || s.Rounds == 0 {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s %d%%/%d%%(%d)", s.Source,
			percentOf(s.Responded, s.Rounds), percentOf(s.Won, s.Rounds), s.Rounds))
		if detail := lyricSourceAlertDetail(s); detail != "" {
			items = append(items, healthCheckItem{Name: "歌词源近况 · " + s.Source, Status: healthWarn, Detail: detail})
		}
	}
	age := now.Sub(time.Unix(f.UpdatedAt, 0))
	head := healthCheckItem{Name: "歌词源近 7 天", Status: healthOK,
		Detail: "给出候选/胜出(查了几次):" + strings.Join(parts, " ")}
	if len(parts) == 0 {
		head.Detail = "还没有现查记录(播到没解析过的歌、补搜或升级重试时才记)"
	}
	if age > lyricSourceStatsStaleAfter {
		head.Status = healthWarn
		head.Detail += fmt.Sprintf(";统计 %d 天没更新,常驻进程可能没在跑", int(age.Hours()/24))
	}
	return append([]healthCheckItem{head}, items...)
}

func percentOf(n, total int) int {
	if total <= 0 {
		return 0
	}
	return int(math.Round(float64(n) * 100 / float64(total)))
}

func lyricSourceAlertDetail(s lyricSourceStatsSummary) string {
	switch s.Alert {
	case lyricSourceAlertBarely:
		return fmt.Sprintf("最近 3 天同类曲库至少两家找到歌词的 %d 次查询里,它只在 %d%% 给出了歌词:接口可能变了,或者请求被拦了",
			s.PeerRounds, int(math.Round(s.PeerRate*100)))
	case lyricSourceAlertBelowUsual:
		return fmt.Sprintf("最近 3 天同类曲库至少两家找到歌词的 %d 次查询里,它在 %d%% 给出了歌词,平时是 %d%%", s.PeerRounds,
			int(math.Round(s.PeerRate*100)), int(math.Round(s.UsualRate*100)))
	case lyricSourceAlertCooling:
		return fmt.Sprintf("最近 2 天有 %d%% 的查询因为它接连出错被熔断跳过", int(math.Round(s.SkipRate*100)))
	case lyricSourceAlertNetwork:
		return fmt.Sprintf("最近 2 天有 %d%% 的查询因为连不上它被跳过,%s 也一样:多半是网络到不了(比如没开代理),不是源坏了",
			int(math.Round(s.SkipRate*100)), strings.Join(s.NetworkPeers, "/"))
	}
	return ""
}
