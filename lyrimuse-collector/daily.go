// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// dailyDigestCheckInterval：需要"同一天只推一次、过了触发时间就尽快推"的精度，不能
// 像 weeklyDigestCheckInterval(2小时)那么松——但也不用跟 5s 的 poll 循环同频，半小时
// 查一次足够及时。
const dailyDigestCheckInterval = 30 * time.Minute

// dailyDigestTriggerHour：本地时间到了这个小时(含)之后，当天第一次检查就会推送——
// 定在晚上，图的是"今天基本听得差不多了"，参考"每周听歌小结"选在一周收官之后才推
// 同一个思路。没有做成可配置项：weeklyDigest 同样没有配置触发时机这个先例。
const dailyDigestTriggerHour = 22

// dailyDigestState 持久化"已推送到哪一天"(本地日期字符串 YYYY-MM-DD)，防止
// 同一天内被 dailyDigestCheckInterval 的多次检查重复推送、也防重启后重推当天已推过
// 的报告。用日期字符串而不是像 weeklyDigestState 那样用时间戳——这里比较的是"是不是
// 同一天"，不是"是否已经过了某个精确边界时刻"，字符串比较更直白，不用另外套一层
// 时间戳转日期的逻辑。
type dailyDigestState struct{ path string }

func (s dailyDigestState) load() string {
	if s.path == "" {
		return ""
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return ""
	}
	var v struct {
		LastDate string `json:"last_date"`
	}
	json.Unmarshal(b, &v)
	return v.LastDate
}

func (s dailyDigestState) save(date string) {
	if s.path == "" {
		return
	}
	data, err := json.Marshal(struct {
		LastDate string `json:"last_date"`
	}{date})
	if err != nil {
		return
	}
	os.WriteFile(s.path, data, 0o644)
}

var dailyDigestPath string

// dailyDigest 检查(至多每 dailyDigestCheckInterval 一次)当地时间是否已经到了
// dailyDigestTriggerHour、且今天还没推送过，是的话按 features.DailyDigestSource 解析出
// 的数据源(Last.fm 或 ListenBrainz，见 digest.go 的 resolveDigestSource)拉今天的统计
// 推一条报告。取数/聚合/拼文案的逻辑统一定义在 digest.go(lastfmDigestStats/
// listenbrainzDigestStats)，这里只负责判断该不该触发、选哪个源、传今天的时间范围。
func (p *poller) dailyDigest(now time.Time) {
	if !features.DailyDigest || p.lb.alerter == nil || p.lb.alerter.url == "" {
		return
	}
	if !p.dailyLastCheckedAt.IsZero() && now.Sub(p.dailyLastCheckedAt) < dailyDigestCheckInterval {
		return
	}
	p.dailyLastCheckedAt = now

	if now.Hour() < dailyDigestTriggerHour {
		return
	}
	today := now.Format("2006-01-02")
	if today == p.dailyState.load() {
		return // 今天已经推送过了
	}

	lastfmConfigured := p.cfg.LastfmUser != "" && p.cfg.LastfmAPIKey != ""
	lbConfigured := p.cfg.User != "" && p.cfg.Token != ""
	source := resolveDigestSource(features.DailyDigestSource, lastfmConfigured, lbConfigured)
	if source == "" {
		return // 两个账号都没配，这个功能没法跑，等用户配好任意一个
	}

	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	var stats digestStats
	var err error
	if source == digestSourceLastfm {
		stats, err = lastfmDigestStats(p.ctx, p.cfg.LastfmUser, p.cfg.LastfmAPIKey, midnight.Unix(), now.Unix())
	} else {
		stats, err = listenbrainzDigestStats(p.ctx, p.lb.root, p.cfg.User, midnight.Unix(), now.Unix())
	}
	if err != nil {
		return // 拉取失败,不标记已推送,下次检查再试
	}
	if stats.TotalPlays == 0 {
		p.dailyState.save(today) // 今天确实没听,跳过不推送,但仍标记已处理,避免当天反复重查
		return
	}
	digestPush(p.lb.alerter, fmt.Sprintf("🎧 今日听歌报告（%s）", now.Format("01-02")), stats)
	p.dailyState.save(today)
}
