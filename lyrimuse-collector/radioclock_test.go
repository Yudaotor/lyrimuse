package main

import (
	"testing"
	"time"
)

// 电台曲内时钟:换歌归零、播放中按墙钟走、暂停冻结、单拍有上限。
// 实测背景见 radioclock.go 头注(位置换歌不复位,实测偏了 304 秒)。
func TestAdvanceRadioClock(t *testing.T) {
	base := time.Date(2026, 9, 10, 7, 15, 35, 0, time.UTC)
	// 第一次见:归零起表。
	s := advanceRadioClock(radioClockState{}, "Daniel Caesar|Who Knows", true, base, 0)
	if s.position != 0 || s.trackKey != "Daniel Caesar|Who Knows" {
		t.Fatalf("first sight should start at 0, got %+v", s)
	}
	// 播放中按墙钟累加。
	s = advanceRadioClock(s, "Daniel Caesar|Who Knows", true, base.Add(5*time.Second), 0)
	s = advanceRadioClock(s, "Daniel Caesar|Who Knows", true, base.Add(10*time.Second), 0)
	if s.position != 10 {
		t.Fatalf("playing should accumulate wall clock, got %.3f want 10", s.position)
	}
	// 换歌:归零 —— 这正是系统那块表不做的事(实测 07:20:39 换歌位置照旧往上走)。
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(11*time.Second), 0)
	if s.position != 0 || s.trackKey != "Clairo|Juna" {
		t.Fatalf("track change must reset to 0, got %+v", s)
	}
	// 暂停:上一拍还在播 → 那段算数(基本都在播);之后每一拍都冻结。
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(21*time.Second), 0)
	if s.position != 10 {
		t.Fatalf("want 10 before pause, got %.3f", s.position)
	}
	s = advanceRadioClock(s, "Clairo|Juna", false, base.Add(23*time.Second), 0)
	if s.position != 12 {
		t.Fatalf("the interval that ended in a pause was still mostly playing, got %.3f want 12", s.position)
	}
	s = advanceRadioClock(s, "Clairo|Juna", false, base.Add(120*time.Second), 0)
	if s.position != 12 {
		t.Fatalf("pause must freeze the position, got %.3f", s.position)
	}
	// 回归守卫:恢复那一拍**绝不能**把整段暂停间隔算成播放时间。按"这一拍在播"累加的老写法
	// 会在这里跳到 12+97=109 —— 实测的 3.5~5.8 秒前跳就是这么来的。
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(125*time.Second), 0)
	if s.position != 12 {
		t.Fatalf("resume must not count the paused span, got %.3f want 12", s.position)
	}
	// 恢复之后照常走。
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(128*time.Second), 0)
	if s.position != 15 {
		t.Fatalf("after resuming the clock should run again, got %.3f want 15", s.position)
	}
	// 单拍上限:休眠 / 长卡顿之后墙钟差不再等于"播了多久"。
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(128*time.Second+2*time.Hour), 0)
	if s.position != 15+radioMaxAdvancePerTick.Seconds() {
		t.Fatalf("a huge gap must be clamped, got %.3f", s.position)
	}
	// 时钟倒退(NTP 校时)不减位置。
	before := s.position
	s = advanceRadioClock(s, "Clairo|Juna", true, base, 0)
	if s.position != before {
		t.Fatalf("a backwards clock must not move the position, got %.3f want %.3f", s.position, before)
	}
}

// applyRadioClock 只动电台快照,普通播放原样不碰。
func TestApplyRadioClockOnlyTouchesRadio(t *testing.T) {
	radioClockMu.Lock()
	saved := radioClockValue
	radioClockValue = radioClockState{}
	radioClockMu.Unlock()
	defer func() {
		radioClockMu.Lock()
		radioClockValue = saved
		radioClockMu.Unlock()
	}()

	now := time.Date(2026, 9, 10, 7, 20, 39, 0, time.UTC)
	normal := snapshot{Title: "Fushigi", Artist: "星野源", Elapsed: 42, AnchorElapsed: 7, Duration: 292.21, Playing: true}
	before := normal
	applyRadioClock(&normal, now)
	if normal != before {
		t.Fatalf("a non-radio snapshot must be left alone: %+v vs %+v", normal, before)
	}

	radio := snapshot{Title: "Juna", Artist: "Clairo", Elapsed: 467, AnchorElapsed: 0, Playing: true, Radio: true}
	applyRadioClock(&radio, now)
	if radio.Elapsed != 0 || radio.AnchorElapsed != 0 {
		t.Fatalf("first radio tick should anchor at 0, got elapsed=%.3f anchor=%.3f", radio.Elapsed, radio.AnchorElapsed)
	}
	if !radio.McTS.Equal(now) {
		t.Fatalf("McTS should be the tick instant, got %v", radio.McTS)
	}
	radio.Elapsed = 999 // 系统下一拍照旧报整档节目的位置
	applyRadioClock(&radio, now.Add(20*time.Second))
	if radio.Elapsed != 20 {
		t.Fatalf("radio position must come from our own clock, got %.3f want 20", radio.Elapsed)
	}
}

