package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"
)

func TestBracketIdentifiers(t *testing.T) {
	cases := []struct {
		inner string
		want  string
	}{
		{"#6", "[hash:6]"},
		{"＃６", "[hash:6]"},
		{"# 11", "[hash:11]"},
		{"#1 Hit Version", "[]"},
		{"Part 2", "[part:2]"},
		{"Pt. II", "[part:2]"},
		{"part.3", "[part:3]"},
		{"Part2", "[part:2]"},
		{"Part 1 & 2", "[]"},
		{"Vol.2", "[vol:2]"},
		{"Volume 3", "[vol:3]"},
		{"Ep.12", "[episode:12]"},
		{"Episode 1", "[episode:1]"},
		{"Chapter IV", "[chapter:4]"},
		{"Act 1", "[act:1]"},
		{"No. 5", "[no:5]"},
		{"Op. 27 No. 2", "[]"},
		{"第3集", "[第集:3]"},
		{"第十二话", "[第话:12]"},
		{"第二季", "[第季:2]"},
		{"1", "[number:1]"},
		{"22", "[number:22]"},
		{"II", "[number:2]"},
		{"三", "[number:3]"},
		{"上", "[half:1]"},
		{"下", "[half:3]"},
		{"前篇", "[half:1]"},
		{"後篇", "[half:3]"},
		{"2026 ver", "[rerecord:2026]"},
		{"2026 Ver.", "[rerecord:2026]"},
		{"2026 version", "[rerecord:2026]"},
		{"2023 Re-recording", "[rerecord:2023]"},
		{"2023 Rerecorded", "[rerecord:2023]"},
		// 不是编号的:
		{"x", "[]"},
		{"No Love", "[]"},
		{"Taylor's Version", "[]"},
		{"2011 Remaster", "[]"},
		{"Remastered 2009 Version", "[]"},
		{"Live 2008", "[]"},
		{"2008 Live Version", "[]"},
		{"I Miss You", "[]"},
		{"with Mustafa", "[]"},
		{"Explicit", "[]"},
		{"电影《金多宝》片尾曲", "[]"},
		{"feat. Free Nationals", "[]"},
		{"TV Size", "[]"},
		{"Love Is Everywhere", "[]"},
		{"Instrumental", "[]"},
		{"New Era", "[]"},
		{"Skr", "[]"},
		{"Deep 2", "[]"},
		{"Piano 2", "[]"},
		// 出处、用途说明里带着的编号不算:
		{"第1話〜第30話", "[]"},
		{"第1話〜26話 OP", "[]"},
		{"第1期 第1話〜18話 OP", "[]"},
		{"《时光代理人第二季》动画插曲", "[]"},
		{"英雄联盟:双城之战》动画第二季原声", "[]"},
		{`From "Kill Bill: Vol. 1"`, "[]"},
		{"Single from John Wick: Chapter 4", "[]"},
		{"Team de Sonho, Vol 2", "[]"},
		{"Gymnopedie No. 1", "[]"},
		{"VIVINOS - ALNST Original Soundtrack Part 2", "[]"},
		{"Lost Recording #6", "[]"},
		{"2019.ver", "[rerecord:2019]"},
		{"Re-Recording 2024", "[rerecord:2024]"},
		{"Part.1", "[part:1]"},
		{"2006", "[number:2006]"},
		{"Épisode 3", "[episode:3]"},
		{"Partie 2", "[part:2]"},
	}
	for _, c := range cases {
		var parts []string
		for _, id := range bracketIdentifiers(c.inner) {
			parts = append(parts, fmt.Sprintf("%s:%d", id.kind, id.value))
		}
		if got := "[" + strings.Join(parts, " ") + "]"; got != c.want {
			t.Errorf("bracketIdentifiers(%q) = %s, want %s", c.inner, got, c.want)
		}
	}
}

