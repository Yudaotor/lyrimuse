package main

import (
	"fmt"
	"log/slog"
	"os"
	"strings"
	"syscall"
	"time"
)

// 四档听歌报告什么时候推:推送提醒页「推送时间」(features.json 的 digest_push_time,"HH:MM",缺省 22:00),四档共用。
// 时刻按这台 Mac 当前的时区算,换了时区引擎重启、跟着变(localZoneChanged)。
//   - 每日:推送时间在 digestPushSameDayFrom(12:00)及以后,推当天零点到推送那一刻;在那之前(早上推),推前一天一整天。
//     到点那次没推成(合盖、断网、推送失败)的,到下一个推送时间之前随时补推,补的是那一天一整天。
//   - 每周 / 每月 / 年度:周期结束之后的第一个推送时间推(月报每月 1 日、年报 1 月 1 日;周报看数据源,Last.fm 图表周
//     周日结束、ListenBrainz 周一零点结束);停机错过了照旧补推最近一期。
// 见 15 章决策 77。

const (
	defaultDigestPushMinutes = 22 * 60
	digestPushSameDayFrom    = 12 * 60
)

// digestClock 是解析好的推送时间:零点起的分钟数。set=false 表示没设过(单测直接拼的 featureFlags 也是这样),按缺省。
type digestClock struct {
	minutes int
	set     bool
}

// resolveDigestPushTime:写坏了(不是 HH:MM、越界)按没设过。
func resolveDigestPushTime(s string) digestClock {
	if m, ok := parseClockMinutes(s); ok {
		return digestClock{minutes: m, set: true}
	}
	return digestClock{}
}

// parseClockMinutes 把 "HH:MM"(小时可以是一位)换成零点起的分钟数;多余的字、越界的不认。
func parseClockMinutes(s string) (int, bool) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, false
	}
	return t.Hour()*60 + t.Minute(), true
}

func digestPushMinutes() int {
	if c := features().DigestPushTime; c.set {
		return c.minutes
	}
	return defaultDigestPushMinutes
}

func clockText(minutes int) string { return fmt.Sprintf("%02d:%02d", minutes/60, minutes%60) }

func midnightOf(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, t.Location())
}

// digestPushAt:day 那一天的推送时刻(day 的时区)。
func digestPushAt(day time.Time, minutes int) time.Time {
	return time.Date(day.Year(), day.Month(), day.Day(), minutes/60, minutes%60, 0, 0, day.Location())
}

// firstDigestPushAtOrAfter:t 之后(含)的第一个推送时刻 —— 周期在 t 结束,到这一刻推。
func firstDigestPushAtOrAfter(t time.Time, minutes int) time.Time {
	p := digestPushAt(t, minutes)
	if p.Before(t) {
		p = digestPushAt(midnightOf(t).AddDate(0, 0, 1), minutes)
	}
	return p
}

// digestDue:这一拍要不要检查。满了各自的检查间隔要查;另外上次检查在今天的推送时刻之前、现在已经过了它,也立刻查 ——
// 不然推送时间 22:00、上次 21:50 查过,要等到 23:50 才轮到。
func digestDue(now, last time.Time, interval time.Duration) bool {
	if digestCheckDue(now, last, interval) {
		return true
	}
	p := digestPushAt(midnightOf(now), digestPushMinutes())
	return last.Before(p) && !now.Before(p)
}

// dailyDigestTarget 判这一次检查该推哪一期日报:最近一个已经到了的推送时刻对应的那一天。day 是该期的本地日期(YYYY-MM-DD),
// 跟 dailyDigestState 里记的比;[from, to) 是取数区间 —— 那一天还没过完就到现在为止,过完了就是一整天。
func dailyDigestTarget(now time.Time, minutes int) (day string, from, to time.Time, title string) {
	today := midnightOf(now)
	push := digestPushAt(today, minutes)
	if now.Before(push) {
		push = digestPushAt(today.AddDate(0, 0, -1), minutes)
	}
	from = midnightOf(push)
	if minutes < digestPushSameDayFrom {
		from = from.AddDate(0, 0, -1)
	}
	to = from.AddDate(0, 0, 1)
	if now.Before(to) {
		to = now
	}
	switch {
	case from.Equal(today):
		title = fmt.Sprintf("🎧 今日听歌报告（%s）", from.Format("01-02"))
	case from.Equal(today.AddDate(0, 0, -1)):
		title = fmt.Sprintf("🎧 昨日听歌报告（%s）", from.Format("01-02"))
	default:
		title = fmt.Sprintf("🎧 听歌报告（%s）", from.Format("01-02"))
	}
	return from.Format(time.DateOnly), from, to, title
}

// ---- 时区 ----

var (
	// localZoneLink:系统时区设置(/etc/localtime,指向 zoneinfo 下的一个时区文件)。单测置空,不看。
	localZoneLink = "/etc/localtime"
	// localZoneName:这个进程第一次看到的系统时区。
	localZoneName string
	// restartForZoneChange:时区换了以后让引擎按新时区重来 —— 给自己发 SIGTERM,走跟 launchctl kickstart -k 一样的收尾,
	// launchd(KeepAlive)再把引擎拉起来。单测换掉。
	restartForZoneChange = func() { _ = syscall.Kill(os.Getpid(), syscall.SIGTERM) }
)

// localZoneChanged:Go 在进程启动时读一次系统时区存进 time.Local,之后不再跟;time.Local 又不能在别的 goroutine
// 读着的时候改(主循环、各个后台任务一直在用本地时间)。常驻引擎一跑几个月,用户换了时区(出差、手动改)之后推送时间、
// 报告里的日期都还按旧时区算,所以每轮报告检查前看一眼系统时区换没换:换了就重启引擎(restartForZoneChange),
// 新进程按新时区读。返回 true 表示要重启了,这一轮别往下跑。只在报告那个 goroutine 里调。
func localZoneChanged() bool {
	if localZoneLink == "" {
		return false
	}
	target, err := os.Readlink(localZoneLink)
	if err != nil {
		return false
	}
	i := strings.Index(target, "zoneinfo/")
	if i < 0 {
		return false
	}
	name := target[i+len("zoneinfo/"):]
	if localZoneName == "" {
		localZoneName = name
		return false
	}
	if name == localZoneName {
		return false
	}
	slog.Info("time zone changed, restarting so digest push times follow it", "from", localZoneName, "to", name)
	localZoneName = name
	restartForZoneChange()
	return true
}
