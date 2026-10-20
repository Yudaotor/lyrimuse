package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
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

// dailyDigestCatchUpUntilHour：头天晚上那一期没推成(22 点后取数 / 推送一直失败、关机或睡眠错过)，
// 第二天本地时间这个小时之前的检查补推头天那一期；过了就不补了——周报、月报停机后补推最近一期，
// 日报的「最近一期」只在第二天上午还算新鲜。见 15 章决策 69。
const dailyDigestCatchUpUntilHour = 12

// dailyDigestState 持久化"已推送到哪一天"(本地日期字符串 YYYY-MM-DD)，防止
// 同一天内被 dailyDigestCheckInterval 的多次检查重复推送、也防重启后重推当天已推过
// 的报告。用日期字符串而不是像 weeklyDigestState 那样用时间戳——这里比较的是"哪一天"，
// 不是"是否已经过了某个精确边界时刻"，YYYY-MM-DD 按字典序比就是按日期先后比，不用另外
// 套一层时间戳转日期的逻辑。
type dailyDigestState struct{ path string }

func (s dailyDigestState) load() string {
	if s.path == "" {
		return ""
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		noteFileErr("read", s.path, err)
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
	// 原子写 + 记错误:写到一半(磁盘满、被杀)留下半截 JSON,读回来是零值 —— 下一轮会把上一期当成还没发、再推一次。
	if err := writeFileAtomic(s.path, data); err != nil {
		slog.Error("daily digest: save state failed", "err", err)
	}
}

var dailyDigestPath string

// dailyDigestCatchUpDeadline:这一天补推昨天那期的截止时刻。平时是 dailyDigestCatchUpUntilHour 点;这一刻落在静默时段
// (quiet,见 notifyquiet.go)里时顺延到那段静默结束后再一个 dailyDigestCheckInterval —— 静默期间检查被压着,不顺延的话
// 静默一结束就已经过了截止,头天那期就丢了;静默结束那一拍必查,落在顺延的窗口里。见 15 章决策 72。
func dailyDigestCatchUpDeadline(midnight time.Time, quiet notifyQuietHours) time.Time {
	cutoff := time.Date(midnight.Year(), midnight.Month(), midnight.Day(), dailyDigestCatchUpUntilHour, 0, 0, 0, midnight.Location())
	if !quiet.active(cutoff) {
		return cutoff
	}
	return quiet.endAfter(cutoff).Add(dailyDigestCheckInterval)
}

// dailyDigestTarget 判这一次检查该推哪一期：本地时间到了 dailyDigestTriggerHour 推今天
// (今天零点到此刻)；补推截止(dailyDigestCatchUpDeadline)之前推昨天(昨天零点到今天零点，补头天晚上没推成的那期)；
// 其余时段 ok=false。day 是该期的本地日期(YYYY-MM-DD)，跟 dailyDigestState 里记的比。
func dailyDigestTarget(now time.Time, quiet notifyQuietHours) (day string, from, to time.Time, title string, ok bool) {
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	switch {
	case now.Hour() >= dailyDigestTriggerHour:
		return midnight.Format("2006-01-02"), midnight, now, fmt.Sprintf("🎧 今日听歌报告（%s）", now.Format("01-02")), true
	case now.Before(dailyDigestCatchUpDeadline(midnight, quiet)):
		yesterday := midnight.AddDate(0, 0, -1)
		return yesterday.Format("2006-01-02"), yesterday, midnight, fmt.Sprintf("🎧 昨日听歌报告（%s）", yesterday.Format("01-02")), true
	}
	return "", time.Time{}, time.Time{}, "", false
}

// dailyDigest 检查(至多每 dailyDigestCheckInterval 一次)这时该推哪一期(见 dailyDigestTarget)、
// 那一期推过没有，没推过就按 features().DailyDigestSource 解析出的数据源(Last.fm 或 ListenBrainz，
// 见 digest.go 的 resolveDigestSource)拉那一期的统计推一条报告。取数/聚合/拼文案的逻辑统一定义在
// digest.go(lastfmDigestStats/listenbrainzDigestStats)，这里只负责判断该不该触发、选哪个源、传时间范围。
// 状态只记推到哪天：补推的昨天那期记下后，当晚今天那期日期更大照推；昨晚已推过的，第二天上午不再补。
func (p *poller) dailyDigest(now time.Time, env digestEnv) {
	if !features().DailyDigest || !env.alerter.configured(notifyEventDaily) {
		return
	}
	if !digestCheckDue(now, p.dailyLastCheckedAt, dailyDigestCheckInterval) {
		return
	}
	if digestQuietHold(now, &p.dailyQuietHeld) {
		return // 静默时段里:不推、不记检查时刻,静默一结束下一拍就查(notifyquiet.go)
	}
	p.dailyLastCheckedAt = now.Round(0)
	deferred := digestQuietRelease(&p.dailyQuietHeld)

	day, from, to, title, ok := dailyDigestTarget(now, features().NotificationQuietHours)
	if !ok {
		return
	}
	if day <= p.dailyState.load() {
		return // 这一期已经推送过了
	}

	lastfmConfigured := env.cfg.LastfmUser != "" && env.cfg.lastfmBridgeAPIKey() != ""
	lbConfigured := env.cfg.User != "" && env.cfg.Token != ""
	source := resolveDigestSource(features().DailyDigestSource, lastfmConfigured, lbConfigured)
	if source == "" {
		return // 两个账号都没配，这个功能没法跑，等用户配好任意一个
	}

	var stats digestStats
	var err error
	if source == digestSourceLastfm {
		stats, err = lastfmDigestStats(env.ctx, env.cfg.LastfmUser, env.cfg.lastfmBridgeAPIKey(), from.Unix(), to.Unix())
	} else {
		stats, err = listenbrainzDigestStats(env.ctx, env.lbRoot, env.cfg.User, from.Unix(), to.Unix())
	}
	if err != nil {
		return // 拉取失败,不标记已推送,下次检查再试
	}
	if stats.TotalPlays == 0 {
		p.dailyState.save(day) // 那天确实没听,跳过不推送,但仍标记已处理,避免反复重查
		return
	}
	if digestPush(env.alerter, notifyEventDaily, title, stats, deferred) != nil {
		return // 推送没成功,不标记已推送,下次检查再推
	}
	p.dailyState.save(day)
}
