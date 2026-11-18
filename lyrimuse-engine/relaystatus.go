package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"log/slog"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// 网页推送的健康度:引擎 → App 的状态文件(lyrimuse-relay-status.json),设置页「网页推送」据此报红 / 橙,
// 不再只看地址和令牌填没填。形制同 lyrimuse-lastfm-status.json:只在推不出去时存在,推成功一次就删;
// 引擎启动时、中继地址或令牌改了时也删(旧结论说的是旧配置)。例外是「KV 写额度用完」:它带着停推的截止时刻,
// 没到期时启动不删,引擎读回来接着停(见 restoreRelayQuotaPause)。App 侧读取与判定在 Core RelayPushStatus,
// 形状两边一起改,样例在 shared/testdata/relay-status/。

// relayStatusSchema:状态文件的版本。App 只认这个版本(RelayPushStatus.currentSchema),别的版本当作没有。
const relayStatusSchema = 1

// 推送失败的几类。前三类是配置错,App 一看到就报红;后两类会自己好,持续一阵才报橙。
const (
	relayFailAuth     = "auth"      // 401 / 403:令牌不对
	relayFailNotFound = "not_found" // 404 / 405:地址不对,那边没有推送接口
	relayFailRejected = "rejected"  // 其余 4xx
	relayFailServer   = "server"    // 408 / 429 / 5xx:中继自己暂时出错或限流
	relayFailNetwork  = "network"   // 没拿到响应:连不上、超时
	relayFailQuota    = "quota"     // 503 且响应体说 KV 写额度用完:停推到 until(relayQuotaResumeAt)
)

// relayQuotaResetSlack:KV 写额度在 UTC 0 点重置。0 点之后这么久以内又报额度用完,按「本机时钟比中继快、
// 重置还没生效」处理,只停 relayBackoffMax 再试,不再停到下一个 0 点。
const relayQuotaResetSlack = time.Hour

// relayQuotaExhausted:中继这次回的是不是「KV 写额度用完」。中继(state-worker)在 kv.put 抛错时回 503,
// 响应体 {"error":"kv write failed (quota?)","detail":"<KV 的原话>"};只有原话里也说了 limit(KV 报的是
// 「KV put() limit exceeded for the day」)才算,同一个 key 写得太快之类别的写入失败照普通 503 退避。见 13 章决策 17。
func relayQuotaExhausted(status int, body []byte) bool {
	if status != 503 {
		return false
	}
	b := bytes.ToLower(body)
	return bytes.Contains(b, []byte("quota")) && bytes.Contains(b, []byte("limit"))
}

// relayQuotaResumeAt:at 那一刻报了额度用完,停推到什么时候:下一个 UTC 0 点。at 落在 0 点之后
// relayQuotaResetSlack 以内时只停 relayBackoffMax。
func relayQuotaResumeAt(at time.Time) time.Time {
	u := at.UTC()
	midnight := time.Date(u.Year(), u.Month(), u.Day(), 0, 0, 0, 0, time.UTC)
	if u.Sub(midnight) < relayQuotaResetSlack {
		return at.Add(relayBackoffMax)
	}
	return midnight.Add(24 * time.Hour)
}

// relayQuotaPauseUntil:额度用完、停推到这一刻(unix 纳秒,0 = 没停)。主循环写,封面托管的上传 goroutine 读:
// 停推期间封面也不传,传上去同样是一次 KV 写、只会失败。
var relayQuotaPauseUntil atomic.Int64

func setRelayQuotaPause(until time.Time) {
	if until.IsZero() {
		relayQuotaPauseUntil.Store(0)
		return
	}
	relayQuotaPauseUntil.Store(until.UnixNano())
}

func relayQuotaPaused(now time.Time) bool {
	until := relayQuotaPauseUntil.Load()
	return until != 0 && now.UnixNano() < until
}

// relayStatusFile 是状态文件的形状。Swift 侧 RelayPushStatus.Info 按同一个形状读。
type relayStatusFile struct {
	Schema int    `json:"schema"`
	Kind   string `json:"kind"`
	Status int    `json:"status,omitempty"` // HTTP 状态码;没拿到响应时省略
	Since  int64  `json:"since"`            // 这一串失败从什么时候开始(unix 秒)
	Until  int64  `json:"until,omitempty"`  // 只有 quota:停推到什么时候(unix 秒)
}

