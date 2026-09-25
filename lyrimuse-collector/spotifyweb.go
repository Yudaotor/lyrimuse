package main

import (
	"context"
	"log"
	"strconv"
	"strings"
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
//
// ## 名字对得上
//
// 网页版设置 MediaSession 的代码(web-player 主包里 `new window.MediaMetadata({...})` 那段)是
// title=name、album=album.name、artist=artists 的名字用 `getSeparator()` 连起来,而那个分隔符除了阿拉伯语、
// 波斯语都是 ", "(中文界面也是)。队列项正好是同一份数据,所以这里拼出来的 key 跟真播到时逐字一致 ——
// 不像 YouTube Music 那样有本地化名字对不上的歌。

const spotifyWebHostMarker = "open.spotify.com"

// spotifyWebQueueJS:第一条记录是当前这首,之后按播放顺序(队列新鲜时是 queued、nextUp,快照过期时是
// getState().nextItems,取舍见文件头注)。记录之间 RS(0x1e),字段之间 US(0x1f),字段顺序 title、artist、
// album、毫秒、uri。只收曲目(uri 以 spotify:track: 开头)。找不到播放器接口返回 NOTFOUND。纪律同
// ytmusicQueueJS:不许双引号、不写反斜杠。
const spotifyWebQueueJS = `(function(){` +
	`var US = String.fromCharCode(31), RS = String.fromCharCode(30);` +
	`var el = document.querySelector('[data-testid=now-playing-widget]');` +
	`if (!el) return 'NOTFOUND';` +
	`var fk = Object.keys(el).filter(function(k){ return k.indexOf('__reactFiber') === 0; })[0];` +
	`var f = fk ? el[fk] : null, api = null;` +
	`while (f) { var p = f.memoizedProps; if (p && p.playerAPI && (typeof p.playerAPI.getQueue === 'function' || typeof p.playerAPI.getState === 'function')) { api = p.playerAPI; break; } f = f.return; }` +
	`if (!api) return 'NOTFOUND';` +
	`var s = typeof api.getState === 'function' ? api.getState() : null;` +
	`var live = s && s.item && String(s.item.uri || '').indexOf('spotify:track:') === 0 ? s.item : null;` +
	`var q = typeof api.getQueue === 'function' ? api.getQueue() : null;` +
	`var cur = null, rest = [];` +
	`if (q && q.current && (!live || String(q.current.uri || '') === String(live.uri))) { cur = q.current; rest = (q.queued || []).concat(q.nextUp || []); }` +
	`else if (live) { cur = live; rest = s.nextItems || []; }` +
	`if (!cur) return 'NOTFOUND';` +
	`var rec = function(t){ var arts = (t.artists || []).map(function(a){ return String(a.name || ''); }).join(', ');` +
	`return [String(t.name || ''), arts, String((t.album && t.album.name) || ''), String((t.duration && t.duration.milliseconds) || 0), String(t.uri || '')].join(US); };` +
	`var out = [rec(cur)];` +
	`rest.forEach(function(t){ if (t && String(t.uri || '').indexOf('spotify:track:') === 0) out.push(rec(t)); });` +
	`return out.join(RS);` +
	`})()`

type spotifyWebTrack struct {
	title, artist, album, uri string
	seconds                   float64
}

// parseSpotifyWebQueue 解 spotifyWebQueueJS 的输出:第一条是当前这首,其余按播放顺序。纯函数,可单测。
func parseSpotifyWebQueue(raw string) (current spotifyWebTrack, next []spotifyWebTrack, ok bool) {
	s := unwrapBrowserScriptOutput(raw)
	if s == "" || strings.Contains(s, "NOTFOUND") {
		return spotifyWebTrack{}, nil, false
	}
	flat := strings.NewReplacer("\n", " ", "\r", " ")
	for i, rec := range strings.Split(s, "\x1e") {
		f := strings.Split(rec, "\x1f")
		if len(f) != 5 {
			if i == 0 {
				return spotifyWebTrack{}, nil, false // 当前这首都解不开,整份不信
			}
			continue
		}
		ms, _ := strconv.ParseFloat(strings.TrimSpace(f[3]), 64)
		t := spotifyWebTrack{
			title:   strings.TrimSpace(flat.Replace(f[0])),
			artist:  strings.TrimSpace(flat.Replace(f[1])),
			album:   strings.TrimSpace(flat.Replace(f[2])),
			seconds: ms / 1000,
			uri:     strings.TrimSpace(f[4]),
		}
		if i == 0 {
			current = t
			continue
		}
		if t.title != "" && t.artist != "" {
			next = append(next, t)
		}
	}
	return current, next, current.title != ""
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

// spotifyWebQueueScript 真正去浏览器里跑队列探针的那一步。单测换成假的(TestMain 默认"读不到"),
// 测试进程绝不能去驱动本机真实的浏览器。
var spotifyWebQueueScript = func(bundleID, family string) (string, bool) {
	return runBrowserTabScript(context.Background(), bundleID, family, spotifyWebHostMarker, spotifyWebQueueJS)
}

// spotifyWebUpcoming 是 browserUpcoming 的一路,规则见文件头注。
func spotifyWebUpcoming(artist, title, bundleID string, n int) browserQueueResult {
	target := bundleID
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		target = owner
	}
	family := browserScriptFamily(target)
	if family == "" {
		return browserQueueResult{}
	}
	out, ok := spotifyWebQueueScript(target, family)
	if !ok {
		log.Printf("spotify web upcoming: browser script failed (%s)", target)
		return browserQueueResult{}
	}
	current, next, ok := parseSpotifyWebQueue(out)
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
