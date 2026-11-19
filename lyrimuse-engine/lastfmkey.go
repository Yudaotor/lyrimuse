package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	neturl "net/url"
	"os"
	"regexp"
	"sync/atomic"
	"time"
)

// ---- Last.fm 错误归类:「key 被拒」和「授权失效」分开 ----
//
// Last.fm 只接受订阅了 Last.fm Pro 的账号持有的 API key,没订的 key 所有方法都被拒,重新连接没用;
// 授权失效(session key 被撤销)则是重新连接就好。两者给用户的出路不同,状态文件带上归类结果(reason),App 按它出文案。
// 判据和 App 侧 LastfmErrorClassifier(LyrimuseCore)逐条一致,改一边必须同步改另一边(契约测试见 lastfmkey_test.go)。
// 背景与取舍见 12 章决策 100。

type lastfmErrClass int

const (
	lastfmErrOther lastfmErrClass = iota
	// lastfmErrSessionInvalid:4 / 9,重新连接能恢复。4 要两击坐实(shouldDisable)。
	lastfmErrSessionInvalid
	// lastfmErrKeyRejected:10 / 26、message 提到 Pro / 订阅、或认不出的 403。重新连接用的还是同一把 key,没用。
	lastfmErrKeyRejected
)

// lastfmKnownErrorCodes:Last.fm 官方错误表(https://www.last.fm/api/errorcodes)列出的码,1 和 19 写着不存在、表里没有 28。
// 403 带着这之外的码(或者干脆没有码)算「认不出的 403」。14(token 还没授权)实测就配 403,漏了会被报成要 Pro(12 章决策 100)。
var lastfmKnownErrorCodes = []int{2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 21, 22, 23, 24, 25, 26, 27, 29}

// lastfmProMessagePattern:message 里提到 Pro 或订阅就算 key 被拒,不管带的是哪个码。
const lastfmProMessagePattern = `(?i)\bpro\b|subscri`

var lastfmProMessageRe = regexp.MustCompile(lastfmProMessagePattern)

// classifyLastfmError 按 HTTP 状态、error 码、message 归类。顺序:message 提到 Pro → 10 / 26 → 4 / 9 → 认不出的 403。
func classifyLastfmError(status, code int, message string) lastfmErrClass {
	if lastfmProMessageRe.MatchString(message) {
		return lastfmErrKeyRejected
	}
	switch code {
	case 10, 26:
		return lastfmErrKeyRejected
	case 4, 9:
		return lastfmErrSessionInvalid
	}
	if status == http.StatusForbidden && !lastfmKnownErrorCode(code) {
		return lastfmErrKeyRejected
	}
	return lastfmErrOther
}

func lastfmKnownErrorCode(code int) bool {
	for _, c := range lastfmKnownErrorCodes {
		if c == code {
			return true
		}
	}
	return false
}

// lastfmResponseError 把一次应答里的错误转成 error:有 error 码的一律是 *lastfmAPIError(带 HTTP 状态);没有码、
// 状态不是 200 时,归得进「key 被拒」的也是 *lastfmAPIError(Code 0,message 是应答体摘要),其余是普通错误。
// 200 且没有码返回 nil。写入、读取、回填三条路径共用,别各判一套。
func lastfmResponseError(method string, status, code int, message, contentType string, body []byte) error {
	if code != 0 {
		return &lastfmAPIError{Code: code, Message: message, Method: method, Status: status}
	}
	if status == http.StatusOK {
		return nil
	}
	summary := httpErrorBody(contentType, body)
	if classifyLastfmError(status, 0, summary) == lastfmErrKeyRejected {
		return &lastfmAPIError{Message: summary, Method: method, Status: status}
	}
	return fmt.Errorf("lastfm %s: status %d: %s", method, status, summary)
}

