package main

import "time"

// 歌词源的小时额度:滚动一小时里给这个源发了多少个请求(前台后台一起算),到了额度后台请求就不发,前台照发。
// 令牌桶(hostRateFor)只削尖峰,管不住几个小时的累计量;Musixmatch 的反爬按出口 IP 的累计请求量拦,每小时
// 400 多次连着两三个小时就被拦,拦下之后正在播的歌也问不了它。见 09 章决策 327。
//
// 被额度拦下的后台请求记进这一轮的跳过名单(lyricSourceSkipReasonBudget),跟排不上队一样,以后自动补问;
// 各源近况统计不算它这一轮。导入清单起下一首之前先看余量(sourceBudgetLeft),不够就等,保证导入的每一首都问到这个源。

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
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	g.sourceHits[source] = append(pruneSourceHits(g.sourceHits[source], now), now)
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
