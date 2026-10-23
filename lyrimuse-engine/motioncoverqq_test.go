package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
)

// withQQMotion 把专辑详情和官方方图换成假的,清掉这张专辑在缓存里的结论。
func withQQMotion(t *testing.T, mid, vid string, fail *bool, official string) *int {
	t.Helper()
	calls := 0
	savedFetch, savedURL := qqAlbumDetailFetch, qqMotionCoverOfficialURL
	qqAlbumDetailFetch = func(_ context.Context, m string) (json.RawMessage, error) {
		calls++
		if fail != nil && *fail {
			return nil, errors.New("network")
		}
		return json.RawMessage(`{"basicInfo":{"albumName":"x","dynamicCoverVid":"` + vid + `"}}`), nil
	}
	qqMotionCoverOfficialURL = func(string) string { return official }
	motionCoverMu.Lock()
	delete(motionCoverCache, qqMotionCoverKey(mid))
	savedPath := motionCoverPath
	motionCoverPath = ""
	motionCoverMu.Unlock()
	t.Cleanup(func() {
		qqAlbumDetailFetch, qqMotionCoverOfficialURL = savedFetch, savedURL
		motionCoverMu.Lock()
		delete(motionCoverCache, qqMotionCoverKey(mid))
		motionCoverPath = savedPath
		motionCoverMu.Unlock()
	})
	return &calls
}

func TestQQAlbumDynamicCoverVid(t *testing.T) {
	for _, c := range []struct {
		raw     string
		vid     string
		wantOK  bool
		comment string
	}{
		{`{"basicInfo":{"dynamicCoverVid":"013nB0VB44pnzC"}}`, "013nB0VB44pnzC", true, "有"},
		{`{"basicInfo":{"dynamicCoverVid":""}}`, "", true, "空串是没有"},
		{`{"basicInfo":{}}`, "", true, "没这个键是没有"},
		{`{"other":1}`, "", false, "没有 basicInfo 是形状不对"},
		{`not json`, "", false, "解不开"},
	} {
		vid, ok := qqAlbumDynamicCoverVid(json.RawMessage(c.raw))
		if vid != c.vid || ok != c.wantOK {
			t.Errorf("%s: %q %v", c.comment, vid, ok)
		}
	}
}

// 问过的结论落进缓存(有、没有都记),再问不发请求;请求失败不记,下次再问;mid 形状不对不问。
func TestQQMotionCoverForCaches(t *testing.T) {
	fail := true
	calls := withQQMotion(t, "002ENNC51FIhXc", "013nB0VB44pnzC", &fail, "")
	if _, done := qqMotionCoverFor(context.Background(), "002ENNC51FIhXc"); done || *calls != 1 {
		t.Fatalf("请求失败没有定论: done=%v calls=%d", done, *calls)
	}
	fail = false
	if m, done := qqMotionCoverFor(context.Background(), "002ENNC51FIhXc"); !done || m != "qqmv:013nB0VB44pnzC" {
		t.Errorf("有动态封面: %q %v", m, done)
	}
	if m, done := qqMotionCoverFor(context.Background(), "002ENNC51FIhXc"); !done || m != "qqmv:013nB0VB44pnzC" || *calls != 2 {
		t.Errorf("第二次读缓存不发请求: %q %v calls=%d", m, done, *calls)
	}
	none := withQQMotion(t, "004AAAAAAAAAAA", "", nil, "")
	if m, done := qqMotionCoverFor(context.Background(), "004AAAAAAAAAAA"); !done || m != "" {
		t.Errorf("没有也是定论: %q %v", m, done)
	}
	if _, done := qqMotionCoverFor(context.Background(), "004AAAAAAAAAAA"); !done || *none != 1 {
		t.Errorf("没有也记下: calls=%d", *none)
	}
	if _, done := qqMotionCoverFor(context.Background(), "bad mid!"); done {
		t.Error("mid 形状不对不问")
	}
}

