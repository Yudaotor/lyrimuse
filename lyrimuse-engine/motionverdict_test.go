package main

import (
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// motionTestImage 在 dir 下写一张 120×120 的灰度图,返回 file:// 地址。
func motionTestImage(t *testing.T, dir, name string, fill func(x, y int) uint8) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 120, 120))
	for y := 0; y < 120; y++ {
		for x := 0; x < 120; x++ {
			v := fill(x, y)
			img.Set(x, y, color.RGBA{R: v, G: v, B: v, A: 255})
		}
	}
	path := filepath.Join(dir, name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	return "file://" + path
}

func motionTestLeft(x, _ int) uint8 {
	if x < 60 {
		return 20
	}
	return 230
}

func motionTestTop(_, y int) uint8 {
	if y < 60 {
		return 20
	}
	return 230
}

// withMotionAlbum 在动态封面缓存里放一张专辑,测试结束还原。
func withMotionAlbum(t *testing.T, id string, mc motionCover) {
	t.Helper()
	motionCoverMu.Lock()
	prev, had := motionCoverCache[id]
	motionCoverCache[id] = mc
	motionCoverMu.Unlock()
	t.Cleanup(func() {
		motionCoverMu.Lock()
		defer motionCoverMu.Unlock()
		if had {
			motionCoverCache[id] = prev
		} else {
			delete(motionCoverCache, id)
		}
	})
}

// motionTestAlbum:一张有动态封面的专辑(首帧和 Apple 官方封面都是左右分的那张),返回首帧、跟它同一张的封面、另一张封面、
// 动画地址和指向这张专辑的 apple_music_url。
func motionTestAlbum(t *testing.T, id string) (preview, same, other, master, appleURL string) {
	t.Helper()
	dir := t.TempDir()
	preview = motionTestImage(t, dir, "preview.png", motionTestLeft)
	same = motionTestImage(t, dir, "same.png", motionTestLeft)
	other = motionTestImage(t, dir, "other.png", motionTestTop)
	master = "https://mvod.itunes.apple.com/itunes-assets/" + id + "_default.m3u8"
	withMotionAlbum(t, id, motionCover{Master: master, PreviewFrame: preview, AlbumArtwork: preview, AlbumArtworkChecked: true,
		Checked: true})
	return preview, same, other, master, "https://music.apple.com/us/album/love/" + id + "?i=1421416328&uo=4"
}

// 动态封面结论绑在核它时那张封面上:封面换过、封面清空了、早先没记对照封面的,都算作废。
func TestMotionVerdictCurrent(t *testing.T) {
	const a, b = "https://p1.music.126.net/a.jpg", "https://p1.music.126.net/b.jpg"
	for _, c := range []struct {
		name           string
		e              enrichEntry
		current, stale bool
	}{
		{"没有结论", enrichEntry{CoverURL: a}, false, false},
		{"对着这张核过、有动画", enrichEntry{CoverURL: a, MotionCoverURL: "m", MotionCoverChecked: true, MotionCoverFor: a}, true, false},
		{"对着这张核过、没有动画", enrichEntry{CoverURL: a, MotionCoverChecked: true, MotionCoverFor: a}, true, false},
		{"只有动画地址", enrichEntry{CoverURL: a, MotionCoverURL: "m", MotionCoverFor: a}, true, false},
		{"封面后来换了", enrichEntry{CoverURL: b, MotionCoverURL: "m", MotionCoverChecked: true, MotionCoverFor: a}, false, true},
		{"早先没记对照封面", enrichEntry{CoverURL: a, MotionCoverURL: "m", MotionCoverChecked: true}, false, true},
		{"封面清空了", enrichEntry{MotionCoverChecked: true, MotionCoverFor: a}, false, true},
	} {
		if got := motionVerdictCurrent(c.e); got != c.current {
			t.Errorf("%s: motionVerdictCurrent = %v", c.name, got)
		}
		if got := motionVerdictStale(c.e); got != c.stale {
			t.Errorf("%s: motionVerdictStale = %v", c.name, got)
		}
	}
}

