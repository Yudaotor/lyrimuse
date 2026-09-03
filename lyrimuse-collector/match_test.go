package main

import (
	"fmt"
	"sort"
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
	if got := scoreLyricCandidate("Someone", "Instrumental Track", "", 275.19, c, false, 0); got != -1 {
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
		// 2026-08-26 补中文版本限定词(真实bug案例:「蜗牛 (伴奏)」查 lyricfind,词表原来
		// 只认拉丁词,伴奏版被当成正常版收了)。
		{"蜗牛 (伴奏)", []string{"伴奏"}},
		{"起风了 (Live)", []string{"live"}},
		{"晴天 [现场版]", []string{"现场"}},
		{"告白气球 (阿卡贝拉版本)", []string{"阿卡贝拉"}},
		// 假阳性陷阱同样适用于中文:词只在括号/破折号段里找。
		{"不插电的夏天", nil},
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

// ---- v7(2026-09-01):liveAlbumIdentityConflict(「两场不同演唱会」判据) ----
//
// 全部字符串取自真实曲库的 lyrics_decision 记录(2339 条全库回放的命中/放行样本),不是编的。
// 起因:陈奕迅《Shall We Dance (Live)》/《活着多好 (Live)》,本地专辑《The Easy Ride 演唱会
// (Live)》,酷狗那份挂在《Get A Life (Live)》(另一场巡演)——两边都是 Live,versionTagsMismatch
// 的限定词集合相等、必然静默,而标题/专辑亲和分全部打平,错的那份靠逐字或时长巧合赢。
func TestLiveAlbumIdentityConflict(t *testing.T) {
	cases := []struct {
		name                 string
		artist, localAlbum   string
		candTitle, candAlbum string
		want                 bool
	}{
		// 核心案例:两场不同命名的演唱会 → 冲突
		{"陈奕迅 Easy Ride vs Get A Life", "陈奕迅", "The Easy Ride 演唱会 (Live)",
			"活着多好 (Live)", "Get A Life (Live)", true},
		{"陈奕迅 Easy Ride vs 2003演唱会", "陈奕迅", "The Easy Ride 演唱会 (Live)",
			"Shall We Talk (Live)", "2003演唱会", true},
		{"方大同 大事发声 vs Timeless演唱会", "方大同", "大事发声.录音棚现场: 方大同 专场",
			"公园 (Live)", "Timeless演唱会", true},
		{"周杰伦 地表最强 vs 无与伦比2004", "周杰伦", "周杰伦地表最强世界巡回演唱会 (Live)",
			"晴天 (Live)", "周杰伦 2004 无与伦比 演唱会 Live CD", true},
		// 同一场演出的不同写法 → 放行(四道门之④:共享身份词元)
		{"同场:Easy Ride 网易云写法(共享 easy/ride)", "陈奕迅", "The Easy Ride 演唱会 (Live)",
			"活着多好(Live)", "The Easy Ride Live 陈奕迅演唱会", false},
		{"同场:15 香港演唱会 中英命名(共享 15/2011)", "Khalil Fong", "15 Khalil Fong Live in Hong Kong 2011",
			"Rosy (Live)", "15 香港演唱会(2011Live)", false},
		// 歌手名前缀粘连 → 放行(剥掉歌手名后共享整个演出名;lrclib 真实数据)
		{"同场:歌手名粘连前缀", "周杰伦", "周杰伦地表最强世界巡回演唱会 (Live)",
			"以父之名 (Live)", "地表最强世界巡回演唱会", false},
		// 本地专辑名不是现场专辑 → 放行(四道门之①;Queen 全库回放的真实假阳性:
		// 《The Game (Deluxe Edition)》的 bonus 现场曲,候选《Queen Rock Montreal》
		// 是本地标题里写的同一场蒙特利尔演出,录音室专辑名对"是哪场演出"没有发言权)
		{"本地是录音室专辑的 bonus 现场曲", "Queen", "The Game (Deluxe Edition)",
			"Save Me (Live In Montreal / November 1981)", "Queen Rock Montreal", false},
		// 候选是录音室版 → 放行(四道门之②,归 versionTagsMismatch 管)
		{"候选是录音室版", "陈奕迅", "The Easy Ride 演唱会 (Live)",
			"活着多好", "The Easy Ride", false},
		// 候选专辑为空 → 放行(没有身份声明构不成矛盾)
		{"候选专辑为空", "陈奕迅", "The Easy Ride 演唱会 (Live)", "活着多好 (Live)", "", false},
	}
	for _, c := range cases {
		if got := liveAlbumIdentityConflict(c.artist, c.localAlbum, c.candTitle, c.candAlbum); got != c.want {
			t.Errorf("%s: liveAlbumIdentityConflict(%q, %q, %q, %q) = %v, want %v",
				c.name, c.artist, c.localAlbum, c.candTitle, c.candAlbum, got, c.want)
		}
	}
}

// 端到端:同一首《活着多好 (Live)》,除了专辑归属其余条件对齐,挂在另一场演唱会的候选
// 必须吃到 liveAlbumConflict 的 -600、总分被压到吻合场次的候选之下。
func TestScoreLyricCandidatePenalizesOtherConcert(t *testing.T) {
	lyr := "[00:10.00]第一句现场歌词占位\n[00:20.00]第二句现场歌词占位\n[00:30.00]第三句现场歌词占位"
	wrongConcert := lyricCandidate{source: "kugou", lyrics: lyr,
		title: "活着多好 (Live)", album: "Get A Life (Live)"}
	rightConcert := lyricCandidate{source: "netease", lyrics: lyr,
		title: "活着多好(Live)", album: "The Easy Ride Live 陈奕迅演唱会"}
	sWrong, terms := scoreLyricCandidateDetailed("陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)", 0, wrongConcert, false, 0)
	sRight, _ := scoreLyricCandidateDetailed("陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)", 0, rightConcert, false, 0)
	if p := scoreTermPoints(terms, scoreTermLiveAlbumConflict); p != -liveAlbumConflictPenalty {
		t.Errorf("另一场演唱会的候选应吃到 liveAlbumConflict %d,实际 %d", -liveAlbumConflictPenalty, p)
	}
	if sWrong >= sRight {
		t.Errorf("其余条件对齐时,另一场演唱会的候选(%d)不该赢过吻合场次的候选(%d)", sWrong, sRight)
	}
}

// ---- v8(2026-09-01):sameRecordingDespiteVersionTags(时长锚定的限定词豁免) ----
//
// 核心案例字符串/时长全部取自真实数据(陈奕迅《孤独探戈 (Live)》,网易云 id=67184,
// 见 docs/features/09 第 33 条):本地时长 215.373s,候选自报 215.4s(逐位吻合),
// 专辑对得上,只是候选曲名多一节"(Acoustic Piano)"——这场演出本来就是钢琴演绎,
// 命名差异不是版本差异。
func TestSameRecordingDespiteVersionTags(t *testing.T) {
	localTitle, localAlbum, localDur := "孤独探戈 (Live)", "The Easy Ride 演唱会 (Live)", 215.373
	cases := []struct {
		name                 string
		candTitle, candAlbum string
		candDur              float64
		want                 bool
	}{
		{"孤独探戈真实案例:acoustic 演奏方式标注", "孤独探戈(Acoustic Piano)(Live)", "The Easy Ride Live 陈奕迅演唱会", 215.4, true},
		// 时长差超 1% → 不豁免(Get A Life 那条错场次候选自报 233.081s,差 7.6%)
		{"时长差 7.6% 的错场次", "孤独探戈 (Live)", "Get A Life (Live)", 233.081, false},
		// 候选缺本地已有的限定词 → 不豁免:本地是 Live、候选是录音室版,哪怕时长碰巧相同
		{"候选缺 Live 标记", "孤独探戈", "The Easy Ride", 215.4, false},
		// 多出的词不在白名单 → 不豁免:伴奏版时长常与原曲完全相同,但它是另一次录音
		{"伴奏版时长相同也不豁免", "孤独探戈 (伴奏)(Live)", "The Easy Ride Live 陈奕迅演唱会", 215.4, false},
		// 粤语/国语同曲异词、同一伴奏、时长几乎一样 —— versionTags 存在的理由,永不豁免
		{"国语版时长相同也不豁免", "孤独探戈 (国语)(Live)", "The Easy Ride Live 陈奕迅演唱会", 215.4, false},
		// 专辑毫无亲和 → 不豁免(时长巧合没有专辑证据背书)
		{"专辑对不上", "孤独探戈(Acoustic Piano)(Live)", "完全无关的专辑", 215.4, false},
		// 候选没自报时长 → 不豁免(没有证据不等于证据)
		{"没自报时长", "孤独探戈(Acoustic Piano)(Live)", "The Easy Ride Live 陈奕迅演唱会", 0, false},
	}
	for _, c := range cases {
		if got := sameRecordingDespiteVersionTags(localTitle, localAlbum, localDur, c.candTitle, c.candAlbum, c.candDur); got != c.want {
			t.Errorf("%s: sameRecordingDespiteVersionTags(...%q/%q/%.1f) = %v, want %v",
				c.name, c.candTitle, c.candAlbum, c.candDur, got, c.want)
		}
	}
	// 本地时长未知 → 不豁免
	if sameRecordingDespiteVersionTags(localTitle, localAlbum, 0, "孤独探戈(Acoustic Piano)(Live)", "The Easy Ride Live 陈奕迅演唱会", 215.4) {
		t.Error("本地时长未知时不该豁免")
	}
}

// 端到端:同一份歌词,只差"曲名多一节 (Acoustic Piano)+自报时长是否吻合",打分层必须
// 豁免真实案例的 -600、且对时长不吻合的照扣。
func TestScoreLyricCandidateWaivesVersionTagsForSameRecording(t *testing.T) {
	lyr := "[00:13.33]你可知道石头\n[00:16.84]要几多冷汗才被冲走\n[00:20.57]你早知探戈"
	waived := lyricCandidate{source: "netease", lyrics: lyr,
		title: "孤独探戈(Acoustic Piano)(Live)", album: "The Easy Ride Live 陈奕迅演唱会",
		sourceReportedDurationSecs: 215.4}
	_, terms := scoreLyricCandidateDetailed("陈奕迅", "孤独探戈 (Live)", "The Easy Ride 演唱会 (Live)", 215.373, waived, false, 0)
	if p := scoreTermPoints(terms, scoreTermVersionTags); p != 0 {
		t.Errorf("时长锚定坐实同一次录音时,versionTags 应被豁免,实际 %+d", p)
	}
	notAnchored := waived
	notAnchored.sourceReportedDurationSecs = 233.081 // Get A Life 那条的真实自报时长
	_, terms = scoreLyricCandidateDetailed("陈奕迅", "孤独探戈 (Live)", "The Easy Ride 演唱会 (Live)", 215.373, notAnchored, false, 0)
	if p := scoreTermPoints(terms, scoreTermVersionTags); p != -versionMismatchPenalty {
		t.Errorf("时长不吻合时 versionTags 应照扣 %d,实际 %+d", -versionMismatchPenalty, p)
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

		// 2026-08-26 真实bug复现:本地「蜗牛 (伴奏)」,lyricfind 召回的是正常演唱版
		// 「蜗牛」——中文限定词补进词表前,这里判两边都是空集、-600 不触发,伴奏版被当成
		// 正常版收了(候选内容对,但时间轴/歌词其实是另一版本的伴奏)。
		{"正式版 vs 伴奏", "蜗牛 (伴奏)", "", "蜗牛", "", true},
		{"两边都是伴奏", "蜗牛 (伴奏)", "", "蜗牛 (伴奏)", "", false},
		{"不插电的夏天 不是不插电版", "不插电的夏天", "", "不插电的夏天", "", false},

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

	gs := scoreLyricCandidate("Michael Jackson", "Blue Gangsta", "", 9, good, false, 0)
	bs := scoreLyricCandidate("Michael Jackson", "Blue Gangsta", "", 9, bad, false, 0)
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

		// ↓↓↓ 2026-08-11 新增:双语标题(中文名 + 英文别名后缀) ↓↓↓

		// 真实事故复现:丁世光《起源》,QQ/酷狗都叫「起源 Origin」,原规则五源只剩两条候选
		{"双语后缀:候选带英文别名,认", "起源 Origin", "起源", true},
		{"双语后缀:反向(本地带别名),认", "起源", "起源 Origin", true},
		{"双语后缀 + 括号叠加,认", "起源 Origin (Live)", "起源", true},
		// 三条护栏:规则只对「含汉字的前缀 + 纯字母尾巴」开口子
		{"纯英文前缀关系仍不认(Love/Love Song 是两首歌)", "Love Song", "Love", false},
		{"尾巴带数字不认(起源2 是另一首歌)", "起源2", "起源", false},
		{"尾巴含汉字不认(起源之战 是另一首歌)", "起源之战", "起源", false},
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
				"someone", "song", "", dur, lyricCandidate{source: src, lyrics: good}, false, 0)
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
			"someone", "song", "", dur, lyricCandidate{source: "qq", lyrics: off}, false, 0)
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
			"someone", "song", "", dur, lyricCandidate{source: "lrclib", lyrics: good}, false, 0)
		if score >= ok {
			t.Errorf("时长不符的候选(%d)不该压过时长吻合的(%d)", score, ok)
		}
	})

	t.Run("硬拒绝只留真的不能用的那几种", func(t *testing.T) {
		// 没有时间戳的纯文本仍然一票否决
		if s, _ := scoreLyricCandidateDetailed(
			"someone", "song", "", dur, lyricCandidate{source: "qq", lyrics: "just words\nno timestamps"}, false, 0); s != -1 {
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
	qqScore, qqTerms := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, shortA, corr[shortA.source], 0)
	lrcScore, _ := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, fits, corr[fits.source], 0)
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
	if _, terms := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, shortA, corr2[shortA.source], 0); !hasTerm(terms, scoreTermCorroborated) {
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

// ---- v3 维度(2026-08-12)的单测。分值背书见 lyricsScoringVersion 注释的消融数据 ----

func TestTitleMatchTierPoints(t *testing.T) {
	cases := []struct {
		name        string
		cand, local string
		want        int
	}{
		{"精确同名", "月食", "月食", 120},
		{"大小写与空白不敏感", "Blue  Gangsta", "blue gangsta", 120},
		{"feat 噪音括号升回精确档", "Song (feat. Rick Ross)", "Song", 120},
		{"版本括号只到括号档", "Song (Live)", "Song", 60},
		{"中英双语同名", "起源 Origin", "起源", 30},
		{"完全不同的歌名", "Another Tune", "Song", 0},
		{"候选没报标题", "", "Song", 0},
		// 2026-08-26 补:中文限定词在 segmentVersionTags 里没有空格分词,"伴奏版"整段
		// 会被当成一个词元、跟裸词"伴奏"逐词比对不上——不补 isASCIITag 分流的话这里会
		// 误判成"纯噪音括号"给回 120,而不是限定词该给的 60。
		{"中文版本括号只到括号档(伴奏)", "蜗牛 (伴奏)", "蜗牛", 60},
		{"中文版本括号只到括号档(伴奏版,词元被粘连)", "蜗牛 (伴奏版)", "蜗牛", 60},
	}
	for _, c := range cases {
		if got := titleMatchTierPoints(c.cand, c.local); got != c.want {
			t.Errorf("%s: titleMatchTierPoints(%q, %q) = %d, want %d", c.name, c.cand, c.local, got, c.want)
		}
	}
}

func TestAlbumAffinityTerm(t *testing.T) {
	lyr := "[00:10.00]first real line here\n[00:20.00]second real line here\n[00:30.00]third real line here"
	find := func(terms []scoreTerm, kind string) int {
		for _, tm := range terms {
			if tm.Kind == kind {
				return tm.Points
			}
		}
		return 0
	}
	// 专辑 loose 相等 → albumScore=200 档 → +150
	_, terms := scoreLyricCandidateDetailed("someone", "song", "实况电影", 0,
		lyricCandidate{source: "qq", lyrics: lyr, album: "实况电影"}, false, 0)
	if got := find(terms, scoreTermAlbum); got != 150 {
		t.Errorf("专辑完全一致应 +150,实际 %+d", got)
	}
	// 候选没报专辑 → 零证据,不加不减
	_, terms = scoreLyricCandidateDetailed("someone", "song", "实况电影", 0,
		lyricCandidate{source: "qq", lyrics: lyr}, false, 0)
	if got := find(terms, scoreTermAlbum); got != 0 {
		t.Errorf("候选专辑缺失应是零证据(0),实际 %+d", got)
	}
	// 专辑对不上 → 只加不减:不能出现负的 album 项
	_, terms = scoreLyricCandidateDetailed("someone", "song", "实况电影", 0,
		lyricCandidate{source: "qq", lyrics: lyr, album: "Totally Different"}, false, 0)
	if got := find(terms, scoreTermAlbum); got < 0 {
		t.Errorf("专辑亲和是 bonus-only,不该扣分,实际 %+d", got)
	}
}

func TestContentConsensusPeers(t *testing.T) {
	same := "[00:01.00]this is the same lyric line one\n[00:05.00]and the very same line two here\n[00:09.00]closing line of the song text"
	diff := "[00:01.00]completely different words entirely\n[00:05.00]nothing shared with the others\n[00:09.00]another unrelated closing line"
	cands := []lyricCandidate{
		{source: "netease", lyrics: same},
		{source: "qq", lyrics: same},
		{source: "kugou", lyrics: diff},
	}
	peers := contentConsensusPeers("someone", "song", cands, 0)
	if peers["netease"] != 1 || peers["qq"] != 1 {
		t.Errorf("内容一致的两源应互为 peer(各 1),实际 netease=%d qq=%d", peers["netease"], peers["qq"])
	}
	if peers["kugou"] != 0 {
		t.Errorf("内容孤立的源 peers 应为 0,实际 %d", peers["kugou"])
	}
	// 防搜歪共伴闸:批内存在时长吻合的候选时,自身时长不吻合的候选领不到共识分。
	// same 末句 9s,diffFits 末句 98s 吻合 100s 曲长 → netease/qq 的 peer 数被闸成 0。
	diffFits := "[00:01.00]completely different words entirely\n[00:50.00]nothing shared with the others\n[01:38.00]another unrelated closing line"
	cands2 := []lyricCandidate{
		{source: "netease", lyrics: same},
		{source: "qq", lyrics: same},
		{source: "lrclib", lyrics: diffFits},
	}
	peers2 := contentConsensusPeers("someone", "song", cands2, 100)
	if peers2["netease"] != 0 || peers2["qq"] != 0 {
		t.Errorf("存在时长吻合候选时,时长不吻合的候选不该领共识分,实际 netease=%d qq=%d", peers2["netease"], peers2["qq"])
	}
	// 打分侧:peers>=2 → +250,peers==1 → +150
	lyr := "[00:10.00]first real line here\n[00:20.00]second real line here\n[00:30.00]third real line here"
	s2, _ := scoreLyricCandidateDetailed("someone", "song", "", 0, lyricCandidate{source: "qq", lyrics: lyr}, false, 2)
	s1, _ := scoreLyricCandidateDetailed("someone", "song", "", 0, lyricCandidate{source: "qq", lyrics: lyr}, false, 1)
	s0, _ := scoreLyricCandidateDetailed("someone", "song", "", 0, lyricCandidate{source: "qq", lyrics: lyr}, false, 0)
	if s2-s0 != 250 || s1-s0 != 150 {
		t.Errorf("共识分档位不对: peers2-peers0=%d(want 250), peers1-peers0=%d(want 150)", s2-s0, s1-s0)
	}
}

func TestUsableValueAdd(t *testing.T) {
	main := "[00:01.00]la la la one\n[00:02.00]lo lo lo two\n[00:03.00]le le le three\n[00:04.00]li li li four"
	trFull := "[00:01.00]中文一\n[00:02.00]中文二\n[00:03.00]中文三\n[00:04.00]中文四"
	trSparse := "[00:01.00]中文一\n[00:02.00]中文二\nx\ny\nz\nw"
	kanaMain := "[00:01.00]ひかりのなか one\n[00:02.00]こころのうた two\n[00:03.00]そらとうみが three"
	roma := "[00:01.00]hikari no naka\n[00:02.00]kokoro no uta\n[00:03.00]sora to umi ga"

	if tr, _ := usableValueAdd(main, trFull, "zh", "", "zh"); !tr {
		t.Error("覆盖全的中文译文配英文原文应判可用")
	}
	if tr, _ := usableValueAdd(main, trFull, "zh", "", "en"); tr {
		t.Error("目标语言 en 时中文译文不该判可用")
	}
	if tr, _ := usableValueAdd(main, trSparse, "zh", "", "zh"); tr {
		t.Error("覆盖不过半的译文不该判可用")
	}
	if tr, _ := usableValueAdd(trFull, trFull, "zh", "", "zh"); tr {
		t.Error("原文本身是中文(cjk>0.5)时不需要中文译文,不该加分")
	}
	if _, rm := usableValueAdd(kanaMain, "", "", roma, "zh"); !rm {
		t.Error("日文形态歌词配带时间轴罗马音应判可用")
	}
	if _, rm := usableValueAdd(main, "", "", roma, "zh"); rm {
		t.Error("非日文歌词的\"罗马音\"没有增值,不该判可用")
	}
}

func TestOvershootPenalty(t *testing.T) {
	dur := 100.0
	// 末句 115s > 100+5:物理矛盾
	over := "[00:01.00]aaa bbb ccc\n[01:50.00]ddd eee fff\n[01:55.00]ggg hhh iii"
	find := func(terms []scoreTerm, kind string) (int, bool) {
		for _, tm := range terms {
			if tm.Kind == kind {
				return tm.Points, true
			}
		}
		return 0, false
	}
	// 关键性质:即便 corroborated=true(别的源在同一点结束)也不豁免——两个源一起
	// 抓到同一个错版本正是印证机制的已知翻车形态。
	_, terms := scoreLyricCandidateDetailed("someone", "song", "", dur,
		lyricCandidate{source: "qq", lyrics: over}, true, 0)
	if p, ok := find(terms, scoreTermDurationOvershoot); !ok || p != -700 {
		t.Errorf("overshoot 应记独立项 -700,实际 %+d (present=%v)", p, ok)
	}
	if _, ok := find(terms, scoreTermCorroborated); ok {
		t.Error("overshoot 候选不该再拿到印证豁免那一项")
	}
}

// ---- 2026-08-12 审阅修复的回归断言 ----

func TestParenVersionTagsWordBoundary(t *testing.T) {
	// feat. 名单里的人名不该被当成版本词:normLoose 挤掉空格后 "featolivertree" 含
	// "live"、"featdemons" 含 "demo",子串匹配会把这类纯噪音括号错判成版本括号。
	for _, title := range []string{"Song (feat. Oliver Tree)", "Song (feat. Demons)", "Song (with Akon)"} {
		if tags := parenOnlyVersionTags(title); len(tags) != 0 {
			t.Errorf("%q 的括号是纯噪音,不该抽出版本词,实际 %v", title, tags)
		}
		if got := titleMatchTierPoints("Song", title); got != 120 {
			t.Errorf("%q 对裸标题候选应升回精确档 120,实际 %d", title, got)
		}
	}
	// 真的版本括号照旧要认出来
	for _, title := range []string{"Song (Live)", "Song (Acoustic Version)", "Song (Radio Edit)"} {
		if tags := parenOnlyVersionTags(title); len(tags) == 0 {
			t.Errorf("%q 的括号是真版本词,应该抽出来", title)
		}
	}
}

func TestUsableTranslationLanguageAndJapanese(t *testing.T) {
	main := "[00:01.00]one two three\n[00:02.00]four five six\n[00:03.00]seven eight nine\n[00:04.00]ten eleven twelve"
	trZh := "[00:01.00]中文一\n[00:02.00]中文二\n[00:03.00]中文三\n[00:04.00]中文四"
	// zh 译文 vs zh-hans 目标:主语言子标签相同就该判可用
	if tr, _ := usableValueAdd(main, trZh, "zh", "", "zh-hans"); !tr {
		t.Error("trLang=zh 与 targetLang=zh-hans 是同一种语言,应判可用")
	}
	// 汉字密集的日文原文 + 中文译文:不该被"原文已是中文"那道闸误杀
	jaMain := "[00:01.00]桜流し 春の空\n[00:02.00]記憶の海 深く沈む\n[00:03.00]永遠の夢 見果てぬまま\n[00:04.00]君の声 遠く響く"
	if cjkRatio(jaMain) <= 0.5 {
		t.Skipf("测试样本汉字占比 %.2f 未达 0.5,构造不出该场景", cjkRatio(jaMain))
	}
	if tr, _ := usableValueAdd(jaMain, trZh, "zh", "", "zh"); !tr {
		t.Error("汉字密集的日文原文配中文译文应判可用(kana 占比已排除中文原文)")
	}
	// 纯中文原文仍然不需要中文译文
	if tr, _ := usableValueAdd(trZh, trZh, "zh", "", "zh"); tr {
		t.Error("纯中文原文不需要中文译文,不该加分")
	}
}

func TestConsensusDeniedToOvershoot(t *testing.T) {
	// 两个源被同一个搜索词一起带到同一个错的完整版:内容一致、双双超出曲长、
	// 没有任何候选时长吻合 —— 正是 anyFits 闸盖不住、必须靠 overshoot 规则收手的局面。
	long := "[00:01.00]same wrong version line one\n[01:30.00]same wrong version line two\n[02:30.00]same wrong version line three"
	cands := []lyricCandidate{
		{source: "qq", lyrics: long},
		{source: "kugou", lyrics: long},
	}
	peers := contentConsensusPeers("someone", "song", cands, 100) // 曲长 100s,末句 150s
	if peers["qq"] != 0 || peers["kugou"] != 0 {
		t.Errorf("overshoot 候选不该领跨源共识分,实际 qq=%d kugou=%d", peers["qq"], peers["kugou"])
	}
}

func TestLyricsUpgradeBaselineAcrossScoringVersions(t *testing.T) {
	const oldLyrics = "[00:01.00]stored line one\n[00:02.00]stored line two\n[00:03.00]stored line three"
	e := enrichEntry{
		Lyrics:               oldLyrics,
		LyricsSource:         "kugou",
		LyricsScore:          549, // 按 v2 规则算出来的分
		LyricsScoringVersion: 2,
	}
	scored := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: "[00:01.00]other", Score: 700},
		{Source: "kugou", Lyrics: oldLyrics, Score: 880}, // 同一份歌词在当前规则下的分
	}
	// 版本落后:基准必须换成"同一份歌词在这一轮的分",不能拿 v2 的 549 去比 v3 的分
	if base, ok := lyricsUpgradeBaseline(e, scored); !ok || base != 880 {
		t.Errorf("跨版本应改用同一份歌词的本轮分 880 作基准,实际 base=%d ok=%v", base, ok)
	}
	// 版本落后且现存歌词这轮没出现 → 不可比,这一轮不该换
	if _, ok := lyricsUpgradeBaseline(e, scored[:1]); ok {
		t.Error("现存歌词不在本轮候选里时应判为不可比,交给 rescore 收编")
	}
	// 版本一致:照旧用存量分
	e.LyricsScoringVersion = lyricsScoringVersion
	if base, ok := lyricsUpgradeBaseline(e, scored); !ok || base != 549 {
		t.Errorf("同版本应直接用存量分 549,实际 base=%d ok=%v", base, ok)
	}
}

