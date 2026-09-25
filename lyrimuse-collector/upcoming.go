package main

import (
	"context"
	"log"
	"sync"
	"time"
)

// 预取「接下来会播的那几首」,而不是「同一张专辑里的其它曲目」。
//
// ## 为什么是两层,不是替换
//
// 队列是**播放器自己的私有状态**,只能一家一家去它的本地文件里读;而同专辑那条路
// (albumprefetch.go)按**歌词来源**分流 —— 拿网易云的专辑接口答"这张专辑有哪些歌",
// 对所有播放器通用。实测下来有两家拿不全队列:
//
//   Spotify      —— AppleScript 字典里只有单个 current track;但本机有「恢复播放状态」文件和
//                   元数据缓存,两份拼起来就是完整的上下文曲目表(见 spotifyqueue.go)。
//                   开着随机时放弃 —— 打乱后的顺序没查实。
//   Apple Music  —— 播本地资料库内容时能读(见 appleMusicUpcoming),但播 Apple Music
//                   目录的歌单/电台时 current playlist 直接报 -1728,而且那个歌单根本
//                   不在 playlists 列表里 —— 脚本接口看不见云端内容。
//   YouTube Music(网页)—— 读页面上的播放队列(见 ytmusicqueue.go),名字按账号语言本地化的那部分
//                   歌对不上播放器报的名字。
//   Spotify 网页版 —— 读网页播放器自己的队列接口(见 spotifyweb.go),名字跟 MediaSession 同源。
//
// 所以队列路径拿不到时**退回同专辑预取**,而不是什么都不做:这些情况恰恰会从"有预取"
// 退成"没有"。系统层面也没有兜底 —— MediaRemote 的导出符号里,队列相关的全是
// PlaybackQueueDataSource*(App 发布自己的队列)和 InsertSystemAppPlaybackQueue*(往
// 系统 App 队列里塞),GetNowPlaying* 系列只有 Info/Artwork/Client/Player/PlaybackState,
// 没有任何"读当前播放队列"的接口。别再去找那个通用方案了,它不存在。

// prefetchUpcomingCount 是往前看几首。
//
// 取 5 而不是"整条队列":队列动辄几十上百首(实测网易云 552、酷狗 100),而这条路径本身
// 就是"自己把自己打限流"最大的放大器(见 albumPrefetchStagger)。5 首足够覆盖"等真播到
// 那首时已经解析好"这个目的 —— 按每首 3~4 分钟算,5 首是往前看二十分钟。
const prefetchUpcomingCount = 5

// upcomingTrack 是队列里接下来会播的一首。
//
// 跟 albumTrack 分开而不是复用:那个结构假设整批曲目**同属一张专辑**(album 由调用方
// 统一传进来),而队列里每首歌的专辑各不相同,少这一个字段就会把整条队列的专辑名写成
// 当前这首的。
type upcomingTrack struct {
	artist, title, album string
	// duration 是秒;0 表示这个来源没给,交给解析路径自己去问。
	duration float64
}

// upcomingFromQueue 取这个播放器接下来会播的几首。
//
// ok=false 有两种含义,调用方不需要区分(都退回同专辑预取):这家播放器拿不到队列,或者
// 这一刻拿不准 —— 后者是常态,不是异常:队列文件可能停在上一次播放、当前这首可能根本
// 不在队列里(用户刚手点了另一首)、Apple Music 可能开着随机播放。**宁可退回也不硬撑**,
// 猜错的代价是预取一批不会播的歌,白占那条本就稀缺的解析带宽。
func upcomingFromQueue(artist, title, album, bundleID string, durationSecs float64, n int) ([]upcomingTrack, bool) {
	switch bundleID {
	case sodaMusicBundleID:
		// 推荐流与听歌模式的队列落在 QueueCache;歌单、专辑这类点播的队列不落盘,改看客户端预载了哪几首。
		if res, ok := sodaUpcoming(artist, title, n); ok {
			return res, true
		}
		return sodaUpcomingFromPreload(artist, title, n, time.Now())
	case qqMusicBundleID:
		return qqUpcoming(artist, title, n)
	case kugouMusicBundleID:
		return kugouUpcoming(artist, title, n)
	case neteaseMusicBundleID:
		return neteaseUpcoming(artist, title, n)
	case appleMusicBundleID:
		return appleMusicUpcoming(artist, title, n)
	case spotifyBundleID:
		return spotifyUpcoming(artist, title, n)
	}
	return browserUpcoming(artist, title, bundleID, durationSecs, n)
}

