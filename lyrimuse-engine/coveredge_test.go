package main

import (
	"context"
	"image"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
	"time"
)

// resetCoverEdgeMemo:用例从空的尺寸记录开始,收尾换回原来的。
func resetCoverEdgeMemo(t *testing.T) {
	t.Helper()
	coverEdgeMu.Lock()
	saved := coverEdgeMemo
	coverEdgeMemo = map[string]int{}
	coverEdgeMu.Unlock()
	t.Cleanup(func() {
		coverEdgeMu.Lock()
		coverEdgeMemo = saved
		coverEdgeMu.Unlock()
	})
}

// coverServer:按路径给图的假图床,返回每个路径被请求了几次。/text 给一段不是图片的内容。
func coverServer(t *testing.T, imgs map[string]image.Image) (*httptest.Server, func(path string) int) {
	t.Helper()
	var mu sync.Mutex
	hits := map[string]int{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits[r.URL.Path]++
		mu.Unlock()
		if r.URL.Path == "/text" {
			_, _ = w.Write([]byte("not an image"))
			return
		}
		img, ok := imgs[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_ = jpeg.Encode(w, img, &jpeg.Options{Quality: 90})
	}))
	t.Cleanup(srv.Close)
	return srv, func(path string) int {
		mu.Lock()
		defer mu.Unlock()
		return hits[path]
	}
}

func TestCoverActualEdge(t *testing.T) {
	resetCoverEdgeMemo(t)
	ctx := context.Background()
	if got := coverActualEdge(ctx, writeCoverFile(t, t.TempDir(), "a.jpg", synthCover(150, 1))); got != 150 {
		t.Errorf("本机文件量出 %d, 要 150", got)
	}
	srv, hits := coverServer(t, map[string]image.Image{"/cover.jpg": synthCover(900, 2)})
	if got := coverActualEdge(ctx, srv.URL+"/cover.jpg"); got != 900 {
		t.Errorf("远程图量出 %d, 要 900", got)
	}
	if got := coverActualEdge(ctx, srv.URL+"/cover.jpg"); got != 900 || hits("/cover.jpg") != 1 {
		t.Errorf("量过的按地址记着、不再请求: %d, 请求了 %d 次", got, hits("/cover.jpg"))
	}
	for _, u := range []string{srv.URL + "/text", srv.URL + "/missing.jpg", "ftp://example.invalid/a.jpg",
		deviceArtworkURLPrefix + "/no/such/file.jpg", ""} {
		if got := coverActualEdge(ctx, u); got != 0 {
			t.Errorf("%q 量不出,该是 0: %d", u, got)
		}
	}
	coverActualEdge(ctx, srv.URL+"/missing.jpg")
	if n := hits("/missing.jpg"); n != 2 {
		t.Errorf("量不出的不记、下次再量: 请求了 %d 次, 要 2", n)
	}
}

func TestDeviceCoverSmall(t *testing.T) {
	resetCoverEdgeMemo(t)
	dir := t.TempDir()
	for _, c := range []struct {
		name string
		edge int
		want bool
	}{
		{"s.jpg", 150, true}, {"e.jpg", deviceCoverTrustedMinEdge - 1, true},
		{"t.jpg", deviceCoverTrustedMinEdge, false}, {"b.jpg", 600, false},
	} {
		if got := deviceCoverSmall(writeCoverFile(t, dir, c.name, synthCover(c.edge, 1))); got != c.want {
			t.Errorf("%dpx 的设备封面: deviceCoverSmall = %v, 要 %v", c.edge, got, c.want)
		}
	}
	if deviceCoverSmall(deviceArtworkURLPrefix + dir + "/missing.jpg") {
		t.Error("读不出的设备封面算不小")
	}
	if deviceCoverSmall("https://p1.music.126.net/x.jpg") {
		t.Error("不是本机文件的不算设备封面")
	}
}

