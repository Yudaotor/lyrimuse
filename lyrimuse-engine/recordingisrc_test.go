package main

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
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
		{Source: "kuwo", Score: 1031, SourceReportedDurationSecs: 281, ISRC: "CNA001600001"},                                  // 别的源报的不收
		{Source: "applemusic", Score: 998, SourceReportedDurationSecs: 281.093, ISRC: "hka351501001"},                         // 毫秒级吻合
		{Source: "deezer", Score: 611, SourceReportedDurationSecs: 280, ISRC: "HKC382400008"},                                 // 整秒,差 1.0 秒
		{Source: "deezer", Score: -1, SourceReportedDurationSecs: 281, ISRC: "HKI490867406"},                                  // 没被认可
		{Source: "applemusic", Score: 500, SourceReportedDurationSecs: 290, ISRC: "HKI491267110"},                             // 时长差 9 秒
		{Source: "applemusic", Score: 400, SourceReportedDurationSecs: 281.1, ISRC: "ZZZZZ9999999"},                           // 占位符
		{Source: "deezer", Score: 300, SourceReportedDurationSecs: 281, ISRC: "HKA351501001"},                                 // 重复
		{Source: "applemusic", Score: 300, SourceReportedDurationSecs: 0, ISRC: "HKI490667205"},                               // 源没报时长
		{Source: "applemusic", Score: 200, SourceReportedDurationSecs: 281.093, ISRC: "HKA351509999", Title: "Listen (Live)"}, // 版本词对不上
	}
	got := recordingISRCsFromScored("JPU902200009", scored, 281.093, "Listen", "JTW")
	want := []recordedISRC{{"JPU902200009", isrcLevelPlayer}, {"HKA351501001", isrcLevelVerified}, {"HKC382400008", isrcLevelVerified},
		{"HKA351501001", isrcLevelVerified}, {"HKA351509999", isrcLevelSearched}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("recordingISRCsFromScored = %v, want %v(播放器报的在前记 player,候选只收被认可、时长对得上的 applemusic / deezer,版本词对不上记 searched)", got, want)
	}
	if got := recordingISRCsFromScored("", scored, 0, "Listen", "JTW"); len(got) != 0 {
		t.Errorf("播放器没报时长时候选报的一个都不收: %v", got)
	}
}

// 候选的曲名证明不了是这一条:歌手泛搜凭时长改写曲名之后那一轮搜到的、两边都是拉丁字母又明摆着是两首歌的,只记 searched;
// 别的改写轮(原产地商店、专辑曲目表)和跨文字的照旧记 verified。
func TestRecordingISRCsFromScoredTitleProof(t *testing.T) {
	cand := func(isrc, title, method string) scoredLyricCandidateResult {
		return scoredLyricCandidateResult{Source: "applemusic", Score: 500, SourceReportedDurationSecs: 243, ISRC: isrc, Title: title, RetryMethod: method}
	}
	scored := []scoredLyricCandidateResult{
		cand("TWA479820005", "我的情歌", lyricQueryReasonTitleStorefront),
		cand("TWA479820009", "你伤了我的心", lyricQueryReasonTitleSearch),
		cand("TWA479820010", "我的情歌", "title-from-album"),
		cand("USUM70000001", "Sabana de luz", ""),
		cand("TWA479820011", "Wo De Qing Ge", ""),
		cand("TWA479820012", "我的情歌", ""),
	}
	got := recordingISRCsFromScored("", scored, 243, "Wo De Qing Ge", "Revolution")
	want := []recordedISRC{
		{"TWA479820005", isrcLevelVerified}, {"TWA479820009", isrcLevelSearched}, {"TWA479820010", isrcLevelVerified},
		{"USUM70000001", isrcLevelSearched}, {"TWA479820011", isrcLevelVerified}, {"TWA479820012", isrcLevelVerified},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("recordingISRCsFromScored = %v, want %v", got, want)
	}
}

