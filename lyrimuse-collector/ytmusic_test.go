package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 2026-08-25 加:歌词第七个候选来源。这些测试的 JSON 片段字段名/嵌套结构全部来自
// 2026-08-25 对真实 InnerTube 端点发裸 HTTP 请求实测抓到的响应(不是照抄文档/库源码
// 假设的形状)——手写成最小片段而不是整段塞真实响应,是为了让每条测试一眼看出在验
// 哪一层结构,跟 amllttml_test.go 手写 TTML 样本同一个理由。

func TestYtmusicParseDurationText(t *testing.T) {
	cases := map[string]float64{
		"3:21":    201,
		"0:45":    45,
		"1:02:03": 3723,
		"":        0,
		"abc":     0,
		"3":       0,
		"-1:00":   0,
	}
	for in, want := range cases {
		if got := ytmusicParseDurationText(in); got != want {
			t.Errorf("ytmusicParseDurationText(%q) = %v, want %v", in, got, want)
		}
	}
}

// 真实 search 响应一条 item 的最小结构(2026-08-25 对 "Taylor Swift Anti-Hero" 实测
// 核实过这几段字段路径:flexColumns[0]=歌名、flexColumns[1]="歌手 • 专辑 • 时长"
// 用 U+2022 连接、overlay 里的 watchEndpoint 带 videoId + musicVideoType)。
func ytmusicSearchItemJSON(title, meta, videoID, musicVideoType string) string {
	return `{"musicResponsiveListItemRenderer":{` +
		`"flexColumns":[` +
		`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"` + title + `"}]}}},` +
		`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"` + meta + `"}]}}}` +
		`],` +
		`"thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[` +
		`{"url":"https://example.com/60.jpg","width":60},` +
		`{"url":"https://example.com/120.jpg","width":120}` +
		`]}}},` +
		`"overlay":{"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":{` +
		`"playNavigationEndpoint":{"watchEndpoint":{` +
		`"videoId":"` + videoID + `",` +
		`"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"` + musicVideoType + `"}}` +
		`}}}}}}` +
		`}}`
}

func TestYtmusicParseSearchItem(t *testing.T) {
	raw := ytmusicSearchItemJSON("Anti-Hero", "Taylor Swift • Midnights • 3:21", "3YgtjHZyCIQ", "MUSIC_VIDEO_TYPE_ATV")
	var item ytmusicSearchItem
	if err := json.Unmarshal([]byte(raw), &item); err != nil {
		t.Fatalf("解析测试用例本身失败: %v", err)
	}
	p, ok := ytmusicParseSearchItem(item)
	if !ok {
		t.Fatal("应该解析成功")
	}
	if p.videoID != "3YgtjHZyCIQ" || p.title != "Anti-Hero" || p.artist != "Taylor Swift" ||
		p.album != "Midnights" || p.durationSecs != 201 || !p.isATV {
		t.Errorf("字段解析不对: %+v", p)
	}
	if p.cover == "" {
		t.Error("应该拿到封面 URL")
	}

	// 专辑名本身含 " • "(实测真实存在,见 ytmusic.go 头注引用的多段元数据)——
	// 中间段全部拼回专辑名,不能只取第一段。
	raw2 := ytmusicSearchItemJSON("彩虹+軌跡", "周杰倫 • 魔天倫世界巡迴演唱會 • 3:18", "x", "MUSIC_VIDEO_TYPE_ATV")
	var item2 ytmusicSearchItem
	if err := json.Unmarshal([]byte(raw2), &item2); err != nil {
		t.Fatalf("解析测试用例本身失败: %v", err)
	}
	p2, ok := ytmusicParseSearchItem(item2)
	if !ok || p2.album != "魔天倫世界巡迴演唱會" || p2.artist != "周杰倫" {
		t.Errorf("中日文/长专辑名解析不对: %+v ok=%v", p2, ok)
	}

	// videoId 缺失(没有可播放的曲目)→ 不接受这条。
	raw3 := ytmusicSearchItemJSON("Foo", "Bar • Baz • 3:00", "", "MUSIC_VIDEO_TYPE_ATV")
	var item3 ytmusicSearchItem
	_ = json.Unmarshal([]byte(raw3), &item3)
	if _, ok := ytmusicParseSearchItem(item3); ok {
		t.Error("缺 videoId 的条目不该被接受")
	}
}

