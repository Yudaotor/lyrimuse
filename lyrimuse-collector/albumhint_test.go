package main

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// 用户那首的真实形状(2026-09-08 iTunes Search 实测):YT Music MV「王子 - Why You Wanna Treat Me So Bad?」230.1s、
// album 空;US 商店回 Prince「Prince」「The Hits/The B-Sides」(曲目级 releaseDate 都是 1979-10-19,只有专辑级日期
// 分得开)、Tuesday Knight 的翻唱、几条时长差很多的翻唱;CN 商店对一切查询回空。
func princeResults() []itunesResult {
	const title = "Why You Wanna Treat Me So Bad?"
	return []itunesResult{
		{TrackName: title, ArtistName: "Prince", CollectionName: "The Hits/The B-Sides", CollectionID: 212972881, TrackTimeMillis: 231000, ReleaseDate: "1979-10-19T07:00:00Z"},
		{TrackName: title, ArtistName: "Prince", CollectionName: "Prince", CollectionID: 1544298981, TrackTimeMillis: 231000, ReleaseDate: "1979-10-19T07:00:00Z"},
		{TrackName: title, ArtistName: "Tuesday Knight", CollectionName: "Tuesday Knight", CollectionID: 1124764563, TrackTimeMillis: 245000, ReleaseDate: "1987-01-01T08:00:00Z"},
		{TrackName: title, ArtistName: "Blakeleeluv", CollectionName: "Covers", CollectionID: 1536542433, TrackTimeMillis: 187300, ReleaseDate: "2020-10-17T07:00:00Z"},
		{TrackName: title, ArtistName: "Tuesday Knight", CollectionName: "Tuesday Knight (2018 Remaster)", CollectionID: 1778733373, TrackTimeMillis: 233400, ReleaseDate: "1987-05-27T07:00:00Z"},
		{TrackName: title + " (Live)", ArtistName: "Prince", CollectionName: "One Nite Alone... Live!", TrackTimeMillis: 300000},
		// US 商店那份重复一遍(两个商店合并):去重要认出来。
		{TrackName: title, ArtistName: "Prince", CollectionName: "Prince", CollectionID: 1544298981, TrackTimeMillis: 231000, ReleaseDate: "1979-10-19T07:00:00Z"},
	}
}

func TestAlbumHintCandidatesFromResults(t *testing.T) {
	cands := albumHintCandidatesFromResults(princeResults(), "Why You Wanna Treat Me So Bad?", 230.121)
	var got []string
	for _, c := range cands {
		got = append(got, c.Artist+"/"+c.Album)
	}
	want := []string{"Prince/The Hits/The B-Sides", "Prince/Prince", "Tuesday Knight/Tuesday Knight (2018 Remaster)"}
	if len(got) != len(want) {
		t.Fatalf("候选过滤:want %v, got %v", want, got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("候选过滤第 %d 条:want %q, got %q", i, want[i], got[i])
		}
	}
	// 时长 245s(Δ14.9)/187s/300s(Live,曲名也不同)被容差挡掉;重复的「Prince」只留一份;Order 按出现顺序。
	if cands[1].Order != 1 || cands[1].CollectionID != 1544298981 {
		t.Fatalf("候选 Order / CollectionID 没带对:%+v", cands[1])
	}
	if albumHintCandidatesFromResults(princeResults(), "Why You Wanna Treat Me So Bad?", 40) != nil {
		t.Fatalf("短于 75s 不取候选")
	}
	if albumHintCandidatesFromResults(princeResults(), "", 230) != nil {
		t.Fatalf("没曲名不取候选")
	}
}

