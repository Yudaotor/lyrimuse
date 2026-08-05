package main

import "testing"

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
