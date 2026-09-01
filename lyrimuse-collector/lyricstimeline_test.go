package main

import "testing"

// 测试数据全部取自真实缓存条目 Adele|Rumour Has It|21(2026-08-27 用户报的那首)。
// 它是这条修复的原始案例:LRC 与 YRC 逐行文本完全相同、行数相同,只有时间戳是两套。
const (
	// 坏的行级 LRC:第 4/5 行间隔 0.75s(唱不完一整句),第 14/15 行是带**字面左括号**的
	// "(rumour)" —— 这一对是那个正则 bug 的回归钉子。
	rumourLRC = "[ti:Rumour Has It]\n" +
		"[ar:Adele]\n" +
		"\n" +
		"[00:27.41] She, she ain't real\n" +
		"[00:28.16] She ain't gon' be able to love you like I will\n" +
		"[00:48.43] Rumour has it (rumour)\n" +
		"[00:50.82] Rumour has it (rumour)"
	rumourYRC = "[18315,1857](18315,1212,0)She, (19527,177,0)she (19704,299,0)ain't (20003,169,0)real\n" +
		"[21184,1900](21184,48,0)She (21232,96,0)ain't (21328,100,0)gon' (21428,167,0)be (21595,233,0)able (21828,378,0)to (22206,288,0)love (22494,223,0)you (22717,311,0)like (23028,56,0)I (23084,0,0)will\n" +
		"[59722,1414](59722,187,0)Rumour (59909,34,0)has (59943,11,0)it (59954,1182,0)(rumour)\n" +
		"[61136,462](61136,262,0)Rumour (61398,67,0)has (61465,44,0)it (61509,89,0)(rumour)"
	rumourTr = "[00:27.41]她，她不是真的\n" +
		"[00:28.16]她不可能像我一样爱你\n" +
		"[00:48.43]有传言（谣言）"
)

// 字面左括号的回归钉子:词文本里的 "(rumour)" 必须完整解析出来。
// 早先用 `\((\d+),(\d+),\d+\)([^(]*)` 抓词文本时,这一行会被解析成 "Rumour has it",
// 与 LRC 侧的 "Rumour has it (rumour)" 字面对不上,整份条目被静默放弃重挂。
func TestYRCLineHeadsKeepsLiteralParens(t *testing.T) {
	heads := yrcLineHeads(rumourYRC)
	if len(heads) != 4 {
		t.Fatalf("行数: got %d want 4", len(heads))
	}
	if heads[2].text != "Rumour has it (rumour)" {
		t.Errorf("字面左括号被截断: got %q want %q", heads[2].text, "Rumour has it (rumour)")
	}
	if heads[0].ms != 18315 || heads[3].ms != 61136 {
		t.Errorf("行首时间: got %d/%d want 18315/61136", heads[0].ms, heads[3].ms)
	}
}

func TestRehangLRCOnYRCRealCase(t *testing.T) {
	got, remap, ok := rehangLRCOnYRC(rumourLRC, rumourYRC, 223.266, true)
	if !ok {
		t.Fatal("应当重挂,实际放弃了")
	}
	want := "[ti:Rumour Has It]\n" +
		"[ar:Adele]\n" +
		"\n" +
		"[00:18.31]She, she ain't real\n" +
		"[00:21.18]She ain't gon' be able to love you like I will\n" +
		"[00:59.72]Rumour has it (rumour)\n" +
		"[01:01.13]Rumour has it (rumour)"
	if got != want {
		t.Errorf("重挂结果不符\ngot:\n%s\nwant:\n%s", got, want)
	}
	// 元数据行与空行必须原样保留 —— 打分的 lines 项按 len(Split(lyrics,"\n")) 计,
	// 丢了它们会让候选平白掉分(实测这个 bug 在消融里造出 175 条假翻盘)。
	if n := len(splitLines(got)); n != len(splitLines(rumourLRC)) {
		t.Errorf("行数变了: got %d want %d", n, len(splitLines(rumourLRC)))
	}
	// 映射给译文用:旧 27.41s → 新 18.315s
	if remap[27410] != 18315 {
		t.Errorf("remap[27410]: got %d want 18315", remap[27410])
	}
}

// 幂等:重挂过的内容再跑一次必须是空操作(启动期迁移每次开机都会跑)。
func TestRehangLRCOnYRCIdempotent(t *testing.T) {
	once, _, ok := rehangLRCOnYRC(rumourLRC, rumourYRC, 223.266, true)
	if !ok {
		t.Fatal("第一遍应当重挂")
	}
	if _, _, ok2 := rehangLRCOnYRC(once, rumourYRC, 223.266, true); ok2 {
		t.Error("第二遍不该再改")
	}
}