// TestPickAppleAlbumHint:挑选规则。专辑级发行日期是从 lookup 补上的(实测「Prince」1979-10-19,
// 「The Hits/The B-Sides」1993-09-13,「Tuesday Knight (2018 Remaster)」1987-05-27)。
func TestPickAppleAlbumHint(t *testing.T) {
	cands := albumHintCandidatesFromResults(princeResults(), "Why You Wanna Treat Me So Bad?", 230.121)
	releases := map[int64]string{212972881: "1993-09-13T07:00:00Z", 1544298981: "1979-10-19T07:00:00Z", 1778733373: "1987-05-27T07:00:00Z"}
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}
	// 用户那首:本地署名「王子」跟谁都不相等,只有歌词链路核实过的「Prince」能当旁证 → 「Prince」(专辑级最早、非精选)。
	if got := pickAppleAlbumHint(cands, "王子", []string{"Prince"}); got != "Prince" {
		t.Fatalf("旁证 Prince:want Prince, got %q", got)
	}
	// 旁证还没到(歌词还在解析)→ 不猜,先空着;下一拍再挑。
	if got := pickAppleAlbumHint(cands, "王子", nil); got != "" {
		t.Fatalf("没有旁证不采跨文字系统的候选, got %q", got)
	}
	// 旁证是别人(翻唱者)→ 就认那个人的专辑,不会错配到 Prince。
	if got := pickAppleAlbumHint(cands, "王子", []string{"Tuesday Knight"}); got != "Tuesday Knight (2018 Remaster)" {
		t.Fatalf("旁证 Tuesday Knight:got %q", got)
	}
	// 署名本身对得上(0 档)不需要旁证。
	if got := pickAppleAlbumHint(cands, "Prince", nil); got != "Prince" {
		t.Fatalf("署名相等:want Prince, got %q", got)
	}
	// 0 档永远排在 1 档前面:本地署名是 Tuesday Knight、旁证却说 Prince → 仍取 Tuesday Knight 自己的专辑。
	if got := pickAppleAlbumHint(cands, "Tuesday Knight", []string{"Prince"}); got != "Tuesday Knight (2018 Remaster)" {
		t.Fatalf("0 档优先于 1 档:got %q", got)
	}
	// 没有专辑级日期时退回曲目级日期(两张 Prince 专辑都是 1979-10-19 → 平手 → Apple 顺序,精选在前)。
	noAlbumDates := albumHintCandidatesFromResults(princeResults(), "Why You Wanna Treat Me So Bad?", 230.121)
	if got := pickAppleAlbumHint(noAlbumDates, "Prince", nil); got != "The Hits/The B-Sides" {
		t.Fatalf("无专辑级日期时按曲目级日期再按顺序:got %q", got)
	}
}

