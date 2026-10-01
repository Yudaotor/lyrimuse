package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
)

// Amazon Music 的本机日志(~/Library/Application Support/Amazon Music/Logs/AmazonMusic.log)。collector 只从里面读
// 待播预取要的两样(见 amazonUpcoming):`updateQueue` 行给的队列窗口,和最后一次开播是不是云端队列。
// 播放位置与当前这首的曲目标识由 App 读同一份日志得出;曲目标识经播放状态的 `track.amazon_track_id` 带过来,
// 见 noteAmazonCurrentTrack。

// amazonLogTailOnFirstRead:第一次读日志只看末尾这么多字节,见 amazonReplayStart。
const amazonLogTailOnFirstRead = 256 << 10

// amazonMusicLogOverride:单测指向临时文件。
var amazonMusicLogOverride string

func amazonMusicLogPath() string {
	if amazonMusicLogOverride != "" {
		return amazonMusicLogOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Amazon Music", "Logs", "AmazonMusic.log")
}

// amazonLogTail 增量读日志:记着读到哪了,每次只读新写的部分;文件变短(Amazon Music 重启后重写)就从头读。
// 第一次读只看末尾 amazonLogTailOnFirstRead 字节(一份日志一天能长到几 MB),但至少从最后一次开播读起,见 amazonReplayStart。
type amazonLogTail struct {
	path    string
	offset  int64
	partial []byte
	queue   []string // 最近一次 updateQueue 的窗口(当前这首 + 后两首),见 parseAmazonQueueLine
	// cloudQueue:最近一次开播走的是云端队列(电台,见 amazonPlaybackStartKind)。后面放什么由服务器边放边定,
	// 同专辑的其它歌基本放不到。
	cloudQueue bool
}

// amazonPlaybackStartKind 认日志里的开播请求:云端队列(`CQPlaybackRequestImpl … StartingCQPlayback`,电台一类:
// 开播带一串种子 ASIN,之后剩 5 首就向服务器再要一批)返回 cloud=true;普通开播(`BasePlaybackRequest …
// StartPlaybackLookupCompleted`,歌单 / 专辑)和播客开播返回 cloud=false。不是开播行 ok=false。纯函数。
func amazonPlaybackStartKind(line string) (cloud, ok bool) {
	switch {
	case strings.Contains(line, "StartingCQPlayback"):
		return true, true
	case strings.Contains(line, "StartPlaybackLookupCompleted"), strings.Contains(line, "StartPodcastPlayback"):
		return false, true
	}
	return false, false
}

// amazonReplayStart:第一次读从哪个字节开始 —— 末尾 tail 字节,但不晚于最后一次开播那一行(再往前留 amazonReplayLead)。
// 开播后暂停得久,Amazon 照样往日志里写,开播行会被推到末尾那段之前。同 Swift 侧 AmazonMusicPlayhead.replayStart。纯函数。
func amazonReplayStart(data []byte, tail int) int {
	start := max(0, len(data)-tail)
	last := bytes.LastIndex(data, []byte("new track playing"))
	if last < 0 || last >= start {
		return start
	}
	back := max(0, last-amazonReplayLead)
	if nl := bytes.LastIndexByte(data[:back], '\n'); nl >= 0 {
		return nl + 1
	}
	return 0
}

// amazonReplayLead 同 Swift 侧 replayLead。
const amazonReplayLead = 4096

// amazonLastStartIsCloudQueue:一段日志里最后一次开播是不是云端队列。第一次只读末尾一段,开播行常在更前面,
// 这里补看一遍前面那部分。
func amazonLastStartIsCloudQueue(data []byte) bool {
	cq := bytes.LastIndex(data, []byte("StartingCQPlayback"))
	plain := max(bytes.LastIndex(data, []byte("StartPlaybackLookupCompleted")), bytes.LastIndex(data, []byte("StartPodcastPlayback")))
	return cq > plain
}

func (t *amazonLogTail) poll() {
	f, err := os.Open(t.path)
	if err != nil {
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return
	}
	size := info.Size()
	if size < t.offset {
		t.offset, t.partial, t.queue, t.cloudQueue = 0, nil, nil, false
	}
	if t.offset == 0 && size > amazonLogTailOnFirstRead {
		if all, err := io.ReadAll(io.LimitReader(f, size)); err == nil {
			t.offset = int64(amazonReplayStart(all, amazonLogTailOnFirstRead))
			t.cloudQueue = amazonLastStartIsCloudQueue(all[:t.offset])
		} else {
			t.offset = size - amazonLogTailOnFirstRead
		}
	}
	if size == t.offset {
		return
	}
	if _, err := f.Seek(t.offset, io.SeekStart); err != nil {
		return
	}
	chunk, err := io.ReadAll(io.LimitReader(f, size-t.offset))
	if err != nil {
		return
	}
	t.offset += int64(len(chunk))
	data := append(t.partial, chunk...)
	last := bytes.LastIndexByte(data, '\n')
	if last < 0 {
		t.partial = data
		return
	}
	t.partial = append([]byte(nil), data[last+1:]...)
	for _, raw := range bytes.Split(data[:last], []byte{'\n'}) {
		line := string(raw)
		if q, ok := parseAmazonQueueLine(line); ok {
			t.queue = q
		} else if cloud, ok := amazonPlaybackStartKind(line); ok {
			t.cloudQueue = cloud
		}
	}
}

var (
	// amazonLogMu 管 amazonLog。读日志要碰盘,跟 amazonCurrentMu 分开:查曲目页的不用等它。
	amazonLogMu sync.Mutex
	amazonLog   *amazonLogTail

	amazonCurrentMu sync.Mutex
	// amazonCurrentTrack:App 此刻报的 Amazon Music 那首(歌手 / 歌名 + 日志里的曲目标识),给曲目页与本地歌词认身份。
	amazonCurrentTrack struct{ artist, title, trackID string }
)

// noteAmazonCurrentTrack 记下 App 这一拍报的当前曲目。不是 Amazon Music、或 App 没从日志认出这首(trackID 为空)就清空。
func noteAmazonCurrentTrack(bundleID, artist, title, trackID string) {
	if bundleID != amazonMusicBundleID || trackID == "" {
		artist, title, trackID = "", "", ""
	}
	amazonCurrentMu.Lock()
	defer amazonCurrentMu.Unlock()
	amazonCurrentTrack.artist, amazonCurrentTrack.title, amazonCurrentTrack.trackID = artist, title, trackID
}

// amazonQueueWindow 读进日志的新行,返回此刻的队列窗口与最后一次开播是不是云端队列。
func amazonQueueWindow() (queue []string, cloudQueue bool) {
	amazonLogMu.Lock()
	defer amazonLogMu.Unlock()
	if path := amazonMusicLogPath(); amazonLog == nil || amazonLog.path != path {
		amazonLog = &amazonLogTail{path: path}
	}
	amazonLog.poll()
	return slices.Clone(amazonLog.queue), amazonLog.cloudQueue
}

// amazonTrackURL:日志里的 `asin://<ASIN>` 换成公开曲目页。ASIN 是 10 位大写字母数字,别的形状(播客)不给。
func amazonTrackURL(trackID string) string {
	asin, ok := strings.CutPrefix(trackID, "asin://")
	if !ok || len(asin) != 10 {
		return ""
	}
	for _, c := range asin {
		if !(c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return ""
		}
	}
	return "https://music.amazon.com/tracks/" + asin
}

// amazonTrackURLFor:正用 Amazon Music 放、而且 App 从日志认出了这首,返回它的曲目页。
func amazonTrackURLFor(bundleID, artist, title string) string {
	if bundleID != amazonMusicBundleID {
		return ""
	}
	amazonCurrentMu.Lock()
	defer amazonCurrentMu.Unlock()
	if amazonCurrentTrack.artist != artist || amazonCurrentTrack.title != title {
		return ""
	}
	return amazonTrackURL(amazonCurrentTrack.trackID)
}
