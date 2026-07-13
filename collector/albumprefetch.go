// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 用户的听歌习惯是按专辑顺序一首首听——一首歌刚开始播放、还在等 enrich 解析出歌词的
// 那几秒/几十秒,其实是"预取"同一张专辑里其它还没解析过的曲目的好时机:等真的播到那
// 首歌时,大概率已经在后台解析完了,不用现等。只问 Music.app 本地库里这张专辑实际
// 拥有哪些曲目(不是瞎猜/联网查专辑目录),跟正常路径复用同一套 enrichCache/
// enrichInflight 去重,不会跟真播放到那首歌时的解析撞车重复跑。

// albumPrefetchMaxTracks 是安全阀——防止专辑名字段被打上"整个作品集"这类离谱大合集
// (几十上百首)时,一次性炸出上百个并发解析请求。正常专辑几首到二十来首都远低于这个数,
// 不会被这个上限影响。
const albumPrefetchMaxTracks = 60

var (
	prefetchMu     sync.Mutex
	lastPrefetched string // 上一次已经预取过的专辑名,同一张专辑内切歌不用重复问 Music.app
)

// prefetchAlbumSiblings 在真正换到一首新歌时调用(不含单曲循环重新起播那种"同一首歌"
// 的场景)。整个函数体在独立 goroutine 里跑,不阻塞 poller 的正常处理。
func prefetchAlbumSiblings(currentArtist, currentTitle, album string) {
	if album == "" {
		return
	}
	prefetchMu.Lock()
	if lastPrefetched == album {
		prefetchMu.Unlock()
		return // 同一张专辑内换到下一首,上次已经问过 Music.app、该起的都起过了
	}
	lastPrefetched = album
	prefetchMu.Unlock()

	go func() {
		tracks, ok := albumTracksFromMusicApp(album)
		if !ok {
			return
		}
		if len(tracks) > albumPrefetchMaxTracks {
			log.Printf("album prefetch: skipping %q (%d tracks, over the %d-track safety cap)", album, len(tracks), albumPrefetchMaxTracks)
			return
		}
		for _, t := range tracks {
			if t.title == "" || (t.title == currentTitle && t.artist == currentArtist) {
				continue // 当前正在播的这首已经走正常路径解析,不用重复触发
			}
			key := t.artist + "|" + t.title + "|" + album
			enrichMu.Lock()
			_, exists := enrichCache[key]
			inflight := enrichInflight[key]
			eligible := !exists && !inflight
			if eligible {
				enrichInflight[key] = true
			}
			enrichMu.Unlock()
			if !eligible {
				continue // 已经解析过、或者已经有别的 goroutine 在解析,不重复起
			}
			go resolveEnrichAsync(key, t.artist, t.title, album, t.duration)
		}
	}()
}

type musicAppTrack struct {
	title, artist string
	duration      float64
}

// albumTracksFromMusicApp 用 AppleScript 问 Music.app 本地库里这张专辑都有哪些曲目
// (名字/歌手/时长)——跟 system.go 的 appleMusicPosition 同一个手法(本地 AppleScript,
// 不联网,只有 Music.app 在跑才有意义)。任何一步失败都返回 ok=false,调用方直接放弃
// 这次预取,不影响正常播放/解析路径。
func albumTracksFromMusicApp(album string) ([]musicAppTrack, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	// tab/linefeed 是 AppleScript 内置常量(制表符/换行符),用它们而不是手动往脚本字符串里
	// 塞转义序列——更不容易写错,也不用担心 Go/AppleScript 两层转义规则互相打架。
	script := fmt.Sprintf(`tell application "Music"
	set output to ""
	repeat with t in (every track of library playlist 1 whose album is %s)
		set output to output & (name of t) & tab & (artist of t) & tab & (duration of t) & linefeed
	end repeat
	return output
end tell`, appleScriptQuote(album))
	out, err := exec.CommandContext(ctx, "osascript", "-e", script).Output()
	if err != nil {
		return nil, false
	}
	var tracks []musicAppTrack
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) != 3 {
			continue
		}
		dur, _ := strconv.ParseFloat(strings.TrimSpace(parts[2]), 64)
		tracks = append(tracks, musicAppTrack{title: parts[0], artist: parts[1], duration: dur})
	}
	return tracks, true
}

// appleScriptQuote 把一个字符串安全地嵌进 AppleScript 双引号字符串字面量里——转义反斜杠
// 和双引号,防止专辑名里恰好带这两种字符时破坏脚本语法。
func appleScriptQuote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}