// 级别:同一个号取更高的;满了以后级别更高的号挤掉最低的那个,挤不掉的不记;不改原来那份 isrc_levels;拿掉号时级别一起拿掉。
func TestRecordISRCLevels(t *testing.T) {
	shared := map[string]string{"HKA351501001": isrcLevelSearched}
	e := enrichEntry{ISRCs: []string{"HKA351501001"}, ISRCLevels: shared}
	recordISRCs(&e, []recordedISRC{{"hka351501001", isrcLevelPlayer}, {"HKC382400008", isrcLevelVerified}, {"HKI490667205", ""},
		{"HKI490867102", isrcLevelSearched}, {"HKI490867406", isrcLevelPlayer}})
	// 第五个号是播放器报的:挤掉没记级别的 HKI490667205,接在末尾。
	if want := []string{"HKA351501001", "HKC382400008", "HKI490867102", "HKI490867406"}; !reflect.DeepEqual(e.ISRCs, want) {
		t.Errorf("isrcs = %v, want %v", e.ISRCs, want)
	}
	want := map[string]string{"HKA351501001": isrcLevelPlayer, "HKC382400008": isrcLevelVerified, "HKI490867102": isrcLevelSearched,
		"HKI490867406": isrcLevelPlayer}
	if !reflect.DeepEqual(e.ISRCLevels, want) {
		t.Errorf("isrc_levels = %v, want %v", e.ISRCLevels, want)
	}
	if shared["HKA351501001"] != isrcLevelSearched {
		t.Error("原来那份 isrc_levels 被改了")
	}
	recordISRCs(&e, []recordedISRC{{"HKA351501001", isrcLevelSearched}})
	if e.ISRCLevels["HKA351501001"] != isrcLevelPlayer {
		t.Error("低的级别不覆盖高的")
	}
	dst := enrichEntry{}
	mergeEntryISRCs(&dst, e)
	if !reflect.DeepEqual(dst.ISRCs, e.ISRCs) || !reflect.DeepEqual(dst.ISRCLevels, e.ISRCLevels) {
		t.Errorf("合并条目连同级别并过来: %+v", dst)
	}
	removeISRCs(&e, func(c string) bool { return c == "HKA351501001" || c == "HKI490867406" })
	if want := map[string]string{"HKC382400008": isrcLevelVerified, "HKI490867102": isrcLevelSearched}; !reflect.DeepEqual(e.ISRCLevels, want) ||
		len(e.ISRCs) != 2 {
		t.Errorf("拿掉号时级别一起拿掉: %+v", e)
	}
	removeISRCs(&e, func(string) bool { return true })
	if e.ISRCs != nil || e.ISRCLevels != nil {
		t.Errorf("拿光时两个字段都是 nil: %+v", e)
	}
}

// 补扫按检索配上的 Apple 链接取回的号:版本词对得上、署名写全了合作者(或时长几乎相等)才算 verified。
func TestAppleSweepISRCLevel(t *testing.T) {
	duet := "Sam Smith & Aitana|Like I Can|In The Lonely Hour (10th Anniversary Edition / Deluxe)"
	solo := appleCatalogSong{isrc: "GBUM71308834", durationSecs: 168.08, artist: "Sam Smith", title: "Like I Can", album: "In The Lonely Hour (10th Anniversary Edition / Deluxe)"}
	if got := appleSweepISRCLevel(duet, solo, 166.707); got != isrcLevelSearched {
		t.Errorf("合唱版的链接配到独唱那一轨:searched,实得 %s", got)
	}
	credited := solo
	credited.artist = "Sam Smith & Aitana"
	if got := appleSweepISRCLevel(duet, credited, 166.707); got != isrcLevelVerified {
		t.Errorf("署名写全了:verified,实得 %s", got)
	}
	live := credited
	live.title = "Like I Can (Live)"
	if got := appleSweepISRCLevel(duet, live, 166.707); got != isrcLevelSearched {
		t.Errorf("版本词对不上:searched,实得 %s", got)
	}
	if got := appleSweepISRCLevel("Sam Smith|Like I Can|In The Lonely Hour", solo, 167.065); got != isrcLevelVerified {
		t.Errorf("没点名合作者、版本词对得上:verified,实得 %s", got)
	}
}