func TestRehangLRCOnYRCRejects(t *testing.T) {
	cases := []struct {
		name string
		lrc  string
		yrc  string
	}{
		{
			// netease 那 544/568 条的形态:LRC 多一行署名,行数对不上就别猜。
			name: "行数不等",
			lrc:  "[00:27.41] She, she ain't real\n[00:28.16] She ain't gon' be able to love you like I will\n[00:48.43] 制作人 : Someone",
			yrc:  rumourYRC,
		},
		{
			name: "逐行文本对不上",
			lrc:  "[00:27.41] 完全不同的一句\n[00:28.16] 另一句也不同\n[00:48.43] 第三句\n[00:50.82] 第四句",
			yrc:  rumourYRC,
		},
		{
			// 一行挂多个时间戳(同一句在多处重复唱),与 YRC 行不再一一对应。
			name: "一行多戳",
			lrc:  "[00:27.41][01:27.41] She, she ain't real\n[00:28.16] She ain't gon' be able to love you like I will\n[00:48.43] Rumour has it (rumour)\n[00:50.82] Rumour has it (rumour)",
			yrc:  rumourYRC,
		},
		{
			name: "逐字轴乱序",
			lrc:  rumourLRC,
			yrc: "[59722,1414](59722,187,0)She, (59909,34,0)she (59943,11,0)ain't (59954,1182,0)real\n" +
				"[21184,1900](21184,48,0)She (21232,96,0)ain't (21328,100,0)gon' (21428,167,0)be (21595,233,0)able (21828,378,0)to (22206,288,0)love (22494,223,0)you (22717,311,0)like (23028,56,0)I (23084,0,0)will\n" +
				"[18315,1857](18315,1212,0)Rumour (19527,177,0)has (19704,299,0)it (20003,169,0)(rumour)\n" +
				"[61136,462](61136,262,0)Rumour (61398,67,0)has (61465,44,0)it (61509,89,0)(rumour)",
		},
		{name: "没有逐字轴", lrc: rumourLRC, yrc: ""},
		{name: "没有正文", lrc: "", yrc: rumourYRC},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, _, ok := rehangLRCOnYRC(c.lrc, c.yrc, 223.266, true)
			if ok {
				t.Errorf("应当放弃重挂,实际改了:\n%s", got)
			}
			if got != c.lrc {
				t.Error("放弃时必须原样返回")
			}
		})
	}
}

// 安全闸:重挂后 durationFits 从 true 变 false 就放弃。
//
// 真实反例 MJ《Rock With You (Single Version)》(曲长 204.2s):两套轴同样打架,但坏的是
// **YRC** 那边 —— 重挂后末句从 176.1s 跳到 216.6s,尾巴甩出曲目 12 秒。全库 516 条可判
// 时长的条目里正好有这么 1 条会被改坏。这里用同款数字构造最小用例。
func TestRehangLRCOnYRCDurationGuard(t *testing.T) {
	lrc := "[02:56.10]first line here\n[02:56.20]second line here"
	yrc := "[216600,500](216600,250,0)first (216850,250,0)line (217100,100,0)here\n" +
		"[216700,500](216700,250,0)second (216950,250,0)line (217200,100,0)here"
	const dur = 204.2
	if _, _, ok := rehangLRCOnYRC(lrc, yrc, dur, true); ok {
		t.Error("重挂会让歌词尾巴甩出曲目,安全闸应当拦下")
	}
	// 同样的数据,不给曲长(无从判断)时不设闸 —— 拿不准就按既有纪律放行。
	// 曲长未知 + 带闸 = 放弃(校验不了就不赌)。
	if _, _, ok := rehangLRCOnYRC(lrc, yrc, 0, true); ok {
		t.Error("曲长未知时带闸应当放弃")
	}
	// 不带闸(只有消融在用)才照改。
	if _, _, ok := rehangLRCOnYRC(lrc, yrc, 0, false); !ok {
		t.Error("不带闸时应当照改")
	}
}

