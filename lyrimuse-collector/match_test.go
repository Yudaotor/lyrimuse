package main

import (
	"strings"
	"testing"
)

// 固定样本回归测试——覆盖 2026-08-04 实测坐实的网易云"纯音乐曲目返回一份看着正常的
// 完整制作人员名单、每行都带真实时间戳"这个坑:isTimedLRC 会认为它是可用的逐行 LRC
// (行数够、时间戳密度够),旧版 creditLineRe 只手工枚举了"作词/作曲/编曲/制作人/演唱/
// 混音/录音"几个词,指挥/贝斯/中提琴/吉他/大提琴/母带工程师这类角色名统统漏判,导致
// 一份纯制作人员名单被当成真歌词打分、进而可能被选中显示。样本里的角色名/人名全是
// 虚构占位,不是任何真实曲目的制作人员名单或歌词原文,只用来复现"短中文标签+冒号"这个
// 结构本身。
func TestIsCreditOnlyLRC(t *testing.T) {
	cases := []struct {
		name string
		lrc  string
		want bool
	}{
		{
			name: "完整虚构制作人员名单,角色名远超旧版枚举词表",
			lrc: "[00:00.00]作曲: 甲\n" +
				"[00:01.00]制作人: 乙\n" +
				"[00:02.00]指挥: 丙\n" +
				"[00:03.00]混音师: 丁\n" +
				"[00:04.00]贝斯: 戊\n" +
				"[00:05.00]中提琴: 己\n" +
				"[00:06.00]吉他: 庚\n" +
				"[00:07.00]大提琴: 辛\n" +
				"[04:35.19]母带工程师: 壬",
			want: true,
		},
		{
			name: "网易云纯音乐占位文案本身也应该被识别",
			lrc: "[00:00.00]作曲: 甲\n" +
				"[00:01.00]纯音乐，请欣赏\n" +
				"[04:00.00]制作人: 乙",
			want: true,
		},
		{
			name: "旧版枚举关键词表仍然覆盖(英文写法)",
			lrc: "[00:00.00]composed by: 甲\n" +
				"[04:00.00]produced by: 乙",
			want: true,
		},
		{
			name: "真正的歌词正文不应该被误伤(非职员表结构,行数达标)",
			lrc: "[00:00.00]作词: 甲\n" +
				"[00:10.00]占位歌词行一二三四五六\n" +
				"[00:20.00]占位歌词行七八九十十一\n" +
				"[00:30.00]占位歌词行十二十三十四十五",
			want: false,
		},
	}
	for _, c := range cases {
		if got := isCreditOnlyLRC(c.lrc); got != c.want {
			t.Errorf("%s: isCreditOnlyLRC() = %v, want %v", c.name, got, c.want)
		}
	}
}

// scoreLyricCandidate 层面的端到端回归:确认上面那份虚构完整制作人员名单——哪怕时间戳
// 密度、末尾时间戳跟真实时长都对得上(这正是这个 bug 能蒙混过 isTimedLRC 和时长校验的
// 原因)——最终仍然被判定为无效候选(-1),不会被当成真歌词选中。
func TestScoreLyricCandidateRejectsCreditOnlyLyrics(t *testing.T) {
	fakeCreditLRC := "[00:00.00]作曲: 甲\n" +
		"[00:01.00]制作人: 乙\n" +
		"[00:02.00]指挥: 丙\n" +
		"[00:03.00]混音师: 丁\n" +
		"[00:04.00]贝斯: 戊\n" +
		"[00:05.00]中提琴: 己\n" +
		"[00:06.00]吉他: 庚\n" +
		"[00:07.00]大提琴: 辛\n" +
		"[04:35.19]母带工程师: 壬"
	c := lyricCandidate{source: "netease", lyrics: fakeCreditLRC}
	if got := scoreLyricCandidate("Someone", "Instrumental Track", 275.19, c, false); got != -1 {
		t.Errorf("scoreLyricCandidate() = %d, want -1 (credit-only lyrics must be rejected)", got)
	}
}