// extract():电台的 duration 当未知,普通播放原样保留。
func TestExtractRadioDuration(t *testing.T) {
	radioState := map[string]any{
		"title": "Juna", "artist": "Clairo", "bundleIdentifier": "com.apple.Music",
		"duration": 3390.122, "elapsedTime": 467.0, "playing": true,
		"radioStationHash": "CgkIBRoFwOSKqxkQBA",
	}
	s := extract(radioState)
	if !s.Radio {
		t.Fatal("radioStationHash present → Radio must be true")
	}
	if s.Duration != 0 {
		t.Fatalf("no catalog duration → radio duration must be unknown (0), got %.3f", s.Duration)
	}
	// 目录查到了权威曲长就用它 —— 电台的分母靠这个才有意义(整档 3390.122s → 单曲 226.283s)。
	radioState["catalogDurationSecs"] = 226.283
	if got := extract(radioState).Duration; got != 226.283 {
		t.Fatalf("radio duration should come from the Apple catalog, got %.3f want 226.283", got)
	}
	normalState := map[string]any{
		"title": "Fushigi", "artist": "星野源", "bundleIdentifier": "com.apple.Music",
		"duration": 292.21, "elapsedTime": 12.0, "playing": true,
	}
	n := extract(normalState)
	if n.Radio || n.Duration != 292.21 {
		t.Fatalf("normal playback must keep its duration, got radio=%v duration=%.3f", n.Radio, n.Duration)
	}
}

// mergeRadioKeys:AppleScript 那份 state 拿不到 MediaRemote 独有的两个键,靠 media-control
// 那份 raw 补。两条路共用它(refineAppleMusicState 走 auto / 多选,getAppleMusicOnlyState
// 走"只勾了 Apple Music")—— 后者之前根本不问 media-control,电台整层不生效。
func TestMergeRadioKeys(t *testing.T) {
	// 电台 + 目录已经给出权威曲长:两个键都补进去,AppleScript 自己的字段一个不动。
	state := map[string]any{"title": "Juna", "artist": "Clairo", "duration": 3390.1220703125}
	mergeRadioKeys(state, map[string]any{
		"radioStationHash": "CgkIBRoFwOSKqxkQBA", "catalogDurationSecs": 226.283,
	})
	if state["radioStationHash"] != "CgkIBRoFwOSKqxkQBA" {
		t.Errorf("电台判据没补上:%v", state["radioStationHash"])
	}
	if state["catalogDurationSecs"] != 226.283 {
		t.Errorf("目录曲长没补上:%v", state["catalogDurationSecs"])
	}
	if state["duration"] != 3390.1220703125 {
		t.Errorf("duration 该原样留着(换算在 snapshot.extract 里做),得到 %v", state["duration"])
	}

	// 电台但目录还没查到(异步,刚换歌那几拍就是 0):只补判据,**不**把 0 当成曲长写进去 ——
	// 写了会让 extract() 把"未知"当成事实,而下一拍目录到位了也没人回头改。
	state = map[string]any{"title": "Juna", "duration": 3390.122}
	mergeRadioKeys(state, map[string]any{"radioStationHash": "CgkIBRoFwOSKqxkQBA", "catalogDurationSecs": 0.0})
	if state["radioStationHash"] != "CgkIBRoFwOSKqxkQBA" {
		t.Errorf("目录没到位也该补判据,得到 %v", state["radioStationHash"])
	}
	if _, ok := state["catalogDurationSecs"]; ok {
		t.Errorf("目录曲长为 0 时不该写进 state,得到 %v", state["catalogDurationSecs"])
	}

	// 不是电台:一个字段都不许动。AppleScript 的 duration 精度比目录高
	// (实测 289.7659912109375 vs 289.766),拿目录值去盖是降精度。
	state = map[string]any{"title": "Fushigi", "duration": 289.7659912109375}
	mergeRadioKeys(state, map[string]any{"radioStationHash": "", "catalogDurationSecs": 289.766})
	if len(state) != 2 || state["duration"] != 289.7659912109375 {
		t.Errorf("非电台不该动 state,得到 %v", state)
	}

	// 认 MV 那条判据不经过这里:mediaKind 是 AppleScript 那份 state 自己就有的,
	// 合并不该碰它(也不该从 raw 造一个出来)。见 notAudioMedia 头注。
	state = map[string]any{"title": "In the Morning", "mediaKind": "music video", "duration": 232.857}
	mergeRadioKeys(state, map[string]any{"radioStationHash": "", "mediaType": "MRMediaRemoteMediaTypeMusic"})
	if state["mediaKind"] != "music video" || len(state) != 3 {
		t.Errorf("非电台时一个字段都不该动(mediaKind 尤其),得到 %v", state)
	}
}

