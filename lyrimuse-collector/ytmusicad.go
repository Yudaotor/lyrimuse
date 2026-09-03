// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// YouTube Music 网页播放的「这是广告还是一首歌」判据(2026-09-02)。
//
// ## 为什么需要它
//
// 在此之前,浏览器里播 YouTube Music **压根不会被识别**(用户原话「为什么我现在用 chrome
// 播放的 YouTube music 不能识别到」)。原因不是 bug,是 `trustedPlaybackNotASong` 那道
// 防视频守卫:信任的非内置播放器,artist 或 album 有一个为空就整条丢掉。而 YouTube Music
// 经 MediaSession 报出来的 album **常常是空的**,于是被当成"浏览器里的视频"挡在门外。
//
// ⚠️ 是"常常"不是"总是"(2026-09-02 实测订正,初版注释写成了"恒为空"):同一个 Chrome 里
// 播 YT Music,「死神」「September」的 album 是空的,而「Bad」报的是
// `The Essential Michael Jackson`。所以这不是"YT Music 一律进不来",是"看运气"——报了专辑名
// 的那些本来就能进,这条复核是给报不出来的那些兜底。
//
// 那道守卫是 2026-08-21 定的,判据是四份真实样本里 album 唯一 100% 分得开歌与视频;注释
// 里当时就写明了代价:「电台/单曲场景下真音乐 App 若不报专辑名会被误挡……宁可漏认,不要
// 把视频写进永久收听历史」。YouTube Music 正好踩在这个代价上。
//
// ## 为什么不能简单地"给 music.youtube.com 免检 album"
//
// 因为 album 那一条**同时也在挡广告**。2026-09-02 抓了两条真实广告(成对采样,media-control
// 与页面 JS 同一时刻读):
//
//	22:00:42  title=「Liese Jelly to Bubble 全新登場!染髮新革命」 artist=KAO Hong Kong        album="" dur=30.021
//	22:01:14  title=「趁早把握出生頭3年腦部發育黃金期…」          artist=香港美贊臣 Mead Johnson album="" dur=20.001
//
// **artist 是非空的**(广告主的频道名)。所以免检 album 之后这两条会畅通无阻地被当成
// "KAO Hong Kong 的一首歌"收下 —— 跟仓库里已记录的 Spotify 事故同一个形态(用户曾在
// 「最近播放」看到 `Now Streaming on Hulu.` / `BLIZZARD® Double Flip Deal BOGO for 99¢`)。
//
// ⚠️ 别指望 `minTrackSecs = 30` 兜住:那条 Liese 广告是 **30.021 秒**,比 30 秒地板高
// 21 毫秒,照样过闸(打卡阈值 min(时长/2,240)=15s,播满就超)。YouTube 的标准 30 秒广告位
// 基本都会这样贴着线过去。
//
// ## 判据:问页面本身,不猜字段
//
// 跟 `spotifyCurrentTrackIsAd`(问 Spotify 本尊要 `spotify:ad:` 前缀)同一个思路 ——
// 字段启发式分不出来的事,去问权威来源。YouTube 没有对应的 AppleScript 接口,所以问的是
// 页面 DOM。2026-09-02 同一批成对采样里,**22 个连续样本、横跨两条不同广告**:
//
//	                        广告期间        真歌期间
//	  播放器 class 含 ad-showing   22/22 命中     0
//	  广告徽章元素存在              22/22 命中     0
//	  document.title              「YouTube Music」  「歌名 | YouTube Music」
//
// 三个信号各自都是干净的。三个都读、**任一命中就算广告**(不是取多数):这个方向的取舍
// 跟那道守卫本身一致 —— 误判成广告只是这首歌这一轮没被识别(下一轮轮询就自我纠正),
// 误判成歌是把广告永久写进 Last.fm(仓库注释原话:落进去之后「只能上网页一条条手删」)。
//
// `document.title` 那条已知有一个假阳性:页面刚加载、还没开始播时标题也是裸的
// 「YouTube Music」。接受它 —— 此刻本来也没有播放可言,而且下一轮就好。留着它是因为它
// 是另外两条的**兜底**:YouTube 哪天改了 class 名,这一条还在挡。
//
// ## 失败方向
//
// 探测失败(浏览器没开那道"允许来自 Apple 事件的 JavaScript"开关、标签页休眠、TCC 没给
// 这个进程自动化权限、超时)一律返回 unknown,调用方按 **fail-closed** 处理 —— 退回
// `trustedPlaybackNotASong` 的原判据,也就是"丢掉",跟这个功能不存在时完全一样。所以最坏
// 情况是"YouTube Music 仍然不被识别",而不是"广告漏进收听历史"。

