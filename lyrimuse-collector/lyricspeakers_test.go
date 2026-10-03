package main

import (
	"context"
	"encoding/json"
	"net/http"
	neturl "net/url"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

const (
	spkA = "mxm:artist:1"
	spkB = "mxm:artist:2"
)

var spkLines = []string{
	"I walk along the empty road",
	"Thinking of the things you said",
	"Every light is fading now",
	"Still I hear you in my head",
	"Every time I close my eyes",
	"I can see the morning rise",
	"Together we will find the way",
	"Together we will start today",
}

// spkSpans:前四行 A 唱,接着两行 B 唱,最后两行两人一起。
var spkSpans = []musixmatchPerformerSpan{
	{text: strings.Join(spkLines[:4], "\n"), performers: []string{spkA}},
	{text: strings.Join(spkLines[4:6], "\n"), performers: []string{spkB}},
	{text: strings.Join(spkLines[6:], "\n"), performers: []string{spkB, spkA}},
}

func spkLRC(startMs int, lines ...string) string {
	var b strings.Builder
	for i, l := range lines {
		b.WriteString(formatLRCTime(startMs+i*4000) + l + "\n")
	}
	return b.String()
}

func spkYRC(lines ...string) string {
	var b strings.Builder
	for i, l := range lines {
		s := 10000 + i*4000
		b.WriteString("[" + strconv.Itoa(s) + ",3000](" + strconv.Itoa(s) + ",3000,0)" + l + "\n")
	}
	return b.String()
}

func spkMx(spans []musixmatchPerformerSpan) scoredLyricCandidateResult {
	return scoredLyricCandidateResult{Source: "musixmatch", Score: 900, Lyrics: spkLRC(5000, spkLines...), Performers: spans}
}

// 片段的演唱者只收带歌手 ID 的 artist;只剩「未知」「和声」的片段留着(定位要用),演唱者为空;形状不对整份为空。
func TestParseMusixmatchPerformerTagging(t *testing.T) {
	raw := json.RawMessage(`{"completed":true,"content":[
		{"snippet":"Line one\nLine two","performers":[{"type":"artist","fqid":"mxm:artist:1","credit_role_id":405}]},
		{"snippet":"Line three","performers":[{"type":"unknown"},{"type":"artist","fqid":"mxm:artist:2"}]},
		{"snippet":"(ooh)","performers":[{"type":"backing_vocalist"}]}
	],"resources":{"artists":[{"artist_fq_id":"mxm:artist:1","artist_name":"A"}]}}`)
	want := []musixmatchPerformerSpan{
		{text: "Line one\nLine two", performers: []string{"mxm:artist:1"}},
		{text: "Line three", performers: []string{"mxm:artist:2"}},
		{text: "(ooh)"},
	}
	if got := parseMusixmatchPerformerTagging(raw); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v", got)
	}
	for _, bad := range []string{``, `null`, `[]`, `""`, `{"content":"x"}`} {
		if got := parseMusixmatchPerformerTagging(json.RawMessage(bad)); got != nil {
			t.Errorf("%q 该解析成空: %+v", bad, got)
		}
	}
}

// mxmMacroWithTagging:在 mxmMacroFixture 的匹配结果里加上 performer_tagging。
func mxmMacroWithTagging(t *testing.T, base string, tagging string) string {
	t.Helper()
	var root map[string]any
	if err := json.Unmarshal([]byte(base), &root); err != nil {
		t.Fatal(err)
	}
	calls := root["message"].(map[string]any)["body"].(map[string]any)["macro_calls"].(map[string]any)
	track := calls["matcher.track.get"].(map[string]any)["message"].(map[string]any)["body"].(map[string]any)["track"].(map[string]any)
	var pt any
	if err := json.Unmarshal([]byte(tagging), &pt); err != nil {
		t.Fatal(err)
	}
	track["performer_tagging"] = pt
	b, _ := json.Marshal(root)
	return string(b)
}

const mxmTestTagging = `{"content":[{"snippet":"line one\nline two\nline three","performers":[{"type":"artist","fqid":"mxm:artist:1"}]},` +
	`{"snippet":"line four\nline five\nline six","performers":[{"type":"artist","fqid":"mxm:artist:2"}]}]}`

