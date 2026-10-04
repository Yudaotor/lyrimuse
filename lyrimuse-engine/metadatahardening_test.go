package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"image"
	"image/color"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 封面、元数据、歌手身份、榜单、Apple 目录、跨专辑复用这一侧的加固。

// ---- MusicBrainz ----

func TestMBLuceneEscapeAndSearchURL(t *testing.T) {
	cases := map[string]string{
		"AC/DC":    `AC\/DC`,
		"(G)I-DLE": `\(G\)I\-DLE`,
		"P!nk":     `P\!nk`,
		"方大同":      "方大同",
	}
	for in, want := range cases {
		if got := mbLuceneEscape(in); got != want {
			t.Errorf("mbLuceneEscape(%q) = %q, want %q", in, got, want)
		}
	}
	u := mbArtistSearchURL("AC/DC")
	if u != mbArtistSearchURL("AC/DC") || !strings.Contains(u, "query=AC%5C%2FDC&") {
		t.Errorf("搜索地址应当稳定且转义过: %s", u)
	}
}

func TestMBDefinitiveMiss(t *testing.T) {
	for status, want := range map[int]bool{404: true, 400: true, 503: false, 500: false} {
		if got := mbDefinitiveMiss(&mbStatusError{url: "u", status: status}); got != want {
			t.Errorf("status %d: mbDefinitiveMiss = %v, want %v", status, got, want)
		}
	}
	if mbDefinitiveMiss(errors.New("timeout")) {
		t.Error("网络错误不是确定没有")
	}
}

func withArtistAliasState(t *testing.T) {
	t.Helper()
	artistAliasMu.Lock()
	savedCache, savedFailed, savedPath := artistAliasCache, artistAliasFailedUntil, artistAliasPath
	artistAliasCache, artistAliasFailedUntil, artistAliasPath = map[string]string{}, map[string]time.Time{}, ""
	artistAliasMu.Unlock()
	savedOnly := artistCanonicalCacheOnly
	artistCanonicalCacheOnly = false
	t.Cleanup(func() {
		artistAliasMu.Lock()
		artistAliasCache, artistAliasFailedUntil, artistAliasPath = savedCache, savedFailed, savedPath
		artistAliasMu.Unlock()
		artistCanonicalCacheOnly = savedOnly
	})
}

// 手工表排在 MusicBrainz 前面,缓存里早先落下的错值顺手纠正过来。
func TestCanonicalArtistTableFirstCorrectsCache(t *testing.T) {
	withArtistAliasState(t)
	calls := withFakeMBFetch(t, func(string) ([]byte, error) { return nil, errors.New("不该联网") })
	artistAliasMu.Lock()
	artistAliasCache["Pei-Yu Hung"] = "错人"
	artistAliasMu.Unlock()
	if got := canonicalArtistViaMusicBrainz(context.Background(), "Pei-Yu Hung"); got != "洪佩瑜" {
		t.Fatalf("应当用手工表,got %q", got)
	}
	artistAliasMu.Lock()
	cached := artistAliasCache["Pei-Yu Hung"]
	artistAliasMu.Unlock()
	if cached != "洪佩瑜" || len(*calls) != 0 {
		t.Errorf("缓存应被纠正且不联网: cached=%q calls=%v", cached, *calls)
	}
}

// 没问成:不写缓存,退避一段时间内不再排队问。
func TestCanonicalArtistFailureBacksOff(t *testing.T) {
	withArtistAliasState(t)
	calls := withFakeMBFetch(t, func(string) ([]byte, error) {
		return nil, &mbStatusError{url: "u", status: http.StatusServiceUnavailable}
	})
	if got := canonicalArtistViaMusicBrainz(context.Background(), "Backoff Artist"); got != "" {
		t.Fatalf("没问成应返回空,got %q", got)
	}
	first := len(*calls)
	if first == 0 {
		t.Fatal("第一次应当真去问")
	}
	canonicalArtistViaMusicBrainz(context.Background(), "Backoff Artist")
	if len(*calls) != first {
		t.Errorf("退避期内不该再问,又发了 %d 个请求", len(*calls)-first)
	}
	artistAliasMu.Lock()
	_, cached := artistAliasCache["Backoff Artist"]
	until := artistAliasFailedUntil["Backoff Artist"]
	artistAliasMu.Unlock()
	if cached || time.Until(until) <= 0 {
		t.Errorf("不该写缓存、应记退避: cached=%v until=%v", cached, until)
	}
}