// ytmusicAdVerdict 是三态,不是 bool —— "不知道"必须跟"是歌"分开,前者要 fail-closed。
type ytmusicAdVerdict int

const (
	ytmusicAdUnknown ytmusicAdVerdict = iota
	ytmusicAdIsAd
	ytmusicAdIsSong
)

const (
	ytmusicHostMarker = "music.youtube.com"
	// ytmusicAdProbeTimeout:整个 osascript 子进程的硬超时。Arc 在开关关着时是
	// **挂起不返回**(Chrome 则立刻抛错),脚本里的 `with timeout` 把挂起变成一个抓得住的
	// 错误,这里再兜最后一层 —— 两层都是照 Swift 侧 BrowserPositionProbe 的做法。
	ytmusicAdProbeTimeout = 6 * time.Second
	// ytmusicAdProbeEventTimeout 是 AppleScript `with timeout of N seconds` 的 N。
	ytmusicAdProbeEventTimeout = 4
)

// ytmusicAdProbeJS ——⚠️ **返回值绝不能含双引号**。`execute … javascript` 把 JS 返回的
// 字符串再包一层 AppleScript 字符串时,会把里面已有的双引号**真的**转义成反斜杠(不是
// 显示转义,是字符串本身多了真实的 `\`),等于整段被二次转义,拿去跟手写字面量比 contains
// 会稳定判 false。Swift 侧 youtubeMusicScript 为此专门放弃了 JSON.stringify,改用竖线
// 分隔的裸文本;这里照抄同一条纪律。
//
// ⚠️ 同理,JS 里的字符串字面量**只用单引号** —— 整段要嵌进 AppleScript 的双引号字符串。
//
// 返回 `a|b|c|album`:前三段各为 0/1(ad-showing / 广告徽章 / 裸标题),第四段是**页面上
// 读到的专辑名**(2026-09-03 加,可能为空)。判定留给 Go 侧(parseYTMusicAdProbe),这样
// 这条规则是可单测的,不是埋在一段没法跑测试的 JS 里。
// 页面上压根找不到播放器 → `NOTFOUND`,让调用方走 fail-closed。
//
// ⚠️ **专辑名必须放最后一段**:它是任意文本、理论上可以含 `|`,解析那边按"最多切 4 段"
// 切,第四段原样保留。
//
// ⚠️ 找专辑用**遍历 + indexOf**,不用 CSS 属性选择器 `a[href*=...]`:选择器里那个值含
// `/`,不加引号不是合法 CSS 标识符,而加引号只能加单引号 —— 单引号已经被外面那层 JS
// 字符串占了。认专辑靠 `browse/MPREb` 前缀:YouTube Music 的**专辑** browse id 一律以
// `MPREb_` 开头,歌手链接是 `channel/UC…`,所以既跟语言无关(不受 byline 里「2026年」这类
// 本地化后缀影响),也不会把歌手/播放量误当专辑。
const ytmusicAdProbeJS = `(function(){` +
	`var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');` +
	`var hasTime = !!document.querySelector('.time-info');` +
	`if (!p && !hasTime) return 'NOTFOUND';` +
	`var cls = p ? (p.className || '') : '';` +
	`var adShowing = cls.indexOf('ad-showing') >= 0 ? '1' : '0';` +
	`var badge = document.querySelector('.ytp-ad-badge, .ytp-ad-simple-ad-badge, .ytp-ad-text, .ytp-ad-preview-container') ? '1' : '0';` +
	`var t = (document.title || '').trim();` +
	`var bare = (t === 'YouTube Music') ? '1' : '0';` +
	`var bl = document.querySelectorAll('ytmusic-player-bar .byline a');` +
	`var album = '';` +
	`for (var i = 0; i < bl.length; i++) {` +
	`var h = bl[i].getAttribute('href') || '';` +
	`if (h.indexOf('browse/MPREb') >= 0) { album = (bl[i].textContent || '').trim(); break; }` +
	`}` +
	`return adShowing + '|' + badge + '|' + bare + '|' + album;` +
	`})()`

// browserScriptFamily 回答"这个 bundle id 该用哪种 AppleScript 方言"。
//
// 清单与 Swift 侧 BrowserAutomationPermission 保持一致(Chromium 系三家 + Safari);
// 别的浏览器(Firefox 等没有提供脚本命令的)返回空串,调用方静默跳过 —— 跟 Swift 侧
// `family` 返回 nil 时的处理一致,不特意报"不支持"。
func browserScriptFamily(bundleID string) string {
	switch bundleID {
	case "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser":
		return "chromium"
	case "com.apple.Safari":
		return "safari"
	default:
		return ""
	}
}