// 标注跟着匹配结果一起解析;标注那一块形状不对时匹配结果照常可用。
func TestParseMusixmatchMacroPerformerTagging(t *testing.T) {
	base := mxmMacroFixture(t, "Song", "Singer", 194, 0, 200)
	m, ok := parseMusixmatchMacro([]byte(mxmMacroWithTagging(t, base, mxmTestTagging)))
	if !ok || len(m.performers) != 2 || m.performers[1].performers[0] != spkB {
		t.Fatalf("标注没解析出来: ok=%v %+v", ok, m.performers)
	}
	m, ok = parseMusixmatchMacro([]byte(mxmMacroWithTagging(t, base, `[]`)))
	if !ok || m.lrc != mxmTestLRC || m.performers != nil {
		t.Fatalf("标注形状不对不该连累匹配结果: ok=%v lrc=%v performers=%+v", ok, m.lrc != "", m.performers)
	}
}

// 生产请求要在 part 里带上 track_performer_tagging,取回来的标注一路带到结果上。
func TestResolveMusixmatchCarriesPerformers(t *testing.T) {
	f := withMxmFake(t, func(action string, r *http.Request) string {
		if action == "macro.subtitles.get" {
			return mxmMacroWithTagging(t, mxmMacroFixture(t, "Song", "Singer", 194, 0, 200), mxmTestTagging)
		}
		return mxmEmpty404
	})
	r := resolveMusixmatchLyric(context.Background(), "Singer", "Song", 194, "", "")
	if r.lrc == "" || len(r.performers) != 2 {
		t.Fatalf("结果没带上标注: lrc=%v performers=%+v", r.lrc != "", r.performers)
	}
	calls := f.called("macro.subtitles.get")
	if len(calls) == 0 {
		t.Fatal("没发 macro.subtitles.get")
	}
	q, _ := neturl.ParseQuery(calls[0][strings.Index(calls[0], "?")+1:])
	if part := q.Get("part"); !strings.Contains(part, "track_performer_tagging") || !strings.Contains(part, "track_lyrics_translation_status") {
		t.Errorf("part = %q", part)
	}
}

// 排序那一步把 musixmatch 的标注抄进候选。
func TestRankCarriesMusixmatchPerformers(t *testing.T) {
	raw := map[string]lyricSourceResult{
		"musixmatch": {source: "musixmatch", lyr: spkLRC(5000, spkLines...), performers: spkSpans},
	}
	scored := rankLyricSourceResults("someone", "song", "", 60, raw)
	if len(scored) == 0 || scored[0].Source != "musixmatch" || !reflect.DeepEqual(scored[0].Performers, spkSpans) {
		t.Fatalf("标注该进候选: %+v", scored)
	}
}

// 走完整的收集通道:musixmatch 候选带着标注。
func TestFetchCarriesMusixmatchPerformers(t *testing.T) {
	withMxmFake(t, func(action string, r *http.Request) string {
		if action == "macro.subtitles.get" {
			return mxmMacroWithTagging(t, mxmMacroFixture(t, "Song", "Singer", 194, 0, 200), mxmTestTagging)
		}
		return mxmEmpty404
	})
	setFeatureForTest(t, func(f *featureFlags) { f.LyricsSources = map[string]bool{"musixmatch": true} })
	_, scored := fetchScoredLyricCandidatesStreaming(qqRoundCtx(), "Singer", "Song", "", 194, nil)
	for _, r := range scored {
		if r.Source == "musixmatch" {
			if len(r.Performers) != 2 {
				t.Fatalf("musixmatch 候选的标注 = %+v", r.Performers)
			}
			return
		}
	}
	t.Fatalf("没有 musixmatch 候选: %+v", scored)
}

// 指纹:跟 App 侧 LyricSpeakerTags.fingerprint 同一组输入同一个输出;开头的 BOM 不算内容。
func TestLyricSpeakersFingerprint(t *testing.T) {
	lrc := "[00:01.00]hello\n[00:05.00]world"
	yrc := "[1000,500](1000,500,0)hello"
	for _, c := range []struct{ lyrics, yrc, want string }{
		{lrc, yrc, "8bef5a361f6e"},
		{"\uFEFF" + lrc, "\uFEFF\uFEFF" + yrc, "8bef5a361f6e"},
		{lrc, "", "aaf35c2bbdc7"},
	} {
		if got := lyricSpeakersFingerprint(c.lyrics, c.yrc); got != c.want {
			t.Errorf("fingerprint(%q, %q) = %s, want %s", c.lyrics, c.yrc, got, c.want)
		}
	}
	if lyricSpeakersFingerprint("ab", "") == lyricSpeakersFingerprint("a", "b") {
		t.Error("两份正文的分界要算进指纹")
	}
}

