package main

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
)

func resetPlayerCatalogMemo(t *testing.T) {
	t.Helper()
	clear := func() {
		playerCatalogMu.Lock()
		playerCatalogMemo = map[string]playerCatalogAt{}
		playerCatalogMu.Unlock()
	}
	clear()
	t.Cleanup(clear)
}

// testSodaCatalogRecord 拼一条音频缓存记录(同 testSodaPreviewRecord),曲目、歌手、专辑的 id 用真实的数字形状。artists 是
// {id, 名字},第二位起用结构引用,跟真实数据一样。
func testSodaCatalogRecord(id, name string, artists [][2]string, albumID, album string, durMs, pvStart, pvDur uint32) []byte {
	artistVals := make([][]byte, 0, len(artists))
	for i, a := range artists {
		if i == 0 {
			artistVals = append(artistVals, mpDef('D', []string{"id", "name"}, mpStr(a[0]), mpStr(a[1])))
		} else {
			artistVals = append(artistVals, mpRef('D', mpStr(a[0]), mpStr(a[1])))
		}
	}
	playable := mpDef('C', []string{"id", "name", "artists", "album", "duration", "preview"},
		mpStr(id), mpStr(name), mpArr(artistVals...),
		mpDef('E', []string{"id", "name"}, mpStr(albumID), mpStr(album)), mpU32(durMs),
		mpDef('F', []string{"start", "duration"}, mpU32(pvStart), mpU32(pvDur)))
	detail := mpDef('B', []string{"video_model", "playable"}, []byte{0xc0}, playable)
	info := mpDef('A', []string{"trackId", "urls", "mediaDetail"}, mpStr(id), mpArr(), detail)
	return mpDef('@', []string{"resourceId", "info", "headers", "chunkId", "previousAccessTime", "size"},
		mpStr("v_P_medium"), info, []byte{0x80}, mpStr("x"), mpU32(uint32(time.Now().Unix())), mpU32(1))
}

func useTestSodaPreload(t *testing.T, records ...[]byte) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "entries.db")
	var raw []byte
	for _, r := range records {
		raw = append(raw, r...)
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	old := sodaPreloadOverride
	sodaPreloadOverride = path
	reset := func() {
		sodaPreloadIndexMu.Lock()
		sodaPreloadIndexMod, sodaPreloadIndexSize, sodaPreloadIndexTrack = time.Time{}, 0, nil
		sodaPreloadIndexMu.Unlock()
	}
	reset()
	t.Cleanup(func() {
		sodaPreloadOverride = old
		reset()
	})
}

const testSodaSongPage = "https://music.douyin.com/qishui/share/track?track_id=7687935075879012369"

// 汽水:队列缓存里有这首,曲目 id 拼成歌曲页,专辑、第一位歌手的 id 原样记。多人署名拆开逐个查。
func TestPlayerCatalogSodaFromQueueCache(t *testing.T) {
	resetPlayerCatalogMemo(t)
	tanta := sodaTestTrack("坍塌", "田馥甄", "要去什麼地方", 257000, 1, 1000)
	tanta["id"] = "7687935075879012369"
	tanta["artists"] = []map[string]any{{"id": "6841932444073986049", "name": "田馥甄"}}
	tanta["album"] = map[string]any{"id": "7687934888654342145", "name": "要去什麼地方"}
	duet := sodaTestTrack("一样的月光", "HUSH|孙盛希", "合辑", 240000, 1, 1000)
	duet["id"] = "7000000000000000001"
	duet["artists"] = []map[string]any{{"id": "6000000000000000001", "name": "HUSH"}, {"id": "6000000000000000002", "name": "孙盛希"}}
	resetSodaLocalIndex(t, writeTestSodaQueue(t, []map[string]any{tanta, duet}))

	got := playerCatalogIDsFor(sodaMusicBundleID, "田馥甄", "坍塌", "要去什麼地方", 257)
	want := playerCatalogIDs{song: testSodaSongPage, album: "7687934888654342145", artist: "6841932444073986049"}
	if got != want {
		t.Errorf("队列缓存里的这首: got %+v want %+v", got, want)
	}
	got = playerCatalogIDsFor(sodaMusicBundleID, "HUSH, 孙盛希", "一样的月光", "", 240)
	if got.song != "https://music.douyin.com/qishui/share/track?track_id=7000000000000000001" || got.artist != "6000000000000000001" {
		t.Errorf("多人署名拆开查,歌手页给第一位: %+v", got)
	}
	if got := playerCatalogIDsFor(sodaMusicBundleID, "田馥甄", "坍塌", "要去什麼地方", 400); got != (playerCatalogIDs{}) {
		t.Errorf("时长对不上不认: %+v", got)
	}
}

