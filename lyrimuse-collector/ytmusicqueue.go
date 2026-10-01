package main

import (
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
// 以及 longBylineText「歌手 • 专辑 • 年份」—— 专辑那一段带 `MPREb_` 开头的 browseId,跟语言无关地认得出来。
// 面板收着的时候这份 DOM 也在,实测 50 首的队列全部读得到。读页面这一步由 App 代跑(往标签页注入一段只读 JS,
// 见 appquery.go 与 App 侧 PlayerQueryServer.youTubeMusicQueueJS)。
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

type ytmusicQueueItem struct {
	selected                      bool
	title, artist, album, videoID string
	seconds                       float64
	// musicVideo:这一首是 MV(OMV / UGC)。它的 lengthText 是视频长度,不是歌的长度。
	musicVideo bool
}

// ytmusicIsMusicVideoType:这个类型的时长算不算"视频的长度"而不是"歌的长度"。
// 白名单:OMV = 官方 MV,UGC = 用户上传(现场、翻唱、带画面的搬运,时长同样不是录音室版的)。
// ATV(歌曲版)、空串(读不到)和其余类型一律按歌处理 —— 认不准时保持现状,不误伤。
func ytmusicIsMusicVideoType(vt string) bool {
	switch vt {
	case "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC":
		return true
	}
	return false
}

// parseYTMusicQueue 解那段队列 JS 的输出:每首一条记录,记录之间 RS(0x1e)、字段之间 US(0x1f),字段顺序
// selected(0/1)、title、artist、album、lengthText、videoId、musicVideoType(读不到为空,认 MV 的白名单见
// ytmusicIsMusicVideoType);找不到队列是 NOTFOUND。歌名、专辑名是任意文本,所以用控制字符分隔。
// 字段数不对、没有歌名的记录跳过。纯函数,可单测。
func parseYTMusicQueue(raw string) []ytmusicQueueItem {
	s := unwrapBrowserScriptOutput(raw)
	if s == "" || strings.Contains(s, "NOTFOUND") {
		return nil
	}
	flat := strings.NewReplacer("\n", " ", "\r", " ")
	var items []ytmusicQueueItem
	for _, rec := range strings.Split(s, "\x1e") {
		f := strings.Split(rec, "\x1f")
		if len(f) != 6 && len(f) != 7 {
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
		if len(f) == 7 {
			it.musicVideo = ytmusicIsMusicVideoType(strings.TrimSpace(f[6]))
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
	// 高亮对不上(换歌那一拍它常常还停在上一首):队列里重名的歌是常态(重复曲目、电台回流、不同歌手的
	// 「Home」「Intro」),取第一个命中会把已经播过的那首当成当前、交出去的「接下来」全是播过的。
	// 先认歌手+歌名都对得上的;只剩歌名对得上的不止一条时,认高亮之后的第一条(高亮停在上一首时
	// 当前这首就在它后面),没有高亮可参照就不猜。
	selected := -1
	for i, it := range items {
		if !it.selected {
			continue
		}
		if selected >= 0 {
			selected = -2 // 不止一条 selected,当没有参照
			break
		}
		selected = i
	}
	var full, byTitle []int
	for i, it := range items {
		if loosenEnrichKey(it.artist+"|"+it.title) == wantFull {
			full = append(full, i)
		}
		if matches(it) {
			byTitle = append(byTitle, i)
		}
	}
	for _, cands := range [][]int{full, byTitle} {
		if len(cands) == 1 {
			return cands[0]
		}
		if len(cands) > 1 {
			if selected >= 0 {
				for _, i := range cands {
					if i > selected {
						return i
					}
				}
			}
			return -1
		}
	}
	if durationSecs <= 0 {
		return -1
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
			continue // 没有歌手的多半是视频 / 用户上传,真播到时 App 也不认它是歌(TrustedPlayers.notASong)
		}
		// MV 的时长交给歌词解析按「未知」处理,跟真播到时一致(snapshot.lyricsDurationSecs)。拿视频长度去打分会把
		// 长度相近的另一个版本(混音 / 加长版)选上、把原版判成负分,条目落盘后播放时缓存命中就换不回来。
		duration := it.seconds
		if it.musicVideo {
			duration = 0
		}
		res = append(res, upcomingTrack{artist: it.artist, title: it.title, album: it.album, duration: duration})
	}
	return res, len(res) > 0
}

// unwrapBrowserScriptOutput 处理浏览器 JS 探针的原始输出(两个队列探针共用)。
//
// Chromium 系的 `execute … javascript` 有时把返回的字符串再包一层双引号、并把里面的双引号转义成真的反斜杠
// (见 App 侧 BrowserTabProbeScript 头注);Safari 的 `do JavaScript` 原样返回。歌名、专辑名里带双引号很常见
// (实测「I Knew It, I Knew You - From "Toy Story 5"」),所以**只在整段首尾都是双引号时**才当成被包了一层:
// 去掉外层、把 `\"` 还原。不能无条件 Trim 掉首尾引号 —— 那会把以引号开头的歌名削掉一个字符。
func unwrapBrowserScriptOutput(raw string) string {
	s := strings.TrimSpace(raw)
	if len(s) >= 2 && strings.HasPrefix(s, `"`) && strings.HasSuffix(s, `"`) {
		s = strings.ReplaceAll(s[1:len(s)-1], `\"`, `"`)
	}
	return strings.TrimSpace(s)
}

var ytmusicQueueLogOnce sync.Once

// ytmusicQueueScript 读这个浏览器里 YouTube Music 页面的队列,由 App 代跑(askApp)。family 只用于调用方先判能不能驱动。
// 单测换成假的(TestMain 默认"读不到")。
var ytmusicQueueScript = func(bundleID, _ string) (string, bool) {
	return askApp(appQueryRequest{Kind: appQueryBrowserQueue, BundleID: bundleID, Platform: browserPlatformYouTubeMusic}, appQueryScriptTimeout)
}

// ytmusicUpcoming 是 browserUpcoming 的一路:在这个浏览器里找 YouTube Music 标签页读队列。
// bundleID 是播放器报上来的那个(Safari 报的是媒体代理进程,这里换回宿主)。
func ytmusicUpcoming(artist, title, bundleID string, durationSecs float64, n int) browserQueueResult {
	target := bundleID
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		target = owner
	}
	family := browserScriptFamily(target)
	if family == "" || !browserPlatformPaired(browserPlatformYouTubeMusic, target) {
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