// ---- v5(2026-08-27):applyWordTimingTitleOverride ----
//
// 数字全部来自真实曲库的 lyrics_decision 记录(方大同《公园 (Live版)》,收在专辑「大事发声·
// 录音棚现场:方大同专场」),不是编的——见 lyricsScoringVersion 注释里的消融数据出处。

func TestApplyWordTimingTitleOverride_RealWorldCase(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{
			Source: "kugou", Score: 944, Title: "公园 (Live)", Album: "Timeless演唱会",
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermDuration, Points: 170},
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermLines, Points: 64},
				{Kind: scoreTermTitleMatch, Points: 60},
				{Kind: scoreTermConsensus, Points: 250},
			},
		},
		{
			Source: "netease", Score: 674, Title: "公园 (Live版)", Album: "方大同·专场",
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermDuration, Points: 169},
				{Kind: scoreTermLines, Points: 60},
				{Kind: scoreTermAlbum, Points: 75},
				{Kind: scoreTermTitleMatch, Points: 120},
				{Kind: scoreTermConsensus, Points: 250},
			},
		},
	}
	applyWordTimingTitleOverride(results)

	kugou, netease := &results[0], &results[1]
	if kugou.Score != 544 {
		t.Errorf("酷狗的逐字加分应被整段撤销:944-400=544,实际 %d", kugou.Score)
	}
	if p := scoreTermPoints(kugou.ScoreTerms, scoreTermWordTimingOverride); p != -400 {
		t.Errorf("应该多出一条 wordTimingOverride:-400,实际 %d", p)
	}
	if netease.Score != 674 {
		t.Errorf("网易云不该被这条规则动到,实际 %d", netease.Score)
	}
	// 撤销之后排序必须真的翻盘——这是最终能不能选对源的唯一标准,光改分不够。
	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	if results[0].Source != "netease" {
		t.Errorf("修复后冠军应该是 netease(674 > 544),实际是 %s", results[0].Source)
	}
}

