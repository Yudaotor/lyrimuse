// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
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
// 首歌时,大概率已经在后台解析完了,不用现等。跟正常路径复用同一套 enrichCache/
// enrichInflight 去重,不会跟真播放到那首歌时的解析撞车重复跑。
//
// 曲目表从哪来,2026-08-14 起按**歌词来源**分流,而不是按播放器:
//
//   Apple Music → AppleScript 问 Music.app 的本地资料库。最准,因为曲目字符串跟播放器
//                 上报的逐字节一致,算出来的 enrich key 必然对得上。
//   其余播放器  → 用解析这首歌时命中的那个平台的专辑接口(目前:网易云)。
//
// 为什么不是"按播放器":trackEnrichment 里除了广告判断**没有任何 bundleID 分支** ——
// 你用 Spotify 听歌时,歌词本来就是去网易云/QQ 搜的。所以要的不是"问 Spotify 它的专辑
// 有哪些歌"(那需要 Spotify Web API 的 OAuth 凭据,仓库里没有也不该硬编码),而是"这张
// 专辑有哪些歌" —— 后者网易云就能答,且对 Spotify / QQ 音乐 / 网易云三个播放器通用。
//
// 2026-08-14 之前这里**只有** Music.app 那一条,而调用点没有任何播放器判断:用别的播放器
// 听歌时,它拿着别家的专辑名去查 Apple Music 资料库,必然查不到,每换一张专辑白跑一次
// osascript;更糟的是那段脚本没有 running 守卫,会把没开的 Music.app 拉起来。

// albumPrefetchMaxTracks 是安全阀——防止专辑名字段被打上"整个作品集"这类离谱大合集
// (几十上百首)时,一次性炸出上百个并发解析请求。正常专辑几首到二十来首都远低于这个数,
// 不会被这个上限影响。
// 2026-08-14 从 60 收到 30:闸门从"专辑名必须完全相等"放宽到"宽松包含"之后,这个上限
// 才真正开始起兜底作用 —— 放进来的可能是同一张专辑的加长版(Bad 25th Anniversary 24 首
// vs 原版 11 首)。正常专辑几首到二十来首,30 够用;超过的多半是合集,不值得为它一次性
// 炸出几十个解析请求。
const albumPrefetchMaxTracks = 30

var (
	prefetchMu     sync.Mutex
	lastPrefetched string // 上一次已经预取过的专辑名,同一张专辑内切歌不用重复问 Music.app
)

// prefetchAlbumSiblings 在真正换到一首新歌时调用(不含单曲循环重新起播那种"同一首歌"
// 的场景)。整个函数体在独立 goroutine 里跑,不阻塞 poller 的正常处理。
func prefetchAlbumSiblings(currentArtist, currentTitle, album, bundleID string) {
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
		tracks, ok := albumTracks(currentArtist, currentTitle, album, bundleID)
		if !ok {
			return
		}
		if len(tracks) > albumPrefetchMaxTracks {
			log.Printf("album prefetch: skipping %q (%d tracks, over the %d-track safety cap)", album, len(tracks), albumPrefetchMaxTracks)
			return
		}
		queued := 0
		for _, t := range tracks {
			if t.title == "" || (t.title == currentTitle && t.artist == currentArtist) {
				continue // 当前正在播的这首已经走正常路径解析,不用重复触发
			}
			// 走 enrichKey 而不是自己拼:这条路径的曲目名来自**歌词平台**(网易云的曲目
			// 表),跟播放器报的拼法天然不一致 —— 播放器给 `不散的筵席（I Miss You）`、
			// 网易云给 `不散的筵席`,自己拼就等于每张专辑都预取出一批重复条目。
			key := enrichKey(t.artist, t.title, album)
			enrichMu.Lock()
			_, exists := enrichCache[key]
			if !exists {
				// 2026-08-16 补上:预取是重复条目最大的产生源 —— 曲目名来自**网易云曲库**,
				// 跟播放器报的拼法在"中英文之间加不加空格""繁体还是简体"上系统性不一致。
				// 上面那句"走 enrichKey 而不是自己拼"只挡住了译名括号这一档,挡不住这两档。
				// 精确没命中时再宽松找一次,已经有等价条目就不预取了(实测那 14 组重复里,
				// 丁世光/方大同/孙燕姿那批繁简对就是这么来的)。
				if _, found := canonicalEnrichKey(key); found {
					exists = true
				}
			}
			// 在途的也要宽松查:专辑预取一次会排一整批曲目,跟"正在播的那首"几乎同时
			// 发起,而那首的解析这时还没写进 enrichCache —— 只查精确键会漏。
			_, inflight := looseInflightKey(key)
			eligible := !exists && !inflight
			if eligible {
				enrichInflight[key] = true
			}
			enrichMu.Unlock()
			if !eligible {
				continue // 已经解析过、或者已经有别的 goroutine 在解析,不重复起
			}
			queued++
			go resolveEnrichAsync(key, t.artist, t.title, album, t.duration)
		}
		// 成功也打一条。原来这个函数**只在超上限被跳过时**才打日志,正常路径一行不打 ——
		// 于是"预取到底跑没跑"完全不可观测:日志里没记录,既可能是没跑、也可能是跑得好好的,
		// 分不开。这次排查就卡在这一点上。
		log.Printf("album prefetch: %q → %d tracks, %d queued", album, len(tracks), queued)
	}()
}

