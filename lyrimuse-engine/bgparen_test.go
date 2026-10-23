package main

import (
	"regexp"
	"strings"
	"testing"
)

func TestParenBGLine(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"Kills me slowly (slowly)", "Kills me slowly"},
		{"(Yeah) Pray it away", "Pray it away"},
		{"Me pregunto cómo estás (estás), qué haces y dónde estás (estás)", "Me pregunto cómo estás, qué haces y dónde estás"},
		{"This is (this is) the part", "This is the part"},
		{"全世界都跳起來（跳起來）", "全世界都跳起來"},
		{"问天地（问苍穹）", "问天地"},
		{"v1：She really that A-list girl (A-list girl)", "v1：She really that A-list girl"},
		{"（Hot Space）...Let's go !", "...Let's go !"},
	} {
		got, _, ok := parenBGLine(c.in, false)
		if !ok || got != c.want {
			t.Errorf("%q: got %q ok=%v, want %q", c.in, got, ok, c.want)
		}
	}
	for _, in := range []string{
		"(Ho-o-oh, ho-o-oh)",                         // 整行
		"(男)他们告诉我爱是个恶魔",                              // 演唱者
		"（春）又何必在乎那些",                                 // 行首短名字
		"Oooooo (repeat)", "Ooh ooh (2x)", "Be (x9)", // 重复次数
		"Einstein(愛因斯坦) Freud(浮來得)", // 注释
		"相変わらず脱皮してる毎日(bling bling)", // 带假名的行紧贴
		"雪花飘（国）", "林峯-原罪（粤）",        // 标题
		"New Power Generation (Pt. 2)-Prince",
		"Training Season (Live from the Royal Albert Hall) - Dua Lipa",
		"制作 by enjoy music 宝鸿妮(黄怡/陈子鸿/戴佩妮)",
		"Check clear, money ready by 5:00 (by 5:00)",
		"Laugh (ha)ha", "Oh (yeah", "a (b (c)) d", "Part (2)", "Love (Explicit)",
		"[kana:1よる1な(5564,160)よ]",
		"Thanks to you (Anna/Bob) forever",                          // 人名清单
		"Alena Omargalieva – Мужчина (Man)",                         // 长破折号的标题行
		"Mastered by Randy Merrill at Sterling Sound (New York NY)", // 英文署名行
		"© 2020 TASRM Publishing (BMI)",
		"（阿杜） 我们一起走",                    // 行首短名字,后面隔着空格
		"梦里花开（电影插曲）",                    // 中文版本标注
		"君の願いは彼岸（悲願）",                   // 带假名的行,同种文字紧贴(读音注释)
		"Wake up (wake up)-Artist Name", // 右括号后紧跟「-」
		"林峯-原罪（来吧）",                     // 「-」紧挨中日韩字
		"监制 张三（李四）",                     // 中文职务词
	} {
		if got, _, ok := parenBGLine(in, false); ok {
			t.Errorf("%q 不该拆: %q", in, got)
		}
	}
	if _, _, ok := parenBGLine("你呈給我的只有謊言(yeah)", false); ok {
		t.Error("正文里紧贴、换了文字的不拆")
	}
	if got, _, ok := parenBGLine("你呈給我的只有謊言(yeah)", true); !ok || got != "你呈給我的只有謊言" {
		t.Errorf("译文里紧贴也拆: %q %v", got, ok)
	}
}

