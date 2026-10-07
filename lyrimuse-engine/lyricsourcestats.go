package main

import (
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"log"
	"math"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 歌词源的按天统计:每个源在现查里被问了几次、交出候选几次、胜出几次、因熔断被跳过几次,以及按「同类源」
// 条件算的命中率。落盘时顺带算出每个源的摘要和判定,给设置页「歌词来源」卡和 healthcheck 用。判定规则
// 与阈值的依据见 09 章决策 147、202。
//
// 只认 first-resolve / refill / upgrade 三条现查路径:批量重打分不一定发新请求,别把它数进来。只有常驻
// 进程记(startLyricSourceStats 在 run 里调);一次性子命令走同一段解析代码时这里是空操作,两个进程同写
// 这份文件会互相覆盖。
//
// 命中率只在「同一类曲库里另有至少两家给了候选」的那几次里算。「比平时少」要跟这个源自己的过去比,而一个源
// 给不给得出词很看歌是哪种文字(经 YouTube Music 取的 LyricFind:西文歌一半给得出,中文歌两成),这几天多听
// 了哪种歌就能把比例带偏 —— 所以同类计数按歌名 / 歌手名带不带中日韩文字分两类记,「平时应有」按这几天两类
// 各占多少现算(决策 202)。

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
	// lyricSourceStatsStaleTempAge:启动时清掉多久以前的写盘临时文件。只有常驻进程写这份文件,一次写盘是毫秒级,
	// 留一分钟只是不去碰上一个进程退出前刚起的那份。
	lyricSourceStatsStaleTempAge = time.Minute
	// lyricSourceRecentKeep / lyricSourceRecentMaxAge:快速判定用的逐轮记录,每个源最多留多少条、留多久。
	lyricSourceRecentKeep   = 120
	lyricSourceRecentMaxAge = 7 * 24 * time.Hour
)

// 判定阈值,数字的来历见 09 章决策 147、202。
const (
	// 几乎不给词:3 天窗口里同类条件命中率低于这个值。只跟同类源比、不看自己的过去 —— 接入那天就坏着的源
	// (酷我少带 vipver=1 那次)靠它抓。
	lyricSourceBarelyRate      = 0.10
	lyricSourceBarelyMinRounds = 50
	// 比平时少一大截:低于「平时应有」的这个比例。「平时应有」= 3 天窗口里两类各自的轮数 × 那一类的基线,
	// 再加起来;只算有基线的那几类。
	lyricSourceBelowUsualRatio     = 0.6
	lyricSourceBelowUsualMinRounds = 100
	lyricSourceBelowUsualMinBase   = 0.2
	lyricSourceBaselineDays        = 14
	// 基线 = 此前 14 天里一类样本 ≥ lyricSourceBaselineMinRounds 的那些天各自命中率的中位数,
	// 够格的天数不到 lyricSourceBaselineMinDays 的那一类没有基线。
	lyricSourceBaselineMinRounds = 20
	lyricSourceBaselineMinDays   = 7
	// 大部分时间在冷却:2 天窗口里被跳过的轮数超过这个比例。
	lyricSourceCoolingRatio     = 0.5
	lyricSourceCoolingMinRounds = 20
	// 同时有这么多个源因为网络错误在冷却,算「网络到不了」,不算源坏了。
	lyricSourceNetworkMinSources = 2
	// 快速判定:从它上一次给出候选往后,同类条件成立的轮数到这么多才看。按天的计数要两三天才反应得过来,
	// 一个源半天里整个哑掉时等不了那么久。
	lyricSourceStreakMinRounds = 20
	// 快速判定「突然不给了」:这一段问了它的那些轮,每位歌手只算一次、按那一类的基线累加,平时本该给出至少
	// 这么多次。
	lyricSourceStoppedMinExpected = 12
)