// 姊妹案例(同一批消融找到的另一个,迈克尔·杰克逊单曲版混进原声带的场景):专辑名部分
// 对得上、标题吻合分同样反超,同一条规则应该同样命中。
func TestApplyWordTimingTitleOverride_SecondRealWorldCase(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{
			Source: "kugou", Score: 1059,
			Title: "Shake Your Body (Remastered Single Version)", Album: "Michael Jackson's This Is It",
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermAlbum, Points: 75},
				{Kind: scoreTermTitleMatch, Points: 60},
				{Kind: scoreTermConsensus, Points: 250},
				{Kind: scoreTermLines, Points: 60},
				{Kind: scoreTermDuration, Points: 214}, // 凑够 1059:400+75+60+250+60+214
			},
		},
		{
			Source: "musixmatch", Score: 825,
			Title: "Shake Your Body (Down to the Ground) [Single Version]",
			Album: "Michael Jackson's This Is It (The Music That Inspired the Movie)",
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermAlbum, Points: 150},
				{Kind: scoreTermTitleMatch, Points: 120},
				{Kind: scoreTermConsensus, Points: 250},
				{Kind: scoreTermLines, Points: 90},
				{Kind: scoreTermDuration, Points: 215}, // 凑够 825
			},
		},
	}
	applyWordTimingTitleOverride(results)
	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	if results[0].Source != "musixmatch" {
		t.Errorf("修复后冠军应该是 musixmatch(标题/专辑都更吻合),实际是 %s", results[0].Source)
	}
}

