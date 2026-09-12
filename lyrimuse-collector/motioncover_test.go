package main

import "testing"

// fixture 按 2026-09-09 实测的真实结构精简:videoArtwork 挂在
// data/0/data/sections/0/items/0 下,同一个 item 里带着
// containerContentDescriptor.identifiers.storeAdamID = 这张专辑的 ID。
func motionCoverPage(adamID string) string {
	return `<!doctype html><html><head><title>x</title></head><body>` +
		`<script type="application/json" id="serialized-server-data">` +
		`{"data":[{"intent":{"$kind":"AlbumDetailPageIntent"},"data":{"sections":[{"items":[{` +
		`"containerContentDescriptor":{"kind":"album","identifiers":{"storeAdamID":"` + adamID + `"}},` +
		`"videoArtwork":{"dictionary":{"motionDetailSquare":{` +
		`"previewFrame":{"bgColor":"08061b","textColor1":"f697c3","height":3840,"width":3840,` +
		`"url":"https://is1-ssl.mzstatic.com/image/thumb/Video211/v4/x/y.png/{w}x{h}bb.{f}"},` +
		`"video":"https://mvod.itunes.apple.com/itunes-assets/HLSVideo211/v4/x/P1_default.m3u8"` +
		`}},"cropStyle":"cc"},` +
		`"tallVideoArtwork":{"dictionary":{"motionDetailTall":{"video":"https://mvod/tall.m3u8"}}}` +
		`}]}]}}]}` +
		`</script></body></html>`
}

func TestParseMotionCover(t *testing.T) {
	mc, ok := parseMotionCover([]byte(motionCoverPage("6773830957")), "6773830957")
	if !ok {
		t.Fatal("期望解析成功")
	}
	if want := "https://mvod.itunes.apple.com/itunes-assets/HLSVideo211/v4/x/P1_default.m3u8"; mc.Master != want {
		t.Errorf("Master = %q, want %q", mc.Master, want)
	}
	// 取的必须是**方形**那份,不能拿成 tallVideoArtwork(3:4 竖版)。
	if mc.Master == "https://mvod/tall.m3u8" {
		t.Error("取到了竖版 motionDetailTall,应该只要方形 motionDetailSquare")
	}
	if want := "https://is1-ssl.mzstatic.com/image/thumb/Video211/v4/x/y.png/{w}x{h}bb.{f}"; mc.PreviewFrame != want {
		t.Errorf("PreviewFrame = %q, want %q", mc.PreviewFrame, want)
	}
	if mc.BgColor != "08061b" || mc.TextColor != "f697c3" {
		t.Errorf("配色 = %q/%q, want 08061b/f697c3", mc.BgColor, mc.TextColor)
	}
}

// 这是 motioncover.go 文件头 ⚠️ 2 那道防线:页面里的 videoArtwork 必须属于我们要的那张专辑。
// 拿错专辑的动态封面比没有动态封面糟得多——那会给这首歌配上另一张专辑的画面。
func TestParseMotionCoverRejectsForeignAlbum(t *testing.T) {
	if mc, ok := parseMotionCover([]byte(motionCoverPage("1111111111")), "6773830957"); ok || mc.Master != "" {
		t.Errorf("专辑 ID 对不上时不该认: ok=%v master=%q", ok, mc.Master)
	}
}

func TestParseMotionCoverMissingPieces(t *testing.T) {
	cases := []struct {
		name string
		page string
	}{
		{"没有 script 标签", `<html><body>nothing</body></html>`},
		{"script 里不是合法 JSON", `<script type="application/json" id="serialized-server-data">{oops</script>`},
		{"有 script 但没有 videoArtwork", `<script type="application/json" id="serialized-server-data">` +
			`{"data":[{"items":[{"containerContentDescriptor":{"identifiers":{"storeAdamID":"6773830957"}}}]}]}</script>`},
		{"videoArtwork 是空对象", `<script type="application/json" id="serialized-server-data">` +
			`{"data":[{"identifiers":{"storeAdamID":"6773830957"},"videoArtwork":{}}]}</script>`},
		{"有 videoArtwork 但没有 video 字段", `<script type="application/json" id="serialized-server-data">` +
			`{"data":[{"identifiers":{"storeAdamID":"6773830957"},` +
			`"videoArtwork":{"dictionary":{"motionDetailSquare":{"previewFrame":{"url":"u"}}}}}]}</script>`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if mc, ok := parseMotionCover([]byte(c.page), "6773830957"); ok || mc.Master != "" {
				t.Errorf("应当解析失败: ok=%v master=%q", ok, mc.Master)
			}
		})
	}
}

