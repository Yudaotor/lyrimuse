package main

import "testing"

func TestTitleMaskCompatible(t *testing.T) {
	for _, c := range []struct {
		local, other string
		want         bool
	}{
		{"****", "F*ck", true},
		{"****", "Fuck", true},
		{"F*ck", "Fuck", true},
		{"Fu*k", "F*ck", true}, // 两边打码的位置不同
		{"all-american b***h", "all-american bitch", true},
		{"tonight we ****in’ party", "tonight we fuckin' party", true}, // 撇号写法不同
		{"他*的", "他妈的", true},
		{"他*的", "他姐的", true}, // 中文单字打码对得上的不止一首,只能配着时长用
		{"****", "Crush", false},
		{"F*ck", "Fork", false},
		{"Fuck", "F*ck", false}, // 本地没打码
		{"****", "", false},
	} {
		if got := titleMaskCompatible(c.local, c.other); got != c.want {
			t.Errorf("titleMaskCompatible(%q, %q) = %v, want %v", c.local, c.other, got, c.want)
		}
	}
}

func TestTitleCacheKeyPart(t *testing.T) {
	for in, want := range map[string]string{"****": "****", "F*ck": normLoose("F*ck"), "Hello": normLoose("Hello"), "": ""} {
		if got := titleCacheKeyPart(in); got != want {
			t.Errorf("titleCacheKeyPart(%q) = %q, want %q", in, got, want)
		}
	}
}

// 本地曲名整个打了码:专辑里逐字对得上、时长在跨文字那一档容差以内的那首按时长挑;时长对不上、没有时长、两首都对得上又咬得太紧
// 都不挑。区服遍历的结论也认这种写法。
func TestAppleStorefrontPickTrackMaskedTitle(t *testing.T) {
	tracks := []itunesResult{
		{TrackName: "Messy", TrackTimeMillis: 284100},
		{TrackName: "Crush", TrackTimeMillis: 164500},
		{TrackName: "F*ck", TrackTimeMillis: 164000},
		{TrackName: "Good Books", TrackTimeMillis: 254700},
	}
	if hit := appleStorefrontPickTrack("****", 164.04, tracks); hit == nil || hit.TrackName != "F*ck" {
		t.Errorf("该挑中 F*ck,实际 %+v", hit)
	}
	if hit := appleStorefrontPickTrack("****", 180, tracks); hit != nil {
		t.Errorf("时长差太多不该挑,实际 %+v", hit)
	}
	if hit := appleStorefrontPickTrack("****", 0, tracks); hit != nil {
		t.Errorf("没有时长不该挑,实际 %+v", hit)
	}
	tight := append(tracks, itunesResult{TrackName: "Fine", TrackTimeMillis: 164300})
	if hit := appleStorefrontPickTrack("****", 164.04, tight); hit != nil {
		t.Errorf("两首都对得上、时长咬得太紧不该挑,实际 %+v", hit)
	}
	if !storefrontTraversalTitleUsable("****", "", "F*ck") {
		t.Error("打码的本地曲名,区服遍历挑出的逐字对得上的曲名该能用")
	}
	if storefrontTraversalTitleUsable("Hello", "", "Hallo") {
		t.Error("同文字、没打码的曲名不该能用")
	}
}
