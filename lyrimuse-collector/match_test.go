package main

import (
	"fmt"
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
	if got := scoreLyricCandidate("Someone", "Instrumental Track", "", 275.19, c, false); got != -1 {
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
		localAlbum string
		candidate  string
		candAlbum  string
		wantMismat bool
	}{
		// 核心回归:本地是正式版,候选自报 Original Version → 必须判不匹配
		{"正式版 vs Original Version", "Blue Gangsta", "", "Blue Gangsta (Original Version)", "", true},
		{"正式版 vs Demo", "Beat It", "", "Beat It (Demo)", "", true},
		{"正式版 vs Live", "Billie Jean", "", "Billie Jean (Live)", "", true},
		// 反向同理:本地就是 demo,候选给正式版也不行(时间轴同样对不上)
		{"Demo vs 正式版", "Beat It (Demo)", "", "Beat It", "", true},
		{"Original Version vs 正式版", "Blue Gangsta (Original Version)", "", "Blue Gangsta", "", true},
		// 两边同一种版本 → 匹配
		{"两边都是 Live", "Billie Jean (Live)", "", "Billie Jean [Live]", "", false},
		{"两边都干净", "Blue Gangsta", "", "Blue Gangsta", "", false},
		// 母带/发行版差异不该判不匹配
		{"正式版 vs Remastered", "Thriller", "", "Thriller (2001 Remastered)", "", false},
		{"正式版 vs Deluxe", "Bad", "", "Bad (Deluxe Edition)", "", false},
		// 候选没回报歌名 → 没有证据,不扣分
		{"候选歌名为空", "Blue Gangsta", "", "", "", false},
		{"候选歌名只有空白", "Blue Gangsta", "", "   ", "", false},
		// 假阳性陷阱不能触发不匹配
		{"Live and Let Die 不是 live 版", "Live and Let Die", "", "Live and Let Die", "", false},

		// ↓↓↓ 2026-08-10 新增:限定词写在**专辑名**里的那一类 ↓↓↓

		// 真实事故复现:PRINCE 的 "1999"。候选歌名干干净净就叫 "1999",Live 只出现在
		// 专辑名里,只看歌名的话这道闸门完全不响,那条现场版拿 768 分排第一。
		{
			"歌名干净但专辑是现场版", "1999", "The Hits/The B-Sides",
			"1999", "Nude Tour, 1990 (Remastered, Live On Broadcasting)", true,
		},
		// 同一事故里专辑真正对得上的那条,不能被误伤
		{
			"专辑对得上(连字符写法)", "1999", "The Hits/The B-Sides",
			"1999", "The Hits-The B-Sides", false,
		},
		// 合集 vs 原始专辑:两边都没有版本限定词,不该因为"专辑名不一样"就判不匹配
		{"合集 vs 原始专辑", "1999", "The Hits/The B-Sides", "1999", "1999", false},
		// 位置差异不算差异:一边写在歌名、一边写在专辑,取并集之后是一致的
		{
			"限定词一个写歌名一个写专辑", "Layla (Acoustic)", "",
			"Layla", "Unplugged (Acoustic)", false,
		},
		// ⚠️ 已知缺口,固化在这里:限定词在专辑名里**裸着**出现(没有括号、也不在
		// 最后一个 " - " 之后)时抓不到 —— titleVersionTags 只在"限定词该出现的位置"
		// 里找,而那条规则是为了挡住 "Live and Let Die"/"Demolition" 这类假阳性。
		// 代价就是 "MTV Unplugged in New York"、"Live at Wembley" 这种专辑名逃过判定。
		// 要补的话得给专辑名单独做**按词边界**的全名匹配(能认 unplugged/live,又不会
		// 把 "Alive"/"Demolition" 认错),但也会带来 "Extended Play" 这类新的假阳性,
		// 值不值得要另做实测。现在如实标成 false。
		{
			"已知缺口:专辑名里的裸词限定词抓不到", "Come As You Are", "MTV Unplugged in New York",
			"Come As You Are", "Nevermind", false,
		},
		// 专辑里的母带/发行说明不该触发(remastered/deluxe 故意不在词表里)
		{
			"专辑写 Remastered 不算版本差异", "Thriller", "Thriller",
			"Thriller", "Thriller (2001 Remastered Edition)", false,
		},
		// 专辑名里不带括号的普通词不该被当成限定词 —— titleVersionTags 只在括号段和
		// 最后一个 " - " 之后找
		{"专辑名裸词 Alive 不算 live", "Song", "Alive", "Song", "Some Album", false},
		// 候选歌名和专辑都为空 → 没有证据,不扣分
		{"候选元数据全空", "Blue Gangsta", "Bad", "", "", false},
	}
	for _, c := range cases {
		got := versionTagsMismatch(c.local, c.localAlbum, c.candidate, c.candAlbum)
		if got != c.wantMismat {
			t.Errorf("%s: versionTagsMismatch(%q/%q, %q/%q) = %v, want %v",
				c.label, c.local, c.localAlbum, c.candidate, c.candAlbum, got, c.wantMismat)
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

	gs := scoreLyricCandidate("Michael Jackson", "Blue Gangsta", "", 9, good, false)
	bs := scoreLyricCandidate("Michael Jackson", "Blue Gangsta", "", 9, bad, false)
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

// lyricTitleAccepted 是五个源共用的、**唯一**一条曲名判定(2026-08-09 由三个函数合并
// 而来:netease 的 titleMatches、lrclib 的 lrclibStrictTitleMatch、以及这个)。
//
// 只认「归一化后相等」或「双方各自去括号后相等」,**绝不认任意子串包含**。
// 收紧的代价实测为零:250 首全量候选数据里,靠子串才被接受的候选一条都没有。
func TestLyricTitleAccepted(t *testing.T) {
	cases := []struct {
		label           string
		candidate, want string
		accept          bool
	}{
		{"完全一致", "In My Room", "In My Room", true},
		{"候选没有版本后缀:去括号后相等,认",
			"In My Room", "In My Room (Remastered 2014)", true},
		{"本地没有、候选有:同理", "In My Room (Remastered 2014)", "In My Room", true},
		{"两边括号内容不同但主名相同:认(真正的版本差异交给 versionTagsMismatch 拦)",
			"Hello (Live)", "Hello (Studio)", true},
		{"括号完全一致", "In My Room (Remastered 2014)", "In My Room (Remastered 2014)", true},
		{"大小写/空格不算差异", "never let go (remastered 2014)", "Never Let Go (Remastered 2014)", true},
		{"根本是两首歌", "First Love", "In My Room", false},
		// 下面三条是这次收紧的核心:旧的 looseContains(双向子串包含)会全部误认
		{"子串:候选是本地的前缀,不认", "Real Love", "Real Love Baby", false},
		{"子串:本地是候选的前缀,不认", "Real Love Baby", "Real Love", false},
		{"子串:短词命中长曲名,不认", "Love", "Real Love", false},
		{"空串两侧都不认", "", "In My Room", false},
	}
	for _, c := range cases {
		if got := lyricTitleAccepted(c.candidate, c.want); got != c.accept {
			t.Errorf("%s: lyricTitleAccepted(%q, %q) = %v, want %v",
				c.label, c.candidate, c.want, got, c.accept)
		}
	}
	if lyricTitleAccepted("In My Room", "") {
		t.Error("本地标题为空不该认")
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
				"someone", "song", "", dur, lyricCandidate{source: src, lyrics: good}, false)
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
			"someone", "song", "", dur, lyricCandidate{source: "qq", lyrics: off}, false)
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
			"someone", "song", "", dur, lyricCandidate{source: "lrclib", lyrics: good}, false)
		if score >= ok {
			t.Errorf("时长不符的候选(%d)不该压过时长吻合的(%d)", score, ok)
		}
	})

	t.Run("硬拒绝只留真的不能用的那几种", func(t *testing.T) {
		// 没有时间戳的纯文本仍然一票否决
		if s, _ := scoreLyricCandidateDetailed(
			"someone", "song", "", dur, lyricCandidate{source: "qq", lyrics: "just words\nno timestamps"}, false); s != -1 {
			t.Errorf("没有时间戳的歌词仍应判 -1,实际 %d", s)
		}
	})
}