// Apple 那支没给出动态封面时按 QQ 核:身份对上才挂,对不上、QQ 没有都记「没有」;取不到图没有定论;没有 mid 时 Apple 核过
// 「没有」就记没有,压根没核就整组清掉。
func TestMotionVerdictFromQQ(t *testing.T) {
	dir := t.TempDir()
	cover := motionTestImage(t, dir, "cover.png", motionTestLeft)
	other := motionTestImage(t, dir, "other.png", motionTestTop)
	const mid = "002ENNC51FIhXc"
	ctx := context.Background()

	withQQMotion(t, mid, "013nB0VB44pnzC", nil, cover)
	e := enrichEntry{CoverURL: cover, QQAlbumMid: mid}
	if !e.motionVerdictFromQQ(ctx, true) || e.MotionCoverURL != "qqmv:013nB0VB44pnzC" || !e.MotionCoverIdentityVerified ||
		!e.MotionCoverChecked || e.MotionCoverFor != cover || e.MotionPreviewURL != "" {
		t.Errorf("身份对上: %+v", e)
	}
	withQQMotion(t, mid, "013nB0VB44pnzC", nil, other)
	e = enrichEntry{CoverURL: cover, QQAlbumMid: mid}
	if !e.motionVerdictFromQQ(ctx, true) || e.MotionCoverURL != "" || !e.MotionCoverChecked {
		t.Errorf("封面不是这张专辑的: %+v", e)
	}
	withQQMotion(t, mid, "013nB0VB44pnzC", nil, "file:///nonexistent/official.png")
	e = enrichEntry{CoverURL: cover, QQAlbumMid: mid}
	if e.motionVerdictFromQQ(ctx, true) || e.MotionCoverChecked {
		t.Errorf("取不到官方图:没有定论 %+v", e)
	}
	withQQMotion(t, mid, "", nil, cover)
	e = enrichEntry{CoverURL: cover, QQAlbumMid: mid}
	if !e.motionVerdictFromQQ(ctx, false) || e.MotionCoverURL != "" || !e.MotionCoverChecked {
		t.Errorf("QQ 也没有: %+v", e)
	}
	e = enrichEntry{CoverURL: cover, MotionCoverURL: "old", MotionCoverChecked: true}
	if !e.motionVerdictFromQQ(ctx, true) || e.MotionCoverURL != "" || !e.MotionCoverChecked || e.MotionCoverFor != cover {
		t.Errorf("没有 mid、Apple 核过没有: %+v", e)
	}
	e = enrichEntry{CoverURL: cover, MotionCoverURL: "old", MotionCoverChecked: true}
	if !e.motionVerdictFromQQ(ctx, false) || e.MotionCoverURL != "" || e.MotionCoverChecked {
		t.Errorf("没有 mid、也没有 Apple 专辑:整组清掉 %+v", e)
	}
}

// 核过「没有」的存量条目,QQ 那张专辑还没问过时播到值得补核一次;问过了、有地址、封面换过、没有 mid 都不算。
func TestQQMotionCoverUnasked(t *testing.T) {
	const mid = "002ENNC51FIhXc"
	withQQMotion(t, mid, "", nil, "")
	base := enrichEntry{CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c", QQAlbumMid: mid}
	if !qqMotionCoverUnasked(base) {
		t.Error("核过没有、QQ 没问过")
	}
	for name, e := range map[string]enrichEntry{
		"已有地址":   {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c", MotionCoverURL: "x", QQAlbumMid: mid},
		"没核过":    {CoverURL: "c", QQAlbumMid: mid},
		"对着别的封面": {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "old", QQAlbumMid: mid},
		"没有 mid": {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c"},
	} {
		if qqMotionCoverUnasked(e) {
			t.Errorf("%s 不该补核", name)
		}
	}
	qqMotionCoverFor(context.Background(), mid)
	if qqMotionCoverUnasked(base) {
		t.Error("QQ 问过了就不再补")
	}
}

// 接线:Apple 没给出动态封面的三处都转到 QQ,播到时补核、重核入口认 QQ 没问过的。
func TestQQMotionCoverIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, want := range []string{
		"if albumID <= 0 {\n\t\treturn e.motionVerdictFromQQ(ctx, false)\n\t}",
		"if mc.Master == \"\" {\n\t\treturn e.motionVerdictFromQQ(ctx, true)\n\t}",
		"case motionDecisionReject:\n\t\treturn e.motionVerdictFromQQ(ctx, true)",
		"if motionVerdictCurrent(*e) && !qqMotionCoverUnasked(*e) {",
		"if !ok || (motionVerdictCurrent(e) && !qqMotionCoverUnasked(e)) {",
		"} else if (motionVerdictStale(e) || qqMotionCoverUnasked(e)) && !motionRecheckTried[key] && !enrichInflight[key] {",
	} {
		if !containsCode(src, want) {
			t.Errorf("enrich.go 缺 %q", strings.SplitN(want, "\n", 2)[0])
		}
	}
}