// borrowAppleScriptPosition:电台一律不借 AppleScript 那份播放头。
//
// 修的真实缺陷 —— 借过来会把 applyRadioClock 刚换好的单曲表覆盖成整档节目的位置,
// 下一拍必然命中单曲循环判定、会话每 5 秒被重建一次,playedSecs 永远涨不过一拍,于是电台上
// 一条收听都提交不了(实测 4.5 小时里 loop restart 2397 次、listen recorded 只有 4 条)。
// Swift 侧同义的闸在 adaptedSnapshot,两边必须同时成立。
func TestBorrowAppleScriptPosition(t *testing.T) {
	const am = appleMusicBundleID
	cases := []struct {
		name                            string
		selected                        bool
		bundle                          string
		playing, tracked, radio, expect bool
	}{
		{"普通 Apple Music 播放:借", true, am, true, true, false, true},
		{"电台:不借 —— player position 报的是整档节目", true, am, true, true, true, false},
		{"没勾 Apple Music:不借", false, am, true, true, false, false},
		{"这一轮报的是别的播放器:不借(别拿 Music.app 的位置盖掉它算对的值)", true, spotifyBundleID, true, true, false, false},
		{"没在播:不借(位置本来就冻结,精度没有意义)", true, am, false, true, false, false},
		{"不是我们关心的来源:不借", true, am, true, false, false, false},
		{"电台 + 其它条件全满足也不借 —— 这条闸不能被别的条件绕过", true, am, true, true, true, false},
	}
	for _, c := range cases {
		if got := borrowAppleScriptPosition(c.selected, c.bundle, c.playing, c.tracked, c.radio); got != c.expect {
			t.Errorf("%s: borrowAppleScriptPosition(%v, %q, %v, %v, %v) = %v, 期望 %v",
				c.name, c.selected, c.bundle, c.playing, c.tracked, c.radio, got, c.expect)
		}
	}
}

// needsRadioDurationBackfill:电台真曲长比会话起点晚到,要补进 sess.meta。
//
// 修 borrowAppleScriptPosition 之后剩下的第二道闸。实测 Dolly Parton《Dumb Blonde》:
// 会话 20:15:45.030 建立、Apple 目录 20:15:49.740 才给出 150.447s,晚 4.7 秒;sess.meta 是会话
// 创建那一刻的快照,不补的话 listenThreshold 拿到 0 → 退回 240s 上限 → 150 秒的歌永远够不着。
func TestNeedsRadioDurationBackfill(t *testing.T) {
	cases := []struct {
		name             string
		sameTrack, radio bool
		sessDur, curDur  float64
		expect           bool
	}{
		{"电台 + 会话还没有曲长 + 目录已到位:补", true, true, 0, 150.447, true},
		{"目录还没到位(仍是 0):不补 —— 别把「未知」当成事实钉死一整首歌", true, true, 0, 0, false},
		{"会话已经有权威曲长:不覆盖", true, true, 150.447, 226.283, false},
		{"不是电台:不补 —— 换曲预载窗口里 duration 可能是下一首的脏值", true, false, 0, 226.283, false},
		{"换歌了:不补 —— 那是上一首的会话,补过去就是张冠李戴", false, true, 0, 150.447, false},
		{"负数曲长同样算「没有」", true, true, -1, 150.447, true},
	}
	for _, c := range cases {
		if got := needsRadioDurationBackfill(c.sameTrack, c.radio, c.sessDur, c.curDur); got != c.expect {
			t.Errorf("%s: needsRadioDurationBackfill(%v, %v, %v, %v) = %v, 期望 %v",
				c.name, c.sameTrack, c.radio, c.sessDur, c.curDur, got, c.expect)
		}
	}
}

