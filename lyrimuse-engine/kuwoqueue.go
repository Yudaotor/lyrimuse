package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"log"
	neturl "net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 酷我的播放列表:容器里 Caches/DocumentData/kwmusic.db 的 PlayList 表,就是它「播放列表」面板里那一份,按 ID 升序
// 是列表顺序。每条有歌名、歌手、专辑、整秒时长和曲目 id(PersistentId),歌名、歌手、专辑跟它报给系统的写法一致。
// 没有当前位置(LastIndex 表常是空的),靠歌名、歌手在列表里认出在放的这首;电台里的歌不进这份列表,认不出就退回
// 同专辑预取。
//
// 偏好里有个 keyPlayMode,各值对应哪种模式没有核实过,不读;顺序 / 随机看换歌行为(queueorder.go),
// 小列表整份预取,同酷狗(kugouPickUpcoming)。见 09 章决策 377。

// kuwoUpcomingOverride 让单测把库指到临时路径。空 = 用真实路径。
var kuwoUpcomingOverride string

func kuwoUpcomingPath() string {
	if kuwoUpcomingOverride != "" {
		return kuwoUpcomingOverride
	}
	return kuwoContainerDocumentDir("kwmusic.db")
}

// kuwoQueueQueryTimeout:sqlite3 子进程的上限。库只有几十 KB,正常几十毫秒;撞上客户端写锁时宁可这一拍放弃。
const kuwoQueueQueryTimeout = 4 * time.Second

// kuwoQueueSQL 只取列表要用的几列。列名写死:客户端改了表结构时 sqlite3 报错,按 parser 不认得上报。
const kuwoQueueSQL = `SELECT ID, PersistentId, Title, Artist, Album, Duration FROM PlayList ORDER BY ID`

type kuwoQueueRow struct {
	ID           int64  `json:"ID"`
	PersistentID any    `json:"PersistentId"`
	Title        string `json:"Title"`
	Artist       string `json:"Artist"`
	Album        string `json:"Album"`
	Duration     any    `json:"Duration"`
}

// kuwoLoadQueue 读整份播放列表。读不了、空列表返回 nil, false。
func kuwoLoadQueue() ([]kuwoQueueRow, bool) {
	path := kuwoUpcomingPath()
	if path == "" {
		return nil, false
	}
	if _, err := os.Stat(path); err != nil {
		noteLocalCacheDenied("kuwo", path, err)
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), kuwoQueueQueryTimeout)
	defer cancel()
	// mode=ro:库是回滚日志模式(没有 -wal / -shm),只读打开不建任何文件;撞上客户端写锁就失败、fail-soft。
	uri := (&neturl.URL{Scheme: "file", Path: path, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, kuwoQueueSQL).Output()
	if err != nil {
		noteLocalCacheReadFailure("kuwo", path)
		if sqliteSchemaMismatch(err) {
			noteParserUnrecognized("kuwo-local-queue", sqliteErrorDetail(err))
		}
		return nil, false
	}
	noteLocalCacheReadable("kuwo")
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return nil, false // 零行时 sqlite3 -json 输出空串,不是 "[]"
	}
	var rows []kuwoQueueRow
	if err := json.Unmarshal(trimmed, &rows); err != nil {
		noteParserUnrecognized("kuwo-local-queue", "PlayList rows did not decode")
		return nil, false
	}
	return rows, len(rows) > 0
}

// kuwoQueueNumber 把 sqlite3 -json 给的数字或数字串统一成十进制串;别的形状返回空串。
func kuwoQueueNumber(v any) string {
	switch x := v.(type) {
	case float64:
		if x < 0 || x != float64(int64(x)) {
			return ""
		}
		return strconv.FormatInt(int64(x), 10)
	case string:
		s := strings.TrimSpace(x)
		if catalogIDChars(s, 1, 20, isASCIIDigitRune) {
			return s
		}
	}
	return ""
}

func (r kuwoQueueRow) track() upcomingTrack {
	t := upcomingTrack{artist: strings.TrimSpace(r.Artist), title: strings.TrimSpace(r.Title), album: strings.TrimSpace(r.Album)}
	if d, err := strconv.ParseFloat(kuwoQueueNumber(r.Duration), 64); err == nil && d > 0 {
		t.duration = d
	}
	return t
}

var (
	kuwoPlayOrderMu   sync.Mutex
	kuwoPlayOrderLast queueOrder
)

// kuwoUpcoming 取酷我播放列表里接下来会放的几首。在放的这首不在列表里(电台、列表停在上一次)返回 ok=false。
func kuwoUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	rows, ok := kuwoLoadQueue()
	if !ok {
		return nil, false
	}
	return kuwoPickUpcoming(rows, artist, title, n)
}

// kuwoPickUpcoming 是 kuwoUpcoming 去掉读库的那一半(单测直接喂行)。
func kuwoPickUpcoming(rows []kuwoQueueRow, artist, title string, n int) ([]upcomingTrack, bool) {
	tracks := make([]upcomingTrack, len(rows))
	for i, r := range rows {
		tracks[i] = r.track()
	}
	m := newQueueCurrentMatcher(artist, title)
	pos := queueCurrentIndex(len(tracks), -1, func(i int) queueMatch { return m.match(tracks[i].artist, tracks[i].title) })
	if pos < 0 {
		return nil, false
	}
	at := func(i int) (upcomingTrack, bool) { return tracks[i], tracks[i].title != "" }
	others := 0
	for i := range tracks {
		if _, ok := at(i); ok && i != pos {
			others++
		}
	}
	if others == 0 {
		return nil, false
	}

	kuwoPlayOrderMu.Lock()
	prevPos := kuwoPlayOrderLast.pos
	shuffled, flipped := kuwoPlayOrderLast.observeWrapping(kuwoQueueID(rows), pos, len(tracks))
	kuwoPlayOrderMu.Unlock()
	if flipped {
		log.Printf("kuwo upcoming: moved from position %d to %d in the play list, treating playback as shuffled", prevPos, pos)
	}

	if shuffled || len(tracks) <= queueShuffleWholeListMax {
		return shuffleCandidates(len(tracks), pos, at), true
	}
	res := make([]upcomingTrack, 0, n)
	for i := pos + 1; i < len(tracks) && len(res) < n; i++ {
		if t, ok := at(i); ok {
			res = append(res, t)
		}
	}
	return res, len(res) > 0
}

// kuwoQueueID 是一份列表的身份:全部行的 ID 和曲目 id 的摘要。
func kuwoQueueID(rows []kuwoQueueRow) string {
	h := fnv.New64a()
	for _, r := range rows {
		fmt.Fprintf(h, "%d:%s\x00", r.ID, kuwoQueueNumber(r.PersistentID))
	}
	return strconv.FormatUint(h.Sum64(), 16) + "/" + strconv.Itoa(len(rows))
}