// key:同一类失败只写一次的比对口径。额度用完带上截止时刻,第二天又用完时重写。
func (f relayStatusFile) key() string {
	return f.Kind + "|" + strconv.Itoa(f.Status) + "|" + strconv.FormatInt(f.Until, 10)
}

var (
	relayStatusMu   sync.Mutex
	relayStatusPath string // 空 = 不落盘(单测、子命令)
	// relayQuotaCarried:登记路径时读到的、还没到期的「额度用完」,run() 里交给 poller(restoreRelayQuotaPause)。
	relayQuotaCarried relayStatusFile
)

// setRelayStatusPath 登记状态文件的路径,同时删掉上一次运行留下的那份:它说的是上一个进程的推送。
// 没到期的「额度用完」留着,记进 relayQuotaCarried。
func setRelayStatusPath(path string) {
	setRelayStatusPathAt(path, time.Now())
}

func setRelayStatusPathAt(path string, now time.Time) {
	relayStatusMu.Lock()
	relayStatusPath = path
	relayQuotaCarried = relayStatusFile{}
	if data, err := os.ReadFile(path); err == nil {
		var f relayStatusFile
		if json.Unmarshal(data, &f) == nil && f.Schema == relayStatusSchema && f.Kind == relayFailQuota && now.Unix() < f.Until {
			relayQuotaCarried = f
		}
	}
	carried := relayQuotaCarried.Kind != ""
	relayStatusMu.Unlock()
	if !carried {
		clearRelayStatus()
	}
}

// restoreRelayQuotaPause:上一个进程报的额度用完还没到期,接着停推到那一刻;设置页那条状态不重写。
func (p *poller) restoreRelayQuotaPause(now time.Time) {
	relayStatusMu.Lock()
	f := relayQuotaCarried
	relayQuotaCarried = relayStatusFile{}
	relayStatusMu.Unlock()
	if f.Kind != relayFailQuota || now.Unix() >= f.Until {
		return
	}
	p.relayQuotaUntil = time.Unix(f.Until, 0)
	p.relayFailingSince = time.Unix(f.Since, 0)
	p.relayStatusKey = f.key()
	setRelayQuotaPause(p.relayQuotaUntil)
	log.Printf("relay push: daily KV write quota still exhausted, paused until %s", p.relayQuotaUntil.UTC().Format(time.RFC3339))
}

// relayHTTPError:中继回了非 200。状态码决定这次失败归哪一类,见 relayFailureKind;quota 是响应体说 KV 写额度用完
// (relayQuotaExhausted)。
type relayHTTPError struct {
	path   string
	status int
	quota  bool
}

func (e *relayHTTPError) Error() string {
	msg := "relay " + e.path + ": status " + strconv.Itoa(e.status)
	if e.quota {
		msg += " (daily KV write quota exhausted)"
	}
	return msg
}

// relayFailureKind 把一次推送失败归类(见上面那组常量)。
func relayFailureKind(err error) (kind string, status int) {
	var he *relayHTTPError
	if !errors.As(err, &he) {
		return relayFailNetwork, 0
	}
	if he.quota {
		return relayFailQuota, he.status
	}
	switch s := he.status; {
	case s == 401 || s == 403:
		return relayFailAuth, s
	case s == 404 || s == 405:
		return relayFailNotFound, s
	case s == 408 || s == 429 || s >= 500:
		return relayFailServer, s
	default:
		return relayFailRejected, s
	}
}

func writeRelayStatus(f relayStatusFile) {
	relayStatusMu.Lock()
	defer relayStatusMu.Unlock()
	if relayStatusPath == "" {
		return
	}
	data, err := json.Marshal(f)
	if err != nil {
		return
	}
	if err := writeFileAtomic(relayStatusPath, data); err != nil {
		slog.Error("relay status: write failed", "err", err)
	}
}

