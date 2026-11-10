package main

import (
	"os"
	"strings"
	"testing"
)

func TestManualSearchFoundUsable(t *testing.T) {
	cases := []struct {
		name string
		rs   []scoredLyricCandidateResult
		want bool
	}{
		{"空", nil, false},
		{"只有判废的", []scoredLyricCandidateResult{{Source: "lrclib", Score: -1, Lyrics: "a"}}, false},
		{"有歌无词", []scoredLyricCandidateResult{{Source: "netease", Score: 0, TrackFoundNoLyrics: true}}, false},
		{"正文是空的", []scoredLyricCandidateResult{{Source: "qq", Score: 500, Lyrics: "  "}}, false},
		{"有一条能用的", []scoredLyricCandidateResult{{Source: "lrclib", Score: -1, Lyrics: "a"}, {Source: "kugou", Score: 0, Lyrics: "[00:01.00]x"}}, true},
		{"纯音乐算有结论", []scoredLyricCandidateResult{{Source: "lrclib", Score: -1, Instrumental: true}}, true},
	}
	for _, c := range cases {
		if got := manualSearchFoundUsable(c.rs); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestDurationOffRoundMarksUsable(t *testing.T) {
	in := []scoredLyricCandidateResult{
		{Source: "kugou", Score: 798, Lyrics: "[00:01.00]家乡", ScoreTerms: []scoreTerm{{Kind: scoreTermDuration, Points: 300}}, SourceReportedDurationSecs: 343},
		{Source: "lrclib", Score: -1, Lyrics: "纯文本", ScoreTerms: []scoreTerm{{Kind: scoreRejectPlainTextOnly}}},
		{Source: "netease", TrackFoundNoLyrics: true},
	}
	out := durationOffRound(in)
	if out[0].Score != -1 || len(out[0].ScoreTerms) != 1 || out[0].ScoreTerms[0].Kind != scoreRejectSourceDurationOff {
		t.Errorf("能用的那条要改判成时长不符、原因只留一条: %+v", out[0])
	}
	if out[0].SourceReportedDurationSecs != 343 || out[0].Lyrics != "[00:01.00]家乡" {
		t.Errorf("正文和源标注的时长原样带着: %+v", out[0])
	}
	if out[1].ScoreTerms[0].Kind != scoreRejectPlainTextOnly || out[2].Score != 0 || out[2].ScoreTerms != nil {
		t.Errorf("本来判废的、有歌无词的原样留着: %+v / %+v", out[1], out[2])
	}
	if in[0].Score != 798 || in[0].ScoreTerms[0].Kind != scoreTermDuration {
		t.Errorf("不改传进来的切片: %+v", in[0])
	}
}

func TestMergeDurationOffRound(t *testing.T) {
	first := []scoredLyricCandidateResult{{Source: "lrclib", Score: -1}, {Source: "kugou", Score: -1}}
	loose := []scoredLyricCandidateResult{{Source: "kugou", Score: -1, Lyrics: "loose"}, {Source: "qq", Score: -1}}
	got := mergeDurationOffRound(first, loose)
	var names []string
	for _, r := range got {
		names = append(names, r.Source)
	}
	if strings.Join(names, ",") != "kugou,qq,lrclib" || got[0].Lyrics != "loose" {
		t.Errorf("不看时长那轮在前、第一轮补上那轮没有的源、同源只留一条: %v %+v", names, got[0])
	}
}

func TestSearchCLIRetriesAtAnotherDurationWhenNothingUsable(t *testing.T) {
	src, err := os.ReadFile("searchcli.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"if effectiveDuration > 0 && !manualSearchFoundUsable(filterEnabledLyricSources(results)) {",
		"durationOffRetryUsable(m.durationSecs, effectiveDuration) {",
		"retryDuration = m.durationSecs",
		"_, loose := scoredLyricCandidatesStreaming(searchCtx, sArtist, sTitle, sAlbum, retryDuration,",
		"emit(ne, durationOffRound(rs), done, total)",
		"results = mergeDurationOffRound(results, durationOffRound(loose))",
	} {
		if !containsCode(string(src), want) {
			t.Errorf("searchcli.go 里少了 %q", want)
		}
	}
}

func TestDurationOffRetryUsable(t *testing.T) {
	if !durationOffRetryUsable(343.3, 223.27) {
		t.Error("Apple 目录 343 秒、播放器报 223 秒:换成目录那份再搜")
	}
	if durationOffRetryUsable(224, 223.27) {
		t.Error("跟播放器报的差不多:换了也是同样的结果,不换")
	}
	if durationOffRetryUsable(0, 223.27) {
		t.Error("目录里没有时长:不换,退回不带时长")
	}
}