// 片段按文字顺序落到行上:重复的歌词按先后分给两个片段;括号里的字记成和声;演唱者为空的片段照样占位。
func TestMusixmatchLineOwners(t *testing.T) {
	keysOf := func(chars []speakerChar) (main, bg map[string]int) {
		main, bg = map[string]int{}, map[string]int{}
		for _, c := range chars {
			if c.bg {
				bg[c.key]++
			} else {
				main[c.key]++
			}
		}
		return
	}
	owners := musixmatchLineOwners([]string{"How are you (doing really fine today)"},
		[]musixmatchPerformerSpan{{text: "How are you", performers: []string{spkB}}, {text: " (doing really fine today)", performers: []string{spkA}}})
	main, bg := keysOf(owners[0])
	if main[spkB] != len("Howareyou") || bg[spkA] != len("doingreallyfinetoday") || speakerLineKey(owners[0]) != spkB {
		t.Errorf("和声字数再多,这一行也归括号外唱的那位: main=%v bg=%v key=%q", main, bg, speakerLineKey(owners[0]))
	}
	owners = musixmatchLineOwners([]string{"la la la", "la la la", "x y"},
		[]musixmatchPerformerSpan{{text: "la la la"}, {text: "la la la", performers: []string{spkB}}, {text: "not here", performers: []string{spkA}}})
	if speakerLineKey(owners[0]) != "" || speakerLineKey(owners[1]) != spkB || speakerLineKey(owners[2]) != "" {
		t.Errorf("顺序定位不对: %q %q %q", speakerLineKey(owners[0]), speakerLineKey(owners[1]), speakerLineKey(owners[2]))
	}
	owners = musixmatchLineOwners([]string{"together now"}, []musixmatchPerformerSpan{{text: "together now", performers: []string{spkB, spkA, spkA}}})
	if got := speakerLineKey(owners[0]); got != spkA+"+"+spkB {
		t.Errorf("多人的组 key = %q", got)
	}
}