// 满了以后:级别不比最低的高就进不来;高的挤掉最低的(最低的有几个挤最后进来的);同一次里先进来的号也按它带的级别算。
func TestRecordISRCEviction(t *testing.T) {
	full := func() enrichEntry {
		return enrichEntry{ISRCs: []string{"USAAA0000001", "USAAA0000002", "USAAA0000003", "USAAA0000004"},
			ISRCLevels: map[string]string{"USAAA0000001": isrcLevelPlayer, "USAAA0000002": isrcLevelSearched,
				"USAAA0000003": isrcLevelVerified, "USAAA0000004": isrcLevelSearched}}
	}
	e := full()
	recordISRCs(&e, []recordedISRC{{"USAAA0000005", isrcLevelSearched}, {"USAAA0000006", ""}})
	if !reflect.DeepEqual(e.ISRCs, full().ISRCs) || !reflect.DeepEqual(e.ISRCLevels, full().ISRCLevels) {
		t.Errorf("级别不比最低的高,进不来: %+v", e)
	}
	e = full()
	recordISRCs(&e, []recordedISRC{{"USAAA0000005", isrcLevelVerified}})
	if want := []string{"USAAA0000001", "USAAA0000002", "USAAA0000003", "USAAA0000005"}; !reflect.DeepEqual(e.ISRCs, want) ||
		e.ISRCLevels["USAAA0000004"] != "" || e.ISRCLevels["USAAA0000005"] != isrcLevelVerified {
		t.Errorf("核对过的号挤掉最后进来的检索配的号: %+v", e)
	}
	e = full()
	recordISRCs(&e, []recordedISRC{{"USAAA0000005", isrcLevelPlayer}, {"USAAA0000006", isrcLevelPlayer}, {"USAAA0000007", isrcLevelPlayer}})
	if want := []string{"USAAA0000001", "USAAA0000005", "USAAA0000006", "USAAA0000007"}; !reflect.DeepEqual(e.ISRCs, want) {
		t.Errorf("一次来三个播放器报的号,依次挤掉两个检索配的、一个核对过的: %v", e.ISRCs)
	}
	if want := map[string]string{"USAAA0000001": isrcLevelPlayer, "USAAA0000005": isrcLevelPlayer, "USAAA0000006": isrcLevelPlayer,
		"USAAA0000007": isrcLevelPlayer}; !reflect.DeepEqual(e.ISRCLevels, want) {
		t.Errorf("挤掉的号级别一起拿掉: %v", e.ISRCLevels)
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

func TestISRCLookupParts(t *testing.T) {
	e := enrichEntry{AppleURL: "https://music.apple.com/cn/album/x/1587171414?i=1587171823&uo=4",
		SpotifyTrackID: "7HuBDWi18s4aJM8UFnNheH", AmazonURL: "https://music.amazon.com/tracks/B0ABCDE123"}
	want := []string{"apple:cn:1587171823", "spotify-local:7HuBDWi18s4aJM8UFnNheH", "amazon-local:B0ABCDE123"}
	if got := isrcLookupParts(e); !reflect.DeepEqual(got, want) {
		t.Errorf("isrcLookupParts = %v, want %v", got, want)
	}
	if got := isrcLookupParts(enrichEntry{AppleURL: "https://music.apple.com/us/album/x/123", AmazonURL: "https://music.amazon.com/tracks/bad"}); got != nil {
		t.Errorf("链接里没有歌曲 id、ASIN 形状不对的不算: %v", got)
	}
	// 原来的 spotify:<id> 那时不记级别,不算 spotify-local 补过;跟现在的 id 对不上的旧记号丢掉;锚点那一支排在 apple 后面。
	e.ISRCLookup = "apple:cn:1587171823 spotify:7HuBDWi18s4aJM8UFnNheH apple:us:1"
	if got := isrcLookupWith(e, "amazon-local:B0ABCDE123", "apple-anchor:cn:1587171823"); got != "apple:cn:1587171823 apple-anchor:cn:1587171823 amazon-local:B0ABCDE123" {
		t.Errorf("isrcLookupWith = %q", got)
	}
	if job, ok := isrcSweepJobFor("k", e); !ok || job.askApple || !job.readSpotify || !job.readAmazon || job.anchorCheck {
		t.Errorf("旧的 spotify: 记号按本机缓存重读,Amazon 那支要读,Apple 补过不再问: %+v", job)
	}
}

func TestISRCSweepJobs(t *testing.T) {
	cn := "https://music.apple.com/cn/album/%E5%90%AC/1587171414?i=1587171823&uo=4"
	withEnrichCache(t, map[string]enrichEntry{
		"Khalil Fong|How It Feels|Wonderland": {AppleURL: "https://music.apple.com/us/album/how-it-feels/272875165?i=272875201&uo=4", DurationSecs: 223},
		"方大同|听|JTW西游记":                        {AppleURL: cn, DurationSecs: 281.093, ISRCLookup: "apple:cn:1587171823"},
		"Artist|Song|Album": {SpotifyTrackID: "7HuBDWi18s4aJM8UFnNheH", DurationSecs: 200,
			ISRCLookup: "spotify-local:7HuBDWi18s4aJM8UFnNheH"},
		"Artist|Old|Album":    {SpotifyTrackID: "7HuBDWi18s4aJM8UFnNheX", DurationSecs: 200, ISRCLookup: "spotify:7HuBDWi18s4aJM8UFnNheX"},
		"Artist|Amazon|Album": {AmazonURL: "https://music.amazon.com/tracks/B0ABCDE123", DurationSecs: 200},
		"Artist|Played|Album": {AppleURL: cn, DurationSecs: 281.093, ISRCLookup: "apple:cn:1587171823", Players: []string{appleMusicBundleID}},
		"Artist|Anchored|Album": {AppleURL: cn, DurationSecs: 281.093, ISRCLookup: "apple:cn:1587171823 apple-anchor:cn:1587171823",
			Players: []string{appleMusicBundleID}},
		"Artist|NoID|Album":   {AppleURL: "https://music.apple.com/us/album/x/123", DurationSecs: 200},
		"Artist|Search|Album": {QQURL: "https://y.qq.com/n/ryqq/search?w=x"},
	})
	enrichMu.Lock()
	jobs := isrcSweepJobsLocked()
	enrichMu.Unlock()
	got := map[string]isrcSweepJob{}
	var keys []string
	for _, j := range jobs {
		got[j.key] = j
		keys = append(keys, j.key)
	}
	want := []string{"Artist|Amazon|Album", "Artist|Old|Album", "Artist|Played|Album", "Khalil Fong|How It Feels|Wonderland"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("挑出来的条目(按 key 排) = %v, want %v", keys, want)
	}
	if j := got["Khalil Fong|How It Feels|Wonderland"]; !j.askApple || j.appleID != "272875201" || j.storefront != "us" || j.readSpotify || j.anchorCheck {
		t.Errorf("Apple 那条按链接里的商店问: %+v", j)
	}
	if j := got["Artist|Old|Album"]; !j.readSpotify || j.spotifyID != "7HuBDWi18s4aJM8UFnNheX" || j.askApple {
		t.Errorf("原来的 spotify: 记号按本机缓存重读: %+v", j)
	}
	if j := got["Artist|Amazon|Album"]; !j.readAmazon || j.amazonASIN != "B0ABCDE123" || !reflect.DeepEqual(j.parts, []string{"amazon-local:B0ABCDE123"}) {
		t.Errorf("Amazon 那条读本机目录缓存: %+v", j)
	}
	if j := got["Artist|Played|Album"]; !j.anchorCheck || j.askApple {
		t.Errorf("在 Apple Music 上放过、锚点那一支没做过:先在锁外核对锚点,别的不用问: %+v", j)
	}
}

func TestISRCResolveAnchors(t *testing.T) {
	cn := "https://music.apple.com/cn/album/x/1587171414?i=1587171823&uo=4"
	jobs := []isrcSweepJob{
		{key: "方大同|听~dur281|JTW西游记", appleID: "1587171823", storefront: "cn", durationSecs: 281, anchorCheck: true},
		{key: "A|别的|B", appleID: "1587171823", storefront: "cn", durationSecs: 281, anchorCheck: true, readSpotify: true, spotifyID: "s"},
		{key: "A|没有|B", appleID: "1587171823", storefront: "cn", durationSecs: 281, anchorCheck: true},
		{key: "A|只读|B", readAmazon: true, amazonASIN: "B0ABCDE123"},
	}
	var asked []string
	anchor := func(artist, title, album string, durationSecs float64) string {
		asked = append(asked, artist+"|"+title+"|"+album)
		switch title {
		case "听":
			return cn
		case "别的":
			return "https://music.apple.com/cn/album/x/1?i=999"
		}
		return ""
	}
	out := isrcResolveAnchors(jobs, anchor)
	if len(out) != 3 {
		t.Fatalf("不是锚点、别的几支也都补过的去掉: %+v", out)
	}
	if j := out[0]; !j.askApple || !j.applePlayer || j.anchorCheck {
		t.Errorf("链接就是锚点:按锚点问、号记 player: %+v", j)
	}
	if j := out[1]; j.askApple || j.applePlayer || !j.readSpotify {
		t.Errorf("锚点是别的曲目:不问锚点那一支,本机缓存照读: %+v", j)
	}
	if j := out[2]; j.key != "A|只读|B" || j.askApple {
		t.Errorf("不用核对锚点的原样留着: %+v", j)
	}
	if !reflect.DeepEqual(asked, []string{"方大同|听|JTW西游记", "A|别的|B", "A|没有|B"}) {
		t.Errorf("按写法键(歌名去掉时长变体位)查锚点,不用核对的不查: %v", asked)
	}
}

func TestRunISRCSweepJobs(t *testing.T) {
	var appleCalls []string
	deps := isrcSweepDeps{
		spotify: func(ids []string) map[string]string {
			return map[string]string{"7HuBDWi18s4aJM8UFnNheH": "gbum71308833"}
		},
		amazon: func(asin string) string {
			if asin == "B0ABCDE123" {
				return "USUM72100001"
			}
			return ""
		},
		apple: func(ctx context.Context, storefront string, ids []string) (map[string]appleCatalogSong, bool) {
			appleCalls = append(appleCalls, storefront+":"+strings.Join(ids, ","))
			if storefront == "us" {
				return nil, false
			}
			return map[string]appleCatalogSong{
				"1587171823": {isrc: "HKA351501001", durationSecs: 281.093, artist: "方大同", title: "听", album: "JTW西游记"},
				"2":          {isrc: "HKA351501002", durationSecs: 200, artist: "A", title: "Song", album: "Album"},
			}, true
		},
	}
	jobs := []isrcSweepJob{
		{key: "A|Spotify|B", spotifyID: "7HuBDWi18s4aJM8UFnNheH", readSpotify: true},
		{key: "A|SpotifyMiss|B", spotifyID: "7HuBDWi18s4aJM8UFnNheX", readSpotify: true},
		{key: "A|Amazon|B", amazonASIN: "B0ABCDE123", readAmazon: true},
		{key: "方大同|听|JTW西游记", appleID: "1587171823", storefront: "cn", durationSecs: 281.093, askApple: true, applePlayer: true},
		{key: "A|Song|Album", appleID: "2", storefront: "cn", durationSecs: 200, askApple: true},
		{key: "A|US|B", appleID: "3", storefront: "us", durationSecs: 200, askApple: true},
	}
	out, requests := runISRCSweepJobs(context.Background(), jobs, deps)
	if requests != 2 || !reflect.DeepEqual(appleCalls, []string{"cn:1587171823,2", "us:3"}) {
		t.Errorf("Apple 按商店分批问: requests=%d calls=%v", requests, appleCalls)
	}
	check := func(key string, isrcs []recordedISRC, done []string, settled bool) {
		t.Helper()
		o := out[key]
		if !reflect.DeepEqual(o.isrcs, isrcs) || !reflect.DeepEqual(o.done, done) || o.settled != settled {
			t.Errorf("%s: %+v, want isrcs=%v done=%v settled=%v", key, *o, isrcs, done, settled)
		}
	}
	check("A|Spotify|B", []recordedISRC{{"GBUM71308833", isrcLevelPlayer}}, []string{"spotify-local:7HuBDWi18s4aJM8UFnNheH"}, true)
	// 本机缓存里还没有这首:不记成读过,下次再读。
	check("A|SpotifyMiss|B", nil, nil, true)
	check("A|Amazon|B", []recordedISRC{{"USUM72100001", isrcLevelPlayer}}, []string{"amazon-local:B0ABCDE123"}, true)
	check("方大同|听|JTW西游记", []recordedISRC{{"HKA351501001", isrcLevelPlayer}},
		[]string{"apple:cn:1587171823", "apple-anchor:cn:1587171823"}, true)
	check("A|Song|Album", []recordedISRC{{"HKA351501002", isrcLevelVerified}}, []string{"apple:cn:2"}, true)
	// 这一批没问成:整条不写,下次再来。
	check("A|US|B", nil, nil, false)
}

func TestApplyISRCSweepResult(t *testing.T) {
	apple := "https://music.apple.com/cn/album/%E5%90%AC/1587171414?i=1587171823&uo=4"
	withEnrichCache(t, map[string]enrichEntry{
		"a": {AppleURL: apple, DurationSecs: 281.093, ISRCs: []string{"HKC382400008"}, SpotifyTrackID: "7HuBDWi18s4aJM8UFnNheH",
			ISRCLookup: "spotify:7HuBDWi18s4aJM8UFnNheH"},
		"b": {AppleURL: "https://music.apple.com/cn/album/x/1?i=2", DurationSecs: 200},
	})
	enrichMu.Lock()
	defer enrichMu.Unlock()
	partsA := []string{"apple:cn:1587171823", "spotify-local:7HuBDWi18s4aJM8UFnNheH"}
	o := isrcSweepOutcome{isrcs: []recordedISRC{{"HKA351501001", isrcLevelVerified}, {"HKC382400008", isrcLevelPlayer}},
		done: partsA, settled: true}
	if !applyISRCSweepResultLocked(isrcSweepJob{key: "a", parts: partsA}, o) {
		t.Fatal("id 没变时写回")
	}
	e := enrichCache["a"]
	if !reflect.DeepEqual(e.ISRCs, []string{"HKC382400008", "HKA351501001"}) ||
		!reflect.DeepEqual(e.ISRCLevels, map[string]string{"HKC382400008": isrcLevelPlayer, "HKA351501001": isrcLevelVerified}) ||
		e.ISRCLookup != "apple:cn:1587171823 spotify-local:7HuBDWi18s4aJM8UFnNheH" {
		t.Errorf("合进已有的、老号按本机缓存补记成 player、记下做完的几支(旧的 spotify: 记号去掉): %+v", e)
	}
	if applyISRCSweepResultLocked(isrcSweepJob{key: "b", parts: []string{"apple:cn:3"}}, isrcSweepOutcome{done: []string{"apple:cn:3"}, settled: true}) {
		t.Error("问的时候链接已经换了(id 对不上)就不写")
	}
	if applyISRCSweepResultLocked(isrcSweepJob{key: "gone", parts: []string{"apple:cn:3"}}, isrcSweepOutcome{settled: true}) {
		t.Error("条目没了不复活")
	}
	if applyISRCSweepResultLocked(isrcSweepJob{key: "b", parts: []string{"apple:cn:2"}}, isrcSweepOutcome{done: []string{"apple:cn:2"}}) {
		t.Error("这一批没问成不写")
	}
	if applyISRCSweepResultLocked(isrcSweepJob{key: "b", parts: []string{"apple:cn:2"}}, isrcSweepOutcome{settled: true}) {
		t.Error("什么都没做成(本机缓存没读到)不写")
	}
	if !applyISRCSweepResultLocked(isrcSweepJob{key: "b", parts: []string{"apple:cn:2"}}, isrcSweepOutcome{done: []string{"apple:cn:2"}, settled: true}) ||
		enrichCache["b"].ISRCLookup != "apple:cn:2" || enrichCache["b"].ISRCs != nil {
		t.Errorf("没取到 ISRC 也记成问过: %+v", enrichCache["b"])
	}
}

func TestPlaybackISRCJob(t *testing.T) {
	anchor := "https://music.apple.com/cn/album/x/1587171414?i=1587171823&uo=4"
	withEnrichCache(t, nil)
	savedInflight, savedTried := isrcPlaybackInflight, isrcPlaybackTried
	isrcPlaybackInflight, isrcPlaybackTried = map[string]bool{}, map[string]time.Time{}
	t.Cleanup(func() { isrcPlaybackInflight, isrcPlaybackTried = savedInflight, savedTried })
	now := time.Unix(1_800_000_000, 0)
	e := enrichEntry{AppleURL: anchor, DurationSecs: 281}
	job, ok := playbackISRCJobLocked("k", e, appleMusicBundleID, anchor, now)
	if !ok || !job.askApple || !job.applePlayer || job.readSpotify {
		t.Fatalf("Apple Music 正在放、链接就是锚点:问一次,号记 player: %+v ok=%v", job, ok)
	}
	if _, again := playbackISRCJobLocked("k", e, appleMusicBundleID, anchor, now.Add(isrcPlaybackRetry)); again {
		t.Error("在做的不重复起,过了重试间隔也一样")
	}
	delete(isrcPlaybackInflight, "k")
	if _, again := playbackISRCJobLocked("k", e, appleMusicBundleID, anchor, now.Add(time.Minute)); again {
		t.Error("没做成的隔 isrcPlaybackRetry 才再试")
	}
	if _, again := playbackISRCJobLocked("k", e, appleMusicBundleID, anchor, now.Add(isrcPlaybackRetry)); !again {
		t.Error("过了 isrcPlaybackRetry 再试")
	}
	if _, ok := playbackISRCJobLocked("k2", e, spotifyBundleID, anchor, now); ok {
		t.Error("别的播放器在放:链接碰巧是锚点也不当播放器给的,留给补扫")
	}
	if _, ok := playbackISRCJobLocked("k3", enrichEntry{AppleURL: "https://music.apple.com/cn/album/x/1?i=2"}, appleMusicBundleID, anchor, now); ok {
		t.Error("链接不是锚点(按歌名配的):留给补扫,不当场联网")
	}
	sp := enrichEntry{SpotifyTrackID: "7HuBDWi18s4aJM8UFnNheH", AppleURL: "https://music.apple.com/cn/album/x/1?i=2"}
	if job, ok := playbackISRCJobLocked("k4", sp, spotifyBundleID, "", now); !ok || !job.readSpotify || job.askApple {
		t.Errorf("本机缓存那支没读到过就当场读,按歌名配的 Apple 链接留给补扫: %+v ok=%v", job, ok)
	}
	anchored := e
	anchored.ISRCLookup = "apple:cn:1587171823 apple-anchor:cn:1587171823"
	if _, ok := playbackISRCJobLocked("k5", anchored, appleMusicBundleID, anchor, now); ok {
		t.Error("锚点那一支补过就不再问")
	}
}

// 正在放的那首当场补到号之后走带 key 的存盘:这一条进待落盘小文件(一次性子命令和 App 不用等整份落盘),没补到不记。
func TestPlaybackISRCJobSavesThisEntry(t *testing.T) {
	withTempDecisionCache(t)
	savedKeys, savedInflight := enrichPendingKeys, isrcPlaybackInflight
	savedNow, savedSave := enrichPendingNow, enrichSaveNow
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichPendingKeys, isrcPlaybackInflight = savedKeys, savedInflight
		enrichMu.Unlock()
		enrichPendingNow, enrichSaveNow = savedNow, savedSave
	})
	enrichPendingNow, enrichSaveNow = func() {}, func() {}
	deps := isrcSweepDeps{amazon: func(asin string) string {
		if asin == "B00FAEYA98" {
			return "TWA479820001"
		}
		return ""
	}}
	for _, c := range []struct {
		key, asin string
		want      bool
	}{
		{"Leehom Wang|Gong Zhuan Zi Zhuan|Revolution", "B00FAEYA98", true},
		{"Leehom Wang|Nothing|Revolution", "B00NOTHING", false},
	} {
		enrichMu.Lock()
		enrichPendingKeys, isrcPlaybackInflight = map[string]uint64{}, map[string]bool{c.key: true}
		enrichCache[c.key] = enrichEntry{DurationSecs: 256}
		enrichMu.Unlock()
		runPlaybackISRCJobWith(isrcSweepJob{key: c.key, amazonASIN: c.asin, readAmazon: true}, deps)
		enrichMu.Lock()
		_, pending := enrichPendingKeys[c.key]
		isrcs := enrichCache[c.key].ISRCs
		enrichMu.Unlock()
		if pending != c.want || (c.want && len(isrcs) != 1) {
			t.Errorf("%s: 进待落盘 = %v(want %v), isrcs = %v", c.key, pending, c.want, isrcs)
		}
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
	in := map[string]enrichEntry{"a|b|c": {ISRCs: []string{"HKA351501001"}, ISRCLevels: map[string]string{"HKA351501001": isrcLevelPlayer},
		ISRCLookup: "apple:cn:1587171823"}}
	raw, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"isrcs":["HKA351501001"]`) || !strings.Contains(string(raw), `"isrc_lookup":"apple:cn:1587171823"`) ||
		!strings.Contains(string(raw), `"isrc_levels":{"HKA351501001":"player"}`) {
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
		strings.Count(enrich, "recordISRCs(&e, recordingISRCsFromScored(sourceISRC, scored, durationSecs, title, album))"); n != 2 || m != 2 {
		t.Errorf("重试升级、重打分两处在上锁之前取 ISRC 再收,现在取 %d 处、收 %d 处", n, m)
	}
	if !strings.Contains(enrich, "mergeEntryISRCs(&e, fresh)") {
		t.Error("外围补全并进这一轮的 ISRC")
	}
	if !strings.Contains(read("enrichkey.go"), "mergeEntryISRCs(&winner, loser)") {
		t.Error("合并条目时把落选那条的 ISRC 并过来")
	}
	if !strings.Contains(read("poller.go"), "go startRecordingISRCSweep(ctx)") {
		t.Error("引擎起来时开存量补扫")
	}
	sweep := read("recordingisrc.go")
	if !strings.Contains(sweep, "spotifyCodes = deps.spotify(spotifyIDs)") || !strings.Contains(sweep, "spotify: spotifyLocalISRCs, amazon: amazonISRCForASIN") ||
		strings.Contains(sweep, "spotifyLocalISRC(job.") {
		t.Error("补号的 Spotify 那几条一次查完(spotifyLocalISRCs),别一条一条查;Amazon 读本机目录缓存")
	}
	if !containsCode(sweep, "enrichMu.Unlock()\n\t// 锚点在 appleCatalogMu 后面,放开 enrichMu 再核对。\n\tjobs = isrcResolveAnchors(jobs, appleCatalogLinkFor)") {
		t.Error("补扫在放开 enrichMu 之后才核对锚点(appleCatalogMu 要先于 enrichMu 取)")
	}
	if !containsCode(enrich, "if !enrichInflight[key] {\n\t\t\tif job, ok := playbackISRCJobLocked(key, e, bundleID, anchorLink, time.Now()); ok {\n\t\t\t\tgo runPlaybackISRCJob(job)") {
		t.Error("缓存命中那一支当场补播放器给的号(锚点在取 enrichMu 之前算好);这条还有后台解析在跑时先不起,免得被那次整条提交盖掉")
	}
	if !strings.Contains(read("../lyrimuse/Sources/LyrimuseCore/Local/EnrichCacheReader.swift"), "        case isrcs\n") {
		t.Error("App 解码 isrcs(EnrichCacheReader.swift 的 CodingKeys)")
	}
}
