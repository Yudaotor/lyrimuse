package main

import (
	"encoding/json"
	"os"
	"slices"
	"time"
)

// 歌词源的小时额度:滚动一小时里给这个源发了多少个请求(前台后台一起算),到了额度后台请求就不发,前台照发。
// 令牌桶(hostRateFor)只削尖峰,管不住几个小时的累计量;Musixmatch 的反爬按出口 IP 的累计请求量拦,每小时
// 400 多次连着两三个小时就被拦,拦下之后正在播的歌也问不了它。见 09 章决策 327。
//
// 被额度拦下的后台请求记进这一轮的跳过名单(lyricSourceSkipReasonBudget),跟排不上队一样,以后自动补问;
// 各源近况统计不算它这一轮。导入清单起下一首之前先看余量(sourceBudgetLeft),不够就等,保证导入的每一首都问到这个源。
//
// 窗口里的请求时刻存进 sourceBudgetPath,启动时读回来:引擎一天被重启很多次(改设置、装新版),只记在内存里的话每次重启
// 额度都从零算,等于没限。

// sourceBudgetWindow:额度按多长的滚动窗口算。
const sourceBudgetWindow = time.Hour

// newHostGuardSourceBudget:各歌词源一小时的请求额度,0 = 不限。单测总入口换成全部不限,专测额度的用例自己设。
var newHostGuardSourceBudget = func(source string) int {
	if source == "musixmatch" {
		return 240
	}
	return 0
}

// noteSourceHit 记一个发出去的请求。不限额的源不记。
func (g *hostGuard) noteSourceHit(source string) {
	if g.sourceBudget(source) <= 0 {
		return
	}
	g.budgetSaveMu.Lock()
	defer g.budgetSaveMu.Unlock()
	g.mu.Lock()
	now := g.now()
	g.sourceHits[source] = append(pruneSourceHits(g.sourceHits[source], now), now)
	path, snapshot := g.budgetPath, sourceHitsFile(g.sourceHits)
	g.mu.Unlock()
	if path == "" {
		return
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return
	}
	_ = writeFileAtomic(path, data)
}

// sourceHitsFile:存盘的形状,源 → 请求时刻(unix 毫秒)。
func sourceHitsFile(hits map[string][]time.Time) map[string][]int64 {
	out := make(map[string][]int64, len(hits))
	for src, ts := range hits {
		for _, t := range ts {
			out[src] = append(out[src], t.UnixMilli())
		}
	}
	return out
}

// useSourceBudgetFile 让这个闸把额度记在 path,并读回上一个进程记下的请求(窗口外的由 sourceBudgetLeft / noteSourceHit 剪掉)。
func (g *hostGuard) useSourceBudgetFile(path string) {
	var saved map[string][]int64
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
	} else if err := json.Unmarshal(data, &saved); err != nil {
		noteFileErr("decode", path, err)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.budgetPath = path
	// 比此刻还晚的不要(上一个进程写的时候墙钟偏快、之后被校正回来):它要等墙钟追上再过一小时才剪得掉,一直占着额度。
	// 剩下的排好序,pruneSourceHits 遇到第一条没过期的就停。
	now := g.now()
	for src, ms := range saved {
		hits := make([]time.Time, 0, len(ms))
		for _, m := range ms {
			if t := time.UnixMilli(m); !t.After(now) {
				hits = append(hits, t)
			}
		}
		slices.SortFunc(hits, func(a, b time.Time) int { return a.Compare(b) })
		g.sourceHits[src] = hits
	}
}

// sourceBudgetLeft:这个源这一刻还剩几个请求的额度,和要再腾出 need 个还得等多久(够了是 0)。不限额的源 ok=false。
func (g *hostGuard) sourceBudgetLeft(source string, need int) (left int, wait time.Duration, ok bool) {
	budget := g.sourceBudget(source)
	if budget <= 0 {
		return 0, 0, false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	hits := pruneSourceHits(g.sourceHits[source], now)
	g.sourceHits[source] = hits
	left = budget - len(hits)
	if short := need - left; short > 0 {
		// 最早的 short 个请求滑出窗口之后就够了。
		i := min(short, len(hits)) - 1
		wait = hits[i].Add(sourceBudgetWindow).Sub(now)
	}
	return left, wait, true
}

// pruneSourceHits 丢掉窗口外的记录。hits 按时间先后排。
func pruneSourceHits(hits []time.Time, now time.Time) []time.Time {
	cut := now.Add(-sourceBudgetWindow)
	i := 0
	for i < len(hits) && !hits[i].After(cut) {
		i++
	}
	return hits[i:]
}