func clearRelayStatus() {
	relayStatusMu.Lock()
	defer relayStatusMu.Unlock()
	if relayStatusPath == "" {
		return
	}
	if err := os.Remove(relayStatusPath); err != nil && !os.IsNotExist(err) {
		warnf("relay status: clear failed: %v", err)
	}
}

// noteRelayFailure:一次推送没推出去,报给设置页。同一类失败只写一次,since 记的是这一串失败的头一次。
// 额度用完时先停推到下一个 UTC 0 点(relayQuotaUntil),截止时刻一起写进去。主动取消(引擎退出)不算失败。
func (p *poller) noteRelayFailure(err error, at time.Time) {
	if errors.Is(err, context.Canceled) {
		return
	}
	kind, status := relayFailureKind(err)
	if p.relayFailingSince.IsZero() {
		p.relayFailingSince = at
	}
	f := relayStatusFile{Schema: relayStatusSchema, Kind: kind, Status: status, Since: p.relayFailingSince.Unix()}
	if kind == relayFailQuota {
		p.relayQuotaUntil = relayQuotaResumeAt(at)
		setRelayQuotaPause(p.relayQuotaUntil)
		f.Until = p.relayQuotaUntil.Unix()
		warnf("relay push paused: daily KV write quota exhausted, resuming at %s", p.relayQuotaUntil.UTC().Format(time.RFC3339))
	}
	if f.key() == p.relayStatusKey {
		return
	}
	p.relayStatusKey = f.key()
	writeRelayStatus(f)
}

// relayQuotaHit:后台任务(Top10 歌手推送)写中继时认出额度用完,交回主循环按同一套停推(takeRelayQuotaHit)。
type relayQuotaHit struct {
	err error
	at  time.Time
}

// noteRelayQuotaHit:后台任务写中继失败时调。只收额度用完这一种,别的失败各自重试、不影响网页推送的退避。
func (p *poller) noteRelayQuotaHit(err error, at time.Time) {
	if kind, _ := relayFailureKind(err); kind == relayFailQuota {
		p.relayQuotaHitPending.Store(&relayQuotaHit{err: err, at: at})
	}
}

// relayQuotaPausedOrHit:停推中,或者后台已经撞上额度用完、主循环还没接手。后台任务开写之前问它。
func (p *poller) relayQuotaPausedOrHit(now time.Time) bool {
	return relayQuotaPaused(now) || p.relayQuotaHitPending.Load() != nil
}

// takeRelayQuotaHit:主循环接手后台报来的额度用完,跟 /push 自己撞上一样停推、写状态。
func (p *poller) takeRelayQuotaHit() {
	if h := p.relayQuotaHitPending.Swap(nil); h != nil && !h.at.Before(p.relayQuotaUntil) {
		p.noteRelayFailure(h.err, h.at)
	}
}

// noteRelaySuccess:推成功了,之前报过的失败撤掉。
func (p *poller) noteRelaySuccess() {
	if !p.relayQuotaUntil.IsZero() {
		p.relayQuotaUntil = time.Time{}
		setRelayQuotaPause(time.Time{})
	}
	if p.relayFailingSince.IsZero() && p.relayStatusKey == "" {
		return
	}
	p.relayFailingSince, p.relayStatusKey = time.Time{}, ""
	clearRelayStatus()
}

// resetRelayPush:中继地址或令牌改了。去重锚点和退避清零,下一拍就按新配置推一次,设置页很快看到新结论;
// 旧结论删掉;在飞的那次推送回来时按 relayGen 认出是旧配置的,不记账。
func (p *poller) resetRelayPush() {
	p.relayGen++
	p.relayLastState, p.relayLastAt, p.relayStateSince = "", time.Time{}, time.Time{}
	p.relayFailKey, p.relayFailAt, p.relayBackoff = "", time.Time{}, 0
	p.relayDeferKey, p.relayDeferSince = "", time.Time{}
	p.relayFailingSince, p.relayStatusKey = time.Time{}, ""
	p.relayQuotaUntil, p.relayReanchorPending = time.Time{}, false
	p.relayQuotaHitPending.Store(nil)
	setRelayQuotaPause(time.Time{})
	clearRelayStatus()
}
