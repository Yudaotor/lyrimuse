package main

import (
	"context"
	"slices"
	"testing"
	"time"
)

func TestAppleNamesDue(t *testing.T) {
	now := time.Unix(2_000_000_000, 0)
	link := func(id string) enrichEntry {
		return enrichEntry{AppleURL: "https://music.apple.com/cn/album/x/1?i=" + id}
	}
	entries := map[string]enrichEntry{"a": link("30"), "b": link("10"), "c": link("10"), "d": link("20"), "e": {}, "f": link("50"),
		"g": {PlayerSongIDs: map[string]string{appleMusicBundleID: "40"}}}
	have := map[string]appleCatalogNames{
		"20": {Checked: now.Add(-time.Hour).Unix(), Rated: true},
		"30": {Checked: now.Add(-appleNamesRecheck - time.Hour).Unix(), Rated: true},
		"50": {Checked: now.Add(-time.Hour).Unix()},
	}
	if got := appleNamesDue(entries, have, now); !slices.Equal(got, []string{"10", "30", "40", "50"}) {
		t.Errorf("没问过的、过期的、问的时候还没带删减标记的要问,Apple Music 报的 id 也问,刚问过的不问,同一个 id 只问一次: %v", got)
	}
}

func TestFetchAppleNames(t *testing.T) {
	var ids []string
	for i := range 650 {
		ids = append(ids, string(rune('a'+i%26))+time.Duration(i).String())
	}
	var calls []int
	failCN := map[int]bool{1: true}
	batchNo := -1
	fetch := func(_ context.Context, sf string, batch []string) (map[string]appleCatalogSong, bool) {
		calls = append(calls, len(batch))
		if sf == "us" {
			batchNo++
		}
		if sf == "cn" && failCN[batchNo] {
			return nil, false
		}
		out := map[string]appleCatalogSong{}
		for _, id := range batch[:len(batch)-1] {
			out[id] = appleCatalogSong{title: sf + "-" + id, artist: "A", audioLocale: "zxx", durationSecs: 100}
			if sf != "us" {
				out[id] = appleCatalogSong{title: sf + "-" + id, artist: "A", audioLocale: "zxx", durationSecs: 100, contentRating: "explicit-" + sf}
			}
		}
		return out, true
	}
	have := map[string]appleCatalogNames{}
	now := time.Unix(2_000_000_000, 0)
	saves := 0
	requests, complete := fetchAppleNames(context.Background(), ids, have, now, 0, 0, fetch, func() { saves++ })
	for _, n := range calls {
		if n > appleNamesBatch {
			t.Fatalf("一次最多 %d 个 id,这次带了 %d 个", appleNamesBatch, n)
		}
	}
	if requests != len(calls) || requests != 3+2+3+3 || !complete {
		t.Errorf("三批:第二批中国区没问成,整批等一下重问;都问完了:requests=%d calls=%v complete=%v", requests, calls, complete)
	}
	if _, ok := have[ids[300]]; !ok {
		t.Error("重问成了的那一批记下")
	}
	if saves != 0 {
		t.Errorf("不满 %d 批不落盘(收尾那次由调用方写): %d", catalogSweepSaveEvery, saves)
	}
	rec, ok := have[ids[0]]
	if !ok || rec.Names["tw"].Name != "tw-"+ids[0] || rec.AudioLocale != "zxx" || rec.DurationSecs != 100 || rec.Checked != now.Unix() ||
		rec.ContentRating != "explicit-cn" || !rec.Rated {
		t.Errorf("三个区的名字、audioLocale、时长、问的时刻、头一个有的删减标记都记下: %+v", rec)
	}
	if rec, ok := have[ids[299]]; !ok || len(rec.Names) != 0 {
		t.Errorf("哪个区都没有的也记成问过,名字为空: %+v %v", rec, ok)
	}
}

func songNamesTestBuild(t *testing.T, vs []songVariant, names map[string]appleCatalogNames) map[string]string {
	t.Helper()
	attachAppleNames(vs, names)
	_, of := songTestBuild(t, vs, nil)
	return of
}