func TestParenBGYRCLine(t *testing.T) {
	for _, c := range []struct{ name, in, main, bg string }{
		{"网易云:括号单独成零时长词条",
			"[78050,1960](78050,220,0)Ooh(78270,0,0), (78270,120,0)you're (78390,360,0)so (78750,480,0)sweet (79230,0,0)（(79230,330,0)So (79560,450,0)sweet(80010,0,0)）",
			"[78050,1960](78050,220,0)Ooh(78270,0,0), (78270,120,0)you're (78390,360,0)so (78750,480,0)sweet",
			"[78050,1960](79230,330,0)So (79560,450,0)sweet"},
		{"Musixmatch:右括号后的标点并回主句、两段各去括号",
			"[29180,4132](29180,42,0)I'm (29222,50,0)not (29272,260,0)breathing (29532,55,0)(I'm (29587,55,0)not (29642,996,0)breathing), (30638,786,0)slowly (31424,586,0)bleeding (32010,1302,0)(bleeding)",
			"[29180,4132](29180,42,0)I'm (29222,50,0)not (29272,260,0)breathing, (30638,786,0)slowly (31424,586,0)bleeding",
			"[29180,4132](29532,55,0)I'm (29587,55,0)not (29642,996,0)breathing (32010,1302,0)bleeding"},
		{"右括号后面单独一个标点词条",
			"[60150,4470](60150,390,0)girl (61470,0,0)（(61470,1320,0)I'm (62790,300,0)that (63090,420,0)girl(63510,0,0)）(63510,0,0), (63510,180,0)it's",
			"[60150,4470](60150,390,0)girl(63510,0,0), (63510,180,0)it's",
			"[60150,4470](61470,1320,0)I'm (62790,300,0)that (63090,420,0)girl"},
		{"左括号粘在主句词条末尾(QQ / 酷狗)",
			"[0,1200](0,300,0)Double (300,300,0)the (600,300,0)hype ((900,300,0)Right)",
			"[0,1200](0,300,0)Double (300,300,0)the (600,300,0)hype",
			"[0,1200](900,300,0)Right"},
		{"左括号紧贴主句词条、行中,后面的空格补回主句",
			"[0,1500](0,300,0)Turn (300,300,0)now((600,300,0)loud) (900,300,0)and (1200,300,0)go",
			"[0,1500](0,300,0)Turn (300,300,0)now (900,300,0)and (1200,300,0)go",
			"[0,1500](600,300,0)loud"},
		{"左括号紧贴主句词条,右括号后的标点并回这个词条",
			"[0,1500](0,300,0)Turn (300,300,0)now((600,300,0)loud), (900,300,0)and (1200,300,0)go",
			"[0,1500](0,300,0)Turn (300,300,0)now, (900,300,0)and (1200,300,0)go",
			"[0,1500](600,300,0)loud"},
		{"中文,左括号粘在词条末尾",
			"[0,1200](0,300,0)给(300,300,0)我（(600,300,0)为何(900,300,0)尊敬）",
			"[0,1200](0,300,0)给(300,300,0)我",
			"[0,1200](600,300,0)为何(900,300,0)尊敬"},
		{"行首",
			"[1000,900](1000,300,0)(Yeah) (1300,300,0)Pray (1600,300,0)away",
			"[1000,900](1300,300,0)Pray (1600,300,0)away",
			"[1000,900](1000,300,0)Yeah"},
	} {
		main, bg, _, _, ok := parenBGYRCLine(c.in)
		if !ok || main != c.main || bg != c.bg {
			t.Errorf("%s:\n got main %q\n     bg   %q ok=%v\nwant main %q\n     bg   %q", c.name, main, bg, ok, c.main, c.bg)
		}
	}
	for _, in := range []string{
		"[0,1000](0,500,0)sweet(So (500,500,0)sweet)",               // 左括号在词条中间、后面还有字
		"[0,1000](0,300,0)Laugh (300,300,0)(ha)(600,400,0)ha",       // 右括号后紧跟字(规则那一层就拒)
		"[0,1000](0,300,0)Laugh (300,300,0)(ha)ha (600,400,0)yes",   // 同一词条里右括号后还有字
		"[0,600](0,300,0)(Ho-o-oh, (300,300,0)ho)",                  // 整行
		"[0,900](0,300,0)Kill (300,300,0)(so), yeah (600,300,0)now", // 同一词条里右括号后还有字
	} {
		if main, bg, _, _, ok := parenBGYRCLine(in); ok {
			t.Errorf("%q 不该拆: %q / %q", in, main, bg)
		}
	}
}

// parenBGYRCPlain:逐字一行的纯文本(去掉行头与词条时间),否定断言要在纯文本上判,词条之间的子串跨不过时间标记。
func parenBGYRCPlain(yrc string) string {
	return regexp.MustCompile(`\[\d+,\d+\]|\(\d+,\d+,\d+\)`).ReplaceAllString(yrc, "")
}

