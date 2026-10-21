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
// 每条都连正文一起记:推送页点开一条看推出去的完整内容,没推成的「重发」照原样再推一次(notifytest.go)。正文就是
// 听歌统计,跟配置目录里别的缓存同一个密级;一条几百字节,100 条也不大。平台的原话截短并去掉密钥(notifyDetail)。

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
	Body        string `json:"body,omitempty"`
	OK          bool   `json:"ok"`
	Kind        string `json:"kind"`
	Status      int    `json:"status,omitempty"`
	Code        string `json:"code,omitempty"`
	Detail      string `json:"detail,omitempty"`
	ElapsedMS   int64  `json:"elapsed_ms"`
	// Digest:听歌报告的那份数,重发时照它重新排版(notifyrich.go)。
	Digest *digestStats `json:"digest,omitempty"`
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
		Body: msg.Body, Detail: r.Detail, ElapsedMS: r.Elapsed.Milliseconds(), Digest: msg.Digest,
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

// notifyDeliveredSince:推送记录里有没有 since(unix 秒)及以后推到 channel、同一事件同一标题、推成了的一条。
func notifyDeliveredSince(channel, event, title string, since int64) bool {
	notifyLogMu.Lock()
	defer notifyLogMu.Unlock()
	if notifyLogPath == "" {
		return false
	}
	for _, e := range readNotifyLog(notifyLogPath).Entries {
		if e.OK && e.At >= since && e.Channel == channel && e.Event == event && e.Title == title {
			return true
		}
	}
	return false
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