// 名字边:Apple 链接核对过的写法,某个区的名字跟另一条写法对得上、两边时长都知道且接近,并成一首。
func TestSongEntityAppleNameEdges(t *testing.T) {
	apple := "https://music.apple.com/cn/album/x/1?i=777"
	names := map[string]appleCatalogNames{"777": {DurationSecs: 241, AudioLocale: "zh-Hans-CN", Names: map[string]appleCatalogName{
		"us": {Name: "Oasis", Artist: "Khalil Fong"}, "cn": {Name: "那沙漠里的水", Artist: "方大同"},
	}}}
	zh := func() songVariant {
		return songTestVariant("方大同|那沙漠里的水|梦想家", enrichEntry{DurationSecs: 241.2, AppleURL: apple}, nil)
	}
	of := songNamesTestBuild(t, []songVariant{zh(), songTestVariant("Khalil Fong|Oasis|The Dreamer", enrichEntry{DurationSecs: 241.5}, nil)}, names)
	if !songTestSame(of, "方大同|那沙漠里的水|梦想家", "Khalil Fong|Oasis|The Dreamer") {
		t.Error("美区名字对上英文写法,应当并成一首")
	}
	for name, other := range map[string]songVariant{
		"时长差过闸":   songTestVariant("Khalil Fong|Oasis|The Dreamer", enrichEntry{DurationSecs: 250}, nil),
		"没有时长":    songTestVariant("Khalil Fong|Oasis|The Dreamer", enrichEntry{}, nil),
		"歌手对不上":   songTestVariant("Someone Else|Oasis|X", enrichEntry{DurationSecs: 241.5}, nil),
		"歌名不是同一族": songTestVariant("Khalil Fong|Oasis (Live)|X", enrichEntry{DurationSecs: 241.5}, nil),
	} {
		of := songNamesTestBuild(t, []songVariant{zh(), other}, names)
		if songTestSame(of, "方大同|那沙漠里的水|梦想家", other.key) {
			t.Errorf("%s,不该并", name)
		}
	}
}

// 挂名字之前核对链接:时长对不上、没有哪个区的歌名跟写法同一个写法族(带版本尾巴那一版)、歌手对不上的,都不挂。
func TestAttachAppleNamesVerifiesLink(t *testing.T) {
	apple := "https://music.apple.com/us/album/x/1?i=888"
	mk := func(title string, secs float64) []songVariant {
		return []songVariant{songTestVariant("Michael Jackson|"+title+"|Off the Wall", enrichEntry{DurationSecs: secs, AppleURL: apple}, nil)}
	}
	rec := func(name, artist string, secs float64) map[string]appleCatalogNames {
		return map[string]appleCatalogNames{"888": {DurationSecs: secs, AudioLocale: "en-US", Names: map[string]appleCatalogName{"us": {Name: name, Artist: artist}}}}
	}
	cases := []struct {
		name  string
		vs    []songVariant
		names map[string]appleCatalogNames
		want  bool
	}{
		{"对得上", mk("Rock With You", 220), rec("Rock with You", "Michael Jackson", 220.4), true},
		{"时长对不上", mk("Rock With You", 220), rec("Rock with You", "Michael Jackson", 230), false},
		{"链接配到带版本尾巴的那一版", mk("Rock With You", 220), rec("Rock with You (Single Version)", "Michael Jackson", 220.4), false},
		{"歌手对不上", mk("Rock With You", 220), rec("Rock with You", "Someone Else", 220.4), false},
	}
	for _, c := range cases {
		attachAppleNames(c.vs, c.names)
		if got := len(c.vs[0].catalogNames) > 0 && c.vs[0].audioLocale == "en-US"; got != c.want {
			t.Errorf("%s: 挂上=%v,应为 %v", c.name, got, c.want)
		}
	}
}

// 只凭 audioLocale 判的没有人声:对面也是按 audioLocale 判的有人声时否决,对面只凭配到的歌词判有人声时不否决。
func TestSongEntityLocaleVocalsVeto(t *testing.T) {
	lyrics := songTestLRC(1000, songTestWords("v", 12))
	mk := func(key, locale string, e enrichEntry) songVariant {
		v := songTestVariant(key, e, nil)
		v.audioLocale = locale
		return v
	}
	none := mk("A|Intro|X", "zxx", enrichEntry{DurationSecs: 192})
	byLocale := mk("A|Intro|Y", "zh-Hans-CN", enrichEntry{DurationSecs: 192})
	byLyrics := mk("A|Intro|Z", "", enrichEntry{DurationSecs: 192, Lyrics: lyrics, ResolvedDurationSecs: 192})
	if r := songPairVeto(&none, &byLocale, true, nil); r != "vocals" {
		t.Errorf("zxx 对 audioLocale 有人声要否决,得到 %q", r)
	}
	if r := songPairVeto(&none, &byLyrics, true, nil); r == "vocals" {
		t.Error("zxx 对只凭歌词判的有人声不否决")
	}
	flagged := mk("A|Intro (伴奏)|W", "", enrichEntry{DurationSecs: 192})
	if r := songPairVeto(&flagged, &byLyrics, true, nil); r != "vocals" && r != "version" {
		t.Errorf("伴奏版本词那一边照旧否决,得到 %q", r)
	}
}