// 2026-08-25 实测坐实:不带 songs 过滤器的默认搜索"Top result"经常命中演唱会直拍/
// 翻唱视频而不是录音室曲目(Taylor Swift "Anti-Hero" 命中过 Eras Tour 现场版)。
// 这组测试钉住挑选逻辑本身:曲名/歌手门 + 版本限定词门 + ATV 优先 + 时长最接近。
func TestYtmusicPickSearchItem(t *testing.T) {
	atv := func(title, artist, album string, dur float64) ytmusicParsedSearchItem {
		return ytmusicParsedSearchItem{videoID: "v", title: title, artist: artist, album: album, durationSecs: dur, isATV: true}
	}

	// 曲名/歌手对不上的候选必须挡掉。
	items := []ytmusicParsedSearchItem{
		atv("Anti-Hero", "Someone Else", "Midnights", 201),
		atv("A Completely Different Song", "Taylor Swift", "Midnights", 201),
	}
	if _, ok := ytmusicPickSearchItem(items, "Taylor Swift", "Anti-Hero", "Midnights", 201); ok {
		t.Error("曲名/歌手都对不上,不该选出任何候选")
	}

	// 版本限定词相反(本地是 Live,候选不是)必须挡掉——同一套 versionTagsMismatch 判定。
	items = []ytmusicParsedSearchItem{atv("Anti-Hero", "Taylor Swift", "Midnights", 201)}
	if _, ok := ytmusicPickSearchItem(items, "Taylor Swift", "Anti-Hero (Live)", "", 201); ok {
		t.Error("版本限定词相反的候选不该被采纳")
	}

	// isATV 优先于时长吻合度:非 ATV 那条时长完全吻合,但 ATV 的那条即使差一点也该赢。
	nonATV := atv("Anti-Hero", "Taylor Swift", "Midnights", 201)
	nonATV.isATV = false
	realATV := ytmusicParsedSearchItem{videoID: "v2", title: "Anti-Hero", artist: "Taylor Swift", album: "Midnights", durationSecs: 205, isATV: true}
	got, ok := ytmusicPickSearchItem([]ytmusicParsedSearchItem{nonATV, realATV}, "Taylor Swift", "Anti-Hero", "", 201)
	if !ok || got.videoID != "v2" {
		t.Errorf("应该优先选 ATV(真录音室曲目),实际 %+v", got)
	}

	// 都是 ATV 时按时长挑最接近的(跟 pickLRCLIBSearchResult 同一个判据)。
	multi := []ytmusicParsedSearchItem{
		atv("Anti-Hero", "Taylor Swift", "", 270),
		atv("Anti-Hero", "Taylor Swift", "", 202),
		atv("Anti-Hero", "Taylor Swift", "", 150),
	}
	got, ok = ytmusicPickSearchItem(multi, "Taylor Swift", "Anti-Hero", "", 201)
	if !ok || got.durationSecs != 202 {
		t.Errorf("应该挑最接近 201s 的 202s,实际 %+v", got)
	}

	// 本地时长未知(<=0)时退回"第一个过门的"。
	got, ok = ytmusicPickSearchItem(multi, "Taylor Swift", "Anti-Hero", "", 0)
	if !ok || got.durationSecs != 270 {
		t.Errorf("时长未知时应退回第一个过门的候选,实际 %+v", got)
	}
}

func TestYtmusicExtractSearchItems(t *testing.T) {
	// 真实响应把候选包在 tabbedSearchResultsRenderer 深处的 musicShelfRenderer.contents
	// 数组里(2026-08-25 实测核实的路径,见 ytmusic.go 头注)。ytmusicExtractSearchItems
	// 故意不按这条精确路径导航、而是通用递归找 key——这条测试把它包在一个*不同*的外壳
	// 里(用一个虚构的容器名),确认这个函数真的是按 key 名找,不依赖外层路径。
	raw := `{"someWeirdContainer":{"nested":[` +
		ytmusicSearchItemJSON("Song A", "Artist A • Album A • 3:00", "vidA", "MUSIC_VIDEO_TYPE_ATV") + `,` +
		ytmusicSearchItemJSON("Song B", "Artist B • Album B • 4:00", "vidB", "MUSIC_VIDEO_TYPE_ATV") +
		`]}}`
	items := ytmusicExtractSearchItems([]byte(raw))
	if len(items) != 2 {
		t.Fatalf("应该找到 2 条候选,实际 %d", len(items))
	}
}