func TestPickAppleAlbumHintRanking(t *testing.T) {
	// Seal《Kiss from a Rose》实测形状:原专辑「Seal II」(1994-05-31)、同专辑豪华版「Seal (Deluxe Edition)」
	// (1994-05-23,比原版还早一周)、精选「Seal: Best 1991-2004」(2004)、「Seal: Hits」(2009)。
	seal := []albumHintCandidate{
		{Artist: "Seal", Album: "Seal: Best 1991-2004 (Deluxe Version)", AlbumRelease: "2004-11-08T08:00:00Z", Order: 0},
		{Artist: "Seal", Album: "Seal (Deluxe Edition)", AlbumRelease: "1994-05-23T07:00:00Z", Order: 1},
		{Artist: "Seal", Album: "Seal II", AlbumRelease: "1994-05-31T07:00:00Z", Order: 2},
		{Artist: "Seal", Album: "Seal: Hits", AlbumRelease: "2009-11-30T08:00:00Z", Order: 3},
	}
	if got := pickAppleAlbumHint(seal, "Seal", nil); got != "Seal II" {
		t.Fatalf("豪华版减分、精选靠日期排后:want Seal II, got %q", got)
	}
	// 群星合辑(专辑署名是 Various Artists)排在本人专辑之后,哪怕发行更早;只有合辑时也照样给。
	comp := []albumHintCandidate{
		{Artist: "Seal", CollectionArtist: "Various Artists", Album: "Batman Forever (Soundtrack)", AlbumRelease: "1995-06-06T07:00:00Z", Order: 0},
		{Artist: "Seal", Album: "Seal II", AlbumRelease: "1996-01-01T08:00:00Z", Order: 1},
	}
	if got := pickAppleAlbumHint(comp, "Seal", nil); got != "Seal II" {
		t.Fatalf("群星合辑排后:want Seal II, got %q", got)
	}
	if got := pickAppleAlbumHint(comp[:1], "Seal", nil); got != "Batman Forever (Soundtrack)" {
		t.Fatalf("只有合辑时照样给, got %q", got)
	}
	// 单曲排在专辑之后,哪怕发行更早。
	single := []albumHintCandidate{
		{Artist: "Prince", Album: "Why You Wanna Treat Me So Bad? - Single", AlbumRelease: "1979-01-01T08:00:00Z", Order: 0},
		{Artist: "Prince", Album: "The Hits/The B-Sides", AlbumRelease: "1993-09-13T07:00:00Z", Order: 1},
	}
	if got := pickAppleAlbumHint(single, "Prince", nil); got != "The Hits/The B-Sides" {
		t.Fatalf("单曲排后:want The Hits/The B-Sides, got %q", got)
	}
	// 缺日期的排在有日期的后面。
	noDate := []albumHintCandidate{
		{Artist: "X", Album: "Later", Order: 0},
		{Artist: "X", Album: "Dated", AlbumRelease: "2001-01-01T00:00:00Z", Order: 1},
	}
	if got := pickAppleAlbumHint(noDate, "X", nil); got != "Dated" {
		t.Fatalf("缺日期排后:want Dated, got %q", got)
	}
	// credit 子集:本地只报主唱,Apple 记「Prince & The Revolution」;顺序不同也算;繁简折叠(周杰伦 ↔ 周杰倫)也算 0 档。
	credit := []albumHintCandidate{{Artist: "Prince & The Revolution", Album: "Around the World in a Day", AlbumRelease: "1985-04-22T07:00:00Z"}}
	if got := pickAppleAlbumHint(credit, "Prince", nil); got != "Around the World in a Day" {
		t.Fatalf("credit 子集:got %q", got)
	}
	if got := pickAppleAlbumHint(credit, "The Revolution & Prince", nil); got != "Around the World in a Day" {
		t.Fatalf("credit 顺序不同:got %q", got)
	}
	if got := pickAppleAlbumHint([]albumHintCandidate{{Artist: "周杰倫", Album: "七里香", AlbumRelease: "2004-08-03T00:00:00Z"}}, "周杰伦", nil); got != "七里香" {
		t.Fatalf("繁简折叠算 0 档:got %q", got)
	}
	// 周杰伦《七里香》在 US 商店的真实形状:只有别人的同名歌和一张拉丁名艺人的钢琴翻唱专辑 —— 都不是他、也没有旁证 → 空。
	// 这条正是不再"跨文字系统就认"的理由:裸按文字系统判,会把「Jay - Piano Cover (Piano Version)」安到周杰伦头上。
	jay := []albumHintCandidate{
		{Artist: "阿紫", Album: "船歌", AlbumRelease: "2005-06-01T07:00:00Z", Order: 0},
		{Artist: "Choiyl", Album: "Jay - Piano Cover (Piano Version)", AlbumRelease: "2024-04-05T07:00:00Z", Order: 1},
	}
	if got := pickAppleAlbumHint(jay, "周杰伦", []string{"周杰伦"}); got != "" {
		t.Fatalf("同名翻唱 / 钢琴版不采:got %q", got)
	}
}