func TestSpeakersFromScored(t *testing.T) {
	winnerLRC := "[ti:Song]\n[00:00.50]作词 : Someone\n" + spkLRC(20000, spkLines...)
	wantLRC := []string{"", "", "v1", "v1", "v1", "v1", "v2", "v2", "合", "合", ""}
	yrc := spkYRC(spkLines...)
	wantYRC := []string{"v1", "v1", "v1", "v1", "v2", "v2", "合", "合", ""}
	split := append(append(append([]string{}, spkLines[:4]...), "Every time", "I close my eyes"), spkLines[5:]...)
	other := []string{"我走在空荡荡的路上", "想着你说过的话", "每一盏灯都在暗下去", "我还在脑海里听见你", "闭上眼睛的时候", spkLines[0], spkLines[4]}
	var credits []string
	for _, role := range []string{"作词", "作曲", "编曲", "制作人", "吉他", "贝斯", "鼓", "和声", "混音", "母带"} {
		credits = append(credits, role+" : Someone")
	}

	sp := speakersFromScored(winnerLRC, yrc, []scoredLyricCandidateResult{{Source: "qq", Score: 1100, Lyrics: winnerLRC}, spkMx(spkSpans)})
	if sp == nil || !reflect.DeepEqual(sp.LRC, wantLRC) || !reflect.DeepEqual(sp.YRC, wantYRC) || sp.For != lyricSpeakersFingerprint(winnerLRC, yrc) {
		t.Fatalf("整行对得上: %+v", sp)
	}

	splitLRC := spkLRC(20000, split...)
	if sp := speakersFromScored(splitLRC, "", []scoredLyricCandidateResult{spkMx(spkSpans)}); sp == nil ||
		!reflect.DeepEqual(sp.LRC, []string{"v1", "v1", "v1", "v1", "v2", "v2", "v2", "合", "合", ""}) || sp.YRC != nil {
		t.Errorf("断行不同的两半都该标上: %+v", sp)
	}

	labeled := spkLRC(20000, append([]string{"男：" + spkLines[0], "女：" + spkLines[1], "男：" + spkLines[2]}, spkLines[3:]...)...)
	five := []musixmatchPerformerSpan{
		{text: spkLines[0], performers: []string{"mxm:artist:1"}}, {text: spkLines[1], performers: []string{"mxm:artist:2"}},
		{text: spkLines[2], performers: []string{"mxm:artist:3"}}, {text: spkLines[3], performers: []string{"mxm:artist:4"}},
		{text: strings.Join(spkLines[4:], "\n"), performers: []string{"mxm:artist:5"}},
	}
	four := append(append([]musixmatchPerformerSpan{}, five[:3]...), musixmatchPerformerSpan{text: strings.Join(spkLines[3:], "\n"), performers: []string{"mxm:artist:4"}})
	rejected := spkMx(spkSpans)
	rejected.Score = -1
	for _, c := range []struct {
		name   string
		lyrics string
		mx     scoredLyricCandidateResult
		want   bool
	}{
		{"正文自带演唱者标记", labeled, spkMx(spkSpans), false},
		{"Musixmatch 没过身份关", winnerLRC, rejected, false},
		{"只有一位演唱者", winnerLRC, spkMx([]musixmatchPerformerSpan{{text: strings.Join(spkLines, "\n"), performers: []string{spkA}}}), false},
		{"五位演唱者", winnerLRC, spkMx(five), false},
		{"四位演唱者", winnerLRC, spkMx(four), true},
		{"对得上的行不到一半", spkLRC(20000, other...), spkMx(spkSpans), false},
		{"署名行不算进覆盖率", spkLRC(0, append(credits, spkLines...)...), spkMx(spkSpans), true},
		{"没有标注", winnerLRC, spkMx(nil), false},
	} {
		if got := speakersFromScored(c.lyrics, "", []scoredLyricCandidateResult{c.mx}) != nil; got != c.want {
			t.Errorf("%s: 有标注 = %v, want %v", c.name, got, c.want)
		}
	}
	if sp := speakersFromScored(winnerLRC, spkYRC(other...), []scoredLyricCandidateResult{spkMx(spkSpans)}); sp == nil || sp.LRC == nil || sp.YRC != nil {
		t.Errorf("逐字那份对不上时只标整行那份: %+v", sp)
	}
}

// 整行对齐不看括号里的和声:一个源写了和声、另一个没写,也算同一行。
func TestSpeakerAlignKey(t *testing.T) {
	if a, b := speakerAlignKey("Can you feel it? (I can feel it)"), speakerAlignKey("can you FEEL it"); a != b || a == "" {
		t.Errorf("%q != %q", a, b)
	}
}

// 逐字对齐那一步:对上的字太少的行不认归属。
func TestSpeakersFromScoredWeakGapLine(t *testing.T) {
	lines := append(append(append([]string{}, spkLines[:4]...), "Every zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"), spkLines[5:]...)
	sp := speakersFromScored(spkLRC(20000, lines...), "", []scoredLyricCandidateResult{spkMx(spkSpans)})
	if sp == nil || sp.LRC[4] != "" || sp.LRC[5] != "v2" {
		t.Fatalf("对上的字不到四成的那一行不该标: %+v", sp)
	}
}

// 这一轮算得出就换新的;算不出时,旧的还对得上当前正文就留着,对不上就清掉。
func TestRefreshedSpeakers(t *testing.T) {
	lrc := spkLRC(20000, spkLines...)
	old := &lyricSpeakers{For: lyricSpeakersFingerprint(lrc, ""), LRC: []string{"v2"}}
	if got := refreshedSpeakers(old, lrc, "", []scoredLyricCandidateResult{spkMx(spkSpans)}); got == nil || got == old || got.LRC[0] != "v1" {
		t.Errorf("算得出该换新的: %+v", got)
	}
	if got := refreshedSpeakers(old, lrc, "", nil); got != old {
		t.Errorf("Musixmatch 没应答时旧的该留着: %+v", got)
	}
	if got := refreshedSpeakers(old, lrc+"[01:00.00]more\n", "", nil); got != nil {
		t.Errorf("正文换了,旧的该清掉: %+v", got)
	}
}

