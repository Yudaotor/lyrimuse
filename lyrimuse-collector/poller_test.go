// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"testing"
	"time"
)

var baseTestTime = time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC)

// nowAt 返回一个固定基准时间往后推 offsetSecs 秒的时间点,避免测试里用真实 time.Now()
// (相邻两次 time.Now() 调用间隔是真实墙钟时间、不受控,会让 gap 计算失真)。
func nowAt(offsetSecs int) time.Time {
	return baseTestTime.Add(time.Duration(offsetSecs) * time.Second)
}

// 回归测试:AppleScript 换掉 media-control 之后,Music.playerPosition() 每轮轮询都是
// 新鲜的实时进度,不再像旧版 media-control 那样在稳定播放期间冻结。updatePosition()
// 里"是否需要重新锚定"的判断如果还用逐字节的 elapsed != prevElapse 比较,稳定播放时
// 每一轮都会被误判成一次 seek,导致 pushRelayState 每个轮询间隔就写一次 KV,足以烧穿
// 1000 写/天的免费额度。这里直接覆盖"稳定播放不应重锚"和"真实 seek 应该重锚"两个
// 分支,防止这个判断以后又被改回逐字节比较。
func TestUpdatePosition_SteadyPlaybackDoesNotReanchor(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	if reanchor, _ := p.updatePosition(nowAt(0)); !reanchor {
		t.Fatalf("first observation should reanchor")
	}

	// 接下来连续 5 轮,每轮间隔 5 秒(= pollInterval),Elapsed 按真实播放时间正常前进——
	// 这正是 AppleScript 实时读法下,稳定播放时每一轮都会看到的样子。
	base := 10.0
	for i := 1; i <= 5; i++ {
		p.cur.Elapsed = base + float64(i)*5
		reanchor, _ := p.updatePosition(nowAt(i * 5))
		if reanchor {
			t.Fatalf("round %d: steady playback must not reanchor (elapsed=%v prevElapse=%v)", i, p.cur.Elapsed, p.prevElapse)
		}
	}
}

func TestUpdatePosition_RealSeekReanchors(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	p.updatePosition(nowAt(0)) // seed first observation

	// 用户把进度条拖到了 90s——跟按 gap*rate 预测的 15s 差得远,必须重锚。
	p.cur.Elapsed = 90
	reanchor, _ := p.updatePosition(nowAt(5))
	if !reanchor {
		t.Fatalf("a real seek (10s -> 90s over one 5s poll) must reanchor")
	}
	if p.trackPos != 90 {
		t.Fatalf("trackPos should snap to the seeked-to position, got %v", p.trackPos)
	}
}

// 回归测试:2026-08-04 实测排查坐实的 bug——poll() 里 appleMusicPosition() 校准
// p.cur.Position/AnchorTS(这一轮推给网页的值)之后,如果不回写 p.trackPos/p.prevWall,
// 下一轮 updatePosition() 的"稳定播放"分支(p.trackPos += gap*rate)会从校准前那个
// 旧值继续累加,校准效果只在当轮昙花一现。这里直接模拟 poll() 里那次回写,验证下一轮
// updatePosition() 确实从校准后的值(而不是校准前的旧 trackPos)继续外推。
func TestAppleScriptCorrectionFeedsBackIntoTrackPos(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	p.updatePosition(nowAt(0)) // seed first observation

	p.cur.Elapsed = 15
	if reanchor, _ := p.updatePosition(nowAt(5)); reanchor {
		t.Fatalf("steady playback must not reanchor")
	}
	if p.trackPos != 15 {
		t.Fatalf("trackPos before correction should be 15, got %v", p.trackPos)
	}

	// 模拟 poll() 里 appleMusicPosition() 校准命中:真实播放头比内部累加器悄悄快了
	// 0.5s,poll() 应把 p.trackPos/p.prevWall 一并回写成校准后的值+对应时刻。
	p.trackPos = 15.5
	p.prevWall = nowAt(5)

	// 媒体控件自己那条独立的 Elapsed 跟踪流照常前进(不受这次校准影响,见 poller.go
	// 里 p.prevElapse 单独维护的注释)——5 秒后到 20,没有触发 seek 容差。
	p.cur.Elapsed = 20
	if reanchor, _ := p.updatePosition(nowAt(10)); reanchor {
		t.Fatalf("steady playback after correction must not reanchor")
	}
	if p.trackPos != 20.5 {
		t.Fatalf("trackPos should extrapolate from the corrected 15.5 baseline (want 20.5), got %v — correction was discarded", p.trackPos)
	}
}