func TestAppleAlbumHintHelpers(t *testing.T) {
	if got := appleAlbumHintKey(" 王子 ", "Why You Wanna Treat Me So Bad?", 230.121); got != "王子|Why You Wanna Treat Me So Bad?|230" {
		t.Fatalf("key 形状(原样署名|曲名|整秒时长):got %q", got)
	}
	for _, c := range []struct {
		artist, title string
		dur           float64
		want          bool
	}{
		{"王子", "Why You Wanna Treat Me So Bad?", 230, true},
		{"", "Why You Wanna Treat Me So Bad?", 230, false},
		{"王子", "", 230, false},
		{"王子", "Intro", 40, false},
		{"王子", "Why You Wanna Treat Me So Bad?", 0, false},
	} {
		if got := appleAlbumHintEligible(c.artist, c.title, c.dur); got != c.want {
			t.Fatalf("eligible(%q,%q,%.0f) = %v, want %v", c.artist, c.title, c.dur, got, c.want)
		}
	}
	for _, c := range []struct {
		album string
		want  bool
	}{
		{"Why You Wanna Treat Me So Bad? - Single", true}, {"Something - EP", true}, {"Prince", false}, {"Single Ladies", false},
	} {
		if got := albumHintIsSingleOrEP(c.album); got != c.want {
			t.Fatalf("isSingleOrEP(%q) = %v, want %v", c.album, got, c.want)
		}
	}
	for _, c := range []struct {
		album string
		want  bool
	}{
		{"Seal (Deluxe Edition)", true}, {"Tuesday Knight (2018 Remaster)", true}, {"七里香 (豪华版)", true}, {"Seal II", false}, {"Prince", false},
	} {
		if got := albumHintHasEditionQualifier(c.album); got != c.want {
			t.Fatalf("editionQualifier(%q) = %v, want %v", c.album, got, c.want)
		}
	}
	// 上送用的专辑名:报了就原样,没报才用回填;两者都空就是空。
	if got := (snapshot{Album: "Prince", AlbumHint: "X"}).albumForUpload(); got != "Prince" {
		t.Fatalf("Album 非空时原样:got %q", got)
	}
	if got := (snapshot{AlbumHint: "Prince"}).albumForUpload(); got != "Prince" {
		t.Fatalf("Album 空时用回填:got %q", got)
	}
	if got := (snapshot{}).albumForUpload(); got != "" {
		t.Fatalf("都空则空:got %q", got)
	}
	// relay 去重 key 的 `|a` 标记只在"回填补上了空缺"时出现。
	if relayAlbumHintSuffix(snapshot{AlbumHint: "Prince"}) != "|a" ||
		relayAlbumHintSuffix(snapshot{Album: "Prince", AlbumHint: "Prince"}) != "" ||
		relayAlbumHintSuffix(snapshot{}) != "" {
		t.Fatalf("relayAlbumHintSuffix 标记规则不对")
	}
	// 缓存里已有候选时当场挑、不发请求;旁证晚到也能在下一次调用时挑出来(Path 为空 → 只用内存,永不落盘)。
	appleAlbumHintMu.Lock()
	appleAlbumHintPath = ""
	key := appleAlbumHintKey("王子", "Why You Wanna Treat Me So Bad?", 230.121)
	appleAlbumHintCache[key] = []albumHintCandidate{
		{Artist: "Prince", Album: "Prince", AlbumRelease: "1979-10-19T07:00:00Z"},
		{Artist: "Tuesday Knight", Album: "Tuesday Knight", AlbumRelease: "1987-01-01T00:00:00Z", Order: 1},
	}
	delete(appleAlbumHintLogged, key)
	appleAlbumHintMu.Unlock()
	if got := appleAlbumHint(context.Background(), "王子", "Why You Wanna Treat Me So Bad?", 230.121, nil); got != "" {
		t.Fatalf("旁证未到:want 空, got %q", got)
	}
	if got := appleAlbumHint(context.Background(), "王子", "Why You Wanna Treat Me So Bad?", 230.121, []string{"Prince"}); got != "Prince" {
		t.Fatalf("旁证到了:want Prince, got %q", got)
	}
	if got := appleAlbumHint(context.Background(), "", "x", 230, nil); got != "" {
		t.Fatalf("不合格的请求不问也不返回:got %q", got)
	}
}

