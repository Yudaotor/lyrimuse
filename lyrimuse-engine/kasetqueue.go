package main

import (
	"encoding/json"
	"log"
	"sync"
)

// Kaset(YouTube Music 的原生客户端)的待播队列。App 代问它的 AppleScript `get play queue` 与循环模式,
// 曲目身份按 App 的口径整理好再交过来(署名清理、不给专辑,见 KasetPlayerInfo.queueReply):这里拿去预取的
// 缓存键,跟这首真播到时 App 写进播放状态的一字不差,所以这边不再动歌名歌手。
//
// 队列就是播放顺序 —— 开着随机时 Kaset 把打乱后的顺序直接排进队列。单曲循环时下一首还是这首,没有要预取的;
// 列表循环时放到队尾接回开头。

// kasetQueueReply 是 App 交来的那份,键名跟 KasetPlayerInfo.QueueReply 两边一起改(样例 shared/testdata/kaset-queue/)。
type kasetQueueReply struct {
	CurrentIndex *int   `json:"current_index"`
	Repeating    string `json:"repeating"`
	Tracks       []struct {
		Title        string  `json:"title"`
		Artist       string  `json:"artist"`
		Duration     float64 `json:"duration"`
		VideoID      string  `json:"video_id"`
		AudioVideoID string  `json:"audio_video_id"`
	} `json:"tracks"`
}

// kasetAudioVideoIDsCap:记下的 videoId → 音轨版本超过这么多条,就整个换成最新这条队列的。
const kasetAudioVideoIDsCap = 2000

var (
	kasetAudioMu sync.Mutex
	// kasetAudioVideoIDs:队列里出现过的 videoId → 它的音轨版本(Kaset 的 audioVideoId)。
	kasetAudioVideoIDs = map[string]string{}
)

// kasetQueueAudioVideoIDs:队列里每一首的 videoId → 音轨版本 videoId,两个都得是 videoId 的形状。纯函数,单测覆盖。
func kasetQueueAudioVideoIDs(out string) map[string]string {
	var r kasetQueueReply
	if json.Unmarshal([]byte(out), &r) != nil {
		return nil
	}
	m := map[string]string{}
	for _, t := range r.Tracks {
		if youtubeMusicWatchURL(t.VideoID) != "" && youtubeMusicWatchURL(t.AudioVideoID) != "" {
			m[t.VideoID] = t.AudioVideoID
		}
	}
	return m
}

func noteKasetAudioVideoIDs(m map[string]string) {
	kasetAudioMu.Lock()
	defer kasetAudioMu.Unlock()
	if len(kasetAudioVideoIDs)+len(m) > kasetAudioVideoIDsCap {
		kasetAudioVideoIDs = map[string]string{}
	}
	for k, v := range m {
		kasetAudioVideoIDs[k] = v
	}
}

// kasetAudioVideoIDFor:这个 videoId 的音轨版本;队列里没见过就是它自己。YouTube Music 只给音轨版本登记专辑,
// MV / 视频版本的署名行是播放量。
func kasetAudioVideoIDFor(videoID string) string {
	kasetAudioMu.Lock()
	defer kasetAudioMu.Unlock()
	if a := kasetAudioVideoIDs[videoID]; a != "" {
		return a
	}
	return videoID
}

func kasetUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	out, ok := askApp(appQueryRequest{Kind: appQueryKasetQueue}, appQueryScriptTimeout)
	if !ok {
		return nil, false
	}
	noteKasetAudioVideoIDs(kasetQueueAudioVideoIDs(out))
	res, ok := parseKasetQueue(out, artist, title, n)
	// 接下来这几首在 YouTube Music 上的登记(专辑、原名)后台先问好,播到时界面上的专辑不用等。
	for _, t := range res {
		ytmusicCreditCachedOrFetch(kasetAudioVideoIDFor(t.videoID))
	}
	return res, ok
}

// parseKasetQueue 从 App 交来的队列里取当前这首之后的 n 首。当前这首先认队列自己标的那一格(歌名要对得上);
// 对不上(换歌那一下队列还停在上一首)就按歌名 + 歌手在整条队列里找,恰好一首才认,否则 ok=false 退回同专辑预取。
// 纯函数,单测覆盖。
func parseKasetQueue(out, artist, title string, n int) ([]upcomingTrack, bool) {
	var r kasetQueueReply
	if json.Unmarshal([]byte(out), &r) != nil || len(r.Tracks) == 0 || title == "" {
		return nil, false
	}
	cur := -1
	if i := r.CurrentIndex; i != nil && *i >= 0 && *i < len(r.Tracks) && r.Tracks[*i].Title == title {
		cur = *i
	} else {
		for i, t := range r.Tracks {
			if t.Title != title || t.Artist != artist {
				continue
			}
			if cur >= 0 {
				log.Printf("kaset upcoming: %q appears more than once in the queue; falling back to album prefetch", artist+" - "+title)
				return nil, false
			}
			cur = i
		}
	}
	if cur < 0 {
		return nil, false
	}
	if r.Repeating == "one" {
		return nil, true
	}
	var res []upcomingTrack
	for k := 1; k < len(r.Tracks) && len(res) < n; k++ {
		i := cur + k
		if i >= len(r.Tracks) {
			if r.Repeating != "all" {
				break
			}
			i -= len(r.Tracks)
		}
		t := r.Tracks[i]
		if t.Title == "" || t.Artist == "" {
			continue
		}
		res = append(res, upcomingTrack{artist: t.Artist, title: t.Title, duration: t.Duration, videoID: t.VideoID})
	}
	return res, true
}
