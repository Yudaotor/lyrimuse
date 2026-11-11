package main

import (
	"context"
	"testing"
)

// 来源列表:认得的子集照收,缺失 / 一个都认不得时两处都找;结论记的来源键,两处都找为空串(存量条目照旧算数)。
func TestResolveMotionCoverSources(t *testing.T) {
	cases := []struct {
		in           []string
		apple, other bool
		key          string
	}{
		{nil, true, true, ""},
		{[]string{}, true, true, ""},
		{[]string{"bogus"}, true, true, ""},
		{[]string{"apple"}, true, false, "apple"},
		{[]string{"other"}, false, true, "other"},
		{[]string{"other", "apple", "bogus"}, true, true, ""},
	}
	for _, c := range cases {
		apple, other := resolveMotionCoverSources(c.in)
		key := motionCoverSourcesKey(featureFlags{MotionCoverSkipApple: !apple, MotionCoverSkipOther: !other})
		if apple != c.apple || other != c.other || key != c.key {
			t.Errorf("%v → apple=%v other=%v key=%q, want %v %v %q", c.in, apple, other, key, c.apple, c.other, c.key)
		}
	}
	f := buildFeatureFlags(featureFlagsFile{MotionCoverSources: []string{"other"}})
	if !f.MotionCoverSkipApple || f.MotionCoverSkipOther {
		t.Errorf("buildFeatureFlags 没接上: %+v", f)
	}
}

func withMotionSources(t *testing.T, apple, other bool) {
	t.Helper()
	f := features()
	f.MotionCoverSkipApple, f.MotionCoverSkipOther = !apple, !other
	withFeatures(t, f)
}

// 关了其余几支:到 Apple 为止,前面核出「没有」就记没有、压根没核就整组清掉;记下的来源键是 apple;播到时不再为那几支重核。
func TestMotionCoverSourcesOtherOff(t *testing.T) {
	ctx := context.Background()
	found := `{"code":200,"data":{"videoPlayUrl":"http://dcover.music.126.net/a.mp4"}}`
	withNeteaseMotion(t, "186016", &found)
	withMotionSources(t, true, false)
	const page = "https://music.163.com/song?id=186016"
	e := enrichEntry{CoverURL: "c", NeteaseURL: page}
	if !e.motionVerdictFromQQ(ctx, true) || e.MotionCoverURL != "" || !e.MotionCoverChecked || e.MotionCoverSources != "apple" {
		t.Errorf("Apple 核过没有: %+v", e)
	}
	e = enrichEntry{CoverURL: "c", NeteaseURL: page, MotionCoverURL: "old", MotionCoverChecked: true}
	if !e.motionVerdictFromQQ(ctx, false) || e.MotionCoverURL != "" || e.MotionCoverChecked {
		t.Errorf("没有可核的: %+v", e)
	}
	e = enrichEntry{CoverURL: "c", MotionCoverFor: "c", MotionCoverChecked: true, MotionCoverSources: "apple", QQAlbumMid: "002ENNC51FIhXc"}
	if motionCoverFallbackUnasked(e) {
		t.Error("关了其余几支还要为 QQ 重核")
	}
}

// 关了 Apple:Apple 那张专辑核过「没有」也不算数,直接从 QQ 那支开始(这里几支都没有可核的,整组清掉);
// 关了 Apple 不为 Apple 那支回填。
func TestMotionCoverSourcesAppleOff(t *testing.T) {
	const id = 1440000001
	motionCoverMu.Lock()
	prev, had := motionCoverCache["1440000001"]
	motionCoverCache["1440000001"] = motionCover{Checked: true}
	motionCoverMu.Unlock()
	t.Cleanup(func() {
		motionCoverMu.Lock()
		if had {
			motionCoverCache["1440000001"] = prev
		} else {
			delete(motionCoverCache, "1440000001")
		}
		motionCoverMu.Unlock()
	})
	apple := "https://music.apple.com/cn/album/x/1440000001?i=1"
	if motionCoverAlbumIDFromAppleURL(apple) != id {
		t.Fatal("测试用的专辑 ID 认不出")
	}
	withMotionSources(t, true, true)
	e := enrichEntry{CoverURL: "c", AppleURL: apple}
	if !e.motionVerdictFromAlbum(context.Background(), "a", "t", "al") || !e.MotionCoverChecked {
		t.Fatalf("两处都找时 Apple 核过没有应记「没有」: %+v", e)
	}
	withMotionSources(t, false, true)
	e = enrichEntry{CoverURL: "c", AppleURL: apple}
	if !e.motionVerdictFromAlbum(context.Background(), "a", "t", "al") || e.MotionCoverChecked {
		t.Errorf("关了 Apple 还在看 Apple 那张专辑: %+v", e)
	}
	if motionCoverWorthBackfill(enrichEntry{AppleURL: "https://music.apple.com/cn/album/x/1440000002"}, "a", "t", "al") {
		t.Error("关了 Apple 还为 Apple 那支回填")
	}
}

// 换了一组来源:原来的结论不算数(播到时重核),重核记录按条目 + 来源分开记;封面没换时后台补封面那一遍不为它整库重来。
func TestMotionCoverSourcesChangeInvalidatesVerdict(t *testing.T) {
	withMotionSources(t, true, true)
	e := enrichEntry{CoverURL: "c"}
	e.recordMotionVerdict("qqmv:abcdef", "", true)
	if !motionVerdictCurrent(e) || motionVerdictSourcesChanged(e) || e.MotionCoverSources != "" {
		t.Fatalf("两处都找时记下的结论: %+v", e)
	}
	both := motionRecheckKey("k")
	withMotionSources(t, true, false)
	if motionVerdictCurrent(e) || !motionVerdictSourcesChanged(e) || motionVerdictStale(e) {
		t.Errorf("换了来源: current=%v changed=%v stale=%v", motionVerdictCurrent(e), motionVerdictSourcesChanged(e), motionVerdictStale(e))
	}
	if motionRecheckKey("k") == both {
		t.Error("换了来源,重核记录没分开")
	}
	e.clearMotionVerdict()
	if e.MotionCoverSources != "" || motionVerdictSourcesChanged(e) {
		t.Errorf("清掉之后: %+v", e)
	}
}