func TestYtmusicLyricsBrowseID(t *testing.T) {
	// 真实 "next" 响应里 tabs 数组混着好几个 tab(Up next/Lyrics/Comments/Related),
	// 只有 pageType 是 MUSIC_PAGE_TYPE_TRACK_LYRICS 的那个才是歌词 —— 2026-08-25 实测
	// 核实过这个数组的真实位置和其它三个 tab 的存在,这条测试确认判定不会误认别的 tab。
	raw := `{
		"contents": {"singleColumnMusicWatchNextResultsRenderer": {"tabbedRenderer": {
			"watchNextTabbedResultsRenderer": {"tabs": [
				{"tabRenderer": {"title": "Up next"}},
				{"tabRenderer": {"endpoint": {"browseEndpoint": {
					"browseId": "MPLYt_MOJF3UvLsif-3",
					"browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig": {
						"pageType": "MUSIC_PAGE_TYPE_TRACK_LYRICS"
					}}
				}}}},
				{"tabRenderer": {"title": "Comments"}},
				{"tabRenderer": {"endpoint": {"browseEndpoint": {
					"browseId": "MPTRt_MOJF3UvLsif-3",
					"browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig": {
						"pageType": "MUSIC_PAGE_TYPE_TRACK_RELATED"
					}}
				}}}}
			]}
		}}}
	}`
	if got := ytmusicLyricsBrowseID([]byte(raw)); got != "MPLYt_MOJF3UvLsif-3" {
		t.Errorf("应该挑中歌词 tab 的 browseId,实际 %q", got)
	}

	// 没有歌词 tab(纯音乐/太冷门)时返回空串。
	noLyrics := `{"contents": {"singleColumnMusicWatchNextResultsRenderer": {"tabbedRenderer": {
		"watchNextTabbedResultsRenderer": {"tabs": [{"tabRenderer": {"title": "Up next"}}]}
	}}}}`
	if got := ytmusicLyricsBrowseID([]byte(noLyrics)); got != "" {
		t.Errorf("没有歌词 tab 应该返回空串,实际 %q", got)
	}
}