// 候选地址里读不出尺寸时量一次实际尺寸:同一张图、更清晰就让位,另一张图、不比设备封面大都不让;设备封面够清晰时不量。
func TestDeviceCoverOverridesCandidateMeasuresUnknownSize(t *testing.T) {
	resetCoverEdgeMemo(t)
	ctx := context.Background()
	dir := t.TempDir()
	device := writeCoverFile(t, dir, "device.jpg", synthCover(150, 1))
	bigDevice := writeCoverFile(t, dir, "big.jpg", synthCover(400, 1))
	srv, hits := coverServer(t, map[string]image.Image{
		"/same.jpg": synthCover(900, 1), "/same2.jpg": synthCover(900, 1),
		"/other.jpg": synthCover(900, 2), "/tiny.jpg": synthCover(120, 1),
	})
	if coverURLIntendedEdge(srv.URL+"/same.jpg") != 0 {
		t.Fatal("测试用的地址里不该读得出尺寸")
	}
	if deviceCoverOverridesCandidate(ctx, device, srv.URL+"/same.jpg") {
		t.Error("量出来 900、同一张图:该换成候选")
	}
	if !deviceCoverOverridesCandidate(ctx, device, srv.URL+"/other.jpg") {
		t.Error("另一张图:留设备封面")
	}
	if !deviceCoverOverridesCandidate(ctx, device, srv.URL+"/tiny.jpg") {
		t.Error("不比设备封面大:留设备封面")
	}
	if !deviceCoverOverridesCandidate(ctx, bigDevice, srv.URL+"/same2.jpg") || hits("/same2.jpg") != 0 {
		t.Errorf("设备封面够清晰:直接用、不取候选(请求了 %d 次)", hits("/same2.jpg"))
	}
}

// 设备封面小的条目,别的外围字段都齐也补一次(按这一轮查到的远程封面再比);够清晰的、读不出的不补,上限照旧。
func TestNeedsPeripheralBackfillSmallDeviceCover(t *testing.T) {
	resetCoverEdgeMemo(t)
	dir := t.TempDir()
	long := time.Now().Unix() - int64(enrichPeripheralRetryInterval/time.Second) - 1
	full := enrichEntry{AccentColor: "#fff", AppleURL: "a", QQURL: "q", NeteaseURL: "n", CanonicalArtist: "某歌手",
		TS: long, CoverSource: "device"}
	small, big, missing := full, full, full
	small.CoverURL = writeCoverFile(t, dir, "s.jpg", synthCover(150, 1))
	big.CoverURL = writeCoverFile(t, dir, "b.jpg", synthCover(600, 1))
	missing.CoverURL = deviceArtworkURLPrefix + dir + "/missing.jpg"
	capped := small
	capped.PeripheralRetryCount = peripheralBackfillMaxAttempts
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if !needsPeripheralBackfill(small, "某歌手", "专辑") {
		t.Error("设备封面太小:该补一次")
	}
	if needsPeripheralBackfill(big, "某歌手", "专辑") {
		t.Error("设备封面够清晰:不补")
	}
	if needsPeripheralBackfill(missing, "某歌手", "专辑") {
		t.Error("设备封面读不出:不在这里补")
	}
	if needsPeripheralBackfill(capped, "某歌手", "专辑") {
		t.Error("补满了上限:不补")
	}
}

// fakeCoverSweepUpgrade 换掉后台补封面里「本机播放器数据找清晰版」那一步:记下调过的 key,upgrade 里的换成播放器自带的。
func fakeCoverSweepUpgrade(t *testing.T, upgrade map[string]bool) *[]string {
	t.Helper()
	saved := coverSweepUpgradeLocal
	t.Cleanup(func() { coverSweepUpgradeLocal = saved })
	var keys []string
	coverSweepUpgradeLocal = func(_ context.Context, key, deviceCoverURL, artist, title, album string, _ float64) bool {
		keys = append(keys, key)
		enrichMu.Lock()
		defer enrichMu.Unlock()
		delete(enrichInflight, key)
		if !upgrade[key] {
			return false
		}
		e := enrichCache[key]
		e.CoverURL, e.CoverSource = "https://i.kfs.io/album/x/fit/1000x1000.jpg", "player"
		enrichCache[key] = e
		return true
	}
	return &keys
}

