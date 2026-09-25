package main

import (
	"context"
	"log"
	"math"
	"strings"
	"sync"
)

// YouTube Music 网页播放的「接下来会播的那几首」:直接读页面上的播放队列。
//
// ## 数据从哪来
//
// 队列面板(`ytmusic-player-queue`)里每一首是一个 `ytmusic-player-queue-item`,它的 `data` 属性就是
// InnerTube 下发的 playlistPanelVideoRenderer:videoId、title、lengthText、`selected`(此刻在播的那首),
// 以及 longBylineText「歌手 • 专辑 • 年份」—— 专辑那一段带 `MPREb_` 开头的 browseId,跟语言无关地认得出来
// (同 ytmusicAdProbeJS 找专辑的办法)。面板收着的时候这份 DOM 也在,实测 50 首的队列全部读得到。
// 页面里开了随机,YouTube Music 是把这份列表**本身**打乱,所以按页面顺序往后取就是真实的下一首。
//
// 同一首歌有「歌曲版 / 视频版」两份时,替身那份包在 `#counterpart-renderer` 里、不在播放顺序上,跳过。
//
// ## 名字对不对得上
//
// 预解析的 enrich key 要跟真播到时播放器报的(MediaSession)一致才用得上。实测已经播过、还留在队列头上的
// 4 首里 3 首一字不差(含专辑);对不上的那首是「陶喆 - 飞机场的10.30」,MediaSession 报的是
// 「David Tao - Airport in 10:30」—— 同一个视频,队列按账号语言显示本地化的名字,MediaSession 用的是另一份。
// 这种歌预解析会白做,真播到时照常现解析,不比没有这条路差。匿名 InnerTube 的 player 端点也给不出
// MediaSession 那份(曹格那首它给「Gary Chaw」,MediaSession 报「曹格」),所以不绕路,就用队列本身。
//
// ## 当前这首怎么定
//
// 优先认 `selected` 那一条,但要它的歌名或「歌手+歌名」跟播放器报的对得上;对不上再在整份队列里按名字找。
// 名字都对不上时(队列按账号语言本地化,如 MediaSession 报「David Tao - Airport in 10:30」、队列里是
// 「陶喆 - 飞机场的10.30」),唯一那条 `selected` 的时长跟播放器报的相差不超过
// ytmusicSelectedDurationToleranceSecs 也认。都不成立就判"对不上"退回同专辑预取 —— 典型情形是用户在同一个
// 浏览器里改放别的网站,YouTube Music 那个标签页还停着,它的 `selected` 是上次那首,不能拿它的队列来预取。

// ytmusicSelectedDurationToleranceSecs:名字对不上时,`selected` 那条与播放器报的时长最多差多少秒仍认它。
// lengthText 只到秒,MediaSession 带小数。
const ytmusicSelectedDurationToleranceSecs = 2.0

