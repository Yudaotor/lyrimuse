package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// 决策记录的三条铁律之一"只存元数据,绝不存歌词正文"在结构上就成立(候选结构体没有
// 歌词字段),这里用序列化结果再钉一道:哪天有人往 lyricsDecisionCandidate 里加正文
// 字段,这个测试当场红。
func TestBuildLyricsDecisionOmitsLyricsText(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: "SECRET_LYRICS_BODY", Score: 525,
			ScoreTerms: []scoreTerm{{Kind: scoreTermDuration, Points: 300}},
			Title:      "悟空", Artist: "戴荃", Album: "悟空"},
		{Source: "lrclib", Lyrics: "ANOTHER_BODY", Score: 83},
	}
	d := buildLyricsDecision("first-resolve", "戴荃", "悟空", "悟空", 289.5, scored, &scored[0], true)
	blob, err := json.Marshal(d)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(blob), "SECRET_LYRICS_BODY") || strings.Contains(string(blob), "ANOTHER_BODY") {
		t.Fatalf("决策记录里带上了歌词正文 —— 缓存文件会因此翻倍: %s", blob)
	}
	if d.Winner != "netease" || !d.Applied {
		t.Fatalf("winner/applied 不对: %+v", d)
	}
	if len(d.Candidates) != 2 || d.Candidates[0].Score != 525 {
		t.Fatalf("候选表不完整: %+v", d.Candidates)
	}
}

// "回了烂候选"和"超时没露面"必须分得开:被判负分的源要出现在 SourcesResponded 和
// 候选表里(带着它的 reject 原因),这正是这份记录要回答的第一问。
func TestBuildLyricsDecisionKeepsRejectedCandidates(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "qq", Score: 482, Title: "某歌"},
		{Source: "kugou", Score: -1,
			ScoreTerms: []scoreTerm{{Kind: "rejectNotTimed", Points: 0}}},
	}
	d := buildLyricsDecision("upgrade", "a", "t", "", 200, scored, &scored[0], false)
	if len(d.SourcesResponded) != 2 {
		t.Fatalf("负分候选的源没算进应答清单: %v", d.SourcesResponded)
	}
	if len(d.Candidates) != 2 || d.Candidates[1].Score != -1 ||
		len(d.Candidates[1].ScoreTerms) != 1 {
		t.Fatalf("被拒候选(及其原因)没保留: %+v", d.Candidates)
	}
	if d.Applied {
		t.Fatal("这一轮明明维持现状,Applied 却是 true —— 记录语义见 decision.go")
	}
	if d.Winner != "qq" {
		t.Fatalf("winner = %q", d.Winner)
	}
}

// 没选出任何可用候选:Winner 留空、候选表照样全量保留 —— "为什么这首歌没歌词"
// 跟"为什么选了这份歌词"同样需要证据。
func TestBuildLyricsDecisionNoWinner(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "lrclib", Score: -1, Instrumental: true},
	}
	d := buildLyricsDecision("first-resolve", "a", "t", "", 0, scored, nil, false)
	if d.Winner != "" || d.Applied {
		t.Fatalf("无胜者时 winner/applied 应为空/false: %+v", d)
	}
	if len(d.Candidates) != 1 || !d.Candidates[0].Instrumental {
		t.Fatalf("纯音乐标记没保留: %+v", d.Candidates)
	}
}