// 汽水:从歌单、专辑点播的不在队列缓存里,看音频缓存库;放的是试听段时按试听段对时长。
func TestPlayerCatalogSodaFromPreload(t *testing.T) {
	resetPlayerCatalogMemo(t)
	tianFuZhen := [][2]string{{"6841932444073986049", "田馥甄"}}
	useTestSodaPreload(t,
		testSodaCatalogRecord("7687935075879012369", "坍塌", tianFuZhen, "7687934888654342145", "要去什麼地方", 257000, 60000, 30000),
		testSodaCatalogRecord("7111111111111111111", "坍塌", tianFuZhen, "7222222222222222222", "现场版", 300000, 0, 0),
		testSodaCatalogRecord("7333333333333333333", "坍塌", tianFuZhen, "7444444444444444444", "精选", 257000, 0, 0))
	want := playerCatalogIDs{song: testSodaSongPage, album: "7687934888654342145", artist: "6841932444073986049"}
	if got := playerCatalogIDsFor(sodaMusicBundleID, "田馥甄", "坍塌", "要去什麼地方", 257); got != want {
		t.Errorf("整首对得上: got %+v want %+v", got, want)
	}
	if got := playerCatalogIDsFor(sodaMusicBundleID, "田馥甄", "坍塌", "", 30); got != want {
		t.Errorf("播放器报的是试听段长度: got %+v want %+v", got, want)
	}
	if got := playerCatalogIDsFor(sodaMusicBundleID, "田馥甄", "坍塌", "现场版", 300); got.album != "7222222222222222222" {
		t.Errorf("同名几条按时长挑: %+v", got)
	}
	if got := playerCatalogIDsFor(sodaMusicBundleID, "田馥甄", "坍塌", "精选", 257); got.album != "7444444444444444444" {
		t.Errorf("时长一样长的,专辑对得上的优先: %+v", got)
	}
	if got := playerCatalogIDsFor(sodaMusicBundleID, "别人", "坍塌", "", 257); got != (playerCatalogIDs{}) {
		t.Errorf("歌手对不上不认: %+v", got)
	}
	// 多位歌手时取第一位的 id。
	recs := parseSodaPreloads(testSodaCatalogRecord("1", "歌", [][2]string{{"61", "甲"}, {"62", "乙"}}, "71", "专辑", 1000, 0, 0))
	if len(recs) != 1 || recs[0].artistID != "61" || recs[0].albumID != "71" || recs[0].upcoming.artist != "甲/乙" {
		t.Errorf("第一位歌手的 id: %+v", recs)
	}
}

// KKBOX:单曲详情里的 album.id / artist.id(artist_roles 里的歌手没有 id)。
func TestPlayerCatalogKKBOX(t *testing.T) {
	resetPlayerCatalogMemo(t)
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "su1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/AH1?terr=tw",
		`{"data":{"id":"AH1","name":"Anti-Hero","url":"https://www.kkbox.com/tw/tc/song/AH1",`+
			`"album":{"id":"DY_DcEg9I9ARV8260S","name":"Midnights"},"artist":{"id":"KqGSBUJYQwYgkNtSSR","name":"Taylor Swift (泰勒絲)"},`+
			`"artist_roles":{"main_artists":[{"id":null,"name":"Taylor Swift"}]},"duration_ms":200690}}`)
	got := playerCatalogIDsFor(kkboxBundleID, "Taylor Swift", "Anti-Hero", "Midnights", 200.7)
	if want := (playerCatalogIDs{album: "DY_DcEg9I9ARV8260S", artist: "KqGSBUJYQwYgkNtSSR"}); got != want {
		t.Errorf("got %+v want %+v", got, want)
	}
	if got := playerCatalogIDsFor(kkboxBundleID, "Taylor Swift", "Not Played", "", 0); got != (playerCatalogIDs{}) {
		t.Errorf("没放过的歌没有: %+v", got)
	}
}

