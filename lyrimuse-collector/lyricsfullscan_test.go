package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// 见 lyricsfullscan.go 头注:分层规则 + 四道硬闸。这是这个功能唯一"改错了不报错、只是数字
// 悄悄变形"的地方 —— 层分错了扫描照样跑完,只是把该修的歌漏掉、或者把不该碰的歌重搜一遍。
func TestLyricsFullScanTier(t *testing.T) {
	cur := lyricsScoringVersion
	cases := []struct {
		name     string
		entry    enrichEntry
		pinned   bool
		inflight bool
		want     int
	}{
		{"空条目 → 第 0 层", enrichEntry{}, false, false, 0},
		{"只有纯文本兜底 → 仍算没词,第 0 层", enrichEntry{PlainLyrics: "text"}, false, false, 0},
		{"有词没逐字 → 第 1 层", enrichEntry{Lyrics: "[00:01.00]x", LyricsScoringVersion: cur}, false, false, 1},
		{"有逐字但版本落后 → 第 2 层", enrichEntry{Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur - 1}, false, false, 2},
		{"老条目没写过版本号(读成 0)→ 第 2 层", enrichEntry{Lyrics: "x", LyricsYRC: "y"}, false, false, 2},
		{"有逐字且版本已追平 → 不碰", enrichEntry{Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur}, false, false, -1},
		{"版本号比当前还高(降级过)→ 不碰", enrichEntry{Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur + 1}, false, false, -1},
		{"人工修正过 → 一票否决,哪怕是空条目", enrichEntry{ManualLyrics: true}, false, false, -1},
		{"确证纯音乐 → 一票否决", enrichEntry{Instrumental: true}, false, false, -1},
		{"校准过时间轴 → 一票否决(补空扫描没有这道闸)", enrichEntry{Lyrics: "x", LyricsScoringVersion: cur - 1}, true, false, -1},
		{"正在飞 → 这一轮跳过", enrichEntry{Lyrics: "x", LyricsScoringVersion: cur - 1}, false, true, -1},
	}
	for _, c := range cases {
		if got := lyricsFullScanTier(c.entry, c.pinned, c.inflight); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
}

// 候选按层拼接、层内字典序 —— 中途停掉时留下的必须是收益最高的那部分,所以顺序本身是契约。
func TestLyricsFullScanCandidatesOrder(t *testing.T) {
	cur := lyricsScoringVersion
	savedCache, savedInflight := enrichCache, enrichInflight
	savedPins := lyricsPinsPath
	t.Cleanup(func() {
		enrichCache, enrichInflight, lyricsPinsPath = savedCache, savedInflight, savedPins
		lyricsPins, lyricsPinsRead = nil, false
	})
	lyricsPinsPath = ""
	lyricsPins, lyricsPinsRead = nil, false
	enrichCache = map[string]enrichEntry{
		"z|stale yrc|":   {Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur - 3},
		"a|stale yrc|":   {Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur - 1},
		"m|line only|":   {Lyrics: "[00:01.00]x", LyricsScoringVersion: cur},
		"b|line only|":   {Lyrics: "[00:01.00]x"},
		"q|empty|":       {},
		"c|empty|":       {PlainLyrics: "text"},
		"k|caught up|":   {Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur},
		"p|manual|":      {Lyrics: "x", ManualLyrics: true},
		"i|instrumental": {Instrumental: true},
	}
	enrichInflight = map[string]bool{}

	got := lyricsFullScanCandidates()
	want := []string{
		// 第 0 层:没词的(含只有纯文本兜底的)
		"c|empty|", "q|empty|",
		// 第 1 层:有词没逐字
		"b|line only|", "m|line only|",
		// 第 2 层:有逐字但版本落后
		"a|stale yrc|", "z|stale yrc|",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v\nwant %v", got, want)
	}
}

// pin 必须真的挡住 —— 这道闸是全量扫库相对补空扫描多出来的那一道,走的是文件快照
// (lyricsPinnedKeys),跟 lyricsPinned 逐条查同一份数据,这里连着文件一起钉。
func TestLyricsFullScanCandidatesSkipsPinned(t *testing.T) {
	cur := lyricsScoringVersion
	savedCache, savedInflight, savedPins := enrichCache, enrichInflight, lyricsPinsPath
	t.Cleanup(func() {
		enrichCache, enrichInflight, lyricsPinsPath = savedCache, savedInflight, savedPins
		lyricsPins, lyricsPinsRead = nil, false
	})
	dir := t.TempDir()
	lyricsPinsPath = filepath.Join(dir, "pins.json")
	if err := os.WriteFile(lyricsPinsPath,
		[]byte(`{"version":1,"pins":{"a|pinned|":1787650854}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	lyricsPins, lyricsPinsRead = nil, false
	enrichCache = map[string]enrichEntry{
		"a|pinned|": {Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur - 1},
		"b|plain|":  {Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur - 1},
	}
	enrichInflight = map[string]bool{}

	if got, want := lyricsFullScanCandidates(), []string{"b|plain|"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
	if !lyricsPinned("a|pinned|") {
		t.Error("lyricsPinned 和 lyricsPinnedKeys 对同一份文件给出了不同答案")
	}
}

// 请求文件多认一个动词。旧 collector 把 "full" 当成普通 key 那条降级路径也一并钉住 ——
// 它是"新 App + 旧 collector"时唯一会发生的事,不能变成"误扫了一批别的东西"。
func TestParseLyricsFillRequestFull(t *testing.T) {
	req := parseLyricsFillRequest("full\n")
	if !req.full || !req.manual || req.all || req.cancel || len(req.keys) != 0 {
		t.Errorf("full: %+v", req)
	}
	if req := parseLyricsFillRequest("all\n"); req.full {
		t.Error(`"all" 不该被解成全量扫库`)
	}
	// 降级语义:把 full 当普通 key 时,它只会去匹配一个不存在的缓存条目。
	savedCache, savedInflight := enrichCache, enrichInflight
	t.Cleanup(func() { enrichCache, enrichInflight = savedCache, savedInflight })
	enrichCache = map[string]enrichEntry{"a|x|": {}}
	enrichInflight = map[string]bool{}
	legacy := lyricsFillRequest{manual: true, keys: map[string]bool{"full": true}}
	if got := lyricsFillSweepCandidates(legacy); len(got) != 0 {
		t.Errorf("旧 collector 应当空跑一轮,却挑出了 %v", got)
	}
}

// 「待续」标记的读写与清除。跑完/用户停止都清,进程被杀(两者都不走)才留着。
func TestLyricsFullScanActiveMarker(t *testing.T) {
	saved := lyricsFullScanStatePath
	t.Cleanup(func() {
		lyricsFullScanMu.Lock()
		lyricsFullScanStatePath = saved
		lyricsFullScanMu.Unlock()
	})
	path := filepath.Join(t.TempDir(), "fullscan.json")
	setLyricsFullScanStatePath(path)

	// setLyricsFullScanStatePath 必须**建**出文件(App 要从这里读打分版本号),而且不能
	// 顺手把 Active 清掉。
	state := readLyricsFullScanState()
	if state.ScoringVersion != lyricsScoringVersion {
		t.Errorf("scoringVersion: got %d, want %d", state.ScoringVersion, lyricsScoringVersion)
	}
	if lyricsFullScanActive() {
		t.Error("全新的状态文件不该带着待续标记")
	}

	setLyricsFullScanActive(true)
	if !lyricsFullScanActive() {
		t.Fatal("置位之后应当为 true")
	}
	started := readLyricsFullScanState().StartedAt
	if started == 0 {
		t.Error("置位应当记下起始时刻")
	}
	// 重新走一遍启动路径(模拟 collector 重启):标记必须活下来,这正是续跑的全部依据。
	setLyricsFullScanStatePath(path)
	if !lyricsFullScanActive() {
		t.Error("重启后待续标记丢了 —— 续跑机制失效")
	}
	if got := readLyricsFullScanState().StartedAt; got != started {
		t.Errorf("续跑不该刷新起始时刻: got %d, want %d", got, started)
	}

	cancelLyricsFillSweep()
	if lyricsFullScanActive() {
		t.Error("用户按停止之后待续标记应当被清掉")
	}

	// 文件坏了一律当"没有待续的一轮" —— 反过来会让每次启动都自动开一轮几十小时的全库扫描。
	if err := os.WriteFile(path, []byte("{ not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if lyricsFullScanActive() {
		t.Error("坏掉的状态文件不该被读成 active")
	}
}

// 第一发定时器的档位。续跑是用户点出来的那一轮被重启打断,不该陪自动补空一起等 10 分钟 ——
// 选错常量完全不报错(扫描照跑、日志照写,只是晚十分钟),表现成「续跑怎么没自动开始」。
func TestLyricsFillSweepFirstDelay(t *testing.T) {
	if got := lyricsFillSweepFirstDelay(false); got != lyricsFillSweepInitialDelay {
		t.Errorf("没有待续的一轮时应当用自动扫描那档: got %v, want %v", got, lyricsFillSweepInitialDelay)
	}
	if got := lyricsFillSweepFirstDelay(true); got != lyricsFullScanResumeDelay {
		t.Errorf("续跑应当用短的那档: got %v, want %v", got, lyricsFullScanResumeDelay)
	}
	if lyricsFullScanResumeDelay >= lyricsFillSweepInitialDelay {
		t.Errorf("续跑的延迟必须明显短于自动扫描的礼貌窗口: resume=%v initial=%v",
			lyricsFullScanResumeDelay, lyricsFillSweepInitialDelay)
	}
	// 界面上那句「稍后会自动接着跑」得撑得住这个数 —— 十分钟的「稍后」用户会当成坏了。
	if lyricsFullScanResumeDelay > 2*time.Minute {
		t.Errorf("续跑延迟 %v 太长,界面那句「稍后」就名不副实了", lyricsFullScanResumeDelay)
	}
}

// 两首之间的间隔分两档:补空慢、全量快。跟上面那条同一个理由 —— 选错常量不报错,
// 只是全库多花十几个小时,而那要等一天才看得出来。
func TestLyricsFillSweepPace(t *testing.T) {
	if got := lyricsFillSweepPace(false); got != lyricsFillSweepGap {
		t.Errorf("补空扫描应当用 lyricsFillSweepGap: got %v, want %v", got, lyricsFillSweepGap)
	}
	if got := lyricsFillSweepPace(true); got != lyricsFullScanGap {
		t.Errorf("全量扫库应当用 lyricsFullScanGap: got %v, want %v", got, lyricsFullScanGap)
	}
	if lyricsFullScanGap >= lyricsFillSweepGap {
		t.Errorf("全量那一档必须比补空短,否则这次改动没有意义: full=%v sweep=%v",
			lyricsFullScanGap, lyricsFillSweepGap)
	}
	// 下限守卫:一首歌会打出 100+ 个请求散到十几个主机,而整个采集器没有 per-host 限流器。
	// gap 是这些突发之间唯一的喘息 —— 真要压到 2 秒以下,得先补限流,不能只改这个数。
	if lyricsFullScanGap < 2*time.Second {
		t.Errorf("gap %v 太短:没有 per-host 限流器兜底时这是唯一的喘息,先补限流再压",
			lyricsFullScanGap)
	}
	// 5300 首的全库一轮别超过一天 —— 超了「全量重新扫库」这个功能就没人用得下去。
	const libraryTracks = 5300
	const searchSecondsPerTrack = 3 // 实测:18 秒/首 - 15 秒 gap
	total := time.Duration(libraryTracks) * (lyricsFullScanGap + searchSecondsPerTrack*time.Second)
	if total > 24*time.Hour {
		t.Errorf("按 %d 首估算全库要 %v,超过一天了", libraryTracks, total)
	}
}
