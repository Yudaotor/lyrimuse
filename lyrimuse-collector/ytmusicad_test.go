package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

// parseYTMusicAdVerdict 是这条链路上唯一做判断的地方(JS 只负责读三个标志、不做判定,
// 正是为了让判定能在这里被单测),所以它的边界要钉死。
func TestParseYTMusicAdVerdict(t *testing.T) {
	cases := []struct {
		name, raw string
		want      ytmusicAdVerdict
	}{
		// 2026-09-02 实测:广告期间三个标志同时命中(22/22 连续样本,横跨两条不同广告)。
		{"真实广告样本(三条全中)", "1|1|1", ytmusicAdIsAd},
		// 真歌期间三条全灭。
		{"真实歌曲样本(三条全灭)", "0|0|0", ytmusicAdIsSong},
		// 任一命中就算广告 —— 取舍见 ytmusicad.go 头注(误判成广告只丢一轮,误判成歌是
		// 永久写进 Last.fm)。这三条也是"YouTube 改了某个 class 名"时的兜底路径。
		{"只有 ad-showing 命中", "1|0|0", ytmusicAdIsAd},
		{"只有广告徽章命中", "0|1|0", ytmusicAdIsAd},
		{"只有裸标题命中", "0|0|1", ytmusicAdIsAd},
		// 页面上找不到播放器 → 不知道,调用方 fail-closed。
		{"NOTFOUND", "NOTFOUND", ytmusicAdUnknown},
		{"空输出", "", ytmusicAdUnknown},
		{"只有空白", "   \n", ytmusicAdUnknown},
		// 形状不认识一律不猜。
		{"字段数不对(2 个)", "1|0", ytmusicAdUnknown},
		// ⚠️ 2026-09-03 起第四段是**专辑名**(任意文本),所以 4 段是合法形状,不再 unknown。
		// 专辑名那一半单独在 TestParseYTMusicAdProbeAlbum 里钉。
		{"4 段:第四段是专辑名,不影响判定", "1|0|0|某专辑", ytmusicAdIsAd},
		{"非 0/1", "1|x|0", ytmusicAdUnknown},
		{"true/false 不认", "true|false|false", ytmusicAdUnknown},
		// AppleScript 有时把返回值再包一层双引号。
		{"带外层引号的广告", "\"1|1|1\"", ytmusicAdIsAd},
		{"带外层引号+换行的歌曲", "\"0|0|0\"\n", ytmusicAdIsSong},
	}
	for _, c := range cases {
		if got := parseYTMusicAdVerdict(c.raw); got != c.want {
			t.Errorf("%s: parseYTMusicAdVerdict(%q) = %v, want %v", c.name, c.raw, got, c.want)
		}
	}
}

func TestBrowserScriptFamily(t *testing.T) {
	chromium := []string{"com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser"}
	for _, id := range chromium {
		if got := browserScriptFamily(id); got != "chromium" {
			t.Errorf("%s 应该是 chromium, got %q", id, got)
		}
	}
	if got := browserScriptFamily("com.apple.Safari"); got != "safari" {
		t.Errorf("Safari 方言判错: %q", got)
	}
	// 没有提供脚本命令的浏览器(以及一切非浏览器)返回空串 → 调用方静默跳过,
	// 跟 Swift 侧 family 返回 nil 的处理一致。
	for _, id := range []string{"org.mozilla.firefox", "com.apple.Music", "", "com.whatever.app"} {
		if got := browserScriptFamily(id); got != "" {
			t.Errorf("%q 不该有方言, got %q", id, got)
		}
	}
}