// 反向护栏:标题吻合分**没有**站在亚军那边时(哪怕专辑名有差异、哪怕逐字确实是决定性
// 因素),这条规则绝对不能出手——这是"窄口子"这三个字的字面意思,也是为什么另外
// 238 个真实决定性案例不受影响的原因。数字取自 Ariana Grande《big feelings》案的形状:
// 两边标题吻合分相等(查询词没有版本括号可比),专辑名有"(Explicit)"标签差异。
func TestApplyWordTimingTitleOverride_DoesNotFireWhenTitleDoesNotFavorRunnerUp(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{
			Source: "kugou", Score: 400 + 75 + 120,
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermAlbum, Points: 75},
				{Kind: scoreTermTitleMatch, Points: 120}, // 跟亚军相等,不是"严格更高"
			},
		},
		{
			Source: "netease", Score: 150 + 120,
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermAlbum, Points: 150},
				{Kind: scoreTermTitleMatch, Points: 120}, // 跟冠军相等
			},
		},
	}
	before := results[0].Score
	applyWordTimingTitleOverride(results)
	if results[0].Score != before {
		t.Errorf("标题吻合分相等(不是亚军严格更高)时不该触发撤销,分数从 %d 变成了 %d", before, results[0].Score)
	}
}

// 没有逐字加分的冠军:整条规则的第一道闸(wtPoints<=0)必须挡住,不能误伤"冠军本来就
// 没靠逐字赢"的正常案例。
func TestApplyWordTimingTitleOverride_NoOpWithoutWordTiming(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{Source: "netease", Score: 900, ScoreTerms: []scoreTerm{{Kind: scoreTermAlbum, Points: 150}, {Kind: scoreTermTitleMatch, Points: 120}}},
		{Source: "qq", Score: 500, ScoreTerms: []scoreTerm{{Kind: scoreTermTitleMatch, Points: 500}}},
	}
	applyWordTimingTitleOverride(results)
	if results[0].Score != 900 || len(results[0].ScoreTerms) != 2 {
		t.Error("冠军没有 wordTiming 加分时,函数不该动任何分数或加任何新 term")
	}
}

