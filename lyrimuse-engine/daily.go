package main

import (
	"encoding/json"
	"log/slog"
	"os"
	"time"
)

// dailyDigestCheckInterval：没推成时多久再试一次。到推送时间那一刻的检查不等这个间隔(digestDue)。
const dailyDigestCheckInterval = 30 * time.Minute

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

// dailyDigest 检查(至多每 dailyDigestCheckInterval 一次)这时该推哪一期(见 dailyDigestTarget)、
// 那一期推过没有，没推过就按 features().DailyDigestSource 解析出的数据源(Last.fm 或 ListenBrainz，
// 见 digest.go 的 resolveDigestSource)拉那一期的统计推一条报告。取数/聚合/拼文案的逻辑统一定义在
// digest.go(lastfmDigestStats/listenbrainzDigestStats)，这里只负责判断该不该触发、选哪个源、传时间范围。
// 状态只记推到哪天：补推的昨天那期记下后，当晚今天那期日期更大照推；昨晚已推过的，第二天上午不再补。
func (p *poller) dailyDigest(now time.Time, env digestEnv) {
	if !features().DailyDigest || !env.alerter.configured(notifyEventDaily) {
		return
	}
	if !digestDue(now, p.dailyLastCheckedAt, dailyDigestCheckInterval) {
		return
	}
	p.dailyLastCheckedAt = now.Round(0)

	day, from, to, title := dailyDigestTarget(now, digestPushMinutes())
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
	addDigestExtras(env, source, dailyDigestPeriod(from, to), &stats, now)
	if digestPush(env.alerter, notifyEventDaily, title, stats) != nil {
		return // 推送没成功,不标记已推送,下次检查再推
	}
	p.dailyState.save(day)
}