// 2026-08-05 实测排查坐实的真实 bug 的回归测试:同一首歌的不同录音(demo/original
// version/live)时长接近、歌词字面还一样,而 scoreLyricCandidate 改动前完全不看候选自报的
// 歌名 —— 于是 Michael Jackson 的 "Blue Gangsta" 被匹配成酷狗的
// "Blue Gangsta (Original Version)",播放时第一句就展示成
// "Michael Jackson - Blue Gangsta(Original Version)",时间轴也是原始版那一套。
// 详见 versionTagsMismatch / distinctRecordingVersionTags 的注释。
func TestTitleVersionTags(t *testing.T) {
	cases := []struct {
		title string
		want  []string
	}{
		// 括号里的限定词
		{"Blue Gangsta (Original Version)", []string{"original version"}},
		{"Beat It (Demo)", []string{"demo"}},
		{"Billie Jean [Live]", []string{"live"}},
		{"Thriller (Instrumental)", []string{"instrumental"}},
		{"Bad (Extended Dance Remix)", []string{"remix", "extended"}},
		// 破折号后面的限定词
		{"Smooth Criminal - Live at Wembley", []string{"live"}},
		// 同一次录音的不同发行/母带,不该算版本差异
		{"Thriller (2001 Remastered)", nil},
		{"Bad (Deluxe Edition)", nil},
		{"Beat It (Explicit)", nil},
		// ⚠️ 假阳性陷阱:限定词只在括号/破折号段里找,不能对整个歌名做子串匹配
		{"Live and Let Die", nil},
		{"Demolition Man", nil},
		{"Remixing My Heart", nil},
		{"Instrumentality", nil},
		// 干净标题
		{"Blue Gangsta", nil},
		{"", nil},
		// 括号没闭合(标签写得不规范)也要认出来
		{"Blue Gangsta (Demo", []string{"demo"}},
	}
	for _, c := range cases {
		got := titleVersionTags(c.title)
		if len(got) != len(c.want) {
			t.Errorf("titleVersionTags(%q) = %v, want %v", c.title, got, c.want)
			continue
		}
		for _, w := range c.want {
			if !got[w] {
				t.Errorf("titleVersionTags(%q) = %v, 缺 %q", c.title, got, w)
			}
		}
	}
}

func TestVersionTagsMismatch(t *testing.T) {
	cases := []struct {
		label      string
		local      string
		candidate  string
		wantMismat bool
	}{
		// 核心回归:本地是正式版,候选自报 Original Version → 必须判不匹配
		{"正式版 vs Original Version", "Blue Gangsta", "Blue Gangsta (Original Version)", true},
		{"正式版 vs Demo", "Beat It", "Beat It (Demo)", true},
		{"正式版 vs Live", "Billie Jean", "Billie Jean (Live)", true},
		// 反向同理:本地就是 demo,候选给正式版也不行(时间轴同样对不上)
		{"Demo vs 正式版", "Beat It (Demo)", "Beat It", true},
		{"Original Version vs 正式版", "Blue Gangsta (Original Version)", "Blue Gangsta", true},
		// 两边同一种版本 → 匹配
		{"两边都是 Live", "Billie Jean (Live)", "Billie Jean [Live]", false},
		{"两边都干净", "Blue Gangsta", "Blue Gangsta", false},
		// 母带/发行版差异不该判不匹配
		{"正式版 vs Remastered", "Thriller", "Thriller (2001 Remastered)", false},
		{"正式版 vs Deluxe", "Bad", "Bad (Deluxe Edition)", false},
		// 候选没回报歌名 → 没有证据,不扣分
		{"候选歌名为空", "Blue Gangsta", "", false},
		{"候选歌名只有空白", "Blue Gangsta", "   ", false},
		// 假阳性陷阱不能触发不匹配
		{"Live and Let Die 不是 live 版", "Live and Let Die", "Live and Let Die", false},
	}
	for _, c := range cases {
		if got := versionTagsMismatch(c.local, c.candidate); got != c.wantMismat {
			t.Errorf("%s: versionTagsMismatch(%q, %q) = %v, want %v", c.label, c.local, c.candidate, got, c.wantMismat)
		}
	}
}

