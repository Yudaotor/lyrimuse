package main

import "testing"

// 全角字母数字、全角空格跟半角写法一样比;全角标点在查询词里原样保留。
func TestFoldFullwidthAlnum(t *testing.T) {
	cases := map[string]string{
		"ＬＯＶＥ\u3000１２": "LOVE 12",
		"ｙｏａｓｏｂｉ":      "yoasobi",
		"夜に駆ける（Ｌｉｖｅ）":  "夜に駆ける（Live）",
		"周杰伦":          "周杰伦",
		"":             "",
	}
	for in, want := range cases {
		if got := foldFullwidthAlnum(in); got != want {
			t.Errorf("foldFullwidthAlnum(%q) = %q, want %q", in, got, want)
		}
	}
}

// 本地标签是全角(日系标签常见)时,半角写法的候选照样过标题闸、对得上歌手。
func TestFullwidthTagsMatchHalfwidthCandidates(t *testing.T) {
	if normLoose("ＬＯＶＥ １２") != normLoose("Love 12") {
		t.Errorf("normLoose 全角 / 半角该相等: %q vs %q", normLoose("ＬＯＶＥ １２"), normLoose("Love 12"))
	}
	if !lyricTitleAccepted("LOVE", "ＬＯＶＥ") {
		t.Error("半角候选该过全角本地标题的标题闸")
	}
	for _, tc := range []struct{ local, candidate string }{
		{"Ｙｏａｓｏｂｉ", "YOASOBI"},
		{"DAOKO＆米津玄師", "米津玄師"},
		{"Kanye West; Jay-Z", "Jay-Z"},
		{"Kanye West；Jay-Z", "Kanye West"},
		{"Ａ／Ｂ", "B"},
	} {
		if !artistMatches(tc.local, tc.candidate) {
			t.Errorf("artistMatches(%q, %q) 该对上", tc.local, tc.candidate)
		}
	}
	if artistMatches("DAOKO＆米津玄師", "米津") {
		t.Error("拆开之后仍按整段比,半个名字不该对上")
	}
}

// 发给各源的查询词:全角字母数字换成半角,全角括号这类标点原样。
func TestSearchQueryFieldsFoldsFullwidthAlnum(t *testing.T) {
	a, ti, al := searchQueryFields("ＹＯＡＳＯＢＩ", "夜に駆ける（Ｌｉｖｅ）", "ＴＨＥ ＢＯＯＫ")
	if a != "YOASOBI" || ti != "夜に駆ける（Live）" || al != "THE BOOK" {
		t.Errorf("searchQueryFields = %q / %q / %q", a, ti, al)
	}
}
