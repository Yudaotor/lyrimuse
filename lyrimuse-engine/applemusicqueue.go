package main

import (
	"log"
	"sync"
)

// Apple Music 的待播队列走系统媒体接口(MediaRemote 的 playback queue),不走 AppleScript。
//
// AppleScript 的字典里没有 Up Next,只能拿 `current playlist` + index 往后数:开着随机时那个顺序不是真的
// 播放顺序(只好整轮放弃),播 Apple Music 目录内容时 `current playlist` 直接报 -1728。MediaRemote 这边
// Music.app 发布的是**它自己的待播队列**:打乱之后的真实顺序、跨专辑跨歌手,带歌名 / 歌手 / 专辑 / 时长。
// 取数由 App 代跑并整理好(PlayerQueryServer 的 apple_music_queue:App 包里那套 perl 加载器,参数 `queue=N`,理由与
// 接口签名见 lyrimuse/native/nowplaying-clients/nowplaying-clients.m;整理见 PlayerQueryTracks.appleMusicSystemQueue),
// 这边只核对当前这首、往后取几首。取不到(App 不可用、加载器不在包里、Music.app 没在系统里注册、私有接口变了)就返回
// ok=false,由 appleMusicUpcoming 退回 AppleScript 那条。
//
// 其它播放器不走这里:实测 Spotify / 酷狗在这个接口上只给当前这一首,各自读本地队列文件(upcoming.go)。

var appleMusicQueueLogOnce sync.Once

// appleMusicUpcomingFromSystemQueue 请 App 读系统待播队列,取 Music.app 接下来会播的几首。
func appleMusicUpcomingFromSystemQueue(artist, title string, n int) ([]upcomingTrack, bool) {
	r, ok := askAppTracks(appQueryRequest{Kind: appQueryAppleMusicQueue, Count: n}, appQueryScriptTimeout)
	if !ok {
		return nil, false
	}
	res, ok := pickAppleMusicUpcoming(r, artist, title, n)
	if ok {
		appleMusicQueueLogOnce.Do(func() {
			log.Printf("apple music upcoming: reading the system playback queue (real play order, shuffle included)")
		})
	}
	return res, ok
}
