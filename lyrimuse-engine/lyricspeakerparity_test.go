package main

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

func readSwiftLyricsSyncEngine(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Lyrics/LyricsSyncEngine.swift")
	if err != nil {
		t.Fatalf("读不到 Swift 侧 LyricsSyncEngine.swift(路径变了就跟着改,别删守卫): %v", err)
	}
	return string(b)
}

// 署名角色词表、关键词正则跟 Swift 侧逐字一致。
func TestLyricCreditRoleTablesMatchSwift(t *testing.T) {
	src := readSwiftLyricsSyncEngine(t)
	start := strings.Index(src, "private static let creditRoleWords: [String] = [")
	if start < 0 {
		t.Fatal("Swift 侧找不到 creditRoleWords")
	}
	end := strings.Index(src[start:], "\n    ]")
	body := src[start : start+end]
	var swiftWords []string
	for _, line := range strings.Split(body, "\n") {
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		for _, m := range regexp.MustCompile(`"([^"]+)"`).FindAllStringSubmatch(line, -1) {
			swiftWords = append(swiftWords, m[1])
		}
	}
	// 按集合比(Swift 那张表里「収録」写了两遍,重复不影响判定)。
	dedupe := func(ws []string) string {
		seen := map[string]bool{}
		var out []string
		for _, w := range ws {
			if !seen[w] {
				seen[w] = true
				out = append(out, w)
			}
		}
		sort.Strings(out)
		return strings.Join(out, ",")
	}
	if dedupe(swiftWords) != dedupe(lyricCreditRoleWords) {
		t.Errorf("角色词表两边不一致:\nSwift %v\nGo    %v", swiftWords, lyricCreditRoleWords)
	}
	m := regexp.MustCompile(`creditLinePattern = try! NSRegularExpression\(\s*pattern: #"(.*?)"#`).FindStringSubmatch(src)
	if m == nil {
		t.Fatal("Swift 侧找不到 creditLinePattern")
	}
	if goPattern := strings.TrimPrefix(lyricKeywordCreditRe.String(), "(?i)"); goPattern != m[1] {
		t.Errorf("关键词正则两边不一致:\nSwift %s\nGo    %s", m[1], goPattern)
	}
	en := regexp.MustCompile(`englishRoleNounPattern = try! NSRegularExpression\(\s*pattern:((?:\s*\+?\s*#"[^"]*"#)+)`).FindStringSubmatch(src)
	if en == nil {
		t.Fatal("Swift 侧找不到 englishRoleNounPattern")
	}
	var swiftEN strings.Builder
	for _, part := range regexp.MustCompile(`#"([^"]*)"#`).FindAllStringSubmatch(en[1], -1) {
		swiftEN.WriteString(part[1])
	}
	if goEN := strings.TrimPrefix(lyricEnglishRoleNounRe.String(), "(?i)"); goEN != swiftEN.String() {
		t.Errorf("英文角色名正则两边不一致:\nSwift %s\nGo    %s", swiftEN.String(), goEN)
	}
}

// 说话人标签:像职员表角色名的不算,真人名照旧算。
func TestLyricPlausibleSpeakerNameRejectsCreditRoles(t *testing.T) {
	rejected := []string{
		"总策划", "版权方", "人声编辑", "封面设计", "翻译", "和声", "唱片公司", "作词/作曲",
		"制作人 Producer", "鼓 Drums", "Protools编辑", "录音师/录音室", "監製", "封面設計",
	}
	for _, l := range rejected {
		if lyricPlausibleSpeakerName(l) {
			t.Errorf("%q 是职员表角色名,不该算说话人", l)
		}
	}
	accepted := []string{"周杰伦", "费玉清", "曲婉婷", "男", "女", "Jay", "五月天阿信"}
	for _, l := range accepted {
		if !lyricPlausibleSpeakerName(l) {
			t.Errorf("%q 是人名,应当算说话人", l)
		}
	}
}

// 对唱歌尾部的署名行不再被当成说话人豁免,曲末时间取真正的末句。
func TestDuetCreditTailDoesNotStretchLastTimestamp(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 5; i++ {
		b.WriteString("[00:0" + string(rune('0'+i)) + ".00]周杰伦：第一句\n")
		b.WriteString("[00:1" + string(rune('0'+i)) + ".00]费玉清：第二句\n")
	}
	b.WriteString("[00:28.00]周杰伦：末句\n[01:00.00]总策划：某某\n[01:40.00]版权方：某某唱片")
	lrc := b.String()
	speakers := lyricSpeakerLabels(lrc)
	if speakers["总策划"] || speakers["版权方"] {
		t.Fatalf("署名不该进说话人名单: %v", speakers)
	}
	if !speakers["周杰伦"] || !speakers["费玉清"] {
		t.Fatalf("真说话人应当认出: %v", speakers)
	}
	if got, ok := lastLRCTimestampSecs(lrc); !ok || got != 28 {
		t.Errorf("lastLRCTimestampSecs = %v, want 28", got)
	}
}