// 生成的 AppleScript 有几条硬约束,写错了不会编译报错、只会在运行时静默失败。
func TestBuildYTMusicAdAppleScript(t *testing.T) {
	for _, family := range []string{"chromium", "safari"} {
		s := buildYTMusicAdAppleScript("com.google.Chrome", family)
		if s == "" {
			t.Fatalf("%s: 生成了空脚本", family)
		}
		// 用 bundle id 而不是写死 App 名字(照 Swift 侧 BrowserPositionProbe 的做法:
		// 不受"App 被改名/装了变体版本"影响)。
		if !strings.Contains(s, `tell application id "com.google.Chrome"`) {
			t.Errorf("%s: 应该用 `tell application id`", family)
		}
		// 只在 music.youtube.com 的标签页上执行 —— 普通 YouTube 视频不受这条链路影响。
		if !strings.Contains(s, ytmusicHostMarker) {
			t.Errorf("%s: 没有按 %s 过滤标签页", family, ytmusicHostMarker)
		}
		// `with timeout` 是把 Arc 那种"挂起不返回"变成抓得住的错误的唯一手段(裸 try
		// 抓不住挂起),两处执行点都必须有。
		if n := strings.Count(s, "with timeout of"); n != 2 {
			t.Errorf("%s: `with timeout` 出现 %d 次, want 2", family, n)
		}
		if n := strings.Count(s, "end timeout"); n != 2 {
			t.Errorf("%s: `end timeout` 出现 %d 次, want 2", family, n)
		}
		// 超时秒数必须来自那个常量,不能是另写的字面量(这一条 2026-09-02 真的写错过一次:
		// 常量之外又硬编码了一个 "4",两处会漂)。
		if !strings.Contains(s, "with timeout of 4 seconds") {
			t.Errorf("%s: 超时秒数没有跟常量对齐", family)
		}
		// try…end try 吞掉单个标签页的错误、继续找下一个。
		if strings.Count(s, "end try") < 2 {
			t.Errorf("%s: 缺少 try…end try 包裹", family)
		}
		if !strings.Contains(s, `return "NOTFOUND"`) {
			t.Errorf("%s: 没有兜底返回 NOTFOUND", family)
		}
	}

	// 两种方言的执行语句不能搞混。
	chromium := buildYTMusicAdAppleScript("com.google.Chrome", "chromium")
	safari := buildYTMusicAdAppleScript("com.apple.Safari", "safari")
	if !strings.Contains(chromium, "javascript \"") {
		t.Error("chromium 应该用 `execute … javascript`")
	}
	if strings.Contains(chromium, "do JavaScript") {
		t.Error("chromium 不该出现 Safari 的 `do JavaScript`")
	}
	if !strings.Contains(safari, "do JavaScript") {
		t.Error("safari 应该用 `do JavaScript`")
	}
	if strings.Contains(safari, "execute (") {
		t.Error("safari 不该出现 Chromium 的 `execute (…) javascript`")
	}
	// 不认识的方言返回空串,调用方据此跳过。
	if s := buildYTMusicAdAppleScript("com.google.Chrome", "gecko"); s != "" {
		t.Errorf("未知方言应返回空串, got %d 字节", len(s))
	}
}

// ⚠️ 这一条守的是本仓库明确记过的坑:`execute … javascript` 会把 JS 返回值里已有的双引号
// **真的**转义成反斜杠,整段被二次转义,拿去比 contains 会稳定判 false。所以 JS 源码里
// 不许出现双引号(它整段要嵌进 AppleScript 的双引号字符串),返回值也不含双引号。
func TestYTMusicAdProbeJSHasNoDoubleQuotes(t *testing.T) {
	if strings.Contains(ytmusicAdProbeJS, "\"") {
		t.Error("JS 源码里出现了双引号 —— 嵌进 AppleScript 会被打坏(见 ytmusicad.go 头注)")
	}
	// 三个信号都得在,少一个就是悄悄削弱了判据。
	// 后两个是 2026-09-03 加的专辑名读取(Swift 侧 selftest 有同款守卫,两边同时改)。
	for _, marker := range []string{"ad-showing", "ytp-ad-badge", "YouTube Music", "NOTFOUND",
		"browse/MPREb", "ytmusic-player-bar"} {
		if !strings.Contains(ytmusicAdProbeJS, marker) {
			t.Errorf("JS 里缺少 %q", marker)
		}
	}
	// 返回的是三段竖线分隔的裸文本。
	if !strings.Contains(ytmusicAdProbeJS, "+ '|' +") {
		t.Error("JS 应该返回竖线分隔的裸文本")
	}
}