// parseYTMusicAdProbe 把探针的裸文本输出解成"判定 + 页面上读到的专辑名"。纯函数,可单测。
//
// 三个标志任一为 1 就算广告,理由见文件头注(误判成广告只丢一轮,误判成歌是永久污染)。
// 形状不认识(空、NOTFOUND、段数不够、前三段非 0/1)一律 unknown —— 不猜。
//
// ⚠️ 只切 4 段(SplitN):第四段是专辑名,是任意文本、可能自带 `|`,原样保留。用普通 Split
// 的话专辑名里一个竖线就会让整条读数退化成"形状不对",连带把广告判定一起丢掉。
// 段数只有 3(旧形状)照样解得出,专辑为空。
//
// ⚠️ 跟 Swift 侧 `YouTubeMusicAdProbe.parse` 是同一套语义,两边必须同时改。
func parseYTMusicAdProbe(raw string) (ytmusicAdVerdict, string) {
	s := strings.TrimSpace(raw)
	// AppleScript 有时会把返回值再包一层双引号,脱掉。
	s = strings.Trim(s, "\"")
	s = strings.TrimSpace(s)
	if s == "" || strings.Contains(s, "NOTFOUND") {
		return ytmusicAdUnknown, ""
	}
	parts := strings.SplitN(s, "|", 4)
	if len(parts) < 3 {
		return ytmusicAdUnknown, ""
	}
	ad := false
	for _, p := range parts[:3] {
		switch strings.TrimSpace(p) {
		case "1":
			ad = true
		case "0":
			// 正常
		default:
			return ytmusicAdUnknown, "" // 形状不对,不做任何推断
		}
	}
	album := ""
	if len(parts) == 4 {
		// 专辑名里的换行压平:osascript 的输出是按行读的,真混进换行会让下游的日志/比较
		// 莫名其妙。压平放在这儿而不是 JS 里 —— JS 那边写 `\s` 要用反斜杠,而整段 JS 嵌在
		// AppleScript 的双引号字符串里,反斜杠是那边的转义字符。
		album = strings.NewReplacer("\n", " ", "\r", " ").Replace(parts[3])
		album = strings.TrimSpace(album)
	}
	verdict := ytmusicAdIsSong
	if ad {
		verdict = ytmusicAdIsAd
	}
	return verdict, album
}

// parseYTMusicAdVerdict 是只要判定那一半的薄封装(既有调用点和单测用)。
func parseYTMusicAdVerdict(raw string) ytmusicAdVerdict {
	v, _ := parseYTMusicAdProbe(raw)
	return v
}

// ytmusicAlbumPatch 回答"要不要拿探针读到的专辑名去补上游那份、补成什么"。
// 返回空串 = 不动上游那份。⚠️ 跟 Swift 侧 `YouTubeMusicAdProbe.albumPatch` 同一套判据。
//
// 2026-09-03 加。起因是用户报「YouTube Music 播一张专辑的时候,第一首歌怎么不上送专辑名」。
// 当场抓的实测(两张不同专辑、四个采样)坐实那是 **YouTube Music 自己的疏漏**:它开一条新
// 队列时在专辑上下文解析出来之前就把 MediaSession 元数据设好了,之后不再刷新这一首,所以
// 页面 byline 上后来有了专辑名、MediaSession 里那份却永远停在空;第二首起就带上了。
// (完整的四行实测表在 Swift 侧 `YouTubeMusicAdProbe.albumPatch` 的注释里,含那条证明
// "规律是队列第一首、不是专辑名与曲名同名去重"的关键反例。)
//
// 三条同时成立才补:
//   - 上游报的是空(**非空一律不动** —— 上游那份是权威,探针只补缺、不做纠正);
//   - 探针读到了非空;
//   - 这一条被判定成**歌**。广告没有专辑,而广告期间 byline 上读到的多半是上一首歌的残留。
func ytmusicAlbumPatch(reported string, verdict ytmusicAdVerdict, probed string) string {
	if strings.TrimSpace(reported) != "" {
		return ""
	}
	if verdict != ytmusicAdIsSong {
		return ""
	}
	return strings.TrimSpace(probed)
}

