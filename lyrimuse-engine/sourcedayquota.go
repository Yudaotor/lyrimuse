package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 歌词源的每日额度。Megalobiz 不带 key 时每个 IP 每天 1000 次,应答头里报这一天还剩几次(X-RateLimit-Remaining-Day)、
// 多少秒后重置(X-RateLimit-Reset-Day,UTC 零点)。见 09 章决策 387。
//   - 剩的不到这个源的留量(描述符的 DayQuotaReserve,lyricSourceDayReserve):只给前台用(正在放的那首、用户手动搜索 / 重新匹配 / 测试),后台(待播队列的预解析)不问(hostGuard.admit)。
//   - 用完(头里报剩 0,或回了 429 且剩 0 / Retry-After 超过熔断封顶):停到重置时刻,前台也不问。经熔断器的 blockedForLocked 生效,
//     一轮里按冷却跳过(原因 lyricSourceSkipReasonBudget),条目的待补搜名单不收它(剩余冷却远超补搜等待)。
//   - 状态存进 sourceDayQuotaFileName,常驻引擎和手动搜索、设置页测试的子进程共用,重启也记得;判之前看到文件变了就重读。
//     单测不开存盘。

const (
	sourceDayQuotaFileName = "lyrimuse-source-day-quota.json"
	// sourceDayQuotaMaxPause:按应答头停最长停多久,头里写了离谱的数也不会把源停上好几天。
	sourceDayQuotaMaxPause = 25 * time.Hour
)

// sourceDayQuotaRecord 是一个源的每日额度状态。时刻都是 unix 秒。
type sourceDayQuotaRecord struct {
	// Remaining / ResetAt:最近一次应答头报的这一天还剩几次、几点重置;SeenAt 是那次应答的时刻。
	Remaining int   `json:"remaining"`
	ResetAt   int64 `json:"reset_at"`
	SeenAt    int64 `json:"seen_at"`
	// PausedUntil:用完了,停到这个时刻。
	PausedUntil int64 `json:"paused_until,omitempty"`
}

var (
	sourceDayQuotaMu    sync.Mutex
	sourceDayQuotaPath  string
	sourceDayQuotaMtime time.Time
	sourceDayQuota      = map[string]sourceDayQuotaRecord{}
)

// useSourceDayQuotaFile:这个进程把每日额度记在 path,并读回已有的。
func useSourceDayQuotaFile(path string) {
	sourceDayQuotaMu.Lock()
	defer sourceDayQuotaMu.Unlock()
	sourceDayQuotaPath = path
	sourceDayQuotaMtime = time.Time{}
	reloadSourceDayQuotaLocked()
}

// reloadSourceDayQuotaLocked:文件在上次读写之后变了就并进来(每个源取更晚看到的那份,停的时刻取更晚的)。持 sourceDayQuotaMu。
func reloadSourceDayQuotaLocked() {
	if sourceDayQuotaPath == "" {
		return
	}
	st, err := os.Stat(sourceDayQuotaPath)
	if err != nil || st.ModTime().Equal(sourceDayQuotaMtime) {
		return
	}
	data, err := os.ReadFile(sourceDayQuotaPath)
	if err != nil {
		noteFileErr("read", sourceDayQuotaPath, err)
		return
	}
	var saved map[string]sourceDayQuotaRecord
	if err := json.Unmarshal(data, &saved); err != nil {
		noteFileErr("decode", sourceDayQuotaPath, err)
		return
	}
	sourceDayQuotaMtime = st.ModTime()
	for src, r := range saved {
		sourceDayQuota[src] = mergedSourceDayQuota(sourceDayQuota[src], r)
	}
}

func mergedSourceDayQuota(a, b sourceDayQuotaRecord) sourceDayQuotaRecord {
	out := a
	if b.SeenAt > a.SeenAt {
		out = b
	}
	out.PausedUntil = max(a.PausedUntil, b.PausedUntil)
	return out
}

// saveSourceDayQuotaLocked:在文件锁里并上盘上那份再写回。持 sourceDayQuotaMu。
func saveSourceDayQuotaLocked() {
	if sourceDayQuotaPath == "" {
		return
	}
	unlock := exclusiveFileLock(sourceDayQuotaPath)
	defer unlock()
	sourceDayQuotaMtime = time.Time{}
	reloadSourceDayQuotaLocked()
	data, err := json.Marshal(sourceDayQuota)
	if err != nil {
		return
	}
	if err := writeFileAtomic(sourceDayQuotaPath, data); err != nil {
		noteFileErr("write", sourceDayQuotaPath, err)
		return
	}
	if st, err := os.Stat(sourceDayQuotaPath); err == nil {
		sourceDayQuotaMtime = st.ModTime()
	}
}