// 逐字加分不是决定性因素时(冠军去掉 +400 依然是冠军)不该触发——这条规则只管"逐字
// 是唯一让它赢的理由"这一种情况,不是"只要有逐字就要跟标题比一比"。
func TestApplyWordTimingTitleOverride_NoOpWhenWordTimingNotDecisive(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{
			Source: "kugou", Score: 1200,
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermAlbum, Points: 150},
				{Kind: scoreTermTitleMatch, Points: 30}, // 就算比亚军低也无所谓:去掉 400 仍是冠军
				{Kind: scoreTermConsensus, Points: 250},
				{Kind: scoreTermLines, Points: 370},
			},
		},
		{
			Source: "netease", Score: 600,
			ScoreTerms: []scoreTerm{{Kind: scoreTermTitleMatch, Points: 120}},
		},
	}
	before := results[0].Score
	applyWordTimingTitleOverride(results)
	if results[0].Score != before {
		t.Errorf("去掉逐字加分冠军依然是冠军(800>600)时不该触发,分数从 %d 变成了 %d", before, results[0].Score)
	}
}

// 一票否决/纯音乐标记(Score<0)不该被当成候选池的一员,不管是当"冠军"还是当"亚军"。
func TestApplyWordTimingTitleOverride_SkipsRejectedCandidates(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{Source: "lrclib", Score: -1, Instrumental: true},
		{
			Source: "kugou", Score: 500,
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermTitleMatch, Points: 30},
			},
		},
		{Source: "musixmatch", Score: -1, ScoreTerms: []scoreTerm{{Kind: scoreRejectNotTimed}}},
	}
	applyWordTimingTitleOverride(results)
	if results[1].Score != 500 {
		t.Errorf("只有一个真实候选、没有亚军可比时不该触发,分数从 500 变成了 %d", results[1].Score)
	}
	if results[0].Score != -1 || results[2].Score != -1 {
		t.Error("一票否决/纯音乐标记的分数不该被这条规则改动")
	}
}