func TestRemapLRCTimestamps(t *testing.T) {
	_, remap, ok := rehangLRCOnYRC(rumourLRC, rumourYRC, 223.266, true)
	if !ok {
		t.Fatal("前置重挂失败")
	}
	got, changed := remapLRCTimestamps(rumourTr, remap)
	if !changed {
		t.Fatal("译文应当被搬到新轴")
	}
	want := "[00:18.31]她，她不是真的\n" +
		"[00:21.18]她不可能像我一样爱你\n" +
		"[00:59.72]有传言（谣言）"
	if got != want {
		t.Errorf("译文重挂不符\ngot:\n%s\nwant:\n%s", got, want)
	}
	// 附属歌词常比正文少几行(没译到的行本来就不写),缺行是正常情况,
	// 不该因此整份放弃 —— 只搬查得到的。
	partial := "[00:27.41]她，她不是真的\n[09:99.99]查不到的一行"
	got2, changed2 := remapLRCTimestamps(partial, remap)
	if !changed2 {
		t.Fatal("有一行能搬就该搬")
	}
	if got2 != "[00:18.31]她，她不是真的\n[09:99.99]查不到的一行" {
		t.Errorf("查不到的行应原样保留: got %q", got2)
	}
	if _, changed3 := remapLRCTimestamps("", remap); changed3 {
		t.Error("空译文不该报 changed")
	}
}

func TestRehangCandidateTimelines(t *testing.T) {
	cands := []lyricCandidate{
		{source: "musixmatch", lyrics: rumourLRC, wordTimingYRC: rumourYRC},
		{source: "lrclib", lyrics: rumourLRC}, // 没有逐字轴,不该被碰
	}
	rehangCandidateTimelines(cands, 223.266)
	if cands[0].lyrics == rumourLRC {
		t.Error("带逐字轴的候选应当被重挂")
	}
	if len(cands[0].timelineRemap) == 0 {
		t.Error("重挂过的候选应当留下映射供译文复用")
	}
	if cands[1].lyrics != rumourLRC || cands[1].timelineRemap != nil {
		t.Error("没有逐字轴的候选不该被动")
	}
}

// ---- 逐字轴自相矛盾 → 弃用(2026-09-01) ----
//
// 测试数据取自真实缓存条目 陈奕迅|2001太空漫游 (Live)|The Easy Ride 演唱会 (Live)
// (用户报"LRC 写着 32 秒有词、播放到 32 秒人已开唱歌词却不出"):netease 的行级与逐字
// 是两条独立产线,这一条两套轴断行方式不同、行数不等(39 vs 40),rehangLRCOnYRC 修不了,
// 而配对行的时间差 41~72 秒(中位 55.5s)——播放走 YRC,首句 74.3s 才出,比 LRC(和人声)
// 晚了 42 秒。以下各取真实第一段主歌(10 行 LRC / 10 行 YRC,其中"水星"一行两边转写
// 不同、配不上,恰好覆盖"允许少数行配不上"的路径)。
const (
	taikongLRC = "[00:32.30]大预言话:地球是大限将至\n" +
		"[00:36.10]到今天还是未有事\n" +
		"[00:40.29]未是时候就无谓乱下赌注\n" +
		"[00:44.10]去侦测太空怎样住\n" +
		"[00:48.10]水星 发梦有附送\n" +
		"[00:50.80]火星 怪物无尽\n" +
		"[00:52.10]可否 继续留在被窝之中(其实)\n" +
		"[00:55.61]金星 引力那样重\n" +
		"[00:58.90]土星 行为迟钝\n" +
		"[01:00.38]穿梭机中 几秒后已经想看钟"
	taikongYRC = "[74349,3290](74349,242,0)大(74591,170,0)预(74761,164,0)言(74925,196,0)话(75121,168,0):(75289,170,0)地(75459,160,0)球(75619,190,0)是(75809,208,0)大(76017,264,0)限(76281,232,0)将(76513,1126,0)至\n" +
		"[77639,3999](77639,200,0)到(77839,198,0)今(78037,204,0)天(78241,216,0)还(78457,264,0)是(78721,230,0)未(78951,214,0)有(79165,2473,0)事\n" +
		"[81638,3236](81638,196,0)未(81834,180,0)是(82014,182,0)时(82196,258,0)候(82454,180,0)就(82634,216,0)无(82850,218,0)谓(83068,210,0)乱(83278,216,0)下(83494,216,0)赌(83710,1164,0)注\n" +
		"[84874,3868](84874,248,0)去(85122,212,0)侦(85334,200,0)测(85534,196,0)太(85730,256,0)空(85986,246,0)怎(86232,218,0)样(86450,2292,0)住\n" +
		"[88742,1850](88742,220,0)水(88962,408,0)星 (89370,228,0)引(89598,232,0)力(89830,224,0)那(90054,232,0)样(90286,306,0)重\n" +
		"[90592,1799](90592,226,0)火(90818,248,0)星 (91066,240,0)怪(91306,204,0)物(91510,248,0)无(91758,633,0)尽\n" +
		"[92391,3480](92391,208,0)可(92599,224,0)否 (92823,272,0)继(93095,720,0)续(93815,236,0)留(94051,216,0)在(94267,204,0)被(94471,200,0)窝(94671,200,0)之(94871,232,0)中(95103,264,0)（(95367,216,0)其(95583,288,0)实\n" +
		"[96159,1656](96159,198,0)金(96357,234,0)星 (96591,228,0)引(96819,232,0)力(97051,252,0)那(97303,208,0)样(97511,304,0)重\n" +
		"[97815,1888](97815,224,0)土(98039,252,0)星 (98291,252,0)行(98543,244,0)为(98787,248,0)迟(99035,668,0)钝\n" +
		"[99703,5021](99703,206,0)穿(99909,202,0)梭(100111,220,0)机(100331,374,0)中 (100705,212,0)几(100917,214,0)秒(101131,282,0)后(101413,206,0)已(101619,200,0)经(101819,232,0)想(102051,212,0)看(102263,2461,0)钟"
)

