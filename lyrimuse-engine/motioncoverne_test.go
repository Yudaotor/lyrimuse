package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// withNeteaseMotion 把游客注册和 dynamic-cover 换成假的(answer 为 nil 时请求失败),清掉内存里的身份、注册冷却和这首的结论。
func withNeteaseMotion(t *testing.T, id string, answer *string) (registers, asks *int, cookies *[]string) {
	t.Helper()
	registers, asks, cookies = new(int), new(int), &[]string{}
	savedRegister, savedFetch := neteaseGuestRegister, neteaseDynamicCoverFetch
	savedGap := neteaseGuestGap
	neteaseGuestRegister = func(context.Context) (neteaseGuest, error) {
		*registers++
		return neteaseGuest{MusicA: "guest-" + string(rune('0'+*registers)), Expires: time.Now().Add(100 * 24 * time.Hour).Unix()}, nil
	}
	neteaseDynamicCoverFetch = func(_ context.Context, _ string, cookie string) ([]byte, error) {
		*asks++
		*cookies = append(*cookies, cookie)
		if answer == nil {
			return nil, errors.New("network")
		}
		return []byte(*answer), nil
	}
	neteaseGuestGap = 0
	resetGuest := func() {
		neteaseGuestMu.Lock()
		neteaseGuestCached, neteaseGuestRetryAt, neteaseGuestBusy = neteaseGuest{}, time.Time{}, false
		neteaseGuestMu.Unlock()
		_ = os.Remove(neteaseGuestPath())
	}
	resetGuest()
	if err := os.MkdirAll(filepath.Dir(neteaseGuestPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	motionCoverMu.Lock()
	delete(motionCoverCache, neteaseMotionCoverKey(id))
	savedPath := motionCoverPath
	motionCoverPath = ""
	motionCoverMu.Unlock()
	t.Cleanup(func() {
		neteaseGuestRegister, neteaseDynamicCoverFetch, neteaseGuestGap = savedRegister, savedFetch, savedGap
		resetGuest()
		motionCoverMu.Lock()
		delete(motionCoverCache, neteaseMotionCoverKey(id))
		motionCoverPath = savedPath
		motionCoverMu.Unlock()
	})
	return registers, asks, cookies
}

func TestParseNeteaseDynamicCover(t *testing.T) {
	for _, c := range []struct {
		raw  string
		want neteaseDynamicCoverReply
	}{
		{`{"code":200,"data":{"height":0,"videoPlayUrl":"http://dcover.music.126.net/a/b.mp4?wsSecret=x"}}`, neteaseDynamicCoverFound},
		{`{"code":200,"data":{}}`, neteaseDynamicCoverNone},
		{`{"code":200,"data":{"videoPlayUrl":"  "}}`, neteaseDynamicCoverNone},
		{`{"code":301,"message":"系统错误","data":null}`, neteaseDynamicCoverLoggedOut},
		{`{"code":405,"message":"操作频繁"}`, neteaseDynamicCoverUnknown},
		{`{"code":405,"data":{}}`, neteaseDynamicCoverUnknown},
		{`{"code":200,"data":null}`, neteaseDynamicCoverUnknown},
		{`<html>`, neteaseDynamicCoverUnknown},
	} {
		if got := parseNeteaseDynamicCover([]byte(c.raw)); got != c.want {
			t.Errorf("%s: %d, want %d", c.raw, got, c.want)
		}
	}
}

// 跟 App 那份(NeteaseMotionCover.guestUsername)同一组向量,两边改一边另一边的测试就红。
func TestNeteaseGuestUsername(t *testing.T) {
	got := neteaseGuestUsername("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123")
	want := "MDEyMzQ1Njc4OUFCQ0RFRjAxMjM0NTY3ODlBQkNERUYwMTIzNDU2Nzg5QUJDREVGMDEyMyBYa2pIc2o5dnlXcTVRNDdCdXYyVWNnPT0="
	if got != want {
		t.Errorf("username = %s", got)
	}
}

func TestNeteaseGuestFromReply(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	ok := []byte(`{"code":200,"userId":1,"createTime":1}`)
	a := func(c http.Cookie) []*http.Cookie { return []*http.Cookie{{Name: "NMTID", Value: "n"}, &c} }
	g, err := neteaseGuestFromReply(200, ok, a(http.Cookie{Name: "MUSIC_A", Value: "tok", MaxAge: 15552000}), now)
	if err != nil || g.MusicA != "tok" || g.Expires != now.Unix()+15552000 {
		t.Errorf("Max-Age: %+v %v", g, err)
	}
	g, _ = neteaseGuestFromReply(200, ok, a(http.Cookie{Name: "MUSIC_A", Value: "tok", Expires: now.Add(48 * time.Hour)}), now)
	if g.Expires != now.Add(48*time.Hour).Unix() {
		t.Errorf("Expires: %+v", g)
	}
	g, _ = neteaseGuestFromReply(200, ok, a(http.Cookie{Name: "MUSIC_A", Value: "tok"}), now)
	if g.Expires != now.Add(150*24*time.Hour).Unix() {
		t.Errorf("没写有效期按 150 天: %+v", g)
	}
	for name, c := range map[string]struct {
		status  int
		body    string
		cookies []*http.Cookie
	}{
		"HTTP 不是 200": {503, string(ok), a(http.Cookie{Name: "MUSIC_A", Value: "tok"})},
		"code 400":    {200, `{"code":400}`, a(http.Cookie{Name: "MUSIC_A", Value: "tok"})},
		"没发 MUSIC_A":  {200, string(ok), []*http.Cookie{{Name: "NMTID", Value: "n"}}},
		"MUSIC_A 是空的": {200, string(ok), a(http.Cookie{Name: "MUSIC_A", Value: ""})},
	} {
		if _, err := neteaseGuestFromReply(c.status, []byte(c.body), c.cookies, now); err == nil {
			t.Errorf("%s 该算失败", name)
		}
	}
}

// 注册一次落盘,之后内存、盘上的都直接用;盘上那份快过期了重新注册;几次都没成进冷却,冷却期间不再注册;被拒的身份丢掉。
func TestNeteaseGuestNow(t *testing.T) {
	registers, _, _ := withNeteaseMotion(t, "1", nil)
	ctx := context.Background()
	g, ok := neteaseGuestNow(ctx)
	if !ok || g != "guest-1" || *registers != 1 {
		t.Fatalf("首次注册: %q %v %d", g, ok, *registers)
	}
	var onDisk neteaseGuest
	b, _ := os.ReadFile(neteaseGuestPath())
	if json.Unmarshal(b, &onDisk) != nil || onDisk.MusicA != "guest-1" {
		t.Errorf("落盘: %s", b)
	}
	if g, _ := neteaseGuestNow(ctx); g != "guest-1" || *registers != 1 {
		t.Errorf("第二次用内存里的: %q %d", g, *registers)
	}

	neteaseGuestMu.Lock()
	neteaseGuestCached = neteaseGuest{}
	neteaseGuestMu.Unlock()
	app, _ := json.Marshal(neteaseGuest{MusicA: "from-app", Expires: time.Now().Add(30 * 24 * time.Hour).Unix()})
	if err := os.WriteFile(neteaseGuestPath(), app, 0o600); err != nil {
		t.Fatal(err)
	}
	if g, _ := neteaseGuestNow(ctx); g != "from-app" || *registers != 1 {
		t.Errorf("盘上 App 注册的那份直接用: %q %d", g, *registers)
	}

	neteaseForgetGuest("from-app")
	if _, err := os.Stat(neteaseGuestPath()); !os.IsNotExist(err) {
		t.Error("被拒的身份从盘上删掉")
	}
	soon, _ := json.Marshal(neteaseGuest{MusicA: "soon", Expires: time.Now().Add(time.Hour).Unix()})
	_ = os.WriteFile(neteaseGuestPath(), soon, 0o600)
	if g, _ := neteaseGuestNow(ctx); g != "guest-2" || *registers != 2 {
		t.Errorf("盘上那份一天内过期就重新注册: %q %d", g, *registers)
	}

	other, _ := json.Marshal(neteaseGuest{MusicA: "other", Expires: time.Now().Add(30 * 24 * time.Hour).Unix()})
	_ = os.WriteFile(neteaseGuestPath(), other, 0o600)
	neteaseForgetGuest("guest-2")
	if readNeteaseGuestFile(neteaseGuestPath()).MusicA != "other" {
		t.Error("盘上已经换成别的身份时不删")
	}

	_ = os.Remove(neteaseGuestPath())
	neteaseGuestMu.Lock()
	neteaseGuestCached = neteaseGuest{}
	neteaseGuestMu.Unlock()
	fails := 0
	neteaseGuestRegister = func(context.Context) (neteaseGuest, error) { fails++; return neteaseGuest{}, errors.New("code 400") }
	if _, ok := neteaseGuestNow(ctx); ok || fails != neteaseGuestAttempts {
		t.Errorf("连试 %d 次都没成: ok=%v fails=%d", neteaseGuestAttempts, ok, fails)
	}
	if _, ok := neteaseGuestNow(ctx); ok || fails != neteaseGuestAttempts {
		t.Errorf("冷却期间不再注册: fails=%d", fails)
	}
}

// 问过的结论落进缓存(有、没有都记),再问不发请求;请求失败、形状不对、身份被拒都不记;id 形状不对不问。
func TestNeteaseMotionCoverForCaches(t *testing.T) {
	ctx := context.Background()
	found := `{"code":200,"data":{"videoPlayUrl":"http://dcover.music.126.net/a.mp4"}}`
	registers, asks, cookies := withNeteaseMotion(t, "186016", nil)
	if _, done := neteaseMotionCoverFor(ctx, "186016"); done || *asks != 1 {
		t.Fatalf("请求失败没有定论: done=%v asks=%d", done, *asks)
	}
	if (*cookies)[0] != "os=pc; MUSIC_A=guest-1" {
		t.Errorf("带游客身份: %q", (*cookies)[0])
	}
	answer := `{"code":405,"message":"操作频繁"}`
	neteaseDynamicCoverFetch = func(context.Context, string, string) ([]byte, error) { *asks++; return []byte(answer), nil }
	if _, done := neteaseMotionCoverFor(ctx, "186016"); done {
		t.Error("认不出的应答没有定论")
	}
	answer = `{"code":301}`
	if _, done := neteaseMotionCoverFor(ctx, "186016"); done {
		t.Error("身份被拒没有定论")
	}
	answer = found
	if m, done := neteaseMotionCoverFor(ctx, "186016"); !done || m != "ncmv:186016" || *registers != 2 {
		t.Errorf("被拒后重新注册、问成: %q %v registers=%d", m, done, *registers)
	}
	before := *asks
	if m, done := neteaseMotionCoverFor(ctx, "186016"); !done || m != "ncmv:186016" || *asks != before {
		t.Errorf("第二次读缓存不发请求: %q %v", m, done)
	}

	none := `{"code":200,"data":{}}`
	_, noneAsks, _ := withNeteaseMotion(t, "1868553", &none)
	if m, done := neteaseMotionCoverFor(ctx, "1868553"); !done || m != "" {
		t.Errorf("没有也是定论: %q %v", m, done)
	}
	if _, done := neteaseMotionCoverFor(ctx, "1868553"); !done || *noneAsks != 1 {
		t.Errorf("没有也记下: asks=%d", *noneAsks)
	}
	if _, done := neteaseMotionCoverFor(ctx, "12a"); done {
		t.Error("id 形状不对不问")
	}
}

// 没有游客身份(注册没成)时不问、没有定论。
func TestNeteaseMotionCoverWithoutGuest(t *testing.T) {
	found := `{"code":200,"data":{"videoPlayUrl":"http://x/a.mp4"}}`
	_, asks, _ := withNeteaseMotion(t, "186016", &found)
	neteaseGuestRegister = func(context.Context) (neteaseGuest, error) { return neteaseGuest{}, errors.New("code 400") }
	if _, done := neteaseMotionCoverFor(context.Background(), "186016"); done || *asks != 0 {
		t.Errorf("没有身份: done=%v asks=%d", done, *asks)
	}
}

// 按网易云核:有就挂上(身份交给 App 比中段帧),没有记「没有」;没问成没有定论;没有歌曲 id 时前面核过「没有」就记没有,
// 压根没核就整组清掉。QQ 没给出时转到这一支。
func TestMotionVerdictFromNetease(t *testing.T) {
	ctx := context.Background()
	found := `{"code":200,"data":{"videoPlayUrl":"http://dcover.music.126.net/a.mp4"}}`
	withNeteaseMotion(t, "186016", &found)
	const page = "https://music.163.com/song?id=186016"
	e := enrichEntry{CoverURL: "c", NeteaseURL: page}
	if !e.motionVerdictFromNetease(ctx, true) || e.MotionCoverURL != "ncmv:186016" || e.MotionCoverIdentityVerified ||
		!e.MotionCoverChecked || e.MotionCoverFor != "c" || e.MotionPreviewURL != "" {
		t.Errorf("有: %+v", e)
	}

	e = enrichEntry{CoverURL: "c", NeteaseURL: page}
	if !e.motionVerdictFromQQ(ctx, false) || e.MotionCoverURL != "ncmv:186016" {
		t.Errorf("没有 QQ mid 时转到网易云: %+v", e)
	}
	const mid = "002ENNC51FIhXc"
	withQQMotion(t, mid, "", nil, "")
	e = enrichEntry{CoverURL: "c", NeteaseURL: page, QQAlbumMid: mid}
	if !e.motionVerdictFromQQ(ctx, true) || e.MotionCoverURL != "ncmv:186016" {
		t.Errorf("QQ 没有时转到网易云: %+v", e)
	}

	none := `{"code":200,"data":{}}`
	withNeteaseMotion(t, "186016", &none)
	e = enrichEntry{CoverURL: "c", NeteaseURL: page, MotionCoverURL: "old"}
	if !e.motionVerdictFromNetease(ctx, false) || e.MotionCoverURL != "" || !e.MotionCoverChecked || e.MotionCoverFor != "c" {
		t.Errorf("没有: %+v", e)
	}
	withNeteaseMotion(t, "186016", nil)
	e = enrichEntry{CoverURL: "c", NeteaseURL: page}
	if e.motionVerdictFromNetease(ctx, true) || e.MotionCoverChecked {
		t.Errorf("没问成没有定论: %+v", e)
	}
	e = enrichEntry{CoverURL: "c", MotionCoverURL: "old"}
	if !e.motionVerdictFromNetease(ctx, true) || e.MotionCoverURL != "" || !e.MotionCoverChecked {
		t.Errorf("没有 id、前面核过没有: %+v", e)
	}
	e = enrichEntry{CoverURL: "c", MotionCoverURL: "old", MotionCoverChecked: true}
	if !e.motionVerdictFromNetease(ctx, false) || e.MotionCoverURL != "" || e.MotionCoverChecked {
		t.Errorf("没有 id、前面也没核:整组清掉 %+v", e)
	}
}

// 核过「没有」的存量条目,这首网易云还没问过时播到值得补核一次;问过了、有地址、封面换过、没有 id 都不算。
func TestNeteaseMotionCoverUnasked(t *testing.T) {
	none := `{"code":200,"data":{}}`
	withNeteaseMotion(t, "186016", &none)
	const page = "https://music.163.com/song?id=186016"
	base := enrichEntry{CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c", NeteaseURL: page}
	if !neteaseMotionCoverUnasked(base) || !motionCoverFallbackUnasked(base) {
		t.Error("核过没有、网易云没问过")
	}
	for name, e := range map[string]enrichEntry{
		"已有地址":   {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c", MotionCoverURL: "x", NeteaseURL: page},
		"没核过":    {CoverURL: "c", NeteaseURL: page},
		"对着别的封面": {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "old", NeteaseURL: page},
		"没有 id":  {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c"},
	} {
		if neteaseMotionCoverUnasked(e) {
			t.Errorf("%s 不该补核", name)
		}
	}
	neteaseMotionCoverFor(context.Background(), "186016")
	if neteaseMotionCoverUnasked(base) || motionCoverFallbackUnasked(base) {
		t.Error("网易云问过了就不再补")
	}
}

// 游客身份文件名跟 App 那份同一个名字。
func TestNeteaseGuestFileSharedWithApp(t *testing.T) {
	core, err := os.ReadFile(filepath.Join("..", "lyrimuse", "Sources", "LyrimuseCore", "Local", "NeteaseMotionCover.swift"))
	if err != nil {
		t.Skip("没有 App 源码")
	}
	if !containsCode(string(core), `public static let guestFileName = "`+neteaseGuestFileName+`"`) {
		t.Errorf("App 那份的文件名不是 %s", neteaseGuestFileName)
	}
}

// 酷狗本机那份:前面几支都没给出时,这条记着的酷狗专辑 id 在本机有动态封面视频就拷进缓存目录、记 `kgmv:<id>`,身份交给 App 核;
// 没有文件、id 形状不对照旧记「没有」或整组清掉;拷不过来时没有定论。文件后来才有、拷过来的被删了,播到时值得补核。
func TestMotionVerdictFromKugou(t *testing.T) {
	dir := t.TempDir()
	old := kugouDynamicArtworkOverride
	kugouDynamicArtworkOverride = dir
	t.Cleanup(func() { kugouDynamicArtworkOverride = old })
	caches := t.TempDir()
	t.Setenv("LYRIMUSE_CACHE_DIR", caches)
	video := []byte("kugou-mp4")
	if err := os.WriteFile(filepath.Join(dir, "969063.mp4"), video, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "2654569.jpg"), []byte("jpg"), 0o600); err != nil {
		t.Fatal(err)
	}
	// id 形状不核的话,「../escape」会读到酷狗那个目录外面去。
	if err := os.WriteFile(filepath.Join(filepath.Dir(dir), "escape.mp4"), video, 0o600); err != nil {
		t.Fatal(err)
	}
	staged := filepath.Join(caches, "kugou-motion-covers", "969063.mp4")
	ids := func(id string) map[string]string { return map[string]string{kugouMusicBundleID: id} }
	ctx := context.Background()

	e := enrichEntry{CoverURL: "c", PlayerAlbumIDs: ids("969063")}
	if !e.motionVerdictFromNetease(ctx, true) || e.MotionCoverURL != "kgmv:969063" || e.MotionCoverIdentityVerified ||
		!e.MotionCoverChecked || e.MotionCoverFor != "c" {
		t.Errorf("没有网易云 id、酷狗本机有: %+v", e)
	}
	if b, err := os.ReadFile(staged); err != nil || string(b) != string(video) {
		t.Errorf("拷进缓存目录: %q %v", b, err)
	}
	none := `{"code":200,"data":{}}`
	withNeteaseMotion(t, "186016", &none)
	e = enrichEntry{CoverURL: "c", NeteaseURL: "https://music.163.com/song?id=186016", PlayerAlbumIDs: ids("969063")}
	if !e.motionVerdictFromNetease(ctx, false) || e.MotionCoverURL != "kgmv:969063" {
		t.Errorf("网易云没有时转到酷狗: %+v", e)
	}
	e = enrichEntry{CoverURL: "c", PlayerAlbumIDs: ids("969063")}
	if !e.motionVerdictFromQQ(ctx, false) || e.MotionCoverURL != "kgmv:969063" {
		t.Errorf("一路转到酷狗: %+v", e)
	}
	for name, id := range map[string]string{"只有首帧没有视频": "2654569", "本机没有": "1", "id 形状不对": "../escape"} {
		e = enrichEntry{CoverURL: "c", MotionCoverURL: "old", PlayerAlbumIDs: ids(id)}
		if !e.motionVerdictFromKugou(true) || e.MotionCoverURL != "" || !e.MotionCoverChecked {
			t.Errorf("%s:前面核过没有,记没有 %+v", name, e)
		}
	}
	e = enrichEntry{CoverURL: "c", MotionCoverURL: "old", MotionCoverChecked: true}
	if !e.motionVerdictFromKugou(false) || e.MotionCoverURL != "" || e.MotionCoverChecked {
		t.Errorf("没有 id、前面也没核:整组清掉 %+v", e)
	}

	base := enrichEntry{CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c", PlayerAlbumIDs: ids("969063")}
	if !kugouMotionCoverUnasked(base) || !motionCoverFallbackUnasked(base) {
		t.Error("核过没有、酷狗本机后来有了:补核")
	}
	recorded := enrichEntry{CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c", MotionCoverURL: "kgmv:969063",
		PlayerAlbumIDs: ids("969063")}
	for name, e := range map[string]enrichEntry{
		"拷过来的还在": recorded,
		"别家的地址":  {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c", MotionCoverURL: "x", PlayerAlbumIDs: ids("969063")},
		"没核过":    {CoverURL: "c", PlayerAlbumIDs: ids("969063")},
		"对着别的封面": {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "old", PlayerAlbumIDs: ids("969063")},
		"本机没有":   {CoverURL: "c", MotionCoverChecked: true, MotionCoverFor: "c", PlayerAlbumIDs: ids("2654569")},
	} {
		if kugouMotionCoverUnasked(e) {
			t.Errorf("%s 不该补核", name)
		}
	}
	if err := os.Remove(staged); err != nil {
		t.Fatal(err)
	}
	if !kugouMotionCoverUnasked(recorded) {
		t.Error("拷过来的被删了:补核、再拷一次")
	}
	if !recorded.fillMotionCover(ctx, "", "", "") || recorded.MotionCoverURL != "kgmv:969063" {
		t.Errorf("补核记回酷狗那份: %+v", recorded)
	}
	if _, err := os.Stat(staged); err != nil {
		t.Errorf("补核时再拷一次: %v", err)
	}

	kugouDynamicArtworkOverride = filepath.Join(dir, "missing")
	e = enrichEntry{CoverURL: "c", PlayerAlbumIDs: ids("969063")}
	if !e.motionVerdictFromKugou(true) || e.MotionCoverURL != "" {
		t.Errorf("酷狗那个目录读不了当没有: %+v", e)
	}
}

// 拷过来的多于上限时按修改时间删最旧的。
func TestPruneKugouMotionStage(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i, n := range []string{"1.mp4", "2.mp4", "3.mp4", "note.txt"} {
		p := filepath.Join(dir, n)
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		mod := now.Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(p, mod, mod); err != nil {
			t.Fatal(err)
		}
	}
	pruneKugouMotionStage(dir, 2)
	var left []string
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		left = append(left, e.Name())
	}
	if strings.Join(left, ",") != "2.mp4,3.mp4,note.txt" {
		t.Errorf("删最旧的那份、别的文件不动: %v", left)
	}
}

// 拷过来的目录名、地址前缀跟 App 那边同一份。
func TestKugouMotionCoverSharedWithApp(t *testing.T) {
	core, err := os.ReadFile(filepath.Join("..", "lyrimuse", "Sources", "LyrimuseCore", "Local", "KugouMotionCover.swift"))
	if err != nil {
		t.Skip("没有 App 源码")
	}
	for _, want := range []string{`public static let stageDirName = "` + kugouMotionStageDirName + `"`,
		`public static let scheme = "` + strings.TrimSuffix(kugouMotionCoverScheme, ":") + `"`} {
		if !containsCode(string(core), want) {
			t.Errorf("App 那份缺 %s", want)
		}
	}
}