func TestTitleIdentifiersConflict(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"Song (#6)", "Song (#11)", true},
		{"Song (#6)", "Song (#6)", false},
		{"Song (#6)", "Song", false},
		{"Song", "Song (#11)", false},
		{"Song (Part 1)", "Song (Part 2)", true},
		{"Song (Part 1)", "Song (Pt. I)", false},
		{"Song (#6)", "Song (Part 2)", false},
		{"Song (2026 ver.)", "Song (2020 ver.)", true},
		{"Song (2026 ver.)", "Song (2026 Version)", false},
		{"Song (Remastered 2009)", "Song (Remastered 2011)", false},
		{"Song（上）", "Song（下）", true},
		{"Song (1)", "Song (2)", true},
		{"Song (第3集)", "Song (第4集)", true},
		{"Song (第3集)", "Song (第3话)", false},
		{"Song (#6) (Live)", "Song (#11) [Live]", true},
		{"Song (Live)", "Song (#11)", false},
		{"Song (Episode 1)", "Song (Épisode 3)", true},
	}
	for _, c := range cases {
		if got := titleIdentifiersConflict(c.a, c.b); got != c.want {
			t.Errorf("titleIdentifiersConflict(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestLyricSearchTitle(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Song (#6)", "Song (#6)"},
		{"Song (2026 ver)", "Song (2026 ver)"},
		{"Song（2026 ver）", "Song（2026 ver）"},
		{"Song (2026 re-recording)", "Song (2026 re-recording)"},
		{"Song (Part 2) (Explicit)", "Song (Part 2)"},
		{"Song (Live) (#6)", "Song (Live) (#6)"},
		{"Song (#6) (Live)", "Song (#6) (Live)"},
		{"Song [第3集]", "Song [第3集]"},
		{"Song (Part 2) (2)", "Song (Part 2)"},
		{"Song (2) (Part 3)", "Song (2) (Part 3)"},
	}
	for _, c := range cases {
		if got := lyricSearchTitle(c.in); got != c.want {
			t.Errorf("lyricSearchTitle(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	// 括号里没有编号时跟 normEnrichTitle 逐字相同:搜索、挑选、缓存 key 都跟原来一样。
	for _, in := range []string{
		"不散的筵席（I Miss You）", "Colder (Explicit)", "万幸 (电影《金多宝》片尾曲)", "Toronto 2014 (with Mustafa)",
		"等你下课 (with 杨瑞代)", "皇帝的新衣(Skr)", "君をのせて (天空の城ラピュタ)", "404 (New Era)",
		"Don't Call (feat. Free Nationals) (Explicit)", "Song (2014 Remaster)", "Song (Live)", "Song (Remastered 2009)",
		"(Interlude)", "Song (TV Size)", "Song", "",
		// 光数字、上 / 下说不准是不是编号,照样剥:
		"想逃避（22）", "Song（上）", "Song (2006)", "Song (II)",
	} {
		if got, want := lyricSearchTitle(in), normEnrichTitle(in); got != want {
			t.Errorf("lyricSearchTitle(%q) = %q, want normEnrichTitle %q", in, got, want)
		}
	}
}

func TestLyricQueryTitle(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Song (#6)", "Song"},
		{"Song (Part 2)", "Song"},
		{"想逃避（22）", "想逃避（22）"},
		{"Song (2026 ver.)", "Song (2026 ver.)"},
		{"Song (Live)", "Song (Live)"},
		{"Song", "Song"},
	}
	for _, c := range cases {
		if got := lyricQueryTitle(c.in); got != c.want {
			t.Errorf("lyricQueryTitle(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSearchTitleVariantsWithIdentifiers(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"Song (#6)", []string{"Song (#6)", "Song"}},
		{"Song (Part 2)", []string{"Song (Part 2)", "Song"}},
		{"想逃避（22）", []string{"想逃避", "想逃避（22）"}},
		{"Song（上）", []string{"Song", "Song（上）"}},
		{"Song", []string{"Song"}},
	}
	for _, c := range cases {
		if got := searchTitleVariants(c.in); fmt.Sprint(got) != fmt.Sprint(c.want) {
			t.Errorf("searchTitleVariants(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLyricTitleAcceptedIdentifiers(t *testing.T) {
	cases := []struct {
		candidate, local string
		want             bool
	}{
		{"Song (#7)", "Song (#6)", false},
		{"Song (#6)", "Song (#6)", true},
		{"Song", "Song (#6)", true},
		{"Song (Live)", "Song (#6)", true},
		{"Song (Part 2)", "Song (Part 1)", false},
		{"Song (2020 ver.)", "Song (2026 ver.)", false},
		{"Song (#6)", "Song", true},
		{"Song (#11)", "Song", true},
	}
	for _, c := range cases {
		if got := lyricTitleAccepted(c.candidate, c.local); got != c.want {
			t.Errorf("lyricTitleAccepted(%q, %q) = %v, want %v", c.candidate, c.local, got, c.want)
		}
	}
}

func TestLyricSearchTitleContext(t *testing.T) {
	bg := context.Background()
	ctx := withLyricSearchTitle(bg, "Song (#6)")
	if got := lyricSearchTitleFor(ctx, "Song"); got != "Song (#6)" {
		t.Errorf("lyricSearchTitleFor = %q", got)
	}
	if got := lyricSearchTitleFor(ctx, "Other"); got != "Other" {
		t.Errorf("别的歌不该换: %q", got)
	}
	if got := lyricSearchTitleToStore(ctx, "Song"); got != "Song (#6)" {
		t.Errorf("lyricSearchTitleToStore = %q", got)
	}
	if got := lyricSearchTitleToStore(withLyricSearchTitle(bg, "Song"), "Song"); got != "" {
		t.Errorf("跟 key 歌名相同时不记: %q", got)
	}
	if withLyricSearchTitle(bg, "") != bg {
		t.Error("空串不该挂到 ctx 上")
	}
	if got := lyricSearchTitleOrStored(bg, "Song (#6)", "Song"); got != "Song (#6)" {
		t.Errorf("没有 ctx 时用条目里记下的: %q", got)
	}
	if got := lyricSearchTitleOrStored(withLyricSearchTitle(bg, "Song (#7)"), "Song (#6)", "Song"); got != "Song (#7)" {
		t.Errorf("ctx 上的优先: %q", got)
	}
	if got := lyricSearchTitleOrStored(bg, "Other (#1)", "Song"); got != "Song" {
		t.Errorf("记下的不是这一首就不用: %q", got)
	}
	if got := lyricSearchTitleWorthStoring("Song (#6)", "Song"); got != "Song (#6)" {
		t.Errorf("lyricSearchTitleWorthStoring = %q", got)
	}
}

func TestLyricTitleSameName(t *testing.T) {
	cases := []struct {
		candidate, local  string
		sameName, sameNum bool
	}{
		{"Song (Part 2)", "Song (Part 2)", true, true},
		{"Song (Part.2)", "Song (Part 2)", true, true},
		{"Song", "Song (Part 2)", true, false},
		{"Song (Part 1)", "Song (Part 2)", false, false},
		{"Song (Live)", "Song (Part 2)", false, false},
		{"Song", "Song", true, false},
		{"Song (Live)", "Song", false, false},
		// 本地只有光数字、上 / 下时照旧逐字比:
		{"Song", "Song (2)", false, false},
		{"Song", "Song（上）", false, false},
		{"페이지원", "페이지원(Part.2)", true, false},
		// 编号写法不同、值相同:
		{"Sadeness (Part 1)", "Sadeness (Part I)", true, true},
		{"Song (Pt. 2) (Explicit)", "Song (Part 2)", true, true},
		{"Song (Part 2) (Live)", "Song (Part 2)", false, false},
		{"Song (Pt. 1)", "Song (Part 2)", false, false},
	}
	for _, c := range cases {
		if got := lyricTitleSameName(c.candidate, c.local); got != c.sameName {
			t.Errorf("lyricTitleSameName(%q, %q) = %v, want %v", c.candidate, c.local, got, c.sameName)
		}
		if got := lyricTitleSameNumber(c.candidate, c.local); got != c.sameNum {
			t.Errorf("lyricTitleSameNumber(%q, %q) = %v, want %v", c.candidate, c.local, got, c.sameNum)
		}
	}
}

func TestLyricSourceTitleContext(t *testing.T) {
	bg := context.Background()
	// 交给各源的是按查询词归一化过的写法(繁体转简体),对的是归一化过的 key 歌名。
	ctx := withLyricSourceTitle(bg, "愛的故事 (第二集)", "周杰倫", "愛的故事", "專輯")
	if got := lyricSourceTitleFor(ctx, "爱的故事"); got != "爱的故事 (第二集)" {
		t.Errorf("lyricSourceTitleFor = %q", got)
	}
	// 三栏里有假名就原样送出,同 searchQueryFields。
	ctx = withLyricSourceTitle(bg, "夢 (Part 2)", "あいみょん", "夢", "")
	if got := lyricSourceTitleFor(ctx, "夢"); got != "夢 (Part 2)" {
		t.Errorf("日文歌不该转简体: %q", got)
	}
	if got := lyricSourceTitleFor(ctx, "别的歌名"); got != "别的歌名" {
		t.Errorf("换了歌名的轮次用它自己的: %q", got)
	}
	if withLyricSourceTitle(bg, "Song", "A", "Song", "") != bg {
		t.Error("跟 key 歌名相同时不该挂")
	}
	if withLyricSourceTitle(bg, "Other (#1)", "A", "Song", "") != bg {
		t.Error("不是这一首的不该挂")
	}
	if got := lyricSourceTitleFor(bg, "Song"); got != "Song" {
		t.Errorf("没挂时用 title: %q", got)
	}
}

func TestLyricIdentityFieldsWithSourceTitle(t *testing.T) {
	bg := context.Background()
	ctx := withSearchQueryOriginal(bg, "周杰倫", "愛的故事", "專輯")
	ctx = withLyricSourceTitle(ctx, "愛的故事 (第二集)", "周杰倫", "愛的故事", "專輯")
	for _, title := range []string{"爱的故事 (第二集)", "爱的故事"} {
		a, ti, al := lyricIdentityFields(ctx, "周杰伦", title, "专辑")
		if a != "周杰倫" || ti != "愛的故事" || al != "專輯" {
			t.Errorf("lyricIdentityFields(%q) = %q %q %q, want 原样标签", title, a, ti, al)
		}
	}
	// 没记原样写法(归一化没改动)时换回 key 里的歌名。
	ctx = withLyricSourceTitle(bg, "Song (#6)", "A", "Song", "Al")
	if a, ti, al := lyricIdentityFields(ctx, "A", "Song (#6)", "Al"); a != "A" || ti != "Song" || al != "Al" {
		t.Errorf("lyricIdentityFields = %q %q %q", a, ti, al)
	}
	if _, ti, _ := lyricIdentityFields(ctx, "A", "Other (Live)", "Al"); ti != "Other (Live)" {
		t.Errorf("别的歌名不换: %q", ti)
	}
}

func TestTriangleAcceptsTitleWithoutIdentifier(t *testing.T) {
	if !lyricRecordingTriangleMatches("페이지원", "커피 하우스 OST", 186, "페이지원(Part.2)", "커피하우스 OST", 186.626) {
		t.Error("候选歌名不带编号、专辑和时长对得上,该跟本地歌名不带编号时一样收")
	}
	if lyricRecordingTriangleMatches("페이지원 (Part.1)", "커피 하우스 OST", 186, "페이지원(Part.2)", "커피하우스 OST", 186.626) {
		t.Error("编号不同的不该收")
	}
}

func TestKugouRankSongsPrefersSameNumber(t *testing.T) {
	accept := func(*kugouSong) (bool, bool) { return true, false }
	songs := []kugouSong{
		{Hash: "a", SongName: "Song", Duration: 200},
		{Hash: "b", SongName: "Song (Part 2)", Duration: 200},
	}
	if got, _ := kugouRankSongs(songs, "Song (Part 2)", "", 200, accept); got == nil || got.Hash != "b" {
		t.Errorf("编号也对得上的该排最前: %+v", got)
	}
	songs = []kugouSong{
		{Hash: "a", SongName: "Song (Acoustic)", Duration: 200},
		{Hash: "b", SongName: "Song", Duration: 200},
	}
	if got, _ := kugouRankSongs(songs, "Song (Part 2)", "", 200, accept); got == nil || got.Hash != "b" {
		t.Errorf("不带编号的同名该排在剥括号相等的前面: %+v", got)
	}
}

// 带编号的歌:完整歌名搜回来的只有自报时长对不上的,接着拿去掉编号的写法搜;不带编号的歌照旧挑到就停。
func TestResolveKugouLyricKeepsLookingWhenNumberedPickDoesNotFit(t *testing.T) {
	run := func(title string, pages map[string][]string) string {
		var asked string
		withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
			switch {
			case target == "http://mobilecdn.kugou.com/api/v3/search/song":
				return http.StatusOK, kgTestPage(r, pages[r.URL.Query().Get("keyword")])
			case target == "http://krcs.kugou.com/search":
				asked = r.URL.Query().Get("hash")
				return http.StatusOK, `{"status":200,"candidates":[{"id":"1","accesskey":"k"}]}`
			case strings.HasSuffix(target, ".kugou.com/download"):
				return http.StatusOK, `{"status":200,"content":"` + kgTestKRCContent(t, kgTestKRC) + `"}`
			}
			return http.StatusNotFound, ""
		})
		resolveKugouLyric(qqRoundCtx(), "Enigma", title, "The Platinum Collection", 257)
		return asked
	}
	numbered := map[string][]string{
		"Enigma Sadeness (Part I)": {`{"hash":"short","songname":"Sadeness","singername":"Enigma","album_name":"Single","duration":181}`},
		"Enigma Sadeness":          {`{"hash":"right","songname":"Sadeness","singername":"Enigma","album_name":"The Platinum Collection","duration":255}`},
	}
	if got := run("Sadeness (Part I)", numbered); got != "right" {
		t.Errorf("时长对不上的该先记着、接着搜: asked=%q", got)
	}
	numbered["Enigma Sadeness"] = nil
	if got := run("Sadeness (Part I)", numbered); got != "short" {
		t.Errorf("都没有更合适的,用记着的那条: asked=%q", got)
	}
	live := map[string][]string{
		"Enigma Sadeness (Live)": {`{"hash":"short","songname":"Sadeness (Live)","singername":"Enigma","album_name":"Single","duration":181}`},
		"Enigma Sadeness":        {`{"hash":"right","songname":"Sadeness (Live)","singername":"Enigma","album_name":"The Platinum Collection","duration":255}`},
	}
	if got := run("Sadeness (Live)", live); got != "short" {
		t.Errorf("不带编号的歌照旧挑到就停: asked=%q", got)
	}
}

func TestPickQQAlbumTrackPrefersSameNumber(t *testing.T) {
	songs := []qqAlbumSong{{mid: "1", name: "Song"}, {mid: "2", name: "Song (Part 2)"}}
	if got, ok := pickQQAlbumTrack(songs, "A", "Song (Part 2)"); !ok || got.mid != "2" {
		t.Errorf("编号也对得上的该排最前: %+v %v", got, ok)
	}
	songs = []qqAlbumSong{{mid: "1", name: "Song (Acoustic)"}, {mid: "2", name: "Song"}}
	if got, ok := pickQQAlbumTrack(songs, "A", "Song (Part 2)"); !ok || got.mid != "2" {
		t.Errorf("不带编号的同名该排在剥括号相等的前面: %+v %v", got, ok)
	}
}

func TestQQCandidatesWithIdentifiers(t *testing.T) {
	items := []qqSearchItem{
		{Mid: "1", Name: "Song", Singer: "A", Album: "X"},
		{Mid: "2", Name: "Song (Part 2)", Singer: "A", Album: "X"},
		{Mid: "3", Name: "Song (Part 1)", Singer: "A", Album: "X"},
	}
	cands := qqCollectCandidates(items, "A", "Song (Part 2)", true)
	if len(cands) != 2 || !cands[0].exact || cands[0].sameNumber || !cands[1].exact || !cands[1].sameNumber {
		t.Fatalf("qqCollectCandidates = %+v", cands)
	}
	if got, ok := qqPickCandidate(cands, "A", 0); !ok || got.mid != "2" {
		t.Errorf("qqPickCandidate = %+v", got)
	}
	if got, ok, _ := qqPickCandidateWithAlbum(cands, "A", "X", 0, func(string) string { return "" }); !ok || got.mid != "2" {
		t.Errorf("qqPickCandidateWithAlbum = %+v", got)
	}
	// 专辑对不上时,不带编号的同名照旧够格(跟本地歌名不带编号时一样)。
	cands = qqCollectCandidates(items[:1], "A", "Song (Part 2)", true)
	if _, ok, _ := qqPickCandidateWithAlbum(cands, "A", "Other Album", 0, func(string) string { return "" }); !ok {
		t.Error("不带编号的同名候选该算精确同名")
	}
	if qqSearchNeedsSmartboxSupplement(items[:1], "Song (Part 2)") {
		t.Error("已有不带编号的同名条目时不用补 smartbox")
	}
	if !qqSearchNeedsSmartboxSupplement([]qqSearchItem{{Mid: "1", Name: "Song (Live)"}}, "Song (Part 2)") {
		t.Error("没有同名条目时要补")
	}
}

func TestNeteasePickSongWithIdentifiers(t *testing.T) {
	var songs []neSearchSong
	if err := json.Unmarshal([]byte(`[
		{"name":"Song","artists":[{"name":"A"}],"album":{"name":"X"}},
		{"name":"Song (Part 2)","artists":[{"name":"A"}],"album":{"name":"Y"}}
	]`), &songs); err != nil {
		t.Fatal(err)
	}
	if got := neteasePickSong(songs, "A", "Song (Part 2)", "", 0); got == nil || got.Name != "Song (Part 2)" {
		t.Errorf("编号也对得上的该先挑: %+v", got)
	}
	// 只有一条不带编号的同名、专辑对不上:跟本地歌名不带编号时一样当精确同名信它。
	if got := neteasePickSong(songs[:1], "A", "Song (Part 2)", "Z", 0); got == nil || got.Name != "Song" {
		t.Errorf("不带编号的唯一同名候选该收: %+v", got)
	}
}

func TestMiguAliasCandidateWithIdentifier(t *testing.T) {
	var item miguSearchItem
	if err := json.Unmarshal([]byte(`{"name":"爱爱爱","lyricUrl":"u","songAliasName":"Love Love Love","singers":[{"name":"A"}]}`), &item); err != nil {
		t.Fatal(err)
	}
	item.duration = 200
	if !miguAliasCandidate(item, "A", "Love Love Love (Part 2)", "", 200) {
		t.Error("别名跟去掉编号的本地歌名同名时该收")
	}
}

func TestLyricSearchTitleIsWired(t *testing.T) {
	read := func(name string) string {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	enrich := read("enrich.go")
	for _, n := range []string{
		"searchTitle := lyricSearchTitle(title)\n\ttitle = normEnrichTitle(title)",
		"cancelCtx = withLyricSearchTitle(cancelCtx, searchTitle)",
		"go backfillPeripheralFields(withPlayerCover(withLyricSearchTitle(context.Background(), searchTitle), playerCover),",
		"go retryLyricsUpgrade(withLyricSearchTitle(context.Background(), searchTitle),",
		"go rescoreLyrics(withLyricSearchTitle(context.Background(), searchTitle),",
		"go retryLyricsUpgradeWith(withLyricSearchTitle(context.Background(), searchTitle),",
		"if st := lyricSearchTitleWorthStoring(searchTitle, title); st != \"\" && e.LyricsSearchTitle != st {",
		"p.LyricsSearchTitle = lyricSearchTitleToStore(ctx, title)",
		"e.LyricsSearchTitle = lyricSearchTitleToStore(ctx, title)",
		"ctx = withLyricSourceTitle(ctx, lyricSearchTitleFor(ctx, title), artist, title, searchAlbum)\n\tartist, title, searchAlbum = searchQueryFields(artist, title, searchAlbum)",
		"srcTitle := lyricSourceTitleFor(ctx, title)",
		"info := neteaseLookup(ctx, artist, srcTitle, album, durationSecs)",
		"match := qqMusicMatchCached(ctx, artist, srcTitle, album, durationSecs)",
		"qrc := qqQRCLyric(ctx, qqMid, artist, srcTitle, album, durationSecs)",
		"artist: artist, title: srcTitle, album: album,",
		"kugouLocalLyric(artist, srcTitle, album, durationSecs)",
		"kugouLyric(ctx, artist, srcTitle, album, durationSecs)",
		"lrclibLyric(ctx, artist, srcTitle, album, durationSecs)",
		"musixmatchLyric(mxCtx, artist, srcTitle, durationSecs,",
		"ytmusicLyric(ctx, artist, srcTitle, album, durationSecs)",
		"kuwoLyric(ctx, artist, srcTitle, album, durationSecs)",
		"miguLyric(ctx, artist, srcTitle, album, durationSecs)",
		"deezerLyric(ctx, artist, srcTitle, album, durationSecs, lyricSourceISRC(ctx, artist, title, album))",
		"applemusicLyric(ctx, artist, srcTitle, album, durationSecs, appleID, lyricSourceISRC(ctx, artist, title, album))",
		"sodaLyric(ctx, artist, srcTitle, album, durationSecs)",
	} {
		if !strings.Contains(enrich, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
	if n := strings.Count(enrich, "roundCtx = withLyricSourceTitle(roundCtx, lyricSearchTitleOrStored(ctx, storedSearchTitle, title), artist, title, searchAlbum)"); n != 2 {
		t.Errorf("升级重试、重打分两处都要把带编号的歌名交给各源,实际 %d 处", n)
	}
	// 打分、ISRC、平台曲目 ID 照旧用 key 里的歌名。
	for _, n := range []string{
		"ne, scored = scoredLyricCandidates(roundCtx, artist, title, searchAlbum, durationSecs)",
		"rankLyricSourceResults(artist, title, album, durationSecs, raw)",
		"idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)",
	} {
		if !strings.Contains(enrich, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
	if !strings.Contains(read("searchcli.go"), "searchCtx = withLyricSourceTitle(searchCtx, lyricSearchTitleOrStored(searchCtx, storedSearchTitle, *title), *artist, *title, *album)") {
		t.Error("手动搜索没把条目里记下的搜索歌名交给各源")
	}
	for _, name := range []string{"upcoming.go", "albumprefetch.go"} {
		if s := read(name); !strings.Contains(s, "withLyricSearchTitle(") || !strings.Contains(s, "lyricSearchTitle(t.title)") {
			t.Errorf("%s 预取没带上搜索用歌名", name)
		}
	}
	// 各源挑候选时比歌名的地方都换成了 lyricTitleSameName / lyricTitleSameNumber。
	for name, want := range map[string][2]int{"match.go": {1, 0}, "kugou.go": {1, 1}, "qq.go": {5, 4}, "netease.go": {2, 1}, "migu.go": {1, 0}} {
		s := read(name)
		if n, m := strings.Count(s, "lyricTitleSameName("), strings.Count(s, "lyricTitleSameNumber("); n != want[0] || m != want[1] {
			t.Errorf("%s 用 lyricTitleSameName / lyricTitleSameNumber 比歌名:%d / %d 处,want %d / %d", name, n, m, want[0], want[1])
		}
	}
	for name, want := range map[string]int{"deezer.go": 2, "applemusic.go": 1, "kuwo.go": 1, "soda.go": 1, "migu.go": 1, "ytmusic.go": 1, "kugou.go": 2} {
		if n := strings.Count(read(name), "lyricQueryTitle(title)"); n != want {
			t.Errorf("%s 拼搜索词要过 lyricQueryTitle:%d 处,want %d", name, n, want)
		}
	}
}