func TestUpdatePosition_PauseDoesNotReanchor(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	p.updatePosition(nowAt(0))

	p.cur.Playing = false
	p.cur.Rate = 0
	// 暂停这个事件本身(以及暂停后位置冻结、多轮不动)都不该重锚——pushRelayState 那边
	// 靠 key 从 mac|X 变成 macpause|X 自己触发过一次写入,不需要 updatePosition 再帮它
	// 强制重写(见 poller.go 里 !p.cur.Playing 分支的注释)。
	for i := 1; i <= 4; i++ {
		reanchor, _ := p.updatePosition(nowAt(i * 5))
		if reanchor {
			t.Fatalf("round %d: paused must not reanchor", i)
		}
	}
}

// ---- Spotify 自然切歌锚点超前校正(2026-08-20,机制见 poller.posBias 注释) ----------

func TestNaturalAdvanceCorrection(t *testing.T) {
	cases := []struct {
		name               string
		reported, overrun  float64
		wantOK             bool
		wantSeed, wantBias float64
	}{
		// 实测样本(Forever Love→在那遙遠的地方):元数据提前 0.837s,首笔读数 0.048,
		// 整曲恒定偏置 +0.885s。
		{"measured real transition", 0.048, -0.837, true, -0.837, 0.885},
		// 元数据晚于真声切换(overrun 为正)同样成立:真值=越界量。
		{"late metadata switch", 1.5, 0.6, true, 0.6, 0.9},
		// 手动跳歌(旧曲远没播完)——窗口外,不校正。
		{"manual skip mid-track", 0.3, -188, false, 0, 0},
		// 偏置太小(Apple Music 级精度/无预载):不值得校正。
		{"bias below noise floor", 0.3, 0.28, false, 0, 0},
		// 偏置超上限:换歌瞬间读数还挂着上一首的陈旧值(08-18 实测 30.3 vs 0.02),
		// 或模型失效——放弃,退回原样采信(seek 分支会兜住陈旧值)。
		{"stale first sample", 30.3, -0.5, false, 0, 0},
		// 偏置为负(读数落后连续性真值):模型外,不校正。
		{"negative bias", 0.1, 0.9, false, 0, 0},
	}
	for _, c := range cases {
		seed, bias, ok := naturalAdvanceCorrection(c.reported, c.overrun)
		if ok != c.wantOK {
			t.Fatalf("%s: ok=%v want %v", c.name, ok, c.wantOK)
		}
		if !ok {
			continue
		}
		if diff := seed - c.wantSeed; diff > 1e-9 || diff < -1e-9 {
			t.Fatalf("%s: seed=%v want %v", c.name, seed, c.wantSeed)
		}
		if diff := bias - c.wantBias; diff > 1e-9 || diff < -1e-9 {
			t.Fatalf("%s: bias=%v want %v", c.name, bias, c.wantBias)
		}
	}
}

// 端到端走 updatePosition:自然切歌按旧曲连续性播种(允许负值,发布口钳 0),之后稳定
// 播放不再超前;真实 seek 清偏置改信原始读数。时间线:旧曲时长 293s,t=10 时跟踪到
// 290s → 真声应在 t=13 结束;Spotify 在 t=12.1 提前切元数据并打锚(超前 0.9s),采集器
// t=12.5 发现换歌,此刻原始读数=锚点年龄 0.4s、连续性真值=-0.5s(旧曲还剩 0.5s)。
func TestUpdatePosition_NaturalAdvanceSeedsFromContinuity(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 280, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur.Elapsed = 285
	p.updatePosition(nowAt(5))
	p.cur.Elapsed = 290
	p.updatePosition(nowAt(10))

	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 236.266, Playing: true, Elapsed: 0.4, Rate: 1, Bundle: spotifyBundleID}
	reanchor, _ := p.updatePosition(baseTestTime.Add(12500 * time.Millisecond))
	if !reanchor {
		t.Fatalf("track change must reanchor")
	}
	if diff := p.trackPos - (-0.5); diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("seed should be continuity overrun -0.5, got %v", p.trackPos)
	}
	if diff := p.posBias - 0.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("bias should be 0.9, got %v", p.posBias)
	}
	if p.cur.Position != 0 {
		t.Fatalf("published position must clamp negative seed to 0, got %v", p.cur.Position)
	}

	// 稳定播放 5s:内部从 -0.5 累加到 4.5(=真声位置),不因原始读数超前而漂快。
	p.cur.Elapsed = 5.4
	reanchor, _ = p.updatePosition(baseTestTime.Add(17500 * time.Millisecond))
	if reanchor {
		t.Fatalf("steady play after natural advance must not reanchor")
	}
	if diff := p.trackPos - 4.5; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("steady position should be 4.5 (true audio), got %v", p.trackPos)
	}

	// 真实 seek 到 60s:Spotify 重打对齐真声的锚点,偏置作废、改信原始读数。
	p.cur.Elapsed = 60.2
	reanchor, _ = p.updatePosition(baseTestTime.Add(22500 * time.Millisecond))
	if !reanchor {
		t.Fatalf("real seek must reanchor")
	}
	if p.posBias != 0 {
		t.Fatalf("real seek must clear posBias, got %v", p.posBias)
	}
	if diff := p.trackPos - 60.2; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("seek should adopt raw reading 60.2, got %v", p.trackPos)
	}
}

