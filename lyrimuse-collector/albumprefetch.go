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
// 曲目表从哪来:播放器本机有这张专辑的曲目表就用它自己的,没有才问歌词平台:
//
//   Apple Music 到 AppleScript 问 Music.app 的本地资料库。最准,因为曲目字符串跟播放器
//                 上报的逐字节一致,算出来的 enrich key 必然对得上。资料库里没收全的,按目录锚点
//                 的专辑 id 从 Apple 目录补(applemusicalbum.go)。
//   Spotify     到 客户端自己的元数据缓存(spotifyalbum.go),同样是播放器自己的写法;
//                 那张专辑没被客户端加载过时退回下一条。
//   QQ 音乐     到 QQ 自己的专辑曲目表(按播放列表归档里这首的 albumMid 问);问不到退回下一条。
//   酷狗        到 酷狗自己的专辑曲目表(按队列里这首的文件 hash 问专辑);问不到退回下一条。
//   汽水        到 汽水网页版的专辑分享页(按这首的专辑 id);问不到退回下一条。
//   其余播放器  到 用解析这首歌时命中的那个平台的专辑接口(目前:网易云)。
//
// 播放器自己的曲目表优先,是因为写进 enrich key 的歌名要跟它真播到时报的一致;歌词平台的曲目表
// 在繁简、大小写、版本后缀上常跟播放器不同,下面的宽松去重兜得住一部分,兜不住的就是白解析一首。
// Spotify 只走本地缓存、不走 Web API:在线接口要 OAuth 凭据,仓库里没有也不该硬编码。
// 网易云那条对任何播放器通用 —— 要的只是"这张专辑有哪些歌"。
//
// 每条来源都必须按 bundleID 挑:拿别家的专辑名去查 Music.app 资料库必然查不到,还会白跑一次
// osascript(那段脚本没有 running 守卫,会把没开的 Music.app 拉起来)。

// albumPrefetchMaxTracks 是安全阀——防止专辑名字段被打上"整个作品集"这类离谱大合集
// (几十上百首)时,一次性炸出上百个并发解析请求。正常专辑几首到二十来首都远低于这个数,
// 不会被这个上限影响。
// 从 60 收到 30:闸门从"专辑名必须完全相等"放宽到"宽松包含"之后,这个上限
// 才真正开始起兜底作用 —— 放进来的可能是同一张专辑的加长版(Bad 25th Anniversary 24 首
// vs 原版 11 首)。正常专辑几首到二十来首,30 够用;超过的多半是合集,不值得为它一次性
// 炸出几十个解析请求。
const albumPrefetchMaxTracks = 30

