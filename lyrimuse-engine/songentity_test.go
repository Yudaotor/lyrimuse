package main

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

// songTestLRC:每行一句、隔 8 秒,第一行从 startMs 起。
func songTestLRC(startMs int, lines []string) string {
	var b strings.Builder
	for i, l := range lines {
		ms := startMs + i*8000
		fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", ms/60000, ms/1000%60, ms%1000/10, l)
	}
	return b.String()
}

// songTestWords:n 句歌词,每个词都带 seed 和行号:同一个 seed 出同一套词,不同 seed 之间一个词都不共用。
func songTestWords(seed string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("%sa%d %sb%d %sc%d %sd%d", seed, i, seed, i, seed, i, seed, i)
	}
	return out
}

// songTestVariant:按 enrichEntry 摘一条写法;登记歌名直接给(不读旁路文件)。
func songTestVariant(key string, e enrichEntry, registered map[string]string) songVariant {
	v := songVariantOf(key, e, false)
	v.titlesDone, v.registered = true, registered
	return v
}

// songTestBuild:写法按键排好再建表,返回每条写法所在实体的第一条写法的键。
func songTestBuild(t *testing.T, vs []songVariant, splits map[string]bool) (*songEntityBuild, map[string]string) {
	t.Helper()
	slices.SortFunc(vs, func(a, b songVariant) int { return strings.Compare(a.key, b.key) })
	b := buildSongEntities(vs, splits, "")
	of := map[string]string{}
	for _, members := range b.clusters {
		for _, m := range members {
			of[vs[m].key] = vs[members[0]].key
		}
	}
	return b, of
}

func songTestSame(of map[string]string, a, b string) bool { return of[a] != "" && of[a] == of[b] }

