package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"sync"
	"time"
)

// 推送记录 lyrimuse-notify-log.json:每往一个渠道推一次(报告、里程碑、「测一下」)记一条,留最近
// notifyLogMax 条。App 的推送页从这里读每个渠道最近一次推送成没成、没成是哪一类原因,以及完整的推送记录。
// 跨重启保留(不像 relay-status 那样启动时清掉):用户打开推送页想看的就是「上周的周报发出去没有」。
//
// 成功的只记标题;没推成的连正文一起记,推送页的「重发」照原样再推一次(notifytest.go)。正文就是听歌统计,
// 跟配置目录里别的缓存同一个密级。平台的原话截短并去掉密钥(notifyDetail)。

const (
	notifyLogSchema = 1
	notifyLogMax    = 100
)

type notifyLogEntry struct {
	ID          string `json:"id"`
	At          int64  `json:"at"` // unix 秒
	Channel     string `json:"channel"`
	ChannelName string `json:"channel_name,omitempty"`
	Platform    string `json:"platform"`
	Event       string `json:"event,omitempty"`
	Title       string `json:"title,omitempty"`
	Body        string `json:"body,omitempty"` // 只有没推成的才记
	OK          bool   `json:"ok"`
	Kind        string `json:"kind"`
	Status      int    `json:"status,omitempty"`
	Code        string `json:"code,omitempty"`
	Detail      string `json:"detail,omitempty"`
	ElapsedMS   int64  `json:"elapsed_ms"`
}

type notifyLogFile struct {
	Schema  int              `json:"schema"`
	Entries []notifyLogEntry `json:"entries"` // 旧的在前
}

var (
	notifyLogMu   sync.Mutex
	notifyLogPath string // 空 = 不落盘(单测、子命令)
)

func setNotifyLogPath(path string) {
	notifyLogMu.Lock()
	notifyLogPath = path
	notifyLogMu.Unlock()
}

// recordNotifyDelivery 记一条推送。
func recordNotifyDelivery(ch notifyChannel, msg notifyMessage, r notifyResult) {
	notifyLogMu.Lock()
	defer notifyLogMu.Unlock()
	if notifyLogPath == "" {
		return
	}
	f := readNotifyLog(notifyLogPath)
	e := notifyLogEntry{
		ID: newNotifyLogID(), At: time.Now().Unix(), Channel: ch.ID, ChannelName: ch.Name, Platform: ch.Platform,
		Event: msg.Event, Title: msg.Title, OK: r.OK, Kind: r.Kind, Status: r.Status, Code: r.Code,
		Detail: r.Detail, ElapsedMS: r.Elapsed.Milliseconds(),
	}
	if !r.OK {
		e.Body = msg.Body
	}
	f.Entries = append(f.Entries, e)
	if n := len(f.Entries); n > notifyLogMax {
		f.Entries = f.Entries[n-notifyLogMax:]
	}
	f.Schema = notifyLogSchema
	b, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return
	}
	_ = writeFileAtomic(notifyLogPath, b)
}

// findNotifyLogEntry 按 id 找一条推送记录。
func findNotifyLogEntry(id string) (notifyLogEntry, bool) {
	notifyLogMu.Lock()
	defer notifyLogMu.Unlock()
	if notifyLogPath == "" {
		return notifyLogEntry{}, false
	}
	for _, e := range readNotifyLog(notifyLogPath).Entries {
		if e.ID == id {
			return e, true
		}
	}
	return notifyLogEntry{}, false
}

func newNotifyLogID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// readNotifyLog 读推送记录;不存在或坏了就从空的开始(记录丢了不影响推送)。
func readNotifyLog(path string) notifyLogFile {
	var f notifyLogFile
	b, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return f
	}
	if err := json.Unmarshal(b, &f); err != nil {
		noteFileErr("decode", path, err)
		return notifyLogFile{}
	}
	return f
}
