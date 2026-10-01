package main

import (
	"context"
	"log"
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
//   Apple Music → 问 Music.app 的本地资料库(由 App 代跑,见 appquery.go)。最准,因为曲目字符串跟播放器
//                 上报的逐字节一致,算出来的 enrich key 必然对得上。资料库里没收全的,按目录锚点
//                 的专辑 id 从 Apple 目录补(applemusicalbum.go)。
//   Spotify     到 客户端自己的元数据缓存(spotifyalbum.go),同样是播放器自己的写法;
//                 那张专辑没被客户端加载过时退回下一条。
//   QQ 音乐     到 QQ 自己的专辑曲目表(按播放列表归档里这首的 albumMid 问);问不到退回下一条。
//   酷狗        到 酷狗自己的专辑曲目表(按队列里这首的文件 hash 问专辑);问不到退回下一条。
//   汽水        到 汽水网页版的专辑分享页(按这首的专辑 id);问不到退回下一条。
//   其余播放器  → 用解析这首歌时命中的那个平台的专辑接口(目前:网易云)。
//
// 播放器自己的曲目表优先,是因为写进 enrich key 的歌名要跟它真播到时报的一致;歌词平台的曲目表
// 在繁简、大小写、版本后缀上常跟播放器不同,下面的宽松去重兜得住一部分,兜不住的就是白解析一首。
// Spotify 只走本地缓存、不走 Web API:在线接口要 OAuth 凭据,仓库里没有也不该硬编码。
// 网易云那条对任何播放器通用 —— 要的只是"这张专辑有哪些歌"。
//
// 每条来源都必须按 bundleID 挑:拿别家的专辑名去查 Music.app 资料库必然查不到,还白让 App 问一次 Music.app。

// albumPrefetchMaxTracks 是安全阀——防止专辑名字段被打上"整个作品集"这类离谱大合集
// (几十上百首)时,一次性炸出上百个并发解析请求。正常专辑几首到二十来首都远低于这个数,
// 不会被这个上限影响。
// 从 60 收到 30:闸门从"专辑名必须完全相等"放宽到"宽松包含"之后,这个上限
// 才真正开始起兜底作用 —— 放进来的可能是同一张专辑的加长版(Bad 25th Anniversary 24 首
// vs 原版 11 首)。正常专辑几首到二十来首,30 够用;超过的多半是合集,不值得为它一次性
// 炸出几十个解析请求。
const albumPrefetchMaxTracks = 30

// 预取一次只跑一首:上一首解析跑完(waitPrefetchResolved)才起下一首。预取这条路径是「自己把自己打限流」
// 最大的放大器 —— 一次排一整批,越难匹配的歌补查轮越多;几首叠在一起跑时,跟「正在播的那首」抢同一批
// 歌词源的配额和服务端限流,正在播的那首首轮要多等好几秒。按固定间隔错峰挡不住:单首解析 5～20 秒,
// 远长于间隔。顺序跑也让队列里排第一的那首(最可能下一首播到的)独占配额、最先解析完。见 09 章决策 102。
//
// prefetchResolveMaxWait:等上一首最多等这么久,到点照样起下一首,一首卡住不堵死整批。
var prefetchResolveMaxWait = 30 * time.Second // 变量只为单测能调短

// prefetchResolvePoll:等上一首时多久看一次它还在不在 enrichInflight 里。
const prefetchResolvePoll = 250 * time.Millisecond

// waitPrefetchResolved 等 key 这一轮解析结束(resolveEnrichAsync 收尾时把它移出 enrichInflight),
// 最多等 prefetchResolveMaxWait。
func waitPrefetchResolved(key string) {
	deadline := time.Now().Add(prefetchResolveMaxWait)
	for time.Now().Before(deadline) {
		enrichMu.Lock()
		running := enrichInflight[key]
		enrichMu.Unlock()
		if !running {
			return
		}
		time.Sleep(prefetchResolvePoll)
	}
}

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
		var prevKey string // 上一首起了解析的预取曲目,起下一首前等它跑完
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
			// claim=false 只看,claim=true 看完顺手占位。先只看一遍再等上一首(跳过的曲目不用等),等完在同一把锁里
			// 重查一遍才占位:等的这段(最长 prefetchResolveMaxWait)里用户可能已经切到这首,由正常路径接手解析 ——
			// 先占位的话正常路径看到「在途」就不起,正在播的这首要空等预取排到它,还拿不到设备封面、停不下来。
			eligible := func(claim bool) bool {
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
				ok := !exists && !inflight
				if ok && claim {
					enrichInflight[key] = true
				}
				enrichMu.Unlock()
				return ok
			}
			if !eligible(false) {
				continue // 已经解析过、或者已经有别的 goroutine 在解析,不重复起
			}
			if prevKey != "" {
				// 只在真正要起下一个解析前才等——跳过的曲目(已解析/在途)不用等,
				// 不然一张大半已经解析过的专辑,光是跳过那些曲目就会被拖慢一路。
				waitPrefetchResolved(prevKey)
			}
			if !eligible(true) {
				continue
			}
			queued++
			prevKey = key
			// 专辑预取没有对应的"停止"入口(不是首次搜索占位行,没有 UI 可以取消它),
			// 见 backfillPeripheralFields 同款注释。
			// isNewTrack 传 false:预取的是同专辑里**没在播**的其它曲目,这一刻的设备
			// Now Playing 数据对应的是当前正在播的那首,不能拿来当这些曲目的封面——见
			// trackEnrichment 参数注释。
			// 曲名先过 normEnrichTitle,理由同 upcoming.go 的调用点。
			go resolveEnrichAsync(withBackgroundOutbound(context.Background()), key, t.artist, normEnrichTitle(t.title), album, "", t.duration, false)
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
	// KKBOX 同理:缓存里有这张专辑的曲目表就用它的(kkboxalbum.go kkboxAlbumTracks);没有才往下走网易云,
	// 歌手改写成 KKBOX 的写法(见下面 return 那一行)。
	if bundleID == kkboxBundleID {
		if tracks, ok := kkboxAlbumTracks(artist, title); ok {
			return tracks, true
		}
	}
	// 复用解析歌词时那次搜索的结果 —— 当前这首歌刚按真实时长解析过,neteaseCachedLookup 不看缓存 key 里的时长,
	// 这里是缓存命中、零网络;拿到的 AlbumID 是**这首歌自己所属**的那张专辑。缓存里没有(还没解析完、网易云这一路
	// 关着)才真的去查一次,durationSecs 传 0:这条路径查的是"这首歌属于哪张专辑",预取时还没有真实播放时长。
	ne, cached := neteaseCachedLookup(artist, title, album)
	if !cached {
		ne = neteaseLookup(context.Background(), artist, title, album, 0)
	}
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
	tracks, ok := neteaseAlbumTracks(context.Background(), ne.AlbumID)
	if ok && bundleID == kkboxBundleID {
		tracks = kkboxAlbumTrackArtists(tracks, artist)
	}
	return tracks, ok
}

