package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// MyGo Music 的播放队列:没有脚本字典或对外队列接口,读它存在 `session.json` 里的会话快照(队列、播放顺序、当前位置、
// 随机、循环档)。快照在播放有变后约 30 秒写一次、在放时每 30 秒再写一次,暂停时不写,所以刚换过列表那半分钟里读到的
// 还是旧队列:当前这首在快照里对不上就不认、退回同专辑预取。本机曲目在快照里只有曲目 ID(文件路径的哈希),
// 按它的曲库索引 `local/index.json` 反查文件路径,让引擎顺带读下一首旁边的 .lrc。见 02 章决策 250。

// myGoDataDirOverride:测试用,非空时代替 `~/Library/Application Support/MyGo Music`。
var myGoDataDirOverride string

func myGoDataDir() string {
	if myGoDataDirOverride != "" {
		return myGoDataDirOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Application Support/MyGo Music")
}

// myGoRepeat:快照里的循环档(MyGo 源码 player.RepeatMode)。
const (
	myGoRepeatOff = 0
	myGoRepeatAll = 1
	myGoRepeatOne = 2
)

type myGoSession struct {
	Queue  []myGoTrack `json:"queue"`
	Order  []int       `json:"order"`
	At     int         `json:"at"`
	Repeat int         `json:"repeat"`
}

type myGoTrack struct {
	ID      string `json:"id"`
	Source  string `json:"source"`
	Name    string `json:"name"`
	Artists []struct {
		Name string `json:"name"`
	} `json:"artists"`
	Album struct {
		Name string `json:"name"`
	} `json:"album"`
	Duration    int64  `json:"duration"`
	ShowID      string `json:"showId"`
	Unavailable bool   `json:"unavailable"`
}

// artist:多位歌手按 MyGo 报给系统会话的写法用「, 」连。
func (t myGoTrack) artist() string {
	names := make([]string, 0, len(t.Artists))
	for _, a := range t.Artists {
		if n := strings.TrimSpace(a.Name); n != "" {
			names = append(names, n)
		}
	}
	return strings.Join(names, ", ")
}

// myGoLocalTrackID:本机曲目的 ID,sha256("track" + NUL + 文件绝对路径) 前 8 字节的十六进制(MyGo 源码 local.makeID)。
func myGoLocalTrackID(path string) string {
	sum := sha256.Sum256([]byte("track\x00" + path))
	return hex.EncodeToString(sum[:8])
}

// myGoSameSong:快照里这一条是不是播放器报的这一首(歌名、歌手按缓存键那一套归一后相同)。
func myGoSameSong(t myGoTrack, artist, title string) bool {
	if strings.TrimSpace(t.Name) == "" {
		return false
	}
	return loosenEnrichKey(legacyEnrichKey(t.artist(), t.Name, "")) == loosenEnrichKey(legacyEnrichKey(artist, title, ""))
}

// myGoUpcomingFrom:按快照排出当前这首之后会放的几首。当前这首先看快照记的位置,对不上再在播放顺序里找唯一一条同名同歌手的;
// 都对不上 ok=false。单曲循环没有要预取的;放到最后,列表循环接回开头、不循环就到此为止。播客单集、标了放不了的跳过。
// `paths` 是本机曲目 ID 到文件路径(找不到的不带路径)。纯函数,单测覆盖。
func myGoUpcomingFrom(s myGoSession, paths map[string]string, artist, title string, n int) ([]upcomingTrack, bool) {
	size := len(s.Queue)
	if size == 0 || len(s.Order) != size {
		return nil, false
	}
	for _, i := range s.Order {
		if i < 0 || i >= size {
			return nil, false
		}
	}
	pos := -1
	if s.At >= 0 && s.At < size && myGoSameSong(s.Queue[s.Order[s.At]], artist, title) {
		pos = s.At
	} else {
		for p, i := range s.Order {
			if !myGoSameSong(s.Queue[i], artist, title) {
				continue
			}
			if pos >= 0 {
				return nil, false
			}
			pos = p
		}
	}
	if pos < 0 {
		return nil, false
	}
	if s.Repeat == myGoRepeatOne {
		return nil, true
	}
	var out []upcomingTrack
	for step := 1; step < size && len(out) < n; step++ {
		p := pos + step
		if p >= size {
			if s.Repeat != myGoRepeatAll {
				break
			}
			p -= size
		}
		t := s.Queue[s.Order[p]]
		if t.ShowID != "" || t.Unavailable || strings.TrimSpace(t.Name) == "" {
			continue
		}
		u := upcomingTrack{artist: t.artist(), title: t.Name, album: t.Album.Name, duration: float64(t.Duration) / 1000}
		if t.Source == "local" {
			u.path = paths[t.ID]
		}
		out = append(out, u)
	}
	return out, true
}

func myGoReadSession() (myGoSession, bool) {
	dir := myGoDataDir()
	if dir == "" {
		return myGoSession{}, false
	}
	path := filepath.Join(dir, "session.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			noteFileErr("read", path, err)
		}
		return myGoSession{}, false
	}
	var s myGoSession
	if json.Unmarshal(raw, &s) != nil {
		noteParserUnrecognized("mygo-session", "session.json is not the expected JSON")
		return myGoSession{}, false
	}
	return s, true
}