// 2026-08-28 用户报「搜索候选歌词」把方大同《南音》的正确候选判成"语言跟这首歌对不上"
// 而拒绝采用——本地标签(Apple Music)罗马化写成 artist="Khalil Fong" title="Nanyin",
// 两者都不含汉字,candidateArtist 补上之前测不出来的这一层信息(候选源自己确认匹配到的
// 歌手,已经过前置的歌手身份闸,不是瞎猜):它含汉字就说明这首歌本来就该有中文候选,不是
// "上传者把翻译当原文传错了"。
func TestIsProbablyWrongLanguageLyrics(t *testing.T) {
	chineseLyrics := "[00:13.76]在他的墨鏡裡\n[00:16.38]看不到二泉的月映有多麼朦朧\n[00:21.77]只記得少年時"
	englishLyrics := "[00:00.10]this is an english lyric line\n[00:03.20]another english line here today"

	cases := []struct {
		name                                             string
		localArtist, localTitle, candidateArtist, lyrics string
		want                                             bool
	}{
		{
			name:        "罗马化标签+候选源确认的中文歌手名→不拦",
			localArtist: "Zyx Qwerty Nonexistent", localTitle: "Some Song", candidateArtist: "方大同",
			lyrics: chineseLyrics, want: false,
		},
		{
			// "Pei-yu Hung" 真实存在于 artistAliasTable(→"洪佩瑜")——这条测的是
			// knownArtistAlias 那道豁免本身,不是"候选源给没给中文名"那道。2026-08-31
			// 手工表缩到只剩两条通用机制(MusicBrainz+QQ)都覆盖不了的真实残留案例,
			// 用例跟着换成现存的那条(原来的"方大同/Khalil Fong"已经被通用机制覆盖、
			// 从表里删掉了,不能再用来测手工表本身)。
			name:        "罗马化标签在手工别名表里能查到中文名(洪佩瑜真实残留案例)→不拦,即使候选源没给中文名",
			localArtist: "Pei-yu Hung", localTitle: "Some Song", candidateArtist: "",
			lyrics: chineseLyrics, want: false,
		},
		{
			// 用一个**不在**别名表里的虚构罗马化名字,确保测的是"没有任何救援信号"
			// 这一档,不会被表里恰好登记过的真实歌手悄悄救回去。
			name:        "罗马化标签+候选源没给出歌手名+别名表也没登记→维持原判,拦",
			localArtist: "Zyx Qwerty Nonexistent", localTitle: "Some Song", candidateArtist: "",
			lyrics: chineseLyrics, want: true,
		},
		{
			name:        "罗马化标签+候选源报的歌手名同样是罗马化写法+别名表也没登记→救不了,拦",
			localArtist: "Zyx Qwerty Nonexistent", localTitle: "Some Song", candidateArtist: "Some Artist",
			lyrics: chineseLyrics, want: true,
		},
		{
			name:        "本地标签本身含汉字→本来就不适用这条判断,不拦",
			localArtist: "方大同", localTitle: "南音", candidateArtist: "",
			lyrics: chineseLyrics, want: false,
		},
		{
			name:        "本地标签非中文+候选正文也非中文→本来就没有语言分歧,不拦",
			localArtist: "Ed Sheeran", localTitle: "Shape of You", candidateArtist: "Ed Sheeran",
			lyrics: englishLyrics, want: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := isProbablyWrongLanguageLyrics(c.localArtist, c.localTitle, c.candidateArtist, c.lyrics)
			if got != c.want {
				t.Errorf("isProbablyWrongLanguageLyrics(%q, %q, %q, ...) = %v, want %v",
					c.localArtist, c.localTitle, c.candidateArtist, got, c.want)
			}
		})
	}
}

