package main

import (
	"strings"
	"testing"
)

// 演唱者标签识别 —— 用例全部照用户库里的真实形态写(见 lyricspeaker.go 顶部注释)。
func TestLyricSplitLabel(t *testing.T) {
	cases := []struct {
		in          string
		label, rest string
		ok          bool
	}{
		{"男：周末守着烤箱", "男", "周末守着烤箱", true},
		{"女: 偏爱年轻女伴", "女", "偏爱年轻女伴", true},
		{"周杰伦：", "周杰伦", "", true},   // 独占一行
		{"词：方文山", "词", "方文山", true}, // 形状命中,是不是演唱者由上层判
		{"情人节也落单", "", "", false},
		{"Chris Tucker: Oh man", "", "", false}, // 含空格,刻意不认(与 Swift 侧一致)
		{"Baby, I said: hello", "", "", false},  // 含标点
		{"一二三四五六七八九十一：x", "", "", false},        // 超过 10 字
		{"：只有冒号", "", "", false},
	}
	for _, c := range cases {
		label, rest, ok := lyricSplitLabel(c.in)
		if ok != c.ok || label != c.label || rest != c.rest {
			t.Errorf("lyricSplitLabel(%q) = (%q,%q,%v), 期望 (%q,%q,%v)",
				c.in, label, rest, ok, c.label, c.rest, c.ok)
		}
	}
}

func TestLyricSpeakerLabels(t *testing.T) {
	// 已知声部词单独出现就算数
	got := lyricSpeakerLabels("[00:01.00]男：一\n[00:02.00]女：二\n")
	if !got["男"] || !got["女"] || len(got) != 2 {
		t.Errorf("已知声部词: got %v", got)
	}
	// 一次性的署名标签不算
	got = lyricSpeakerLabels("[00:01.00]词：葛大为\n[00:02.00]曲：陶喆\n[00:03.00]真歌词\n")
	if len(got) != 0 {
		t.Errorf("署名标签不该算演唱者: got %v", got)
	}
	// 《圣诞星》形态:周杰伦 x2 + 杨瑞代 x1 → 2 个不同 / 3 处 / 有重复
	got = lyricSpeakerLabels("[00:01.00]周杰伦：\n[00:02.00]一\n[00:03.00]杨瑞代：\n[00:04.00]二\n[00:05.00]周杰伦：\n[00:06.00]三\n")
	if !got["周杰伦"] || !got["杨瑞代"] || len(got) != 2 {
		t.Errorf("人名标记过闸: got %v", got)
	}
	// 《好走不见》形态:Rap x1 + Rap2 x1 —— 只有 2 处,不算
	got = lyricSpeakerLabels("[00:01.00]Rap：\n[00:02.00]一\n[00:03.00]Rap2：\n[00:04.00]二\n")
	if len(got) != 0 {
		t.Errorf("两处一次性标记不该算: got %v", got)
	}
	// 《红尘客栈》形态:5 个标签各 1 次 —— 职员表
	got = lyricSpeakerLabels("[00:01.00]执行制作：甲\n[00:02.00]录音师：乙\n[00:03.00]混音师：丙\n[00:04.00]录音室：丁\n[00:05.00]混音室：戊\n[00:06.00]歌词\n")
	if len(got) != 0 {
		t.Errorf("都不重复的多标签是职员表: got %v", got)
	}
	// 叙事标签:计数够,但含代词/动词
	got = lyricSpeakerLabels("[00:01.00]我说：是的\n[00:02.00]然后她问我：好吗\n[00:03.00]我说：好\n")
	if len(got) != 0 {
		t.Errorf("叙事标签不是演唱者: got %v", got)
	}
	// CRLF 也要能切开(酷狗那一支是 CRLF)
	got = lyricSpeakerLabels("[00:01.00]男：一\r\n[00:02.00]女：二\r\n")
	if !got["男"] || !got["女"] {
		t.Errorf("CRLF 切行: got %v", got)
	}
}

// 这条是这次改动的**目的**:带对唱标注的候选不该在跨源共识比对里被摘成残缺正文。
func TestLyricConsensusBodyKeepsDuetLyrics(t *testing.T) {
	// 同一首歌两个源:一份每句带「男：/女：」行内前缀,一份没有标记。
	tagged := "[00:01.00]男：我爱过你笑的脸庞\n[00:02.00]女：时间留不住一句话\n" +
		"[00:03.00]男：我记得曾为你疯狂\n[00:04.00]女：何时过了年少轻狂\n"
	plain := "[00:01.00]我爱过你笑的脸庞\n[00:02.00]时间留不住一句话\n" +
		"[00:03.00]我记得曾为你疯狂\n[00:04.00]何时过了年少轻狂\n"
	a, b := lyricConsensusBody(tagged), lyricConsensusBody(plain)
	if a != b {
		t.Errorf("带标注与不带标注的同一首歌,共识正文应当完全相同\n带标注: %q\n不带:   %q", a, b)
	}
	if a == "" {
		t.Fatal("共识正文被摘空了")
	}
	// 3-gram 相似度必须是 1.0 —— 改动前这里是 0(带标注那份被摘成空串)
	if j := gramJaccard(lyricGram3Set(a), lyricGram3Set(b)); j < 0.999 {
		t.Errorf("同一首歌跨源相似度应为 1.0, 实际 %.3f", j)
	}
}

// 独占标记行只贡献"无正文",不该把正文也带走。
func TestLyricConsensusBodyStandaloneMarkers(t *testing.T) {
	lrc := "[00:01.00]周杰伦：\n[00:02.00]没有了联络\n[00:03.00]阿信：\n[00:04.00]电话开始躲\n" +
		"[00:05.00]周杰伦：\n[00:06.00]你什么都没有\n"
	body := lyricConsensusBody(lrc)
	for _, want := range []string{"没有了联络", "电话开始躲", "你什么都没有"} {
		if !strings.Contains(body, want) {
			t.Errorf("共识正文里缺 %q: %q", want, body)
		}
	}
	if strings.Contains(body, "周杰伦") || strings.Contains(body, "阿信") {
		t.Errorf("标签本身不该进共识正文: %q", body)
	}
}

// 整份都是行内前缀的对唱歌不该被判成"只有职员表"。
func TestIsCreditOnlyLRCKeepsDuet(t *testing.T) {
	duet := "[00:01.00]男：我爱过你笑的脸庞\n[00:02.00]女：时间留不住一句话\n" +
		"[00:03.00]男：我记得曾为你疯狂\n[00:04.00]女：何时过了年少轻狂\n"
	if isCreditOnlyLRC(duet) {
		t.Error("整份行内前缀的对唱被误判成 credit-only")
	}
	// 反例:真的只有职员表,照旧判废
	credits := "[00:01.00]作词：甲\n[00:02.00]作曲：乙\n[00:03.00]编曲：丙\n"
	if !isCreditOnlyLRC(credits) {
		t.Error("真职员表应当判废")
	}
}