// 手动跳歌(旧曲远没播完)必须保持原行为:原样采信读数、不设偏置。
func TestUpdatePosition_ManualSkipKeepsRawSeed(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 100, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))

	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 0.3, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5))
	if p.posBias != 0 {
		t.Fatalf("manual skip must not set bias, got %v", p.posBias)
	}
	if diff := p.trackPos - 0.3; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("manual skip should seed raw 0.3, got %v", p.trackPos)
	}
}

// 自然切歌之后暂停:冻结的 elapsedTime 带着同一个超前锚点的值,要扣掉偏置再当冻结位置。
func TestUpdatePosition_PauseSubtractsNaturalAdvanceBias(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5)) // overrun=2, bias=1.9? no: 290+5-293=2 → bias=3.9-2=1.9
	if diff := p.posBias - 1.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("expected bias 1.9, got %v", p.posBias)
	}
	p.cur.Playing = false
	p.cur.Rate = 0
	p.cur.Elapsed = 20.0 // 冻结的原始读数(仍超前 1.9s)
	p.updatePosition(nowAt(10))
	if diff := p.trackPos - 18.1; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("paused position should subtract bias (20-1.9=18.1), got %v", p.trackPos)
	}
}

// 暂停→恢复(同曲)必须继承偏置:恢复时 Spotify 重打的锚点值来自仍超前的内部计数器,
// 走 seek 分支清偏置会让恢复后整段重新偏快、且与 App 侧语义相反(2026-08-20 对抗审查 high)。
func TestUpdatePosition_ResumeKeepsNaturalAdvanceBias(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5)) // overrun=2 → bias=1.9

	p.cur.Playing = false
	p.cur.Rate = 0
	p.cur.Elapsed = 20.0
	p.updatePosition(nowAt(10)) // 暂停:冻结值扣偏置

	p.cur.Playing = true
	p.cur.Rate = 1
	p.cur.Elapsed = 22.0 // 恢复 ~2s 后的原始读数(仍带 1.9s 偏置)
	reanchor, _ := p.updatePosition(nowAt(15))
	if !reanchor {
		t.Fatalf("resume should reanchor (push relay promptly)")
	}
	if diff := p.posBias - 1.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("resume must keep bias 1.9, got %v", p.posBias)
	}
	if diff := p.trackPos - 20.1; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("resume position should be 22-1.9=20.1, got %v", p.trackPos)
	}
}

// 暂停中在播放器里拖进度条(冻结值跳变)= Spotify 已重打对齐真声的锚点,旧偏置作废。
func TestUpdatePosition_PausedExternalSeekClearsBias(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5)) // bias=1.9

	p.cur.Playing = false
	p.cur.Rate = 0
	p.cur.Elapsed = 20.0
	p.updatePosition(nowAt(10)) // 第一拍暂停(prevPlaying 还是 true,只冻结)
	p.cur.Elapsed = 80.0        // 暂停中拖到 80s
	p.updatePosition(nowAt(15))
	if p.posBias != 0 {
		t.Fatalf("paused external seek must clear bias, got %v", p.posBias)
	}
	if diff := p.trackPos - 80.0; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("paused position should adopt raw 80, got %v", p.trackPos)
	}
}

// 瞬时读取失败(快照陈旧)不能让陈旧 Elapsed 走 seek 分支清偏置/倒回位置;且陈旧轮之后
// 的第一笔新鲜读数也不能被误判成 seek(prevElapse@prevWall 配对要保持一致)。
func TestUpdatePosition_StaleSnapshotKeepsBiasAndContinuity(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5)) // seed=2, bias=1.9

	p.snapshotStale = true // 这一轮 getState 失败,p.cur 原样残留(Elapsed 还是 3.9)
	reanchor, _ := p.updatePosition(nowAt(10))
	if reanchor {
		t.Fatalf("stale round must not reanchor")
	}
	if diff := p.posBias - 1.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("stale round must keep bias, got %v", p.posBias)
	}
	if diff := p.trackPos - 7.0; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("stale round should wall-clock advance 2+5=7, got %v", p.trackPos)
	}

	p.snapshotStale = false
	p.cur.Elapsed = 13.9 // 新鲜读数:原始时钟 3.9 + 10s
	reanchor, _ = p.updatePosition(nowAt(15))
	if reanchor {
		t.Fatalf("first fresh round after stale must not be misjudged as seek")
	}
	if diff := p.posBias - 1.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("bias must survive stale→fresh, got %v", p.posBias)
	}
	if diff := p.trackPos - 12.0; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("position should be 2+10=12, got %v", p.trackPos)
	}
}