// ytmusicQueueJS 读队列。返回值:每首一条记录,记录之间用 RS(0x1e),字段之间用 US(0x1f),
// 字段顺序 selected(0/1)、title、artist、album、lengthText、videoId。找不到队列返回 NOTFOUND。
//
// 跟 ytmusicAdProbeJS 同样的纪律:不许有双引号(整段要嵌进 AppleScript 的双引号字符串),也不写反斜杠
// (那是 AppleScript 字符串的转义字符)—— 分隔符因此用 String.fromCharCode 现造。歌名、专辑名是任意文本,
// 用控制字符分隔才不会撞上。
const ytmusicQueueJS = `(function(){` +
	`var US = String.fromCharCode(31), RS = String.fromCharCode(30);` +
	`var items = document.querySelectorAll('ytmusic-player-queue-item');` +
	`if (!items.length) return 'NOTFOUND';` +
	`var text = function(o){ return (o && o.runs) ? o.runs.map(function(r){ return String(r.text || ''); }).join('') : ''; };` +
	`var out = [];` +
	`for (var i = 0; i < items.length; i++) {` +
	`var el = items[i];` +
	`if (el.closest('#counterpart-renderer')) continue;` +
	`var d = el.data;` +
	`if (!d) continue;` +
	`var runs = (d.longBylineText && d.longBylineText.runs) || [];` +
	`var artist = [], album = '', afterSep = false;` +
	`for (var j = 0; j < runs.length; j++) {` +
	`var t = String(runs[j].text || '');` +
	`var be = runs[j].navigationEndpoint && runs[j].navigationEndpoint.browseEndpoint;` +
	`var id = be ? String(be.browseId || '') : '';` +
	`if (id.indexOf('MPREb') === 0) { album = t; }` +
	`if (t.trim() === '•') { afterSep = true; continue; }` +
	`if (!afterSep) artist.push(t);` +
	`}` +
	`var sel = (d.selected || el.hasAttribute('selected')) ? '1' : '0';` +
	`out.push([sel, text(d.title), artist.join(''), album, text(d.lengthText), String(d.videoId || '')].join(US));` +
	`}` +
	`return out.length ? out.join(RS) : 'NOTFOUND';` +
	`})()`

type ytmusicQueueItem struct {
	selected                      bool
	title, artist, album, videoID string
	seconds                       float64
}

// parseYTMusicQueue 解 ytmusicQueueJS 的输出。字段数不对、没有歌名的记录跳过。纯函数,可单测。
func parseYTMusicQueue(raw string) []ytmusicQueueItem {
	s := unwrapBrowserScriptOutput(raw)
	if s == "" || strings.Contains(s, "NOTFOUND") {
		return nil
	}
	flat := strings.NewReplacer("\n", " ", "\r", " ")
	var items []ytmusicQueueItem
	for _, rec := range strings.Split(s, "\x1e") {
		f := strings.Split(rec, "\x1f")
		if len(f) != 6 {
			continue
		}
		it := ytmusicQueueItem{
			selected: strings.TrimSpace(f[0]) == "1",
			title:    strings.TrimSpace(flat.Replace(f[1])),
			artist:   strings.TrimSpace(flat.Replace(f[2])),
			album:    strings.TrimSpace(flat.Replace(f[3])),
			seconds:  ytmusicParseDurationText(f[4]),
			videoID:  strings.TrimSpace(f[5]),
		}
		if it.title == "" {
			continue
		}
		items = append(items, it)
	}
	return items
}

// ytmusicQueueCurrent 定位此刻在播的那首,规则见文件头注。找不到返回 -1。durationSecs 是播放器报的时长,
// 0 表示不知道(此时不走时长兜底)。
func ytmusicQueueCurrent(items []ytmusicQueueItem, artist, title string, durationSecs float64) int {
	wantTitle := loosenEnrichKey(title)
	wantFull := loosenEnrichKey(artist + "|" + title)
	matches := func(it ytmusicQueueItem) bool {
		return loosenEnrichKey(it.title) == wantTitle || loosenEnrichKey(it.artist+"|"+it.title) == wantFull
	}
	for i, it := range items {
		if it.selected && matches(it) {
			return i
		}
	}
	for i, it := range items {
		if matches(it) {
			return i
		}
	}
	if durationSecs <= 0 {
		return -1
	}
	selected := -1
	for i, it := range items {
		if !it.selected {
			continue
		}
		if selected >= 0 {
			return -1 // 不止一条 selected,不猜
		}
		selected = i
	}
	if selected >= 0 && items[selected].seconds > 0 &&
		math.Abs(items[selected].seconds-durationSecs) <= ytmusicSelectedDurationToleranceSecs {
		return selected
	}
	return -1
}