// albumPrefetchStagger:加——预取这条路径本身就是"自己把自己打限流"最大的
// 放大器。neteaseThrottle(netease.go)那道 250ms 全局节流只挡住了"单个请求发得太快",
// 挡不住"这一批请求总量太大":换到一张全新专辑时,原来的写法是给最多 30 首曲目**各自**
// 立即起一个 goroutine 解析,越难匹配的歌触发的重试轮越多(实测《Can We Dance》一首在
// "标题反查轮"里就打了 6 次网易云请求),二十来首曲目里只要有几首难搜,几秒内堆起几十次
// 网易云请求毫不夸张——而且这些请求跟共享同一把 neteaseThrottle 锁,会把"正在播的这首"
// 自己的封面/歌词请求也一起排在后面堵住。
//
// 这里改成错峰:每起一个新曲目的解析 goroutine 前,让预取这条队列本身歇一段时间再起下一个
// (不影响"正在播的那首"的正常首次解析路径——那条不经过这里,该多快还多快)。间隔选得
// 比单首歌自己内部几轮重试加起来的耗时长一些,让前一首的网易云请求基本收尾了,下一首才
// 接上,不叠加峰值。专辑里的歌反正是按顺序听、要等几分钟才轮到下一首,预取慢几十秒起步
// 完全不影响"轮到时已经解析好"这个目的。
const albumPrefetchStagger = 3 * time.Second

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
		// 当前正在播的这首的宽松键 —— 用来把它从预取名单里剔掉。
		//
		// 从"两个字段逐字节相等"改成这个:曲目表跟播放器对同一首歌的拼法
		// 系统性不同(专辑名括号、中英文空格、繁简,以及多歌手串的分隔符 `A/B` vs
		// `A & B`),逐字节比几乎必然漏 —— 于是正在播的这首被当成"另一首"又预取一遍,
		// 在缓存里留下一条只差写法的重复条目(实测 Ticking Away 就是这么来的:那张专辑
		// 只有 1 首,预取队列里那一首正是它自己)。
		currentLoose := loosenEnrichKey(enrichKey(currentArtist, currentTitle, album))
		for _, t := range tracks {
			if t.title == "" || loosenEnrichKey(enrichKey(t.artist, t.title, album)) == currentLoose {
				continue // 当前正在播的这首已经走正常路径解析,不用重复触发
			}
			// 走 enrichKey 而不是自己拼:这条路径的曲目名来自**歌词平台**(网易云的曲目
			// 表),跟播放器报的拼法天然不一致 —— 播放器给 `不散的筵席（I Miss You）`、
			// 网易云给 `不散的筵席`,自己拼就等于每张专辑都预取出一批重复条目。
			key := enrichKey(t.artist, t.title, album)
			enrichMu.Lock()
			_, exists := enrichCache[key]
			if !exists {
				// 补上:预取是重复条目最大的产生源 —— 曲目名来自**网易云曲库**,
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
			if queued > 0 {
				// 只在真正要起下一个解析前才等——跳过的曲目(已解析/在途)不占错峰配额,
				// 不然一张大半已经解析过的专辑,光是跳过那些曲目就会被拖慢一路。
				time.Sleep(albumPrefetchStagger)
			}
			queued++
			// 专辑预取没有对应的"停止"入口(不是首次搜索占位行,没有 UI 可以取消它),
			// 见 backfillPeripheralFields 同款注释。
			// isNewTrack 传 false:预取的是同专辑里**没在播**的其它曲目,这一刻的设备
			// Now Playing 数据对应的是当前正在播的那首,不能拿来当这些曲目的封面——见
			// trackEnrichment 参数注释。
			go resolveEnrichAsync(withBackgroundOutbound(context.Background()), key, t.artist, t.title, album, "", t.duration, false)
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
	// neteaseSongID/neteaseAlbum:这条曲目在网易云上的歌曲 id 和专辑名,只有
	// neteaseAlbumTracks 这一个来源会填(Apple Music 本地资料库、搜索结果那两条来源
	// 都是 0/空)。给 resolveNeteaseInfo 的专辑锚定兜底用——那条路径要拿 id 直取歌词,
	// 不能只有标题文字(见 anchorAlbumTrackForLocalTitle 头注:标题文字拿去重搜正是
	// 召回失败的那条路)。
	neteaseSongID int64
	neteaseAlbum  string
}

// albumTracks 按当前播放器挑一个"这张专辑有哪些曲目"的来源,见文件头注释。
func albumTracks(artist, title, album, bundleID string) ([]albumTrack, bool) {
	if bundleID == appleMusicBundleID {
		// 资料库那份,加上目录里有、资料库没收的(applemusicalbum.go)。
		return appleMusicAlbumTracks(title, album)
	}
	// Spotify 先查客户端自己的元数据缓存(曲目名跟它报给系统的逐字一致,见 spotifyalbum.go),
	// 那张专辑没被客户端加载过才往下走网易云。
	if bundleID == spotifyBundleID {
		if tracks, ok := spotifyAlbumTracks(artist, title, album); ok {
			return tracks, true
		}
	}
	// QQ 音乐同理:问 QQ 自己的专辑曲目表(qqlocal.go qqAlbumTracks)。
	if bundleID == qqMusicBundleID {
		if tracks, ok := qqAlbumTracks(artist, title, album); ok {
			return tracks, true
		}
	}
	// 汽水同理:按这首的专辑 id 取汽水网页版的专辑曲目表(sodaalbum.go sodaAlbumTracks)。
	if bundleID == sodaMusicBundleID {
		if tracks, ok := sodaAlbumTracks(artist, title, album); ok {
			return tracks, true
		}
	}
	// 酷狗同理:按队列里这首的 hash 问酷狗自己的专辑曲目表(kugouqueue.go kugouAlbumTracks)。
	if bundleID == kugouMusicBundleID {
		if tracks, ok := kugouAlbumTracks(artist, title, album); ok {
			return tracks, true
		}
	}
	// 复用解析歌词时那次搜索的结果 —— neteaseLookup 带 30 天缓存,当前这首歌刚解析过,
	// 这里是缓存命中、零网络;拿到的 AlbumID 是**这首歌自己所属**的那张专辑。缓存命中
	// 路径不会真的发请求,没有可取消的对象,context.Background() 就够。
	// durationSecs 传 0:这条路径查的是"这首歌属于哪张专辑"(要 AlbumID),时长锚定档
	// 用不上也不该用 —— 预取时还没有真实播放时长。
	ne := neteaseLookup(context.Background(), artist, title, album, 0)
	if ne.AlbumID <= 0 {
		return nil, false
	}
	// 专辑名至少要"宽松包含"(albumScore >= 100)才预取。
	//
	// 修正过一次:这里原来要求满分 200(normLoose 后完全相等),理由是怕选到
	// 精选集。把三档分数真的量出来之后,那个担心站不住:
	//
	//   albumScore("神经志",                "神經志 The Journal")   = 100  —— 想要的
	//   albumScore("Bad",                   "Bad 25th Anniversary") = 100  —— 怕的
	//   albumScore("King of Pop [Box set]", "Bad")                  =   0  —— 最怕的,本来就进不来
	//
	// 真正灾难性的那种(76 首的合集、上百首的作品集)名字跟本地专辑毫不沾边,天然是 0 分,
	// 不需要 200 这道闸去挡。而 200 挡掉的全是"同一张专辑、写法不同"——繁简(normLoose
	// 已经归一)、带英文副标题、带 (Remastered) 后缀,这些在中文曲库里极其常见。实测:
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
	// 先判 running 再 tell:`tell application "Music"` 只要发出任何命令就会**启动**
	// Music.app —— 一个只用 Spotify/QQ 音乐的用户会被每换一张专辑就静默拉起一次 Apple
	// Music。本仓其它几段 Music/Spotify 脚本(getStateScript、spotifyPositionScript)
	// 开头都有同样的守卫,同一个理由。
	// `media kind is song` 把专辑里混的非歌曲轨道(演唱会/豪华版常见的 music video 花絮、
	// 纪录片)挡在 AppleScript 这一层——例如 Michael Jackson《XSCAPE
	// (Deluxe)》第 18/19 轨"XSCAPE Documentary"/"XSCAPE Documentary Outtakes"的
	// `media kind` 是 "music video" 不是 "song"（Apple 官方目录里 `kind` 字段也是
	// "music-video"），本来就没有歌词可言,预取会拿它们去问全部歌词源,注定全军覆没,
	// 还会占满 needsLyricsFirstFill 的重试配额、白白拖长退避周期。用 `is song` 白名单
	// 而不是拉黑名单排除 video/podcast/audiobook 等——防的是"漏收一种没想到的非歌曲媒体
	// 类型",而不是"漏挡一种已知的"。
	script := fmt.Sprintf(`if application "Music" is not running then
	return ""
end if
tell application "Music"
	set output to ""
	repeat with t in (every track of library playlist 1 whose album is %s and media kind is song)
		set output to output & (name of t) & tab & (artist of t) & tab & (duration of t) & linefeed
	end repeat
	return output
end tell`, appleScriptQuote(album))
	out, err := exec.CommandContext(ctx, "osascript", "-e", script).Output()
	if err != nil {
		return nil, false
	}
	return parseMusicAppAlbumTracks(string(out)), true
}

// parseMusicAppAlbumTracks 解 albumTracksFromMusicApp 那段脚本的输出:每行 名\t歌手\t时长(秒)。
// 时长解不出来记 0(按"未知"处理),不丢这一行。
func parseMusicAppAlbumTracks(out string) []albumTrack {
	var tracks []albumTrack
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) != 3 {
			continue
		}
		dur, _ := parseAppleScriptReal(parts[2])
		tracks = append(tracks, albumTrack{title: parts[0], artist: parts[1], duration: dur})
	}
	return tracks
}

