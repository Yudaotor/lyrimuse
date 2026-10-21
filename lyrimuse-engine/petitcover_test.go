package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

// petitTestSongISRC:petitTestSong 再带一个 <isrc>。
func petitTestSongISRC(isrc, id, title, artist, album string, durMs int, lyricsType, official, data string) string {
	s := petitTestSong(id, title, artist, album, durMs, lyricsType, official, data)
	return strings.Replace(s, "<lyricsType>", "<isrc>"+isrc+"</isrc><lyricsType>", 1)
}

// withPetitCoverFake:换掉按 ISRC 取录音的那一步,记下问过哪些 ISRC。
func withPetitCoverFake(t *testing.T, tracks map[string]deezerTrack) *[]string {
	t.Helper()
	var asked []string
	saved := petitCoverByISRC
	petitCoverByISRC = func(_ context.Context, isrc string) (deezerTrack, bool) {
		asked = append(asked, isrc)
		tr, ok := tracks[isrc]
		return tr, ok
	}
	t.Cleanup(func() { petitCoverByISRC = saved })
	return &asked
}

func withPetitSongs(t *testing.T, songs ...string) {
	t.Helper()
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		_ = r.ParseForm()
		if r.Form.Get("key_lyricsId") != "" {
			return http.StatusOK, petitTestResponse(songs[0])
		}
		return http.StatusOK, petitTestResponse(songs...)
	})
}

func petitDzTrack(artist, title string, durSecs int) deezerTrack {
	t := dzTrack(artist, title, "結び", "https://cdn-images.dzcdn.net/images/cover/aa/1000x1000-000000-80-0-0.jpg")
	t.Duration = durSecs
	return t
}

func TestResolvePetitLyricCoverByISRC(t *testing.T) {
	asked := withPetitCoverFake(t, map[string]deezerTrack{"JPPO02604160": petitDzTrack("Ayumu Imazu", "musubi", 207)})
	withPetitSongs(t, petitTestSongISRC("JPPO02604160", "1", "結び", "Ayumu Imazu", "結び", 206998, "3", "1", petitTestSync))
	r := resolvePetitLyric(qqRoundCtx(), "Ayumu Imazu", "結び", "結び", 207)
	if r.lyrics == "" || r.isrc != "JPPO02604160" {
		t.Fatalf("歌词和 ISRC 应带回: %+v", r)
	}
	if r.cover != "https://cdn-images.dzcdn.net/images/cover/aa/1800x1800-000000-80-0-0.jpg" {
		t.Errorf("封面取 Deezer 那条录音的原图档: %q", r.cover)
	}
	if len(*asked) != 1 {
		t.Errorf("一首只问一次: %v", *asked)
	}
}

func TestResolvePetitLyricCoverRejected(t *testing.T) {
	cases := []struct {
		name  string
		track deezerTrack
	}{
		{"歌手、曲名都对不上", petitDzTrack("Someone Else", "Another Song", 207)},
		{"时长差太多", petitDzTrack("Ayumu Imazu", "musubi", 260)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withPetitCoverFake(t, map[string]deezerTrack{"JPPO02604160": c.track})
			withPetitSongs(t, petitTestSongISRC("JPPO02604160", "1", "結び", "Ayumu Imazu", "結び", 206998, "3", "1", petitTestSync))
			r := resolvePetitLyric(qqRoundCtx(), "Ayumu Imazu", "結び", "結び", 207)
			if r.lyrics == "" || r.cover != "" {
				t.Errorf("歌词照常、不带封面: lyrics=%v cover=%q", r.lyrics != "", r.cover)
			}
		})
	}
}

func TestResolvePetitLyricCoverSkipped(t *testing.T) {
	t.Run("没有 ISRC 不问", func(t *testing.T) {
		asked := withPetitCoverFake(t, nil)
		withPetitSongs(t, petitTestSong("1", "結び", "Ayumu Imazu", "結び", 206998, "3", "1", petitTestSync))
		if r := resolvePetitLyric(qqRoundCtx(), "Ayumu Imazu", "結び", "結び", 207); r.lyrics == "" || r.cover != "" || len(*asked) != 0 {
			t.Errorf("cover=%q asked=%v", r.cover, *asked)
		}
	})
	t.Run("Deezer 源关着不问", func(t *testing.T) {
		saved := features()
		defer func() { setFeatures(saved) }()
		featuresRef().LyricsSources = map[string]bool{"petitlyrics": true, "deezer": false}
		asked := withPetitCoverFake(t, map[string]deezerTrack{"JPPO02604160": petitDzTrack("Ayumu Imazu", "musubi", 207)})
		withPetitSongs(t, petitTestSongISRC("JPPO02604160", "1", "結び", "Ayumu Imazu", "結び", 206998, "3", "1", petitTestSync))
		if r := resolvePetitLyric(qqRoundCtx(), "Ayumu Imazu", "結び", "結び", 207); r.lyrics == "" || r.cover != "" || len(*asked) != 0 {
			t.Errorf("cover=%q asked=%v", r.cover, *asked)
		}
	})
	t.Run("选中的那份 ISRC 不是查的那个", func(t *testing.T) {
		withPetitCoverFake(t, map[string]deezerTrack{"AAA000000001": petitDzTrack("Ayumu Imazu", "musubi", 207)})
		withPetitFake(t, func(r *http.Request, target string) (int, string) {
			_ = r.ParseForm()
			if r.Form.Get("key_lyricsId") != "" {
				return http.StatusOK, petitTestResponse(petitTestSongISRC("BBB000000002", "2", "結び", "Ayumu Imazu", "結び", 206998, "3", "1", petitTestSync))
			}
			return http.StatusOK, petitTestResponse(
				petitTestSongISRC("AAA000000001", "1", "結び", "Ayumu Imazu", "結び", 206998, "1", "1", "plain"),
				petitTestSongISRC("BBB000000002", "2", "結び", "Ayumu Imazu", "結び", 206998, "3", "0", ""),
			)
		})
		if r := resolvePetitLyric(qqRoundCtx(), "Ayumu Imazu", "結び", "結び", 207); r.lyrics == "" || r.isrc != "BBB000000002" || r.cover != "" {
			t.Errorf("lyrics=%v isrc=%q cover=%q", r.lyrics != "", r.isrc, r.cover)
		}
	})
}

// 封面、ISRC 装进候选,跟别的源一样当这条候选自带的封面。
func TestRankLyricSourceResultsPetitCover(t *testing.T) {
	var lines [][]petitTestWord
	for i := 0; i < 20; i++ {
		lines = append(lines, petitChars((10+i*10)*1000, 300, "歌詞の一行"))
	}
	lrc, yrc := petitBuildLyrics(petitTestWSY(lines...))
	for _, c := range rankLyricSourceResults("Artist", "Song", "", 220, map[string]lyricSourceResult{
		"petitlyrics": {source: "petitlyrics", lyr: lrc, yrc: yrc, srcDur: 220, matchTitle: "Song", matchArtist: "Artist",
			matchCover: "https://cdn-images.dzcdn.net/images/cover/aa/1800x1800-000000-80-0-0.jpg", isrc: "JPPO02604160"},
	}) {
		if c.Source == "petitlyrics" {
			if c.CoverURL == "" || c.ISRC != "JPPO02604160" || c.BorrowedCoverURL != "" {
				t.Errorf("候选应带自己的封面和 ISRC: %+v", c)
			}
			return
		}
	}
	t.Fatal("没有 petitlyrics 候选")
}
