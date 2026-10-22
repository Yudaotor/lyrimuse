package main

import (
	"os"
	"strings"
	"testing"
)

// 原文和译文同一个时间戳、行尾没写结束时间:句尾那个词要收在真正的下一句起点,不能因为紧挨着的译文行起点一样就按 5 秒上限收。
func TestWordTimedTailEndSkipsSameStartLines(t *testing.T) {
	lrc := "[00:10.00]<00:10.00>Hello <00:10.50>world\n[00:10.00]你好世界\n[00:14.00]<00:14.00>Next <00:14.50>line"
	_, yrc, ok := splitWordTimedLRC(lrc)
	if !ok || !strings.Contains(yrc, "(10500,3500,0)world") {
		t.Fatalf("world 应收在 14000, yrc=%q", yrc)
	}
}

// 只有时间标记没有字的行(间奏 / 句尾标记):正文里不留 `<mm:ss.xx>`,留一个空行;它照样算上一句的终点。
func TestWordTimedMarkerLine(t *testing.T) {
	lrc := "[00:10.00]<00:10.00>A <00:11.00>B\n[00:15.00]<00:15.00>\n[00:20.00]<00:20.00>C <00:21.00>D"
	lines, yrc, ok := splitWordTimedLRC(lrc)
	if !ok {
		t.Fatal("应拆")
	}
	if strings.Contains(lines, "<00:15") || !strings.Contains(lines, "[00:15.00]") {
		t.Errorf("标记行应只留行首时间戳, lines=%q", lines)
	}
	if !strings.Contains(yrc, "(11000,4000,0)B") {
		t.Errorf("B 应收在标记行 15000, yrc=%q", yrc)
	}
	if strings.Count(yrc, "\n") != 1 {
		t.Errorf("标记行不进 YRC, yrc=%q", yrc)
	}
}

// 只在行尾写结束时间的逐行 LRC(每行一个「词」)只洗正文,不给 YRC:不然整份逐行歌词拿到逐字加分。
func TestWordTimedSingleWordLinesStayLineTimed(t *testing.T) {
	lines, yrc, ok := splitWordTimedLRC("[00:12.00]整句[00:15.00]\n[00:16.00]第二句[00:19.00]")
	if !ok || yrc != "" {
		t.Fatalf("应只洗正文, ok=%v yrc=%q", ok, yrc)
	}
	if strings.Contains(lines, "整句[00:15") {
		t.Errorf("行尾时间戳应洗掉, lines=%q", lines)
	}
}

// 快速预判只在同一行里找方括号时间戳:普通逐行 LRC 不该命中。
func TestWordTimedHintIgnoresLineBreaks(t *testing.T) {
	if wordTimedHintRe.MatchString("[00:01.00]第一句\n[00:02.00]第二句\n") {
		t.Error("普通逐行 LRC 不该命中逐字预判")
	}
	if !wordTimedHintRe.MatchString("[00:01.00]第一[00:01.50]句") {
		t.Error("同一行正文中间的时间戳要命中")
	}
}

// 源码契约:几处接线。
func TestNewFeatureAuditContracts(t *testing.T) {
	read := func(name string) string {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	imp := read("lyricsimport.go")
	if !containsCode(imp, "if lines, yrc, split := splitWordTimedLRC(v); split {") {
		t.Error("歌词文件夹导入的 .lrc 也要拆逐字写法")
	}
	np := read("networkproxy.go")
	if !containsCode(np, "return nil, errNoFallbackProxy") {
		t.Error("走代理那一半拿不到代理时报错,不悄悄直连")
	}
	if !containsCode(np, "if u != nil && !proxyReachableWithin(u, manualProxyProbeTimeout(u)) {") {
		t.Error("手动档探活按本机 / 远程分开超时")
	}
	pf := read("proxyfallback.go")
	if !containsCode(pf, "t.stickyUntil = time.Now().Round(0).Add(window)") ||
		!containsCode(pf, "sticky := time.Now().Round(0).Before(t.stickyUntil)") {
		t.Error("走代理的粘性窗口按墙钟算")
	}
	mx := read("musixmatchreroute.go")
	if !containsCode(mx, "viaClash = m != nil && c != nil && m.Host == c.Host") {
		t.Error("手动档填的不是 Clash 时不切 Clash 节点")
	}
}
