package main

import (
	"context"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestDeezerSongwriters(t *testing.T) {
	for _, c := range []struct {
		in   string
		want []string
	}{
		{"Daniel Kyriakides, Danny Parker, Teddy Geiger", []string{"Daniel Kyriakides", "Danny Parker", "Teddy Geiger"}},
		{" A ,, B , A ", []string{"A", "B"}},
		{"", nil},
	} {
		if got := deezerSongwriters(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("deezerSongwriters(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// 取词应答里的 writers 拆成名单进 payload。
func TestDeezerFetchLyricsSongwriters(t *testing.T) {
	withDeezerFake(t, func(c dzCall) (int, string) {
		if c.op == "SynchronizedTrackLyrics" {
			return http.StatusOK, `{"data":{"track":{"lyrics":{"text":"one\ntwo","writers":"Alex One, Sam Two",` +
				`"synchronizedLines":[{"lrcTimestamp":"[00:01.00]","milliseconds":1000,"line":"one"},{"lrcTimestamp":"[00:05.00]","milliseconds":5000,"line":"two"}]}}}}`
		}
		return 0, ""
	})
	p, err := deezerFetchLyrics(context.Background(), "123")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(p.songwriters, []string{"Alex One", "Sam Two"}) {
		t.Errorf("songwriters = %q", p.songwriters)
	}
	if !strings.Contains(deezerLyricsQuery, "\n      writers\n") {
		t.Error("取词查询里要请求 writers")
	}
}

// 走完整的收集:deezer 结果经收集通道进候选,名单不丢。
func TestFetchCarriesDeezerSongwriters(t *testing.T) {
	withDeezerFake(t, func(c dzCall) (int, string) {
		switch c.op {
		case "SearchTracks":
			return http.StatusOK, dzSearchResponse(dzHit{"2", "Hello", "Adele", "25", 295, true})
		case "SynchronizedTrackLyrics":
			return http.StatusOK, strings.Replace(dzLyricsResponse(dzSixLines...), `"lyrics":{`, `"lyrics":{"writers":"Adele Adkins",`, 1)
		}
		return 0, ""
	})
	featuresRef().LyricsSources = map[string]bool{"deezer": true}
	_, scored := fetchScoredLyricCandidatesStreaming(qqRoundCtx(), "Adele", "Hello", "25", 295, nil)
	for _, r := range scored {
		if r.Source == "deezer" {
			if !reflect.DeepEqual(r.Songwriters, []string{"Adele Adkins"}) {
				t.Fatalf("deezer 候选的名单 = %q", r.Songwriters)
			}
			return
		}
	}
	t.Fatalf("没有 deezer 候选: %+v", scored)
}

func dzSongwriterLRC(lines ...string) string {
	var b strings.Builder
	for i, l := range lines {
		b.WriteString(formatLRCTime(10000+i*4000) + l + "\n")
	}
	return b.String()
}

// Deezer 的名单排在 applemusic、amll 之后;它那份正文是中日韩文字时不用(这类歌它给的是拼音 / 罗马字);没过身份关的不用。
func TestSongwritersFromScoredDeezer(t *testing.T) {
	en := dzSongwriterLRC("I walked along the river", "and the night was cold")
	zh := dzSongwriterLRC("至少还有你", "值得我去珍惜")
	ja := dzSongwriterLRC("あの日の空を覚えている", "君と歩いた道")
	ko := dzSongwriterLRC("밤편지를 보내요", "그대에게")
	dz := []string{"Alex One", "Sam Two"}
	apple := []string{"Apple Writer"}
	for _, c := range []struct {
		name   string
		scored []scoredLyricCandidateResult
		want   []string
	}{
		{"只有 deezer、英文正文", []scoredLyricCandidateResult{{Source: "deezer", Score: 700, Lyrics: en, Songwriters: dz}}, dz},
		{"applemusic 优先", []scoredLyricCandidateResult{{Source: "deezer", Score: 900, Lyrics: en, Songwriters: dz}, {Source: "applemusic", Score: 100, Songwriters: apple}}, apple},
		{"amll 优先", []scoredLyricCandidateResult{{Source: "deezer", Score: 900, Lyrics: en, Songwriters: dz}, {Source: "amll", Score: 100, Songwriters: apple}}, apple},
		{"中文正文不用", []scoredLyricCandidateResult{{Source: "deezer", Score: 700, Lyrics: zh, Songwriters: dz}}, nil},
		{"日文正文不用", []scoredLyricCandidateResult{{Source: "deezer", Score: 700, Lyrics: ja, Songwriters: dz}}, nil},
		{"韩文正文不用", []scoredLyricCandidateResult{{Source: "deezer", Score: 700, Lyrics: ko, Songwriters: dz}}, nil},
		{"没过身份关不用", []scoredLyricCandidateResult{{Source: "deezer", Score: -1, Lyrics: en, Songwriters: dz}}, nil},
	} {
		if got := songwritersFromScored(c.scored); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// 候选装配时 deezer 的名单进结果。
func TestRankCarriesDeezerSongwriters(t *testing.T) {
	var lines []string
	for i := 0; i < 12; i++ {
		lines = append(lines, "Line number "+strconv.Itoa(i)+" goes here")
	}
	raw := map[string]lyricSourceResult{
		"deezer": {source: "deezer", lyr: dzSongwriterLRC(lines...), songwriters: []string{"Alex One"}},
	}
	scored := rankLyricSourceResults("someone", "song", "", 60, raw)
	if len(scored) == 0 || scored[0].Source != "deezer" || !reflect.DeepEqual(scored[0].Songwriters, []string{"Alex One"}) {
		t.Fatalf("deezer 的名单该进结果: %+v", scored)
	}
}

// 解析结果带上挑中那条的名单:有同步歌词时、退到纯文本时都带。
func TestResolveDeezerCarriesSongwriters(t *testing.T) {
	withWriters := func(body string) string {
		return strings.Replace(body, `"lyrics":{`, `"lyrics":{"writers":"Adele Adkins, Greg Kurstin",`, 1)
	}
	want := []string{"Adele Adkins", "Greg Kurstin"}
	t.Run("同步歌词", func(t *testing.T) {
		withDeezerFake(t, func(c dzCall) (int, string) {
			switch c.op {
			case "SearchTracks":
				return http.StatusOK, dzSearchResponse(dzHit{"2", "Hello", "Adele", "25", 295, true})
			case "SynchronizedTrackLyrics":
				return http.StatusOK, withWriters(dzLyricsResponse(dzSixLines...))
			}
			return 0, ""
		})
		r := resolveDeezerLyric(context.Background(), "Adele", "Hello", "25", 295, "")
		if r.lyrics == "" || r.plainOnly || !reflect.DeepEqual(r.songwriters, want) {
			t.Fatalf("got lyrics=%v plainOnly=%v songwriters=%q", r.lyrics != "", r.plainOnly, r.songwriters)
		}
	})
	t.Run("纯文本", func(t *testing.T) {
		withDeezerFake(t, func(c dzCall) (int, string) {
			switch c.op {
			case "SearchTracks":
				return http.StatusOK, dzSearchResponse(dzHit{"5", "Hello", "Adele", "25", 295, false})
			case "SynchronizedTrackLyrics":
				return http.StatusOK, withWriters(`{"data":{"track":{"lyrics":{"text":"plain one\nplain two","synchronizedLines":null}}}}`)
			}
			return 0, ""
		})
		r := resolveDeezerLyric(context.Background(), "Adele", "Hello", "25", 295, "")
		if !r.plainOnly || !reflect.DeepEqual(r.songwriters, want) {
			t.Fatalf("got plainOnly=%v songwriters=%q", r.plainOnly, r.songwriters)
		}
	})
}