// buildYTMusicAdAppleScript 逐项照 Swift 侧 BrowserPositionProbe.buildAppleScript 的写法:
//   - `tell application id "<bundleID>"` 而不是写死 App 名字(实测对三家 Chromium 系和
//     Safari 都有效,不受"App 被改名/装了变体版本"影响);
//   - 先扫各窗口的**当前**标签页,再退回全量标签页扫描;
//   - 每次执行都套 `with timeout`(把 Arc 那种"挂起不返回"变成抓得住的错误)+ 裸
//     `try…end try`(吞掉错误继续找下一个标签页)。
func buildYTMusicAdAppleScript(bundleID, family string) string {
	var activeTab, executeActive, executeTab string
	switch family {
	case "chromium":
		activeTab = "active tab of window wi"
		executeActive = "execute (active tab of window wi) javascript \"" + ytmusicAdProbeJS + "\""
		executeTab = "execute (tab ti of window wi) javascript \"" + ytmusicAdProbeJS + "\""
	case "safari":
		activeTab = "current tab of window wi"
		executeActive = "do JavaScript \"" + ytmusicAdProbeJS + "\" in current tab of window wi"
		executeTab = "do JavaScript \"" + ytmusicAdProbeJS + "\" in tab ti of window wi"
	default:
		return ""
	}
	t := strconv.Itoa(ytmusicAdProbeEventTimeout)
	return "tell application id \"" + bundleID + "\"\n" +
		"\tset winCount to count of windows\n" +
		"\trepeat with wi from 1 to winCount\n" +
		"\t\ttry\n" +
		"\t\t\tif (URL of " + activeTab + ") contains \"" + ytmusicHostMarker + "\" then\n" +
		"\t\t\t\twith timeout of " + t + " seconds\n" +
		"\t\t\t\t\tset r to " + executeActive + "\n" +
		"\t\t\t\tend timeout\n" +
		"\t\t\t\tif r does not contain \"NOTFOUND\" then\n" +
		"\t\t\t\t\treturn r\n" +
		"\t\t\t\tend if\n" +
		"\t\t\tend if\n" +
		"\t\tend try\n" +
		"\tend repeat\n" +
		"\trepeat with wi from 1 to winCount\n" +
		"\t\tset tabCount to count of tabs of window wi\n" +
		"\t\trepeat with ti from 1 to tabCount\n" +
		"\t\t\ttry\n" +
		"\t\t\t\tif (URL of tab ti of window wi) contains \"" + ytmusicHostMarker + "\" then\n" +
		"\t\t\t\t\twith timeout of " + t + " seconds\n" +
		"\t\t\t\t\t\tset r to " + executeTab + "\n" +
		"\t\t\t\t\tend timeout\n" +
		"\t\t\t\t\tif r does not contain \"NOTFOUND\" then\n" +
		"\t\t\t\t\t\treturn r\n" +
		"\t\t\t\t\tend if\n" +
		"\t\t\t\tend if\n" +
		"\t\t\tend try\n" +
		"\t\tend repeat\n" +
		"\tend repeat\n" +
		"\treturn \"NOTFOUND\"\n" +
		"end tell\n"
}

// 一次探测的结果按曲目身份缓存。
//
// 为什么要缓存:这道判定挂在 `trustedPlaybackNotASong` 会拒的那条路上,而真 YouTube Music
// 歌曲的 album 常常是空的,所以这些歌播放期间**每一轮轮询**都会走到这里。一次 AppleScript 往返
// 实测 ~0.9s(见 Swift 侧 BrowserPositionProbe 的实测记录),每 5 秒烧 0.9s 不值当。
//
// 按曲目身份缓存是**安全**的:广告在 media-control 里是一条**独立的 now-playing 条目**
// (自己的 title/artist/duration,实测如此),换成广告身份就变了、缓存自然失效。
const ytmusicAdMaxAge = 60 * time.Second

var (
	ytmusicAdMu    sync.Mutex
	ytmusicAdKey   string
	ytmusicAdVal   ytmusicAdVerdict
	ytmusicAdAlbum string
	ytmusicAdAt    time.Time
)

// ytmusicAdProbe 判断"此刻这个浏览器里的 YouTube Music 播的是广告还是歌"。
//
// trackKey 是曲目身份(见上面缓存那段注释),用来复用同一首歌/同一条广告的判定结果。
func ytmusicAdProbe(ctx context.Context, bundleID, trackKey string) (ytmusicAdVerdict, string) {
	// Safari 的播放报的是媒体代理进程,要换回宿主 App 才驱得动它(见 mediaProxyOwners)。
	target := bundleID
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		target = owner
	}
	family := browserScriptFamily(target)
	if family == "" {
		return ytmusicAdUnknown, ""
	}

	cacheKey := target + "\x00" + trackKey
	ytmusicAdMu.Lock()
	if ytmusicAdKey == cacheKey && time.Since(ytmusicAdAt) < ytmusicAdMaxAge {
		v, al := ytmusicAdVal, ytmusicAdAlbum
		ytmusicAdMu.Unlock()
		return v, al
	}
	ytmusicAdMu.Unlock()

	v, album := runYTMusicAdProbe(ctx, target, family)

	ytmusicAdMu.Lock()
	// unknown 不进缓存:那多半是"这一下没读到"(超时/标签页刚好在切),下一轮该重试,
	// 缓存住它等于把一次偶发失败按整首歌的时长放大。
	if v != ytmusicAdUnknown {
		ytmusicAdKey, ytmusicAdVal, ytmusicAdAlbum, ytmusicAdAt = cacheKey, v, album, time.Now()
	}
	ytmusicAdMu.Unlock()
	return v, album
}

