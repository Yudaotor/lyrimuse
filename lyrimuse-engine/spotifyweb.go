package main

import (
	"log"
	"sync"
)

// Spotify 网页版(open.spotify.com)的「接下来会播的那几首」:读网页播放器自己的队列。
//
// ## 数据从哪来
//
// 网页版不把队列落盘(localStorage 里只有界面偏好),桌面客户端那份 context_player_state_restore 也不跟着
// 网页版的播放走(实测解析不出当前这首)。队列面板要点开才渲染,「正在播放」侧栏底部只挂一张「队列中的下一首歌」
// 卡片。但页面里的 React 组件树上有一个组件带着 `playerAPI` 属性,它的 `getQueue()` **同步**返回
// `{current, queued, nextUp}`:`queued` 是用户手动加进队列的(先放),`nextUp` 是播放上下文里接下来的
// (随机时就是打乱后的顺序,跟队列面板显示的一致),每一项都带 uri、name、album.name、artists[].name、
// duration.milliseconds。实测一份歌单 48 首。从 `now-playing-widget` 的 React fiber 往上找就能摸到它。
//
// `getQueue()` 会停在某一刻的快照上不再更新(实测一个标签页开着放了几个小时,它一直返回最早那首和那一批
// 后续曲目),而同一个对象的 `getState()` 是实时的:`item` 是正在放的这首,`nextItems` 是接下来的(通常只有
// 一首,放完歌单进入自动续播时本来也只知道下一首)。所以以 `getState()` 为准:两边当前这首的 uri 相同才用
// `getQueue()` 的整份队列,不同就改用 `getState()` 的 item + nextItems。
//
// 只读:不点任何按钮、不改界面,读完即走。这是网页内部结构,改版了读不到就 ok=false,退回同专辑预取。
// 读页面这一步由 App 代跑(往标签页注入一段只读 JS,见 appquery.go 与 App 侧 PlayerQueryServer.spotifyWebQueueJS),
// 读出来的记录也由 App 整理好(PlayerQueryTracks)。
//
// ## 名字对得上
//
// 网页版设置 MediaSession 的代码(web-player 主包里 `new window.MediaMetadata({...})` 那段)是
// title=name、album=album.name、artist=artists 的名字用 `getSeparator()` 连起来,而那个分隔符除了阿拉伯语、
// 波斯语都是 ", "(中文界面也是)。队列项正好是同一份数据,所以这里拼出来的 key 跟真播到时逐字一致 ——
// 不像 YouTube Music 那样有本地化名字对不上的歌。

type spotifyWebTrack struct {
	title, artist, album, uri string
	seconds                   float64
}

// spotifyWebQueueFrom:App 交来的队列(PlayerQueryTracks.spotifyWebQueue 整理好的:current 是当前这首,tracks 按播放顺序;
// 队列新鲜时是 queued、nextUp,快照过期时是 getState().nextItems,取舍见文件头注)换成这边的形状,后面没有歌名或歌手的
// 丢掉。没有当前这首就不认。纯函数,可单测。
func spotifyWebQueueFrom(r appQueryTracks) (current spotifyWebTrack, next []spotifyWebTrack, ok bool) {
	if r.Current == nil || r.Current.Title == "" {
		return spotifyWebTrack{}, nil, false
	}
	convert := func(t appQueryTrack) spotifyWebTrack {
		return spotifyWebTrack{title: t.Title, artist: t.Artist, album: t.Album, uri: t.URI, seconds: t.Duration}
	}
	for _, t := range r.Tracks {
		if t.Title != "" && t.Artist != "" {
			next = append(next, convert(t))
		}
	}
	return convert(*r.Current), next, true
}

// pickSpotifyWebUpcoming:网页版的当前这首要对得上播放器报的(歌名,或歌手+歌名),否则不信它的队列 ——
// 典型情形是同一个浏览器里 Spotify 网页版停着、正在放的是别的网站。纯函数,可单测。
func pickSpotifyWebUpcoming(current spotifyWebTrack, next []spotifyWebTrack, artist, title string, n int) ([]upcomingTrack, bool) {
	if !spotifyWebCurrentMatches(current, artist, title) {
		return nil, false
	}
	res := make([]upcomingTrack, 0, n)
	for _, t := range next {
		if len(res) == n {
			break
		}
		res = append(res, upcomingTrack{artist: t.artist, title: t.title, album: t.album, duration: t.seconds})
	}
	return res, len(res) > 0
}

// spotifyWebCurrentMatches:网页版的当前这首跟播放器报的是不是同一首(歌名,或歌手+歌名)。
func spotifyWebCurrentMatches(current spotifyWebTrack, artist, title string) bool {
	return loosenEnrichKey(current.title) == loosenEnrichKey(title) ||
		loosenEnrichKey(current.artist+"|"+current.title) == loosenEnrichKey(artist+"|"+title)
}

var spotifyWebLogOnce sync.Once

// spotifyWebQueueScript 读这个浏览器里 Spotify 网页播放器的队列,由 App 代跑并整理好(askAppTracks):这个浏览器能不能
// 驱动、用哪种脚本方言都由 App 判。单测换成假的(TestMain 默认"读不到")。
var spotifyWebQueueScript = func(bundleID string) (appQueryTracks, bool) {
	return askAppTracks(appQueryRequest{Kind: appQueryBrowserQueue, BundleID: bundleID, Platform: browserPlatformSpotifyWeb}, appQueryScriptTimeout)
}

// spotifyWebUpcoming 是 browserUpcoming 的一路,规则见文件头注。
func spotifyWebUpcoming(artist, title, bundleID string, n int) browserQueueResult {
	target := bundleID
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		target = owner
	}
	if !browserPlatformPaired(browserPlatformSpotifyWeb, target) {
		return browserQueueResult{}
	}
	r, ok := spotifyWebQueueScript(target)
	if !ok {
		log.Printf("spotify web upcoming: browser script failed (%s)", target)
		return browserQueueResult{}
	}
	current, next, ok := spotifyWebQueueFrom(r)
	if !ok {
		return browserQueueResult{} // 没有 Spotify 标签页是常态(在放别的网站),不记
	}
	if !spotifyWebCurrentMatches(current, artist, title) {
		return browserQueueResult{status: browserQueueMismatch, seen: current.artist + " - " + current.title}
	}
	res, ok := pickSpotifyWebUpcoming(current, next, artist, title, n)
	if !ok {
		return browserQueueResult{} // 对得上但后面没有曲目了
	}
	spotifyWebLogOnce.Do(func() {
		log.Printf("spotify web upcoming: reading the play queue from the web player (%d tracks)", len(next))
	})
	return browserQueueResult{tracks: res, status: browserQueueOK}
}
