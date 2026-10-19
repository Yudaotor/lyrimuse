package main

import (
	"fmt"
	"strings"
	"testing"
)

// 《We Are the World》那种十几位独唱轮流唱的 TTML:超过 9 位演唱者时,声部按 xml:id 字面排会把 v10 排到 v2 前面,
// 第 2 位起整体错位。
func TestAMLLSpeakerPrefixesOrderBeyondNine(t *testing.T) {
	var agents []ttmlAgent
	for i := 1; i <= 12; i++ {
		agents = append(agents, ttmlAgent{Type: "person", ID: fmt.Sprintf("v%d", i)})
	}
	agents = append(agents, ttmlAgent{Type: "group", ID: "v1000"})
	got := amllSpeakerPrefixes(agents)
	for i := 1; i <= 8; i++ {
		if id := fmt.Sprintf("v%d", i); got[id] != id {
			t.Errorf("%s 应编成 %s,实得 %q(全部:%v)", id, id, got[id], got)
		}
	}
	for _, id := range []string{"v9", "v10", "v11", "v12"} {
		if p, ok := got[id]; ok {
			t.Errorf("第 9 位起不标(anonymousMarkers 只到 v8),%s 却标成 %q", id, p)
		}
	}
	if got["v1000"] != "合" {
		t.Errorf("group 应写成「合」: %v", got)
	}
}

func TestParseAMLLTTMLTwelveSingers(t *testing.T) {
	var head, body strings.Builder
	for i := 1; i <= 12; i++ {
		fmt.Fprintf(&head, `<ttm:agent type="person" xml:id="v%d"/>`, i)
		fmt.Fprintf(&body, `<p begin="00:%02d.000" end="00:%02d.500" ttm:agent="v%d"><span begin="00:%02d.000" end="00:%02d.500">L%d</span></p>`,
			i, i, i, i, i, i)
	}
	doc := `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">` +
		`<head><metadata xmlns="">` + head.String() + `</metadata></head><body><div xmlns="">` + body.String() + `</div></body></tt>`
	r, ok := parseAMLLTTML(doc)
	if !ok {
		t.Fatal("解析失败")
	}
	lrc := strings.Split(strings.TrimRight(r.lrc, "\n"), "\n")
	if len(lrc) != 12 {
		t.Fatalf("应有 12 行,实际 %d: %q", len(lrc), r.lrc)
	}
	if !strings.HasSuffix(lrc[1], "v2：L2") || !strings.HasSuffix(lrc[7], "v8：L8") {
		t.Errorf("第 2、8 位应各自标 v2、v8: %q / %q", lrc[1], lrc[7])
	}
	if strings.Contains(lrc[9], "：") {
		t.Errorf("第 10 位不该挪用别人的声部: %q", lrc[9])
	}
}

func TestCompareTTMLAgentIDs(t *testing.T) {
	cases := []struct {
		a, b string
		less bool
	}{
		{"v2", "v10", true},
		{"v10", "v2", false},
		{"v1", "v2", true},
		{"v09", "v10", true},
		{"a1", "v1", true},
		{"singer", "v1", true},
	}
	for _, c := range cases {
		if got := compareTTMLAgentIDs(c.a, c.b) < 0; got != c.less {
			t.Errorf("compareTTMLAgentIDs(%q, %q) < 0 = %v, want %v", c.a, c.b, got, c.less)
		}
	}
}
