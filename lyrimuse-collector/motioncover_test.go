package main

import (
	"context"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

// fixture 按实测的真实结构精简:videoArtwork 挂在
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
		`"tallVideoArtwork":{"dictionary":{"motionDetailTall":{"video":"https://mvod/tall.m3u8"}}},` +
		`"artwork":{"dictionary":{"url":"https://is1-ssl.mzstatic.com/image/thumb/Video211/v4/x/y.png/{w}x{h}bb.{f}"}}` +
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
	// 页面上 videoArtwork 旁边那个 `artwork` 不一定是专辑封面(实测可能就是动画首帧本身),
	// 解析器不许拿它填 AlbumArtwork —— 那个字段只认目录 lookup,见 motionCover.AlbumArtwork。
	if mc.AlbumArtwork != "" || mc.AlbumArtworkChecked {
		t.Errorf("专辑页解析不该填官方封面: AlbumArtwork=%q checked=%v", mc.AlbumArtwork, mc.AlbumArtworkChecked)
	}
}

// 这是 motioncover.go 文件头 2 那道防线:页面里的 videoArtwork 必须属于我们要的那张专辑。
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
// (motioncover.go 文件头 3)。
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

// motionCoverWorthBackfill 的三态判据。存量条目要靠它才进得了 backfill,
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

// previewFrame 的模板替换。
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

// 从 apple_music_url 抠专辑 ID。样本取自本机 enrich 缓存的真实形态。
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

// 判据的两条新增分支:已核对过就不再算缺;非 Apple Music 播的条目靠
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