func TestSplitParenBackground(t *testing.T) {
	lrc := "[00:01.00]Kills me slowly (slowly)\n[00:05.00]No parens here"
	yrc := yrcLine(1000, "Kills me slowly (slowly)") + "\n" + yrcLine(5000, "No parens here")
	sp, ok := splitParenBackground(lrc, yrc)
	if !ok {
		t.Fatal("没拆")
	}
	if sp.lrc != "[00:01.00]Kills me slowly\n[00:05.00]No parens here" {
		t.Errorf("lrc = %q", sp.lrc)
	}
	if strings.Contains(parenBGYRCPlain(sp.yrc), "(slowly") || !strings.HasPrefix(sp.yrc, "[1000,800]") ||
		!strings.HasSuffix(sp.yrc, yrcLine(5000, "No parens here")) {
		t.Errorf("yrc = %q", sp.yrc)
	}
	if sp.bg != "[1000,800](1600,200,0)slowly\n" {
		t.Errorf("bg = %q", sp.bg)
	}
	if len(sp.stamps) != 1 || !sp.stamps[1000] {
		t.Errorf("stamps = %v", sp.stamps)
	}
	if _, again := splitParenBackground(sp.lrc, sp.yrc); again {
		t.Error("拆过的再拆一遍应当没有变化")
	}

	// 压缩写法的一行带两个时间戳:两遍逐字都配上才拆,只配上一遍整行不动。
	multi := "[00:01.00][00:10.00]Kills me (me)"
	both := yrcLine(1000, "Kills me (me)") + "\n" + yrcLine(10000, "Kills me (me)")
	if sp, ok := splitParenBackground(multi, both); !ok || sp.lrc != "[00:01.00][00:10.00]Kills me" || strings.Count(sp.bg, "\n") != 2 {
		t.Errorf("两个时间戳都配上: %+v %v", sp, ok)
	}
	if _, ok := splitParenBackground(multi, yrcLine(1000, "Kills me (me)")); ok {
		t.Error("只配上一个时间戳不该拆")
	}
	for name, y := range map[string]string{
		"逐字没有括号段(QQ 那样删掉了和声)": yrcLine(1000, "Kills me slowly"),
		"两边括号里的字不一样":          yrcLine(1000, "Kills me slowly (softly)"),
		"时间差太远":               yrcLine(1000+parenBGPairToleranceMs+1, "Kills me slowly (slowly)"),
	} {
		if _, ok := splitParenBackground("[00:01.00]Kills me slowly (slowly)", y); ok {
			t.Errorf("%s 不该拆", name)
		}
	}
	if _, ok := splitParenBackground(lrc, ""); ok {
		t.Error("没有逐字不拆")
	}
	// 两行逐字的行首挤在背景人声挂行的容差里:拆出来会挂错行,这两行都不拆,别的行照拆。
	crowdLRC := "[00:01.00]3D (woo)\n[00:01.00]You know how I like it, girl (girl)\n[00:05.00]Kills me (me)"
	crowdYRC := yrcLine(1000, "3D (woo)") + "\n" + yrcLine(1020, "You know how I like it, girl (girl)") + "\n" + yrcLine(5000, "Kills me (me)")
	if sp, ok := splitParenBackground(crowdLRC, crowdYRC); !ok || strings.Count(sp.bg, "\n") != 1 || !strings.HasPrefix(sp.bg, "[5000,") ||
		!strings.Contains(sp.lrc, "3D (woo)") || !strings.Contains(sp.lrc, "girl (girl)") {
		t.Errorf("行首挤在一起的不拆: %+v %v", sp, ok)
	}
}