// nextUTCMidnight:now 之后的第一个 UTC 零点。
func nextUTCMidnight(now time.Time) time.Time {
	u := now.UTC()
	return time.Date(u.Year(), u.Month(), u.Day()+1, 0, 0, 0, 0, time.UTC)
}

// headerSeconds:非负整数秒的应答头;没有或写坏了 ok=false。
func headerSeconds(h http.Header, name string) (int, bool) {
	v, err := strconv.Atoi(strings.TrimSpace(h.Get(name)))
	return v, err == nil && v >= 0
}

// noteSourceDayQuota 按一次应答更新 source 的每日额度。不报每日额度的源不记。
func noteSourceDayQuota(source string, status int, h http.Header, now time.Time) {
	if lyricSourceDayReserve(source) <= 0 {
		return
	}
	remaining, hasRemaining := headerSeconds(h, "X-RateLimit-Remaining-Day")
	resetAt := nextUTCMidnight(now)
	if secs, ok := headerSeconds(h, "X-RateLimit-Reset-Day"); ok && time.Duration(secs)*time.Second <= sourceDayQuotaMaxPause {
		resetAt = now.Add(time.Duration(secs) * time.Second)
	}
	retryAfter, hasRetryAfter := headerSeconds(h, "Retry-After")
	exhausted := hasRemaining && remaining == 0
	if status == http.StatusTooManyRequests && !hasRemaining && hasRetryAfter &&
		time.Duration(retryAfter)*time.Second > lyricSourceBreakerRetryAfterMax {
		// 头里没报剩几次、只说要等很久:按它说的停。
		exhausted = true
		resetAt = now.Add(min(time.Duration(retryAfter)*time.Second, sourceDayQuotaMaxPause))
	}
	if !hasRemaining && !exhausted {
		return
	}
	sourceDayQuotaMu.Lock()
	defer sourceDayQuotaMu.Unlock()
	reloadSourceDayQuotaLocked()
	r := sourceDayQuota[source]
	before := r
	if hasRemaining {
		r.Remaining, r.ResetAt, r.SeenAt = remaining, resetAt.Unix(), now.Unix()
	}
	if exhausted && resetAt.Unix() > r.PausedUntil {
		r.PausedUntil = resetAt.Unix()
		slog.Info("lyric source used up its daily quota, pausing it until the reset", "source", source, "until", logClock(resetAt))
	}
	sourceDayQuota[source] = r
	// 剩余次数每个应答都变,只在跨过留量、用完、换了一天时落盘;别的进程看到的剩余略旧不要紧。
	reserve := lyricSourceDayReserve(source)
	if r.PausedUntil != before.PausedUntil || r.ResetAt/3600 != before.ResetAt/3600 ||
		(r.Remaining <= reserve) != (before.Remaining <= reserve) || before.SeenAt == 0 {
		saveSourceDayQuotaLocked()
	}
}

// sourceDayQuotaPausedFor:source 用完了每日额度、还要停多久。
func sourceDayQuotaPausedFor(source string, now time.Time) (time.Duration, bool) {
	if lyricSourceDayReserve(source) <= 0 {
		return 0, false
	}
	sourceDayQuotaMu.Lock()
	defer sourceDayQuotaMu.Unlock()
	reloadSourceDayQuotaLocked()
	until := time.Unix(sourceDayQuota[source].PausedUntil, 0)
	if !until.After(now) {
		return 0, false
	}
	return until.Sub(now), true
}

// sourceDayQuotaLow:source 这一天剩下的不到它的留量(只给前台用)。不知道、或已经过了重置时刻的不算。
func sourceDayQuotaLow(source string, now time.Time) bool {
	reserve := lyricSourceDayReserve(source)
	if reserve <= 0 {
		return false
	}
	sourceDayQuotaMu.Lock()
	defer sourceDayQuotaMu.Unlock()
	reloadSourceDayQuotaLocked()
	r := sourceDayQuota[source]
	return r.SeenAt > 0 && now.Unix() < r.ResetAt && r.Remaining <= reserve
}

// useSharedLyricSourceQuota:常驻引擎和会问歌词源的子命令(手动搜索、设置页测试)共用的额度记账:小时额度(sourcebudget.go)、
// 每日额度。两边读写同一份文件,子进程发的请求一样算进去。
func useSharedLyricSourceQuota() {
	sharedHostGuard().useSourceBudgetFile(configFilePath(clientName + "-source-budget.json"))
	if p := configFilePath(sourceDayQuotaFileName); p != sourceDayQuotaFileName {
		useSourceDayQuotaFile(p)
	}
}
