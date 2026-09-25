package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

const trustedLyricTestBundle = "com.example.lyricplayer"

func resetTrustedLyricArtist(t *testing.T) {
	t.Helper()
	reset := func() {
		trustedLyricArtistMu.Lock()
		trustedLyricArtistValue = trustedLyricArtistState{}
		trustedLyricArtistConfirmed = map[string]trustedRotField{}
		trustedTitleOrders = map[string]trustedTitleOrder{}
		trustedCatalogInflight = map[string]bool{}
		trustedCatalogTried = map[string]bool{}
		trustedSplitResolved = map[string]trustedIdentity{}
		trustedLyricArtistMu.Unlock()
		enrichMu.Lock()
		enrichRetracted = map[string]time.Time{}
		enrichMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

// trustPlayers 把这几个 bundle 放进信任列表,跑完还原。
func trustPlayers(t *testing.T, bundles ...string) {
	t.Helper()
	startup := features()
	t.Cleanup(func() { setFeatures(startup) })
	f := startup
	f.TrustedPlayers = map[string]string{}
	for _, b := range bundles {
		f.TrustedPlayers[b] = "Lyric Player"
	}
	setFeatures(f)
}

// withTrustedEnrichCache 同 withEnrichCache,还原之前先等后台 goroutine(撤回会读写 enrichCache)跑完。
func withTrustedEnrichCache(t *testing.T, m map[string]enrichEntry) {
	t.Helper()
	withEnrichCache(t, m)
	t.Cleanup(trustedBackground.Wait)
}

// stubCatalog 替换曲库核对:按身份字段给出对得上的读法(没登记的返回空),返回调用次数计数器。
func stubCatalog(t *testing.T, reached bool, answers map[string][]trustedSplitCandidate) *int32 {
	t.Helper()
	var calls int32
	saved := trustedCatalogLookup
	t.Cleanup(func() { trustedCatalogLookup = saved })
	trustedCatalogLookup = func(_ context.Context, stable string) ([]trustedSplitCandidate, bool) {
		atomic.AddInt32(&calls, 1)
		return answers[stable], reached
	}
	return &calls
}

// waitUntil 等后台 goroutine(曲库核对 / 撤回)落定。
func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("等不到:%s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func orderLookupSettled() bool {
	trustedLyricArtistMu.Lock()
	defer trustedLyricArtistMu.Unlock()
	return len(trustedCatalogInflight) == 0
}

func keyRetracted(key string) bool {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	return enrichKeyRetractedLocked(key)
}

func readPlayerArtistFixFile(t *testing.T, path string) playerArtistFixState {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var st playerArtistFixState
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatal(err)
	}
	return st
}

// beat 是喂给纯函数的一拍。
type beat struct{ artist, title string }

// feed 按 5 秒一拍把一串读数喂进纯函数,返回最后的状态。
func feed(st trustedLyricArtistState, album string, duration float64, start time.Time, beats ...beat) trustedLyricArtistState {
	for i, b := range beats {
		st = advanceTrustedLyricArtist(st, trustedLyricTestBundle, b.title, b.artist, album, duration, true, rotNone,
			start.Add(time.Duration(i)*5*time.Second))
	}
	return st
}

// ---- 判定 ----

// 歌词在 artist 里、身份在 title 里:窗口内 artist 换第二次就判定成立。
func TestAdvanceTrustedDetectsArtistRotation(t *testing.T) {
	title := "漫步人生路 - 邓丽君"
	st := feed(trustedLyricArtistState{}, "漫步人生路", 212, time.Unix(1000, 0),
		beat{"作曲: 中岛美雪", title}, beat{"作词: 邬裕康", title}, beat{"在你身边路虽远未疲倦", title})
	if !st.poisoned || st.rot != rotArtist {
		t.Fatalf("该判定成 artist 在换: %+v", st)
	}
	if stable, ref := st.stableAndRef(); stable != title || ref != "作曲: 中岛美雪" {
		t.Errorf("stableAndRef = (%q, %q)", stable, ref)
	}
}

// 反过来:歌词在 title 里、身份在 artist 里,同样认得出。
func TestAdvanceTrustedDetectsTitleRotation(t *testing.T) {
	artist := "漫步人生路 - 邓丽君"
	st := feed(trustedLyricArtistState{}, "漫步人生路", 212, time.Unix(1000, 0),
		beat{artist, "作曲: 中岛美雪"}, beat{artist, "作词: 邬裕康"}, beat{artist, "在你身边路虽远未疲倦"})
	if !st.poisoned || st.rot != rotTitle {
		t.Fatalf("该判定成 title 在换: %+v", st)
	}
	if stable, ref := st.stableAndRef(); stable != artist || ref != "作曲: 中岛美雪" {
		t.Errorf("stableAndRef = (%q, %q)", stable, ref)
	}
}

// 只换一次不算,但窗口内先按住;过了窗口放行。
func TestAdvanceTrustedHoldsSingleChangeWithinWindow(t *testing.T) {
	start := time.Unix(1000, 0)
	st := feed(trustedLyricArtistState{}, "专辑", 200, start, beat{"占位名", "歌名"}, beat{"真歌手", "歌名"})
	if st.poisoned {
		t.Fatalf("只换了一次,不该判定: %+v", st)
	}
	if !st.holding(start.Add(10 * time.Second)) {
		t.Error("窗口内该先按住")
	}
	if st.holding(start.Add(5*time.Second + trustedLyricArtistWindow + time.Second)) {
		t.Error("过了窗口还没换第二次,该放行")
	}
}

// 换歌那一拍字段不同步:title 先换、下一拍 artist 也换 —— 是真换歌,重新起判。
func TestAdvanceTrustedTreatsStaggeredChangeAsNewTrack(t *testing.T) {
	start := time.Unix(1000, 0)
	st := feed(trustedLyricArtistState{}, "", 200, start,
		beat{"歌手甲", "第一首"}, beat{"歌手甲", "第二首"}, beat{"歌手乙", "第二首"})
	if st.poisoned || st.refArtist != "歌手乙" || st.refTitle != "第二首" || st.changes != 0 {
		t.Fatalf("两个字段都跟第一次见到的不同了,该当新歌重新起判: %+v", st)
	}
	if !st.startedAt.Equal(start.Add(10 * time.Second)) {
		t.Errorf("startedAt = %v,该是新歌那一拍", st.startedAt)
	}
}

// 两次换值隔得比窗口还远(电台那种几分钟一换的形态)不算。
func TestAdvanceTrustedIgnoresSlowChanges(t *testing.T) {
	start := time.Unix(1000, 0)
	st := trustedLyricArtistState{}
	for i, a := range []string{"歌手甲", "歌手乙", "歌手丙", "歌手丁"} {
		st = advanceTrustedLyricArtist(st, trustedLyricTestBundle, "某某电台", a, "", 3600, true, rotNone,
			start.Add(time.Duration(i)*3*time.Minute))
	}
	if st.poisoned {
		t.Fatalf("每次换值都隔几分钟,不该判定: %+v", st)
	}
}

// 没有时长的不参与(电台常见形态);不在范围内的一律空状态。
func TestAdvanceTrustedSkipsZeroDurationAndIneligible(t *testing.T) {
	st := feed(trustedLyricArtistState{}, "", 0, time.Unix(1000, 0), beat{"甲", "t"}, beat{"乙", "t"}, beat{"丙", "t"})
	if st.bundle != "" {
		t.Errorf("时长为 0 该返回空状态: %+v", st)
	}
	st = trustedLyricArtistState{}
	for i, a := range []string{"甲", "乙", "丙"} {
		st = advanceTrustedLyricArtist(st, trustedLyricTestBundle, "歌名", a, "", 200, false, rotNone,
			time.Unix(1000+int64(i)*5, 0))
	}
	if st.bundle != "" {
		t.Errorf("不在范围内该返回空状态: %+v", st)
	}
}

// 先报一个字段后补另一个、专辑从空补上,都是补全,不算换值也不算换歌。
func TestAdvanceTrustedTreatsBackfillAsBackfill(t *testing.T) {
	start := time.Unix(1000, 0)
	st := advanceTrustedLyricArtist(trustedLyricArtistState{}, trustedLyricTestBundle, "歌名", "", "", 200, true, rotNone, start)
	st = advanceTrustedLyricArtist(st, trustedLyricTestBundle, "歌名", "真歌手", "专辑", 200, true, rotNone, start.Add(5*time.Second))
	if st.changes != 0 || st.refArtist != "真歌手" || st.album != "专辑" || !st.startedAt.Equal(start) {
		t.Fatalf("补全不该算换值或换歌: %+v", st)
	}
	st = advanceTrustedLyricArtist(st, trustedLyricTestBundle, "歌名", "真歌手", "另一张专辑", 200, true, rotNone, start.Add(10*time.Second))
	if !st.startedAt.Equal(start.Add(10 * time.Second)) {
		t.Errorf("专辑从一个值换成另一个值该算换歌: %+v", st)
	}
}

// 时长在小数位上漂不算换歌,否则状态机每拍重置、永远判不出来。
func TestAdvanceTrustedToleratesDurationJitter(t *testing.T) {
	start := time.Unix(1000, 0)
	st := trustedLyricArtistState{}
	for i, b := range []struct {
		artist string
		dur    float64
	}{{"甲", 212.0}, {"乙", 212.3}, {"丙", 211.9}} {
		st = advanceTrustedLyricArtist(st, trustedLyricTestBundle, "歌名", b.artist, "", b.dur, true, rotNone,
			start.Add(time.Duration(i)*5*time.Second))
	}
	if !st.poisoned {
		t.Fatalf("时长抖动在容差内,该判定成立: %+v", st)
	}
}

// 判定过的播放器换歌后第一拍就按已判定起步,记着是哪个字段在换。
func TestAdvanceTrustedStartsPoisonedOnceConfirmed(t *testing.T) {
	prev := trustedLyricArtistState{bundle: trustedLyricTestBundle, refTitle: "上一首", duration: 200, poisoned: true}
	st := advanceTrustedLyricArtist(prev, trustedLyricTestBundle, "第一句歌词", "邓丽君 - 甜蜜蜜", "", 180, true, rotTitle, time.Unix(1000, 0))
	if !st.poisoned || st.rot != rotTitle {
		t.Fatalf("已判定的播放器换歌该直接成立: %+v", st)
	}
}

// ---- 拆分 ----

// 排列已知时:歌名在前取最后一个分隔符,歌手在前取第一个;几种分隔符都认。
func TestSplitTrustedByOrder(t *testing.T) {
	cases := []struct {
		s            string
		order        trustedTitleOrder
		song, artist string
	}{
		{"漫步人生路 - 邓丽君", titleOrderSongFirst, "漫步人生路", "邓丽君"},
		{"邓丽君 - 漫步人生路", titleOrderArtistFirst, "漫步人生路", "邓丽君"},
		// 歌名自带破折号(本机缓存里真实存在的形态)。
		{"魚仔 - 電視劇<花甲男孩轉大人>主題曲 - 盧廣仲", titleOrderSongFirst, "魚仔 - 電視劇<花甲男孩轉大人>主題曲", "盧廣仲"},
		{"盧廣仲 - 魚仔 - 電視劇<花甲男孩轉大人>主題曲", titleOrderArtistFirst, "魚仔 - 電視劇<花甲男孩轉大人>主題曲", "盧廣仲"},
		{"漫步人生路 – 邓丽君", titleOrderSongFirst, "漫步人生路", "邓丽君"},
		{"漫步人生路 — 邓丽君", titleOrderSongFirst, "漫步人生路", "邓丽君"},
		{"漫步人生路 － 邓丽君", titleOrderSongFirst, "漫步人生路", "邓丽君"},
	}
	for _, c := range cases {
		song, artist, ok := splitTrustedByOrder(c.s, c.order)
		if !ok || song != c.song || artist != c.artist {
			t.Errorf("splitTrustedByOrder(%q, %v) = (%q, %q, %v), want (%q, %q)", c.s, c.order, song, artist, ok, c.song, c.artist)
		}
	}
	for _, s := range []string{"漫步人生路", "Jay-Z", "Talking-The Power Of Soul"} {
		if _, _, ok := splitTrustedByOrder(s, titleOrderSongFirst); ok {
			t.Errorf("%q 没有带空格的分隔符,不该拆", s)
		}
	}
}

// 第一拍在换的那个字段恰好是某种读法里的歌手 —— 排列就认出来了;是歌词时认不出。
func TestTrustedOrderFromRotRef(t *testing.T) {
	orderOf := func(stable, ref string) (trustedTitleOrder, bool) {
		return trustedOrderOf(trustedMatchRotRef(trustedSplitCandidates(stable), ref))
	}
	if o, ok := orderOf("漫步人生路 - 邓丽君", "邓丽君"); !ok || o != titleOrderSongFirst {
		t.Errorf("= (%v, %v),该认成歌名在前", o, ok)
	}
	if o, ok := orderOf("鄧麗君 - 漫步人生路", "邓丽君"); !ok || o != titleOrderArtistFirst {
		t.Errorf("= (%v, %v),繁简不同也该认成歌手在前", o, ok)
	}
	if _, ok := orderOf("漫步人生路 - 邓丽君", "作曲: 中岛美雪"); ok {
		t.Error("第一拍是制作信息行,认不出排列")
	}
}

// 曲库结果认排列:同名专辑那种字段上对称的情形也分得出;两种都对得上时不猜。
func TestTrustedOrderFromCatalogResults(t *testing.T) {
	results := []itunesResult{
		{TrackName: "漫步人生路", ArtistName: "鄧麗君"},
		{TrackName: "Tim McGraw", ArtistName: "Taylor Swift"},
	}
	orderOf := func(stable string, rs []itunesResult) (trustedTitleOrder, bool) {
		return trustedOrderOf(trustedMatchesFromResults(stable, rs))
	}
	if o, ok := orderOf("漫步人生路 - 邓丽君", results); !ok || o != titleOrderSongFirst {
		t.Errorf("= (%v, %v),该认成歌名在前", o, ok)
	}
	if o, ok := orderOf("Taylor Swift - Tim McGraw", results); !ok || o != titleOrderArtistFirst {
		t.Errorf("= (%v, %v),同名专辑那首也该按曲库认成歌手在前", o, ok)
	}
	both := append(results, itunesResult{TrackName: "邓丽君", ArtistName: "漫步人生路"})
	if _, ok := orderOf("漫步人生路 - 邓丽君", both); ok {
		t.Error("两种读法曲库里都有,不该猜")
	}
	if _, ok := orderOf("没收录的歌 - 没收录的人", results); ok {
		t.Error("曲库里没有,认不出")
	}
}

// 拆法不唯一时,曲库结果定位置:歌手名自带破折号、歌名自带破折号两种都分得出。
func TestTrustedSplitFromCatalogResults(t *testing.T) {
	pick := func(stable string, rs []itunesResult) (trustedSplitCandidate, bool) {
		return trustedUniqueWithOrder(trustedMatchesFromResults(stable, rs), titleOrderSongFirst)
	}
	c, ok := pick("Song - A - B", []itunesResult{{TrackName: "Song", ArtistName: "A - B"}})
	if !ok || c.song != "Song" || c.artist != "A - B" {
		t.Errorf("歌手名自带破折号: (%+v, %v)", c, ok)
	}
	c, ok = pick("魚仔 - 電視劇<花甲男孩轉大人>主題曲 - 盧廣仲",
		[]itunesResult{{TrackName: "魚仔 - 電視劇<花甲男孩轉大人>主題曲", ArtistName: "盧廣仲"}})
	if !ok || c.artist != "盧廣仲" {
		t.Errorf("歌名自带破折号: (%+v, %v)", c, ok)
	}
	if _, ok := pick("Song - A - B", []itunesResult{{TrackName: "Song", ArtistName: "A - B"}, {TrackName: "Song - A", ArtistName: "B"}}); ok {
		t.Error("两处拆法曲库里都有,不该定")
	}
}

// ---- 端到端 ----

// 歌词在 artist 里:判定期间按住、判定成立后先固定身份并去曲库认排列,认出来就拆出真身份、
// 发给 App,并撤回第一拍那个身份留下的条目;之后换歌第一拍就直接拆。
func TestTrustedFixedTrackArtistRotationEndToEnd(t *testing.T) {
	resetTrustedLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle)
	title, album := "漫步人生路 - 邓丽君", "漫步人生路"
	calls := stubCatalog(t, true, map[string][]trustedSplitCandidate{
		title: {{song: "漫步人生路", artist: "邓丽君", order: titleOrderSongFirst}},
	})
	path := filepath.Join(t.TempDir(), "fix.json")
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	refKey := enrichKey("作曲: 中岛美雪", title, album)
	withTrustedEnrichCache(t, map[string]enrichEntry{refKey: {TS: time.Now().Unix()}})

	if _, _, ok := trustedFixedTrack(trustedLyricTestBundle, title, "作曲: 中岛美雪", album, 212); ok {
		t.Fatal("第一拍什么都还不知道,不该改")
	}
	if a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, title, "作词: 邬裕康", album, 212); !ok || a != "作曲: 中岛美雪" || tt != title {
		t.Fatalf("第一次换值该按住在第一次见到的身份: (%q, %q, %v)", a, tt, ok)
	}
	if a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, title, "在你身边路虽远未疲倦", album, 212); !ok || a != "作曲: 中岛美雪" || tt != title {
		t.Fatalf("判定成立、排列还没认出来时,身份该固定在第一次见到的那个: (%q, %q, %v)", a, tt, ok)
	}
	waitUntil(t, "曲库核对落定", orderLookupSettled)
	if atomic.LoadInt32(calls) != 1 {
		t.Errorf("曲库核对 %d 次,该是 1 次", atomic.LoadInt32(calls))
	}
	if a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, title, "伴你漫步一段又一段", album, 212); !ok || a != "邓丽君" || tt != "漫步人生路" {
		t.Fatalf("排列认出来后该拆成 邓丽君 / 漫步人生路: (%q, %q, %v)", a, tt, ok)
	}
	waitUntil(t, "第一拍的身份被撤回", func() bool { return keyRetracted(refKey) })
	enrichMu.Lock()
	_, still := enrichCache[refKey]
	enrichMu.Unlock()
	if still {
		t.Error("第一拍那个身份这首歌里写下的条目该被删掉")
	}
	st := readPlayerArtistFixFile(t, path)
	if st.Bundle != trustedLyricTestBundle || st.Title != title || st.Artist != "邓丽君" ||
		st.FixedTitle != "漫步人生路" || st.StableField != "" || st.Order != "songFirst" || !st.Unreliable {
		t.Errorf("App 侧没收到同一个身份: %+v", st)
	}
	if a, tt, ok := trustedKnownFix(trustedLyricTestBundle, "随便一句歌词", title); !ok || a != "邓丽君" || tt != "漫步人生路" {
		t.Errorf("封面核对该拿到同一个身份: (%q, %q, %v)", a, tt, ok)
	}

	// 换歌:已判定、排列已知,第一拍就拆,不再问曲库。
	if a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, "伤心太平洋 - 任贤齐", "第一句歌词", "爱像太平洋", 290); !ok || a != "任贤齐" || tt != "伤心太平洋" {
		t.Errorf("换歌后第一拍 = (%q, %q, %v),该直接拆", a, tt, ok)
	}
	if atomic.LoadInt32(calls) != 1 {
		t.Errorf("排列已知后不该再问曲库,实际 %d 次", atomic.LoadInt32(calls))
	}
}

