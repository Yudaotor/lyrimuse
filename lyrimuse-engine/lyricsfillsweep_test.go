package main

import (
	"reflect"
	"testing"
	"time"
)

// 见 lyricsfillsweep.go 头注:后台补空扫描挑候选的规矩——三道硬闸(有词/人工/纯音乐)对自动、
// 手动都生效,退避只管自动,手动可以按 key 指定子集,自动有每轮上限。
func TestLyricsFillSweepCandidates(t *testing.T) {
	now := time.Now().Unix()
	day := int64(24 * 3600)
	savedCache, savedInflight := enrichCache, enrichInflight
	t.Cleanup(func() { enrichCache, enrichInflight = savedCache, savedInflight })
	enrichCache = map[string]enrichEntry{
		"a|old empty|":        {TS: now - 2*day},                        // 退避到期 → 自动也要
		"b|fresh empty|":      {TS: now - 60},                           // 刚解析过 → 自动不要,手动要
		"c|has lyrics|":       {TS: now - 2*day, Lyrics: "[00:01.00]x"}, // 有词 → 都不要
		"d|manual|":           {TS: now - 2*day, ManualLyrics: true},    // 人工修正 → 都不要
		"e|instrumental|":     {TS: now - 2*day, Instrumental: true},    // 确证纯音乐 → 都不要
		"f|plain only|":       {TS: now - 2*day, PlainLyrics: "text"},   // 只有纯文本兜底 → 仍算没词,要
		"g|inflight|":         {TS: now - 2*day},                        // 正在飞 → 这一轮跳过
		"h|old empty second|": {TS: now - 3*day},
	}
	enrichInflight = map[string]bool{"g|inflight|": true}

	got := lyricsFillSweepCandidates(lyricsFillRequest{})
	want := []string{"a|old empty|", "f|plain only|", "h|old empty second|"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("auto: got %v, want %v", got, want)
	}

	got = lyricsFillSweepCandidates(lyricsFillRequest{manual: true, all: true})
	want = []string{"a|old empty|", "b|fresh empty|", "f|plain only|", "h|old empty second|"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("manual all: got %v, want %v", got, want)
	}

	got = lyricsFillSweepCandidates(lyricsFillRequest{manual: true, keys: map[string]bool{"b|fresh empty|": true, "c|has lyrics|": true, "zz|missing|": true}})
	want = []string{"b|fresh empty|"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("manual keys: got %v, want %v", got, want)
	}
}

func TestLyricsFillSweepDailyCap(t *testing.T) {
	now := time.Now().Unix()
	savedCache, savedInflight := enrichCache, enrichInflight
	t.Cleanup(func() { enrichCache, enrichInflight = savedCache, savedInflight })
	enrichCache = map[string]enrichEntry{}
	enrichInflight = map[string]bool{}
	for i := 0; i < lyricsFillSweepDailyCap+7; i++ {
		enrichCache[string(rune('a'+i%26))+string(rune('a'+i/26))+"|t|"] = enrichEntry{TS: now - 3*24*3600}
	}
	if got := len(lyricsFillSweepCandidates(lyricsFillRequest{})); got != lyricsFillSweepDailyCap {
		t.Errorf("auto sweep should cap at %d, got %d", lyricsFillSweepDailyCap, got)
	}
	if got := len(lyricsFillSweepCandidates(lyricsFillRequest{manual: true, all: true})); got != lyricsFillSweepDailyCap+7 {
		t.Errorf("manual sweep must not cap, got %d", got)
	}
}

func TestParseLyricsFillRequest(t *testing.T) {
	cases := []struct {
		in   string
		want lyricsFillRequest
	}{
		{"all\n", lyricsFillRequest{manual: true, all: true}},
		{"cancel", lyricsFillRequest{manual: true, cancel: true}},
		{"  周杰伦|晴天|叶惠美 \n\nA|B|C\n", lyricsFillRequest{manual: true, keys: map[string]bool{"周杰伦|晴天|叶惠美": true, "A|B|C": true}}},
		{"\n \n", lyricsFillRequest{manual: true}},
	}
	for _, c := range cases {
		if got := parseLyricsFillRequest(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("parse(%q) = %+v, want %+v", c.in, got, c.want)
		}
	}
}