// 检索 id 连着的一中一外两条写法:登记歌名对不上外文那条时原来只当计数用;外文那条挂着核对过的 Apple 名字、其中一个区
// 跟登记歌名对得上时,不再只当计数用。
func TestSongRegisteredViaAppleNames(t *testing.T) {
	netease := "https://music.163.com/song?id=4242"
	edge := func(withNames bool) *songEdge {
		vs := []songVariant{
			songTestVariant("方大同|那沙漠里的水|梦想家", enrichEntry{DurationSecs: 161, NeteaseURL: netease},
				map[string]string{"netease_song:4242": "那沙漠里的水"}),
			songTestVariant("方大同|Oasis|The Dreamer", enrichEntry{DurationSecs: 161.2, NeteaseURL: netease,
				AppleURL: "https://music.apple.com/us/album/x/1?i=99"}, nil),
		}
		names := map[string]appleCatalogNames{}
		if withNames {
			names["99"] = appleCatalogNames{DurationSecs: 161.2, Names: map[string]appleCatalogName{
				"us": {Name: "Oasis", Artist: "方大同"}, "cn": {Name: "那沙漠里的水", Artist: "方大同"}}}
		}
		attachAppleNames(vs, names)
		b, _ := songTestBuild(t, vs, nil)
		for i := range b.edges {
			if b.edges[i].kind == songIDNeteaseSong {
				return &b.edges[i]
			}
		}
		return nil
	}
	if e := edge(false); e == nil || !e.countOnly {
		t.Fatalf("没有 Apple 名字时一中一外只当计数用: %+v", e)
	}
	if e := edge(true); e == nil || e.countOnly {
		t.Errorf("外文那条的 Apple 名字有一个区跟登记歌名对得上,不该只当计数用: %+v", e)
	}
}

// Spotify 演唱语言:有 zxx 记 zxx、否则记第一个,覆盖 Apple 挂的;读不到的照旧;没有 Spotify 曲目 id 的不动。
func TestAttachSpotifyLanguages(t *testing.T) {
	sp := func(id, locale string) songVariant {
		v := songTestVariant("A|"+id+"|X", enrichEntry{SpotifyTrackID: id}, nil)
		v.audioLocale = locale
		return v
	}
	vs := []songVariant{
		sp("0000000000000000000001", "en-US"),
		sp("0000000000000000000002", "en-US"),
		sp("0000000000000000000003", "en-US"),
		songTestVariant("A|NoSpotify|X", enrichEntry{}, nil),
	}
	vs[3].audioLocale = "ja"
	langs := map[string][]string{
		"0000000000000000000001": {"en", "zxx"},
		"0000000000000000000002": {"ja"},
	}
	attachSpotifyLanguages(vs, func(id string) []string { return langs[id] })
	want := []string{"zxx", "ja", "en-US", "ja"}
	for i, v := range vs {
		if v.audioLocale != want[i] {
			t.Errorf("#%d audioLocale=%q,应为 %q", i, v.audioLocale, want[i])
		}
	}
}

// 目录名字补扫连续 catalogSweepMaxFailures 次没问成就停(断网、token 失效、一直被限流),不把剩下的批次一口气空转完;每问成
// catalogSweepSaveEvery 批落一次盘。
func TestFetchAppleNamesStopsAfterFailures(t *testing.T) {
	ids := make([]string, appleNamesBatch*(catalogSweepSaveEvery+3))
	for i := range ids {
		ids[i] = time.Duration(i + 1).String()
	}
	calls, saves := 0, 0
	fail := false
	fetch := func(_ context.Context, sf string, batch []string) (map[string]appleCatalogSong, bool) {
		calls++
		return map[string]appleCatalogSong{}, !fail
	}
	have := map[string]appleCatalogNames{}
	now := time.Unix(2_000_000_000, 0)
	if _, complete := fetchAppleNames(context.Background(), ids, have, now, 0, 0, fetch, func() { saves++ }); !complete || saves != 1 {
		t.Fatalf("都问成:complete=%v saves=%d", complete, saves)
	}
	clear(have)
	calls, fail = 0, true
	requests, complete := fetchAppleNames(context.Background(), ids, have, now, 0, 0, fetch, func() {})
	if complete || requests != catalogSweepMaxFailures || calls != catalogSweepMaxFailures || len(have) != 0 {
		t.Errorf("一直没问成:第一批问 %d 次就停: requests=%d calls=%d complete=%v", catalogSweepMaxFailures, requests, calls, complete)
	}
}