// Amazon Music:目录缓存里这首(App 报的 ASIN)的专辑与歌手 ASIN。
func TestPlayerCatalogAmazon(t *testing.T) {
	resetPlayerCatalogMemo(t)
	useTempAmazonData(t)
	amazonCurrentMu.Lock()
	savedCur := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	t.Cleanup(func() {
		amazonCurrentMu.Lock()
		amazonCurrentTrack = savedCur
		amazonCurrentMu.Unlock()
	})
	noteAmazonCurrentTrack(amazonMusicBundleID, "Ella Langley & Morgan Wallen", "I Can't Love You Anymore [Explicit]", "asin://B0TESTAAA2")
	got := playerCatalogIDsFor(amazonMusicBundleID, "Ella Langley & Morgan Wallen", "I Can't Love You Anymore [Explicit]", "", 229)
	if want := (playerCatalogIDs{album: "B0TESTALB1", artist: "B0TESTART1"}); got != want {
		t.Errorf("got %+v want %+v", got, want)
	}
	if got := playerCatalogIDsFor(amazonMusicBundleID, "Someone Else", "Other", "", 229); got != (playerCatalogIDs{}) {
		t.Errorf("不是 App 认出的那首、也没记过它的 ASIN: %+v", got)
	}
}

// Spotify:元数据缓存里这首的所属专辑与第一位歌手。
func TestPlayerCatalogSpotify(t *testing.T) {
	resetPlayerCatalogMemo(t)
	newTestSpotifyAlbumEnv(t, false, true)
	track1, _ := testSpotifyID(1)
	albumID, albumGID := testSpotifyID(100)
	artistID, artistGID := testSpotifyID(200)
	_, otherGID := testSpotifyID(201)
	v := pbMsg(pbStr(2, "歌1"), pbBytes(3, pbMsg(pbBytes(1, albumGID), pbStr(2, "专辑1"))),
		pbBytes(4, pbMsg(pbBytes(1, artistGID), pbStr(2, "甲"))), pbBytes(4, pbMsg(pbBytes(1, otherGID), pbStr(2, "乙"))))
	rec := pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Track"), pbBytes(2, v))))
	testWriteTable(t, filepath.Join(spotifyActiveUserDir(), "primary.ldb", "000003.ldb"),
		[]testLDBEntry{{key: string(spotifyXmetaKey(spotifyTrackKind, track1)), seq: 2000, value: string(rec)}}, 2, true)
	got := playerCatalogIDsFor(spotifyBundleID, "甲", "歌1", "专辑1", 1)
	if want := (playerCatalogIDs{album: albumID, artist: artistID}); got != want {
		t.Errorf("got %+v want %+v", got, want)
	}
	if got := spotifyParseTrackArtistID(testSpotifyTrackInAlbum(1000, albumGID)); got != "" {
		t.Errorf("没有歌手字段时为空: %q", got)
	}
	if got := playerCatalogIDsFor(spotifyBundleID, "乙", "没记过的歌", "", 1); got != (playerCatalogIDs{}) {
		t.Errorf("没有换曲那一拍记下的曲目 id 时不猜: %+v", got)
	}
}

