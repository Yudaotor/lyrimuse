package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"strconv"
	"sync"
	"time"
)

// 网页推送的健康度:引擎 → App 的状态文件(lyrimuse-relay-status.json),设置页「网页推送」据此报红 / 橙,
// 不再只看地址和令牌填没填。形制同 lyrimuse-lastfm-status.json:只在推不出去时存在,推成功一次就删;
// 引擎启动时、中继地址或令牌改了时也删(旧结论说的是旧配置)。App 侧读取与判定在 Core RelayPushStatus,
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
)

// relayStatusFile 是状态文件的形状。Swift 侧 RelayPushStatus.Info 按同一个形状读。
type relayStatusFile struct {
	Schema int    `json:"schema"`
	Kind   string `json:"kind"`
	Status int    `json:"status,omitempty"` // HTTP 状态码;没拿到响应时省略
	Since  int64  `json:"since"`            // 这一串失败从什么时候开始(unix 秒)
}

var (
	relayStatusMu   sync.Mutex
	relayStatusPath string // 空 = 不落盘(单测、子命令)
)

// setRelayStatusPath 登记状态文件的路径,同时删掉上一次运行留下的那份:它说的是上一个进程的推送。
func setRelayStatusPath(path string) {
	relayStatusMu.Lock()
	relayStatusPath = path
	relayStatusMu.Unlock()
	clearRelayStatus()
}

// relayHTTPError:中继回了非 200。状态码决定这次失败归哪一类,见 relayFailureKind。
type relayHTTPError struct {
	path   string
	status int
}

func (e *relayHTTPError) Error() string {
	return "relay " + e.path + ": status " + strconv.Itoa(e.status)
}

// relayFailureKind 把一次推送失败归类(见上面那组常量)。
func relayFailureKind(err error) (kind string, status int) {
	var he *relayHTTPError
	if !errors.As(err, &he) {
		return relayFailNetwork, 0
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
// 主动取消(引擎退出)不算失败。
func (p *poller) noteRelayFailure(err error, at time.Time) {
	if errors.Is(err, context.Canceled) {
		return
	}
	kind, status := relayFailureKind(err)
	if p.relayFailingSince.IsZero() {
		p.relayFailingSince = at
	}
	key := kind + "|" + strconv.Itoa(status)
	if key == p.relayStatusKey {
		return
	}
	p.relayStatusKey = key
	writeRelayStatus(relayStatusFile{Schema: relayStatusSchema, Kind: kind, Status: status, Since: p.relayFailingSince.Unix()})
}

// noteRelaySuccess:推成功了,之前报过的失败撤掉。
func (p *poller) noteRelaySuccess() {
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
	clearRelayStatus()
}