// 搜索首条分数再高,本地写法不是那位艺人的主名或别名就不认。
func TestResolveArtistIdentityMBVerifiesName(t *testing.T) {
	artistIdentityMu.Lock()
	savedIDs := artistIdentityCache
	artistIdentityCache = map[string]mbArtistIdentity{}
	artistIdentityMu.Unlock()
	t.Cleanup(func() {
		artistIdentityMu.Lock()
		artistIdentityCache = savedIDs
		artistIdentityMu.Unlock()
	})
	withFakeMBFetch(t, func(url string) ([]byte, error) {
		switch {
		case strings.Contains(url, "query=Wrong"):
			return []byte(`{"artists":[{"id":"mbid-other","name":"Somebody Else","score":100}]}`), nil
		case strings.Contains(url, "query=Right"):
			return []byte(`{"artists":[{"id":"mbid-right","name":"Right Person","score":100}]}`), nil
		case strings.Contains(url, "mbid-other"):
			return []byte(`{"name":"Somebody Else","aliases":[]}`), nil
		default:
			return []byte(`{"name":"Right Person","country":"TW","aliases":[{"name":"对的人","locale":"zh","type":"Artist name"}]}`), nil
		}
	})
	if id := resolveArtistIdentityMB("Wrong Name", ""); id.Mbid != "" || id.Zh != "" {
		t.Errorf("对不上名字的首条不该采纳: %+v", id)
	}
	if id := resolveArtistIdentityMB("Right Person", ""); id.Mbid != "mbid-right" {
		t.Errorf("名字对得上应采纳: %+v", id)
	}
}

// ---- 歌手榜 ----

func TestArtistMergeFold(t *testing.T) {
	pairs := [][2]string{
		{"Dean Ting", "DeanTing"},
		{"Beyoncé", "Beyonce"},
		{"ＡＢＣ", "abc"},
		{"周杰倫", "周杰伦"},
	}
	for _, p := range pairs {
		if artistMergeFold(p[0]) != artistMergeFold(p[1]) {
			t.Errorf("%q 与 %q 应折成同一个键: %q vs %q", p[0], p[1], artistMergeFold(p[0]), artistMergeFold(p[1]))
		}
	}
}

// 合唱串带的 mbid 属于整条 credit(常是第二位的),拿它并桶会把两位歌手连成一行。
func TestMergeBucketsCollabMbidDoesNotBridge(t *testing.T) {
	entries := []lastfmChartEntry{
		{Name: "A & B", PlayCount: 5, Mbid: "mbid-b"},
		{Name: "B", PlayCount: 4, Mbid: "mbid-b"},
		{Name: "A", PlayCount: 3},
	}
	resolve := func(_ string, known string) mbArtistIdentity { return mbArtistIdentity{Mbid: known} }
	key := func(s string) string { return artistMergeFold(firstCreditedArtist(s)) }
	out, _ := mergeAliasedArtistBuckets(entries, resolve, key, func(s string) string { return s })
	if len(out) != 2 {
		t.Fatalf("应当两桶(A、B 各一),got %+v", out)
	}
	for _, b := range out {
		if b.Name == "B" && b.PlayCount != 4 {
			t.Errorf("B 那桶不该并进合唱串: %+v", b)
		}
	}
}

// 上期名次按桶的身份对齐:本期展示成中文、上期展示成英文的同一个人不标「新」。
func TestPreviousBucketRanksByMemberIdentity(t *testing.T) {
	key := func(s string) string { return artistMergeFold(s) }
	curEntries := []lastfmChartEntry{{Name: "窦靖童"}, {Name: "Leah Dou"}, {Name: "别人"}}
	current := []mergedArtist{
		{lastfmChartEntry: lastfmChartEntry{Name: "窦靖童"}, members: []int{0, 1}},
		{lastfmChartEntry: lastfmChartEntry{Name: "别人"}, members: []int{2}},
	}
	prevEntries := []lastfmChartEntry{{Name: "某某"}, {Name: "Leah Dou"}}
	previous := []mergedArtist{
		{lastfmChartEntry: lastfmChartEntry{Name: "某某"}, members: []int{0}},
		{lastfmChartEntry: lastfmChartEntry{Name: "Leah Dou"}, members: []int{1}},
	}
	got := previousBucketRanks(current, curEntries, nil, previous, prevEntries, nil, key)
	if got[0] != 2 || got[1] != 0 {
		t.Errorf("ranks = %v, want [2 0]", got)
	}
	// 只靠 mbid 也对得上。
	curIDs := []mbArtistIdentity{{}, {}, {Mbid: "mbid-x"}}
	prevIDs := []mbArtistIdentity{{Mbid: "mbid-x"}, {}}
	got = previousBucketRanks(current, curEntries, curIDs, previous, prevEntries, prevIDs, key)
	if got[1] != 1 {
		t.Errorf("mbid 相同应对上上期第 1 名,got %v", got)
	}
}