// 读到的 id 记进条目;读不到的不删记下的;不是这四家什么都不动。
func TestApplyPlayerCatalogIDs(t *testing.T) {
	e := enrichEntry{SodaAlbumID: "1", KKBOXArtistID: "keep"}
	if !applyPlayerCatalogIDsLocked(&e, sodaMusicBundleID, playerCatalogIDs{song: testSodaSongPage, album: "2", artist: "3"}) ||
		e.SodaURL != testSodaSongPage || e.SodaAlbumID != "2" || e.SodaArtistID != "3" {
		t.Errorf("汽水三样都记: %+v", e)
	}
	if applyPlayerCatalogIDsLocked(&e, sodaMusicBundleID, playerCatalogIDs{song: testSodaSongPage, album: "2", artist: "3"}) {
		t.Error("没变不算改动")
	}
	if applyPlayerCatalogIDsLocked(&e, sodaMusicBundleID, playerCatalogIDs{}) || e.SodaAlbumID != "2" {
		t.Errorf("读不到不删: %+v", e)
	}
	if !applyPlayerCatalogIDsLocked(&e, kkboxBundleID, playerCatalogIDs{album: "A"}) || e.KKBOXAlbumID != "A" || e.KKBOXArtistID != "keep" {
		t.Errorf("KKBOX 只改读到的那样: %+v", e)
	}
	if !applyPlayerCatalogIDsLocked(&e, amazonMusicBundleID, playerCatalogIDs{album: "B0TESTALB1", artist: "B0TESTART1"}) ||
		e.AmazonAlbumASIN != "B0TESTALB1" || e.AmazonArtistASIN != "B0TESTART1" {
		t.Errorf("Amazon: %+v", e)
	}
	if !applyPlayerCatalogIDsLocked(&e, spotifyBundleID, playerCatalogIDs{album: "x", artist: "y"}) ||
		e.SpotifyAlbumID != "x" || e.SpotifyArtistID != "y" {
		t.Errorf("Spotify: %+v", e)
	}
	before := e
	if applyPlayerCatalogIDsLocked(&e, qqMusicBundleID, playerCatalogIDs{song: "s", album: "a", artist: "b"}) || !reflect.DeepEqual(e, before) {
		t.Errorf("别的播放器不动: %+v", e)
	}
}

func TestPlayerCatalogIDShapes(t *testing.T) {
	for _, c := range []struct {
		bundle, id string
		want       bool
	}{
		{sodaMusicBundleID, "7687934888654342145", true},
		{sodaMusicBundleID, "a", false},
		{sodaMusicBundleID, "", false},
		{kkboxBundleID, "DY_DcEg9I9ARV8260S", true},
		{kkboxBundleID, "CpWsMZtnOiWI4EO-Ej", true},
		{kkboxBundleID, "a/b", false},
		{amazonMusicBundleID, "B001KX03JE", true},
		{amazonMusicBundleID, "b001kx03je", false},
		{amazonMusicBundleID, "B001KX03J", false},
		{spotifyBundleID, "72NhFAGG5Pt91VbheJeEPG", true},
		{spotifyBundleID, "72NhFAGG5Pt91VbheJeEP", false},
		{spotifyBundleID, "missing value", false},
		{qqMusicBundleID, "002B4bAK3AC0Cw", false},
	} {
		if got := playerCatalogIDOK(c.bundle, c.id); got != c.want {
			t.Errorf("playerCatalogIDOK(%s, %q) = %v", c.bundle, c.id, got)
		}
	}
	if got := sodaTrackPageURL("7687935075879012369"); got != testSodaSongPage {
		t.Errorf("汽水歌曲页: %q", got)
	}
	if got := sodaTrackPageURL("1&x=2"); got != "" {
		t.Errorf("汽水曲目 id 形状不对不拼: %q", got)
	}
	for _, c := range []struct {
		id, prefix string
		want       bool
	}{
		{"MPREb_OUh6Wf3kq7x", ytmusicAlbumBrowsePrefix, true},
		{"UCZONOh3FvcD-a_b", ytmusicChannelPrefix, true},
		{"MPREb_", ytmusicAlbumBrowsePrefix, false},
		{"VLPL123", ytmusicAlbumBrowsePrefix, false},
		{"UC1/../x", ytmusicChannelPrefix, false},
		{"", ytmusicChannelPrefix, false},
	} {
		if got := ytmusicBrowseIDOK(c.id, c.prefix); got != c.want {
			t.Errorf("ytmusicBrowseIDOK(%q, %q) = %v", c.id, c.prefix, got)
		}
	}
}

