package main

import (
	"bytes"
	"encoding/json"
	"log"
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

// 决策摘要日志。存在的理由见 logLyricsDecision 的注释:缓存里那份会被覆盖、trace 默认
// 关着,"这首歌的歌词为什么是这一份"此前在 lyrimuse.log 里根本查不到。
func TestLogLyricsDecisionLine(t *testing.T) {
	capture := func(fn func()) string {
		var buf bytes.Buffer
		prev := log.Writer()
		log.SetOutput(&buf)
		defer log.SetOutput(prev)
		fn()
		return buf.String()
	}

	t.Run("选出了胜者", func(t *testing.T) {
		// 故意乱序放,日志那一行要按分数降序列出来。
		scored := []scoredLyricCandidateResult{
			{Source: "lrclib", Lyrics: "SECRET_BODY_A", Score: 83},
			{Source: "kugou", Lyrics: "SECRET_BODY_B", Score: 910},
			{Source: "qq", Lyrics: "SECRET_BODY_C", Score: 402},
		}
		out := capture(func() {
			buildLyricsDecision(lyricsDecisionPathFirstResolve, "戴荃", "悟空", "悟空", 289.5, scored, &scored[1], true)
		})

		for _, want := range []string{
			// 断言消息本身而不是 `msg="lyrics decision"`:测试里 slog 用的是默认 handler
			// (`INFO lyrics decision ...`),生产走 logsink 的 TextHandler 才带 msg=。
			"lyrics decision", "path=first-resolve", "winner=kugou", "score=910", "applied=true",
			// 降序,而且要含被判负分/低分的那些 —— "为什么没选第二名"全靠这一段。
			`candidates="kugou:910 qq:402 lrclib:83"`,
		} {
			if !strings.Contains(out, want) {
				t.Errorf("决策日志缺 %s,实际: %q", want, out)
			}
		}
		// 跟决策记录本身同一条铁律:绝不带歌词正文。日志比缓存更容易被贴进 issue。
		for _, leak := range []string{"SECRET_BODY_A", "SECRET_BODY_B", "SECRET_BODY_C"} {
			if strings.Contains(out, leak) {
				t.Errorf("决策日志里漏出了歌词正文 %s: %q", leak, out)
			}
		}
	})

	t.Run("一个候选都没选出", func(t *testing.T) {
		out := capture(func() {
			buildLyricsDecision(lyricsDecisionPathRefill, "a", "t", "", 0, nil, nil, false)
		})
		// 没胜者时要明确写出来,不能留空 —— 空值在 key=value 里读起来像是字段丢了。
		if !strings.Contains(out, "winner=(none)") || !strings.Contains(out, "applied=false") {
			t.Errorf("没选出候选时的决策日志不对: %q", out)
		}
	})

	t.Run("胜者走的是标题反查", func(t *testing.T) {
		scored := []scoredLyricCandidateResult{
			{Source: "netease", Score: 500, RetryMethod: "title-reverse", RetriedTitle: "春雷"},
		}
		out := capture(func() {
			buildLyricsDecision(lyricsDecisionPathUpgrade, "DAOKO", "打上花火", "", 0, scored, &scored[0], true)
		})
		// 歌词张冠李戴多半出在反查轮,来路必须带上。
		if !strings.Contains(out, "retry_method=title-reverse") || !strings.Contains(out, "corrected_title=春雷") {
			t.Errorf("胜者的反查来路没进日志: %q", out)
		}
	})

	t.Run("候选过多时折叠", func(t *testing.T) {
		var scored []scoredLyricCandidateResult
		for i := 0; i < lyricsDecisionLogMaxCandidates+5; i++ {
			scored = append(scored, scoredLyricCandidateResult{Source: "kugou", Score: 100 - i})
		}
		out := capture(func() {
			buildLyricsDecision(lyricsDecisionPathRescore, "a", "t", "", 0, scored, &scored[0], true)
		})
		// 别名轮会给同一个源带回好几条,不封顶单行能冲到几百字节。
		if !strings.Contains(out, "+5") {
			t.Errorf("候选超过 %d 条时该折叠成 +N: %q", lyricsDecisionLogMaxCandidates, out)
		}
	})
}