// 报单曲位置的电台:换歌时系统位置归零到小值才用它起表;整档节目口径(不归零)、冷启动、位置太大一律不采信。
func TestRadioPerTrackSeed(t *testing.T) {
	cases := []struct {
		name     string
		pos      float64
		age      time.Duration
		prev     float64
		hasPrev  bool
		dur      float64
		want     float64
		wantSeed bool
	}{
		{"过渡跳过前奏:262.5 → 13.0", 13.004, 0, 262.506, true, 0, 13.004, true},
		{"没跳前奏:从 0 起", 0.4, 0, 216.2, true, 0, 0.4, true},
		{"整档节目口径:换歌不归零", 467, 0, 460, true, 3390.122, 0, false},
		{"冷启动:没有上一首读数、也不知道时长", 13, 0, 0, false, 0, 0, false},
		{"冷启动:开台第一首,时长是单曲量级", 0.423, 0, 0, false, 255.181, 0.423, true},
		{"冷启动:整档节目时长不算单曲量级", 33.4, 0, 0, false, 3390.122, 0, false},
		{"位置超过上限", 75, 0, 300, true, 255, 0, false},
		{"归零幅度不够、时长未知", 30, 0, 45, true, 0, 0, false},
		{"锚点太旧", 13, 6 * time.Second, 262, true, 255, 0, false},
		{"负位置", -1, 0, 200, true, 255, 0, false},
	}
	for _, c := range cases {
		got, ok := radioPerTrackSeed(c.pos, c.age, c.prev, c.hasPrev, c.dur)
		if ok != c.wantSeed || got != c.want {
			t.Errorf("%s: got (%v, %v), want (%v, %v)", c.name, got, ok, c.want, c.wantSeed)
		}
	}
}

// applyRadioClock 端到端:上一首系统位置 262 秒,换歌那一拍系统报 13 秒 → 表从 13 秒起,而不是 0。
func TestApplyRadioClockSeedsFromPerTrackPosition(t *testing.T) {
	radioClockMu.Lock()
	savedClock, savedKey, savedPos := radioClockValue, radioLastSystemKey, radioLastSystemPos
	radioClockValue, radioLastSystemKey, radioLastSystemPos = radioClockState{}, "", 0
	radioClockMu.Unlock()
	t.Cleanup(func() {
		radioClockMu.Lock()
		radioClockValue, radioLastSystemKey, radioLastSystemPos = savedClock, savedKey, savedPos
		radioClockMu.Unlock()
	})
	now := time.Now()
	prev := snapshot{Title: "龙拳", Artist: "周杰伦", Playing: true, Radio: true, Elapsed: 262.5, McTS: now}
	applyRadioClock(&prev, now)
	next := snapshot{Title: "Area", Artist: "MagnusTheMagnus", Playing: true, Radio: true, Elapsed: 13.0, McTS: now.Add(time.Second)}
	applyRadioClock(&next, now.Add(time.Second))
	if next.Elapsed != 13.0 {
		t.Fatalf("换歌时系统位置归零到 13 秒,表该从 13 秒起, got %v", next.Elapsed)
	}
	if radioWallClock(next) {
		t.Fatal("判成单曲位置的这首不该再走墙钟表(poller 要照常借 Music.app 播放头)")
	}
	// 同一首里系统重报 0(起播缓冲):快照保留系统值,不被表顶替成墙钟累加的 14 秒。
	rebuffer := snapshot{Title: "Area", Artist: "MagnusTheMagnus", Playing: true, Radio: true, Elapsed: 0, McTS: now.Add(2 * time.Second)}
	applyRadioClock(&rebuffer, now.Add(2*time.Second))
	if rebuffer.Elapsed != 0 {
		t.Fatalf("单曲位置的台:同一首后续拍保留系统位置, got %v", rebuffer.Elapsed)
	}
	whole := snapshot{Title: "Juna", Artist: "Clairo", Playing: true, Radio: true, Elapsed: 480, McTS: now.Add(2 * time.Second)}
	applyRadioClock(&whole, now.Add(2*time.Second))
	if whole.Elapsed != 0 {
		t.Fatalf("系统位置没归零(整档节目口径)时照旧从 0 起, got %v", whole.Elapsed)
	}
	if !radioWallClock(whole) {
		t.Fatal("整档节目口径的台照旧走墙钟表、不借 AppleScript 播放头")
	}
	whole2 := snapshot{Title: "Juna", Artist: "Clairo", Playing: true, Radio: true, Elapsed: 485, McTS: now.Add(7 * time.Second)}
	applyRadioClock(&whole2, now.Add(7*time.Second))
	if whole2.Elapsed != 5 {
		t.Fatalf("整档节目口径的台:同一首按墙钟累加, got %v", whole2.Elapsed)
	}
}