// browserQueueStatus 是浏览器里一路队列探针的结论。
type browserQueueStatus int

const (
	browserQueueUnavailable browserQueueStatus = iota // 不是能驱动的浏览器、没有这个网站的标签页、脚本失败、后面没有曲目
	browserQueueMismatch                              // 读到了队列,但页面上的当前这首跟播放器报的对不上
	browserQueueOK
)

type browserQueueResult struct {
	tracks []upcomingTrack
	status browserQueueStatus
	seen   string // status 为 browserQueueMismatch 时,页面上的当前这首(给日志用)
}

// browserQueueRetryDelay:页面上的当前这首跟播放器报的对不上时,隔多久重读一次。换歌那一拍网页的队列
// 高亮常常还停在上一首,MediaSession 已经换了。单测设成 0。
var browserQueueRetryDelay = 2 * time.Second

// browserUpcoming 是浏览器里的网页播放器那一支:YouTube Music(页面 DOM,见 ytmusicqueue.go)、Spotify
// 网页版(网页播放器自己的队列接口,见 spotifyweb.go)。两边都要「当前这首」对得上播放器报的才认,同时开着
// 两个标签页也不会读错;不是能驱动的浏览器(Firefox 等)时直接 ok=false。只要有一路是"对不上",隔
// browserQueueRetryDelay 重读一次;第二次仍对不上才记日志,换歌那一拍的时差不刷屏。
func browserUpcoming(artist, title, bundleID string, durationSecs float64, n int) ([]upcomingTrack, bool) {
	for attempt := 0; ; attempt++ {
		yt := ytmusicUpcoming(artist, title, bundleID, durationSecs, n)
		if yt.status == browserQueueOK {
			return yt.tracks, true
		}
		sp := spotifyWebUpcoming(artist, title, bundleID, n)
		if sp.status == browserQueueOK {
			return sp.tracks, true
		}
		if yt.status != browserQueueMismatch && sp.status != browserQueueMismatch {
			return nil, false
		}
		if attempt > 0 {
			for _, r := range []struct {
				name string
				res  browserQueueResult
			}{{"ytmusic", yt}, {"spotify web", sp}} {
				if r.res.status == browserQueueMismatch {
					log.Printf("%s upcoming: page is on %q, player reports %q; falling back to album prefetch", r.name, r.res.seen, artist+" - "+title)
				}
			}
			return nil, false
		}
		time.Sleep(browserQueueRetryDelay)
	}
}

var (
	upcomingMu sync.Mutex
	// lastUpcomingKey 是上一次真的起过预取的那首歌的 enrich key。
	//
	// 判据是**当前这首歌**,不是像同专辑那条路那样记专辑名:队列是动态的(用户随时
	// 会换歌单、汽水的推荐流每次还会续新的),同一条队列里换了首歌就该重新往前看 5 首。
	lastUpcomingKey string
)