// 汽水歌曲页跟别家的歌曲页一样进 fields()、ListenBrainz 和中继;专辑、歌手 id 只给 App,不进 fields()。合并条目时都带上。
func TestPlayerCatalogFieldsAndMerge(t *testing.T) {
	full := enrichEntry{SodaURL: testSodaSongPage, SodaAlbumID: "1", SodaArtistID: "2", KKBOXAlbumID: "3", KKBOXArtistID: "4",
		AmazonAlbumASIN: "B0TESTALB1", AmazonArtistASIN: "B0TESTART1", SpotifyAlbumID: "5", SpotifyArtistID: "6",
		YouTubeMusicAlbum: "Westside Whimsy", YouTubeMusicAlbumLang: "en", YouTubeMusicAlbumRev: kasetAlbumVerdictRev,
		YouTubeMusicAlbumID: "MPREb_OUh6Wf3kq7x", YouTubeMusicArtistID: "UCZONOh3FvcD"}
	f := full.fields()
	if f["soda_url"] != testSodaSongPage {
		t.Errorf("fields() 要带 soda_url: %v", f)
	}
	for k := range f {
		if strings.HasSuffix(k, "_album_id") || strings.HasSuffix(k, "_artist_id") || strings.HasSuffix(k, "_asin") {
			t.Errorf("专辑、歌手 id 不进 fields(): %s", k)
		}
	}
	withEnrichCache(t, map[string]enrichEntry{enrichKey("歌手", "歌名", "专辑"): full})
	s := snapshot{Artist: "歌手", Title: "歌名", Album: "专辑", Remote: true}
	if got := lbMeta(s).AdditionalInfo["soda_url"]; got != testSodaSongPage {
		t.Errorf("ListenBrainz additional_info 带上汽水歌曲页: %v", got)
	}
	links, _ := relayState(s, true, "", 0, true)["links"].(map[string]any)
	if got := links["soda"]; got != testSodaSongPage {
		t.Errorf("中继 links.soda: %v", got)
	}
	if got := mergePeripheralInto(enrichEntry{}, full); !reflect.DeepEqual(got, full) {
		t.Errorf("合并条目时都从落选那条补过来:\n got %+v\nwant %+v", got, full)
	}
	winner := enrichEntry{SodaAlbumID: "w", YouTubeMusicMV: true, YouTubeMusicAlbumLang: "en"}
	if got := mergePeripheralInto(winner, full); got.SodaAlbumID != "w" || got.YouTubeMusicAlbumID != "" || got.YouTubeMusicArtistID != "UCZONOh3FvcD" {
		t.Errorf("胜者有的不动;专辑页 id 跟着专辑判定那一组走,胜者判成 MV 就不补: %+v", got)
	}
}