// 单曲循环(repeat-one)的 gapless 回绕:key 不变,但与跨曲自然切歌同机制——要重估偏置
// 而不是走 seek 分支清掉。形态(b):同一拍观察到回绕(上一拍外推还在结尾前),
// loopRestart 连续性判定同拍触发(收听计数不受影响)。
func TestUpdatePosition_RepeatOneWrapSamePoll(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 193, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur.Elapsed = 198
	p.updatePosition(nowAt(5)) // 稳定播放到 198

	// 真声于 t=7 结束,锚点在 t=6.1 提前打好:t=10 原始读数=3.9,连续性真值=198+5-200=3。
	p.cur.Elapsed = 3.9
	reanchor, loopRestart := p.updatePosition(nowAt(10))
	if !reanchor || !loopRestart {
		t.Fatalf("same-poll wrap should reanchor + fire loopRestart, got %v/%v", reanchor, loopRestart)
	}
	if diff := p.posBias - 0.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("wrap should re-estimate bias 0.9, got %v", p.posBias)
	}
	if diff := p.trackPos - 3.0; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("wrap should seed continuity overrun 3.0, got %v", p.trackPos)
	}
}

// 回绕形态(a):上一拍外推先越过时长、loopRestart 已把 trackPos 归到新一遍,这一拍
// 原始读数才回绕——偏置要以"已归位的新一遍位置"为真值重估,不能走 seek 分支清掉。
func TestUpdatePosition_RepeatOneWrapAfterLoopRestart(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 195, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur.Elapsed = 200
	_, loopRestart := p.updatePosition(nowAt(5)) // 外推达到 200 → loopRestart 先归位到 0
	if !loopRestart {
		t.Fatalf("extrapolation crossing duration should fire loopRestart")
	}
	if p.trackPos != 0 {
		t.Fatalf("loopRestart should wrap trackPos to remainder 0, got %v", p.trackPos)
	}

	p.cur.Elapsed = 3.4 // 这一拍原始读数才回绕:真值=0+2.5,bias=3.4-2.5=0.9
	reanchor, _ := p.updatePosition(baseTestTime.Add(7500 * time.Millisecond))
	if !reanchor {
		t.Fatalf("post-loopRestart wrap should reanchor")
	}
	if diff := p.posBias - 0.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("wrap(a) should re-estimate bias 0.9, got %v", p.posBias)
	}
	if diff := p.trackPos - 2.5; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("wrap(a) should keep continuity 2.5, got %v", p.trackPos)
	}
}

// 旧曲来自别的播放器(auto 模式跨播放器切歌)不能拿去当 Spotify 新曲的真值。
func TestUpdatePosition_CrossPlayerOldTrackNoCorrection(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: qqMusicBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5))
	if p.posBias != 0 {
		t.Fatalf("cross-player old track must not seed bias, got %v", p.posBias)
	}
	if diff := p.trackPos - 3.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("should seed raw 3.9, got %v", p.trackPos)
	}
}

// 自然切歌负播种(旧曲真声未完)的发布口:位置 0 @ 未来 |seed| 秒,网页外推 age>0 才加,
// 自然停在曲首等真声;锚在"现在"的话 relay 按变化去重最长 4 分钟不重写,网页整段超前。
func TestUpdatePosition_NegativeSeedPublishesFutureAnchor(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 292, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 0.4, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(2)) // overrun=292+2-293=1? → 用 -1 场景:改用 nowAt 更早
	// 上面 overrun=+1(元数据晚于真声),seed=+1 不为负;重新构造负播种:
	p2 := &poller{}
	p2.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p2.updatePosition(nowAt(0))
	p2.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 0.4, Rate: 1, Bundle: spotifyBundleID}
	p2.updatePosition(baseTestTime.Add(2500 * time.Millisecond)) // overrun=290+2.5-293=-0.5, bias=0.9, seed=-0.5
	if p2.cur.Position != 0 {
		t.Fatalf("negative seed must publish position 0, got %v", p2.cur.Position)
	}
	wantAt := baseTestTime.Add(2500 * time.Millisecond).Add(500 * time.Millisecond)
	if d := p2.cur.AnchorTS.Sub(wantAt); d > time.Millisecond || d < -time.Millisecond {
		t.Fatalf("anchor should be future-dated by 0.5s, got %v (want %v)", p2.cur.AnchorTS, wantAt)
	}
	if diff := p2.trackPos - (-0.5); diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("internal trackPos should stay -0.5, got %v", p2.trackPos)
	}
}
