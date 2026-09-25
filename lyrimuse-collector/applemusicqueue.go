package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

// Apple Music 的待播队列走系统媒体接口(MediaRemote 的 playback queue),不走 AppleScript。
//
// AppleScript 的字典里没有 Up Next,只能拿 `current playlist` + index 往后数:开着随机时那个顺序不是真的
// 播放顺序(只好整轮放弃),播 Apple Music 目录内容时 `current playlist` 直接报 -1728。MediaRemote 这边
// Music.app 发布的是**它自己的待播队列**:打乱之后的真实顺序、跨专辑跨歌手,带歌名 / 歌手 / 专辑 / 时长。
// 取数经 App 包里那套 perl 加载器(`Resources/nowplaying-clients/`,理由与接口签名见
// native/nowplaying-clients/nowplaying-clients.m),参数 `queue=N`。取不到(不在 App 包里跑、Music.app
// 没在系统里注册、私有接口变了)就返回 ok=false,由 appleMusicUpcoming 退回 AppleScript 那条。
//
// 其它播放器不走这里:实测 Spotify / 酷狗在这个接口上只给当前这一首,各自读本地队列文件(upcoming.go)。

// nowPlayingClientsPathsOverride 让单测指定加载器路径;空 = 按 collector 所在的 App 包找。
var nowPlayingClientsPathsOverride func() (script, lib string)

// appleMusicQueueRun 跑一次加载器,返回它的标准输出。单测替换它。
var appleMusicQueueRun = func(ctx context.Context, script, lib string, n int) ([]byte, error) {
	return exec.CommandContext(ctx, "/usr/bin/perl", script, lib, appleMusicBundleID, "queue="+strconv.Itoa(n)).Output()
}

var appleMusicQueueLogOnce sync.Once

// nowPlayingClientsPaths 找跟 collector 同在 Contents/Resources/ 下的 perl 加载器与 dylib。
func nowPlayingClientsPaths() (script, lib string) {
	if nowPlayingClientsPathsOverride != nil {
		return nowPlayingClientsPathsOverride()
	}
	exe, err := os.Executable()
	if err != nil {
		return "", ""
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	dir := filepath.Join(filepath.Dir(exe), "nowplaying-clients")
	script, lib = filepath.Join(dir, "nowplaying-clients.pl"), filepath.Join(dir, "libnowplaying-clients.dylib")
	for _, p := range []string{script, lib} {
		if _, err := os.Stat(p); err != nil {
			return "", ""
		}
	}
	return script, lib
}

// appleMusicUpcomingFromSystemQueue 从系统待播队列取 Music.app 接下来会播的几首。
func appleMusicUpcomingFromSystemQueue(artist, title string, n int) ([]upcomingTrack, bool) {
	script, lib := nowPlayingClientsPaths()
	if script == "" {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	out, err := appleMusicQueueRun(ctx, script, lib, n)
	if err != nil {
		return nil, false
	}
	res, ok := parseAppleMusicSystemQueue(out, artist, title, n)
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
