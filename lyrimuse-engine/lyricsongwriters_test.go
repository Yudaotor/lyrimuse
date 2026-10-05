package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// appleTTMLWithSongwriters:Apple TTML 的 head 形状(取自 Music.app 缓存):<iTunesMetadata> 里先译文、后名单,名单带空白与重复。
const appleTTMLWithSongwriters = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Line" xml:lang="zh"><head><metadata><ttm:agent type="person" xml:id="v1"/><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal" leadingSilence="0.300"><translations/><songwriters><songwriter>丁世光</songwriter><songwriter> 叶喜儿 </songwriter><songwriter></songwriter><songwriter>李双周</songwriter><songwriter>丁世光</songwriter></songwriters></iTunesMetadata></metadata></head><body dur="1:00.000"><div begin="1.000" end="9.000"><p begin="1.000" end="4.000" itunes:key="L1" ttm:agent="v1">这样已经很好了吧</p></div></body></tt>`

func TestTTMLSongwriters(t *testing.T) {
	want := []string{"丁世光", "叶喜儿", "李双周"}
	r, ok := applemusicParseTTML(appleTTMLWithSongwriters)
	if !ok || !reflect.DeepEqual(r.songwriters, want) {
		t.Fatalf("Apple 解析: ok=%v songwriters=%q", ok, r.songwriters)
	}
	a, ok := parseAMLLTTMLFor(appleTTMLWithSongwriters, "zh")
	if !ok || !reflect.DeepEqual(a.songwriters, want) {
		t.Fatalf("amll 解析: ok=%v songwriters=%q", ok, a.songwriters)
	}
	plain, _ := applemusicParseTTML(appleTTMLSample)
	if plain.songwriters != nil {
		t.Fatalf("没有名单时应为 nil: %q", plain.songwriters)
	}
	am := applemusicResultFrom(applemusicSong{}, plain, false)
	if am.songwriters != nil {
		t.Fatalf("没有名单的结果: %q", am.songwriters)
	}
	am = applemusicResultFrom(applemusicSong{}, amllResult{lrc: "[00:01.00]x", songwriters: want}, false)
	if !reflect.DeepEqual(am.songwriters, want) {
		t.Fatalf("applemusicResultFrom 要带上名单: %q", am.songwriters)
	}
}

func TestSongwritersFromScored(t *testing.T) {
	apple := []string{"丁世光", "叶喜儿"}
	amll := []string{"别的写法"}
	cases := []struct {
		name   string
		scored []scoredLyricCandidateResult
		want   []string
	}{
		{"applemusic 优先于 amll", []scoredLyricCandidateResult{
			{Source: "amll", Score: 900, Songwriters: amll},
			{Source: "netease", Score: 950},
			{Source: "applemusic", Score: 10, Songwriters: apple},
		}, apple},
		{"applemusic 没过身份关时用 amll", []scoredLyricCandidateResult{
			{Source: "applemusic", Score: -1, Songwriters: apple},
			{Source: "amll", Score: 0, Songwriters: amll},
		}, amll},
		{"applemusic 没给名单时用 amll", []scoredLyricCandidateResult{
			{Source: "applemusic", Score: 800},
			{Source: "amll", Score: 700, Songwriters: amll},
		}, amll},
		{"都没有", []scoredLyricCandidateResult{{Source: "qq", Score: 900}, {Source: "amll", Score: -1, Songwriters: amll}}, nil},
	}
	for _, c := range cases {
		if got := songwritersFromScored(c.scored); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %q", c.name, got)
		}
	}
}

func TestLyricsEntryFromScoredSongwriters(t *testing.T) {
	// 胜出的是 qq,名单照样取 Apple 那条;一个能用的候选都没有时,名单也照写(它描述的是这首歌)。
	scored := []scoredLyricCandidateResult{
		{Source: "qq", Score: 900, Lyrics: "[00:01.00]hi"},
		{Source: "applemusic", Score: 600, Lyrics: "[00:01.00]hi", Songwriters: []string{"甲", "乙"}},
	}
	e, picked := lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "a", "t", "", 0, neteaseInfo{}, scored, nil, nil, true, "")
	if picked == nil || picked.Source != "qq" || !reflect.DeepEqual(e.LyricsSongwriters, []string{"甲", "乙"}) {
		t.Fatalf("picked=%v songwriters=%q", picked, e.LyricsSongwriters)
	}
	none := []scoredLyricCandidateResult{{Source: "applemusic", Score: 0, Songwriters: []string{"甲"}}}
	if e, _ := lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "a", "t", "", 0, neteaseInfo{}, none, nil, nil, true, ""); !reflect.DeepEqual(e.LyricsSongwriters, []string{"甲"}) {
		t.Fatalf("没有正文的那一轮: %q", e.LyricsSongwriters)
	}
}

func TestLyricsSongwritersSurviveIndexAndBackfill(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]x", LyricsYRC: "[1000,500](1000,500,0)x", LyricsSongwriters: []string{"甲", "乙"}}
	raw, err := e.MarshalJSON()
	if err != nil || !strings.Contains(string(raw), `"lyrics_songwriters":["甲","乙"]`) {
		t.Fatalf("落盘键名: %s err=%v", raw, err)
	}
	if lean := leanForIndex(e, 1); !reflect.DeepEqual(lean.LyricsSongwriters, e.LyricsSongwriters) {
		t.Fatalf("精简索引要留着名单: %q", lean.LyricsSongwriters)
	}
	var empty enrichEntry
	if !adoptBackfilledLyrics(&empty, e) || !reflect.DeepEqual(empty.LyricsSongwriters, e.LyricsSongwriters) {
		t.Fatalf("补外围字段收下歌词时连名单一起收: %q", empty.LyricsSongwriters)
	}
	kept := enrichEntry{LyricsSongwriters: []string{"原来的"}}
	if !adoptBackfilledLyrics(&kept, enrichEntry{Lyrics: "[00:01.00]x"}) || !reflect.DeepEqual(kept.LyricsSongwriters, []string{"原来的"}) {
		t.Fatalf("这一轮没有名单时保留原值: %q", kept.LyricsSongwriters)
	}
}

// 升级重试、重评选完歌词,作词作曲跟着这一轮的打分结果更新(选哪一份由 songwritersFromScored 定,见上面几条)。
// 这两条路要联网拿候选,这里钉的是接线。
func TestRescoreAndUpgradeWriteSongwriters(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range []string{"func retryLyricsUpgradeWith(", "func rescoreLyricsWith("} {
		body := string(src)
		i := strings.Index(body, fn)
		if i < 0 {
			t.Fatalf("找不到 %s", fn)
		}
		body = body[i+len(fn):]
		if j := strings.Index(body, "\nfunc "); j >= 0 {
			body = body[:j]
		}
		if !strings.Contains(body, "if sw := songwritersFromScored(scored); len(sw) > 0 {") || !strings.Contains(body, "e.LyricsSongwriters = sw\n") {
			t.Errorf("%s 要把打分结果里的作词作曲写回条目", fn)
		}
	}
}