// trustedPlaybackRejected 的分流:哪些情况会去做一次 AppleScript 复核,哪些不会。
func TestTrustedPlaybackRejectedShortCircuits(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	const chrome = "com.google.Chrome"
	features.TrustedPlayers = map[string]string{chrome: "Google Chrome"}
	resetYTMusicAdCacheForTest(t)

	// ① 内置播放器压根不进这条路(基础判据第一行就 return false)。
	if rejected, _ := trustedPlaybackRejected(context.Background(), "com.apple.Music", "", "", ""); rejected {
		t.Error("内置播放器不该被这条守卫拒掉")
	}

	// ② 两个字段都齐全 → 基础判据本来就放行,不该触发任何复核。
	rejected, patch := trustedPlaybackRejected(context.Background(), chrome, "周杰伦", "七里香", "枫")
	if rejected {
		t.Error("artist+album 齐全的不该被拒")
	}
	// 上游已经报了专辑名,这条路一个字都不该补(而且它根本没去复核)。
	if patch != "" {
		t.Errorf("上游有专辑名时不该给补丁, got %q", patch)
	}

	// ③ artist 为空 → 直接拒,**不做**复核(真曲目必有歌手;这一档也省掉一次 AppleScript
	//    往返)。用一个会让复核必然超时的 ctx 来证明"没走复核":真去复核的话这里会慢。
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	start := time.Now()
	if rejected, _ := trustedPlaybackRejected(ctx, chrome, "", "", "某广告"); !rejected {
		t.Error("artist 为空该直接拒")
	}
	if el := time.Since(start); el > 200*time.Millisecond {
		t.Errorf("artist 为空这一档不该发起 AppleScript(耗时 %v)", el)
	}

	// ④ 只有 album 空、artist 非空 → 会去复核。已取消的 ctx ⇒ 复核必然失败 ⇒ unknown
	//    ⇒ **fail-closed 拒掉**。这一条正是"读不到时不许放广告进来"的守卫。
	rejected2, patch2 := trustedPlaybackRejected(ctx, chrome, "KAO Hong Kong", "", "Liese Jelly to Bubble 全新登場")
	if !rejected2 {
		t.Error("复核读不到时必须 fail-closed 拒掉,不能放行")
	}
	// 被拒的那条不该顺带给出专辑名补丁 —— 它压根不会被采纳。
	if patch2 != "" {
		t.Errorf("被拒时不该给补丁, got %q", patch2)
	}
}

// 第四段:页面上读到的专辑名(2026-09-03)。
//
// 起因是用户报「YouTube Music 播一张专辑时,第一首歌不上送专辑名」——实测坐实那是 YT Music
// 自己的疏漏(队列第一首的 MediaSession 里 album 恒空,页面 byline 上却有),见
// ytmusicAlbumPatch 的注释。⚠️ 跟 Swift 侧 selftest 那一组是同一批用例,两边同时改。
func TestParseYTMusicAdProbeAlbum(t *testing.T) {
	cases := []struct {
		name, raw, want string
	}{
		{"读到专辑名", "0|0|0|Already Gone", "Already Gone"},
		{"页面上没读到 → 空串(不是解析失败)", "0|0|0|", ""},
		{"只有三段(旧形状)也解得出", "0|0|0", ""},
		// ⚠️ 专辑名是任意文本、可以自带分隔符。SplitN 保证第四段原样保留 —— 用普通 Split
		// 的话这条会退化成"形状不对",连带把广告判定一起丢掉。
		{"专辑名里自带 | 原样保留", "0|0|0|A|B", "A|B"},
		{"第四段是文本不是标志位", "1|0|0|0", "0"},
		{"两端空白削掉", "0|0|0|  Already Gone  ", "Already Gone"},
		// osascript 的输出按行读,专辑名里真混进换行会让下游日志/比较莫名其妙。
		{"中间换行压成空格", "0|0|0|Already\nGone", "Already Gone"},
		{"NOTFOUND 没有专辑名", "NOTFOUND", ""},
		{"形状不对时不给专辑名", "1|x|0|某专辑", ""},
	}
	for _, c := range cases {
		if _, got := parseYTMusicAdProbe(c.raw); got != c.want {
			t.Errorf("%s: parseYTMusicAdProbe(%q) album = %q, want %q", c.name, c.raw, got, c.want)
		}
	}
}