func TestAvatarNameMatches(t *testing.T) {
	cases := []struct {
		want, got string
		ok        bool
	}{
		{"周杰伦", "周杰倫", true},
		{"周杰伦", "周杰伦 Jay Chou", true},
		{"Jay Chou", "JAY CHOU", true},
		{"A", "ABBA", false},
		{"方大同", "薛凯琪", false},
		{"", "x", false},
	}
	for _, c := range cases {
		if got := avatarNameMatches(c.want, c.got); got != c.ok {
			t.Errorf("avatarNameMatches(%q, %q) = %v, want %v", c.want, c.got, got, c.ok)
		}
	}
}

// ---- 播放器署名 ----

// 两个播放器各自的「署名不可信」结论都跨重启留下,不会被后发布的那个盖掉。
func TestPlayerVerdictsSidecarKeepsEveryBundle(t *testing.T) {
	dir := t.TempDir()
	fixPath := filepath.Join(dir, clientName+"-player-artist-fix.json")
	t.Cleanup(func() { setPlayerArtistFixPathLocked("") })
	setPlayerArtistFixPathLocked(fixPath)
	playerArtistFixMu.Lock()
	rememberPlayerVerdictLocked("com.kugou.mac", playerVerdict{})
	rememberPlayerVerdictLocked("com.other.player", playerVerdict{StableField: "artist", Order: "songFirst"})
	playerArtistFixMu.Unlock()

	_, verdicts := setPlayerArtistFixPathLocked(fixPath)
	if len(verdicts) != 2 || verdicts["com.other.player"].StableField != "artist" || verdicts["com.other.player"].Order != "songFirst" {
		t.Fatalf("重启后两份结论都应在: %+v", verdicts)
	}
	if _, err := os.Stat(filepath.Join(dir, clientName+"-player-verdicts.json")); err != nil {
		t.Errorf("侧文件应当落在同目录: %v", err)
	}
}

// ---- 折叠 ----

func TestFoldDiacriticsPinyinThirdToneAndVietnamese(t *testing.T) {
	cases := map[string]string{
		"Zhǒu":   "Zhou",
		"lǚ":     "lu",
		"Nguyễn": "Nguyen",
		"Phạm":   "Pham",
		"Trương": "Truong",
	}
	for in, want := range cases {
		if got := foldDiacritics(in); got != want {
			t.Errorf("foldDiacritics(%q) = %q, want %q", in, got, want)
		}
	}
}

// ---- 封面 ----

// 设备封面那一档的判据由调用方在锁外算好,这里只认结果;别的来源不调它。
func TestCoverSwapDeviceUsesPrecomputedVerdict(t *testing.T) {
	old := enrichEntry{CoverURL: "device://a", CoverSource: "device"}
	fresh := enrichEntry{CoverURL: "https://x/y.jpg", CoverSource: "qq"}
	if coverSwapAllowedWith(old, fresh, "专辑", func(string, string) bool { return false }) {
		t.Error("设备封面判不能升级就不换")
	}
	if !coverSwapAllowedWith(old, fresh, "专辑", func(string, string) bool { return true }) {
		t.Error("设备封面判能升级就换")
	}
	called := false
	coverSwapAllowedWith(enrichEntry{CoverURL: "https://a", CoverSource: "netease"}, fresh, "专辑",
		func(string, string) bool { called = true; return false })
	if called {
		t.Error("旧封面不是设备封面时不该调设备判据")
	}
}

func fillRect(img *image.RGBA, r image.Rectangle, c color.Color) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			img.Set(x, y, c)
		}
	}
}