// 小设备封面在后台各核一次:本机播放器数据里有同一张图的清晰版就换上;没有、外围补全的上限又没到,再走一次外围补全按
// 远程结果比。核过的记下时刻和找法版本,隔 coverUpgradeRecheckInterval 再核,按旧版找法核过的不等;够清晰的、刚按这一版核过的不挑。
func TestCoverSweepUpgradesSmallDeviceCovers(t *testing.T) {
	resetCoverEdgeMemo(t)
	dir := t.TempDir()
	small := func(name string) string { return writeCoverFile(t, dir, name, synthCover(150, 1)) }
	now := time.Now().Unix()
	stale := now - int64(coverUpgradeRecheckInterval/time.Second) - 1
	withEnrichCache(t, map[string]enrichEntry{
		"A|local|X":  {CoverSource: "device", CoverURL: small("1.jpg")},
		"A|remote|X": {CoverSource: "device", CoverURL: small("2.jpg")},
		"A|capped|X": {CoverSource: "device", CoverURL: small("3.jpg"), PeripheralRetryCount: peripheralBackfillMaxAttempts},
		"A|big|X":    {CoverSource: "device", CoverURL: writeCoverFile(t, dir, "4.jpg", synthCover(600, 1))},
		"A|recent|X": {CoverSource: "device", CoverURL: small("5.jpg"), CoverUpgradeCheckTS: now, CoverUpgradeCheckRules: coverUpgradeCheckRules},
		"A|old|X":    {CoverSource: "device", CoverURL: small("6.jpg"), CoverUpgradeCheckTS: stale, CoverUpgradeCheckRules: coverUpgradeCheckRules},
		"A|rules|X":  {CoverSource: "device", CoverURL: small("7.jpg"), CoverUpgradeCheckTS: now, CoverUpgradeCheckRules: coverUpgradeCheckRules - 1},
	})
	calls, _ := withCoverSweepFakes(t, [][2]int32{{2, 0}}, nil)
	local := fakeCoverSweepUpgrade(t, map[string]bool{"A|local|X": true})
	pass := runCoverSweep(context.Background())
	if want := []string{"A|capped|X", "A|local|X", "A|old|X", "A|remote|X", "A|rules|X"}; !reflect.DeepEqual(*local, want) {
		t.Errorf("先找本机清晰版的 = %v, 要 %v", *local, want)
	}
	var backfilled []string
	for _, c := range *calls {
		backfilled = append(backfilled, c.key)
	}
	if want := []string{"A|old|X", "A|remote|X", "A|rules|X"}; !reflect.DeepEqual(backfilled, want) {
		t.Errorf("再走外围补全的 = %v, 要 %v(本机换成了的、上限已满的不走)", backfilled, want)
	}
	if pass.upgraded != 1 || pass.missed != 4 || pass.candidates != 5 {
		t.Errorf("结果 = %+v", pass)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|local|X"]; e.CoverSource != "player" {
		t.Errorf("本机清晰版该换上: %+v", e)
	}
	for _, k := range []string{"A|capped|X", "A|old|X", "A|remote|X", "A|rules|X"} {
		if e := enrichCache[k]; e.CoverUpgradeCheckTS < now || e.CoverUpgradeCheckRules != coverUpgradeCheckRules {
			t.Errorf("%s 核过该记下时刻和找法版本: %+v", k, e)
		}
	}
}

// 这一条一个请求都没成功(断网):不记核过,下一遍再核。
func TestCoverSweepUpgradeOfflineNotRecorded(t *testing.T) {
	resetCoverEdgeMemo(t)
	withEnrichCache(t, map[string]enrichEntry{
		"A|x|X": {CoverSource: "device", CoverURL: writeCoverFile(t, t.TempDir(), "1.jpg", synthCover(150, 1))},
	})
	withCoverSweepFakes(t, [][2]int32{{3, 3}}, nil)
	fakeCoverSweepUpgrade(t, nil)
	pass := runCoverSweep(context.Background())
	if pass.missed != 0 || pass.upgraded != 0 {
		t.Errorf("结果 = %+v", pass)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if ts := enrichCache["A|x|X"].CoverUpgradeCheckTS; ts != 0 {
		t.Errorf("断网那一条不该记成核过: %d", ts)
	}
}