func TestRecordAndClearMotionVerdict(t *testing.T) {
	e := enrichEntry{CoverURL: "https://p1.music.126.net/a.jpg"}
	e.recordMotionVerdict("m", "p", true)
	if e.MotionCoverURL != "m" || e.MotionPreviewURL != "p" || !e.MotionCoverChecked || !e.MotionCoverIdentityVerified ||
		e.MotionCoverFor != e.CoverURL {
		t.Fatalf("结论整组记下、对照封面是现在这张: %+v", e)
	}
	e.recordMotionVerdict("", "", false)
	if e.MotionCoverURL != "" || e.MotionPreviewURL != "" || !e.MotionCoverChecked || e.MotionCoverIdentityVerified ||
		e.MotionCoverFor != e.CoverURL {
		t.Fatalf("没有动画也是结论: %+v", e)
	}
	e.clearMotionVerdict()
	if e.MotionCoverURL != "" || e.MotionCoverChecked || e.MotionCoverFor != "" || e.MotionCoverIdentityVerified {
		t.Fatalf("整组清掉: %+v", e)
	}
}

// 封面换过的条目按现在这张重核:换成别的图就摘掉动画,换回同一张又挂上,两种都记下对照封面;结论已经是对着这张核的不动;
// 专辑页没查成时原样不动;两条来路都没有专辑 ID 时整组清掉。
func TestFillMotionCoverRechecksStaleVerdict(t *testing.T) {
	const id = "1421415958"
	preview, same, other, master, appleURL := motionTestAlbum(t, id)
	ctx := context.Background()

	e := enrichEntry{CoverURL: other, AppleURL: appleURL, MotionCoverURL: master, MotionPreviewURL: preview,
		MotionCoverChecked: true, MotionCoverFor: same}
	if !e.fillMotionCover(ctx, "Prince", "Love", "单曲发行") {
		t.Fatal("取得到图时该有定论")
	}
	if e.MotionCoverURL != "" || e.MotionPreviewURL != "" || !e.MotionCoverChecked || e.MotionCoverFor != other {
		t.Fatalf("换成另一张图:摘掉动画、记下对照封面: %+v", e)
	}

	e.CoverURL = same
	if !e.fillMotionCover(ctx, "Prince", "Love", "单曲发行") || e.MotionCoverURL != master || e.MotionCoverFor != same {
		t.Fatalf("换回同一张图:挂上动画: %+v", e)
	}

	current := enrichEntry{CoverURL: "file:///nope/missing.png", AppleURL: appleURL, MotionCoverChecked: true,
		MotionCoverFor: "file:///nope/missing.png"}
	if !current.fillMotionCover(ctx, "Prince", "Love", "单曲发行") || current.MotionCoverURL != "" || !current.MotionCoverChecked {
		t.Fatalf("结论已经是对着这张核的:不取图、不动: %+v", current)
	}

	const pendingID = 1421415959
	motionCoverMu.Lock()
	motionCoverInflight[pendingID] = true
	motionCoverMu.Unlock()
	t.Cleanup(func() {
		motionCoverMu.Lock()
		delete(motionCoverInflight, pendingID)
		motionCoverMu.Unlock()
	})
	pending := enrichEntry{CoverURL: same, AppleURL: "https://music.apple.com/us/album/x/1421415959?i=1&uo=4",
		MotionCoverURL: master, MotionCoverChecked: true, MotionCoverFor: other}
	if pending.fillMotionCover(ctx, "Prince", "Love", "单曲发行") ||
		pending.MotionCoverURL != master || pending.MotionCoverFor != other {
		t.Fatalf("专辑页没查成:原样不动、没有定论: %+v", pending)
	}

	noAlbum := enrichEntry{CoverURL: same, MotionCoverURL: master, MotionCoverChecked: true, MotionCoverFor: other}
	if !noAlbum.fillMotionCover(ctx, "查无此人", "查无此歌", "") || noAlbum.MotionCoverURL != "" || noAlbum.MotionCoverChecked ||
		noAlbum.MotionCoverFor != "" {
		t.Fatalf("没有专辑 ID:整组清掉: %+v", noAlbum)
	}
}

