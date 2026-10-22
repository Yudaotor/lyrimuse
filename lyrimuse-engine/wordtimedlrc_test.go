package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestSplitWordTimedLRCEnhanced(t *testing.T) {
	in := "[ti:Song]\n[00:12.00]<00:12.00>Hello <00:12.50>world <00:13.20>\n[00:14.00]<00:14.00>next <00:14.60>line"
	lines, yrc, ok := splitWordTimedLRC(in)
	if !ok {
		t.Fatal("增强 LRC 要拆")
	}
	if want := "[ti:Song]\n[00:12.00]Hello world\n[00:14.00]next line"; lines != want {
		t.Errorf("正文去掉时间标记、元信息行原样留着:\n%q\nwant %q", lines, want)
	}
	if want := "[12000,1200](12000,500,0)Hello (12500,700,0)world \n[14000,5600](14000,600,0)next (14600,5000,0)line"; yrc != want {
		t.Errorf("逐字时间:末尾的单独时间标记是最后一个词的终点,没有就到下一行起点 / 上限:\n%q\nwant %q", yrc, want)
	}
}

func TestSplitWordTimedLRCInlineBrackets(t *testing.T) {
	in := "[00:12.00]Hello [00:12.50]world[00:13.20]\n[00:14.00]next [00:14.60]line[00:15.00]"
	lines, yrc, ok := splitWordTimedLRC(in)
	if !ok {
		t.Fatal("行内方括号要拆")
	}
	if want := "[00:12.00]Hello world\n[00:14.00]next line"; lines != want {
		t.Errorf("一行只留一个时间戳,不再一行重复几遍:\n%q\nwant %q", lines, want)
	}
	if want := "[12000,1200](12000,500,0)Hello (12500,700,0)world\n[14000,1000](14000,600,0)next (14600,400,0)line"; yrc != want {
		t.Errorf("行首时间戳到第一个标记之间的字是第一个词:\n%q\nwant %q", yrc, want)
	}
}

func TestSplitWordTimedLRCLeavesLineLRCAlone(t *testing.T) {
	for _, in := range []string{
		"[00:12.00]Hello world\n[00:14.00]next line",
		"[00:12.00][01:30.50]chorus line\n[00:20.00]verse",
		"[00:12.00]I <3 you\n[00:14.00]a < b > c",
		"[ar:Someone]\n[offset:+200]\n[00:01.00]line",
	} {
		if _, _, ok := splitWordTimedLRC(in); ok {
			t.Errorf("逐行 LRC(含压缩写法、正文里的尖括号)不动: %q", in)
		}
	}
}

func TestSplitWordTimedLRCFractionDigits(t *testing.T) {
	_, yrc, ok := splitWordTimedLRC("[01:02.5]<01:02.5>a <01:02.50>b <01:03.250>c <01:04:1>")
	if !ok {
		t.Fatal("要拆")
	}
	if want := "[62500,1600](62500,0,0)a (62500,750,0)b (63250,850,0)c "; yrc != want {
		t.Errorf("小数 1~3 位、冒号分隔都认:\n%q\nwant %q", yrc, want)
	}
}

func TestSplitWordTimedLRCSparseWordLinesOnlyCleans(t *testing.T) {
	in := "[00:01.00]one\n[00:02.00]two\n[00:03.00]<00:03.00>three <00:03.50>more\n[00:05.00]four"
	lines, yrc, ok := splitWordTimedLRC(in)
	if !ok || yrc != "" {
		t.Fatalf("逐字行不到一半:只洗正文、不给逐字 ok=%v yrc=%q", ok, yrc)
	}
	if want := "[00:01.00]one\n[00:02.00]two\n[00:03.00]three more\n[00:05.00]four"; lines != want {
		t.Errorf("洗过的正文:\n%q\nwant %q", lines, want)
	}
}

func TestSplitWordTimedLRCBackwardsWordsBecomeLine(t *testing.T) {
	lines, yrc, ok := splitWordTimedLRC("[00:12.00]<00:13.00>late <00:12.10>early\n[00:20.00]<00:20.00>ok <00:20.50>fine")
	if !ok {
		t.Fatal("要拆")
	}
	if want := "[00:12.00]late early\n[00:20.00]ok fine"; lines != want {
		t.Errorf("词序倒退的行去掉标记、当整行:\n%q\nwant %q", lines, want)
	}
	if want := "[12000,5000](12000,5000,0)late early\n[20000,5500](20000,500,0)ok (20500,5000,0)fine"; yrc != want {
		t.Errorf("整行那句在逐字里算一个词:\n%q\nwant %q", yrc, want)
	}
}