// 歌词在 title 里:适用范围按原样的 artist 发给 App,title 留空。
func TestTrustedFixedTrackTitleRotationEndToEnd(t *testing.T) {
	resetTrustedLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle)
	artist, album := "邓丽君 - 漫步人生路", "漫步人生路"
	stubCatalog(t, true, map[string][]trustedSplitCandidate{
		artist: {{song: "漫步人生路", artist: "邓丽君", order: titleOrderArtistFirst}},
	})
	withTrustedEnrichCache(t, nil)
	path := filepath.Join(t.TempDir(), "fix.json")
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	for _, line := range []string{"作曲: 中岛美雪", "作词: 邬裕康", "在你身边路虽远未疲倦"} {
		trustedFixedTrack(trustedLyricTestBundle, line, artist, album, 212)
	}
	waitUntil(t, "曲库核对落定", orderLookupSettled)
	a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, "伴你漫步一段又一段", artist, album, 212)
	if !ok || a != "邓丽君" || tt != "漫步人生路" {
		t.Fatalf("= (%q, %q, %v),该拆成 邓丽君 / 漫步人生路", a, tt, ok)
	}
	st := readPlayerArtistFixFile(t, path)
	if st.StableField != "artist" || st.RawArtist != artist || st.Title != "" ||
		st.Artist != "邓丽君" || st.FixedTitle != "漫步人生路" || st.Order != "artistFirst" {
		t.Errorf("歌词在 title 里时适用范围该按原样的 artist: %+v", st)
	}
	if a, tt, ok := trustedKnownFix(trustedLyricTestBundle, artist, "另一句歌词"); !ok || a != "邓丽君" || tt != "漫步人生路" {
		t.Errorf("封面核对按原样的 artist 对齐: (%q, %q, %v)", a, tt, ok)
	}
}