// pickYTMusicUpcoming 取当前这首之后的 n 首。纯函数,可单测。
func pickYTMusicUpcoming(items []ytmusicQueueItem, artist, title string, durationSecs float64, n int) ([]upcomingTrack, bool) {
	pos := ytmusicQueueCurrent(items, artist, title, durationSecs)
	if pos < 0 {
		return nil, false
	}
	res := make([]upcomingTrack, 0, n)
	for i := pos + 1; i < len(items) && len(res) < n; i++ {
		it := items[i]
		if it.artist == "" {
			continue // 没有歌手的多半是视频 / 用户上传,真播到时也过不了 trustedPlaybackNotASong
		}
		res = append(res, upcomingTrack{artist: it.artist, title: it.title, album: it.album, duration: it.seconds})
	}
	return res, len(res) > 0
}

// unwrapBrowserScriptOutput 处理浏览器 JS 探针的原始输出(两个队列探针共用)。
//
// Chromium 系的 `execute … javascript` 有时把返回的字符串再包一层双引号、并把里面的双引号转义成真的反斜杠
// (见 ytmusicAdProbeJS 的注释);Safari 的 `do JavaScript` 原样返回。歌名、专辑名里带双引号很常见
// (实测「I Knew It, I Knew You - From "Toy Story 5"」),所以**只在整段首尾都是双引号时**才当成被包了一层:
// 去掉外层、把 `\"` 还原。不能像广告探针那样无条件 Trim 掉首尾引号 —— 那会把以引号开头的歌名削掉一个字符。
func unwrapBrowserScriptOutput(raw string) string {
	s := strings.TrimSpace(raw)
	if len(s) >= 2 && strings.HasPrefix(s, `"`) && strings.HasSuffix(s, `"`) {
		s = strings.ReplaceAll(s[1:len(s)-1], `\"`, `"`)
	}
	return strings.TrimSpace(s)
}

var ytmusicQueueLogOnce sync.Once

// ytmusicQueueScript 真正去浏览器里跑队列探针的那一步。单测换成假的:测试进程绝不能去驱动本机真实的浏览器
// (TestMain 默认就把它换成"读不到")。
var ytmusicQueueScript = func(bundleID, family string) (string, bool) {
	return runBrowserTabScript(context.Background(), bundleID, family, ytmusicHostMarker, ytmusicQueueJS)
}

// ytmusicUpcoming 是 browserUpcoming 的一路:在这个浏览器里找 YouTube Music 标签页读队列。
// bundleID 是播放器报上来的那个(Safari 报的是媒体代理进程,这里换回宿主)。
func ytmusicUpcoming(artist, title, bundleID string, durationSecs float64, n int) browserQueueResult {
	target := bundleID
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		target = owner
	}
	family := browserScriptFamily(target)
	if family == "" {
		return browserQueueResult{}
	}
	out, ok := ytmusicQueueScript(target, family)
	if !ok {
		log.Printf("ytmusic upcoming: browser script failed (%s)", target)
		return browserQueueResult{}
	}
	items := parseYTMusicQueue(out)
	if len(items) == 0 {
		return browserQueueResult{} // 没有 YouTube Music 标签页是常态,不记
	}
	res, ok := pickYTMusicUpcoming(items, artist, title, durationSecs, n)
	if !ok {
		if ytmusicQueueCurrent(items, artist, title, durationSecs) >= 0 {
			return browserQueueResult{} // 当前这首找到了,只是后面没有能取的曲目
		}
		return browserQueueResult{status: browserQueueMismatch, seen: ytmusicSelectedLabel(items)}
	}
	ytmusicQueueLogOnce.Do(func() {
		log.Printf("ytmusic upcoming: reading the play queue from the YouTube Music page (%d tracks)", len(items))
	})
	return browserQueueResult{tracks: res, status: browserQueueOK}
}

// ytmusicSelectedLabel 是页面上 `selected` 那条的「歌手 - 歌名」,给对不上时的日志用。
func ytmusicSelectedLabel(items []ytmusicQueueItem) string {
	for _, it := range items {
		if it.selected {
			return it.artist + " - " + it.title
		}
	}
	return "(nothing selected)"
}
