package main

import (
	"os"
	"strings"
	"testing"
)

const (
	isrcRefSong = "[00:10.00]清晨的风吹过窗台 我在等一封信到来\n[00:20.00]街角的灯亮了又灭\n" +
		"[00:30.00]你说过的话还留在耳边\n[00:40.00]等到雨停了再出发\n"
	isrcRefSongTrad = "[00:11.20]清晨的風吹過窗台我在等一封信到來\n[00:21.40]街角的燈亮了又滅\n" +
		"[00:31.10]你說過的話還留在耳邊\n[00:41.00]等到雨停了再出發\n"
	isrcRefOther = "[00:10.00]我们都在找一个答案 却总是绕回原点\n[00:20.00]车站的人群散了又聚\n" +
		"[00:30.00]谁也没有回头看一眼\n[00:40.00]明天的事明天再说\n"
)

// 按 ISRC 补来的候选:正文跟前面几轮哪条已认可的候选都对不上的挑出去,对得上的(繁简、时间戳不同照样算)留下。
func TestISRCRetryReferenceFilter(t *testing.T) {
	base := []scoredLyricCandidateResult{
		{Source: "applemusic", Score: 520, Lyrics: isrcRefSong},
		{Source: "kugou", Score: -1, Lyrics: isrcRefOther},
	}
	ref := newISRCRetryReference(base)
	extra := []scoredLyricCandidateResult{
		{Source: "musixmatch", Score: 213, Title: "Morning Wind", Lyrics: isrcRefSongTrad},
		{Source: "deezer", Score: 300, Title: "另一首", Lyrics: isrcRefOther},
		{Source: "amll", Score: 100, Lyrics: "[00:01.00]短句"},
		{Source: "lrclib", Score: -1, Instrumental: true},
		{Source: "qq", Score: -1, TrackFoundNoLyrics: true},
	}
	kept, dropped := ref.filter(extra)
	var keptSrc []string
	for _, r := range kept {
		keptSrc = append(keptSrc, r.Source)
	}
	if strings.Join(keptSrc, ",") != "musixmatch,amll,lrclib,qq" {
		t.Errorf("留下的该是正文对得上的、太短没法比的和两种标记,got %v", keptSrc)
	}
	if len(dropped) != 1 || dropped[0].Source != "deezer" {
		t.Errorf("该挑出去的只有正文对不上的 deezer,got %+v", dropped)
	}
	// 判废的 kugou 不拿来作证:它的正文跟 deezer 一样,deezer 照样被挑出去。
	if s, ok := ref.similarity(extra[1]); !ok || s >= lyricConsensusSimThreshold {
		t.Errorf("deezer 跟已认可候选的相似度该低于门槛,got %.2f %v", s, ok)
	}
}

// 只有一半对得上的正文也挑出去:门槛跟跨源共识同一个。
func TestISRCRetryReferenceUsesConsensusThreshold(t *testing.T) {
	ref := newISRCRetryReference([]scoredLyricCandidateResult{{Source: "applemusic", Score: 520, Lyrics: isrcRefSong}})
	half := "[00:10.00]清晨的风吹过窗台 我在等一封信到来\n[00:20.00]街角的灯亮了又灭\n" +
		"[00:30.00]谁也没有回头看一眼\n[00:40.00]明天的事明天再说\n"
	r := scoredLyricCandidateResult{Source: "musixmatch", Score: 300, Lyrics: half}
	if s, ok := ref.similarity(r); !ok || s < 0.2 || s >= lyricConsensusSimThreshold {
		t.Fatalf("这份正文该是一半对得上,got %.2f %v", s, ok)
	}
	if _, dropped := ref.filter([]scoredLyricCandidateResult{r}); len(dropped) != 1 {
		t.Errorf("低于共识门槛的该挑出去")
	}
}

// 前面几轮没有正文够长的已认可候选时,补来的候选一条不动。
func TestISRCRetryReferenceWithoutEvidenceKeepsAll(t *testing.T) {
	for _, base := range [][]scoredLyricCandidateResult{
		nil,
		{{Source: "applemusic", Score: 520, Lyrics: "[00:01.00]短句"}},
		{{Source: "applemusic", Score: -1, Lyrics: isrcRefSong}},
		{{Source: "lrclib", Score: -1, Instrumental: true}},
	} {
		ref := newISRCRetryReference(base)
		kept, dropped := ref.filter([]scoredLyricCandidateResult{{Source: "deezer", Score: 300, Lyrics: isrcRefOther}})
		if len(kept) != 1 || len(dropped) != 0 {
			t.Errorf("base=%+v:没有能作证的候选时该原样收下,kept=%d dropped=%d", base, len(kept), len(dropped))
		}
	}
}

// 前面几轮里任何一条已认可的候选都能作证,不限于报 ISRC 的那条 Apple Music 候选。
func TestISRCRetryReferenceAnyAcceptedSourceCounts(t *testing.T) {
	ref := newISRCRetryReference([]scoredLyricCandidateResult{
		{Source: "netease", Score: 900, Lyrics: isrcRefSong},
		{Source: "applemusic", Score: 520, Lyrics: isrcRefOther},
	})
	kept, dropped := ref.filter([]scoredLyricCandidateResult{{Source: "musixmatch", Score: 400, Lyrics: isrcRefSongTrad}})
	if len(kept) != 1 || len(dropped) != 0 {
		t.Errorf("跟网易云那条对得上就该留下,kept=%d dropped=%d", len(kept), len(dropped))
	}
}

// 补取那一轮的最终结果和中途推给界面的结果都先过 isrcRetryReference。
func TestISRCRetryReferenceIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, n := range []string{
		"ref := newISRCRetryReference(results)",
		"kept, _ := ref.filter(vres)",
		"isrcResults, dropped := ref.filter(isrcResults)",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}