func TestStripParenBackgroundAux(t *testing.T) {
	stamps := map[int]bool{1000: true, 10000: true}
	tr := "[00:01.00]你呈給我的只有謊言(yeah)\n[00:05.00]如此犹豫（总是微笑）\n[00:10.00]（整行都是）\n[00:01.00][00:20.00]一半（配上）"
	want := "[00:01.00]你呈給我的只有謊言\n[00:05.00]如此犹豫（总是微笑）\n[00:10.00]（整行都是）\n[00:01.00][00:20.00]一半（配上）"
	if got := stripParenBackgroundAux(tr, stamps); got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
	if got := stripParenBackgroundAux(tr, nil); got != tr {
		t.Errorf("没有拆过的行不动: %q", got)
	}
}

func TestParenBGCandidates(t *testing.T) {
	lines := []string{"Kills me slowly (slowly)", "No parens here", "Pray it away (away)"}
	var lrc, yrc []string
	for i, l := range lines {
		ms := 2000 + 4000*i
		lrc = append(lrc, lrcTimestamp(ms)+l)
		yrc = append(yrc, yrcLine(ms, l))
	}
	check := func(t *testing.T, scored []scoredLyricCandidateResult) {
		t.Helper()
		for _, r := range scored {
			if r.Source != "kugou" {
				continue
			}
			if strings.Contains(r.Lyrics, "(") || strings.Contains(parenBGYRCPlain(r.LyricsYRC), "(") {
				t.Errorf("正文 / 逐字里还有括号段: %q / %q", r.Lyrics, r.LyricsYRC)
			}
			if strings.Count(r.LyricsBG, "\n") != 2 || !strings.Contains(r.LyricsBG, "slowly") || !strings.Contains(r.LyricsBG, "away") {
				t.Errorf("背景人声 = %q", r.LyricsBG)
			}
			if !backgroundAlignsWithLyrics(r.LyricsBG, r.LyricsYRC, r.Lyrics) {
				t.Errorf("背景人声挂不上主句: %q", r.LyricsBG)
			}
			return
		}
		t.Fatalf("结果里没有酷狗: %+v", scored)
	}
	raw := map[string]lyricSourceResult{"kugou": {source: "kugou", lyr: strings.Join(lrc, "\n"), yrc: strings.Join(yrc, "\n")}}
	t.Run("rankLyricSourceResults", func(t *testing.T) {
		check(t, rankLyricSourceResults("Somebody", "Slowly", "", 185, raw))
	})
	t.Run("mergeLyricCandidateRounds", func(t *testing.T) {
		base := []scoredLyricCandidateResult{{Source: "kugou", Lyrics: strings.Join(lrc, "\n"), LyricsYRC: strings.Join(yrc, "\n"), HasWordTiming: true, Score: 900}}
		check(t, mergeLyricCandidateRounds("Somebody", "Slowly", "", 185, base, nil))
	})
	t.Run("合并轮已经拆过的不再动", func(t *testing.T) {
		first := rankLyricSourceResults("Somebody", "Slowly", "", 185, raw)
		check(t, mergeLyricCandidateRounds("Somebody", "Slowly", "", 185, first, nil))
	})
	t.Run("amll 不拆", func(t *testing.T) {
		cands := []lyricCandidate{{source: "amll", lyrics: strings.Join(lrc, "\n"), wordTimingYRC: strings.Join(yrc, "\n")}}
		splitCandidateParenBackground(cands)
		if cands[0].parenBG != "" || !strings.Contains(cands[0].lyrics, "(slowly)") {
			t.Errorf("amll 被拆了: %+v", cands[0])
		}
	})
}