// 判定结果(写进摘要的 alert 字段,App 侧 LyricSourceHealth.Alert 是同一套取值)。
const (
	lyricSourceAlertBarely     = "barely"
	lyricSourceAlertBelowUsual = "below_usual"
	lyricSourceAlertCooling    = "cooling"
	lyricSourceAlertNetwork    = "network"
	// lyricSourceAlertBlocked:没问它的那些轮大半是因为被它的反爬拦下了(sourcebreaker.go「反爬拦截」)。
	lyricSourceAlertBlocked = "blocked"
	// lyricSourceAlertStopped:最近连续一段里它一首词都没给,按它平时的收录这不该发生。
	lyricSourceAlertStopped = "stopped"
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

// 同类计数按歌的文字分的两类:歌名或歌手名带汉字 / 假名 / 谚文(containsCJKScript)的算一类,其余算一类。
const (
	lyricSourceClassOther = iota
	lyricSourceClassCJK
	lyricSourceClassCount
)

func lyricSourceClassOf(cjk bool) int {
	if cjk {
		return lyricSourceClassCJK
	}
	return lyricSourceClassOther
}

// lyricSourceDayCounts:一个源一天的计数。asked = 开着、这一轮问了它;skipped = 开着但因熔断冷却 / 限流
// 没问(两者互斥,合起来是这个源开着的现查轮数)。peer_rounds / peer_hits 只在问了它的轮里数。
type lyricSourceDayCounts struct {
	Asked   int `json:"asked,omitempty"`
	Skipped int `json:"skipped,omitempty"`
	// SkippedBlocked:Skipped 里因为被它的反爬拦下而没问的那部分。
	SkippedBlocked int `json:"skipped_blocked,omitempty"`
	Responded      int `json:"responded,omitempty"`
	Usable         int `json:"usable,omitempty"`
	Won            int `json:"won,omitempty"`
	PeerRounds     int `json:"peer_rounds,omitempty"`
	PeerHits       int `json:"peer_hits,omitempty"`
	// PeerRoundsCJK / PeerHitsCJK:PeerRounds / PeerHits 里歌名或歌手名带中日韩文字的那部分,其余是另一类。
	// 只有带 classes 标记的那天作数。
	PeerRoundsCJK int `json:"peer_rounds_cjk,omitempty"`
	PeerHitsCJK   int `json:"peer_hits_cjk,omitempty"`
	// Trips:熔断跳闸次数,按原因(sourcebreaker.go 的 lyricSourceCooldownReason*)。
	Trips map[string]int `json:"trips,omitempty"`
}

// classPeers:这一类的同类条件轮数和命中数。
func (c *lyricSourceDayCounts) classPeers(class int) (rounds, hits int) {
	if class == lyricSourceClassCJK {
		return c.PeerRoundsCJK, c.PeerHitsCJK
	}
	return c.PeerRounds - c.PeerRoundsCJK, c.PeerHits - c.PeerHitsCJK
}

type lyricSourceStatsDay struct {
	Rounds int `json:"rounds"`
	// Classes:这一天从第一轮起就分两类记了(决策 202 之后才开的日子)。升级那天是半路开始分的,不带它,
	// 按两类算的基线和窗口都跳过那天。
	Classes bool                             `json:"classes,omitempty"`
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

// lyricSourceSkipReasonUnknown:被跳过的那一轮记下时,熔断器已经说不出原因(冷却刚好到期)。
const lyricSourceSkipReasonUnknown = "cooldown"

// lyricSourceRecentRound:一个源的一轮结局,快速判定(lyricSourceStreakOf)用。只记同类条件成立的轮(同组另有
// 至少两家给了候选),外加它给了候选的轮 —— 同类不够两家时它给了,也说明它还活着。
type lyricSourceRecentRound struct {
	At  int64 `json:"t"`
	Hit bool  `json:"h,omitempty"`
	// Skip:没问它的原因(lyricSourceCooldownReason*,说不出时是 lyricSourceSkipReasonUnknown);空 = 问了。
	Skip string `json:"s,omitempty"`
	CJK  bool   `json:"c,omitempty"`
	// Artist:歌手名(normLoose 之后)的 FNV-1a 哈希,只用来数几位不同的歌手,不存名字本身。
	Artist uint32 `json:"a,omitempty"`
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
	// Streak:快速判定那两条(stopped、按最近几轮判的 blocked),最近连续多少轮同类条件成立、它一首都没给。
	Streak int `json:"streak,omitempty"`
	// ExpectedHits:stopped 那条,按它平时的收录这一段本该给出几次(四舍五入)。
	ExpectedHits int `json:"expected_hits,omitempty"`
	// BlockedRounds:blocked 那条,因为被反爬拦下而没问它的轮数。
	BlockedRounds int `json:"blocked_rounds,omitempty"`
}

type lyricSourceStatsFile struct {
	UpdatedAt int64                           `json:"updated_at"`
	Days      map[string]*lyricSourceStatsDay `json:"days"`
	// Recent:各源的逐轮记录(lyricSourceRecentRound),旧的在前。
	Recent  map[string][]lyricSourceRecentRound `json:"recent,omitempty"`
	Summary []lyricSourceStatsSummary           `json:"summary"`
}

// lyricSourceRoundOutcome:一轮现查里各源的结局。enabled 是这一轮该问的源(开着、而且配置上用得了)。
type lyricSourceRoundOutcome struct {
	enabled []string
	skipped map[string]bool
	// skipReason:被跳过的源当时为什么不能问(sourcebreaker.go cooldownReason),只有被跳过的源才有。
	skipReason map[string]string
	responded  map[string]bool
	usable     map[string]bool
	winner     string
	// cjk:这首歌的歌名或歌手名带中日韩文字,同类计数按它分类。
	cjk bool
	// artist:歌手名的短哈希(lyricSourceArtistHash)。
	artist uint32
}

// lyricSourcePeersResponded:这一轮同组除 src 以外给了候选的有几家;不在任何一组的源是 0。
func lyricSourcePeersResponded(o lyricSourceRoundOutcome, src string) int {
	n := 0
	for _, p := range lyricSourcePeerGroup(src) {
		if p != src && o.responded[p] {
			n++
		}
	}
	return n
}

// addLyricSourceRound 把一轮结局加进当天的计数。纯函数,单测直接覆盖。
func addLyricSourceRound(day *lyricSourceStatsDay, o lyricSourceRoundOutcome) {
	day.Rounds++
	for _, src := range o.enabled {
		c := day.counts(src)
		if o.skipped[src] {
			c.Skipped++
			if o.skipReason[src] == lyricSourceCooldownReasonBlocked {
				c.SkippedBlocked++
			}
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
		if lyricSourcePeersResponded(o, src) >= 2 {
			c.PeerRounds++
			if o.cjk {
				c.PeerRoundsCJK++
			}
			if o.responded[src] {
				c.PeerHits++
				if o.cjk {
					c.PeerHitsCJK++
				}
			}
		}
	}
}

// addLyricSourceRecent 把一轮结局追加进各源的逐轮记录(记哪几轮见 lyricSourceRecentRound),每个源只留最近
// lyricSourceRecentKeep 条。纯函数,单测直接覆盖。
func addLyricSourceRecent(recent map[string][]lyricSourceRecentRound, o lyricSourceRoundOutcome, at time.Time) {
	for _, src := range o.enabled {
		if lyricSourcePeerGroup(src) == nil {
			continue
		}
		hit := !o.skipped[src] && o.responded[src]
		if !hit && lyricSourcePeersResponded(o, src) < 2 {
			continue
		}
		r := lyricSourceRecentRound{At: at.Unix(), Hit: hit, CJK: o.cjk, Artist: o.artist}
		if o.skipped[src] {
			r.Skip = o.skipReason[src]
			if r.Skip == "" {
				r.Skip = lyricSourceSkipReasonUnknown
			}
		}
		list := append(recent[src], r)
		if len(list) > lyricSourceRecentKeep {
			list = slices.Clone(list[len(list)-lyricSourceRecentKeep:])
		}
		recent[src] = list
	}
}

// lyricSourceOutcomeFromDecision 从一份决策记录拼出这一轮的结局。enabled 判这个源开没开,eligible 判
// 配置上用不用得了(Apple Music 没连账号时不发请求、恒为空,数进来就是误报),skipReason 答被跳过的源
// 当时为什么在冷却(nil = 不问)。
func lyricSourceOutcomeFromDecision(d *lyricsDecision, enabled, eligible func(string) bool, skipReason func(string) string) lyricSourceRoundOutcome {
	o := lyricSourceRoundOutcome{
		skipped:    map[string]bool{},
		skipReason: map[string]string{},
		responded:  map[string]bool{},
		usable:     map[string]bool{},
		winner:     d.Winner,
		cjk:        containsCJKScript(d.QueryArtist) || containsCJKScript(d.QueryTitle),
		artist:     lyricSourceArtistHash(d.QueryArtist),
	}
	for _, s := range d.SourcesSkipped {
		o.skipped[s] = true
		if skipReason != nil {
			o.skipReason[s] = skipReason(s)
		}
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

// lyricSourceArtistHash:歌手名归一之后的 FNV-1a 哈希(lyricSourceRecentRound.Artist)。
func lyricSourceArtistHash(artist string) uint32 {
	h := fnv.New32a()
	h.Write([]byte(normLoose(artist)))
	return h.Sum32()
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
	asked, skipped, skippedBlocked, peerRounds, peerHits int
	trips                                                map[string]int
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
		w.skippedBlocked += c.SkippedBlocked
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

// summarizeLyricSourceStats 算每个源的摘要和判定。纯函数,单测拿回放数据覆盖。recent 是各源的逐轮记录
// (lyricSourceStatsFile.Recent),快速判定用。
func summarizeLyricSourceStats(days map[string]*lyricSourceStatsDay, recent map[string][]lyricSourceRecentRound,
	today time.Time, enabled func(string) bool) []lyricSourceStatsSummary {
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
		if lyricSourcePeerGroup(src) != nil && judgeLyricSource(&s, days, recent[src], last2, last3, base) {
			coolingNetwork[src] = true
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

// judgeLyricSource 给同类组里的一个源下判定,写进 s;返回它是不是网络原因的冷却(并不并进「网络」那一档,
// 由调用方看一共有几个源这样)。
//
// 优先级:冷却 / 网络 / 被反爬拦下 > 突然不给了 > 几乎不给词 > 比平时少。冷却和被拦时这个源大部分轮没被问,
// 命中率的分母本来就小,说「几乎不给词」会把原因说错;快速判定只看最近,排在按天的两条前面。
func judgeLyricSource(s *lyricSourceStatsSummary, days map[string]*lyricSourceStatsDay, recent []lyricSourceRecentRound,
	last2, last3, base []string) (coolingNetwork bool) {
	cool := sumLyricSourceWindow(days, s.Source, last2)
	win := sumLyricSourceWindow(days, s.Source, last3)
	usual, have := lyricSourceClassBaseline(days, s.Source, base)
	streak := lyricSourceStreakOf(recent, usual, have)
	total := cool.asked + cool.skipped
	blockedMost := 2*cool.skippedBlocked > cool.skipped
	// 被拦的源一旦又给出了候选(最近记下的那一轮就是),别再按 2 天窗口报「已暂停」:暂停已经撤了,
	// 窗口里的那些跳过要两天才滚出去。
	recovered := len(recent) > 0 && recent[len(recent)-1].Hit
	switch {
	case total >= lyricSourceCoolingMinRounds && float64(cool.skipped) > lyricSourceCoolingRatio*float64(total) &&
		!(blockedMost && recovered):
		s.SkipRate = roundRate(float64(cool.skipped) / float64(total))
		if blockedMost {
			s.Alert = lyricSourceAlertBlocked
			s.BlockedRounds = cool.skippedBlocked
			return false
		}
		s.Alert = lyricSourceAlertCooling
		network := cool.trips[lyricSourceCooldownReasonNetwork]
		return network > 0 && network >= cool.trips[lyricSourceCooldownReasonServerError]+cool.trips[lyricSourceCooldownReasonRateLimited]
	case streak.rounds >= lyricSourceStreakMinRounds && 2*streak.blocked >= streak.rounds:
		s.Alert = lyricSourceAlertBlocked
		s.Streak = streak.rounds
		s.BlockedRounds = streak.blocked
	case streak.rounds >= lyricSourceStreakMinRounds && streak.expected >= lyricSourceStoppedMinExpected:
		s.Alert = lyricSourceAlertStopped
		s.Streak = streak.rounds
		s.ExpectedHits = int(math.Round(streak.expected))
	case win.peerRounds >= lyricSourceBarelyMinRounds && float64(win.peerHits) < lyricSourceBarelyRate*float64(win.peerRounds):
		s.Alert = lyricSourceAlertBarely
		s.PeerRate = roundRate(float64(win.peerHits) / float64(win.peerRounds))
		s.PeerRounds = win.peerRounds
	default:
		mix := lyricSourceMixWindow(days, s.Source, last3, usual, have)
		if mix.rounds >= lyricSourceBelowUsualMinRounds && mix.expected >= lyricSourceBelowUsualMinBase*float64(mix.rounds) &&
			float64(mix.hits) < lyricSourceBelowUsualRatio*mix.expected {
			s.Alert = lyricSourceAlertBelowUsual
			s.PeerRate = roundRate(float64(mix.hits) / float64(mix.rounds))
			s.PeerRounds = mix.rounds
			s.UsualRate = roundRate(mix.expected / float64(mix.rounds))
		}
	}
	return false
}

// lyricSourceClassBaseline:两类各自的基线 = keys 那几天(只认带 classes 标记的)里这一类样本
// ≥ lyricSourceBaselineMinRounds 的每天命中率的中位数;够格的天数不到 lyricSourceBaselineMinDays 的那一类
// 没有基线(have 为 false)。
func lyricSourceClassBaseline(days map[string]*lyricSourceStatsDay, source string, keys []string) (
	usual [lyricSourceClassCount]float64, have [lyricSourceClassCount]bool) {
	var rates [lyricSourceClassCount][]float64
	for _, k := range keys {
		d := days[k]
		if d == nil || !d.Classes || d.Sources[source] == nil {
			continue
		}
		c := d.Sources[source]
		for class := range lyricSourceClassCount {
			if n, hits := c.classPeers(class); n >= lyricSourceBaselineMinRounds {
				rates[class] = append(rates[class], float64(hits)/float64(n))
			}
		}
	}
	for class, r := range rates {
		if len(r) >= lyricSourceBaselineMinDays {
			usual[class], have[class] = lyricSourceMedian(r), true
		}
	}
	return usual, have
}

func lyricSourceMedian(v []float64) float64 {
	sort.Float64s(v)
	mid := len(v) / 2
	if len(v)%2 == 1 {
		return v[mid]
	}
	return (v[mid-1] + v[mid]) / 2
}

// lyricSourceMix:窗口里有基线的那几类加起来的同类条件轮数、命中数,和按各类基线算出的「平时应有」命中数。
type lyricSourceMix struct {
	rounds, hits int
	expected     float64
}

// lyricSourceMixWindow:keys 那几天(只认带 classes 标记的)按两类各自的基线算「平时应有」。没有基线的那一类
// 整类不算 —— 拿不准它平时给多少,就不拿它来比。
func lyricSourceMixWindow(days map[string]*lyricSourceStatsDay, source string, keys []string,
	usual [lyricSourceClassCount]float64, have [lyricSourceClassCount]bool) lyricSourceMix {
	var m lyricSourceMix
	for _, k := range keys {
		d := days[k]
		if d == nil || !d.Classes || d.Sources[source] == nil {
			continue
		}
		c := d.Sources[source]
		for class := range lyricSourceClassCount {
			if !have[class] {
				continue
			}
			n, hits := c.classPeers(class)
			m.rounds += n
			m.hits += hits
			m.expected += float64(n) * usual[class]
		}
	}
	return m
}

// lyricSourceStreak:逐轮记录末尾、它上一次给出候选之后的那一段(都是同类条件成立、它没给的轮)。
type lyricSourceStreak struct {
	rounds int
	// blocked:其中因为被反爬拦下而没问它的轮数。
	blocked int
	// expected:其中问了它的那些轮,每位歌手只算一次、按那一类的基线累加 —— 平时本该给出几次。没有基线的
	// 那一类不加。
	expected float64
}

// lyricSourceStreakOf 算 recent(旧的在前)末尾那一段。按歌手去重:同一张专辑一口气预取十几首,它没收录这位
// 歌手就是十几轮一起落空,按轮算会把一位歌手当成十几次独立的机会。
func lyricSourceStreakOf(recent []lyricSourceRecentRound, usual [lyricSourceClassCount]float64,
	have [lyricSourceClassCount]bool) lyricSourceStreak {
	var st lyricSourceStreak
	seen := map[uint32]bool{}
	for i := len(recent) - 1; i >= 0; i-- {
		r := recent[i]
		if r.Hit {
			break
		}
		st.rounds++
		if r.Skip != "" {
			if r.Skip == lyricSourceCooldownReasonBlocked {
				st.blocked++
			}
			continue
		}
		if seen[r.Artist] {
			continue
		}
		seen[r.Artist] = true
		if class := lyricSourceClassOf(r.CJK); have[class] {
			st.expected += usual[class]
		}
	}
	return st
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

// pruneLyricSourceRecent 删掉逐轮记录里比 now 早 maxAge 以上的条目:源关掉一阵再打开,不该拿几周前那一段来判。
func pruneLyricSourceRecent(recent map[string][]lyricSourceRecentRound, now time.Time, maxAge time.Duration) {
	cutoff := now.Add(-maxAge).Unix()
	for src, list := range recent {
		i := 0
		for i < len(list) && list[i].At < cutoff {
			i++
		}
		switch {
		case i == len(list):
			delete(recent, src)
		case i > 0:
			recent[src] = slices.Clone(list[i:])
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
	// stopLoop / loopDone:定时落盘那个 goroutine 的开关和「已经停下」的信号,给 stopLyricSourceStats 用。
	stopLoop context.CancelFunc
	loopDone chan struct{}
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
	if s.data.Recent == nil {
		s.data.Recent = map[string][]lyricSourceRecentRound{}
	}
	return s
}

// startLyricSourceStats:常驻进程启动时调一次。清掉上一个进程写到一半留下的临时文件,读回旧数据、立刻按今天
// 重算一次摘要(日期变了,旧摘要里的判定可能已经过期),之后定时落盘。退出前的最后一次由 stopLyricSourceStats 写。
func startLyricSourceStats(ctx context.Context) {
	path := configFilePath(lyricSourceStatsFileName)
	if path == lyricSourceStatsFileName {
		return
	}
	if removed, _ := removeStaleWriteTemps(path, lyricSourceStatsStaleTempAge); removed > 0 {
		log.Printf("lyric source stats: removed %d stale temp file(s)", removed)
	}
	s := loadLyricSourceStats(path, time.Now)
	lyricSourceStatsShared.Store(s)
	s.save()
	loopCtx, cancel := context.WithCancel(ctx)
	s.stopLoop, s.loopDone = cancel, make(chan struct{})
	go func() {
		defer close(s.loopDone)
		t := time.NewTicker(lyricSourceStatsFlushEvery)
		defer t.Stop()
		for {
			select {
			case <-loopCtx.Done():
				return
			case <-t.C:
				s.saveIfNeeded()
			}
		}
	}()
}

// stopLyricSourceStats:常驻进程 run() 返回前调(defer)。先停掉定时落盘、等它手上那次写完,再当场写最后一次。
//
// 别把最后一次写放回那个 goroutine、收到取消时再写:没人等它,main 照常退出,写到一半的临时文件就留在配置
// 目录里(频繁重启时约三成的退出留下一个,个个都在退出前后 5 秒内),最后那一分钟的计数也跟着丢。
func stopLyricSourceStats() {
	s := lyricSourceStatsShared.Load()
	if s == nil || s.stopLoop == nil {
		return
	}
	s.stopLoop()
	<-s.loopDone
	s.save()
}

// noteLyricSourceDecision:一轮决策定下来时记一笔(traceLyricsDecision 开头调)。不是现查、或者不在常驻
// 进程里时是空操作。
func noteLyricSourceDecision(d *lyricsDecision) {
	s := lyricSourceStatsShared.Load()
	if s == nil || d == nil || !lyricSourceStatsCountsPath(d.Path) {
		return
	}
	// 冷却原因在 s.mu 外面问:熔断器是持着自己的锁调 noteLyricSourceTrip 进来的,持着 s.mu 再去拿它的锁会反过来。
	o := lyricSourceOutcomeFromDecision(d, lyricSourceEnabled, lyricSourceStatsEligible, sharedLyricSourceBreaker().cooldownReason)
	s.mu.Lock()
	defer s.mu.Unlock()
	addLyricSourceRound(s.today(), o)
	addLyricSourceRecent(s.data.Recent, o, s.now())
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

// today:调用方持锁。新开的一天从第一轮起就分两类记;读回来的、升级之前开的那天保持原样。
func (s *lyricSourceStats) today() *lyricSourceStatsDay {
	k := s.now().Format(lyricSourceStatsDayLayout)
	d := s.data.Days[k]
	if d == nil {
		d = &lyricSourceStatsDay{Classes: true}
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
	pruneLyricSourceRecent(s.data.Recent, now, lyricSourceRecentMaxAge)
	s.data.Summary = summarizeLyricSourceStats(s.data.Days, s.data.Recent, now, func(src string) bool { return on[src] })
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
		return fmt.Sprintf("最近 3 天同类曲库至少两家找到歌词的 %d 次查询里,它在 %d%% 给出了歌词,按这几天的语种构成平时约 %d%%",
			s.PeerRounds, int(math.Round(s.PeerRate*100)), int(math.Round(s.UsualRate*100)))
	case lyricSourceAlertCooling:
		return fmt.Sprintf("最近 2 天有 %d%% 的查询因为它接连出错被熔断跳过", int(math.Round(s.SkipRate*100)))
	case lyricSourceAlertNetwork:
		return fmt.Sprintf("最近 2 天有 %d%% 的查询因为连不上它被跳过,%s 也一样:多半是网络到不了(比如没开代理),不是源坏了",
			int(math.Round(s.SkipRate*100)), strings.Join(s.NetworkPeers, "/"))
	case lyricSourceAlertBlocked:
		return fmt.Sprintf("被它的反爬拦下了,最近 %d 次查询因此没问它;已暂停,隔一阵自动再试", s.BlockedRounds)
	case lyricSourceAlertStopped:
		return fmt.Sprintf("最近连续 %d 次同类曲库至少两家找到歌词的查询里,它一次都没给,按平时本该给约 %d 次:接口可能变了,或者请求被拦了",
			s.Streak, s.ExpectedHits)
	}
	return ""
}