// 专辑页、歌手页的 id(连同 QQ 的两个 mid)都要被 App 解码、交给 PlatformLinks(EnrichCacheReader.swift)。以 enrichEntry 上的
// 字段为准逐个核对:漏了哪一个都不报错,只是菜单里那一行悄悄不出现。
func TestCatalogIDFieldsReachApp(t *testing.T) {
	raw, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Local/EnrichCacheReader.swift")
	if err != nil {
		t.Fatal(err)
	}
	swift := string(raw)
	start := strings.Index(swift, "public static func platformLinks(")
	if start < 0 {
		t.Fatal("EnrichCacheReader.swift 里没找到 platformLinks(签名改了就跟着改这条测试)")
	}
	feed := swift[start:]
	if end := strings.Index(feed, "\n    }\n"); end > 0 {
		feed = feed[:end]
	}
	idKey := regexp.MustCompile(`_(album|artist)_(id|asin)$|_(album|singer)_mid$`)
	rt := reflect.TypeOf(enrichEntry{})
	n := 0
	for i := 0; i < rt.NumField(); i++ {
		key, _, _ := strings.Cut(rt.Field(i).Tag.Get("json"), ",")
		if !idKey.MatchString(key) {
			continue
		}
		n++
		m := regexp.MustCompile(`case (\w+) = "` + regexp.QuoteMeta(key) + `"`).FindStringSubmatch(swift)
		if m == nil {
			t.Errorf("%s:App 没解码(EnrichCacheReader.swift 的 CodingKeys 里没有)", key)
		} else if !strings.Contains(feed, "entry."+m[1]) {
			t.Errorf("%s:App 解码了却没交给 PlatformLinks(platformLinks 里没用 entry.%s)", key, m[1])
		}
	}
	if n != 12 {
		t.Errorf("认出 %d 个专辑、歌手 id 字段,应为 12 个(QQ 两个 mid + 汽水、KKBOX、Amazon Music、Spotify、YouTube Music 各两个)", n)
	}
}

// trackEnrichment 在锁外读、锁里记,同一套「变了才落盘」。
func TestPlayerCatalogWiredIntoTrackEnrichment(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"catalogIDs := playerCatalogIDsFor(bundleID, artist, title, album, durationSecs)",
		"if applyPlayerCatalogIDsLocked(&e, bundleID, catalogIDs) {"} {
		if !strings.Contains(string(src), want) {
			t.Errorf("enrich.go 缺 %q", want)
		}
	}
}

// Kaset:署名行里链到歌手页的那一段给频道 id;专辑页 id 跟着专辑走,歌手频道 id 这一版没有时留着记下的。
func TestKasetCatalogIDs(t *testing.T) {
	if c := ytmusicCreditFromNext([]byte(ytmCreditNext), "ot0WzesOp6I"); c.artistBrowseID != "UCZONOh3FvcD" {
		t.Errorf("歌手那一段的频道 id: %+v", c)
	}
	if c := ytmusicCreditFromNext([]byte(ytmCreditNext), "Qt2mbGP6vFI"); c.artistBrowseID != "" {
		t.Errorf("没标页面类型的不当歌手页: %+v", c)
	}
	credits := map[string]ytmusicCredit{
		"OMVSAME0001": {videoType: ytmusicVideoTypeOMV, durationSecs: 197, artistBrowseID: "UCZONOh3FvcD"},
		"ATVALBUM001": {album: "Westside Whimsy", videoType: "MUSIC_VIDEO_TYPE_ATV", durationSecs: 196, albumBrowseID: "MPREb_OUh6Wf3kq7x"},
	}
	l := kasetAlbumLookups{
		listed:  func(id string) (ytmusicCredit, bool) { return credits[id], true },
		catalog: func(artist, title string, secs float64) (string, bool) { return "", true },
		audioOf: func(id string) string { return map[string]string{"OMVSAME0001": "ATVALBUM001"}[id] },
	}
	v, settled := kasetAlbumVerdictWith(l, "OMVSAME0001", 0, "Jhené Aiko", "I Don't Mind")
	if want := (kasetAlbumVerdict{album: "Westside Whimsy", albumBrowseID: "MPREb_OUh6Wf3kq7x", artistBrowseID: "UCZONOh3FvcD"}); !settled || v != want {
		t.Errorf("专辑来自音轨版本,歌手来自放的这一版: %+v settled=%v", v, settled)
	}

	e := enrichEntry{}
	if !applyKasetAlbumVerdict(&e, v, "en") || e.YouTubeMusicAlbumID != "MPREb_OUh6Wf3kq7x" || e.YouTubeMusicArtistID != "UCZONOh3FvcD" {
		t.Errorf("两个 id 都记: %+v", e)
	}
	if applyKasetAlbumVerdict(&e, v, "en") {
		t.Error("没变不算改动")
	}
	if !applyKasetAlbumVerdict(&e, kasetAlbumVerdict{mv: true}, "en") || e.YouTubeMusicAlbumID != "" || e.YouTubeMusicArtistID != "UCZONOh3FvcD" {
		t.Errorf("判成 MV:专辑页 id 跟着清掉,歌手频道 id 留着: %+v", e)
	}
	if !applyKasetAlbumVerdict(&e, kasetAlbumVerdict{album: "X", albumBrowseID: "../x", artistBrowseID: "UC2"}, "en") ||
		e.YouTubeMusicAlbumID != "" || e.YouTubeMusicArtistID != "UC2" {
		t.Errorf("形状不对的专辑页 id 不记: %+v", e)
	}
}