// 「交叉渐入渐出」换歌:起表那一拍读到的还是上一首的位置(新标题 + 旧进度),半秒后系统才推新歌自己的进度。
// 起表后 radioPerTrackDecisionWindow 内补判成单曲位置;窗口过了不再补判。
func TestApplyRadioClockUpgradesToPerTrackWithinWindow(t *testing.T) {
	radioClockMu.Lock()
	savedClock, savedKey, savedPos := radioClockValue, radioLastSystemKey, radioLastSystemPos
	savedPrev, savedHas, savedAt := radioStartPrevPos, radioStartHasPrev, radioStartStartedAt
	radioClockValue, radioLastSystemKey, radioLastSystemPos = radioClockState{}, "", 0
	radioClockMu.Unlock()
	t.Cleanup(func() {
		radioClockMu.Lock()
		radioClockValue, radioLastSystemKey, radioLastSystemPos = savedClock, savedKey, savedPos
		radioStartPrevPos, radioStartHasPrev, radioStartStartedAt = savedPrev, savedHas, savedAt
		radioClockMu.Unlock()
	})
	now := time.Now()
	prev := snapshot{Title: "缘分一道桥", Artist: "王力宏", Playing: true, Radio: true, Elapsed: 245.5, McTS: now}
	applyRadioClock(&prev, now)
	torn := snapshot{Title: "夏日漱石", Artist: "橘子海", Playing: true, Radio: true, Elapsed: 246.7, McTS: now.Add(time.Second)}
	applyRadioClock(&torn, now.Add(time.Second))
	if torn.Elapsed != 0 || !radioWallClock(torn) {
		t.Fatalf("起表那一拍读到上一首的位置:先按墙钟表从 0 起, got %v", torn.Elapsed)
	}
	fixed := snapshot{Title: "夏日漱石", Artist: "橘子海", Playing: true, Radio: true, Elapsed: 6.6, McTS: now.Add(1500 * time.Millisecond)}
	applyRadioClock(&fixed, now.Add(1500*time.Millisecond))
	if fixed.Elapsed != 6.6 || radioWallClock(fixed) {
		t.Fatalf("窗口内系统推出新歌自己的进度:补判成单曲位置并保留系统值, got %v wall=%v", fixed.Elapsed, radioWallClock(fixed))
	}

	// 窗口过了:整档节目口径的台在窗口外即使读数变小也不补判。
	whole := snapshot{Title: "Juna", Artist: "Clairo", Playing: true, Radio: true, Elapsed: 480, McTS: now.Add(3 * time.Second)}
	applyRadioClock(&whole, now.Add(3*time.Second))
	late := snapshot{Title: "Juna", Artist: "Clairo", Playing: true, Radio: true, Elapsed: 5, McTS: now.Add(20 * time.Second)}
	applyRadioClock(&late, now.Add(20*time.Second))
	if !radioWallClock(late) {
		t.Fatal("起表超过 radioPerTrackDecisionWindow 之后不再补判成单曲位置")
	}
}
