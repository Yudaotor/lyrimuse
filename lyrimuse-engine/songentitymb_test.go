package main

import (
	"context"
	"slices"
	"testing"
	"time"
)

func TestMBRecordingsDue(t *testing.T) {
	now := time.Unix(2_000_000_000, 0)
	entries := map[string]enrichEntry{
		"A|Song|One":         {ISRCs: []string{"USAAA1100003", "USAAA1100001"}},
		"A|Song|Two":         {ISRCs: []string{"USAAA1100001"}},
		"A|Song (Live)|Tour": {ISRCs: []string{"USAAA1100009"}},
		"A|Other|X":          {ISRCs: []string{"USAAA1100002"}},
	}
	have := map[string]mbISRCRecord{"USAAA1100002": {Checked: now.Add(-time.Hour).Unix()}}
	got := mbRecordingsDue(entries, have, now)
	if !slices.Equal(got, []string{"USAAA1100001", "USAAA1100003"}) {
		t.Errorf("只问级别够格的号(带版本词那条检索配的号不问)、刚问过的不问、同一个号只问一次: %v", got)
	}
}

func TestFetchMBRecordings(t *testing.T) {
	var codes []string
	for i := range 450 {
		codes = append(codes, "C"+time.Duration(i).String())
	}
	asked := 0
	lookup := func(_ context.Context, code string) (mbISRCRecord, bool) {
		asked++
		switch {
		case asked == 100 || asked == 101:
			return mbISRCRecord{}, false
		case asked >= 420:
			return mbISRCRecord{}, false
		}
		return mbISRCRecord{Recording: "r-" + code, Recordings: 1}, true
	}
	saves := 0
	have := map[string]mbISRCRecord{}
	now := time.Unix(2_000_000_000, 0)
	settled := fetchMBRecordings(context.Background(), codes, have, now, 0, lookup, func() { saves++ })
	if settled != 417 || asked != 419+mbRecordingsMaxFailures || len(have) != 417 {
		t.Errorf("问不成退避后重问同一个号,连续 %d 次问不成才停:settled=%d asked=%d have=%d",
			mbRecordingsMaxFailures, settled, asked, len(have))
	}
	if _, ok := have[codes[99]]; !ok {
		t.Error("中间被限速的那个号重问之后要记下")
	}
	if saves != 2 {
		t.Errorf("每问成 %d 个落一次盘,应为 2 次,得到 %d", mbRecordingsSaveEvery, saves)
	}
	if rec := have[codes[0]]; rec.Recording != "r-"+codes[0] || rec.Checked != now.Unix() {
		t.Errorf("记下录音 id 和问的时刻: %+v", rec)
	}
}

// 号不同、MusicBrainz 上是同一个录音的两条写法并成一首;一个号对上几条录音的不用;时长差过闸的不连;检索配的号不用。
func TestSongEntityMBRecordingEdges(t *testing.T) {
	recs := map[string]mbISRCRecord{
		"HKC382400008": {Recording: "c263de6a", Recordings: 1},
		"QNSM12400583": {Recording: "c263de6a", Recordings: 1},
		"USUM71814888": {Recordings: 2},
		"USUM71814889": {Recordings: 2},
		"USAAA1100009": {Recording: "live", Recordings: 1},
		"USAAA1100008": {Recording: "live", Recordings: 1},
	}
	build := func(vs []songVariant) map[string]string {
		attachMBRecordings(vs, recs)
		_, of := songTestBuild(t, vs, nil)
		return of
	}
	of := build([]songVariant{
		songTestVariant("方大同|那沙漠里的水|梦想家", enrichEntry{DurationSecs: 161, ISRCs: []string{"QNSM12400583"}}, nil),
		songTestVariant("Khalil Fong|Oasis|The Dreamer", enrichEntry{DurationSecs: 161.3, ISRCs: []string{"HKC382400008"}}, nil),
		songTestVariant("Post Malone|Sunflower|A", enrichEntry{DurationSecs: 158, ISRCs: []string{"USUM71814888"}}, nil),
		songTestVariant("Post Malone|Girasol|B", enrichEntry{DurationSecs: 158.1, ISRCs: []string{"USUM71814889"}}, nil),
	})
	if !songTestSame(of, "方大同|那沙漠里的水|梦想家", "Khalil Fong|Oasis|The Dreamer") {
		t.Error("号不同、同一个录音的两条写法应当并成一首")
	}
	if songTestSame(of, "Post Malone|Sunflower|A", "Post Malone|Girasol|B") {
		t.Error("一个号对上几条录音的不当证据")
	}
	of = build([]songVariant{
		songTestVariant("方大同|那沙漠里的水|梦想家", enrichEntry{DurationSecs: 161, ISRCs: []string{"QNSM12400583"}}, nil),
		songTestVariant("Khalil Fong|Oasis|The Dreamer", enrichEntry{DurationSecs: 170, ISRCs: []string{"HKC382400008"}}, nil),
		songTestVariant("A|Song|Tour", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA1100009"},
			ISRCLevels: map[string]string{"USAAA1100009": isrcLevelSearched}}, nil),
		songTestVariant("A|Other Name|Y", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA1100008"}}, nil),
	})
	if songTestSame(of, "方大同|那沙漠里的水|梦想家", "Khalil Fong|Oasis|The Dreamer") {
		t.Error("时长差过闸的不连")
	}
	if songTestSame(of, "A|Song|Tour", "A|Other Name|Y") {
		t.Error("记成检索配的号不当证据,它查到的录音也不用")
	}
}