// 认不出排列时一首歌只问一次曲库(问到了没结论、没问成都一样),换下一首再问。
func TestTrustedFixedTrackOrderLookupRetryPolicy(t *testing.T) {
	resetTrustedLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle)
	withTrustedEnrichCache(t, nil)
	calls := stubCatalog(t, false, nil)

	title := "没收录的歌 - 没收录的人"
	for _, line := range []string{"第一句", "第二句", "第三句", "第四句", "第五句"} {
		a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, title, line, "专辑", 200)
		if line != "第一句" && (!ok || a != "第一句" || tt != title) {
			t.Fatalf("认不出排列时身份该固定在第一次见到的那个: (%q, %q, %v)", a, tt, ok)
		}
		waitUntil(t, "曲库核对落定", orderLookupSettled)
	}
	if n := atomic.LoadInt32(calls); n != 1 {
		t.Errorf("同一首只该问 1 次,实际 %d", n)
	}
	trustedFixedTrack(trustedLyricTestBundle, "另一首 - 另一个人", "第一句", "专辑二", 180)
	waitUntil(t, "曲库核对落定", orderLookupSettled)
	if n := atomic.LoadInt32(calls); n != 2 {
		t.Errorf("换了一首该再问一次,实际共 %d 次", n)
	}
}

// 内置播放器(行为都实测过)与没信任的播放器都不归这套管。
func TestTrustedFixedTrackLeavesOtherPlayersAlone(t *testing.T) {
	resetTrustedLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle, kugouMusicBundleID)
	stubCatalog(t, true, nil)
	for _, bundle := range []string{kugouMusicBundleID, "com.tencent.QQMusicMac", "com.example.untrusted"} {
		for _, a := range []string{"甲", "乙", "丙", "丁"} {
			if ga, gt, ok := trustedFixedTrack(bundle, "歌名 - 歌手", a, "歌名", 200); ok {
				t.Fatalf("%s 不该被这套纠正: (%q, %q)", bundle, ga, gt)
			}
		}
	}
}

