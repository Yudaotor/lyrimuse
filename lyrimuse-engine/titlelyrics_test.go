package main

import (
	"context"
	"net/http"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestLyricSearchQueries(t *testing.T) {
	sample := "[ti:烦]\n[00:00.00]烦 (Explicit) - 方大同\n[00:08.37]词：方大同\n[00:16.75]曲：方大同\n" +
		"[00:25.12]今天看电视告诉我\n[00:27.81]这回谁死谁拼了\n[00:30.00]能不能给我一点安静 逃难\n" +
		"[01:05.41](那么烦 烦 烦 烦)\n[01:08.06]<01:08.06>我好<01:09.00>烦我太烦了\n[01:10.00]今天看电视告诉我\n[01:12.00]最后这句被截"
	got := lyricSearchQueries([]string{sample})
	want := []string{"能不能给我一点安静 逃难", "今天看电视告诉我"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("字多的在前、最多两句: %q", got)
	}
	all := lyricSearchQueries([]string{sample, sample})
	if !reflect.DeepEqual(all, want) {
		t.Errorf("同一句只取一次: %q", all)
	}
	if got := lyricSearchQueries([]string{"[00:01.00]作词：方大同 作曲：方大同 编曲：方大同\n[00:02.00]短句\n[00:03.00](全在括号里的和声和声)\n[00:04.00]末尾"}); len(got) != 0 {
		t.Errorf("署名行(再长也不算)、短句、括号里的和声都不拿去搜: %q", got)
	}
	inline := lyricSearchQueries([]string{"[00:01.00]<00:01.00>我好<00:02.00>烦我太烦了啊\n[00:05.00]末尾"})
	if len(inline) != 1 || inline[0] != "我好烦我太烦了啊" {
		t.Errorf("逐字时间标签去掉: %q", inline)
	}
}

func TestRetryTitleFromLyricSearch(t *testing.T) {
	samples := []string{"[00:25.12]今天看电视告诉我\n[00:27.81]这回谁死谁拼了\n[00:29.93]谁犯了法谁醉了"}
	reply := ""
	withNeteaseFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/api/search/get") {
			return http.StatusOK, reply
		}
		return http.StatusNotFound, ""
	})
	song := func(name string, ms int, artist string) string {
		return `{"name":"` + name + `","duration":` + strconv.Itoa(ms) + `,"artists":[{"name":"` + artist + `"}]}`
	}
	cases := []struct {
		name    string
		songs   []string
		artists []string
		title   string
		artist  string
	}{
		{"同一首收在两张专辑里不算分不出", []string{song("烦", 282780, "方大同"), song("烦", 282780, "方大同"), song("歌手与模特儿", 221706, "方大同")},
			[]string{"Khalil Fong", "方大同"}, "烦", "方大同"},
		{"歌手对不上(翻唱)不给", []string{song("烦", 282780, "别的歌手")}, []string{"Khalil Fong", "方大同"}, "", ""},
		{"时长差出容差不给", []string{song("烦 (Live)", 290000, "方大同")}, []string{"方大同"}, "", ""},
		{"两首不同的歌一样近不猜", []string{song("烦", 282780, "方大同"), song("黑夜", 282900, "方大同")}, []string{"方大同"}, "", ""},
		{"歌手对得上的排到第六才对上时长,不认", []string{song("一", 100000, "方大同"), song("二", 110000, "方大同"), song("三", 120000, "方大同"),
			song("四", 130000, "方大同"), song("五", 140000, "方大同"), song("烦", 282780, "方大同")}, []string{"方大同"}, "", ""},
	}
	for _, c := range cases {
		reply = `{"code":200,"result":{"songs":[` + strings.Join(c.songs, ",") + `]}}`
		title, artist, _, ok := retryTitleFromLyricSearchDetailed(context.Background(), c.artists, samples, 282.78)
		if title != c.title || artist != c.artist || ok != (c.title != "") {
			t.Errorf("%s: title=%q artist=%q ok=%v", c.name, title, artist, ok)
		}
	}
	if _, _, _, ok := retryTitleFromLyricSearchDetailed(context.Background(), []string{"方大同"}, nil, 282.78); ok {
		t.Error("没有歌词样本就不搜")
	}
}

// 第四条路接在前三条都落空之后,来路记成 title-from-lyrics;按歌词搜用的是 type=1006。
func TestTitleReverseLyricSearchIsWired(t *testing.T) {
	src, err := os.ReadFile("titlereverse.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	if !strings.Contains(s, "\tdefault:\n\t\tvar lyricArtist string\n\t\tif lyricTitle, lyricArtist, lyricDiff, lyricOK = retryTitleFromLyricSearchDetailed(ctx, titleArtists, samples, durationSecs); lyricOK {\n\t\t\tcorrectedTitle, retryMethod, titleArtist = lyricTitle, lyricQueryReasonTitleLyrics, lyricArtist") {
		t.Error("标题反查的 switch 末尾(前三条都没查到)走按歌词搜")
	}
	lyr, err := os.ReadFile("titlelyrics.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(lyr), "neteaseSongSearch(ctx, neteaseSearchTypeLyric, 10, q)") || neteaseSearchTypeLyric != 1006 {
		t.Error("按歌词搜用网易云的 type=1006")
	}
}