func TestConfidentISRC(t *testing.T) {
	cases := []struct {
		e    enrichEntry
		want string
	}{
		{enrichEntry{ISRCs: []string{"USAAA1100002", "USAAA1100001"}, ISRCLevels: map[string]string{
			"USAAA1100001": isrcLevelVerified, "USAAA1100002": isrcLevelPlayer}}, "USAAA1100002"},
		{enrichEntry{ISRCs: []string{"USAAA1100003", "USAAA1100001"}, ISRCLevels: map[string]string{
			"USAAA1100001": isrcLevelVerified, "USAAA1100003": isrcLevelVerified}}, "USAAA1100001"},
		{enrichEntry{ISRCs: []string{"USAAA1100001"}, ISRCLevels: map[string]string{"USAAA1100001": isrcLevelSearched}}, ""},
		{enrichEntry{ISRCs: []string{"USAAA1100001"}}, ""},
	}
	for i, c := range cases {
		if got := c.e.confidentISRC(); got != c.want {
			t.Errorf("#%d: %q,应为 %q", i, got, c.want)
		}
	}
}

// ListenBrainz 上报:记了级别的号报 isrc,MusicBrainz 唯一命中的再报 recording_mbid;一号多录音的只报 isrc。
func TestLBMetaRecordingIdentity(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	if err := writeMBRecordings(mbRecordingsPath(), map[string]mbISRCRecord{
		"HKC382400008": {Recording: "c263de6a", Recordings: 1},
		"USUM71814888": {Recordings: 2},
	}); err != nil {
		t.Fatal(err)
	}
	withEnrichCache(t, map[string]enrichEntry{
		enrichKey("方大同", "那沙漠里的水", "梦想家"):          {ISRCs: []string{"HKC382400008"}, ISRCLevels: map[string]string{"HKC382400008": isrcLevelPlayer}},
		enrichKey("Post Malone", "Sunflower", "X"): {ISRCs: []string{"USUM71814888"}, ISRCLevels: map[string]string{"USUM71814888": isrcLevelVerified}},
	})
	info := lbMeta(snapshot{Artist: "方大同", Title: "那沙漠里的水", Album: "梦想家", Remote: true}).AdditionalInfo
	if info["isrc"] != "HKC382400008" || info["recording_mbid"] != "c263de6a" {
		t.Errorf("应当带 isrc 和 recording_mbid: %v %v", info["isrc"], info["recording_mbid"])
	}
	info = lbMeta(snapshot{Artist: "Post Malone", Title: "Sunflower", Album: "X", Remote: true}).AdditionalInfo
	if _, has := info["recording_mbid"]; info["isrc"] != "USUM71814888" || has {
		t.Errorf("一号多录音的只报 isrc: %v", info)
	}
}