// 首帧比对 × 专辑身份核验 × 专辑 ID 来路 的完整裁决表,见 decideMotionCover。
func TestDecideMotionCover(t *testing.T) {
	cases := []struct {
		name         string
		frameMatched bool
		identity     motionCoverIdentity
		viaAnchor    bool
		want         motionCoverDecision
	}{
		{"首帧过了:放行,App 照常终审", true, motionIdentityNotAsked, false, motionDecisionAccept},
		{"首帧过了、来自锚点:同上", true, motionIdentityNotAsked, true, motionDecisionAccept},
		{"首帧没过、身份确认(Midnights / XLOV 那一类):放行且 App 跳过终审",
			false, motionIdentityConfirmed, false, motionDecisionAcceptIdentity},
		{"首帧没过、身份确认、来自锚点:身份那一支优先,App 同样跳过终审",
			false, motionIdentityConfirmed, true, motionDecisionAcceptIdentity},
		{"首帧没过、身份被否、来自锚点:锚点仍放行,交给 App 终审(揭幕特效那一类)",
			false, motionIdentityRejected, true, motionDecisionAccept},
		{"首帧没过、身份没查成、来自锚点:锚点仍放行", false, motionIdentityUndecided, true, motionDecisionAccept},
		{"首帧没过、身份被否、文字匹配来的 ID:必须挡住", false, motionIdentityRejected, false, motionDecisionReject},
		{"首帧没过、身份这一轮没查成、文字匹配来的 ID:不能钉死,留给下次",
			false, motionIdentityUndecided, false, motionDecisionPending},
	}
	for _, c := range cases {
		if got := decideMotionCover(c.frameMatched, c.identity, c.viaAnchor); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 身份核验本身:模板为空 = 核过了、没核上;两张静态封面是同一张 = 确认;不是同一张 = 否。
// 图走 file://(loadCoverImage 认本地文件),单测不连网。
func TestMotionCoverAlbumIdentityMatches(t *testing.T) {
	ctx := context.Background()
	if m, v := motionCoverAlbumIdentityMatches(ctx, "", "file:///nope.jpg"); m || !v {
		t.Errorf("页面上没有官方封面时该是'核过了、没核上': matched=%v verified=%v", m, v)
	}

	dir := t.TempDir()
	write := func(name string, fill func(x, y int) uint8) string {
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
	left := func(x, _ int) uint8 {
		if x < 60 {
			return 20
		}
		return 230
	}
	top := func(_, y int) uint8 {
		if y < 60 {
			return 20
		}
		return 230
	}
	official, same, other := write("official.png", left), write("same.png", left), write("other.png", top)
	// 模板必须带 {w}x{h}bb.{f} 才会被换成真地址;file:// 路径不带占位时原样返回,这里直接给路径。
	if m, v := motionCoverAlbumIdentityMatches(ctx, official, same); !m || !v {
		t.Errorf("同一张封面该确认身份: matched=%v verified=%v", m, v)
	}
	if m, v := motionCoverAlbumIdentityMatches(ctx, official, other); m || !v {
		t.Errorf("两张不同的封面该否掉身份: matched=%v verified=%v", m, v)
	}
	if m, v := motionCoverAlbumIdentityMatches(ctx, official, "file://"+filepath.Join(dir, "missing.png")); m || v {
		t.Errorf("取不到封面时该是'这一轮没核成': matched=%v verified=%v", m, v)
	}
}

// motionCoverAlbumArtworkFor 的两条不连网的路:已经查过官方封面的条目直接读缓存;缓存里
// 压根没有这一条时不抓页、也不凭空造条目(造出来的条目 Master 为空,会被读成"没有动画")。
func TestMotionCoverAlbumArtworkForCachedPaths(t *testing.T) {
	const parsed, unknown = "770001", "770002"
	motionCoverMu.Lock()
	motionCoverCache[parsed] = motionCover{Master: "https://mvod/x.m3u8", AlbumArtwork: "https://art/{w}x{h}bb.{f}",
		AlbumArtworkChecked: true, Checked: true}
	delete(motionCoverCache, unknown)
	motionCoverMu.Unlock()
	defer func() {
		motionCoverMu.Lock()
		delete(motionCoverCache, parsed)
		delete(motionCoverCache, unknown)
		motionCoverMu.Unlock()
	}()

	if tmpl, done := motionCoverAlbumArtworkFor(context.Background(), 770001); !done || tmpl != "https://art/{w}x{h}bb.{f}" {
		t.Errorf("已解析过的条目该直接读缓存: tmpl=%q done=%v", tmpl, done)
	}
	if tmpl, done := motionCoverAlbumArtworkFor(context.Background(), 770002); done || tmpl != "" {
		t.Errorf("缓存里没有这一条时该回'没查成'且不抓页: tmpl=%q done=%v", tmpl, done)
	}
	motionCoverMu.Lock()
	_, created := motionCoverCache[unknown]
	motionCoverMu.Unlock()
	if created {
		t.Error("不该为缓存里没有的专辑凭空造一条")
	}
}

// fresh 的动态封面核对结论只对它自己解析出来的那张封面(fresh.CoverURL)有效——
// coverSwapAllowed 判定"不换封面"时,不能把这个结论错配到记录实际留用的旧封面上。
// 错配的后果:被永久卡成"核对过、没有动态封面"(如 M!LK《Bakuretsu Aishiteru》一例),
// 见 backfillPeripheralFields 调用点的注释。
func TestMotionCoverFreshResultAppliesTo(t *testing.T) {
	const retained = "https://is1-ssl.mzstatic.com/.../VEATP-45199.jpg/1200x1200bb.jpg"
	if !motionCoverFreshResultAppliesTo(retained, enrichEntry{CoverURL: retained}) {
		t.Error("fresh 核对的就是最终留用的这张封面,结论该能挪用")
	}
	if motionCoverFreshResultAppliesTo(retained, enrichEntry{CoverURL: "https://y.qq.com/other.jpg"}) {
		t.Error("fresh 核对的是另一张封面(coverSwapAllowed 没让它生效),结论不该挪给 retained 那张")
	}
}

// motionCoverAlbumHasKnownVideo 跟 motionCoverWorthBackfill 只差一处,而正是那一处让它
// 敢被拿去扫全表:专辑还没查过时它回 false,所以扫描不会连带发起几千次专辑页抓取。
func TestMotionCoverAlbumHasKnownVideo(t *testing.T) {
	const albumID = "1474635061"
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

	viaURL := enrichEntry{AppleURL: "https://music.apple.com/cn/album/aim-high/" + albumID + "?i=1"}

	// ① 缓存里确认这张有动画 到 是。
	setMotion(&motionCover{Master: "https://mvod/x.m3u8", Checked: true})
	if !motionCoverAlbumHasKnownVideo(viaURL, "查无此歌", "查无此辑") {
		t.Error("缓存里确认这张专辑有动态封面时该回 true")
	}

	// ② 缓存里确认这张没有 到 否。
	setMotion(&motionCover{Checked: true})
	if motionCoverAlbumHasKnownVideo(viaURL, "查无此歌", "查无此辑") {
		t.Error(`缓存里"查过了没有"时该回 false`)
	}

	// ③ **还没查过 到 否**。这一条是它跟 motionCoverWorthBackfill 的唯一分歧,也是它存在的
	//    全部理由:那个回 true(该去查),这个回 false(别把它扫进一次性清理)。
	setMotion(nil)
	if motionCoverAlbumHasKnownVideo(viaURL, "查无此歌", "查无此辑") {
		t.Error("专辑还没查过时该回 false —— 否则全量扫描会连带抓几千张专辑页")
	}
	if !motionCoverWorthBackfill(viaURL, "查无此歌", "查无此辑") {
		t.Error("同一状态下 motionCoverWorthBackfill 该回 true(两者的分歧点)")
	}

	// ④ 两条来路都没有 → 否。
	setMotion(&motionCover{Master: "https://mvod/x.m3u8", Checked: true})
	if motionCoverAlbumHasKnownVideo(enrichEntry{}, "查无此歌", "查无此辑") {
		t.Error("既无锚点也无 apple_music_url 时该回 false")
	}
}

// backfill 跑完这一轮之后该不该拿这条记录自己的封面补算一次。第①条是设备直送封面那个
// 死角的判据本身,其余三条是"别白发请求"的三道闸。
func TestMotionCoverNeedsRecheckAgainstOwnCover(t *testing.T) {
	// ① fresh 的结论落不到这张封面上(设备直送封面的常态)、而这条一位结论都没有 到 要补算。
	if !motionCoverNeedsRecheckAgainstOwnCover(false, enrichEntry{CoverSource: "device"}) {
		t.Error("结论一位都没落下时该补算 —— 否则设备直送封面的记录永远停在没查过")
	}
	// ② fresh 的结论就是对着这张封面得出的 到 上面那条正常路径已经处理过了,不补。
	if motionCoverNeedsRecheckAgainstOwnCover(true, enrichEntry{}) {
		t.Error("fresh 的结论已经落到这张封面上了,不该再补算一次")
	}
	// ③ 已经有动态封面 → 不补。
	if motionCoverNeedsRecheckAgainstOwnCover(false, enrichEntry{MotionCoverURL: "https://mvod/x.m3u8"}) {
		t.Error("已经有动态封面的记录不该再补算")
	}
	// ④ 已经核对过(结论是这条没有)到 不补。那一位存在的全部意义就是防重复核对。
	if motionCoverNeedsRecheckAgainstOwnCover(false, enrichEntry{MotionCoverChecked: true}) {
		t.Error("已经核对过的记录不该再补算 —— 每轮补一次就是那一位要防的事")
	}
}

// 去边第二次机会:同一张图、预览帧四周多一圈暗角时该判成同一张,而两张真的不同的图去了边
// 仍然过不了。合成图的形态照抄真实案例(浅背景人像 + 中心深色块),理由见 motionCoverBorderCrop。
func TestMotionCoverSameArtworkBorderCrop(t *testing.T) {
	const side = 600
	fill := func(vignette bool) image.Image {
		img := image.NewRGBA(image.Rect(0, 0, side, side))
		for y := 0; y < side; y++ {
			for x := 0; x < side; x++ {
				v := uint8(200)
				if x >= 225 && x < 375 && y >= 225 && y < 375 {
					v = 40
				}
				if vignette && (x < 48 || x >= side-48 || y < 48 || y >= side-48) {
					v = 0
				}
				img.Set(x, y, color.RGBA{R: v, G: v, B: v, A: 255})
			}
		}
		return img
	}
	plain, vignetted := fill(false), fill(true)

	raw := coverFingerprintDistance(coverFingerprint(plain), coverFingerprint(vignetted))
	if raw <= motionCoverFingerprintMaxDistance {
		t.Fatalf("合成图没复现出那个坑:整图距离 %d 本该超阈", raw)
	}
	if d, ok := motionCoverSameArtwork(plain, vignetted); !ok {
		t.Errorf("同一张图、只是多一圈暗角,去边之后该判成同一张(距离 %d)", d)
	}

	// 真反例:上下反过来的另一张图,去了边照样不该放过。
	other := image.NewRGBA(image.Rect(0, 0, side, side))
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			v := uint8(200)
			if y < side/2 {
				v = 0
			}
			other.Set(x, y, color.RGBA{R: v, G: v, B: v, A: 255})
		}
	}
	if d, ok := motionCoverSameArtwork(plain, other); ok {
		t.Errorf("两张不同的图不该被去边那一道放过去(距离 %d)", d)
	}
}

// lookup 结果里只认**这张专辑**本身(wrapperType=collection 且 id 对得上),尺寸段换成模板。
func TestPickCollectionArtwork(t *testing.T) {
	res := []itunesCollectionResult{
		{WrapperType: "track", CollectionID: 42, ArtworkURL100: "https://a/Music/track.jpg/100x100bb.jpg"},
		{WrapperType: "collection", CollectionID: 7, ArtworkURL100: "https://a/Music/other.jpg/100x100bb.jpg"},
		{WrapperType: "collection", CollectionID: 42, ArtworkURL100: "https://a/Music/self.jpg/100x100bb.jpg"},
	}
	if got, want := pickCollectionArtwork(res, 42), "https://a/Music/self.jpg/{w}x{h}bb.{f}"; got != want {
		t.Errorf("got %q, want %q(拿成曲目或别的专辑的图就是用错的图核身份)", got, want)
	}
	if got := pickCollectionArtwork(res, 99); got != "" {
		t.Errorf("目录里没有这张时该回空串, got %q", got)
	}
	odd := []itunesCollectionResult{{WrapperType: "collection", CollectionID: 1, ArtworkURL100: "https://a/x.jpg"}}
	if got := pickCollectionArtwork(odd, 1); got != "https://a/x.jpg" {
		t.Errorf("尾部尺寸认不出来时该原样保留, got %q", got)
	}
}