// appleScriptQuote 把一个字符串安全地嵌进 AppleScript 双引号字符串字面量里——转义反斜杠
// 和双引号,防止专辑名里恰好带这两种字符时破坏脚本语法。
func appleScriptQuote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}

// parseAppleScriptReal 解析 AppleScript 里实数转成的文本(`x as text`、或拼进字符串)。
// 这个转换跟随系统地区的小数分隔符:德 / 法 / 俄等地区下 243.826 输出 "243,826"、
// 12345.5 输出 "1,23455E+4",直接交给 ParseFloat 会失败。实数文本不带千分位,
// 所以出现的逗号只可能是小数点。凡是从 osascript 输出里取实数都走这里;
// 要么就在脚本里先乘 1000 转成 integer(整数不受地区影响)。
func parseAppleScriptReal(s string) (float64, error) {
	return strconv.ParseFloat(strings.Replace(strings.TrimSpace(s), ",", ".", 1), 64)
}

// ---- 播放队列:接下来会播的几首(见 upcoming.go)----

// appleMusicUpcomingScript 是那段只读脚本,提出来只为让单测能照着它核对守卫还在。
//
// 三道守卫,少一道都会出事:
//   - `is not running` —— `tell application "Music"` 只要发出任何命令就会**启动**它,
//     一个只用 Spotify 的用户会被每换一首歌静默拉起一次 Apple Music(同
//     albumTracksFromMusicApp 那段)。
//   - `player state is stopped` —— 停着时 current track 还留着上一次的值,照着它预取
//     等于拿一批过期的歌去占解析带宽。
//   - `shuffle enabled` —— 开着随机播放时,Music.app **不暴露乱序后的顺序**,index+1
//     指的是资料库里的下一首、不是接下来会播的那首。直接放弃,退回同专辑预取。
//
// 还有一种拿不到的情况守卫不了、只能靠 try 兜:播 **Apple Music 目录**的内容(云端
// 歌单/电台/推荐)时 `current playlist` 直接报 -1728(对象不存在),而且那个歌单根本不在
// `playlists` 列表里 —— 脚本接口看不见云端内容。实测:播本地资料库的专辑时曲目 class 是
// `shared track`、current playlist 是「资料库」;播云端歌单时 class 变成 `URL track`、
// current playlist 直接没有。这一半覆盖不到,是 Apple Music 这条路的固有上限。
const appleMusicUpcomingScript = `if application "Music" is not running then
	return ""
end if
tell application "Music"
	if player state is stopped then return ""
	if shuffle enabled then return ""
	try
		set pl to current playlist
		set t to current track
		set i to index of t
	on error
		return ""
	end try
	set output to (name of t) & tab & (artist of t) & linefeed
	repeat with k from (i + 1) to (i + %d)
		try
			set tk to track k of pl
			set output to output & (name of tk) & tab & (artist of tk) & tab & (album of tk) & tab & (duration of tk) & linefeed
		end try
	end repeat
	return output
end tell`

