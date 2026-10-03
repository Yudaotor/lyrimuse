package main

import (
	"encoding/json"
	"log"
	"sync"
)

// Apple Music 的待播队列走系统媒体接口(MediaRemote 的 playback queue),不走 AppleScript。
//
// AppleScript 的字典里没有 Up Next,只能拿 `current playlist` + index 往后数:开着随机时那个顺序不是真的
// 播放顺序(只好整轮放弃),播 Apple Music 目录内容时 `current playlist` 直接报 -1728。MediaRemote 这边
// Music.app 发布的是**它自己的待播队列**:打乱之后的真实顺序、跨专辑跨歌手,带歌名 / 歌手 / 专辑 / 时长。
// 取数由 App 代跑(PlayerQueryServer 的 apple_music_queue:App 包里那套 perl 加载器,参数 `queue=N`,理由与
// 接口签名见 lyrimuse/native/nowplaying-clients/nowplaying-clients.m),这边只解析。取不到(App 不可用、加载器
// 不在包里、Music.app 没在系统里注册、私有接口变了)就返回 ok=false,由 appleMusicUpcoming 退回 AppleScript 那条。
//
// 其它播放器不走这里:实测 Spotify / 酷狗在这个接口上只给当前这一首,各自读本地队列文件(upcoming.go)。

var appleMusicQueueLogOnce sync.Once

// appleMusicUpcomingFromSystemQueue 请 App 读系统待播队列,取 Music.app 接下来会播的几首。
func appleMusicUpcomingFromSystemQueue(artist, title string, n int) ([]upcomingTrack, bool) {
	out, ok := askApp(appQueryRequest{Kind: appQueryAppleMusicQueue, Count: n}, appQueryScriptTimeout)
	if !ok {
		return nil, false
	}
	res, ok := parseAppleMusicSystemQueue([]byte(out), artist, title, n)
	if ok {
		appleMusicQueueLogOnce.Do(func() {
			log.Printf("apple music upcoming: reading the system playback queue (real play order, shuffle included)")
		})
	}
	return res, ok
}

// parseAppleMusicSystemQueue 解加载器输出 `{"items":[…]}`。第一项是它认为正在播的那首,跟 poller 手上的
// 那首核对上才算数(同其余几家:队列停在别的歌上是常态);之后的才是待播。
func parseAppleMusicSystemQueue(out []byte, artist, title string, n int) ([]upcomingTrack, bool) {
	var payload struct {
		Items []struct {
			Title    string  `json:"title"`
			Artist   string  `json:"artist"`
			Album    string  `json:"album"`
			Duration float64 `json:"duration"`
		} `json:"items"`
	}
	if err := json.Unmarshal(out, &payload); err != nil || len(payload.Items) < 2 {
		return nil, false
	}
	head := payload.Items[0]
	if loosenEnrichKey(head.Artist+"|"+head.Title) != loosenEnrichKey(artist+"|"+title) {
		return nil, false
	}
	res := make([]upcomingTrack, 0, n)
	for _, it := range payload.Items[1:] {
		if it.Title == "" || it.Artist == "" {
			continue
		}
		res = append(res, upcomingTrack{artist: it.Artist, title: it.Title, album: it.Album, duration: it.Duration})
		if len(res) == n {
			break
		}
	}
	return res, len(res) > 0
}