// myGoLocalPaths:曲库索引里每个文件的曲目 ID → 路径。读不到时空表(下一首照样预取,只是不带路径)。
func myGoLocalPaths() map[string]string {
	out := map[string]string{}
	dir := myGoDataDir()
	if dir == "" {
		return out
	}
	path := filepath.Join(dir, "local", "index.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			noteFileErr("read", path, err)
		}
		return out
	}
	var idx struct {
		Tracks []struct {
			Path string `json:"path"`
		} `json:"tracks"`
	}
	if json.Unmarshal(raw, &idx) != nil {
		return out
	}
	for _, t := range idx.Tracks {
		if t.Path != "" {
			out[myGoLocalTrackID(t.Path)] = t.Path
		}
	}
	return out
}

// myGoUpcoming:MyGo 快照里当前这首后面的几首,见 myGoUpcomingFrom。
func myGoUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	s, ok := myGoReadSession()
	if !ok {
		return nil, false
	}
	return myGoUpcomingFrom(s, myGoLocalPaths(), artist, title, n)
}

// myGoQueueKey:快照里决定「接下来放什么」的那几样(队列的曲目 ID、播放顺序、循环档)。在放时快照每 30 秒带着新的
// 播放位置重写一次,按文件修改时间比会每 30 秒重读一遍队列,所以只比这几样。纯函数,单测覆盖。
func myGoQueueKey(s myGoSession) string {
	h := sha256.New()
	for _, t := range s.Queue {
		h.Write([]byte(t.Source + "\x00" + t.ID + "\x00"))
	}
	b, _ := json.Marshal(struct {
		Order  []int
		Repeat int
	}{s.Order, s.Repeat})
	h.Write(b)
	return hex.EncodeToString(h.Sum(nil))
}

var (
	myGoStampMu   sync.Mutex
	myGoStampMod  time.Time
	myGoStampLast string
)

// myGoQueueStamp:见 myGoQueueKey。文件没改写时不重读。
func myGoQueueStamp() string {
	dir := myGoDataDir()
	if dir == "" {
		return ""
	}
	mod := fileModTime(filepath.Join(dir, "session.json"))
	myGoStampMu.Lock()
	defer myGoStampMu.Unlock()
	if !mod.IsZero() && mod.Equal(myGoStampMod) {
		return myGoStampLast
	}
	s, ok := myGoReadSession()
	if !ok {
		return ""
	}
	myGoStampMod, myGoStampLast = mod, myGoQueueKey(s)
	return myGoStampLast
}