// 端到端:同样的歌词内容/时长/逐字,只有自报歌名带不带版本后缀不同,打分必须拉开决定性差距。
func TestScoreLyricCandidatePenalizesWrongVersion(t *testing.T) {
	lrc := "[00:01.00]line one\n[00:05.00]line two\n[00:09.00]line three\n"
	base := lyricCandidate{source: "kugou", lyrics: lrc, hasWordTiming: true, wordTimingYRC: "x"}
	good := base
	good.title = "Blue Gangsta"
	bad := base
	bad.title = "Blue Gangsta (Original Version)"

	gs := scoreLyricCandidate("Michael Jackson", "Blue Gangsta", 9, good, false)
	bs := scoreLyricCandidate("Michael Jackson", "Blue Gangsta", 9, bad, false)
	if gs <= bs {
		t.Errorf("标题吻合的候选(%d)必须高于版本对不上的候选(%d)", gs, bs)
	}
	if bs < 1 {
		t.Errorf("扣分后仍要留至少 1 分(只有这一个候选时有总比没有好),实际 %d", bs)
	}
	if gs-bs < 400 {
		t.Errorf("差距要足够决定性,实际只差 %d 分", gs-bs)
	}
}

// 设置里的「歌名匹配」两档:忽略括号(默认)vs 严格。
//
// 这两档的差别只在"括号里的内容算不算数",不影响拿什么去搜(搜索词照旧去括号,那是召回率
// 的事)。真实场景:本地是 "In My Room (Remastered 2014)",而歌词源上普遍只叫 "In My Room"。
func TestTitleMatchesParenModes(t *testing.T) {
	cases := []struct {
		label                 string
		name, title           string
		wantLoose, wantStrict bool
	}{
		{"完全一致:两档都认", "In My Room", "In My Room", true, true},
		{"候选没有版本后缀:忽略括号认,严格不认",
			"In My Room", "In My Room (Remastered 2014)", true, false},
		{"本地没有、候选有:同理", "In My Room (Remastered 2014)", "In My Room", true, false},
		{"两边括号内容不同但主名相同:忽略括号认,严格不认",
			"Hello (Live)", "Hello (Studio)", true, false},
		{"括号完全一致:两档都认",
			"In My Room (Remastered 2014)", "In My Room (Remastered 2014)", true, true},
		{"根本是两首歌:两档都不认", "First Love", "In My Room", false, false},
	}
	for _, c := range cases {
		if got := titleMatches(c.name, c.title, true); got != c.wantLoose {
			t.Errorf("%s: 忽略括号 = %v, want %v", c.label, got, c.wantLoose)
		}
		if got := titleMatches(c.name, c.title, false); got != c.wantStrict {
			t.Errorf("%s: 严格 = %v, want %v", c.label, got, c.wantStrict)
		}
	}
}

func TestLRCLIBStrictTitleMatchParenModes(t *testing.T) {
	// 注意:这个函数名里的 Strict 指"比 titleMatches 严",跟设置里那两档是两件事 ——
	// 即使忽略括号,它也只认相等、不认双向子串包含。
	if !lrclibStrictTitleMatch("In My Room", "In My Room (Remastered 2014)", true) {
		t.Error("忽略括号档:去掉括号后相等,该认")
	}
	if lrclibStrictTitleMatch("In My Room", "In My Room (Remastered 2014)", false) {
		t.Error("严格档:括号里的内容也要对上,不该认")
	}
	if lrclibStrictTitleMatch("Real Love Baby", "Real Love", true) {
		t.Error("即使忽略括号,也绝不能退化成子串包含 —— 那会把另一首歌当成这一首")
	}
}