// 2026-08-25 用户追问坐实:只在真是 LyricFind 时才接受候选,Musixmatch 换个管道重发的
// 一律当"这一源没查到"——理由见 ytmusicLyric 文件头注(跨源共识会被虚假印证 + 6/9 的
// 命中在已有 musixmatch 源上零增量)。这条钉住判定本身,真实的两种 sourceMessage 取值
// 都覆盖到。
func TestYtmusicIsLyricFindSource(t *testing.T) {
	cases := map[string]bool{
		"Source: LyricFind":   true,
		"Source: Musixmatch":  false,
		"":                    false,
		"source: lyricfind":   true, // 大小写不敏感只是防御性写法,见函数注释
		"LyricFind":           true,
		"Some Other Provider": false,
	}
	for in, want := range cases {
		if got := ytmusicIsLyricFindSource(in); got != want {
			t.Errorf("ytmusicIsLyricFindSource(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestYtmusicParseTimedLyrics(t *testing.T) {
	// 真实结构(2026-08-25 对 "Anti-Hero" 实测核实):timedLyricsData 和 sourceMessage
	// 是同一个 lyricsData 对象的兄弟字段,startTimeMilliseconds/endTimeMilliseconds
	// 在原始 JSON 里是**字符串**、不是数字。
	raw := `{"contents": {"elementRenderer": {"newElement": {"type": {"componentType": {"model": {
		"timedLyricsModel": {"lyricsData": {
			"sourceMessage": "Source: LyricFind",
			"timedLyricsData": [
				{"lyricLine": "♪", "cueRange": {"startTimeMilliseconds": "0", "endTimeMilliseconds": "5370", "metadata": {"id": "0"}}},
				{"lyricLine": "I have this thing", "cueRange": {"startTimeMilliseconds": "5370", "endTimeMilliseconds": "10310", "metadata": {"id": "1"}}}
			]
		}}
	}}}}}}}`
	lines, source := ytmusicParseTimedLyrics([]byte(raw))
	if source != "Source: LyricFind" {
		t.Errorf("来源标注不对: %q", source)
	}
	if len(lines) != 2 || lines[0].text != "♪" || lines[0].startMs != 0 || lines[0].endMs != 5370 ||
		lines[1].text != "I have this thing" || lines[1].startMs != 5370 {
		t.Errorf("逐行歌词解析不对: %+v", lines)
	}

	// "歌词不可用" 的响应(见 ytmusic.go 头注:同一个 browseId 换 WEB_REMIX 身份、
	// 或者这首歌真的没有带时间戳的歌词时都会是这个形状)——没有 timedLyricsData,
	// 必须返回空,不能 panic 或者拼出一份假歌词。
	notAvailable := `{"contents": {"messageRenderer": {"text": {"runs": [{"text": "Lyrics not available"}]}}}}`
	lines, source = ytmusicParseTimedLyrics([]byte(notAvailable))
	if len(lines) != 0 || source != "" {
		t.Errorf("歌词不可用时应该返回空,实际 lines=%v source=%q", lines, source)
	}

	// 脏数据:endTimeMilliseconds < startTimeMilliseconds 的行要被跳过,不能产出
	// 一个负时长的词条(下游 formatLRCTime/isTimedLRC 对这种数据没有防御)。
	dirty := `{"timedLyricsData": [
		{"lyricLine": "bad", "cueRange": {"startTimeMilliseconds": "100", "endTimeMilliseconds": "50", "metadata": {"id": "0"}}},
		{"lyricLine": "good", "cueRange": {"startTimeMilliseconds": "100", "endTimeMilliseconds": "200", "metadata": {"id": "1"}}}
	], "sourceMessage": "Source: Musixmatch"}`
	lines, _ = ytmusicParseTimedLyrics([]byte(dirty))
	if len(lines) != 1 || lines[0].text != "good" {
		t.Errorf("时间戳倒退的行应该被跳过,实际 %+v", lines)
	}
}

func TestYtmusicBuildLRC(t *testing.T) {
	lines := []ytmusicLyricLine{
		{text: "♪", startMs: 0, endMs: 5370},
		{text: "I have this thing", startMs: 5370, endMs: 10310},
	}
	lrc := ytmusicBuildLRC(lines)
	want := "[00:00.00]♪\n[00:05.37]I have this thing\n"
	if lrc != want {
		t.Errorf("拼出的 LRC 不对:\n实际 %q\n期望 %q", lrc, want)
	}

	// 拼出来的结果必须真的能通过这个项目的 isTimedLRC 判定(至少 3 行、过半带
	// [mm:ss.xx] 时间戳),不然这一路即使查到候选也会在下游被判"不算逐行歌词"、
	// 白接——这条断言直接复用生产代码走的同一道闸,用一份够长(真实歌曲不会只有
	// 两行)的样本测,别让上面那条 2 行的最小样本掩盖这个要求。
	longer := ytmusicBuildLRC([]ytmusicLyricLine{
		{text: "♪", startMs: 0, endMs: 5370},
		{text: "I have this thing", startMs: 5370, endMs: 10310},
		{text: "where I get older", startMs: 10310, endMs: 15120},
	})
	if !isTimedLRC(longer) {
		t.Error("拼出的 LRC 应该能通过 isTimedLRC")
	}
}

func TestYtmusicExtractVisitorID(t *testing.T) {
	// 真实首页 HTML 里内联的 ytcfg.set({...}),VISITOR_DATA 就在这个 JSON 里
	// (2026-08-25 实测核实过这个形状能从真实响应里抠出来)。
	html := `<html><script>ytcfg.set({"VISITOR_DATA":"abc123==","INNERTUBE_CONTEXT":{}});</script></html>`
	if got := ytmusicExtractVisitorID(html); got != "abc123==" {
		t.Errorf("应该抠出 abc123==,实际 %q", got)
	}
	if got := ytmusicExtractVisitorID("<html>没有 ytcfg</html>"); got != "" {
		t.Errorf("没有 ytcfg.set 时应该返回空串,实际 %q", got)
	}
	if got := ytmusicExtractVisitorID(`ytcfg.set({"OTHER_FIELD":1});`); got != "" {
		t.Errorf("有 ytcfg.set 但没有 VISITOR_DATA 字段时应该返回空串,实际 %q", got)
	}
}

// 2026-08-25 用户报"批量解析时 musixmatch 交出候选的比例远低于单首查询"——根因是并发
// goroutine 各自判定"没有可用凭据"就都去发一次网络请求,YouTube 首页有同样的隐患
// (抓 visitor id 也是一次网络请求)。这里从一开始就按单飞锁写,这条测试直接照抄
// musixmatch_test.go 的 TestMusixmatchEnsureTokenSingleFlight,验证同一个机制。
func TestYtmusicEnsureVisitorIDSingleFlight(t *testing.T) {
	ytmusicVisitorMu.Lock()
	ytmusicVisitorID = ""
	ytmusicVisitorMu.Unlock()

	orig := ytmusicDoFetchVisitorID
	defer func() { ytmusicDoFetchVisitorID = orig }()

	var calls int32
	ytmusicDoFetchVisitorID = func(ctx context.Context) string {
		atomic.AddInt32(&calls, 1)
		time.Sleep(30 * time.Millisecond)
		return "visitor-A"
	}

	const n = 16
	var wg sync.WaitGroup
	results := make([]string, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			results[i] = ytmusicEnsureVisitorID(context.Background())
		}(i)
	}
	wg.Wait()

	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("单飞失效: %d 个并发调用触发了 %d 次真实抓取(应为 1)", n, got)
	}
	for i, r := range results {
		if r != "visitor-A" {
			t.Errorf("goroutine %d 拿到的 visitor id 不对: 实际 %q", i, r)
		}
	}
}

func TestYtmusicEnsureVisitorIDSkipsFetchWhenCached(t *testing.T) {
	ytmusicVisitorMu.Lock()
	ytmusicVisitorID = "already-have-one"
	ytmusicVisitorMu.Unlock()

	orig := ytmusicDoFetchVisitorID
	defer func() { ytmusicDoFetchVisitorID = orig }()
	ytmusicDoFetchVisitorID = func(ctx context.Context) string {
		t.Error("已经有值了,不该去真的抓")
		return "should-not-happen"
	}

	if got := ytmusicEnsureVisitorID(context.Background()); got != "already-have-one" {
		t.Errorf("应该直接返回缓存值,实际 %q", got)
	}
}

// 抓取失败(返回空串)不该"poison"住——下一次调用必须能重试,不能因为第一次没抓到
// 就让这一路永远死掉(进程是长驻的,一次瞬时网络问题不该拖垮整个运行周期)。
func TestYtmusicEnsureVisitorIDRetriesAfterFailure(t *testing.T) {
	ytmusicVisitorMu.Lock()
	ytmusicVisitorID = ""
	ytmusicVisitorMu.Unlock()

	orig := ytmusicDoFetchVisitorID
	defer func() { ytmusicDoFetchVisitorID = orig }()
	var calls int32
	ytmusicDoFetchVisitorID = func(ctx context.Context) string {
		n := atomic.AddInt32(&calls, 1)
		if n == 1 {
			return "" // 第一次抓失败
		}
		return "visitor-B"
	}

	if got := ytmusicEnsureVisitorID(context.Background()); got != "" {
		t.Fatalf("第一次应该失败返回空串,实际 %q", got)
	}
	if got := ytmusicEnsureVisitorID(context.Background()); got != "visitor-B" {
		t.Fatalf("第二次应该重试成功,实际 %q", got)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("应该真的抓了两次,实际 %d", got)
	}
}

func TestYtmusicWebClientVersionFormat(t *testing.T) {
	v := ytmusicWebClientVersion()
	// 形如 "1.20260825.01.00" —— 跟 WEB_REMIX 客户端约定的日期版本号格式一致
	// (ytmusicapi 的做法:日期串永远"看起来最新",不需要手动跟着网页版更新)。
	if !strings.HasPrefix(v, "1.") || !strings.HasSuffix(v, ".01.00") || len(v) != len("1.20260825.01.00") {
		t.Errorf("客户端版本号格式不对: %q", v)
	}
}