// 补不补、补成什么。三条同时成立才补。⚠️ 跟 Swift 侧 YouTubeMusicAdProbe.albumPatch
// 是同一套判据,两边同时改。
func TestYTMusicAlbumPatch(t *testing.T) {
	cases := []struct {
		name, reported string
		verdict        ytmusicAdVerdict
		probed, want   string
	}{
		{"上游报空 + 是歌 + 探针有值 → 补", "", ytmusicAdIsSong, "Already Gone", "Already Gone"},
		{"上游全是空白同样算空", "   ", ytmusicAdIsSong, "Already Gone", "Already Gone"},
		// ⚠️ 上游报了就一律不动 —— 探针只补缺、不做纠正。第二首起 MediaSession 自己有
		// 专辑名,那份是权威(而页面 byline 在换歌那一瞬间可能还停在上一首)。
		{"上游已有专辑名 → 一个字都不动", "The Essential Michael Jackson", ytmusicAdIsSong, "别的", ""},
		// ⚠️ 广告不补:广告没有专辑,byline 上读到的多半是上一首歌的残留。
		{"判定是广告 → 不补", "", ytmusicAdIsAd, "Already Gone", ""},
		{"还没探到 → 不补", "", ytmusicAdUnknown, "Already Gone", ""},
		{"探针读到的是空白 → 不补", "", ytmusicAdIsSong, "   ", ""},
	}
	for _, c := range cases {
		if got := ytmusicAlbumPatch(c.reported, c.verdict, c.probed); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// 缓存按曲目身份走:同一首歌复用,换了曲目(广告是独立的 now-playing 条目)自然失效。
func TestYTMusicAdCacheKeyedByTrack(t *testing.T) {
	resetYTMusicAdCacheForTest(t)
	ytmusicAdMu.Lock()
	ytmusicAdKey = "com.google.Chrome\x00Queen\x00Another One Bites The Dust"
	ytmusicAdVal = ytmusicAdIsSong
	ytmusicAdAt = time.Now()
	ytmusicAdMu.Unlock()

	ctx := context.Background()
	// 同一身份命中缓存,不发起 AppleScript(用极短 ctx 证明:真去跑会失败成 unknown)。
	shortCtx, cancel := context.WithTimeout(ctx, time.Nanosecond)
	defer cancel()
	if got, _ := ytmusicAdProbe(shortCtx, "com.google.Chrome", "Queen\x00Another One Bites The Dust"); got != ytmusicAdIsSong {
		t.Errorf("同一曲目该命中缓存, got %v", got)
	}
	// 缓存里的专辑名也要一起复用 —— 否则同一首歌每一轮都要重探才拿得到专辑名。
	ytmusicAdMu.Lock()
	ytmusicAdAlbum = "A Night at the Opera"
	ytmusicAdMu.Unlock()
	if _, al := ytmusicAdProbe(shortCtx, "com.google.Chrome", "Queen\x00Another One Bites The Dust"); al != "A Night at the Opera" {
		t.Errorf("命中缓存时该带回专辑名, got %q", al)
	}
	// 换成广告那条身份 → 缓存不命中 → 走真探测 → 这里必然失败成 unknown。
	if got, _ := ytmusicAdProbe(shortCtx, "com.google.Chrome", "KAO Hong Kong\x00Liese"); got != ytmusicAdUnknown {
		t.Errorf("换曲目该绕过缓存, got %v", got)
	}
	// 过期之后同一身份也要重探。
	ytmusicAdMu.Lock()
	ytmusicAdAt = time.Now().Add(-ytmusicAdMaxAge - time.Second)
	ytmusicAdMu.Unlock()
	if got, _ := ytmusicAdProbe(shortCtx, "com.google.Chrome", "Queen\x00Another One Bites The Dust"); got != ytmusicAdUnknown {
		t.Errorf("缓存过期该重探, got %v", got)
	}
}

// unknown 不进缓存 —— 那多半是一次偶发失败,缓存住它等于把它按整首歌的时长放大。
func TestYTMusicAdUnknownNotCached(t *testing.T) {
	resetYTMusicAdCacheForTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	_, _ = ytmusicAdProbe(ctx, "com.google.Chrome", "某歌手\x00某歌名")
	ytmusicAdMu.Lock()
	defer ytmusicAdMu.Unlock()
	if ytmusicAdKey != "" {
		t.Errorf("unknown 不该被写进缓存, key = %q", ytmusicAdKey)
	}
}

// 非浏览器 / 不支持脚本的浏览器:直接 unknown,一次子进程都不起。
func TestYTMusicAdProbeSkipsNonBrowsers(t *testing.T) {
	resetYTMusicAdCacheForTest(t)
	for _, id := range []string{"com.apple.Music", "org.mozilla.firefox", "com.whatever"} {
		start := time.Now()
		if got, _ := ytmusicAdProbe(context.Background(), id, "a\x00b"); got != ytmusicAdUnknown {
			t.Errorf("%s 应该 unknown, got %v", id, got)
		}
		if el := time.Since(start); el > 200*time.Millisecond {
			t.Errorf("%s 不该起 osascript(耗时 %v)", id, el)
		}
	}
}

func resetYTMusicAdCacheForTest(t *testing.T) {
	t.Helper()
	clear := func() {
		ytmusicAdMu.Lock()
		ytmusicAdKey, ytmusicAdVal, ytmusicAdAlbum, ytmusicAdAt = "", ytmusicAdUnknown, "", time.Time{}
		ytmusicAdMu.Unlock()
	}
	clear()
	t.Cleanup(clear)
}
