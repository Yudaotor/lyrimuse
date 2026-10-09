package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// head 里 <amll:meta> 登记的网易云 / QQ ID、ISRC 读出来:去掉首尾空白与空值,ISRC 归一、归一后为空的丢掉,别的键不收;
// Apple 那一路(parseAMLLTTML)不读。
func TestParseAMLLTTMLForHeadIDs(t *testing.T) {
	raw := `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll">` +
		`<head><metadata xmlns=""><ttm:agent type="person" xml:id="v1"/>` +
		`<amll:meta key="ncmMusicId" value="186016"/><amll:meta key="qqMusicId" value="0039MnYb0qxYhV"/><amll:meta key="qqMusicId" value=" 97773 "/>` +
		`<amll:meta key="qqMusicId" value=""/><amll:meta key="spotifyId" value="0F02KChKwbcQ3tk4q1YxLH"/><amll:meta key="appleMusicId" value="535824738"/>` +
		`<amll:meta key="isrc" value="tw-k97-03-00503"/><amll:meta key="isrc" value=" - "/><amll:meta key="musicName" value="晴天"/></metadata></head>` +
		`<body><div><p begin="1.000" end="2.000"><span begin="1.000" end="2.000">故事的小黄花</span></p></div></body></tt>`
	r, ok := parseAMLLTTMLFor(raw, "zh")
	if !ok {
		t.Fatal("解析失败")
	}
	if got := strings.Join(r.ncmIDs, ","); got != "186016" {
		t.Errorf("ncmIDs = %q", got)
	}
	if got := strings.Join(r.qqIDs, ","); got != "0039MnYb0qxYhV,97773" {
		t.Errorf("qqIDs = %q", got)
	}
	if got := strings.Join(r.isrcs, ","); got != "TWK970300503" {
		t.Errorf("isrcs = %q", got)
	}
	if a, _ := parseAMLLTTML(raw); a.ncmIDs != nil || a.qqIDs != nil || a.isrcs != nil {
		t.Errorf("parseAMLLTTML 不读 amll:meta: %v %v %v", a.ncmIDs, a.qqIDs, a.isrcs)
	}
}