// runYTMusicAdProbe 真正起 osascript。
//
// ⚠️ 脚本**写进临时文件**再执行,不用 `osascript -e`:这段 AppleScript 里嵌着一整段 JS、
// JS 里又有单引号和逗号,拿 -e 传要在 shell/exec 层再套一层引号,是本仓库明确记过的
// "多层引号把 payload 打坏"那类坑。写文件是零转义的。
func runYTMusicAdProbe(ctx context.Context, bundleID, family string) (ytmusicAdVerdict, string) {
	script := buildYTMusicAdAppleScript(bundleID, family)
	if script == "" {
		return ytmusicAdUnknown, ""
	}
	f, err := os.CreateTemp("", "lyrimuse-ytmusic-ad-*.applescript")
	if err != nil {
		return ytmusicAdUnknown, ""
	}
	path := f.Name()
	defer os.Remove(path)
	if _, err := f.WriteString(script); err != nil {
		f.Close()
		return ytmusicAdUnknown, ""
	}
	if err := f.Close(); err != nil {
		return ytmusicAdUnknown, ""
	}

	ctx, cancel := context.WithTimeout(ctx, ytmusicAdProbeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", filepath.Clean(path)).Output()
	if err != nil {
		// 失败原因很多(开关没开、TCC 没给权限、超时、浏览器没在跑),一律 unknown。
		// 只在 debug 级别记一句:这条路径每首歌都会走,失败时不该刷屏。
		return ytmusicAdUnknown, ""
	}
	return parseYTMusicAdProbe(string(out))
}

// trustedPlaybackRejected 是 `trustedPlaybackNotASong` 的"带 YouTube Music 广告复核"版本,
// 也是**调用方该用的那一个**。
//
// 为什么不直接改 `trustedPlaybackNotASong`:那个函数是纯的、无 ctx、无副作用,而且跟
// Swift 侧 `TrustedPlayers.notASong` 是逐字对应的一套语义(那边注释写着"两侧必须同时改")。
// 把一次 AppleScript 往返塞进去会让它既不纯又没法单测,还会让两侧的"同一套语义"失真。
// 所以基础判据原样不动,复核作为**外面一层**加上去。
//
// 复核只在一种情况下发生:基础判据要拒、而且**唯一的理由是 album 为空**(artist 非空)。
//   - artist 为空 → 一律拒,不复核。真曲目必有歌手,而这也挡住了"广告连频道名都没报"那档,
//     省掉一次 AppleScript 往返。
//   - 复核结果 isSong → 放行(这就是 YouTube Music 终于能被识别的那一步)。
//   - isAd 或 unknown → 拒。**unknown 也拒**是刻意的 fail-closed,见文件头注。
//
// 第二个返回值是**要补给上游的专辑名**(空串 = 不用补),见 ytmusicAlbumPatch。这条复核
// 本来就只在"album 为空"时才发生,正好是需要补的那一刻,顺路带回来不多花一次 AppleScript。
func trustedPlaybackRejected(ctx context.Context, bundleID, artist, album, title string) (bool, string) {
	if !trustedPlaybackNotASong(bundleID, artist, album) {
		return false, ""
	}
	if strings.TrimSpace(artist) == "" {
		return true, ""
	}
	trackKey := strings.TrimSpace(artist) + "\x00" + strings.TrimSpace(title)
	verdict, probedAlbum := ytmusicAdProbe(ctx, bundleID, trackKey)
	switch verdict {
	case ytmusicAdIsSong:
		return false, ytmusicAlbumPatch(album, verdict, probedAlbum)
	case ytmusicAdIsAd:
		// 值得记一句:这是"我们主动挡掉了一条广告",跟"读不到"不是一回事,
		// 排查"为什么这首没被识别"时这一行能直接分开两种情况。
		log.Printf("ytmusic: 判定为广告,不采纳(%s - %s)", artist, title)
		return true, ""
	default:
		return true, ""
	}
}