// 换过封面的条目重核一次就把整组结论(连对照封面)写回缓存;再调一次不动;核的这段时间封面又换了的不写。
func TestRecheckMotionCoverAgainstCurrentCover(t *testing.T) {
	const id = "1421415958"
	preview, same, other, master, appleURL := motionTestAlbum(t, id)
	key := enrichKey("Prince", "Love", "单曲发行")
	setUpEnrichEditTest(t, map[string]enrichEntry{key: {CoverURL: other, AppleURL: appleURL, MotionCoverURL: master,
		MotionPreviewURL: preview, MotionCoverChecked: true, MotionCoverFor: same, Lyrics: bt("[00:01.00]词")}})
	ctx := context.Background()
	if !recheckMotionCoverAgainstCurrentCover(ctx, key, "Love", "单曲发行") {
		t.Fatal("结论作废的条目该重核并写回")
	}
	e, _ := cacheEntry(t, key)
	if e.MotionCoverURL != "" || !e.MotionCoverChecked || e.MotionCoverFor != other || !e.Lyrics.EqualString("[00:01.00]词") {
		t.Fatalf("写回整组结论,别的字段不动: %+v", e)
	}
	if recheckMotionCoverAgainstCurrentCover(ctx, key, "Love", "单曲发行") {
		t.Fatal("已经是对着这张核的,不该再写")
	}
	if recheckMotionCoverAgainstCurrentCover(ctx, enrichKey("Nobody", "Nothing", ""), "Nothing", "") {
		t.Fatal("缓存里没有的条目不写")
	}
}

// 换上新封面那一刻,外围补全这一轮落不到留用封面上时,都按「结论是不是对着现在这张核的」决定要不要重核。
func TestMotionCoverNeedsRecheckAfterCoverChange(t *testing.T) {
	const a, b = "https://p1.music.126.net/a.jpg", "https://p1.music.126.net/b.jpg"
	if !motionCoverNeedsRecheckAgainstOwnCover(false, enrichEntry{CoverURL: b, MotionCoverURL: "m", MotionCoverChecked: true,
		MotionCoverFor: a}) {
		t.Error("封面换过、动画是对着旧封面核的:要重核")
	}
	if motionCoverNeedsRecheckAgainstOwnCover(false, enrichEntry{CoverURL: a, MotionCoverURL: "m", MotionCoverChecked: true,
		MotionCoverFor: a}) {
		t.Error("结论就是对着这张核的:不重核")
	}
}

// 后台补封面那一遍:只重核结论作废的条目,按 key 排;摘掉动画的计进 dropped;要取图的条目之间才等;要取图的连着没查成就停。
func TestCoverSweepRecheckStaleMotion(t *testing.T) {
	const id = "1421415958"
	_, same, other, master, appleURL := motionTestAlbum(t, id)
	stale := func(cover string) enrichEntry {
		return enrichEntry{CoverURL: cover, AppleURL: appleURL, MotionCoverURL: master, MotionCoverChecked: true, MotionCoverFor: same}
	}
	setUpEnrichEditTest(t, map[string]enrichEntry{
		"A|a|x": stale(other),
		"B|b|x": {CoverURL: same, AppleURL: appleURL, MotionCoverURL: master, MotionCoverChecked: true, MotionCoverFor: same},
		"C|c|x": {CoverURL: other, MotionCoverChecked: true, MotionCoverFor: same},
		"D|d|x": {CoverURL: other},
	})
	savedRecheck, savedWait, savedSave := coverSweepRecheckMotion, coverSweepWait, coverSweepSave
	t.Cleanup(func() { coverSweepRecheckMotion, coverSweepWait, coverSweepSave = savedRecheck, savedWait, savedSave })
	waits, saves := 0, 0
	coverSweepWait = func(context.Context, time.Duration) { waits++ }
	coverSweepSave = func() { saves++ }
	var calls []string
	coverSweepRecheckMotion = func(_ context.Context, key, _, _ string) bool {
		calls = append(calls, key)
		enrichMu.Lock()
		defer enrichMu.Unlock()
		e := enrichCache[key]
		e.recordMotionVerdict("", "", false)
		enrichCache[key] = e
		return true
	}
	pass := coverSweepRecheckStaleMotion(context.Background())
	if len(calls) != 2 || calls[0] != "A|a|x" || calls[1] != "C|c|x" {
		t.Fatalf("只重核结论作废的,按 key 排: %v", calls)
	}
	if pass.rechecked != 2 || pass.dropped != 1 || pass.offline {
		t.Fatalf("重核 2 条、摘掉 1 条: %+v", pass)
	}
	if waits != 1 || saves != 1 {
		t.Fatalf("只有要取图的那条之后等一下,收尾存一次盘: waits=%d saves=%d", waits, saves)
	}

	entries := map[string]enrichEntry{}
	for _, k := range []string{"E1|e|x", "E2|e|x", "E3|e|x", "E4|e|x", "E5|e|x", "E6|e|x"} {
		entries[k] = stale(other)
	}
	setUpEnrichEditTest(t, entries)
	calls = nil
	coverSweepRecheckMotion = func(ctx context.Context, key, _, _ string) bool {
		calls = append(calls, key)
		noteNetworkRoundOutcome(ctx, errors.New("dial tcp: no route to host"))
		return false
	}
	if pass := coverSweepRecheckStaleMotion(context.Background()); !pass.offline || len(calls) != coverSweepOfflineLimit {
		t.Fatalf("请求全失败的连着 %d 条就停: %+v calls=%d", coverSweepOfflineLimit, pass, len(calls))
	}

	// 取图有回话、只是比不成(404、解不开),或一个请求都没发(设备封面文件没了):都不算离线,整遍跑完。
	for name, sent := range map[string]bool{"answered": true, "no request": false} {
		calls = nil
		coverSweepRecheckMotion = func(ctx context.Context, key, _, _ string) bool {
			calls = append(calls, key)
			if sent {
				noteNetworkRoundOutcome(ctx, nil)
			}
			return false
		}
		if pass := coverSweepRecheckStaleMotion(context.Background()); pass.offline || len(calls) != len(entries) {
			t.Fatalf("%s: 不算离线,%d 条都核: %+v calls=%d", name, len(entries), pass, len(calls))
		}
	}

	// 只数这一条的请求:别处成功的请求不把它记成查成,失败的那几条中间夹一条有回话的就重新数。
	calls = nil
	coverSweepRecheckMotion = func(ctx context.Context, key, _, _ string) bool {
		calls = append(calls, key)
		noteNetworkRoundOutcome(context.Background(), nil)
		if key == "E3|e|x" {
			noteNetworkRoundOutcome(ctx, nil)
		} else {
			noteNetworkRoundOutcome(ctx, errors.New("timeout"))
		}
		return false
	}
	if pass := coverSweepRecheckStaleMotion(context.Background()); pass.offline || len(calls) != len(entries) {
		t.Fatalf("中间有一条查成就重新数: %+v calls=%d", pass, len(calls))
	}
}