// 「歌名匹配」这个设置必须对**所有**源生效。
//
// 2026-08-09 用户报的真实场景:设成「严格」,自动选中的却是 kugou 那条曲名叫
// "Never let go"(没有 "(Remastered 2014)" 后缀)的候选。原因是这个设置当初只接到了
// netease 和 lrclib —— kugou/QQ/Musixmatch 各自直接调 looseContains,谁都没查过它。
func TestLyricTitleAcceptedHonoursStrictSetting(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	const local = "Never Let Go (Remastered 2014)"
	features.LyricsStrictTitleMatch = false
	if !lyricTitleAccepted("Never let go", local) {
		t.Error("忽略括号档:少了版本后缀也该认(大小写不敏感)")
	}
	if !lyricTitleAccepted("Never Let Go (Remastered 2014)", local) {
		t.Error("忽略括号档:完全一致当然该认")
	}

	features.LyricsStrictTitleMatch = true
	if lyricTitleAccepted("Never let go", local) {
		t.Error("严格档:没有版本后缀就不该认 —— 这正是用户撞到的那一条")
	}
	if !lyricTitleAccepted("never let go (remastered 2014)", local) {
		t.Error("严格档要的是归一化后相等,不是逐字节相等(大小写/空格不算差异)")
	}
	if lyricTitleAccepted("Never Let Go (Live)", local) {
		t.Error("严格档:括号内容不同就是不同版本")
	}
	if lyricTitleAccepted("", local) || lyricTitleAccepted("Never Let Go", "") {
		t.Error("空串两档都不该认")
	}
}

// 2026-08-09 打分体系评估后的三处改动，逐条钉住。
func TestScoringAfter20260809Review(t *testing.T) {
	const dur = 200.0
	// 一份时长吻合、49 行的普通歌词
	good := "[00:00.00]a\n" + strings.Repeat("[00:10.00]x\n", 47) + "[03:20.00]end"

	t.Run("来源不再加分", func(t *testing.T) {
		var scores []int
		for _, src := range []string{"netease", "qq", "kugou", "musixmatch", "lrclib"} {
			s, terms := scoreLyricCandidateDetailed(
				"someone", "song", dur, lyricCandidate{source: src, lyrics: good}, false)
			scores = append(scores, s)
			for _, term := range terms {
				if term.Kind == scoreTermSource {
					t.Errorf("%s 仍然带着来源加分 %d", src, term.Points)
				}
			}
		}
		for i := 1; i < len(scores); i++ {
			if scores[i] != scores[0] {
				t.Errorf("同一份歌词换个来源分数就变了: %v —— 来源不该再影响分数", scores)
				break
			}
		}
	})

	t.Run("时长不符改成重扣而不是一票否决", func(t *testing.T) {
		// 末尾时间戳 60s,曲长 200s —— 差 70%,远超 25% 阈值
		off := "[00:00.00]a\n[00:30.00]b\n[01:00.00]c"
		score, terms := scoreLyricCandidateDetailed(
			"someone", "song", dur, lyricCandidate{source: "qq", lyrics: off}, false)
		if score < 0 {
			t.Fatalf("时长不符不该再判 -1(会被整条丢弃),实际 %d", score)
		}
		var penalized bool
		for _, term := range terms {
			if term.Kind == scoreTermDurationOff {
				penalized = true
				if term.Points >= 0 {
					t.Errorf("时长不符那一项应该是扣分,实际 %+d", term.Points)
				}
			}
		}
		if !penalized {
			t.Error("没有记下「时长不符」这一项,用户就看不到它为什么排在后面")
		}
		// 关键性质:再怎么样也得输给一条时长对得上的
		ok, _ := scoreLyricCandidateDetailed(
			"someone", "song", dur, lyricCandidate{source: "lrclib", lyrics: good}, false)
		if score >= ok {
			t.Errorf("时长不符的候选(%d)不该压过时长吻合的(%d)", score, ok)
		}
	})

	t.Run("硬拒绝只留真的不能用的那几种", func(t *testing.T) {
		// 没有时间戳的纯文本仍然一票否决
		if s, _ := scoreLyricCandidateDetailed(
			"someone", "song", dur, lyricCandidate{source: "qq", lyrics: "just words\nno timestamps"}, false); s != -1 {
			t.Errorf("没有时间戳的歌词仍应判 -1,实际 %d", s)
		}
	})
}