// 补边(一个轴两侧被裁、另一个轴没裁)才算信箱边;纯色底上居中的宽标志四边都被裁,不算。
func TestCoverContentLetterboxed(t *testing.T) {
	white, ink := color.RGBA{255, 255, 255, 255}, color.RGBA{20, 60, 200, 255}
	bars := image.NewRGBA(image.Rect(0, 0, 100, 100))
	fillRect(bars, bars.Bounds(), white)
	for y := 30; y < 70; y++ {
		for x := 0; x < 100; x++ {
			bars.Set(x, y, color.RGBA{uint8(x * 2), uint8(y), 120, 255})
		}
	}
	if !coverContentLetterboxed(bars) {
		t.Error("上下白边、内容占满全宽应判信箱边")
	}
	logo := image.NewRGBA(image.Rect(0, 0, 100, 100))
	fillRect(logo, logo.Bounds(), white)
	fillRect(logo, image.Rect(20, 40, 80, 60), ink)
	if !coverContentSkewed(logo) {
		t.Fatal("前提:居中宽标志裁边后是长方形")
	}
	if coverContentLetterboxed(logo) {
		t.Error("四边都被裁的极简封面不该判信箱边")
	}
}

// 图头声明的尺寸超过上限就不解码(几十字节就能声明一张巨图)。
func TestDecodeCoverImageRejectsHugeHeader(t *testing.T) {
	var buf bytes.Buffer
	buf.Write([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], 8000)
	binary.BigEndian.PutUint32(ihdr[4:], 8000)
	ihdr[8], ihdr[9] = 8, 2 // 8 位 RGB
	chunk := append([]byte("IHDR"), ihdr...)
	binary.Write(&buf, binary.BigEndian, uint32(len(ihdr)))
	buf.Write(chunk)
	binary.Write(&buf, binary.BigEndian, crc32.ChecksumIEEE(chunk))
	if _, err := decodeCoverImage(buf.Bytes()); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("8000² 应当拒绝解码,got %v", err)
	}
}

// 排队时对着的中继已经换了:结果不属于新中继,什么都不记。
func TestArtworkUploadForReplacedRelayIsDiscarded(t *testing.T) {
	resetArtworkRelayState(t)
	release := make(chan struct{})
	var heads atomic.Int32
	old := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		heads.Add(1)
		<-release
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(old.Close)
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	path := filepath.Join(t.TempDir(), testSHA+".jpg")
	if err := os.WriteFile(path, []byte("jpeg"), 0o600); err != nil {
		t.Fatal(err)
	}
	setStateRelay(old.URL, "tok")
	scheduleArtworkUpload(testSHA, path)
	waitFor(t, "旧中继收到 HEAD", func() bool { return heads.Load() > 0 })
	setStateRelay("http://new-relay.invalid", "tok")
	close(release)
	waitArtworkIdle(t)
	artworkMu.Lock()
	uploaded := artworkUploaded[testSHA]
	_, retry := artworkNextRetry[testSHA]
	artworkMu.Unlock()
	if uploaded || retry {
		t.Errorf("旧中继的结果不该记到新中继头上: uploaded=%v retry=%v", uploaded, retry)
	}
}