// amll 候选借封面:先借取回它的那一家,那一家没有封面时借 head 登记了同一曲目 ID 的网易云 / QQ,最后借 ISRC 对得上的
// Apple Music / Deezer;对得上但没有封面的那一家跳过;都对不上就空着。
func TestAMLLCandidateCover(t *testing.T) {
	ne := neteaseInfo{Cover: "ne.jpg", SongID: 186016}
	qq := lyricSourceResult{matchCover: "qq.jpg", trackIDs: []string{"0039MnYb0qxYhV", "97773"}}
	qqMidOnly := lyricSourceResult{matchCover: "qq.jpg", trackIDs: []string{"0039MnYb0qxYhV"}}
	am := lyricSourceResult{matchCover: "am.jpg", isrc: "TWK970300503"}
	dz := lyricSourceResult{matchCover: "dz.jpg", isrc: "twk970300503"}
	var none lyricSourceResult
	head := amllResult{ncmIDs: []string{"186016"}, qqIDs: []string{"97773"}, isrcs: []string{"TWK970300503"}}
	on := func(platform string, r amllResult) amllResult {
		r.platform = platform
		return r
	}
	for _, c := range []struct {
		name       string
		r          amllResult
		ne         neteaseInfo
		qq, am, dz lyricSourceResult
		want       string
	}{
		{"按网易云 ID 取回的借网易云", on("ncm-lyrics", amllResult{}), ne, qq, am, dz, "ne.jpg"},
		{"按 QQ ID 取回的借 QQ", on("qq-lyrics", amllResult{}), ne, qq, am, dz, "qq.jpg"},
		{"取回它的网易云那张扣掉了,借登记了同一数字 ID 的 QQ", on("ncm-lyrics", head), neteaseInfo{SongID: 186016}, qq, am, dz, "qq.jpg"},
		{"按 QQ ID 取回、QQ 没有封面时借 ISRC 对得上的 Apple Music", on("qq-lyrics", head), neteaseInfo{}, lyricSourceResult{trackIDs: qq.trackIDs}, am, none, "am.jpg"},
		{"QQ 登记了同一首但没有封面,接着往下借", on("ncm-lyrics", head), neteaseInfo{SongID: 186016}, lyricSourceResult{trackIDs: qq.trackIDs}, am, none, "am.jpg"},
		{"QQ 那首没登记,借 ISRC 对得上的 Apple Music", on("ncm-lyrics", head), neteaseInfo{SongID: 186016}, qqMidOnly, am, dz, "am.jpg"},
		{"在索引里找到的,网易云那首登记了就借网易云", head, ne, none, none, none, "ne.jpg"},
		{"按 Apple ID 取回的,Apple Music 没有封面时借 ISRC 对得上的 Deezer(写法归一)", on("am-lyrics", amllResult{isrcs: head.isrcs}), neteaseInfo{}, none,
			lyricSourceResult{isrc: "TWK970300503"}, dz, "dz.jpg"},
		{"ISRC 对不上不借", on("am-lyrics", amllResult{isrcs: head.isrcs}), neteaseInfo{}, none, lyricSourceResult{matchCover: "am.jpg", isrc: "USUG12601721"}, none, ""},
		{"没有登记、也不是那两家取回的,不借", amllResult{}, ne, qq, am, dz, ""},
		{"网易云没拿到曲目 ID 时不按 0 去比", amllResult{ncmIDs: []string{"0"}}, neteaseInfo{Cover: "ne.jpg"}, none, none, none, ""},
	} {
		if got := amllCandidateCover(c.r, c.ne, c.qq, c.am, c.dz); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

// 组装 amll 候选时按 amllCandidateCover 借:网易云那张扣掉了时借登记了同一数字 ID 的 QQ;只有 ISRC 对得上的
// Apple Music / Deezer 时借它们的。
func TestRankLyricSourceResultsAMLLBorrowsSameRecordingCover(t *testing.T) {
	var lrc strings.Builder
	for i := 0; i < 20; i++ {
		lrc.WriteString(formatLRCTime((10+i*10)*1000) + fmt.Sprintf("Line number %d of the song\n", i))
	}
	amll := amllResult{lrc: lrc.String(), platform: "ncm-lyrics", qqIDs: []string{"97773"}, isrcs: []string{"TWK970300503"}}
	cover := func(raw map[string]lyricSourceResult) string {
		raw["amll"] = lyricSourceResult{source: "amll", amll: amll}
		for _, r := range rankLyricSourceResults("周杰伦", "晴天", "叶惠美", 269, raw) {
			if r.Source == "amll" {
				return r.CoverURL
			}
		}
		t.Fatal("没有 amll 候选")
		return ""
	}
	if got := cover(map[string]lyricSourceResult{
		"netease": {source: "netease", ne: neteaseInfo{SongID: 186016}},
		"qq":      {source: "qq", matchCover: "https://example.com/qq.jpg", trackIDs: []string{"0039MnYb0qxYhV", "97773"}},
	}); got != "https://example.com/qq.jpg" {
		t.Errorf("该借 QQ 的: %q", got)
	}
	if got := cover(map[string]lyricSourceResult{
		"applemusic": {source: "applemusic", matchCover: "https://example.com/am.jpg", isrc: "TWK970300503"},
	}); got != "https://example.com/am.jpg" {
		t.Errorf("该借 Apple Music 的: %q", got)
	}
	if got := cover(map[string]lyricSourceResult{
		"deezer": {source: "deezer", matchCover: "https://example.com/dz.jpg", isrc: "TWK970300503"},
	}); got != "https://example.com/dz.jpg" {
		t.Errorf("该借 Deezer 的: %q", got)
	}
	if got := cover(map[string]lyricSourceResult{
		"applemusic": {source: "applemusic", matchCover: "https://example.com/am.jpg", isrc: "TWK970300503"},
		"deezer":     {source: "deezer", matchCover: "https://example.com/dz.jpg", isrc: "TWK970300503"},
	}); got != "https://example.com/am.jpg" {
		t.Errorf("两家都对得上时先借 Apple Music 的: %q", got)
	}
}

// amll 借同一条录音的曲长,认法和先后同借封面;那一家没报时长就接着往下找。
func TestAMLLCandidateDuration(t *testing.T) {
	ne := neteaseInfo{DurationSecs: 269.4, SongID: 186016}
	qq := lyricSourceResult{srcDur: 269, trackIDs: []string{"0039MnYb0qxYhV", "97773"}}
	am := lyricSourceResult{srcDur: 270.1, isrc: "TWK970300503"}
	dz := lyricSourceResult{srcDur: 268, isrc: "twk970300503"}
	var none lyricSourceResult
	head := amllResult{ncmIDs: []string{"186016"}, qqIDs: []string{"97773"}, isrcs: []string{"TWK970300503"}}
	on := func(platform string, r amllResult) amllResult {
		r.platform = platform
		return r
	}
	for _, c := range []struct {
		name       string
		r          amllResult
		ne         neteaseInfo
		qq, am, dz lyricSourceResult
		want       float64
		from       string
	}{
		{"按网易云 ID 取回的借网易云", on("ncm-lyrics", amllResult{}), ne, qq, am, dz, 269.4, "netease"},
		{"按 QQ ID 取回的借 QQ", on("qq-lyrics", amllResult{}), ne, qq, am, dz, 269, "qq"},
		{"网易云没报时长,借登记了同一数字 ID 的 QQ", on("ncm-lyrics", head), neteaseInfo{SongID: 186016}, qq, am, dz, 269, "qq"},
		{"QQ 也没报,借 ISRC 对得上的 Apple Music", on("ncm-lyrics", head), neteaseInfo{SongID: 186016}, lyricSourceResult{trackIDs: qq.trackIDs}, am, dz, 270.1, "applemusic"},
		{"Apple Music 没报,借 ISRC 对得上的 Deezer(写法归一)", on("am-lyrics", amllResult{isrcs: head.isrcs}), neteaseInfo{}, none,
			lyricSourceResult{isrc: "TWK970300503"}, dz, 268, "deezer"},
		{"ISRC 对不上不借", on("am-lyrics", amllResult{isrcs: head.isrcs}), neteaseInfo{}, none, lyricSourceResult{srcDur: 270, isrc: "USUG12601721"}, none, 0, ""},
		{"没有登记、也不是那两家取回的,不借", amllResult{}, ne, qq, am, dz, 0, ""},
		{"网易云没拿到曲目 ID 时不按 0 去比", amllResult{ncmIDs: []string{"0"}}, neteaseInfo{DurationSecs: 200}, none, none, none, 0, ""},
	} {
		if got, from := amllCandidateDuration(c.r, c.ne, c.qq, c.am, c.dz); got != c.want || from != c.from {
			t.Errorf("%s: got %v/%q want %v/%q", c.name, got, from, c.want, c.from)
		}
	}
}

// 借来的曲长只透传给「搜索候选歌词」,打分照旧当 amll 没有自报时长:借到一个跟本地差很多的也不扣「源自报曲长不符」。
func TestRankLyricSourceResultsAMLLBorrowedDurationDisplayOnly(t *testing.T) {
	var lrc strings.Builder
	for i := 0; i < 20; i++ {
		lrc.WriteString(formatLRCTime((10+i*10)*1000) + fmt.Sprintf("Line number %d of the song\n", i))
	}
	amll := amllResult{lrc: lrc.String(), platform: "ncm-lyrics"}
	run := func(neDur float64) scoredLyricCandidateResult {
		raw := map[string]lyricSourceResult{
			"netease": {source: "netease", ne: neteaseInfo{SongID: 186016, DurationSecs: neDur}},
			"amll":    {source: "amll", amll: amll},
		}
		for _, r := range rankLyricSourceResults("周杰伦", "晴天", "叶惠美", 269, raw) {
			if r.Source == "amll" {
				return r
			}
		}
		t.Fatal("没有 amll 候选")
		return scoredLyricCandidateResult{}
	}
	plain, far := run(0), run(400)
	if far.BorrowedDurationSecs != 400 || far.BorrowedDurationFrom != "netease" || far.SourceReportedDurationSecs != 0 {
		t.Errorf("借来的曲长只放在 Borrowed 字段: %+v", far)
	}
	if plain.BorrowedDurationSecs != 0 || plain.BorrowedDurationFrom != "" {
		t.Errorf("网易云没报时长时不借: %+v", plain)
	}
	if far.Score != plain.Score || len(far.ScoreTerms) != len(plain.ScoreTerms) {
		t.Errorf("借来的曲长不参与打分: %d %v vs %d %v", far.Score, far.ScoreTerms, plain.Score, plain.ScoreTerms)
	}
}

// QQ 的两种 ID:数字 ID 只读单曲详情的缓存,没缓存时只给 songmid,没有 songmid 时什么都不给。
func TestQQTrackIDs(t *testing.T) {
	qqSongMetaMu.Lock()
	saved := qqSongMetaCache
	qqSongMetaCache = map[string]qqSongMeta{"0039MnYb0qxYhV": {id: 97773}}
	qqSongMetaMu.Unlock()
	t.Cleanup(func() {
		qqSongMetaMu.Lock()
		qqSongMetaCache = saved
		qqSongMetaMu.Unlock()
	})
	if got := strings.Join(qqTrackIDs("0039MnYb0qxYhV"), ","); got != "0039MnYb0qxYhV,97773" {
		t.Errorf("有缓存时两种都给: %q", got)
	}
	if got := strings.Join(qqTrackIDs("002xyzNoCache"), ","); got != "002xyzNoCache" {
		t.Errorf("没缓存时只给 songmid: %q", got)
	}
	if got := qqTrackIDs(""); got != nil {
		t.Errorf("没有 songmid: %v", got)
	}
}

// QQ 那一路把曲目 ID 带进原始应答:少了它,amll 借封面认不出 QQ 那首是不是 TTML 登记的那一条。
func TestQQResultCarriesTrackIDs(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "trackIDs: qqTrackIDs(qqMid)") {
		t.Error("qq 那一路的 lyricSourceResult 没带 trackIDs")
	}
}