type albumTrack struct {
	title, artist string
	duration      float64
}

// albumTracks 按当前播放器挑一个"这张专辑有哪些曲目"的来源,见文件头注释。
func albumTracks(artist, title, album, bundleID string) ([]albumTrack, bool) {
	if bundleID == "com.apple.Music" {
		return albumTracksFromMusicApp(album)
	}
	// 复用解析歌词时那次搜索的结果 —— neteaseLookup 带 30 天缓存,当前这首歌刚解析过,
	// 这里是缓存命中、零网络;拿到的 AlbumID 是**这首歌自己所属**的那张专辑。
	ne := neteaseLookup(artist, title, album)
	if ne.AlbumID <= 0 {
		return nil, false
	}
	// 专辑名至少要"宽松包含"(albumScore >= 100)才预取。
	//
	// 2026-08-14 修正过一次:这里原来要求满分 200(normLoose 后完全相等),理由是怕选到
	// 精选集。把三档分数真的量出来之后,那个担心站不住:
	//
	//   albumScore("神经志",                "神經志 The Journal")   = 100  ← 想要的
	//   albumScore("Bad",                   "Bad 25th Anniversary") = 100  ← 怕的
	//   albumScore("King of Pop [Box set]", "Bad")                  =   0  ← 最怕的,本来就进不来
	//
	// 真正灾难性的那种(76 首的合集、上百首的作品集)名字跟本地专辑毫不沾边,天然是 0 分,
	// 不需要 200 这道闸去挡。而 200 挡掉的全是"同一张专辑、写法不同"——繁简(normLoose
	// 已经归一)、带英文副标题、带 (Remastered) 后缀,这些在中文曲库里极其常见。用户实测:
	// 用 Spotify 放《神經志 The Journal》,每首歌都被这一行拦下,功能等于没上线。
	//
	// 100 这档剩下的风险只是"同一张专辑的另一个版本"(25 周年版 24 首 vs 原版 11 首),
	// 多解析的仍是**同一张专辑里**的歌,由下面的曲目数上限兜底就够了。
	if albumScore(ne.Album, album) < 100 {
		log.Printf("album prefetch: netease album %q != local %q, skipping", ne.Album, album)
		return nil, false
	}
	return neteaseAlbumTracks(ne.AlbumID)
}

// albumTracksFromMusicApp 用 AppleScript 问 Music.app 本地库里这张专辑都有哪些曲目
// (名字/歌手/时长)——跟 system.go 的 appleMusicPosition 同一个手法(本地 AppleScript,
// 不联网,只有 Music.app 在跑才有意义)。任何一步失败都返回 ok=false,调用方直接放弃
// 这次预取,不影响正常播放/解析路径。
func albumTracksFromMusicApp(album string) ([]albumTrack, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	// tab/linefeed 是 AppleScript 内置常量(制表符/换行符),用它们而不是手动往脚本字符串里
	// 塞转义序列——更不容易写错,也不用担心 Go/AppleScript 两层转义规则互相打架。
	// ⚠️ 先判 running 再 tell:`tell application "Music"` 只要发出任何命令就会**启动**
	// Music.app —— 一个只用 Spotify/QQ 音乐的用户会被每换一张专辑就静默拉起一次 Apple
	// Music。本仓其它几段 Music/Spotify 脚本(getStateScript、spotifyPositionScript)
	// 开头都有同样的守卫,同一个理由。
	script := fmt.Sprintf(`if application "Music" is not running then
	return ""
end if
tell application "Music"
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
	var tracks []albumTrack
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
		tracks = append(tracks, albumTrack{title: parts[0], artist: parts[1], duration: dur})
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
