package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ---- 私人漫游(FM)的队列:跟 playingList 分开存 ----

// neteaseFMOverride 让单测把私人漫游的队列文件指到临时路径。空 = 用真实路径。
var neteaseFMOverride string

// neteaseFMPath 是网易云「私人漫游」的队列。进私人漫游后客户端不再写 playingList(那份停在上一个歌单),
// 每换一首改写这一份:顶层 currentIndex 指着正在播的那首,queue 是当前这首前后的一小段(实测 6 首)。见 09 章决策 223。
func neteaseFMPath() string {
	if neteaseFMOverride != "" {
		return neteaseFMOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.netease.163music/Data/Documents",
		"storage/file_storage/webdata/file/fmPlay")
}

// neteaseFMFile 只摘用得上的字段。曲目直接放在 queue 的元素上(playingList 套了一层 track),id 是数字。
type neteaseFMFile struct {
	CurrentIndex int `json:"currentIndex"`
	Queue        []struct {
		Name    string `json:"name"`
		Artists []struct {
			Name string `json:"name"`
		} `json:"artists"`
		Album struct {
			Name string `json:"name"`
		} `json:"album"`
		Duration int64 `json:"duration"` // 毫秒
	} `json:"queue"`
}

// neteaseUpcomingAnyQueue 在 playingList 与私人漫游两份队列里取接下来会播的几首。两份都可能停在旧内容上,
// 先试最近改写过的那份,对不上当前这首再试另一份。
func neteaseUpcomingAnyQueue(artist, title string, n int) ([]upcomingTrack, bool) {
	fmFirst := fileModTime(neteaseFMPath()).After(fileModTime(neteaseUpcomingPath()))
	if fmFirst {
		if res, ok := neteaseFMUpcoming(artist, title, n); ok {
			return res, true
		}
	}
	if res, ok := neteaseUpcoming(artist, title, n); ok {
		return res, true
	}
	if !fmFirst {
		return neteaseFMUpcoming(artist, title, n)
	}
	return nil, false
}

// fileModTime 取不到(不存在、没权限)时返回零值。
func fileModTime(path string) time.Time {
	if path == "" {
		return time.Time{}
	}
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return st.ModTime()
}

// neteaseFMUpcoming 从私人漫游的队列里取当前这首之后的几首。位置先看 currentIndex,对不上再按歌名歌手找;
// 只往后数、不绕回,队列后面没有了就只给已经排好的那几首。
func neteaseFMUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	path := neteaseFMPath()
	if path == "" {
		return nil, false
	}
	st, err := os.Stat(path)
	if err != nil {
		noteLocalCacheDenied("netease", path, err)
		return nil, false
	}
	if st.Size() > neteaseUpcomingMaxBytes {
		return nil, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		noteLocalCacheDenied("netease", path, err)
		return nil, false
	}
	noteLocalCacheReadable("netease")
	var f neteaseFMFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, false
	}
	joinArtists := func(i int) string {
		names := make([]string, 0, len(f.Queue[i].Artists))
		for _, a := range f.Queue[i].Artists {
			if a.Name != "" {
				names = append(names, a.Name)
			}
		}
		return strings.Join(names, "/")
	}
	m := newQueueCurrentMatcher(artist, title)
	pos := queueCurrentIndex(len(f.Queue), f.CurrentIndex, func(i int) queueMatch {
		return m.match(joinArtists(i), f.Queue[i].Name)
	})
	if pos < 0 {
		return nil, false
	}
	res := make([]upcomingTrack, 0, n)
	for i := pos + 1; i < len(f.Queue) && len(res) < n; i++ {
		tr := f.Queue[i]
		if tr.Name == "" {
			continue
		}
		res = append(res, upcomingTrack{
			artist:   joinArtists(i),
			title:    tr.Name,
			album:    tr.Album.Name,
			duration: float64(tr.Duration) / 1000,
		})
	}
	if len(res) > 0 {
		log.Printf("netease upcoming: %d from the private FM queue (position %d of %d)", len(res), pos, len(f.Queue))
	}
	return res, len(res) > 0
}
