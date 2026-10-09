package main

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestNormalizeISRC(t *testing.T) {
	for in, want := range map[string]string{
		"HKA351501001":     "HKA351501001",
		"hka351501001":     "HKA351501001",
		"HK-A35-15-01001":  "HKA351501001",
		" JPU902200007 ":   "JPU902200007",
		"ZZZZZ9999999":     "", // 占位符样式:后七位同一个数字
		"USAB10000000":     "",
		"HKA35150100":      "", // 少一位
		"HKA35150100X":     "", // 序号里有字母
		"1KA351501001":     "", // 国家码不是字母
		"":                 "",
		"not an isrc code": "",
	} {
		if got := normalizeISRC(in); got != want {
			t.Errorf("normalizeISRC(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRecordingISRCsFromScored(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "kuwo", Score: 1031, SourceReportedDurationSecs: 281, ISRC: "CNA001600001"},          // 别的源报的不收
		{Source: "applemusic", Score: 998, SourceReportedDurationSecs: 281.093, ISRC: "hka351501001"}, // 毫秒级吻合
		{Source: "deezer", Score: 611, SourceReportedDurationSecs: 280, ISRC: "HKC382400008"},         // 整秒,差 1.0 秒
		{Source: "deezer", Score: -1, SourceReportedDurationSecs: 281, ISRC: "HKI490867406"},          // 没被认可
		{Source: "applemusic", Score: 500, SourceReportedDurationSecs: 290, ISRC: "HKI491267110"},     // 时长差 9 秒
		{Source: "applemusic", Score: 400, SourceReportedDurationSecs: 281.1, ISRC: "ZZZZZ9999999"},   // 占位符
		{Source: "deezer", Score: 300, SourceReportedDurationSecs: 281, ISRC: "HKA351501001"},         // 重复
		{Source: "applemusic", Score: 300, SourceReportedDurationSecs: 0, ISRC: "HKI490667205"},       // 源没报时长
	}
	got := recordingISRCsFromScored("JPU902200009", scored, 281.093)
	want := []string{"JPU902200009", "HKA351501001", "HKC382400008"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("recordingISRCsFromScored = %v, want %v(播放器报的在前,候选只收被认可、时长对得上的 applemusic / deezer)", got, want)
	}
	if got := recordingISRCsFromScored("", scored, 0); len(got) != 0 {
		t.Errorf("播放器没报时长时候选报的一个都不收: %v", got)
	}
}

func TestMergeRecordingISRCs(t *testing.T) {
	if got := mergeRecordingISRCs(nil, nil); got != nil {
		t.Errorf("两边都空时是 nil(omitempty 不落盘): %v", got)
	}
	got := mergeRecordingISRCs([]string{"HKA351501001"}, []string{"hkc382400008", "HKA351501001", "bad", "HKI490667205", "HKI490867102", "HKI490867406"})
	want := []string{"HKA351501001", "HKC382400008", "HKI490667205", "HKI490867102"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("mergeRecordingISRCs = %v, want %v(已有的在前,去重,丢掉格式不对的,最多 %d 个)", got, want, recordingISRCMax)
	}
}

func TestISRCSweepJobs(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"Khalil Fong|How It Feels|Wonderland": {AppleURL: "https://music.apple.com/us/album/how-it-feels/272875165?i=272875201&uo=4", DurationSecs: 223},
		"方大同|听|JTW西游记": {AppleURL: "https://music.apple.com/cn/album/%E5%90%AC/1587171414?i=1587171823&uo=4", DurationSecs: 281.093,
			ISRCLookup: "apple:cn:1587171823"},
		"Artist|Song|Album":   {SpotifyTrackID: "7HuBDWi18s4aJM8UFnNheH", DurationSecs: 200},
		"Artist|NoID|Album":   {AppleURL: "https://music.apple.com/us/album/x/123", DurationSecs: 200},
		"Artist|Search|Album": {QQURL: "https://y.qq.com/n/ryqq/search?w=x"},
	})
	enrichMu.Lock()
	jobs := isrcSweepJobsLocked()
	enrichMu.Unlock()
	if len(jobs) != 2 {
		t.Fatalf("只挑有 Apple 歌曲 id 或 Spotify 曲目 id、按现在的 id 还没补过的: %+v", jobs)
	}
	if j := jobs[0]; j.key != "Artist|Song|Album" || j.lookup != "spotify:7HuBDWi18s4aJM8UFnNheH" || j.appleID != "" {
		t.Errorf("Spotify 那条: %+v", j)
	}
	if j := jobs[1]; j.key != "Khalil Fong|How It Feels|Wonderland" || j.lookup != "apple:us:272875201" || j.appleID != "272875201" || j.storefront != "us" {
		t.Errorf("Apple 那条按链接里的商店问: %+v", j)
	}
}