// ---- 2026-09-08 晚:封面解析按回填专辑名打分(03 章决策 16) ----

func TestCoverNeedsHintCheck(t *testing.T) {
	apple := enrichEntry{CoverURL: "https://is1-ssl.mzstatic.com/x.jpg", CoverSource: "apple", CoverAlbum: "The Hits/The B-Sides"}
	cases := []struct {
		name        string
		e           enrichEntry
		album, hint string
		want        bool
	}{
		{"王子那首:合集封面 vs 回填原版", apple, "", "Prince", true},
		{"播放器报了专辑就不归这条管", apple, "Prince", "Prince", false},
		{"没有回填名", apple, "", "", false},
		{"回填名跟现有封面同一张专辑", enrichEntry{CoverURL: "u", CoverSource: "netease", CoverAlbum: "Prince"}, "", "Prince", false},
		{"写法差异(宽松包含 100 分)不复查", enrichEntry{CoverURL: "u", CoverSource: "netease", CoverAlbum: "1999 (2019 Remaster)"}, "", "1999", false},
		{"qq 从不报专辑名,判不了", enrichEntry{CoverURL: "u", CoverSource: "qq"}, "", "Prince", false},
		{"device 身份不靠文字", enrichEntry{CoverURL: "u", CoverSource: "device", CoverAlbum: "Something Else"}, "", "Prince", false},
		{"没有封面", enrichEntry{CoverSource: "apple", CoverAlbum: "Something Else"}, "", "Prince", false},
	}
	for _, c := range cases {
		if got := coverNeedsHintCheck(c.e, c.album, c.hint); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

// seedPrinceHintCache 把王子那首首次解析之后的形状摆进内存:回填候选(含专辑级日期)+ 缓存条目里 kugou 胜出候选报「Prince」。
func seedPrinceHintCache(t *testing.T) (key string, restore func()) {
	t.Helper()
	const title = "Why You Wanna Treat Me So Bad?"
	cands := albumHintCandidatesFromResults(princeResults(), title, 230.121)
	releases := map[int64]string{212972881: "1993-09-13T07:00:00Z", 1544298981: "1979-10-19T07:00:00Z", 1778733373: "1987-05-27T07:00:00Z"}
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}
	savedCache, savedHint, savedMisses, savedInflight, savedLogged :=
		enrichCache, appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintLogged
	key = appleAlbumHintKey("王子", title, 230.121)
	appleAlbumHintCache = map[string][]albumHintCandidate{key: cands}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{}
	appleAlbumHintLogged = map[string]string{}
	enrichCache = map[string]enrichEntry{
		"王子|" + title + "|": {LyricsDecisionApplied: &lyricsDecision{Winner: "kugou",
			Candidates: []lyricsDecisionCandidate{{Source: "kugou", Artist: "Prince"}}}},
	}
	return key, func() {
		enrichCache, appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintLogged =
			savedCache, savedHint, savedMisses, savedInflight, savedLogged
	}
}

func TestCoverAlbumForTrack(t *testing.T) {
	_, restore := seedPrinceHintCache(t)
	defer restore()
	ctx := context.Background()
	const title = "Why You Wanna Treat Me So Bad?"
	// 播放器报了专辑:原样返回,不看回填。
	if got := coverAlbumForTrack(ctx, "Prince", "Sexy Dancer", "Prince", 258); got != "Prince" {
		t.Fatalf("album given: got %q", got)
	}
	// 没报专辑、候选已缓存、缓存条目里胜出候选报「Prince」→ 回填原版专辑(只读缓存,不发请求)。
	if got := coverAlbumForTrack(ctx, "王子", title, "", 230.121); got != "Prince" {
		t.Fatalf("album-less MV: got %q want Prince", got)
	}
	// 缓存条目还没有(首次解析前),旁证为空 → 不猜。
	enrichCache = map[string]enrichEntry{}
	if got := coverAlbumForTrack(ctx, "王子", title, "", 230.121); got != "" {
		t.Fatalf("no corroboration yet: got %q want empty", got)
	}
	// 时长不够(< 75s)不问也不猜。
	if got := coverAlbumForTrack(ctx, "王子", title, "", 40); got != "" {
		t.Fatalf("short track: got %q", got)
	}
}

func TestCoverAlbumCorroboration(t *testing.T) {
	_, restore := seedPrinceHintCache(t)
	defer restore()
	const title = "Why You Wanna Treat Me So Bad?"
	picked := &scoredLyricCandidateResult{Source: "kugou", Artist: "Prince"}
	got := coverAlbumCorroboration("王子", title, "", "PRINCE", picked)
	// 缓存里的胜出候选 + MusicBrainz 统一名 + 这一轮胜出候选,三份都在(重复无妨,pick 那边按 normLoose 折叠)。
	want := []string{"Prince", "PRINCE", "Prince"}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
	// 全空:没有缓存条目、没统一名、没胜出候选;空白名字也不算。
	enrichCache = map[string]enrichEntry{}
	if got := coverAlbumCorroboration("王子", title, "", "", nil); len(got) != 0 {
		t.Fatalf("empty corroboration: got %v", got)
	}
	if got := coverAlbumCorroboration("王子", title, "", "  ", &scoredLyricCandidateResult{Artist: " "}); len(got) != 0 {
		t.Fatalf("blank names must be dropped: got %v", got)
	}
}

func TestAppleAlbumHintSyncUsesCacheAndGivesUp(t *testing.T) {
	key, restore := seedPrinceHintCache(t)
	defer restore()
	const title = "Why You Wanna Treat Me So Bad?"
	// 候选已缓存:当场挑,不发请求(ctx 已取消也照样能答 —— 说明没走网络)。
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got := appleAlbumHintSync(ctx, "王子", title, 230.121, []string{"Prince"}); got != "Prince" {
		t.Fatalf("cached: got %q want Prince", got)
	}
	// 同一首同一结果只记一行日志 —— 挑过之后 Logged 里记着 Prince。
	appleAlbumHintMu.Lock()
	logged := appleAlbumHintLogged[key]
	appleAlbumHintMu.Unlock()
	if logged != "Prince" {
		t.Fatalf("logged marker: got %q", logged)
	}
	// 没缓存、已经 miss 满:直接放弃,不再发请求。
	otherKey := appleAlbumHintKey("Nobody", "Nothing Here", 200)
	appleAlbumHintMisses[otherKey] = appleAlbumHintMaxMisses
	if got := appleAlbumHintSync(ctx, "Nobody", "Nothing Here", 200, nil); got != "" {
		t.Fatalf("maxed misses: got %q want empty", got)
	}
	// 后台那次还在飞、ctx 已取消:不等、不重复发,返回空。
	inflightKey := appleAlbumHintKey("Somebody", "Still Loading", 200)
	appleAlbumHintInflight[inflightKey] = true
	if got := appleAlbumHintSync(ctx, "Somebody", "Still Loading", 200, nil); got != "" {
		t.Fatalf("inflight + cancelled ctx: got %q want empty", got)
	}
	// 时长不够不问。
	if got := appleAlbumHintSync(ctx, "王子", title, 40, []string{"Prince"}); got != "" {
		t.Fatalf("short: got %q", got)
	}
}

func TestPeripheralBackfillWindowOpen(t *testing.T) {
	now := time.Now().Unix()
	if peripheralBackfillWindowOpen(enrichEntry{PeripheralRetryCount: peripheralBackfillMaxAttempts, TS: 1}) {
		t.Fatal("capped entry must not reopen")
	}
	if peripheralBackfillWindowOpen(enrichEntry{PeripheralTS: now}) {
		t.Fatal("just backfilled: window closed")
	}
	if !peripheralBackfillWindowOpen(enrichEntry{TS: now - int64(enrichPeripheralRetryInterval/time.Second) - 1}) {
		t.Fatal("old entry without PeripheralTS falls back to TS and reopens")
	}
}

func TestAppleAlbumHintQueryConcluded(t *testing.T) {
	cases := []struct {
		name               string
		n                  int
		attempts, failures int32
		want               bool
	}{
		{"有候选就算数", 3, 4, 4, true},
		{"网络通、Apple 说没有", 0, 4, 1, true},
		{"四个请求全在传输层失败(断网 / DNS)", 0, 4, 4, false},
		{"一个请求都没发出去", 0, 0, 0, false},
		{"只发出一个且失败", 0, 1, 1, false},
	}
	for _, c := range cases {
		if got := appleAlbumHintQueryConcluded(c.n, c.attempts, c.failures); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestStoreAppleAlbumHintResultNetworkDownNoMiss(t *testing.T) {
	savedMisses, savedInflight := appleAlbumHintMisses, appleAlbumHintInflight
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{}
	defer func() { appleAlbumHintMisses, appleAlbumHintInflight = savedMisses, savedInflight }()
	key := appleAlbumHintKey("Nobody", "Offline Song", 200)
	appleAlbumHintInflight[key] = true
	// 断网那一轮:只清在途,不记 miss。
	storeAppleAlbumHintResult(key, nil, false)
	if appleAlbumHintInflight[key] || appleAlbumHintMisses[key] != 0 {
		t.Fatalf("network-down round: inflight=%v misses=%d", appleAlbumHintInflight[key], appleAlbumHintMisses[key])
	}
	// 网络通、Apple 确实没有:记 miss,记满 appleAlbumHintMaxMisses 次就不再问。
	storeAppleAlbumHintResult(key, nil, true)
	storeAppleAlbumHintResult(key, nil, true)
	if appleAlbumHintMisses[key] != appleAlbumHintMaxMisses {
		t.Fatalf("concluded misses: got %d want %d", appleAlbumHintMisses[key], appleAlbumHintMaxMisses)
	}
}

func TestAlbumHintTitleSplit(t *testing.T) {
	cases := []struct {
		title        string
		artist, song string
		ok           bool
	}{
		// 用户那首:频道「音樂頑童」上传,歌手写在曲名里,尾括号是视频标注不是版本。
		{"Musiq Soulchild - Buddy (Official Video)", "Musiq Soulchild", "Buddy", true},
		{"Prince - 1999 (Official Music Video) [HD]", "Prince", "1999", true},
		{"Prince – 1999", "Prince", "1999", true}, // en dash
		// 版本括号按 normEnrichTitle 的规则保留在后段里。
		{"Prince - 1999 (Live)", "Prince", "1999 (Live)", true},
		// 只在第一个破折号拆:后面的破折号留在曲名里。
		{"A - B - C", "A", "B - C", true},
		{"Buddy", "", "", false},
		{"Buddy (Official Video)", "", "", false},
		{" - Buddy", "", "", false},
		{"Buddy - ", "", "", false},
		{"Buddy - (…)", "", "", false},
	}
	for _, c := range cases {
		artist, song, ok := albumHintTitleSplit(c.title)
		if artist != c.artist || song != c.song || ok != c.ok {
			t.Errorf("%q: got (%q, %q, %v) want (%q, %q, %v)", c.title, artist, song, ok, c.artist, c.song, c.ok)
		}
	}
}

// buddyResults 是 2026-09-11 对「Musiq Soulchild Buddy」的 US 商店实测形状(录音室版都是 223.8s)。
func buddyResults() []itunesResult {
	return []itunesResult{
		{TrackName: "B.U.D.D.Y.", ArtistName: "Musiq Soulchild", CollectionName: "Luvanmusiq", CollectionID: 1, TrackTimeMillis: 223800, ReleaseDate: "2007-03-13T07:00:00Z"},
		{TrackName: "Buddy", ArtistName: "Musiq Soulchild", CollectionName: "Buddy - Single", CollectionID: 2, TrackTimeMillis: 223800, ReleaseDate: "2007-01-23T08:00:00Z"},
		{TrackName: "B.U.D.D.Y.", ArtistName: "Musiq Soulchild", CollectionName: "Sobeautiful", CollectionID: 3, TrackTimeMillis: 223800, ReleaseDate: "2009-11-17T08:00:00Z"},
		// 同名别人的歌,时长也在容差内:署名跟前段不符,不能收。
		{TrackName: "Buddy", ArtistName: "De La Soul", CollectionName: "3 Feet High and Rising", CollectionID: 4, TrackTimeMillis: 224000, ReleaseDate: "1989-03-03T08:00:00Z"},
	}
}

func TestAlbumHintCandidatesFromTitleSplit(t *testing.T) {
	// 时长给一个容差内的值,先验证署名那道门。
	cands := albumHintCandidatesFromTitleSplit(buddyResults(), "Musiq Soulchild", "Buddy", 225)
	var got []string
	for _, c := range cands {
		if c.TitleArtist != "Musiq Soulchild" {
			t.Fatalf("TitleArtist 没记上: %+v", c)
		}
		got = append(got, c.Album)
	}
	want := []string{"Luvanmusiq", "Buddy - Single", "Sobeautiful"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("拆分身份候选:want %v, got %v", want, got)
	}
	// 主查询路径不会给这些候选记 TitleArtist。
	for _, c := range albumHintCandidatesFromResults(buddyResults(), "Buddy", 225) {
		if c.TitleArtist != "" {
			t.Fatalf("主查询候选不该带 TitleArtist: %+v", c)
		}
	}
	// 用户那首 MV 的真实时长 231.441s 对 223.8s 超出 max(4s, 3%%)=6.94s:时长容差没放宽,仍然零候选。
	if got := albumHintCandidatesFromTitleSplit(buddyResults(), "Musiq Soulchild", "Buddy", 231.441); len(got) != 0 {
		t.Fatalf("MV 时长超容差仍应零候选, got %v", got)
	}
}

func TestPickAppleAlbumHintTitleArtist(t *testing.T) {
	cands := albumHintCandidatesFromTitleSplit(buddyResults(), "Musiq Soulchild", "Buddy", 225)
	releases := map[int64]string{1: "2007-03-13T07:00:00Z", 2: "2007-01-23T08:00:00Z", 3: "2009-11-17T08:00:00Z"}
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}
	// 播放器署名是频道名、没有歌词旁证:凭 TitleArtist 当 0 档;Single 减分,原专辑「Luvanmusiq」胜出。
	if got := pickAppleAlbumHint(cands, "音樂頑童", nil); got != "Luvanmusiq" {
		t.Fatalf("TitleArtist 当 0 档:want Luvanmusiq, got %q", got)
	}
	// 同样的候选抹掉 TitleArtist 就回到老规矩:频道名对不上、没旁证 → 不采。
	for i := range cands {
		cands[i].TitleArtist = ""
	}
	if got := pickAppleAlbumHint(cands, "音樂頑童", nil); got != "" {
		t.Fatalf("没有 TitleArtist 不该采, got %q", got)
	}
	// TitleArtist 跟 Apple 署名不符(缓存被手改)不算数。
	cands[0].TitleArtist = "Someone Else"
	if got := pickAppleAlbumHint(cands[:1], "音樂頑童", nil); got != "" {
		t.Fatalf("TitleArtist 与署名不符不该采, got %q", got)
	}
}