// 2026-08-30 真实bug:那英《微笑着离去》本地标签罗马化成 artist="Na Ying" title=
// "Smiled Then Passed",LRCLIB 报的 candidateArtist 同样是罗马化写法(它自己也没有这位
// 歌手的中文数据),手工表(artistAliasTable)也没登记——不是每个知名歌手都恰好被人工
// 录入过,真实的中文歌词被误判成"传错语言的翻译"拒收。
//
// 用户反问「怎么还在维护手工表？不能通用处理吗」——正确答案是通用处理:
// canonicalArtistViaMusicBrainz/musicBrainzArtistAliases 这两条 resolve 链路里本来就在
// 跑的 MusicBrainz 查询,只要为了别的目的(CanonicalArtist 解析/别名重试)查过这位歌手
// 一次,答案就已经缓存在 artistAliasCache/mbPrimaryNameCache 里——isProbablyWrongLanguageLyrics
// 只读窥探这两份缓存即可,不需要把"Na Ying"手工写进 artistAliasTable。这里直接预置缓存
// 模拟"MusicBrainz 已经查到过"的状态,不发真实网络请求。
func TestIsProbablyWrongLanguageLyricsUsesResolvedArtistCacheHint(t *testing.T) {
	chineseLyrics := "[00:35.34]不要把臉藏在月光背後\n[00:41.77]有誰在意我們的生活\n[00:45.67]坐在安靜角落"

	t.Run("artistAliasCache 命中→不拦", func(t *testing.T) {
		saved := artistAliasCache
		defer func() { artistAliasCache = saved }()
		artistAliasCache = map[string]string{"Na Ying": "那英"}

		if got := isProbablyWrongLanguageLyrics("Na Ying", "Smiled Then Passed", "Na Ying", chineseLyrics); got {
			t.Error("artistAliasCache 里已经查到中文名时不该拦")
		}
	})

	t.Run("mbPrimaryNameCache 命中→不拦", func(t *testing.T) {
		saved := mbPrimaryNameCache
		defer func() { mbPrimaryNameCache = saved }()
		mbPrimaryNameCache = map[string][]string{"Na Ying": {"那英"}}

		if got := isProbablyWrongLanguageLyrics("Na Ying", "Smiled Then Passed", "Na Ying", chineseLyrics); got {
			t.Error("mbPrimaryNameCache 里已经查到中文名时不该拦")
		}
	})

	t.Run("两份缓存都没查到→维持原判,拦", func(t *testing.T) {
		savedAlias, savedMB := artistAliasCache, mbPrimaryNameCache
		defer func() { artistAliasCache, mbPrimaryNameCache = savedAlias, savedMB }()
		artistAliasCache = map[string]string{}
		mbPrimaryNameCache = map[string][]string{}

		if got := isProbablyWrongLanguageLyrics("Na Ying", "Smiled Then Passed", "Na Ying", chineseLyrics); !got {
			t.Error("两份缓存都没有线索时应该维持原判(拦),不该凭空放行")
		}
	})

	t.Run("mbPrimaryNameCache 里全是非中文候选(查过但没有中文名)→不该误判成命中", func(t *testing.T) {
		saved := mbPrimaryNameCache
		defer func() { mbPrimaryNameCache = saved }()
		mbPrimaryNameCache = map[string][]string{"Some Artist": {"Some Other Latin Name"}}

		if got := isProbablyWrongLanguageLyrics("Some Artist", "Some Song", "Some Artist", chineseLyrics); !got {
			t.Error("缓存里的候选全是非中文时不该触发豁免")
		}
	})
}