func TestSplitWordTimedSourceLyricsKeepsSourceYRC(t *testing.T) {
	raw := map[string]lyricSourceResult{
		localFileLyricsSource: {lyr: "[00:12.00]<00:12.00>Hi <00:12.40>there"},
		"qq":                  {lyr: "[00:12.00]<00:12.00>Hi <00:12.40>there", yrc: "[12000,900](12000,900,0)Hi there"},
		"lrclib":              {lyr: "[00:12.00]plain"},
	}
	out := splitWordTimedSourceLyrics(raw)
	if got := out[localFileLyricsSource]; got.lyr != "[00:12.00]Hi there" || got.yrc == "" {
		t.Errorf("本地 .lrc 拆成逐行 + 逐字: %+v", got)
	}
	if got := out["qq"]; got.lyr != "[00:12.00]Hi there" || got.yrc != raw["qq"].yrc {
		t.Errorf("源自己给了逐字时间:正文洗干净,逐字用源的: %+v", got)
	}
	if out["lrclib"].lyr != "[00:12.00]plain" || out["lrclib"].yrc != "" {
		t.Errorf("逐行的不动: %+v", out["lrclib"])
	}
	if raw[localFileLyricsSource].yrc != "" {
		t.Error("调用方那份原始应答不能被改")
	}
}

func TestApplySaveEditSplitsPastedWordTimedLRC(t *testing.T) {
	e := enrichEntry{Lyrics: bt("[00:01.00]旧")}
	req := enrichEditRequest{Lyrics: "[00:12.00]Hello [00:12.50]world[00:13.20]", MarkManual: true}
	if err := applySaveEdit(&e, req); err != nil {
		t.Fatal(err)
	}
	if !e.Lyrics.EqualString("[00:12.00]Hello world") {
		t.Errorf("粘进来的逐字写法:正文存洗过的: %q", e.Lyrics)
	}
	if !e.LyricsYRC.EqualString("[12000,1200](12000,500,0)Hello (12500,700,0)world") {
		t.Errorf("逐字时间以正文里的为准: %q", e.LyricsYRC)
	}
}

func TestRankLocalWordTimedLRCCarriesWordTiming(t *testing.T) {
	var lrc strings.Builder
	for i := 0; i < 20; i++ {
		at := (10 + i*10) * 1000
		fmt.Fprintf(&lrc, "%s<%s>word%d <%s>more%d\n", formatLRCTime(at), strings.Trim(formatLRCTime(at), "[]"), i,
			strings.Trim(formatLRCTime(at+600), "[]"), i)
	}
	raw := map[string]lyricSourceResult{localFileLyricsSource: {source: localFileLyricsSource, lyr: lrc.String(), srcDur: 220,
		matchTitle: "Song", matchArtist: "Artist", identityFromLocalClient: true}}
	for _, r := range rankLyricSourceResults("Artist", "Song", "", 220, raw) {
		if r.Source != localFileLyricsSource {
			continue
		}
		if strings.Contains(r.Lyrics, "<") || !r.HasWordTiming || r.LyricsYRC == "" {
			t.Fatalf("本地逐字 .lrc 的候选:正文洗干净、带上逐字 has=%v yrc=%d 字节 lyrics=%q", r.HasWordTiming, len(r.LyricsYRC), r.Lyrics[:40])
		}
		return
	}
	t.Fatal("没有本地 .lrc 的候选")
}

func TestSplitWordTimedLRCTailRunsToNextLine(t *testing.T) {
	_, yrc, ok := splitWordTimedLRC("[00:10.00]<00:10.00>a <00:10.40>b\n[00:12.00]<00:12.00>c <00:12.30>d\n[00:30.00]<00:30.00>e <00:30.20>f")
	if !ok {
		t.Fatal("要拆")
	}
	want := "[10000,2000](10000,400,0)a (10400,1600,0)b\n[12000,5300](12000,300,0)c (12300,5000,0)d\n[30000,5200](30000,200,0)e (30200,5000,0)f"
	if yrc != want {
		t.Errorf("最后一个词没写终点:到下一行起点,下一行太远就到上限:\n%q\nwant %q", yrc, want)
	}
}
