package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"os"
	"sync"
	"time"
)

// ListenBrainz 令牌被拒:引擎 → App 的状态文件(lyrimuse-lb-status.json),设置页「ListenBrainz」据此报红、App 弹一次
// 系统通知。原来 401 / 403 只记一行日志、停 10 分钟再试,令牌失效多久用户都不知道,待重发队列攒满就开始丢。
// 形制同 lyrimuse-relay-status.json:只在令牌被拒时存在,提交成功一次就删,引擎启动时也删(旧结论说的是上一个进程)。
// App 侧读取在 Core ListenBrainzSubmitStatus,形状两边一起改,样例在 shared/testdata/lb-status/。

// lbStatusSchema:状态文件的版本。App 只认这个版本(ListenBrainzSubmitStatus.currentSchema),别的版本当作没有。
const lbStatusSchema = 1

// lbStatusFile 是状态文件的形状。Kind 目前只有 "auth"(令牌被拒)。
type lbStatusFile struct {
	Schema int    `json:"schema"`
	Kind   string `json:"kind"`
	Status int    `json:"status"`
	Since  int64  `json:"since"` // 第一次被拒的时刻(unix 秒)
}

var (
	lbStatusMu      sync.Mutex
	lbStatusPath    string // 空 = 不落盘(单测、子命令)
	lbStatusWritten bool   // 这个进程写过状态文件、还没删:提交成功时只在写过才去删
	// lbUnsentPath:LB 不收、或待重发队列装不下的收听原样留档(JSON Lines),见 keepUnsentLBListen。
	lbUnsentPath string
	// lbUnsentMu:留档的追加和 refillLBRetryFromUnsent 的读写互斥。跟 lbRetryMu 一起拿时先拿 lbRetryMu。
	lbUnsentMu sync.Mutex
)

// setLBStatusPath 登记状态文件的路径,同时删掉上一次运行留下的那份。
func setLBStatusPath(path string) {
	lbStatusMu.Lock()
	lbStatusPath = path
	lbStatusMu.Unlock()
	clearLBStatus()
}

// noteLBAuthRejected:令牌被拒。已经写过就不动(since 留第一次的)。
func noteLBAuthRejected(status int) {
	lbStatusMu.Lock()
	defer lbStatusMu.Unlock()
	if lbStatusPath == "" || lbStatusWritten {
		return
	}
	data, err := json.Marshal(lbStatusFile{Schema: lbStatusSchema, Kind: "auth", Status: status, Since: time.Now().Unix()})
	if err != nil {
		return
	}
	if writeFileAtomic(lbStatusPath, data) == nil {
		lbStatusWritten = true
	}
}

// noteLBSubmitOK:提交成功过一次,令牌能用,删掉状态文件。
func noteLBSubmitOK() {
	lbStatusMu.Lock()
	written := lbStatusWritten
	lbStatusMu.Unlock()
	if written {
		clearLBStatus()
	}
}

func clearLBStatus() {
	lbStatusMu.Lock()
	path := lbStatusPath
	lbStatusWritten = false
	lbStatusMu.Unlock()
	if path == "" {
		return
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		noteFileErr("remove", path, err)
	}
}

// lbUnsentListen 是留档的一行:当初要提交的那份载荷,和没送出去的原因。
type lbUnsentListen struct {
	ListenedAt int64       `json:"listened_at"`
	Meta       lbTrackMeta `json:"meta"`
	Reason     string      `json:"reason"` // rejected:LB 回 400 / 413;queue_full:待重发队列装不下
	At         int64       `json:"at"`     // 留档的时刻(unix 秒)
}

// keepUnsentLBListen 把一条暂时不会再自动发的收听追加进留档(lyrimuse-lb-unsent.jsonl)。LB 收紧了校验、
// 或令牌长期失效把待重发队列挤满时,原来这些收听就静默没了。队列装不下的那些,等队列空了由 refillLBRetryFromUnsent
// 挪回去自动补交;LB 拒收的留着原样载荷,以后能对照。
func keepUnsentLBListen(listenedAt int64, meta lbTrackMeta, reason string) {
	if lbUnsentPath == "" || listenedAt <= 0 {
		return
	}
	line, err := json.Marshal(lbUnsentListen{ListenedAt: listenedAt, Meta: lbRetryMeta(meta), Reason: reason, At: time.Now().Unix()})
	if err != nil {
		return
	}
	lbUnsentMu.Lock()
	defer lbUnsentMu.Unlock()
	f, err := os.OpenFile(lbUnsentPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		noteFileErr("write", lbUnsentPath, err)
		return
	}
	_, err = f.Write(append(line, '\n'))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	noteFileErr("write", lbUnsentPath, err)
}

// lbRetryRefillBatch:待重发队列空着时,一次从留档挪回去几条。远小于 lbRetryMaxItems:令牌又坏了的话,
// 挪回去的这批留在队列里等下一轮,不会把别的挤出去。
const lbRetryRefillBatch = 200

// refillLBRetryFromUnsent:待重发队列空着时,把留档里因为队列装不下挪出去的收听挪回队列,交给下一轮重发
// (startLBRetryLoop 每轮重发之后调)。队列不空就不动 —— 不空说明还有发不出去的,令牌多半还没好。LB 拒收的留在留档里。
// 返回挪回几条。
func refillLBRetryFromUnsent(max int) int {
	if lbUnsentPath == "" || max <= 0 {
		return 0
	}
	lbRetryMu.Lock()
	defer lbRetryMu.Unlock()
	if len(loadLBRetryLocked()) > 0 {
		return 0
	}
	lbUnsentMu.Lock()
	defer lbUnsentMu.Unlock()
	data, err := os.ReadFile(lbUnsentPath)
	if err != nil {
		noteFileErr("read", lbUnsentPath, err)
		return 0
	}
	var keep [][]byte
	var back []lbRetryItem
	now := time.Now().Unix()
	for _, line := range bytes.Split(data, []byte("\n")) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var l lbUnsentListen
		if len(back) < max && json.Unmarshal(line, &l) == nil && l.Reason == "queue_full" && l.ListenedAt > 0 {
			back = append(back, lbRetryItem{ListenedAt: l.ListenedAt, Meta: l.Meta, QueuedAt: now})
			continue
		}
		keep = append(keep, line)
	}
	if len(back) == 0 {
		return 0
	}
	out := bytes.Join(keep, []byte("\n"))
	if len(keep) > 0 {
		out = append(out, '\n')
	}
	// 先写回留档再进队列:留档写不回就整批不挪,免得同一批下一轮又挪一遍、发两次。
	if err := writeFileAtomic(lbUnsentPath, out); err != nil {
		return 0
	}
	saveLBRetryLocked(back)
	log.Printf("lb retry: moved %d listens back from %s, %d left there", len(back), lbUnsentPath, len(keep))
	return len(back)
}