// motionCoverFor 对非法 ID 一律不发请求(单测环境没有网,这条同时保证它不会去连网)。
func TestMotionCoverForRejectsBadID(t *testing.T) {
	for _, id := range []int64{0, -1, -3446272063698972557} {
		if _, done := motionCoverFor(id); done {
			t.Errorf("collectionID=%d 不该被当成有定论", id)
		}
	}
}

// 缓存里"查过了但没有"这条要能命中,不然同一张专辑的每首歌都会重抓一次页面
// (motioncover.go 文件头 ⚠️ 3)。
func TestMotionCoverCacheHitForCheckedEmpty(t *testing.T) {
	const id = 424242
	motionCoverMu.Lock()
	prev, had := motionCoverCache["424242"]
	motionCoverCache["424242"] = motionCover{Checked: true}
	motionCoverMu.Unlock()
	defer func() {
		motionCoverMu.Lock()
		if had {
			motionCoverCache["424242"] = prev
		} else {
			delete(motionCoverCache, "424242")
		}
		motionCoverMu.Unlock()
	}()

	mc, done := motionCoverFor(id)
	if !done {
		t.Fatal(`"查过了没有"应当算有定论,直接命中缓存、不再发请求`)
	}
	if mc.Master != "" {
		t.Errorf("Master = %q, want 空", mc.Master)
	}
}

// motionCoverWorthBackfill 的三态判据(2026-09-09)。存量条目要靠它才进得了 backfill,
// 而"这张专辑就是没有"必须**不**算缺 —— 否则七成条目会白重试 5 轮(覆盖率只有三成上下)。
func TestMotionCoverWorthBackfill(t *testing.T) {
	const (
		title = "I Am You"
		album = "Timeless"
		id    = int64(6773830957)
	)
	key := appleCatalogIndexKey(title, album)

	// 造一个已校验的目录锚点(播放路径平时就是这么填的)。
	appleCatalogMu.Lock()
	prevAnchor, hadAnchor := appleCatalogByTrack[key]
	appleCatalogByTrack[key] = appleCatalogTrack{TrackName: title, AlbumName: album, AlbumID: id}
	appleCatalogMu.Unlock()
	defer func() {
		appleCatalogMu.Lock()
		if hadAnchor {
			appleCatalogByTrack[key] = prevAnchor
		} else {
			delete(appleCatalogByTrack, key)
		}
		appleCatalogMu.Unlock()
	}()

	setMotion := func(mc *motionCover) {
		motionCoverMu.Lock()
		defer motionCoverMu.Unlock()
		if mc == nil {
			delete(motionCoverCache, "6773830957")
			return
		}
		motionCoverCache["6773830957"] = *mc
	}
	defer setMotion(nil)

	empty := enrichEntry{}
	filled := enrichEntry{MotionCoverURL: "https://mvod/x.m3u8"}

	// ① 已经有了 → 不用补(连锚点都不查)。
	setMotion(nil)
	if motionCoverWorthBackfill(filled, title, album) {
		t.Error("已经有 master 的条目不该再算缺")
	}
	// ② 没查过 + 有锚点 → 值得补一次。
	if !motionCoverWorthBackfill(empty, title, album) {
		t.Error("还没查过这张专辑时该算缺,给它一次机会")
	}
	// ③ 查过了、这张有 → 算缺(等着被写进这条记录)。
	setMotion(&motionCover{Master: "https://mvod/x.m3u8", Checked: true})
	if !motionCoverWorthBackfill(empty, title, album) {
		t.Error("缓存里确认这张有动态封面时该算缺")
	}
	// ④ 查过了、这张没有 → **不算缺**,这是防白重试的那一半。
	setMotion(&motionCover{Checked: true})
	if motionCoverWorthBackfill(empty, title, album) {
		t.Error(`缓存里标着"查过了没有"时不该算缺,否则七成条目白重试 5 轮`)
	}
	// ⑤ 没有已校验的目录锚点(不是 Apple Music 目录曲目)→ 补也补不出来,不算缺。
	setMotion(nil)
	if motionCoverWorthBackfill(empty, "查无此歌", "查无此辑") {
		t.Error("没有目录锚点时不该算缺")
	}
}