// ---- 状态文件归谁 ----
//
// lyrimuse-lastfm-status.json 有两个写入方:写入器熔断(writeLastfmMirrorStatus,任何凭据错误),读取路径撞上 key 被拒
// (noteLastfmKeyRejected),文件里的 by 记是谁写的。读取成功只撤读取路径写的那份,不撤写入器的(上次运行留下的也一样):
// 读得通不等于写得进,写入器的熔断由它自己的探测(reviveIfKeyAccepted)和下一次写入成功解除。写入器没开(镜像关着)时
// 没有谁会再写成功,那份由读取成功撤。

const (
	lastfmStatusNone int32 = iota
	lastfmStatusByRead
	lastfmStatusByWriter
)

var lastfmStatusOwner atomic.Int32

// lastfmStaleStatusChecked:本进程查过上次运行留下的状态文件没有(只查一次,之后读取成功不再读文件)。
var lastfmStaleStatusChecked atomic.Bool

// lastfmKeyRejectedAt:本进程最近一次落盘的 key 被拒用的 at(Unix 秒,0 = 没有)。状态文件被另一条路径的成功撤掉后
// 再撞上被拒,沿用它而不换新的 at:App 按 at 判要不要再弹通知,读写两路结论不一致时不能每首歌弹一次。
// lastfmReadKeyRejected / lastfmWriteKeyRejected:两条路径最近一次的结论是不是 key 被拒,两路都不是了才忘掉这个 at。
var (
	lastfmKeyRejectedAt    atomic.Int64
	lastfmReadKeyRejected  atomic.Bool
	lastfmWriteKeyRejected atomic.Bool
)

// forgetLastfmKeyRejectedAtIfClear:读写两路都没有在被拒,下一次被拒就是新的一次,换新的 at。
func forgetLastfmKeyRejectedAtIfClear() {
	if !lastfmReadKeyRejected.Load() && !lastfmWriteKeyRejected.Load() {
		lastfmKeyRejectedAt.Store(0)
	}
}

// lastfmStatusClock:状态文件 at 取的时刻,测试换成可控的钟。
var lastfmStatusClock = time.Now

// lastfmWriterOff:镜像写入关着,写入器留下的状态文件不会再等到写入成功。
func lastfmWriterOff() bool { return !features().LastfmMirrorScrobble }

// noteLastfmKeyRejected:读取路径撞上 key 被拒。状态文件还没人写过才写(写入器的熔断优先),同一次被拒只记一条日志。
func noteLastfmKeyRejected(apiErr *lastfmAPIError) {
	if apiErr == nil || apiErr.class() != lastfmErrKeyRejected {
		return
	}
	lastfmReadKeyRejected.Store(true)
	if !lastfmStatusOwner.CompareAndSwap(lastfmStatusNone, lastfmStatusByRead) {
		return
	}
	warnf("lastfm: API key rejected on a read (http %d, error %d): %s - Last.fm requires the key owner to subscribe to Last.fm Pro",
		apiErr.Status, apiErr.Code, apiErr.Message)
	writeLastfmMirrorStatus(apiErr, lastfmStatusByReadTag)
}

// noteLastfmReadOK:读取成功。状态文件是读取路径写的(或者是上次运行读取路径留下的 key 被拒)就撤掉;
// 写入器写的只在镜像写入关着时撤。
func noteLastfmReadOK() {
	lastfmReadKeyRejected.Store(false)
	forgetLastfmKeyRejectedAtIfClear()
	switch lastfmStatusOwner.Load() {
	case lastfmStatusByWriter:
		if lastfmWriterOff() && lastfmStatusOwner.CompareAndSwap(lastfmStatusByWriter, lastfmStatusNone) {
			removeLastfmStatusFile()
		}
		return
	case lastfmStatusByRead:
		if lastfmStatusOwner.CompareAndSwap(lastfmStatusByRead, lastfmStatusNone) {
			removeLastfmStatusFile()
		}
		return
	}
	if lastfmStatusPath == "" || !lastfmStaleStatusChecked.CompareAndSwap(false, true) {
		return
	}
	st, ok := readLastfmStatusFile()
	if !ok || st.Reason != lastfmReasonKeyRejected || (st.By == lastfmStatusByWriterTag && !lastfmWriterOff()) {
		return
	}
	if lastfmStatusOwner.Load() == lastfmStatusNone {
		removeLastfmStatusFile()
	}
}