// 首次解析:胜者是别的源时也标上;标注绑在胜者那份正文上。
func TestLyricsEntryFromScoredSpeakers(t *testing.T) {
	setFeatureForTest(t, func(f *featureFlags) { f.LyricsSources = map[string]bool{"qq": true, "musixmatch": true} })
	winner := spkLRC(20000, spkLines...)
	e, picked := lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "A & B", "Song", "", 60, neteaseInfo{},
		[]scoredLyricCandidateResult{{Source: "qq", Score: 1100, Lyrics: winner}, spkMx(spkSpans)}, nil, nil, false, "")
	if picked == nil || picked.Source != "qq" || e.LyricsSpeakers == nil || e.LyricsSpeakers.For != lyricSpeakersFingerprint(winner, "") {
		t.Fatalf("picked=%v speakers=%+v", picked, e.LyricsSpeakers)
	}
}

// 从别的条目整份搬正文时,标注跟着搬(它绑的就是这份正文)。
func TestAdoptedLyricsCarrySpeakers(t *testing.T) {
	sp := &lyricSpeakers{For: "x", LRC: []string{"v1"}}
	var e enrichEntry
	if !adoptBackfilledLyrics(&e, enrichEntry{Lyrics: "[00:01.00]a", LyricsSpeakers: sp, LyricsSpeakersChecked: lyricsSpeakersVersion}) ||
		e.LyricsSpeakers != sp || e.LyricsSpeakersChecked != lyricsSpeakersVersion {
		t.Errorf("补外围字段收下歌词时没带上标注: %+v checked=%d", e.LyricsSpeakers, e.LyricsSpeakersChecked)
	}
	enrichCache = map[string]enrichEntry{
		"A|Song|Original": {DurationSecs: 200.0, Lyrics: "[00:01.00]low", LyricsSource: "kugou", LyricsScore: 1100},
		"A|Song|Deluxe": {DurationSecs: 200.3, Lyrics: "[00:01.00]high", LyricsSource: "netease", LyricsScore: 1300, LyricsSpeakers: sp,
			LyricsSpeakersChecked: lyricsSpeakersVersion},
	}
	e = enrichCache["A|Song|Original"]
	if !adoptCrossAlbumSiblingLyrics("A|Song|Original", &e) || e.LyricsSpeakers != sp || e.LyricsSpeakersChecked != lyricsSpeakersVersion {
		t.Errorf("跨专辑复用没带上标注: %+v checked=%d", e.LyricsSpeakers, e.LyricsSpeakersChecked)
	}
}

// 标注留在索引里(不进正文小文件);候选的标注不进 search-lyrics 的输出。
func TestLyricSpeakersSerialization(t *testing.T) {
	e := leanForIndex(enrichEntry{Lyrics: "[00:01.00]a", LyricsYRC: "[1000,500](1000,500,0)a", LyricsSpeakers: &lyricSpeakers{For: "abc", LRC: []string{"v1"}}}, 7)
	b, _ := json.Marshal(e)
	if !strings.Contains(string(b), `"lyrics_speakers":{"for":"abc","lrc":["v1"]}`) {
		t.Errorf("索引里没有标注: %s", b)
	}
	c, _ := json.Marshal(scoredLyricCandidateResult{Source: "musixmatch", Performers: spkSpans})
	if strings.Contains(string(c), "walk along") || strings.Contains(strings.ToLower(string(c)), "performer") {
		t.Errorf("候选输出带上了标注: %s", c)
	}
}

// 升级重试、重选、重同步写完正文之后都要刷新标注。
func TestLyricSpeakersRefreshIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	const refresh = "\trefreshSpeakers(&e, scored)\n"
	if n := strings.Count(src, refresh); n != 2 {
		t.Errorf("enrich.go 里升级重试和重选两处该刷新标注,找到 %d 处", n)
	}
	for rest := src; strings.Contains(rest, refresh); {
		rest = rest[strings.Index(rest, refresh)+len(refresh):]
		end := strings.Index(rest, "\n}\n")
		if end < 0 || !strings.Contains(rest[:end], "\tenrichCache[key] = e\n") {
			t.Error("刷新标注之后、同一个函数里要把条目写回 enrichCache")
		}
	}
	r, err := os.ReadFile("resynclyricscli.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(r), "cur = applyResync(cur, picked, plan, songLanguage, preparedRoma)\n\t\trefreshSpeakers(&cur, scored)\n") {
		t.Error("resynclyricscli.go 缺刷新标注")
	}
}
