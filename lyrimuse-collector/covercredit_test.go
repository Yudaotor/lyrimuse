package main

import (
	"context"
	"testing"
)

func TestCoverPerformerIdentity(t *testing.T) {
	cases := []struct {
		title, performer, song string
		ok                     bool
	}{
		{"[Special] Watermelon Sugar (Cover by 화사)", "화사", "Watermelon Sugar", true},
		{"Song (cover by Someone)", "Someone", "Song", true},
		{"Song (Covered by A & B)", "A & B", "Song", true},
		{"Song [Cover by: Someone]", "Someone", "Song", true},
		{"Song（Cover by 某人）", "某人", "Song", true},
		{"【Cover by 某人】Song", "某人", "Song", true},
		{"Song (Live) (Cover by Someone)", "Someone", "Song (Live)", true},
		{"Baby Powder Covered by IVE REI", "IVE REI", "Baby Powder", true},
		{"To.X Covered by IVE GAEUL&LIZ", "IVE GAEUL&LIZ", "To.X", true},
		// 没有翻唱者名字:没有可换的人
		{"Song (Cover)", "", "", false},
		{"Song (COVER版)", "", "", false},
		{"'Flowers / Miley Cyrus' (Cover)", "", "", false},
		// 不是翻唱署名
		{"Song", "", "", false},
		{"Song (Live)", "", "", false},
		{"Song (cover byron)", "", "", false},
		{"Cover by Someone", "", "", false},
		{"Song (Cover by )", "", "", false},
		// 去掉署名后曲名为空
		{"(Cover by Someone)", "", "", false},
		{"[Special] (Cover by Someone)", "Someone", "[Special]", true},
	}
	for _, c := range cases {
		performer, song, ok := coverPerformerIdentity(c.title)
		if ok != c.ok || performer != c.performer || song != c.song {
			t.Errorf("coverPerformerIdentity(%q) = %q, %q, %v; want %q, %q, %v", c.title, performer, song, ok, c.performer, c.song, c.ok)
		}
	}
}

// coverRescue 只换成翻唱者、只重入一次,重入那一轮带着「只认翻唱者本人」的标记;翻唱版没查到就放弃,不找原唱。
func TestCoverRescue(t *testing.T) {
	orig := coverRescueSearch
	t.Cleanup(func() { coverRescueSearch = orig })
	type call struct {
		artist, title, reason string
		dur                   float64
		performerOnly         bool
	}
	var calls []call
	usable := false
	coverRescueSearch = func(ctx context.Context, artist, title, album string, dur float64, _ lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
		calls = append(calls, call{artist, title, lyricQueryReasonFrom(ctx), dur, coverPerformerOnly(ctx)})
		if usable {
			return neteaseInfo{Artist: artist}, []scoredLyricCandidateResult{{Source: "qq", Score: 500}}
		}
		return neteaseInfo{}, []scoredLyricCandidateResult{{Source: "qq", Score: -1}}
	}
	reset := func(u bool) { calls, usable = nil, u }

	reset(true)
	if _, _, ok := coverRescue(context.Background(), "Group", "Song", "", 200, nil); ok || len(calls) != 0 {
		t.Fatalf("没有翻唱者署名不该重入: ok=%v calls=%v", ok, calls)
	}

	reset(true)
	ne, _, ok := coverRescue(context.Background(), "Group", "Song (Cover by Perf)", "", 200, nil)
	if !ok || len(calls) != 1 || calls[0] != (call{"Perf", "Song", lyricQueryReasonCoverCredit, 200, true}) || ne.Artist != "Perf" {
		t.Fatalf("该换成翻唱者、带时长、带只认翻唱者标记: ok=%v calls=%v ne=%q", ok, calls, ne.Artist)
	}

	reset(false)
	if _, _, ok := coverRescue(context.Background(), "Group", "Song (Cover by Perf)", "", 200, nil); ok || len(calls) != 1 {
		t.Fatalf("翻唱版没查到就放弃,不再换别的身份: ok=%v calls=%v", ok, calls)
	}

	reset(true)
	if _, _, ok := coverRescue(context.Background(), "Perf", "Song (Cover by Perf)", "", 200, nil); ok || len(calls) != 0 {
		t.Fatalf("翻唱者就是原署名时不重入: ok=%v calls=%v", ok, calls)
	}

	reset(true)
	if _, _, ok := coverRescue(withCoverPerformerOnly(context.Background()), "Perf", "Song (Cover by Other)", "", 200, nil); ok || len(calls) != 0 {
		t.Fatalf("已经在翻唱重入里就不再重入: ok=%v calls=%v", ok, calls)
	}
}
