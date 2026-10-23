package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"path/filepath"
	"sync"
)

// Pine Player 的播放列表:没有脚本接口、列表不落盘,App 经辅助功能读它主窗口里那张表(看不见的行也读得到),连同菜单里的循环档
// 一起交过来(App 侧 PinePlaylist,歌名歌手已按系统那份的拆法换好,跟这首真播到时写进播放状态的一字不差)。
// 随机开着时列表不重排、跳着放,开没开读不出:跟 QQ / 酷狗一样从换歌行为推断(queueOrder),随机时按 shuffleCandidates 交一批。
// 单曲循环时下一首还是这首,没有要预取的;列表循环(所有曲目 / 选中的列表)放到最后接回开头。见 02 章决策 168。

// pineQueueReply 是 App 交来的那份,键名跟 PinePlaylist.QueueReply 两边一起改。
type pineQueueReply struct {
	Repeating string           `json:"repeating"`
	Tracks    []pineQueueTrack `json:"tracks"`
}

type pineQueueTrack struct {
	Title    string  `json:"title"`
	Artist   string  `json:"artist"`
	Album    string  `json:"album"`
	Duration float64 `json:"duration"`
	File     string  `json:"file"`
}

// pineQueueAsk 让 App 读一次列表。单测替换它。
var pineQueueAsk = func() (string, bool) {
	return askApp(appQueryRequest{Kind: appQueryPineQueue}, appQueryScriptTimeout)
}

var (
	pinePlayOrderMu   sync.Mutex
	pinePlayOrderLast queueOrder
)

// pineUpcoming:Pine 列表里接下来会放的几首。当前这首按 App 报的当前文件(local_file)的文件名在列表里找,恰好一行才认,
// 否则按歌名歌手;读不到列表、列表里没有当前这首时 ok=false,退回同专辑预取。
func pineUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	out, ok := pineQueueAsk()
	if !ok {
		return nil, false
	}
	var q pineQueueReply
	if json.Unmarshal([]byte(out), &q) != nil || len(q.Tracks) == 0 {
		return nil, false
	}
	file := ""
	if p := localFileCurrentPath(artist, title); p != "" {
		file = filepath.Base(p)
	}
	pos := pineCurrentIndex(q.Tracks, file, artist, title)
	if pos < 0 {
		return nil, false
	}
	if q.Repeating == "one" {
		return nil, true
	}
	shuffled := pineObservePosition(pineQueueID(q.Tracks), pos, len(q.Tracks))
	return pineListUpcoming(q.Tracks, pos, n, shuffled, q.Repeating == "all")
}

// pineCurrentIndex:文件名对得上的恰好一行;没有文件名、对不上或不止一行时按歌名歌手。纯函数。
func pineCurrentIndex(tracks []pineQueueTrack, file, artist, title string) int {
	if file != "" {
		hit := -1
		for i, t := range tracks {
			if t.File != file {
				continue
			}
			if hit >= 0 {
				hit = -1
				break
			}
			hit = i
		}
		if hit >= 0 {
			return hit
		}
	}
	m := newQueueCurrentMatcher(artist, title)
	return queueCurrentIndex(len(tracks), -1, func(i int) queueMatch { return m.match(tracks[i].Artist, tracks[i].Title) })
}

// pineQueueID:列表身份,按每行的文件名算。换了列表(加删了歌、换了一份)就重新攒顺序 / 随机的证据。
func pineQueueID(tracks []pineQueueTrack) string {
	h := sha256.New()
	for _, t := range tracks {
		h.Write([]byte(t.File))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// pineObservePosition 记下这一次的位置,返回此刻是否按随机处理。从最后一首到第一首算顺序(列表循环接回开头)。
func pineObservePosition(list string, pos, size int) (shuffled bool) {
	pinePlayOrderMu.Lock()
	defer pinePlayOrderMu.Unlock()
	prevPos := pinePlayOrderLast.pos
	shuffled, flipped := pinePlayOrderLast.observeWrapping(list, pos, size)
	if flipped {
		log.Printf("pine upcoming: moved from position %d to %d in the playlist, treating playback as shuffled and prefetching from the whole list", prevPos, pos)
	}
	return shuffled
}

// pineListUpcoming:pos 那一首之后会放的。随机时按 shuffleCandidates 交一批;否则往后取 n 首,wrap(列表循环)时放到最后接回
// 开头、绕一圈到当前这首为止。歌手空的跳过(没写标签又拆不出歌手的,预取一首对不上的歌只是白占解析带宽)。纯函数。
func pineListUpcoming(tracks []pineQueueTrack, pos, n int, shuffled, wrap bool) ([]upcomingTrack, bool) {
	at := func(i int) (upcomingTrack, bool) {
		t := tracks[i]
		return upcomingTrack{artist: t.Artist, title: t.Title, album: t.Album, duration: t.Duration}, t.Title != "" && t.Artist != ""
	}
	if shuffled {
		return shuffleCandidates(len(tracks), pos, at), true
	}
	res := make([]upcomingTrack, 0, n)
	for k := 1; k < len(tracks) && len(res) < n; k++ {
		i := pos + k
		if i >= len(tracks) {
			if !wrap {
				break
			}
			i -= len(tracks)
		}
		if t, ok := at(i); ok {
			res = append(res, t)
		}
	}
	return res, len(res) > 0
}