// albumTracksFromMusicApp 问 Music.app 本地资料库里这张专辑都有哪些曲目(名字 / 歌手 / 时长)。由 App 代跑
// (askApp;脚本与它的守卫在 App 侧 PlayerQueryServer.appleMusicAlbumTracksScript),不联网,Music.app 没在跑时
// 那段脚本直接返回空。任何一步失败都返回 ok=false,调用方直接放弃这次预取,不影响正常播放 / 解析路径。
func albumTracksFromMusicApp(album string) ([]albumTrack, bool) {
	out, ok := askApp(appQueryRequest{Kind: appQueryAppleMusicAlbumTracks, Album: album}, appQueryScriptTimeout)
	if !ok {
		return nil, false
	}
	return parseMusicAppAlbumTracks(out), true
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

// parseAppleScriptReal 解析 AppleScript 里实数转成的文本(`x as text`、或拼进字符串)。
// 这个转换跟随系统地区的小数分隔符:德 / 法 / 俄等地区下 243.826 输出 "243,826"、
// 12345.5 输出 "1,23455E+4",直接交给 ParseFloat 会失败。实数文本不带千分位,
// 所以出现的逗号只可能是小数点。凡是从 osascript 输出里取实数都走这里;
// 要么就在脚本里先乘 1000 转成 integer(整数不受地区影响)。
func parseAppleScriptReal(s string) (float64, error) {
	return strconv.ParseFloat(strings.Replace(strings.TrimSpace(s), ",", ".", 1), 64)
}

// ---- 播放队列:接下来会播的几首(见 upcoming.go)----

// appleMusicUpcoming 从 Music.app 取接下来会播的几首:先问系统待播队列,取不到再请 App 跑那段 AppleScript
// (PlayerQueryServer.appleMusicUpcomingScript,三道守卫与云端内容读不到的原因写在那边)。
//
// 那段 AppleScript 不是真正的播放队列 —— Music.app 的脚本字典里**没有 Up Next**。它是拿
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
	// 先读系统待播队列(applemusicqueue.go):真实播放顺序,开着随机也对。读不到才请 App 跑那段 AppleScript。
	if res, ok := appleMusicUpcomingFromSystemQueue(artist, title, n); ok {
		return res, true
	}
	out, ok := askApp(appQueryRequest{Kind: appQueryAppleMusicUpcoming, Count: n}, appQueryScriptTimeout)
	if !ok {
		return nil, false
	}
	return parseAppleMusicUpcoming(out, artist, title, n)
}

// parseAppleMusicUpcoming 解 App 回来的那段脚本输出:第一行是它认为正在播的那首(名\t歌手),其余每行
// 名\t歌手\t专辑\t时长(秒)。纯字符串处理,单测直接覆盖。
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