func TestWordTimingContradictsLRC(t *testing.T) {
	// 真实打架数据:9/10 行配上、中位偏差约 41.5s → 矛盾成立
	if !wordTimingContradictsLRC(taikongLRC, taikongYRC) {
		t.Error("《2001太空漫游 (Live)》形态(中位偏差 40s+)应判为矛盾")
	}
	// 同一批 YRC,把 LRC 时间戳换成跟 YRC 一致的 → 不矛盾(自洽双轴的常态,全库 92% <0.5s)
	consistent := "[01:14.35]大预言话:地球是大限将至\n" +
		"[01:17.64]到今天还是未有事\n" +
		"[01:21.64]未是时候就无谓乱下赌注\n" +
		"[01:24.87]去侦测太空怎样住\n" +
		"[01:28.74]水星 发梦有附送\n" +
		"[01:30.59]火星 怪物无尽\n" +
		"[01:32.39]可否 继续留在被窝之中(其实)\n" +
		"[01:36.16]金星 引力那样重\n" +
		"[01:37.82]土星 行为迟钝\n" +
		"[01:39.70]穿梭机中 几秒后已经想看钟"
	if wordTimingContradictsLRC(consistent, taikongYRC) {
		t.Error("时间戳基本一致的双轴不该判矛盾")
	}
	// 配对行不足 8 行时不可判 —— Rumour Has It 那组只有 4 行,单行偏差 9~11s,
	// 但样本太少、中位数不可信,必须放行(那一类归 rehangLRCOnYRC 管,而且它真能修)。
	if wordTimingContradictsLRC(rumourLRC, rumourYRC) {
		t.Error("配对行不足下限时不该判矛盾(拿不准就不动)")
	}
	if wordTimingContradictsLRC("", taikongYRC) || wordTimingContradictsLRC(taikongLRC, "") {
		t.Error("缺任一侧时不该判矛盾")
	}
}

// 候选构造路径:重挂修不了且矛盾成立的候选,逐字轴连同 hasWordTiming 一起清掉 ——
// 它拿不到打分层 wordTiming 那 +400(自相矛盾的逐字轴不是质量证据),播放也退回行级。
func TestRehangCandidateTimelinesDropsContradictoryYRC(t *testing.T) {
	cands := []lyricCandidate{
		{source: "netease", lyrics: taikongLRC, wordTimingYRC: taikongYRC, hasWordTiming: true},
		{source: "musixmatch", lyrics: rumourLRC, wordTimingYRC: rumourYRC, hasWordTiming: true},
	}
	rehangCandidateTimelines(cands, 221.599)
	if cands[0].wordTimingYRC != "" || cands[0].hasWordTiming {
		t.Error("自相矛盾的逐字轴应被弃用")
	}
	// Rumour 那条是可重挂的(1:1 对应),必须走修复路径而不是弃用路径
	if cands[1].wordTimingYRC == "" || !cands[1].hasWordTiming {
		t.Error("可重挂的双轴不该被弃用")
	}
	if cands[1].lyrics == rumourLRC {
		t.Error("可重挂的候选应当被重挂")
	}
}

func splitLines(s string) []string {
	n := 1
	for _, r := range s {
		if r == '\n' {
			n++
		}
	}
	out := make([]string, 0, n)
	start := 0
	for i, r := range s {
		if r == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}