// prefetchUpcoming 在真正换到一首新歌时调用,整个函数体在独立 goroutine 里跑。
//
// 队列拿得到就预取"接下来那几首",拿不到退回同专辑预取 —— 两层的理由见文件头注。
func prefetchUpcoming(currentArtist, currentTitle, album, bundleID string, durationSecs float64) {
	key := enrichKey(currentArtist, currentTitle, album)
	upcomingMu.Lock()
	if lastUpcomingKey == key {
		upcomingMu.Unlock()
		return // 同一首歌重复触发(暂停恢复、位置校正),上一轮该起的都起过了
	}
	lastUpcomingKey = key
	upcomingMu.Unlock()

	// 只有上面那把锁留在同步段。读队列要碰盘(网易云那份 1.3MB JSON、QQ 还要 exec 一次
	// plutil),放在 poller 的 handle() 线程上会把"正在播放"的推送一起拖住。
	go func() {
		tracks, ok := upcomingFromQueue(currentArtist, currentTitle, album, bundleID, durationSecs, prefetchUpcomingCount)
		if !ok {
			prefetchAlbumSiblings(currentArtist, currentTitle, album, bundleID)
			return
		}
		queueUpcomingEnrich(tracks)
	}()
}

// queueUpcomingEnrich 把这几首丢进后台解析,跟正常路径共用同一套 enrichCache/enrichInflight
// 去重 —— 真播到那首时不会重复解析。错峰间隔沿用 albumPrefetchStagger,理由同那边:
// 这条路径一次排一批,单首歌内部还会有好几轮重试,不错峰就会把"正在播的那首"自己的请求
// 也一起堵在同一把节流锁后面。
// upcomingNeedsResolve:这首还没解析过、也没在解析中(只读判断,不占位)。判据与 queueUpcomingEnrich 同一套 ——
// 精确键没命中再宽松找一次(理由见那边)。给「列表很大、只挑没解析过的补几首」的来源用(QQ 随机播放)。
func upcomingNeedsResolve(t upcomingTrack) bool {
	if t.title == "" {
		return false
	}
	key := enrichKey(t.artist, t.title, t.album)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if _, ok := enrichCache[key]; ok {
		return false
	}
	if _, ok := canonicalEnrichKey(key); ok {
		return false
	}
	_, inflight := looseInflightKey(key)
	return !inflight
}

func queueUpcomingEnrich(tracks []upcomingTrack) {
	queued := 0
	for _, t := range tracks {
		if t.title == "" {
			continue
		}
		key := enrichKey(t.artist, t.title, t.album)
		enrichMu.Lock()
		_, exists := enrichCache[key]
		if !exists {
			// 宽松再找一次:队列里的曲目名来自**播放器自己的曲库**,跟解析时写进缓存的
			// 拼法在繁简、中英文空格、多歌手分隔符上系统性不一致(同 albumprefetch.go
			// 那两段注释讲的坑)。精确没命中不等于没解析过。
			if _, found := canonicalEnrichKey(key); found {
				exists = true
			}
		}
		_, inflight := looseInflightKey(key)
		eligible := !exists && !inflight
		if eligible {
			enrichInflight[key] = true
		}
		enrichMu.Unlock()
		if !eligible {
			continue
		}
		if queued > 0 {
			// 只在真要起下一个之前才等 —— 跳过的(已解析/在途)不占错峰配额。
			time.Sleep(albumPrefetchStagger)
		}
		queued++
		// isNewTrack 传 false:这一刻的设备 Now Playing 数据对应的是**正在播的那首**,
		// 不能拿来当这些曲目的封面(同 albumprefetch.go 的调用点)。
		// 曲名先过 normEnrichTitle,跟 trackEnrichment 发起搜索用同一份查询词:key 里剥掉的尾括号
		// (「（合作音乐人:X）」这类)原样发给歌词源会全部落空,落下的空条目正好占着播放时的 key。
		go resolveEnrichAsync(withBackgroundOutbound(context.Background()), key, t.artist, normEnrichTitle(t.title), t.album, "", t.duration, false)
	}
	// 正常路径也打一行 —— 同专辑那条路当初只在"超上限被跳过"时打日志,于是"预取到底跑没跑"
	// 完全不可观测,排查时卡在过这一点上。
	log.Printf("upcoming prefetch: %d from queue, %d queued", len(tracks), queued)
}
