package main

import "testing"

func TestCoverDonorFits(t *testing.T) {
	r := scoredLyricCandidateResult{Source: "petitlyrics", Lyrics: "x", Title: "結び", Artist: "Ayumu Imazu", Album: "結び",
		SourceReportedDurationSecs: 207}
	d := scoredLyricCandidateResult{Source: "applemusic", Lyrics: "x", Title: "musubi", Artist: "Ayumu Imazu", Album: "musubi",
		SourceReportedDurationSecs: 207, CoverURL: "https://is1-ssl.mzstatic.com/a.jpg"}
	cases := []struct {
		name         string
		rISRC, dISRC string
		want         bool
	}{
		{"ISRC 相同(大小写不同)", "JPPO02604160", "jppo02604160", true},
		{"ISRC 不同", "JPPO02604160", "JPPO02604161", false},
		{"只有一边报 ISRC", "JPPO02604160", "", false},
		{"两边都没报", "", "", false},
	}
	for _, c := range cases {
		r.ISRC, d.ISRC = c.rISRC, c.dISRC
		if got := coverDonorFits(r, d); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
	r.ISRC, d.ISRC, d.Title, d.Album = "", "", "結び", "結び"
	if coverDonorFits(r, d) {
		t.Error("没有 ISRC 时歌名、歌手、专辑、时长全对上也不借")
	}
}

func TestApplyBorrowedCovers(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{Source: "petitlyrics", Lyrics: "x", ISRC: "JP1", BorrowedCoverURL: "stale", BorrowedCoverFrom: "old"},
		{Source: "deezer", Lyrics: "x", ISRC: "JP2", CoverURL: "dz.jpg"},
		{Source: "applemusic", Lyrics: "x", ISRC: "jp1", CoverURL: "am.jpg"},
		{Source: "qq", Lyrics: "x", ISRC: "JP1", CoverURL: "qq.jpg"},
		{Source: "lrclib", Lyrics: "x", Title: "Song", Artist: "Artist", BorrowedCoverURL: "stale"},
		{Source: "petitlyrics", Score: -1, Instrumental: true, ISRC: "JP1"},
	}
	applyBorrowedCovers(results)
	if r := results[0]; r.BorrowedCoverURL != "am.jpg" || r.BorrowedCoverFrom != "applemusic" || r.CoverURL != "" {
		t.Errorf("借排在最前、ISRC 相同的那条,自己的 CoverURL 不动: %+v", r)
	}
	if r := results[2]; r.BorrowedCoverURL != "" {
		t.Errorf("自带封面的不借: %+v", r)
	}
	if r := results[4]; r.BorrowedCoverURL != "" {
		t.Errorf("没有 ISRC 的不借,上一轮借的清掉: %+v", r)
	}
	if r := results[5]; r.BorrowedCoverURL != "" {
		t.Errorf("标记行不借: %+v", r)
	}
}