// appleMusicUpcoming 从 Music.app 取接下来会播的几首:先问系统待播队列,取不到再走下面这段 AppleScript。
//
// AppleScript 这段不是真正的播放队列 —— Music.app 的脚本字典里**没有 Up Next**。这里是拿
// 「包含当前曲目的播放列表」+ 当前曲目的 index 往后数。两种情况都实测过:
//
//	从**本地歌单**播 —— current playlist 就是那个歌单(实测「米糕」5 首 user playlist、
//	index=2),index 是歌单内的位置,往后数得到的正是歌单顺序,跨专辑也对。
//
//	从**资料库**播 —— current playlist 是「资料库」,而它的内部顺序是 艺人 到 专辑 到
//	曲目号。按专辑顺序听时天然对(实测 586 是在播的那首、587~591 正是那张专辑的后续曲目,
//	自然切歌后 index 也确实递增);到专辑最后一首会跨去同艺人的下一张专辑,而 Music.app
//	实际多半是停止或转 Autoplay 推荐。猜错的代价只是白解析几首,不会出错,不为它再加判断。
func appleMusicUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	// 先读系统待播队列(applemusicqueue.go):真实播放顺序,开着随机也对。读不到才走下面的 AppleScript。
	if res, ok := appleMusicUpcomingFromSystemQueue(artist, title, n); ok {
		return res, true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "osascript", "-e", fmt.Sprintf(appleMusicUpcomingScript, n)).Output()
	if err != nil {
		return nil, false
	}
	return parseAppleMusicUpcoming(string(out), artist, title, n)
}

// parseAppleMusicUpcoming 解脚本的输出。跟 exec 那半分开是为了能测 —— AppleScript 那边
// 依赖真机上 Music.app 此刻的状态,单测里跑不了,而这半全是纯粹的字符串处理。
func parseAppleMusicUpcoming(out, artist, title string, n int) ([]upcomingTrack, bool) {
	lines := strings.Split(strings.ReplaceAll(out, "\r", ""), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) == "" {
		return nil, false // 三道守卫里任意一道拦下,或者 current playlist 读不到
	}
	// 第一行是脚本报回来的"它认为正在播的那首"。跟 poller 手上的那首核对上才算数 ——
	// 同其余四家:这一步防的是脚本与 MediaRemote 看到的不是同一个播放器。
	head := strings.SplitN(lines[0], "\t", 2)
	if len(head) != 2 || loosenEnrichKey(head[1]+"|"+head[0]) != loosenEnrichKey(artist+"|"+title) {
		return nil, false
	}
	res := make([]upcomingTrack, 0, n)
	for _, line := range lines[1:] {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 4)
		if len(parts) != 4 || parts[0] == "" {
			continue
		}
		dur, _ := parseAppleScriptReal(parts[3])
		res = append(res, upcomingTrack{
			artist: parts[1], title: parts[0], album: parts[2],
			// Music.app 的 duration 本来就是秒。
			duration: dur,
		})
		if len(res) == n {
			break
		}
	}
	return res, len(res) > 0
}