// Amazon:同一位歌手、同名的两首收在两张专辑里(单曲与专辑版)。专辑、歌手 id 只认 App 报的当前曲目,目录里这一轨的
// 专辑名还要跟这一条的专辑对得上;队列按歌手 + 歌名记的 ASIN 不用。
func TestPlayerCatalogAmazonSameTitleOtherAlbum(t *testing.T) {
	resetPlayerCatalogMemo(t)
	dir := t.TempDir()
	savedLS := amazonLocalStorageOverride
	amazonLocalStorageOverride = dir
	amazonCurrentMu.Lock()
	savedCur := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	amazonQueueMu.Lock()
	savedQueue := amazonQueueASINs
	amazonQueueASINs = map[string]string{}
	amazonQueueMu.Unlock()
	t.Cleanup(func() {
		amazonLocalStorageOverride = savedLS
		amazonCurrentMu.Lock()
		amazonCurrentTrack = savedCur
		amazonCurrentMu.Unlock()
		amazonQueueMu.Lock()
		amazonQueueASINs = savedQueue
		amazonQueueMu.Unlock()
	})
	other := strings.NewReplacer(`"B0TESTAAA2"`, `"B0TESTAAA3"`,
		`"name":"I Can't Love You Anymore","asin":"B0TESTALB1"`, `"name":"Greatest Hits","asin":"B0TESTALB2"`).Replace(amazonTestCatalogValue)
	testWriteLog(t, filepath.Join(dir, "000015.log"), [][]testLDBEntry{{
		{key: amazonCatalogKeyPrefix + "B0TESTAAA2", seq: 5, value: amazonTestCatalogValue},
		{key: amazonCatalogKeyPrefix + "B0TESTAAA3", seq: 6, value: other},
	}})
	const artist, title = "Ella Langley & Morgan Wallen", "I Can't Love You Anymore [Explicit]"

	noteAmazonCurrentTrack(amazonMusicBundleID, artist, title, "asin://B0TESTAAA3")
	if got, want := playerCatalogIDsFor(amazonMusicBundleID, artist, title, "Greatest Hits", 229), (playerCatalogIDs{album: "B0TESTALB2", artist: "B0TESTART1"}); got != want {
		t.Errorf("正在放专辑版,记专辑版的 id: got %+v want %+v", got, want)
	}
	if got := playerCatalogIDsFor(amazonMusicBundleID, artist, title, "I Can't Love You Anymore", 229); got != (playerCatalogIDs{}) {
		t.Errorf("当前曲目是专辑版、这一条是单曲:目录里的专辑名对不上,不记: %+v", got)
	}

	resetPlayerCatalogMemo(t)
	noteAmazonCurrentTrack(amazonMusicBundleID, artist, title, "")
	amazonQueueMu.Lock()
	amazonQueueASINs[amazonTrackIdentity(artist, title)] = "B0TESTAAA2"
	amazonQueueMu.Unlock()
	if got := playerCatalogIDsFor(amazonMusicBundleID, artist, title, "I Can't Love You Anymore", 229); got != (playerCatalogIDs{}) {
		t.Errorf("App 没认出当前曲目时,队列按歌手 + 歌名记的 ASIN 不用: %+v", got)
	}
}
