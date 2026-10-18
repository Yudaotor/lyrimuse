package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// 推送页的「测一下」和推送记录里的「重发」:App 写一份请求,这里推一次,把结论写进结果文件。
//   - 测一下 {"id","channel":{…}}:往那个渠道推一条示例消息。带的是完整的渠道(编辑表单里还没保存的也能测),
//     所以文件里有密钥:App 以 0600 写,这里一读到就消费掉。渠道停用着也照推:测的就是它填得对不对。
//   - 重发 {"id","resend":"<推送记录 id>"}:把那条没推成的原样(标题、正文、事件)推到同一个渠道,渠道按 id 从
//     此刻的配置里找(改过地址、密钥的用改过的)。
//
// 请求 notifyTestRequestPath,形制同 lyricsrematch.go:盯着目录,一变就看一次(盯不了时每
// notifyTestRequestCheckInterval 看一次)。结果 notifyTestResultPath 留最近 notifyTestResultMax 次,App 按自己发的
// id 找;只留最后一次的话,接连测两个渠道时第二个的结果会在 App 读到之前盖掉第一个。
//
// 两种都记进推送记录(测试的 event 为 test),渠道行的「上次推送」因此一推就更新。

const (
	notifyTestRequestCheckInterval = 500 * time.Millisecond
	notifyTestResultMax            = 10
)

type notifyTestRequest struct {
	ID      string        `json:"id"`
	Channel notifyChannel `json:"channel"`
	Resend  string        `json:"resend,omitempty"`
}

type notifyTestResult struct {
	ID        string `json:"id"`
	OK        bool   `json:"ok"`
	Kind      string `json:"kind"`
	Status    int    `json:"status,omitempty"`
	Code      string `json:"code,omitempty"`
	Detail    string `json:"detail,omitempty"`
	ElapsedMS int64  `json:"elapsed_ms"`
	At        int64  `json:"at"`
}

type notifyTestResultFile struct {
	Results []notifyTestResult `json:"results"` // 旧的在前
}

var (
	notifyTestRequestPath string
	notifyTestResultPath  string
	notifyTestResultMu    sync.Mutex
)

// setNotifyPaths 在 main() 启动时调一次:推送记录、「测一下」的请求和结果。请求和结果是上一个进程的,清掉。
func setNotifyPaths() {
	setNotifyLogPath(configFilePath(clientName + "-notify-log.json"))
	notifyTestRequestPath = configFilePath(clientName + "-notify-test-request.json")
	notifyTestResultPath = configFilePath(clientName + "-notify-test-result.json")
	_ = os.Remove(notifyTestRequestPath)
	_ = os.Remove(notifyTestResultPath)
}

// notifyTestTitle / notifyTestBody:「测一下」推的那条示例消息。
const (
	notifyTestTitle = "🎧 Lyrimuse 推送测试"
	notifyTestBody  = "收到这条说明这个渠道能用了。听歌报告会推到这里。"
)

// startNotifyTestWatcher 由 run() 单开一个 goroutine,ctx 取消时退出。每次推送另起 goroutine(Telegram 走代理
// 回退时一次能到二十来秒),这个循环一直转着收下一份请求。
func startNotifyTestWatcher(ctx context.Context) {
	if notifyTestRequestPath == "" {
		return
	}
	writes, poll := requestWakeups(ctx, filepath.Dir(notifyTestRequestPath), notifyTestRequestCheckInterval)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-writes:
		case <-poll.C:
		}
		data, err := claimRequestFile(notifyTestRequestPath)
		if err != nil {
			continue
		}
		req, ok := parseNotifyTestRequest(data)
		if !ok {
			continue
		}
		go runNotifyTest(req)
	}
}

func parseNotifyTestRequest(data []byte) (notifyTestRequest, bool) {
	var req notifyTestRequest
	if err := json.Unmarshal(data, &req); err != nil || req.ID == "" {
		slog.Warn("notify test: ignoring malformed request", "err", err)
		return notifyTestRequest{}, false
	}
	req.Channel = req.Channel.trimmed()
	return req, true
}

// runNotifyTest 推一次并写结果。
func runNotifyTest(req notifyTestRequest) {
	ch, msg, r, ok := req.Channel, notifyMessage{Event: notifyEventTest, Title: notifyTestTitle, Body: notifyTestBody}, notifyResult{}, true
	if req.Resend != "" {
		ch, msg, r, ok = resendTarget(req.Resend)
	}
	if ok {
		rememberNotifyChannelSecrets(ch)
		r = pushToChannel(ch, msg)
		recordNotifyDelivery(ch, msg, r)
	}
	slog.Info("notify test: done", "resend", req.Resend != "", "platform", ch.Platform, "kind", r.Kind, "status", r.Status, "code", r.Code)
	writeNotifyTestResult(notifyTestResult{ID: req.ID, OK: r.OK, Kind: r.Kind, Status: r.Status, Code: r.Code,
		Detail: r.Detail, ElapsedMS: r.Elapsed.Milliseconds(), At: time.Now().Unix()})
}

// resendTarget:重发那条推送记录要推的渠道和消息。记录或渠道找不到(记录被挤出去了、渠道删了)时 ok 为 false,
// r 是要写回去的结论。
func resendTarget(entryID string) (notifyChannel, notifyMessage, notifyResult, bool) {
	e, found := findNotifyLogEntry(entryID)
	if !found || e.OK {
		return notifyChannel{}, notifyMessage{}, notifyResult{Kind: notifyKindConfig, Detail: "delivery record not found"}, false
	}
	for _, ch := range configNotifyChannels(liveConfig()) {
		if ch.ID == e.Channel {
			return ch, notifyMessage{Event: e.Event, Title: e.Title, Body: e.Body}, notifyResult{}, true
		}
	}
	return notifyChannel{}, notifyMessage{}, notifyResult{Kind: notifyKindConfig, Detail: "channel no longer exists"}, false
}

func writeNotifyTestResult(res notifyTestResult) {
	notifyTestResultMu.Lock()
	defer notifyTestResultMu.Unlock()
	var f notifyTestResultFile
	if b, err := os.ReadFile(notifyTestResultPath); err == nil {
		_ = json.Unmarshal(b, &f)
	} else {
		noteFileErr("read", notifyTestResultPath, err)
	}
	f.Results = append(f.Results, res)
	if n := len(f.Results); n > notifyTestResultMax {
		f.Results = f.Results[n-notifyTestResultMax:]
	}
	b, err := json.Marshal(f)
	if err != nil {
		return
	}
	_ = writeFileAtomic(notifyTestResultPath, b)
}