// previewFrame 的模板替换(2026-09-10)。
func TestMotionCoverPreviewSizedURL(t *testing.T) {
	got := motionCoverPreviewSizedURL("https://is1-ssl.mzstatic.com/image/thumb/x/y.png/{w}x{h}bb.{f}")
	if want := "https://is1-ssl.mzstatic.com/image/thumb/x/y.png/600x600bb.jpg"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	// 不认的形态原样返回 —— 调用方下不到就当校验失败,不会误判成"同一张"。
	if got := motionCoverPreviewSizedURL("https://x/y.jpg"); got != "https://x/y.jpg" {
		t.Errorf("非模板应原样返回, got %q", got)
	}
	if got := motionCoverPreviewSizedURL(""); got != "" {
		t.Errorf("空串应回空, got %q", got)
	}
}

// 从 apple_music_url 抠专辑 ID(2026-09-10)。样本取自本机 enrich 缓存的真实形态。
func TestMotionCoverAlbumIDFromAppleURL(t *testing.T) {
	cases := []struct {
		url  string
		want int64
	}{
		{"https://music.apple.com/cn/album/aim-high/1474635060?i=1474635079&uo=4", 1474635060},
		{"https://music.apple.com/us/album/sent/1708204438?i=1708204966&uo=4", 1708204438},
		{"https://music.apple.com/cn/album/timeless/6773830957", 6773830957},
		// 专辑名那一段是空的也认(URL 里 slug 可省)。
		{"https://music.apple.com/cn/album//1474635060", 1474635060},
		{"", 0},
		{"https://music.apple.com/cn/artist/prince/155814", 0}, // 不是专辑页
		{"https://music.apple.com/cn/album/x/0", 0},            // 0 不是合理 ID
		{"https://open.spotify.com/album/1474635060", 0},       // 别的平台
	}
	for _, c := range cases {
		if got := motionCoverAlbumIDFromAppleURL(c.url); got != c.want {
			t.Errorf("%q → %d, want %d", c.url, got, c.want)
		}
	}
}

// 判据的两条新增分支(2026-09-10):已核对过就不再算缺;非 Apple Music 播的条目靠
// apple_music_url 也能进 backfill。
func TestMotionCoverWorthBackfillCheckedAndAppleURL(t *testing.T) {
	const albumID = "1474635060"
	setMotion := func(mc *motionCover) {
		motionCoverMu.Lock()
		defer motionCoverMu.Unlock()
		if mc == nil {
			delete(motionCoverCache, albumID)
			return
		}
		motionCoverCache[albumID] = *mc
	}
	defer setMotion(nil)

	// ① 已核对过(不论结论)→ 不再算缺,免得每轮重下首帧算指纹。
	setMotion(&motionCover{Master: "https://mvod/x.m3u8", Checked: true})
	checked := enrichEntry{
		MotionCoverChecked: true,
		AppleURL:           "https://music.apple.com/cn/album/aim-high/" + albumID + "?i=1",
	}
	if motionCoverWorthBackfill(checked, "查无此歌", "查无此辑") {
		t.Error("已核对过的记录不该再算缺")
	}

	// ② 没有目录锚点,但 apple_music_url 里有专辑 ID → 该算缺(这是非 Apple Music 播放器
	//    唯一的入口)。
	viaURL := enrichEntry{AppleURL: "https://music.apple.com/cn/album/aim-high/" + albumID + "?i=1"}
	if !motionCoverWorthBackfill(viaURL, "查无此歌", "查无此辑") {
		t.Error("apple_music_url 带专辑 ID 且缓存里确认这张有动态封面时,该算缺")
	}

	// ③ 同上,但缓存里标着这张没有 → 不算缺(防七成条目白重试)。
	setMotion(&motionCover{Checked: true})
	if motionCoverWorthBackfill(viaURL, "查无此歌", "查无此辑") {
		t.Error(`缓存里"查过了没有"时不该算缺`)
	}

	// ④ 两条来路都没有 → 不算缺。
	setMotion(nil)
	if motionCoverWorthBackfill(enrichEntry{}, "查无此歌", "查无此辑") {
		t.Error("既无锚点也无 apple_music_url 时不该算缺")
	}
}