// 同一个 ISRC 两条写法并成一首;有一条带版本词(Live)时那条的号不收;两边时长差过闸时不连。
func TestSongEntityISRC(t *testing.T) {
	vs := []songVariant{
		songTestVariant("A|Song|Album1", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("A|Song|Album2", enrichEntry{DurationSecs: 200.4, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("A|Song (Live)|Tour", enrichEntry{DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("A|Other|X", enrichEntry{DurationSecs: 300, ISRCs: []string{"USAAA1100002"}}, nil),
		songTestVariant("A|Other|Y", enrichEntry{DurationSecs: 303, ISRCs: []string{"USAAA1100002"}}, nil),
	}
	b, of := songTestBuild(t, vs, nil)
	if !songTestSame(of, "A|Song|Album1", "A|Song|Album2") {
		t.Error("同一个 ISRC、时长对得上应当是同一首")
	}
	if songTestSame(of, "A|Song|Album1", "A|Song (Live)|Tour") {
		t.Error("带版本词的写法上的 ISRC 是检索配的、可能是原版的号,不该当证据")
	}
	if songTestSame(of, "A|Other|X", "A|Other|Y") {
		t.Error("两边时长差 3 秒,超过闸,不该连")
	}
	if b.gateDrops["isrc/unverified"] == 0 || b.gateDrops["isrc/duration"] == 0 {
		t.Errorf("被闸挡下的边要计数: %v", b.gateDrops)
	}
}

// 加边顺序固定:A–B 中证据、B–C 强证据、A–C 有否决时,先加 B–C 得到 {B,C}{A},跟写法到达的先后无关。
func TestSongEntityStrongEdgesFirst(t *testing.T) {
	apple := func(track string) string { return "https://music.apple.com/us/album/x/1000?i=" + track }
	mk := func() []songVariant {
		return []songVariant{
			// A 与 B 只有中证据(网易云 id、写法族);A 与 C 是 Apple 同一张专辑里的两首(否决);B 与 C 共用播放器给的 Spotify 曲目 id。
			songTestVariant("Singer|Tune|One", enrichEntry{DurationSecs: 180, AppleURL: apple("1"), NeteaseURL: "https://music.163.com/song?id=111"}, map[string]string{"netease_song:111": "Tune"}),
			songTestVariant("Singer|Tune|Two", enrichEntry{DurationSecs: 180.2, NeteaseURL: "https://music.163.com/song?id=111", SpotifyTrackID: "abcdefghijklmnopqrstuv"}, map[string]string{"netease_song:111": "Tune"}),
			songTestVariant("Singer|Tune|Three", enrichEntry{DurationSecs: 180.1, AppleURL: apple("2"), SpotifyTrackID: "abcdefghijklmnopqrstuv"}, nil),
		}
	}
	for _, reverse := range []bool{false, true} {
		vs := mk()
		if reverse {
			slices.Reverse(vs)
		}
		_, of := songTestBuild(t, vs, nil)
		if !songTestSame(of, "Singer|Tune|Two", "Singer|Tune|Three") {
			t.Errorf("reverse=%v: 强证据先加,B 与 C 应当并上", reverse)
		}
		if songTestSame(of, "Singer|Tune|One", "Singer|Tune|Two") {
			t.Errorf("reverse=%v: A 跟 C 是同一张专辑的两首,A–B 那几条中证据要被否决", reverse)
		}
	}
}

// 检索 id 的闸:主歌手不同不连(检索把《Uchiagehanabi》配成了米津玄師《春雷》);同一个 id 在同一种文字里出两种歌名
// 整组不用;缺时长时要写法族歌名相同;带版本尾巴时要写法族歌名相同;登记歌名对不上不连,跨文字只当计数用。
func TestSongEntitySearchedIDGates(t *testing.T) {
	ne := func(id string) string { return "https://music.163.com/song?id=" + id }
	cases := []struct {
		name      string
		a, b      songVariant
		gate      string
		countOnly bool
	}{
		{"主歌手不同",
			songTestVariant("DAOKO×米津玄師|Uchiagehanabi|Uchiagehanabi - Single", enrichEntry{DurationSecs: 289.3, NeteaseURL: ne("512359198")}, nil),
			songTestVariant("米津玄師|春雷|BOOTLEG", enrichEntry{DurationSecs: 288.9, NeteaseURL: ne("512359198")}, nil),
			"netease_song/artist", false},
		{"缺时长、歌名不同",
			songTestVariant("Singer|Love|", enrichEntry{NeteaseURL: ne("2")}, nil),
			songTestVariant("Singer|爱|Album", enrichEntry{DurationSecs: 200, NeteaseURL: ne("2")}, nil),
			"netease_song/no_duration", false},
		{"带版本尾巴",
			songTestVariant("Singer|爱 (Live版)|Live", enrichEntry{DurationSecs: 250, NeteaseURL: ne("3")}, nil),
			songTestVariant("Singer|Love|Studio", enrichEntry{DurationSecs: 250.5, NeteaseURL: ne("3")}, nil),
			"netease_song/tail", false},
		// 下面几对写法族相同、一边没有时长,不会另外连出写法族边。
		{"登记歌名对不上",
			songTestVariant("Singer|Morning|A", enrichEntry{NeteaseURL: ne("4")}, map[string]string{"netease_song:4": "Evening"}),
			songTestVariant("Singer|Morning|B", enrichEntry{DurationSecs: 200.3, NeteaseURL: ne("4")}, nil),
			"netease_song/registered", false},
		{"跨文字、没有译名证据只当计数用",
			songTestVariant("Singer|Listen|A", enrichEntry{DurationSecs: 281, NeteaseURL: ne("5")}, map[string]string{"netease_song:5": "听"}),
			songTestVariant("Singer|听|B", enrichEntry{DurationSecs: 281.09, NeteaseURL: ne("5")}, map[string]string{"netease_song:5": "听"}),
			"", true},
		{"登记歌名不知道只当计数用",
			songTestVariant("Singer|Night|A", enrichEntry{QQURL: "https://y.qq.com/n/ryqq/songDetail/000abc"}, nil),
			songTestVariant("Singer|Night|B", enrichEntry{DurationSecs: 200.2, QQURL: "https://y.qq.com/n/ryqq/songDetail/000abc"}, nil),
			"", true},
	}
	for _, c := range cases {
		b, of := songTestBuild(t, []songVariant{c.a, c.b}, nil)
		if c.gate != "" {
			if b.gateDrops[c.gate] == 0 || songTestSame(of, c.a.key, c.b.key) {
				t.Errorf("%s: 应当被 %s 挡下,drops=%v", c.name, c.gate, b.gateDrops)
			}
			continue
		}
		var got *songEdge
		for i := range b.edges {
			if songEvidenceKinds[b.edges[i].kind].searched {
				got = &b.edges[i]
			}
		}
		if got == nil || got.countOnly != c.countOnly || !songTestSame(of, c.a.key, c.b.key) {
			t.Errorf("%s: 应当连上、countOnly=%v,得到 %+v", c.name, c.countOnly, got)
		}
		if c.countOnly && b.shareOf[0] == b.shareOf[1] {
			t.Errorf("%s: 只当计数用的边不连共享组", c.name)
		}
	}

	// 一个 id 两种歌名:整组不用。
	vs := []songVariant{
		songTestVariant("Singer|I Like It (Ballad Version)|A", enrichEntry{DurationSecs: 200, NeteaseURL: ne("6")}, nil),
		songTestVariant("Singer|What Is Love|B", enrichEntry{DurationSecs: 200.1, NeteaseURL: ne("6")}, nil),
		songTestVariant("Singer|What Is Love|C", enrichEntry{DurationSecs: 200.2, NeteaseURL: ne("6")}, nil),
	}
	b, _ := songTestBuild(t, vs, nil)
	if b.gateDrops["netease_song/one_title"] == 0 {
		t.Errorf("一个 id 在同一种文字里两种歌名,整组不用: drops=%v", b.gateDrops)
	}
	for _, e := range b.edges {
		if e.kind == songIDNeteaseSong {
			t.Errorf("这个 id 整组不该出边: %+v", e)
		}
	}
}

// 否决:Apple 同一张专辑里曲目 id 不同的不并;QQ 的专辑 mid 不算;一边没有人声、一边有的不并。
func TestSongEntityVetoes(t *testing.T) {
	apple := func(track string) string { return "https://music.apple.com/us/album/x/1000?i=" + track }
	vs := []songVariant{
		songTestVariant("Singer|Find Love|Album", enrichEntry{DurationSecs: 200, AppleURL: apple("1"), NeteaseURL: "https://music.163.com/song?id=9"}, map[string]string{"netease_song:9": "Find Love"}),
		songTestVariant("Singer|Find Love|Album (Deluxe)", enrichEntry{DurationSecs: 200.1, AppleURL: apple("2"), NeteaseURL: "https://music.163.com/song?id=9"}, map[string]string{"netease_song:9": "Find Love"}),
	}
	b, of := songTestBuild(t, vs, nil)
	if songTestSame(of, vs[0].key, vs[1].key) || len(b.vetoed) == 0 || b.vetoed[0].reason != "same_album:apple_song" {
		t.Errorf("Apple 同专辑不同曲目要否决: %+v", b.vetoed)
	}

	qq := []songVariant{
		songTestVariant("Singer|Waiting|Single", enrichEntry{DurationSecs: 270, ISRCs: []string{"TWK971801101"}, QQAlbumMid: "album", QQURL: "https://y.qq.com/n/ryqq/songDetail/001aaa"}, nil),
		songTestVariant("Singer|Waiting|Album", enrichEntry{DurationSecs: 270.001, ISRCs: []string{"TWK971801101"}, QQAlbumMid: "album", QQURL: "https://y.qq.com/n/ryqq/songDetail/001bbb"}, nil),
	}
	if _, of := songTestBuild(t, qq, nil); !songTestSame(of, qq[0].key, qq[1].key) {
		t.Error("QQ 的专辑 mid 是检索另查的,不当「同专辑不同曲」的依据")
	}

	words := songTestWords("vocal", 30)
	inst := []songVariant{
		songTestVariant("Singer|Tune|A", enrichEntry{DurationSecs: 200, Instrumental: true, SpotifyTrackID: "abcdefghijklmnopqrstuv"}, nil),
		songTestVariant("Singer|Tune|B", enrichEntry{DurationSecs: 200.1, SpotifyTrackID: "abcdefghijklmnopqrstuv", Lyrics: songTestLRC(1000, words), LyricsSource: "netease", ResolvedDurationSecs: 200.1}, nil),
	}
	if b, of := songTestBuild(t, inst, nil); songTestSame(of, inst[0].key, inst[1].key) || len(b.vetoed) == 0 || b.vetoed[0].reason != "vocals" {
		t.Errorf("标了纯音乐的写法不该跟有人声的并: %+v", b.vetoed)
	}
}

// 歌词那两条否决只对中证据生效:写法族连着、两份正文用词对不上的不并;同一个 ISRC 连着时照并。
func TestSongEntityLyricsVetoOnlyForMediumEvidence(t *testing.T) {
	a, c := songTestWords("alpha", 30), songTestWords("omega", 30)
	mk := func(isrc bool) []songVariant {
		x := enrichEntry{DurationSecs: 200, Lyrics: songTestLRC(1000, a), LyricsSource: "kugou", ResolvedDurationSecs: 200}
		y := enrichEntry{DurationSecs: 200.5, Lyrics: songTestLRC(1000, c), LyricsSource: "netease", ResolvedDurationSecs: 200.5}
		if isrc {
			x.ISRCs, y.ISRCs = []string{"HKA351501001"}, []string{"HKA351501001"}
		}
		return []songVariant{songTestVariant("Singer|Song|One", x, nil), songTestVariant("Singer|Song|Two", y, nil)}
	}
	if b, of := songTestBuild(t, mk(false), nil); songTestSame(of, "Singer|Song|One", "Singer|Song|Two") || len(b.vetoed) == 0 || b.vetoed[0].reason != "lyrics_words" {
		t.Errorf("只靠写法族连着、正文不是同一套词,要否决: %+v", b.vetoed)
	}
	if _, of := songTestBuild(t, mk(true), nil); !songTestSame(of, "Singer|Song|One", "Singer|Song|Two") {
		t.Error("有强证据连着时歌词否决不生效")
	}
}

// 共享组:强证据连着的在一组;检索 id 连着的,没有旁证不进一组,两边歌词各自独立得来又对得上才进。
func TestSongEntityShareGroups(t *testing.T) {
	words := songTestWords("share", 30)
	ne := "https://music.163.com/song?id=42"
	reg := map[string]string{"netease_song:42": "Tune"}
	// 两条写法只有这一条网易云 id 连着(一边没有时长,没有写法族边)。
	alone := []songVariant{
		songTestVariant("Singer|Tune|One", enrichEntry{NeteaseURL: ne}, reg),
		songTestVariant("Singer|Tune|Two", enrichEntry{DurationSecs: 300, NeteaseURL: ne}, reg),
	}
	b, of := songTestBuild(t, alone, nil)
	if !songTestSame(of, alone[0].key, alone[1].key) {
		t.Fatal("检索 id 连着的两条应当算同一首")
	}
	if b.shareOf[0] == b.shareOf[1] {
		t.Error("只靠一条检索 id 连着,没有旁证,不该进同一个共享组")
	}
	withLyrics := []songVariant{
		songTestVariant("Singer|Tune|One", enrichEntry{NeteaseURL: ne, Lyrics: songTestLRC(1000, words), LyricsSource: "kugou"}, reg),
		songTestVariant("Singer|Tune|Two", enrichEntry{DurationSecs: 300, NeteaseURL: ne, Lyrics: songTestLRC(1000, words), LyricsSource: "qq", ResolvedDurationSecs: 300}, reg),
	}
	if b, _ := songTestBuild(t, withLyrics, nil); b.shareOf[0] != b.shareOf[1] {
		t.Error("两边歌词各自独立得来又对得上,是检索 id 的旁证,应当进同一个共享组")
	}
	strong := []songVariant{
		songTestVariant("Singer|Tune|One", enrichEntry{DurationSecs: 200, ISRCs: []string{"HKA351501001"}}, nil),
		songTestVariant("Singer|Tune Song|Two", enrichEntry{DurationSecs: 200.3, ISRCs: []string{"HKA351501001"}}, nil),
	}
	if b, _ := songTestBuild(t, strong, nil); b.shareOf[0] != b.shareOf[1] {
		t.Error("强证据连着的应当在同一个共享组")
	}
	// 检索 id 加一条写法族边(歌名带 feat. 尾巴、族键相同、逐字不同):第二种中证据算旁证。
	corroborated := []songVariant{
		songTestVariant("Singer|Tune|One", enrichEntry{DurationSecs: 200, NeteaseURL: ne}, reg),
		songTestVariant("Singer|Tune (feat. Guest)|Two", enrichEntry{DurationSecs: 200.3, NeteaseURL: ne}, reg),
	}
	if b, _ := songTestBuild(t, corroborated, nil); b.shareOf[0] != b.shareOf[1] {
		t.Error("检索 id 加写法族,两种中证据互为旁证,应当进同一个共享组")
	}
}

// 时长 + 歌词(E2):同一位歌手的英文名与中文名写法,时长按精度接近、正文对得上,连一条边;正文出自同一个检索条目的不算。
func TestSongEntityLyricsEvidence(t *testing.T) {
	words := songTestWords("listen", 30)
	mk := func(srcA, srcB string, same bool) []songVariant {
		la, lb := songTestLRC(1000, words), songTestLRC(1000, words)
		if !same {
			lb += "[05:00.00]extra closing line here\n"
		}
		return []songVariant{
			songTestVariant("Khalil Fong|Listen|Journey", enrichEntry{DurationSecs: 281, Lyrics: la, LyricsSource: srcA, ResolvedDurationSecs: 281}, nil),
			songTestVariant("Khalil Fong|听|JTW", enrichEntry{DurationSecs: 281.093, Lyrics: lb, LyricsSource: srcB, ResolvedDurationSecs: 281.093}, nil),
		}
	}
	vs := mk("kuwo", "kugou", true)
	if _, of := songTestBuild(t, vs, nil); !songTestSame(of, vs[0].key, vs[1].key) {
		t.Error("跨文字、时长与正文都对得上,应当连上")
	}
	vs = mk("kuwo", "kuwo", true)
	if b, of := songTestBuild(t, vs, nil); songTestSame(of, vs[0].key, vs[1].key) || b.gateDrops["lyrics/not_independent"] == 0 {
		t.Error("同一个源给出一字不差的两份,是同一个检索条目,不当证据")
	}
}

// 实体 id:跟旧表共有写法最多的旧 id 延续;两个旧实体并成一个时留建立更早的那个、另一个记重定向;新簇开新 id。
func TestSongEntityIDs(t *testing.T) {
	seeds := map[string]string{"a": "s_old1", "b": "s_old1", "c": "s_old2", "d": "s_old3"}
	created := map[string]int64{"s_old1": 200, "s_old2": 100, "s_old3": 300}
	n := 0
	newID := func() string { n++; return fmt.Sprintf("s_new%d", n) }
	ids, redirects := songEntityIDs([][]string{{"a", "c"}, {"b"}, {"d", "e"}, {"f"}}, seeds, created, newID)
	// {a,c}:old1、old2 各一条,同样多取建立更早的 old2;{b} 拿走 old1;{d,e} 延续 old3;{f} 新开。
	want := []string{"s_old2", "s_old1", "s_old3", "s_new1"}
	if !slices.Equal(ids, want) || len(redirects) != 0 {
		t.Fatalf("ids=%v redirects=%v, want %v", ids, redirects, want)
	}
	ids, redirects = songEntityIDs([][]string{{"a", "b", "c"}}, seeds, created, newID)
	if !slices.Equal(ids, []string{"s_old1"}) || redirects["s_old2"] != "s_old1" {
		t.Errorf("合并:留共有写法最多的 old1,old2 重定向过去;ids=%v redirects=%v", ids, redirects)
	}
}

func TestSongFamilyAndCoreTitle(t *testing.T) {
	families := map[string]string{
		"Automatic (Remastered 2014)":   "automatic",
		"Bad - 2012 Remaster":           "bad",
		"那個女孩 (feat. 盧廣仲)":              "那个女孩",
		"Song (Live)":                   "songlive",
		"X - 2012 Remaster (feat. Y)":   "x",
		"Without You (With or Without)": "withoutyouwithorwithout",
	}
	for in, want := range families {
		if got := songFamilyTitle(in); got != want {
			t.Errorf("songFamilyTitle(%q) = %q, want %q", in, got, want)
		}
	}
	cores := map[string]string{
		"Ten Reasons (Live版)":          "Ten Reasons",
		"一口（The Day You Left Me）":      "一口",
		"南音 [Live 08]":                 "南音",
		"苏州河 - 慕容雪 - Mandarin Version": "苏州河",
		"(Intro)": "(Intro)",
	}
	for in, want := range cores {
		if got := songCoreTitle(in); got != want {
			t.Errorf("songCoreTitle(%q) = %q, want %q", in, got, want)
		}
	}
}

// 正文剥法跟 App 侧 EnrichTitleAliases.lyricsBody 同一口径:演唱者标签、署名行、时间戳都不算;夹带整段译文的一份按包含度认。
func TestSongLyricsBodyAndMatch(t *testing.T) {
	plain := songTestWords("duet", 30)
	labeled := make([]string, len(plain))
	for i, l := range plain {
		labeled[i] = []string{"v1：", "v2：", "合："}[i%3] + l
	}
	a := songShingles(songLyricsTokens(songLyricsBody("[00:00.10]作词 : 某人\n" + songTestLRC(1000, plain))))
	b := songShingles(songLyricsTokens(songLyricsBody(songTestLRC(1200, labeled))))
	if !songLyricsMatch(a, b) {
		t.Error("剥掉演唱者标签和署名行之后应当是同一份词")
	}
	extra := append(append([]string{}, plain...), songTestWords("translation", 40)...)
	c := songShingles(songLyricsTokens(songLyricsBody(songTestLRC(1000, extra))))
	if !songLyricsMatch(a, c) {
		t.Error("一份多出整段时按包含度认")
	}
	other := songShingles(songLyricsTokens(songLyricsBody(songTestLRC(1000, songTestWords("unrelated", 30)))))
	if songLyricsMatch(a, other) {
		t.Error("两首不同的歌不该对得上")
	}
	if !songDurationsClose(213, 213.267) || songDurationsClose(213.586, 213.7) || !songDurationsClose(213.586666, 213.586) {
		t.Error("时长闸按精度分档:整秒 0.6 秒,毫秒级 0.05 秒")
	}
}

// 加边顺序先按强弱、再按登记的顺序号:强证据的顺序号排在中证据后面也照样先加。
func TestSongEntityStrongFirstRegardlessOfOrder(t *testing.T) {
	saved := songEvidenceKinds[songIDSpotifyTrack]
	t.Cleanup(func() { songEvidenceKinds[songIDSpotifyTrack] = saved })
	k := saved
	k.order = 99
	songEvidenceKinds[songIDSpotifyTrack] = k
	TestSongEntityStrongEdgesFirst(t)
}

// 强证据只认播放器给的专辑与曲目 id:同一个 ISRC、Apple 链接配到同一张专辑的两首,照样并;Spotify 同一张专辑里
// 曲目 id 不同(播放器给的),不并。
func TestSongEntitySameAlbumVetoAgainstStrongEvidence(t *testing.T) {
	apple := func(track string) string { return "https://music.apple.com/us/album/x/1000?i=" + track }
	searched := []songVariant{
		songTestVariant("Singer|Diana|Number Ones", enrichEntry{DurationSecs: 282.06, ISRCs: []string{"USSM19909072"}, AppleURL: apple("1")}, nil),
		songTestVariant("Singer|Diana|Collection", enrichEntry{DurationSecs: 282.6, ISRCs: []string{"USSM19909072"}, AppleURL: apple("2")}, nil),
	}
	if _, of := songTestBuild(t, searched, nil); !songTestSame(of, searched[0].key, searched[1].key) {
		t.Error("检索配的 Apple 链接不该推翻 ISRC")
	}
	player := []songVariant{
		songTestVariant("Singer|Diana|A", enrichEntry{DurationSecs: 282.06, ISRCs: []string{"USSM19909072"}, SpotifyTrackID: "aaaaaaaaaaaaaaaaaaaaaa", SpotifyAlbumID: "album"}, nil),
		songTestVariant("Singer|Diana|B", enrichEntry{DurationSecs: 282.6, ISRCs: []string{"USSM19909072"}, SpotifyTrackID: "bbbbbbbbbbbbbbbbbbbbbb", SpotifyAlbumID: "album"}, nil),
	}
	if b, of := songTestBuild(t, player, nil); songTestSame(of, player[0].key, player[1].key) || len(b.vetoed) == 0 || b.vetoed[0].reason != "same_album:spotify_track" {
		t.Errorf("播放器给的同专辑不同曲目要否决: %+v", b.vetoed)
	}
}

// 只当计数用的边(跨文字、没有译名证据)不连共享组,哪怕两边歌词各自独立又对得上;E2 那条(时长按精度接近)不成立时,
// 两条只算同一首、各用各的歌词。
func TestSongEntityCountOnlyEdgeStaysOutOfShareGroup(t *testing.T) {
	words := songTestWords("cross", 30)
	ne := "https://music.163.com/song?id=77"
	reg := map[string]string{"netease_song:77": "听"}
	vs := []songVariant{
		songTestVariant("Singer|Listen|A", enrichEntry{DurationSecs: 281, NeteaseURL: ne, Lyrics: songTestLRC(1000, words), LyricsSource: "kuwo", ResolvedDurationSecs: 281}, reg),
		songTestVariant("Singer|听|B", enrichEntry{DurationSecs: 282, NeteaseURL: ne, Lyrics: songTestLRC(1000, words), LyricsSource: "kugou", ResolvedDurationSecs: 282}, reg),
	}
	b, of := songTestBuild(t, vs, nil)
	if !songTestSame(of, vs[0].key, vs[1].key) {
		t.Fatal("检索 id 连着,计数上算同一首")
	}
	if b.shareOf[0] == b.shareOf[1] {
		t.Error("只当计数用的边不连共享组")
	}
}

// 写法族边:歌手、歌名两段逐字相同(只差专辑)的单独就能连共享组;歌名逐字不同(feat. 尾巴)的要有旁证。
func TestSongEntityFamilyEdgeShare(t *testing.T) {
	same := []songVariant{
		songTestVariant("Singer|Tune|One", enrichEntry{DurationSecs: 200}, nil),
		songTestVariant("Singer|Tune|Two", enrichEntry{DurationSecs: 200.5}, nil),
	}
	if b, _ := songTestBuild(t, same, nil); b.shareOf[0] != b.shareOf[1] {
		t.Error("歌手歌名逐字相同、只差专辑(跨专辑复用同一口径),应当在同一个共享组")
	}
	tail := []songVariant{
		songTestVariant("Singer|Tune|One", enrichEntry{DurationSecs: 200}, nil),
		songTestVariant("Singer|Tune (feat. Guest)|Two", enrichEntry{DurationSecs: 200.5}, nil),
	}
	b, of := songTestBuild(t, tail, nil)
	if !songTestSame(of, tail[0].key, tail[1].key) {
		t.Fatal("写法族相同、时长对得上,算同一首")
	}
	if b.shareOf[0] == b.shareOf[1] {
		t.Error("歌名逐字不同、只靠写法族连着,没有旁证,不该进同一个共享组")
	}
}

// 时间轴错开的否决只在两边时长有差别时算:时长几乎相等(任一侧整秒时放宽到 1 秒)时是其中一份歌词错位,照并。
func TestSongEntityTimelineVetoNeedsDifferentLength(t *testing.T) {
	words := songTestWords("shift", 30)
	mk := func(dx, dy float64) []songVariant {
		return []songVariant{
			songTestVariant("Singer|Song|One", enrichEntry{DurationSecs: dx, Lyrics: songTestLRC(1000, words), LyricsSource: "kugou", ResolvedDurationSecs: dx}, nil),
			songTestVariant("Singer|Song|Two", enrichEntry{DurationSecs: dy, Lyrics: songTestLRC(6000, words), LyricsSource: "netease", ResolvedDurationSecs: dy}, nil),
		}
	}
	for _, c := range []struct {
		dx, dy float64
		same   bool
	}{
		{240.0, 240.3, true},
		{240, 240.9, true},
		{240.0, 241.5, false},
	} {
		b, of := songTestBuild(t, mk(c.dx, c.dy), nil)
		if got := songTestSame(of, "Singer|Song|One", "Singer|Song|Two"); got != c.same {
			t.Errorf("时长 %v / %v、歌词错开 5 秒:并=%v,要 %v(否决 %+v)", c.dx, c.dy, got, c.same, b.vetoed)
		}
		if !c.same && (len(b.vetoed) == 0 || b.vetoed[0].reason != "lyrics_timeline") {
			t.Errorf("时长 %v / %v:要按 lyrics_timeline 否决: %+v", c.dx, c.dy, b.vetoed)
		}
	}
}

// 专辑名带来的版次词(加长版专辑、混音 EP)在两边时长几乎相等时不算版本不一致;歌名里的版本词、时长有差别的、
// 删减版与不删减版照旧否决。
func TestSongEntityAlbumEditionTags(t *testing.T) {
	cases := []struct {
		name string
		x, y string
		dy   float64
		same bool
	}{
		{"加长版专辑收的同一轨", "Singer|Track|Heaven", "Singer|Track|Heaven (Extended)", 200.1, true},
		{"混音 EP 里的原版", "Singer|Track|Track", "Singer|Track|Track (The Remixes) - EP", 200.1, true},
		{"时长有差别", "Singer|Track|Heaven", "Singer|Track|Heaven (Extended)", 201.5, false},
		{"删减版与不删减版", "Singer|Track|Petal [Clean]", "Singer|Track|Petal [Explicit]", 200, false},
	}
	for _, c := range cases {
		vs := []songVariant{
			songTestVariant(c.x, enrichEntry{DurationSecs: 200}, nil),
			songTestVariant(c.y, enrichEntry{DurationSecs: c.dy}, nil),
		}
		b, of := songTestBuild(t, vs, nil)
		if got := songTestSame(of, c.x, c.y); got != c.same {
			t.Errorf("%s:并=%v,要 %v(否决 %+v)", c.name, got, c.same, b.vetoed)
		}
	}
	vs := []songVariant{
		songTestVariant("Singer|Track (Remix)|Heaven", enrichEntry{DurationSecs: 200, SpotifyTrackID: "abcdefghijklmnopqrstuv"}, nil),
		songTestVariant("Singer|Track|Heaven (Extended)", enrichEntry{DurationSecs: 200.1, SpotifyTrackID: "abcdefghijklmnopqrstuv"}, nil),
	}
	if b, of := songTestBuild(t, vs, nil); songTestSame(of, vs[0].key, vs[1].key) || len(b.vetoed) == 0 || b.vetoed[0].reason != "version" {
		t.Errorf("歌名里的版本词不吃版次词的例外: %+v", b.vetoed)
	}
}