func TestApplyISRCSweepResult(t *testing.T) {
	apple := "https://music.apple.com/cn/album/%E5%90%AC/1587171414?i=1587171823&uo=4"
	withEnrichCache(t, map[string]enrichEntry{
		"a": {AppleURL: apple, DurationSecs: 281.093, ISRCs: []string{"HKC382400008"}},
		"b": {AppleURL: "https://music.apple.com/cn/album/x/1?i=2", DurationSecs: 200},
	})
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if !applyISRCSweepResultLocked(isrcSweepJob{key: "a", lookup: "apple:cn:1587171823"}, []string{"HKA351501001"}) {
		t.Fatal("id 没变时写回")
	}
	if e := enrichCache["a"]; !reflect.DeepEqual(e.ISRCs, []string{"HKC382400008", "HKA351501001"}) || e.ISRCLookup != "apple:cn:1587171823" {
		t.Errorf("合进已有的、记下按哪个 id 补过: %+v", e)
	}
	if applyISRCSweepResultLocked(isrcSweepJob{key: "b", lookup: "apple:cn:3"}, []string{"HKA351501001"}) {
		t.Error("问的时候链接已经换了(id 对不上)就不写")
	}
	if applyISRCSweepResultLocked(isrcSweepJob{key: "gone", lookup: "apple:cn:3"}, nil) {
		t.Error("条目没了不复活")
	}
	if !applyISRCSweepResultLocked(isrcSweepJob{key: "b", lookup: "apple:cn:2"}, nil) || enrichCache["b"].ISRCLookup != "apple:cn:2" || enrichCache["b"].ISRCs != nil {
		t.Errorf("没取到 ISRC 也记成补过: %+v", enrichCache["b"])
	}
}

func TestISRCFromAppleSong(t *testing.T) {
	song := appleCatalogSong{isrc: "HKA351501001", durationSecs: 281.093}
	if got := isrcFromAppleSong(song, true, 281.093); got != "HKA351501001" {
		t.Errorf("时长对得上就认: %q", got)
	}
	if got := isrcFromAppleSong(song, true, 290); got != "" {
		t.Errorf("链接挂到别的版本上(时长差 9 秒)不认: %q", got)
	}
	if got := isrcFromAppleSong(song, true, 0); got != "" {
		t.Errorf("没有播放器时长不认: %q", got)
	}
	if got := isrcFromAppleSong(appleCatalogSong{}, false, 281); got != "" {
		t.Errorf("这个商店没有这首: %q", got)
	}
}

func TestEnrichEntryISRCFieldsRoundTrip(t *testing.T) {
	in := map[string]enrichEntry{"a|b|c": {ISRCs: []string{"HKA351501001"}, ISRCLookup: "apple:cn:1587171823"}}
	raw, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"isrcs":["HKA351501001"]`) || !strings.Contains(string(raw), `"isrc_lookup":"apple:cn:1587171823"`) {
		t.Errorf("键名: %s", raw)
	}
	var back map[string]enrichEntry
	if err := json.Unmarshal(raw, &back); err != nil || !reflect.DeepEqual(back, in) {
		t.Errorf("往返: %+v err=%v", back, err)
	}
	if f := (enrichEntry{ISRCs: []string{"HKA351501001"}}).fields(); len(f) != 0 {
		t.Errorf("ISRC 不进 fields(): %v", f)
	}
}

// ISRC 在三条解析路径上都收、外围补全和合并条目时都并,补扫在引擎起来时开;App 解码这个键。
func TestRecordingISRCWiring(t *testing.T) {
	read := func(path string) string {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	enrich := read("enrich.go")
	// 首次解析在锁外直接取;重试升级、重打分在上锁之前取好 sourceISRC、锁里只用它(取 ISRC 要拿 enrichMu)。
	if n := strings.Count(enrich, "recordingISRCsFromScored(lyricSourceISRC(ctx, artist, title, "); n != 1 {
		t.Errorf("首次解析收 ISRC,现在 %d 处", n)
	}
	if n, m := strings.Count(enrich, "sourceISRC := lyricSourceISRC(ctx, artist, title, album)"),
		strings.Count(enrich, "recordingISRCsFromScored(sourceISRC, scored, durationSecs)"); n != 2 || m != 2 {
		t.Errorf("重试升级、重打分两处在上锁之前取 ISRC 再收,现在取 %d 处、收 %d 处", n, m)
	}
	if !strings.Contains(enrich, "e.ISRCs = mergeRecordingISRCs(e.ISRCs, fresh.ISRCs)") {
		t.Error("外围补全并进这一轮的 ISRC")
	}
	if !strings.Contains(read("enrichkey.go"), "winner.ISRCs = mergeRecordingISRCs(winner.ISRCs, loser.ISRCs)") {
		t.Error("合并条目时把落选那条的 ISRC 并过来")
	}
	if !strings.Contains(read("poller.go"), "go startRecordingISRCSweep(ctx)") {
		t.Error("引擎起来时开存量补扫")
	}
	if sweep := read("recordingisrc.go"); !strings.Contains(sweep, "spotifyCodes := spotifyLocalISRCs(spotifyIDs)") ||
		strings.Contains(sweep, "spotifyLocalISRC(job.") {
		t.Error("存量补扫的 Spotify 那几条一次查完(spotifyLocalISRCs),别一条一条查")
	}
	if !strings.Contains(read("../lyrimuse/Sources/LyrimuseCore/Local/EnrichCacheReader.swift"), "        case isrcs\n") {
		t.Error("App 解码 isrcs(EnrichCacheReader.swift 的 CodingKeys)")
	}
}