// 超过中继上限的图:一天后再看,不每 5 分钟重试。
func TestArtworkTooLargeBacksOffForADay(t *testing.T) {
	resetArtworkRelayState(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	setStateRelay(srv.URL, "tok")
	path := filepath.Join(t.TempDir(), testSHA+".jpg")
	if err := os.WriteFile(path, bytes.Repeat([]byte{1}, artworkMaxUploadBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	scheduleArtworkUpload(testSHA, path)
	waitArtworkIdle(t)
	artworkMu.Lock()
	next := artworkNextRetry[testSHA]
	artworkMu.Unlock()
	if time.Until(next) < 23*time.Hour {
		t.Errorf("超限的图应退避约一天,下次重试在 %v 之后", time.Until(next))
	}
}

// ---- 头像缓存 ----

func TestPruneAvatarCache(t *testing.T) {
	now := time.Now()
	m := map[string]avatarCacheEntry{
		"fresh":           {URL: "u", TS: now.Add(-time.Hour).Unix()},
		"stale-in-grace":  {URL: "u", TS: now.Add(-avatarCacheTTL - time.Hour).Unix()},
		"long-gone":       {URL: "u", TS: now.Add(-3 * avatarCacheTTL).Unix()},
		"transient-old":   {TS: now.Add(-3 * avatarTransientTTL).Unix(), Transient: true},
		"transient-fresh": {TS: now.Add(-time.Minute).Unix(), Transient: true},
	}
	pruneAvatarCache(m, now)
	for _, k := range []string{"fresh", "stale-in-grace", "transient-fresh"} {
		if _, ok := m[k]; !ok {
			t.Errorf("%s 不该被修剪", k)
		}
	}
	for _, k := range []string{"long-gone", "transient-old"} {
		if _, ok := m[k]; ok {
			t.Errorf("%s 应当被修剪", k)
		}
	}
}

// 跨进程排他锁:第二个拿锁的要等第一个放开。
func TestExclusiveFileLockSerializes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.json")
	unlock := exclusiveFileLock(path)
	got := make(chan struct{})
	go func() {
		u := exclusiveFileLock(path)
		close(got)
		u()
	}()
	select {
	case <-got:
		t.Fatal("第一把锁没放开,第二个不该拿到")
	case <-time.After(100 * time.Millisecond):
	}
	unlock()
	select {
	case <-got:
	case <-time.After(2 * time.Second):
		t.Fatal("放开之后第二个应当拿到")
	}
}

// ---- Apple 目录 ----

func withAppleCatalogState(t *testing.T) {
	t.Helper()
	appleCatalogMu.Lock()
	oldIndex, oldCache, oldPath, oldDirty := appleCatalogByTrack, appleCatalogCache, appleCatalogPath, appleCatalogDirty
	appleCatalogByTrack, appleCatalogCache, appleCatalogPath, appleCatalogDirty = map[string]appleCatalogTrack{}, map[string]appleCatalogTrack{}, "", false
	appleCatalogMu.Unlock()
	appleCatalogUnanchorableMu.Lock()
	oldUnanchorable := appleCatalogUnanchorable
	appleCatalogUnanchorable = map[string]bool{}
	appleCatalogUnanchorableMu.Unlock()
	oldURL := appleCatalogLookupURL
	t.Cleanup(func() {
		appleCatalogMu.Lock()
		appleCatalogByTrack, appleCatalogCache, appleCatalogPath, appleCatalogDirty = oldIndex, oldCache, oldPath, oldDirty
		appleCatalogMu.Unlock()
		appleCatalogUnanchorableMu.Lock()
		appleCatalogUnanchorable = oldUnanchorable
		appleCatalogUnanchorableMu.Unlock()
		appleCatalogLookupURL = oldURL
	})
}

// 中国区答了、却没有这条:再问美区(外区账号播的中国区没上架曲目)。中国区没答成的不往下问。
func TestAppleCatalogLookupFallsBackToUS(t *testing.T) {
	withAppleCatalogState(t)
	var mu sync.Mutex
	var countries []string
	cnStatus := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c := r.URL.Query().Get("country")
		mu.Lock()
		countries = append(countries, c)
		status := cnStatus
		mu.Unlock()
		if c == "cn" {
			if status != http.StatusOK {
				w.WriteHeader(status)
				return
			}
			w.Write([]byte(`{"results":[]}`))
			return
		}
		w.Write([]byte(`{"results":[{"wrapperType":"track","trackName":"Song","artistName":"Artist","collectionName":"Album","collectionId":7,"trackNumber":1,"trackTimeMillis":200000}]}`))
	}))
	t.Cleanup(srv.Close)
	appleCatalogLookupURL = srv.URL
	tr, ok, answered := appleCatalogLookup(42)
	if !ok || !answered || tr.TrackName != "Song" || tr.AlbumID != 7 {
		t.Fatalf("美区应当补上: %+v ok=%v answered=%v", tr, ok, answered)
	}
	mu.Lock()
	if strings.Join(countries, ",") != "cn,us" {
		t.Errorf("应先中国区再美区: %v", countries)
	}
	countries, cnStatus = nil, http.StatusServiceUnavailable
	mu.Unlock()
	if _, ok, answered := appleCatalogLookup(43); ok || answered {
		t.Errorf("中国区没答成不算证据: ok=%v answered=%v", ok, answered)
	}
	mu.Lock()
	defer mu.Unlock()
	if strings.Join(countries, ",") != "cn" {
		t.Errorf("中国区没答成不该再问美区: %v", countries)
	}
}

