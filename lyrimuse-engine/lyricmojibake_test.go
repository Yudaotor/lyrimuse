package main

import (
	"os"
	"strings"
	"testing"
)

func TestRepairLyricMojibake(t *testing.T) {
	cases := []struct{ in, want string }{
		{"And you bad youâ€™re a different animal", "And you bad you’re a different animal"},
		{"Pâ€¦", "P…"},
		{"Veja o sol dessa manhÃ£ tÃo cinza", "Veja o sol dessa manhã tÃo cinza"},
		{"cafÃ© crÃ¨me", "café crème"},
		{"â€œquotedâ€\u009d", "“quoted”"},
		{"PoznaÅ„", "Poznań"},
		// 还原出来不是字母或常用标点的不动
		{"Ha, ha, ha Â¨C **", "Ha, ha, ha Â¨C **"},
		// 正常西文、带重音的大写字母后面跟标点,都不动
		{"Mötley Crüe", "Mötley Crüe"},
		{"Sigur Rós – Þú", "Sigur Rós – Þú"},
		{"naïve café, Ça va", "naïve café, Ça va"},
		{"SÃO PAULO, MÃE", "SÃO PAULO, MÃE"},
		{"«Ça»", "«Ça»"},
		{"é»…", "é»…"},
		{"ß»", "ß»"},
		{"FRANÇ»", "FRANÇ»"},
		// 后续字节不够数的不动
		{"â€", "â€"},
		{"晴天", "晴天"},
		{"", ""},
	}
	for _, c := range cases {
		if got := repairLyricMojibake(c.in); got != c.want {
			t.Errorf("repairLyricMojibake(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLyricTextGarbled(t *testing.T) {
	garbled := []string{
		"Jusqu'?pr�ent",
		"他们随波逐流 �非我辈",
		"Somos tÃo jovens",
		"Ha, ha, ha Â¨C **",
		"youâ€™re",
		"manhÃ£",
	}
	for _, s := range garbled {
		if !lyricTextGarbled(s) {
			t.Errorf("lyricTextGarbled(%q) = false, want true", s)
		}
	}
	clean := []string{
		"SÃO PAULO", "Mötley Crüe", "naïve café", "Ça va", "Âme", "Hãy Trao Cho Anh", "tão", "晴天", "",
		"âme sœur", "Ã",
	}
	for _, s := range clean {
		if lyricTextGarbled(s) {
			t.Errorf("lyricTextGarbled(%q) = true, want false", s)
		}
	}
}

func TestLyricBodyGarbledIgnoresCreditLines(t *testing.T) {
	credits := "[00:00.00]作词 : Mla�\n[00:01.00]作曲 : Calico�\n[00:10.00]Je t'aime pour toujours\n"
	if lyricBodyGarbled(credits) {
		t.Fatal("只有署名行有乱码,不该算正文有乱码")
	}
	body := "[00:00.00]作词 : Mla\n[00:10.00]Jusqu'?pr�ent\n"
	if !lyricBodyGarbled(body) {
		t.Fatal("正文行有替换字符,该算有乱码")
	}
	if lyricBodyGarbled("Jusqu'?pr�ent") {
		t.Fatal("没有时间戳的行不参与")
	}
}

func garbledBatch() []scoredLyricCandidateResult {
	return []scoredLyricCandidateResult{
		{Source: "netease", Score: 1030, Lyrics: "[00:10.00]Jusqu'?pr�ent\n[00:20.00]et � pour toujours\n"},
		{Source: "qq", Score: 890, Lyrics: "[00:10.00]Jusqu'à présent\n[00:20.00]et à pour toujours\n"},
		{Source: "lrclib", Score: 588, Lyrics: "[00:10.00]Jusqu'à présent\n"},
	}
}

func TestApplyGarbledTextPenaltyHandsCrownToCleanCandidate(t *testing.T) {
	results := garbledBatch()
	applyGarbledTextPenalty(results)
	if results[0].Score != 1030-garbledTextPenalty {
		t.Fatalf("乱码候选该扣 %d 分,得到 %d", garbledTextPenalty, results[0].Score)
	}
	if scoreTermPoints(results[0].ScoreTerms, scoreTermGarbledText) != -garbledTextPenalty {
		t.Fatalf("乱码候选该记一条 garbledText,得到 %v", results[0].ScoreTerms)
	}
	for _, r := range results[1:] {
		if r.Score != map[string]int{"qq": 890, "lrclib": 588}[r.Source] || len(r.ScoreTerms) != 0 {
			t.Fatalf("干净候选不该动: %+v", r)
		}
	}
}

func TestApplyGarbledTextPenaltyKeepsBatchWhenNoCleanWinner(t *testing.T) {
	only := garbledBatch()[:1]
	applyGarbledTextPenalty(only)
	if only[0].Score != 1030 || len(only[0].ScoreTerms) != 0 {
		t.Fatalf("只有这一家时不扣: %+v", only[0])
	}

	allBad := garbledBatch()
	allBad[1].Lyrics = "[00:10.00]Somos tÃo jovens\n"
	allBad[2].Lyrics = "[00:10.00]Somos tÃo jovens\n"
	applyGarbledTextPenalty(allBad)
	for _, r := range allBad {
		if len(r.ScoreTerms) != 0 {
			t.Fatalf("家家都坏时整批不动: %+v", r)
		}
	}

	// 判废的乱码候选不参与:扣分会把 -1 夹底成 1,等于让它复活
	revived := garbledBatch()
	revived = append(revived, scoredLyricCandidateResult{Source: "migu", Score: -1, Lyrics: "[00:10.00]Somos tÃo jovens\n"})
	applyGarbledTextPenalty(revived)
	if revived[3].Score != -1 || len(revived[3].ScoreTerms) != 0 {
		t.Fatalf("判废的候选不该被扣分改写: %+v", revived[3])
	}

	// 干净候选判废了(负分)也不算接得住
	rejected := garbledBatch()[:2]
	rejected[1].Score = -1
	applyGarbledTextPenalty(rejected)
	if rejected[0].Score != 1030 {
		t.Fatalf("干净的那份判废时不扣: %+v", rejected[0])
	}
}

func TestApplyGarbledTextPenaltyNeedsWinnerAfterPenalty(t *testing.T) {
	// 扣完 430 仍高于干净的 100:第一名还是乱码那份,整批不动
	results := garbledBatch()
	results[1].Score = 100
	results[2].Score = 90
	applyGarbledTextPenalty(results)
	if results[0].Score != 1030 || len(results[0].ScoreTerms) != 0 {
		t.Fatalf("扣完第一名还是乱码那份时该整批撤销: %+v", results[0])
	}
}

func TestEarlyLyricsRejectsGarbledBody(t *testing.T) {
	c := &scoredLyricCandidateResult{Source: "netease", Score: 1030, Lyrics: "[00:10.00]Jusqu'?pr�ent\n",
		ScoreTerms: []scoreTerm{{Kind: scoreTermTitleMatch, Points: titleMatchFullPoints}}}
	if earlyLyricsAcceptable(c) {
		t.Fatal("正文有乱码的不提前上屏")
	}
	c.Lyrics = "[00:10.00]Jusqu'à présent\n"
	if !earlyLyricsAcceptable(c) {
		t.Fatal("同一份换成干净正文该能提前上屏")
	}
}

func TestDecodeLyricSourceResultRepairsMojibake(t *testing.T) {
	r := decodeLyricSourceResultEntities(lyricSourceResult{lyr: "[00:01.00]youâ€™re\r\n", tr: "[00:01.00]Iâ€™m"})
	if r.lyr != "[00:01.00]you’re\n" || r.tr != "[00:01.00]I’m" {
		t.Fatalf("源应答清洗该还原乱码: %q / %q", r.lyr, r.tr)
	}
}

// 两条流水线都要接(位置由 TestTimelineIntrusionWiredIntoBothPipelines 一起钉着)。
func TestGarbledTextPenaltyWiredIntoBothPipelines(t *testing.T) {
	raw, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(raw), "applyGarbledTextPenalty("); n != 2 {
		t.Fatalf("enrich.go 里要有两处调用(rankLyricSourceResults 与 mergeLyricCandidateRounds),得到 %d", n)
	}
}