// 「搜索词也要去一次括号」——2026-08-09 用户报的场景:各源拿去搜的一直是带
// "(Remastered 2014)" 的原样标题。当时只有 netease 在搜索词那一层调了 stripParens。
//
// 逐源实测(见 searchTitleVariants 注释)坐实这不是洁癖问题:QQ 的 smartbox 只要 key 里
// 带括号就返回 0 条,酷狗则返回 10 条该歌手的热门歌、目标曲根本不在里面。
func TestSearchTitleVariants(t *testing.T) {
	cases := []struct {
		label string
		title string
		want  []string
	}{
		{"没有括号:只有一条,不做无谓的重复请求", "Automatic", []string{"Automatic"}},
		{"噪音括号:裸标题优先,原样作兜底",
			"Automatic (Remastered 2014)", []string{"Automatic", "Automatic (Remastered 2014)"}},
		{"方括号同样算", "Hold My Hand [feat. Akon]",
			[]string{"Hold My Hand", "Hold My Hand [feat. Akon]"}},
		{"整个标题都在括号里:剥完是空的,不能生成一条空查询",
			"(Untitled)", []string{"(Untitled)"}},
		{"空标题", "", []string{""}},
		// 括号里是"另一次录音"的限定词时不能把裸标题提前——去掉它搜回来的是另一版录音,
		// 时间轴对不上。实测:提前之后酷狗这条从 806 分掉到 207。
		{"版本限定词:原样优先",
			"Billie Jean (Single Version)",
			[]string{"Billie Jean (Single Version)", "Billie Jean"}},
		{"live 同理", "Hello (Live)", []string{"Hello (Live)", "Hello"}},
		{"remaster 不算另一次录音,该去括号",
			"Hello (Remastered 2015)", []string{"Hello", "Hello (Remastered 2015)"}},
		{"破折号写法的版本限定词也认", "Hello - Live at Wembley",
			[]string{"Hello - Live at Wembley"}}, // 没有括号可剥,只有一条
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

// 两种写法都必须在序列里,只是谁先谁后。任何一边被砍掉都会丢掉一整类歌:
//   - 丢掉裸标题 → QQ 那种"带括号直接 0 条"的源,对这类歌整个失效;
//   - 丢掉原样标题 → LRCLIB 那两条重制版就没了(搜裸标题回的 20 条全是普通版)。
func TestSearchTitleVariantsAlwaysKeepsBothForms(t *testing.T) {
	for _, title := range []string{
		"Automatic (Remastered 2014)",  // 噪音括号
		"Billie Jean (Single Version)", // 版本限定词
		"Blue Gangsta (Original Version)",
	} {
		got := searchTitleVariants(title)
		if len(got) != 2 {
			t.Errorf("%q 该有两条查询, got %q", title, got)
			continue
		}
		if got[0] == got[1] {
			t.Errorf("%q 两条查询不该重复: %q", title, got)
		}
		bare, raw := false, false
		for _, q := range got {
			if q == title {
				raw = true
			}
			if q == stripParens(title) {
				bare = true
			}
		}
		if !raw || !bare {
			t.Errorf("%q 的查询序列必须同时含原样和裸标题, got %q", title, got)
		}
	}
}

// QQ 是受害最重的一个源(带括号直接 0 条),单独钉住它的查询梯子。
func TestQQSearchQueries(t *testing.T) {
	got := qqSearchQueries("宇多田ヒカル", "Automatic (Remastered 2014)")
	want := []string{"宇多田ヒカル Automatic", "宇多田ヒカル Automatic (Remastered 2014)"}
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

// lrcEndingAt 造一份"末句正好落在 lastSecs"的合法 LRC(足够行数通过 isTimedLRC、
// 不被当成只有 credit 的空壳)。
func lrcEndingAt(lastSecs int, lines int) string {
	var b strings.Builder
	step := lastSecs / lines
	if step < 1 {
		step = 1
	}
	for i := 0; i < lines; i++ {
		t := i * step
		if i == lines-1 {
			t = lastSecs
		}
		// 正文用英文:本地标题是英文时,中文正文会被 isProbablyWrongLanguageLyrics 判为
		// 文不对题直接拒掉(第一版就栽在这儿,两条候选都得 -1 分)。
		fmt.Fprintf(&b, "[%02d:%02d.00]this is lyric line number %d\n", t/60, t%60, i)
	}
	return b.String()
}

// 「两个源一起抓错版本、互相印证」——2026-08-09 实测抓到的真实翻车。
//
// Valentina (feat. Rick Ross) [Bonus] 是 237s,QQ 和酷狗都抓到了普通版(都停在 143s),
// 于是互相印证、各拿 +100 豁免掉时长惩罚;真正抓到 bonus 版、末句 226s 的 LRCLIB 反倒
// 分数低一截,冠军判给了 QQ。
//
// 各源拿的是同一个搜索词,搜歪时会被**一起**带到同一个错版本上——这时候"两个源一致"
// 不是独立证据。判别信号:只要 batch 里有任何一条候选时长是吻合的,就证伪了"这首歌的
// 歌词本来就早早结束",不再发豁免。
func TestCorroborationYieldsToAWellFittingCandidate(t *testing.T) {
	const dur = 237.0
	shortA := lyricCandidate{source: "qq", lyrics: lrcEndingAt(143, 40)}
	shortB := lyricCandidate{source: "kugou", lyrics: lrcEndingAt(143, 40)}
	fits := lyricCandidate{source: "lrclib", lyrics: lrcEndingAt(226, 44)}

	// ① 有一条吻合 → 印证豁免整体作废,两条短的该吃时长惩罚
	corr := corroboratedEndings([]lyricCandidate{shortA, shortB, fits}, dur)
	if len(corr) != 0 {
		t.Errorf("有候选时长吻合时不该再发印证豁免, got %v", corr)
	}
	qqScore, qqTerms := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, shortA, corr[shortA.source])
	lrcScore, _ := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, fits, corr[fits.source])
	for _, term := range qqTerms {
		if term.Kind == scoreTermCorroborated {
			t.Error("抓错版本的候选不该再拿到 corroborated 加分")
		}
	}
	if lrcScore <= qqScore {
		t.Errorf("时长吻合的候选该赢: lrclib %d vs qq %d", lrcScore, qqScore)
	}

	// ② 没有任何一条吻合(真·长尾奏)→ 印证照旧生效,别错杀
	corr2 := corroboratedEndings([]lyricCandidate{shortA, shortB}, dur)
	if !corr2[shortA.source] || !corr2[shortB.source] {
		t.Errorf("所有源都提前结束时,印证豁免必须保留(长尾奏的歌全靠它), got %v", corr2)
	}
	if _, terms := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, shortA, corr2[shortA.source]); !hasTerm(terms, scoreTermCorroborated) {
		t.Error("这一档该走 corroborated 加分")
	}

	// ③ 本地时长未知时不做任何判断,行为跟以前一致
	if corr3 := corroboratedEndings([]lyricCandidate{shortA, shortB, fits}, 0); !corr3[shortA.source] {
		t.Errorf("时长未知时不该收紧, got %v", corr3)
	}
}

func hasTerm(terms []scoreTerm, kind string) bool {
	for _, t := range terms {
		if t.Kind == kind {
			return true
		}
	}
	return false
}