// 没报专辑名的不写索引、记成立不起锚点;ID 不可能是目录 ID 的同样记下。同专辑预取据此不白等。
func TestAppleCatalogUnanchorableSkipsAlbumWait(t *testing.T) {
	withAppleCatalogState(t)
	appleCatalogMu.Lock()
	appleCatalogCache["123"] = appleCatalogTrack{TrackName: "Song", AlbumName: "Album", AlbumID: 9}
	appleCatalogMu.Unlock()
	if _, ok := appleCatalogAnchor(appleMusicBundleID, 123, 0, "Song", ""); !ok {
		t.Fatal("核对通过的应当立起锚点")
	}
	appleCatalogMu.Lock()
	n := len(appleCatalogByTrack)
	appleCatalogMu.Unlock()
	if n != 0 {
		t.Error("没报专辑名不该写索引")
	}
	if !appleCatalogCannotAnchor("Song", "") {
		t.Error("没报专辑名的一律立不起")
	}
	appleCatalogAnchor(appleMusicBundleID, -1, 0, "本地文件", "某专辑")
	if !appleCatalogCannotAnchor("本地文件", "某专辑") {
		t.Error("ID 不可能是目录 ID 的应记成立不起锚点")
	}

	oldWait := appleAlbumAnchorWait
	appleAlbumAnchorWait = 5 * time.Second
	t.Cleanup(func() { appleAlbumAnchorWait = oldWait })
	start := time.Now()
	if got := appleCatalogAlbumTracks("本地文件", "某专辑"); got != nil {
		t.Fatalf("立不起锚点应返回 nil: %+v", got)
	}
	if d := time.Since(start); d > time.Second {
		t.Errorf("不该白等锚点,用了 %v", d)
	}
}

// 分桶索引跟着缓存走:同名不同人按歌手挑;整份换掉缓存后按新缓存答。
func TestAppleCatalogKeyIndexFollowsCache(t *testing.T) {
	withAppleCatalogState(t)
	appleCatalogMu.Lock()
	appleCatalogCache = map[string]appleCatalogTrack{
		"1": {TrackName: "Song", AlbumName: "Album", ArtistName: "Alpha", AlbumID: 11},
		"2": {TrackName: "Song", AlbumName: "Album", ArtistName: "Beta", AlbumID: 22},
	}
	appleCatalogMu.Unlock()
	if id, ok := appleCatalogAlbumIDFor("Beta", "Song", "Album"); !ok || id != 22 {
		t.Fatalf("应按歌手挑出 Beta 那条,got %d %v", id, ok)
	}
	appleCatalogMu.Lock()
	appleCatalogCache = map[string]appleCatalogTrack{"3": {TrackName: "Song", AlbumName: "Album", ArtistName: "Beta", AlbumID: 33}}
	appleCatalogMu.Unlock()
	if id, ok := appleCatalogAlbumIDFor("Beta", "Song", "Album"); !ok || id != 33 {
		t.Fatalf("换了缓存应按新缓存答,got %d %v", id, ok)
	}
}

// 写盘失败:dirty 恢复,下一次保存还会再试。
func TestAppleCatalogSaveFailureKeepsDirty(t *testing.T) {
	withAppleCatalogState(t)
	appleCatalogMu.Lock()
	appleCatalogPath = filepath.Join(t.TempDir(), "missing-dir", "apple-catalog.json")
	appleCatalogCache["1"] = appleCatalogTrack{TrackName: "x"}
	appleCatalogDirty = true
	appleCatalogMu.Unlock()
	saveAppleCatalogCache()
	appleCatalogMu.Lock()
	dirty := appleCatalogDirty
	appleCatalogMu.Unlock()
	if !dirty {
		t.Error("写失败后应保持 dirty")
	}
}

// ---- 跨专辑复用 ----

// ---- 平台页 ----

// 歌手 mbid 还没解析出来:专辑根本没查过,这首歌不能记成「查过、没有」。
func TestWarmPlatformPagesMissingMbidDoesNotSettleTrack(t *testing.T) {
	resetPlatformPagesForTest(t)
	src := platformPagesSource{
		topArtists: func(context.Context, string) ([]lastfmChartEntry, error) { return nil, nil },
		topAlbums:  func(context.Context, string) ([]lastfmChartEntry, error) { return nil, nil },
		topTracks: func(context.Context, string) ([]lastfmChartEntry, error) {
			return []lastfmChartEntry{{Name: "歌", Artist: "歌手"}}, nil
		},
		artistPages: func(context.Context, string) (platformArtistPages, int, error) { return platformArtistPages{}, 0, nil },
		albumSpotify: func(context.Context, string, string) (string, int, error) {
			t.Error("没有 mbid 不该查专辑")
			return "", 0, nil
		},
		artistMbid:  func(string) string { return "" },
		trackAlbums: func(string, string, int) []string { return []string{"专辑"} },
		albumTracks: func(context.Context, string) ([]spotifyAlbumTrack, error) { return nil, nil },
	}
	warmPlatformPages(context.Background(), time.Now(), 10, src)
	platformPagesMu.Lock()
	defer platformPagesMu.Unlock()
	if _, ok := platformPagesCache.Tracks[platformAlbumKey("歌手", "歌")]; ok {
		t.Error("没查过专辑的歌不该落结论")
	}
}
