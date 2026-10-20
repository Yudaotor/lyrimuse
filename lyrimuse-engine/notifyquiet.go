package main

import (
	"fmt"
	"time"
)

// 推送提醒的静默时段(推送提醒页「推送渠道」卡底下那一行,features.json 的 notification_quiet_hours)。
// 开着时,落在这段时间里的四档听歌报告不推、也不记「这次检查过了」:检查时刻不往前推,静默一结束的那一拍检查
// 照样到期,不会再等满 30 分钟 / 2 小时的检查间隔(daily.go、weekly.go、calendardigest.go 开头那道闸)。
// 「发送测试」「重发」是用户当场点的,不受它管(notifytest.go)。跨午夜(23:00–08:00)按「开始之后或结束之前」算;
// 开始和结束一样时当成没有静默。见 15 章决策 72。

// notifyQuietHoursFile 是 features.json 里那一段的形状,跟 App 侧 FeatureFlagsFile.NotificationQuietHours 逐字段对应。
// 时刻写成本地时间的 "HH:MM"(24 小时制),手改文件也看得懂。
type notifyQuietHoursFile struct {
	Enabled *bool  `json:"enabled,omitempty"`
	Start   string `json:"start,omitempty"`
	End     string `json:"end,omitempty"`
}

// notifyQuietHours 是解析好的静默时段:Start / End 是本地时间零点起的分钟数。
type notifyQuietHours struct {
	Enabled    bool
	Start, End int
}

// 缺省 23:00–08:00,开关缺省关。跟 App 侧 NotificationQuietHours.defaultStart / defaultEnd 一致。
const (
	notifyQuietDefaultStart = 23 * 60
	notifyQuietDefaultEnd   = 8 * 60
)

// resolveNotifyQuietHours:段缺失 = 关、默认时刻;时刻写坏了(不是 HH:MM、越界)按默认时刻。
func resolveNotifyQuietHours(f *notifyQuietHoursFile) notifyQuietHours {
	q := notifyQuietHours{Start: notifyQuietDefaultStart, End: notifyQuietDefaultEnd}
	if f == nil {
		return q
	}
	q.Enabled = boolOr(f.Enabled, false)
	if m, ok := parseClockMinutes(f.Start); ok {
		q.Start = m
	}
	if m, ok := parseClockMinutes(f.End); ok {
		q.End = m
	}
	return q
}

// parseClockMinutes 把 "HH:MM"(小时可以是一位)换成零点起的分钟数;多余的字、越界的不认。
func parseClockMinutes(s string) (int, bool) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, false
	}
	return t.Hour()*60 + t.Minute(), true
}

// active:now(本地时间)落在静默时段里没有。区间左闭右开:08:00 那一刻已经不静默。
func (q notifyQuietHours) active(now time.Time) bool {
	if !q.Enabled || q.Start == q.End {
		return false
	}
	m := now.Hour()*60 + now.Minute()
	if q.Start < q.End {
		return m >= q.Start && m < q.End
	}
	return m >= q.Start || m < q.End
}

// endAfter:at 所在那一段静默在什么时刻结束(at 之后最近的一个结束时刻)。只在 active(at) 时有意义。
func (q notifyQuietHours) endAfter(at time.Time) time.Time {
	end := time.Date(at.Year(), at.Month(), at.Day(), q.End/60, q.End%60, 0, 0, at.Location())
	if !end.After(at) {
		end = end.AddDate(0, 0, 1)
	}
	return end
}

// digestQuietHold 是四档报告开头那道闸:这一拍检查已经到期、可正落在静默时段里时返回 true,并记下「被静默压过」
// (*held),调用方直接返回、不记检查时刻。静默一结束,下一拍照样到期去查,推出去的那条在推送记录里标「延后」
// (digestQuietRelease 取走这个标记)。
func digestQuietHold(now time.Time, held *bool) bool {
	if !features().NotificationQuietHours.active(now) {
		return false
	}
	*held = true
	return true
}

// digestQuietRelease:静默之后的头一次检查取走「被静默压过」的标记(取一次就清掉)。这次检查推出去的报告记成延后;
// 这次没推成、过一个间隔再推的不再算延后。
func digestQuietRelease(held *bool) bool {
	deferred := *held
	*held = false
	return deferred
}

// notifyQuietSummary:开关快照日志里那一项,"off" 或 "23:00-08:00"。
func notifyQuietSummary(q notifyQuietHours) string {
	if !q.Enabled {
		return "off"
	}
	return fmt.Sprintf("%02d:%02d-%02d:%02d", q.Start/60, q.Start%60, q.End/60, q.End%60)
}