func TestMigrateParenBackground(t *testing.T) {
	lrc := "[00:01.00]Kills me slowly (slowly)\n[00:05.00]No parens here"
	yrc := yrcLine(1000, "Kills me slowly (slowly)") + "\n" + yrcLine(5000, "No parens here")
	tr := "[00:01.00]慢慢杀死我（慢慢）\n[00:05.00]这里没有括号"
	withEnrichCache(t, map[string]enrichEntry{
		"a|split|":    {LyricsSource: "netease", Lyrics: bt(lrc), LyricsYRC: bt(yrc), LyricsTr: bt(tr)},
		"b|manual|":   {LyricsSource: "netease", Lyrics: bt(lrc), LyricsYRC: bt(yrc), ManualLyrics: true},
		"c|apple|":    {LyricsSource: "applemusic", Lyrics: bt(lrc), LyricsYRC: bt(yrc)},
		"d|has-bg|":   {LyricsSource: "netease", Lyrics: bt(lrc), LyricsYRC: bt(yrc), LyricsBG: bt("[5000,600](5400,200,0)here\n")},
		"e|no-yrc|":   {LyricsSource: "netease", Lyrics: bt(lrc)},
		"f|speakers|": {LyricsSource: "musixmatch", Lyrics: bt(lrc), LyricsYRC: bt(yrc), LyricsSpeakers: &lyricSpeakers{For: lyricSpeakersFingerprint(lrc, yrc), LRC: []string{"v1", "v2"}}},
		"g|picked|":   {LyricsSource: "qq", Lyrics: bt(lrc), LyricsYRC: bt(yrc), ManualPickSHA: manualPickFingerprint(lrc)},
		"h|instr|":    {LyricsSource: "qq", Lyrics: bt(lrc), LyricsYRC: bt(yrc), Instrumental: true},
		"i|local|":    {LyricsSource: localFileLyricsSource, Lyrics: bt(lrc), LyricsYRC: bt(yrc)},
	})
	enrichMu.Lock()
	savedPath, savedDirty := enrichPath, enrichDirty
	enrichPath = "" // 不落盘
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichPath, enrichDirty = savedPath, savedDirty
		enrichMu.Unlock()
	})
	migrateParenBackground()
	a := enrichCache["a|split|"]
	if !a.Lyrics.EqualString("[00:01.00]Kills me slowly\n[00:05.00]No parens here") || a.LyricsBG.IsZero() ||
		!a.LyricsTr.EqualString("[00:01.00]慢慢杀死我\n[00:05.00]这里没有括号") || strings.Contains(parenBGYRCPlain(a.LyricsYRC.String()), "(") {
		t.Errorf("存量没拆: %+v", a)
	}
	for _, k := range []string{"b|manual|", "c|apple|", "e|no-yrc|", "h|instr|", "i|local|"} {
		if e := enrichCache[k]; !e.Lyrics.EqualString(lrc) {
			t.Errorf("%s 不该动: %q", k, e.Lyrics)
		}
	}
	if e := enrichCache["d|has-bg|"]; !e.Lyrics.EqualString("[00:01.00]Kills me slowly\n[00:05.00]No parens here") ||
		!e.LyricsBG.EqualString("[1000,800](1600,200,0)slowly\n[5000,600](5400,200,0)here\n") {
		t.Errorf("已有背景人声的,剩下的括号行拆出来按行头并进去: %q / %q", e.Lyrics, e.LyricsBG)
	}
	if e := enrichCache["f|speakers|"]; e.LyricsSpeakers.For != lyricSpeakersFingerprint(e.Lyrics.String(), e.LyricsYRC.String()) ||
		strings.Join(e.LyricsSpeakers.LRC, ",") != "v1,v2" {
		t.Errorf("对唱标注的指纹要跟着换: %+v", e.LyricsSpeakers)
	}
	if e := enrichCache["g|picked|"]; e.ManualPickSHA != manualPickFingerprint(e.Lyrics.String()) || e.Lyrics.EqualString(lrc) {
		t.Errorf("原样采纳的指纹要跟着换: %+v", e)
	}
}

// 正文的括号背景人声拆走以后,Musixmatch 演唱者标注片段里还带着它,去掉括号里的字照样定位得上。
func TestMusixmatchLineOwnersAfterParenSplit(t *testing.T) {
	lines := []string{"It's whatever, it's whatever", "Next line"}
	spans := []musixmatchPerformerSpan{
		{text: "It's whatever (whatever), it's whatever", performers: []string{"mxm:artist:1"}},
		{text: "(uh-huh)\nNext line", performers: []string{"mxm:artist:2"}},
	}
	owners := musixmatchLineOwners(lines, spans)
	if speakerLineKey(owners[0]) != "mxm:artist:1" || speakerLineKey(owners[1]) != "mxm:artist:2" {
		t.Errorf("owners = %v / %v", speakerLineKey(owners[0]), speakerLineKey(owners[1]))
	}
}