// 现在认的专辑给不出动画(Apple 链接、目录锚点换成了别的版本)时:原来那段跟现在这张封面还是同一张图就留着;对不上就摘;
// 原来那段的首帧取不到就原样不动、没有定论。
func TestFillMotionCoverKeepsMatchingMotionWhenAlbumHasNone(t *testing.T) {
	dir := t.TempDir()
	preview := motionTestImage(t, dir, "old-preview.png", motionTestLeft)
	same := motionTestImage(t, dir, "same.png", motionTestLeft)
	other := motionTestImage(t, dir, "other.png", motionTestTop)
	const id = "1421415960"
	withMotionAlbum(t, id, motionCover{Checked: true})
	appleURL := "https://music.apple.com/us/album/x/" + id + "?i=1&uo=4"
	old := "https://mvod.itunes.apple.com/itunes-assets/old_default.m3u8"
	ctx := context.Background()

	keep := enrichEntry{CoverURL: same, AppleURL: appleURL, MotionCoverURL: old, MotionPreviewURL: preview, MotionCoverChecked: true,
		MotionCoverIdentityVerified: true, MotionCoverFor: other}
	if !keep.fillMotionCover(ctx, "A", "B", "C") || keep.MotionCoverURL != old || keep.MotionPreviewURL != preview ||
		keep.MotionCoverIdentityVerified || keep.MotionCoverFor != same {
		t.Fatalf("原来那段跟现在的封面是同一张图:留着、记下对照封面、按首帧比对放行: %+v", keep)
	}

	drop := enrichEntry{CoverURL: other, AppleURL: appleURL, MotionCoverURL: old, MotionPreviewURL: preview, MotionCoverChecked: true,
		MotionCoverFor: same}
	if !drop.fillMotionCover(ctx, "A", "B", "C") || drop.MotionCoverURL != "" || !drop.MotionCoverChecked || drop.MotionCoverFor != other {
		t.Fatalf("原来那段跟现在的封面对不上:摘掉: %+v", drop)
	}

	missing := "file://" + filepath.Join(dir, "gone.png")
	pending := enrichEntry{CoverURL: same, AppleURL: appleURL, MotionCoverURL: old, MotionPreviewURL: missing, MotionCoverChecked: true,
		MotionCoverFor: other}
	if pending.fillMotionCover(ctx, "A", "B", "C") || pending.MotionCoverURL != old || pending.MotionCoverFor != other {
		t.Fatalf("原来那段的首帧取不到:原样不动、没有定论: %+v", pending)
	}
}