// noteLastfmWriteOK:写入成功,key 和授权都没问题,谁写的状态文件都撤。
func noteLastfmWriteOK() {
	lastfmWriteKeyRejected.Store(false)
	forgetLastfmKeyRejectedAtIfClear()
	if lastfmStatusOwner.Swap(lastfmStatusNone) != lastfmStatusNone {
		removeLastfmStatusFile()
	}
}

func removeLastfmStatusFile() {
	if lastfmStatusPath == "" {
		return
	}
	if err := os.Remove(lastfmStatusPath); err != nil && !os.IsNotExist(err) {
		slog.Warn("lastfm: remove status file failed", "err", err)
	}
}

const (
	lastfmReasonKeyRejected = "key_rejected"
	lastfmReasonSession     = "session"
)

// 状态文件 by 字段:谁写的。没有 by 的(这个字段之前写的)按读取路径处理。
const (
	lastfmStatusByReadTag   = "read"
	lastfmStatusByWriterTag = "writer"
)

// lastfmStatusFile 是 lyrimuse-lastfm-status.json 的内容,App 侧 LastfmMirrorStatus.Info 读。
type lastfmStatusFile struct {
	Error   int    `json:"error"`
	Message string `json:"message"`
	Method  string `json:"method"`
	At      int64  `json:"at"`
	Reason  string `json:"reason,omitempty"`
	Status  int    `json:"status,omitempty"`
	By      string `json:"by,omitempty"`
}

func readLastfmStatusFile() (lastfmStatusFile, bool) {
	var st lastfmStatusFile
	data, err := os.ReadFile(lastfmStatusPath)
	if err != nil || json.Unmarshal(data, &st) != nil {
		return st, false
	}
	return st, true
}

// ---- 写入器熔断后的恢复(只限 key 被拒)----

// lastfmKeyProbeInterval:写入器因 key 被拒熔断后,多久用只读请求探一次 key 有没有恢复(用户订了 Pro)。
var lastfmKeyProbeInterval = 15 * time.Minute

// reviveIfKeyAccepted 在重发循环里调:写入器因 key 被拒熔断、距上次探测够久,就用这把 key 发一次 user.getInfo;
// 被接受就解除熔断(dead 复位),返回 true,调用方接着重发队列。状态文件不在这里撤:等真正写进去一条再撤
// (noteLastfmWriteOK),读得通写不进时不会撤了又写、反复弹通知。授权失效(4 / 9)的熔断不探,只能重新连接。
func (s *lastfmScrobbler) reviveIfKeyAccepted(ctx context.Context, now time.Time, probe func(context.Context, string, string) error) bool {
	if !s.dead.Load() || !s.deadKeyRejected.Load() {
		return false
	}
	last := s.lastKeyProbe.Load()
	if last != 0 && now.Sub(time.Unix(0, last)) < lastfmKeyProbeInterval {
		return false
	}
	s.lastKeyProbe.Store(now.UnixNano())
	err := probe(ctx, s.user, s.apiKey)
	if err != nil {
		slog.Info("lastfm: API key still rejected, scrobbling stays paused", "err", err)
		return false
	}
	s.deadKeyRejected.Store(false)
	s.dead.Store(false)
	warnf("lastfm: API key accepted again, resuming scrobbling and the retry queue")
	return true
}

// probeLastfmKey 是 reviveIfKeyAccepted 默认用的探测:不签名的 user.getInfo,只看 key 收不收。
func probeLastfmKey(ctx context.Context, user, apiKey string) error {
	var out json.RawMessage
	return lastfmAPIGet(ctx, neturl.Values{"method": {"user.getInfo"}, "user": {user}, "api_key": {apiKey}}, &out)
}