// TestAlbumTokensLatinCJKBoundary 钉死 v9 的拉丁↔CJK 交界分词(周杰伦《The One》案:
// QQ 音乐把专辑写成 "The One演唱会",One 和 演唱会 之间不留空格)。
func TestAlbumTokensLatinCJKBoundary(t *testing.T) {
	got := albumTokens("The One演唱会")
	if !got["one"] || !got["演唱会"] {
		t.Errorf("albumTokens(\"The One演唱会\") = %v,应拆出 one + 演唱会", got)
	}
	if got["one演唱会"] {
		t.Errorf("albumTokens(\"The One演唱会\") 不该再有粘连词元 one演唱会:%v", got)
	}
	// 既有的数字↔字母交界分词不回退
	got = albumTokens("2011Live")
	if !got["2011"] || !got["live"] {
		t.Errorf("albumTokens(\"2011Live\") = %v,应拆出 2011 + live", got)
	}
	// CJK 内部仍不分词
	got = albumTokens("周杰伦地表最强世界巡回演唱会")
	if len(got) != 1 || !got["周杰伦地表最强世界巡回演唱会"] {
		t.Errorf("纯 CJK 串仍应是单一词元,got %v", got)
	}
}

// TestAlbumScoreCrossScriptGlue:v9 之前 albumScore("The One演唱会", "The One 周杰伦演唱会")
// 是 0(粘连词元 one演唱会 和 one/周杰伦演唱会 零共享)——同一张专辑被判毫无亲和。
func TestAlbumScoreCrossScriptGlue(t *testing.T) {
	if sc := albumScore("The One演唱会", "The One 周杰伦演唱会"); sc < 1 {
		t.Errorf("QQ 拼法与本地拼法应有词元亲和,got %d", sc)
	}
	// 无关专辑仍为 0
	if sc := albumScore("八度空间", "The One 周杰伦演唱会"); sc != 0 {
		t.Errorf("八度空间 vs The One 应为 0,got %d", sc)
	}
}

// TestVersionTagsMismatchAlbumCJKLiveMarker 钉死 v9 的 recordingVersionTags:
// 专辑名带中文现场标记(演唱会/现场/音乐会)视同声明了 live,双向对称。
func TestVersionTagsMismatchAlbumCJKLiveMarker(t *testing.T) {
	cases := []struct {
		name                                         string
		localTitle, localAlbum, candTitle, candAlbum string
		want                                         bool
	}{
		// 本案:QQ 给 The One 演唱会曲目起名不带 (Live),live 身份只在专辑名上
		{"QQ 现场专辑曲目不再吃 -600", "龙拳 (Live)", "The One 周杰伦演唱会", "龙拳", "The One演唱会", false},
		// 录音室候选照旧拦住
		{"录音室候选仍 mismatch", "龙拳 (Live)", "The One 周杰伦演唱会", "龙拳", "八度空间", true},
		// 对称的新保护:本地是现场专辑(曲名干净),候选是干净录音室版 → 现在能判出来
		{"本地现场专辑 vs 录音室候选", "龙拳", "The One 周杰伦演唱会", "龙拳", "八度空间", true},
		// 拉丁 live 词元刻意不认:《Live and Let Die》是录音室发行的合法专辑名
		{"拉丁 live 词元不触发", "Live and Let Die", "Live and Let Die", "Live and Let Die", "Shaved Fish", false},
		// 两边都是中文现场专辑命名 → 集合相等,不 mismatch(是不是同一场交给 liveAlbumConflict)
		{"双方专辑均带演唱会字样", "晴天", "XX演唱会", "晴天", "YY音乐会", false},
	}
	for _, c := range cases {
		if got := versionTagsMismatch(c.localTitle, c.localAlbum, c.candTitle, c.candAlbum); got != c.want {
			t.Errorf("%s:versionTagsMismatch(%q,%q,%q,%q) = %v,want %v",
				c.name, c.localTitle, c.localAlbum, c.candTitle, c.candAlbum, got, c.want)
		}
	}
}