// 重启后恢复文件里记着的播放器级结论(哪个字段在换、排列):新一首第一拍就拆并发布。
func TestSetPlayerArtistFixPathRestoresTrustedVerdict(t *testing.T) {
	resetTrustedLyricArtist(t)
	resetKugouLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle)
	calls := stubCatalog(t, true, nil)
	withTrustedEnrichCache(t, nil)
	path := filepath.Join(t.TempDir(), "fix.json")
	body := `{"bundle":"` + trustedLyricTestBundle + `","title":"旧曲","artist":"旧","unreliable":true,"stableField":"artist","order":"artistFirst"}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	kept := readPlayerArtistFixFile(t, path)
	if kept.Title != "" || kept.Artist != "" || kept.StableField != "artist" || kept.Order != "artistFirst" || !kept.Unreliable {
		t.Errorf("重启只该留下播放器级字段: %+v", kept)
	}
	kugouLyricArtistMu.Lock()
	kugouConfirmed := kugouArtistPoisonConfirmed
	kugouLyricArtistMu.Unlock()
	if kugouConfirmed {
		t.Error("别的播放器的结论不该恢复成酷狗的判定")
	}
	a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, "第一句歌词", "陈慧琳 - 记事本", "记事本", 263)
	if !ok || a != "陈慧琳" || tt != "记事本" {
		t.Fatalf("= (%q, %q, %v),恢复了结论的播放器第一拍就该拆", a, tt, ok)
	}
	if atomic.LoadInt32(calls) != 0 {
		t.Error("排列已恢复,不该再问曲库")
	}
	if st := readPlayerArtistFixFile(t, path); st.RawArtist != "陈慧琳 - 记事本" || st.Artist != "陈慧琳" || st.FixedTitle != "记事本" {
		t.Errorf("没发布这一首的纠正: %+v", st)
	}
}

// 第一拍报的还是真署名(歌词要等第一句唱出来才顶上去):直接从它认出排列,不必问曲库。
func TestTrustedFixedTrackLearnsOrderFromFirstBeat(t *testing.T) {
	resetTrustedLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle)
	calls := stubCatalog(t, true, nil)
	withTrustedEnrichCache(t, nil)

	title, album := "漫步人生路 - 邓丽君", "漫步人生路"
	var a, tt string
	var ok bool
	for _, artist := range []string{"邓丽君", "在你身边路虽远未疲倦", "伴你漫步一段又一段"} {
		a, tt, ok = trustedFixedTrack(trustedLyricTestBundle, title, artist, album, 212)
	}
	if !ok || a != "邓丽君" || tt != "漫步人生路" {
		t.Fatalf("= (%q, %q, %v),该靠第一拍的真署名认出歌名在前", a, tt, ok)
	}
	waitUntil(t, "曲库核对落定", orderLookupSettled)
	if n := atomic.LoadInt32(calls); n != 0 {
		t.Errorf("第一拍已经给出排列,不该再问曲库,实际 %d 次", n)
	}
}

// 拆法不唯一(歌手名自带破折号):先按取段规则拆,同时逐首问曲库;曲库定下来跟先拆的不同,
// 下一拍换过去,先拆的那个身份撤回。
func TestTrustedFixedTrackResolvesAmbiguousSplitViaCatalog(t *testing.T) {
	resetTrustedLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle)
	title, album := "Song - A - B", "Album"
	calls := stubCatalog(t, true, map[string][]trustedSplitCandidate{
		title: {{song: "Song", artist: "A - B", order: titleOrderSongFirst}},
	})
	withTrustedEnrichCache(t, nil)
	restoreTrustedLyricArtistConfirmed(trustedLyricTestBundle, "", "songFirst")

	a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, title, "first line", album, 200)
	if !ok || a != "B" || tt != "Song - A" {
		t.Fatalf("曲库回来之前按取段规则先拆: (%q, %q, %v)", a, tt, ok)
	}
	waitUntil(t, "曲库核对落定", orderLookupSettled)
	a, tt, ok = trustedFixedTrack(trustedLyricTestBundle, title, "second line", album, 200)
	if !ok || a != "A - B" || tt != "Song" {
		t.Fatalf("曲库定下来后该换成 A - B / Song: (%q, %q, %v)", a, tt, ok)
	}
	waitUntil(t, "先拆的身份被撤回", func() bool { return keyRetracted(enrichKey("B", "Song - A", album)) })
	trustedFixedTrack(trustedLyricTestBundle, title, "third line", album, 200)
	if n := atomic.LoadInt32(calls); n != 1 {
		t.Errorf("同一首只该问 1 次曲库,实际 %d", n)
	}
}

// 拆法不唯一、但第一拍报的是真署名:直接用它定位置,不问曲库。
func TestTrustedFixedTrackResolvesAmbiguousSplitViaFirstBeat(t *testing.T) {
	resetTrustedLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle)
	calls := stubCatalog(t, true, nil)
	withTrustedEnrichCache(t, nil)
	restoreTrustedLyricArtistConfirmed(trustedLyricTestBundle, "", "songFirst")

	a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, "Song - A - B", "A - B", "Album", 200)
	if !ok || a != "A - B" || tt != "Song" {
		t.Fatalf("第一拍的真署名该直接定位置: (%q, %q, %v)", a, tt, ok)
	}
	waitUntil(t, "曲库核对落定", orderLookupSettled)
	if n := atomic.LoadInt32(calls); n != 0 {
		t.Errorf("第一拍已经定了,不该问曲库,实际 %d 次", n)
	}
}

// 只有一种拆法时不问曲库(不给每首歌加一次网络请求)。
func TestTrustedFixedTrackSkipsCatalogForUniqueSplit(t *testing.T) {
	resetTrustedLyricArtist(t)
	trustPlayers(t, trustedLyricTestBundle)
	calls := stubCatalog(t, true, nil)
	withTrustedEnrichCache(t, nil)
	restoreTrustedLyricArtistConfirmed(trustedLyricTestBundle, "", "songFirst")
	if a, tt, ok := trustedFixedTrack(trustedLyricTestBundle, "记事本 - 陈慧琳", "第一句", "记事本", 263); !ok || a != "陈慧琳" || tt != "记事本" {
		t.Fatalf("= (%q, %q, %v)", a, tt, ok)
	}
	waitUntil(t, "曲库核对落定", orderLookupSettled)
	if n := atomic.LoadInt32(calls); n != 0 {
		t.Errorf("只有一种拆法不该问曲库,实际 %d 次", n)
	}
}