// 「搜索词也要去一次括号」——2026-08-09 用户报的场景:设置里选了「忽略括号」,搜索候选
// 里各源拿去搜的却仍然是带 "(Remastered 2014)" 的原样标题。
//
// 当时只有 netease 在搜索词那一层调了 stripParens,其余四个源全是拿原样标题去搜。
// 逐源实测(见 searchTitleVariants 注释)坐实这不是洁癖问题:QQ 的 smartbox 只要 key 里
// 带括号就返回 0 条,酷狗则返回 10 条该歌手的热门歌、目标曲根本不在里面。
func TestSearchTitleVariants(t *testing.T) {
	cases := []struct {
		label string
		title string
		want  []string
	}{
		{"没有括号:只有一条,不做无谓的重复请求", "Automatic", []string{"Automatic"}},
		{"有括号:原样在前、裸标题在后",
			"Automatic (Remastered 2014)", []string{"Automatic (Remastered 2014)", "Automatic"}},
		{"方括号同样算", "Hold My Hand [feat. Akon]",
			[]string{"Hold My Hand [feat. Akon]", "Hold My Hand"}},
		{"整个标题都在括号里:剥完是空的,不能生成一条空查询",
			"(Untitled)", []string{"(Untitled)"}},
		{"空标题", "", []string{""}},
	}
	for _, c := range cases {
		got := searchTitleVariants(c.title)
		if len(got) != len(c.want) {
			t.Errorf("%s: searchTitleVariants(%q) = %q, want %q", c.label, c.title, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%s: searchTitleVariants(%q)[%d] = %q, want %q",
					c.label, c.title, i, got[i], c.want[i])
			}
		}
	}
}

// 搜索词的去括号跟「歌名匹配:忽略括号/严格」那个设置**无关**,两档必须生成同一组查询。
//
// 这条是防回归的核心:很容易顺手把它接到 features.LyricsStrictTitleMatch 上("用户都选
// 严格了,那就别去括号了吧")——那是错的。设置管的是"候选算不算这首歌",这里管的是"拿
// 什么去搜";严格档同样需要裸标题这条退路,否则 QQ 那种带括号直接 0 条的源,严格档下
// 一条候选都拿不到,连被严格判定的机会都没有。放宽搜索词不会放松判定:搜回来的结果照旧
// 要过 lyricTitleAccepted。
func TestSearchTitleVariantsIgnoresStrictSetting(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	const title = "Automatic (Remastered 2014)"
	features.LyricsStrictTitleMatch = false
	loose := searchTitleVariants(title)
	features.LyricsStrictTitleMatch = true
	strict := searchTitleVariants(title)

	if len(loose) != 2 || len(strict) != 2 {
		t.Fatalf("两档都该有两条查询, 忽略括号=%q 严格=%q", loose, strict)
	}
	for i := range loose {
		if loose[i] != strict[i] {
			t.Errorf("第 %d 条查询两档不一致: 忽略括号=%q 严格=%q", i, loose[i], strict[i])
		}
	}
}

// QQ 是受害最重的一个源,单独钉住它的查询梯子。
func TestQQSearchQueries(t *testing.T) {
	got := qqSearchQueries("宇多田ヒカル", "Automatic (Remastered 2014)")
	want := []string{"宇多田ヒカル Automatic (Remastered 2014)", "宇多田ヒカル Automatic"}
	if len(got) != len(want) {
		t.Fatalf("qqSearchQueries = %q, want %q", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("qqSearchQueries[%d] = %q, want %q", i, got[i], want[i])
		}
	}
	// 歌手名为空时不能留下一个前导空格,那会变成另一个查询词
	if q := qqSearchQueries("", "Automatic"); len(q) != 1 || q[0] != "Automatic" {
		t.Errorf("歌手名为空: qqSearchQueries = %q, want [Automatic]", q)
	}
}
