package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// 扩展搜索(lastfmcatalogext.go)的回归测试。跟 lastfmcatalog_test.go 同一条纪律:这套逻辑
// 决定的是写进 Last.fm 的内容,每一条「什么情况下不改写」都要单独钉死。

// stubAliases 把 MusicBrainz 别名来源换成固定表(nil = 谁都没有别名),测试结束还原。
func stubAliases(t *testing.T, table map[string][]string) {
	t.Helper()
	saved := catalogArtistAliases
	catalogArtistAliases = func(_ context.Context, name string) ([]string, error) {
		return table[strings.TrimSpace(name)], nil
	}
	t.Cleanup(func() { catalogArtistAliases = saved })
}

// namedTrackJSON 是带条目自身写法的 track.getInfo 应答(autocorrect 之后的歌手名 / 曲名)。
func namedTrackJSON(artist, name, mbid string, listeners, durationMS int) string {
	return fmt.Sprintf(`{"track":{"name":%q,"mbid":%q,"listeners":"%d","duration":"%d","artist":{"name":%q}}}`,
		name, mbid, listeners, durationMS, artist)
}

// searchJSON 拼一份 track.search 应答。入参按"歌手, 曲名, 听众"三个一组给。
func searchJSON(artistTrackListeners ...any) string {
	var rows []string
	for i := 0; i+2 < len(artistTrackListeners); i += 3 {
		rows = append(rows, fmt.Sprintf(`{"name":%q,"artist":%q,"mbid":"","listeners":"%d"}`,
			artistTrackListeners[i+1], artistTrackListeners[i], artistTrackListeners[i+2]))
	}
	return `{"results":{"trackmatches":{"track":[` + strings.Join(rows, ",") + `]}}}`
}

func decisionOf(col *lastfmCatalogMatcher, artist, track string) lastfmCatalogDecision {
	col.mu.Lock()
	defer col.mu.Unlock()
	return col.cache[artist+"\n"+track]
}

// 本坑的原型:播放器报「鹤 The Crane」,编目条目在英文名「The Crane」下(1110 听众、编目时长 157 s)。
// 双语名拆出来的一半是弱身份:时长两边都有且对得上才认。
func TestCatalogExtBilingualHalfMatches(t *testing.T) {
	const artist, track = "鹤 The Crane", "客客氣氣 COURTESY"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):      {body: notFoundJSON},
		infoKey("鹤", track):         {body: notFoundJSON},
		infoKey("The Crane", track): {body: namedTrackJSON("The Crane", track, "", 1110, 157000)},
	})
	a, tr, matched := col.resolve(context.Background(), artist, track, 157.4, scopeAll)
	if a != "The Crane" || tr != track || !matched {
		t.Fatalf("resolve = %q / %q matched=%v, want The Crane / %s", a, tr, matched, track)
	}
	if d := decisionOf(col, artist, track); d.Verdict != verdictMatch || d.Via != "name" {
		t.Errorf("decision = %+v", d)
	}
}

// 弱身份的时长门槛:播放器没报时长时,双语名的另一半就算编目条目很像样也不认 ——
// 同名的另一个艺人恰好有一首同名歌,靠的就是时长来排除。
func TestCatalogExtBilingualHalfNeedsDuration(t *testing.T) {
	const artist, track = "鹤 The Crane", "客客氣氣 COURTESY"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):      {body: notFoundJSON},
		infoKey("鹤", track):         {body: notFoundJSON},
		infoKey("The Crane", track): {body: namedTrackJSON("The Crane", track, "", 1110, 157000)},
	})
	if a, _, matched := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist || matched {
		t.Errorf("播放器没报时长,弱身份候选不该被采纳;got %q matched=%v", a, matched)
	}
}

// 弱身份时长对不上(另一个同名艺人的同名歌)不认。
func TestCatalogExtBilingualHalfDurationMismatch(t *testing.T) {
	const artist, track = "鹤 The Crane", "Courtesy"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):      {body: notFoundJSON},
		infoKey("鹤", track):         {body: notFoundJSON},
		infoKey("The Crane", track): {body: namedTrackJSON("The Crane", track, "mb-x", 50000, 240000)}, // 另一首,4 分钟
	})
	if a, _, _ := col.resolve(context.Background(), artist, track, 157, scopeAll); a != artist {
		t.Errorf("时长差 83 s 的同名歌不该被当成这首,got %q", a)
	}
}

// 弱身份只有编目时长、听众不够也没 mbid:不认(weakCandidateOK 要求正规身份够硬)。
func TestCatalogExtBilingualHalfNeedsStrongCatalogIdentity(t *testing.T) {
	const artist, track = "鹤 The Crane", "客客氣氣 COURTESY"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):      {body: notFoundJSON},
		infoKey("鹤", track):         {body: notFoundJSON},
		infoKey("The Crane", track): {body: namedTrackJSON("The Crane", track, "", 40, 157000)},
	})
	if a, _, _ := col.resolve(context.Background(), artist, track, 157, scopeAll); a != artist {
		t.Errorf("弱身份候选只有 40 听众、无 mbid,不该被采纳,got %q", a)
	}
}

// MusicBrainz 别名是强身份:丁世光 在 MB 登记的英文名 Dean Ting 名下有这首歌的正规条目。
func TestCatalogExtMusicBrainzAliasMatches(t *testing.T) {
	const artist, track = "丁世光", "瘦子（ Skinny Love ）"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):      {body: trackJSON("", 307, 0)},
		infoKey("Dean Ting", track): {body: namedTrackJSON("Dean Ting", track, "", 1013, 0)},
	})
	stubAliases(t, map[string][]string{"丁世光": {"Dean Ting"}})
	if a, _, matched := col.resolve(context.Background(), artist, track, 0, scopeAll); a != "Dean Ting" || !matched {
		t.Errorf("resolve = %q matched=%v, want Dean Ting", a, matched)
	}
}

// track.search 只收歌手对得上的结果:繁体歌手名(張惠妹)折叠后等于原样(张惠妹)→ 收;
// 同名不同歌手(别人唱的《就是我想你》,听众更多)一律不收。
func TestCatalogExtSearchRequiresArtistIdentity(t *testing.T) {
	const artist, track = "张惠妹", "就是我想你"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 424, 0)},
		searchKey(track): {body: searchJSON(
			"别的歌手", "就是我想你", 90000,
			"張惠妹", "就是我想你", 617,
		)},
		infoKey("張惠妹", track): {body: trackJSON("", 617, 0)},
	})
	a, _, matched := col.resolve(context.Background(), artist, track, 0, scopeAll)
	if a != "張惠妹" || !matched {
		t.Fatalf("resolve = %q matched=%v, want 張惠妹", a, matched)
	}
	if d := decisionOf(col, artist, track); d.Via != "search" {
		t.Errorf("via = %q, want search", d.Via)
	}
}

// track.search 结果里只有同名不同歌手的:一条都不收,维持原样。这是基础判定头注里
// 「张泽熙 / 那个女孩」那一类 —— 扩展搜索放开 track.search 的前提就是这道过滤。
func TestCatalogExtSearchIgnoresOtherArtists(t *testing.T) {
	const artist, track = "陶喆", "那个女孩"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: shadowJSON},
		searchKey(track): {body: searchJSON(
			"张泽熙", "那个女孩", 50000,
			"宝石gem", "那个女孩", 30000,
		)},
	})
	if a, _, matched := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist || matched {
		t.Errorf("同名不同歌手的结果不该被采纳,got %q matched=%v", a, matched)
	}
}

// 曲名折叠键保留版本标记:Live 版不能被搜到的录音室版顶掉。
func TestCatalogExtKeepsVersionMarkers(t *testing.T) {
	const artist, track = "周传雄", "冬天的秘密 (Live)"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 10, 0)},
		infoKey("小刚", track):   {body: notFoundJSON},
		searchKey(track):       {body: searchJSON("周传雄", "冬天的秘密", 1674)},
	})
	stubAliases(t, map[string][]string{"周传雄": {"小刚"}})
	if a, tr, _ := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist || tr != track {
		t.Errorf("Live 版不该被改写成录音室版,got %q / %q", a, tr)
	}
}

// 兜底档:编目里没有正规条目时,在强身份候选里挑明显人多的那条(卢广仲 → 盧廣仲 繁体那条)。
func TestCatalogExtFallbackPicksDeFactoEntry(t *testing.T) {
	const artist, track = "卢广仲", "一百种生活"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):  {body: trackJSON("", 45, 0)},
		searchKey(track):        {body: searchJSON("盧廣仲", "一百種生活", 416, "卢广仲", "100种生活", 879)},
		infoKey("盧廣仲", "一百種生活"): {body: trackJSON("", 416, 0)},
	})
	a, tr, matched := col.resolve(context.Background(), artist, track, 0, scopeAll)
	if a != "盧廣仲" || tr != "一百種生活" || !matched {
		t.Fatalf("resolve = %q / %q matched=%v, want 盧廣仲 / 一百種生活", a, tr, matched)
	}
	if d := decisionOf(col, artist, track); d.Via != "search+fallback" {
		t.Errorf("via = %q", d.Via)
	}
}

// 兜底档门槛:候选没比原样多出一倍就不挪(几十个听众之间的差别说明不了谁是"大家在用的那条")。
func TestCatalogExtFallbackNeedsClearMajority(t *testing.T) {
	const artist, track = "卢广仲", "一百种生活"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 300, 0)},
		searchKey(track):       {body: searchJSON("盧廣仲", "一百種生活", 416)},
	})
	if a, _, _ := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist {
		t.Errorf("416 < 2×300,不该挪,got %q", a)
	}
}

// 兜底档门槛:原样查不到时,候选也得有 lastfmCatalogFallbackMinListeners 个听众 ——
// 一两个人用过的写法多半是手打错的。
func TestCatalogExtFallbackNeedsMinimumListeners(t *testing.T) {
	const artist, track = "张三", "某歌"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: notFoundJSON},
		searchKey(track):       {body: searchJSON("張三", "某歌", 3)},
	})
	if a, _, _ := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist {
		t.Errorf("3 个听众的写法不该当成事实条目,got %q", a)
	}
}

// 兜底档不收弱身份:双语名另一半名下的影子条目不认。
func TestCatalogExtFallbackIgnoresWeakIdentity(t *testing.T) {
	const artist, track = "夏天Alex", "沦陷"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 2, 0)},
		infoKey("夏天", track):   {body: notFoundJSON},
		infoKey("Alex", track): {body: namedTrackJSON("Alex", track, "", 300, 0)}, // 另一个叫 Alex 的人
	})
	if a, _, _ := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist {
		t.Errorf("弱身份的影子条目不该进兜底档,got %q", a)
	}
}

// 基础判定能判 keep / match 的,扩展搜索一个请求都不发 —— 已有正规条目的歌手不许被
// MB 别名名下「听众更多」挪走。
func TestCatalogExtNotUsedWhenBaseDecides(t *testing.T) {
	const artist, track = "方大同", "春风吹"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 800, 0)},
	})
	called := false
	saved := catalogArtistAliases
	catalogArtistAliases = func(context.Context, string) ([]string, error) {
		called = true
		return []string{"Khalil Fong"}, nil
	}
	t.Cleanup(func() { catalogArtistAliases = saved })
	if a, _, _ := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist {
		t.Fatalf("基础判定应 keep,got %q", a)
	}
	if called || cs.count(searchKey(track)) != 0 || cs.count(infoKey("Khalil Fong", track)) != 0 {
		t.Error("基础判定已经得出结论,扩展搜索不该跑")
	}
}

// MB 别名没查成:整次判定当作没查成,不落盘(残缺的候选集判出的 defer 可能漏掉真正的条目)。
func TestCatalogExtAliasFailureNotCached(t *testing.T) {
	const artist, track = "丁世光", "一口"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 47, 0)},
	})
	saved := catalogArtistAliases
	catalogArtistAliases = func(context.Context, string) ([]string, error) { return nil, errMBLookupBackoff }
	t.Cleanup(func() { catalogArtistAliases = saved })
	if a, _, _ := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist {
		t.Errorf("没查成应维持原样,got %q", a)
	}
	if _, ok := col.cache[artist+"\n"+track]; ok {
		t.Error("别名没查成时不该落盘")
	}
}

// track.search 没查成同理。
func TestCatalogExtSearchFailureNotCached(t *testing.T) {
	const artist, track = "某人", "某歌"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: notFoundJSON},
		searchKey(track):       {status: 500, body: `{}`},
	})
	col.resolve(context.Background(), artist, track, 0, scopeAll)
	if _, ok := col.cache[artist+"\n"+track]; ok {
		t.Error("track.search 没查成时不该落盘")
	}
}

// 「自定义·只改曲名」:别的歌手名下的条目一条都不收;歌手折叠后相等(繁简)的仍可采纳。
func TestCatalogExtRespectsTrackOnlyScope(t *testing.T) {
	const artist, track = "张惠妹", "就是我想你"
	trackOnly := matchScope{track: true}
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 10, 0)},
		searchKey(track):       {body: searchJSON("A-Mei", "就是我想你", 5000, "張惠妹", "就是我想你", 617)},
		infoKey("張惠妹", track):  {body: trackJSON("", 617, 0)},
	})
	called := false
	saved := catalogArtistAliases
	catalogArtistAliases = func(context.Context, string) ([]string, error) {
		called = true
		return []string{"A-Mei"}, nil
	}
	t.Cleanup(func() { catalogArtistAliases = saved })
	if a, _, _ := col.resolve(context.Background(), artist, track, 0, trackOnly); a != "張惠妹" {
		t.Errorf("只改曲名时应采纳歌手折叠相等的 張惠妹,got %q", a)
	}
	if called {
		t.Error("不许改歌手时不该去查别名")
	}
}

// 「自定义·只改歌手」:曲名折叠不等的候选不收(那是另一个曲名写法,不许动曲名)。
func TestCatalogExtRespectsArtistOnlyScope(t *testing.T) {
	const artist, track = "卢广仲", "一百种生活"
	artistOnly := matchScope{artist: true}
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):  {body: trackJSON("", 45, 0)},
		searchKey(track):        {body: searchJSON("卢广仲", "100种生活", 879, "盧廣仲", "一百種生活", 416)},
		infoKey("盧廣仲", "一百種生活"): {body: trackJSON("", 416, 0)},
	})
	a, tr, _ := col.resolve(context.Background(), artist, track, 0, artistOnly)
	if tr == "100种生活" {
		t.Fatalf("曲名折叠不等的候选不该被采纳,got %q / %q", a, tr)
	}
}

// 旧口径下判的 defer(没有 Ext)要重判一次;新口径下判的 defer 在窗口内不重查。
func TestCatalogExtRechecksLegacyDefer(t *testing.T) {
	const artist, track = "鹤 The Crane", "客客氣氣 COURTESY"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):      {body: notFoundJSON},
		infoKey("鹤", track):         {body: notFoundJSON},
		infoKey("The Crane", track): {body: namedTrackJSON("The Crane", track, "", 1110, 157000)},
	})
	col.cache[artist+"\n"+track] = lastfmCatalogDecision{
		Verdict: verdictDefer, Artist: artist, TS: time.Now().Unix(),
		V: lastfmCatalogDecisionVersion, Scope: scopeAll.id()}
	if a, _, _ := col.resolve(context.Background(), artist, track, 157, scopeAll); a != "The Crane" {
		t.Fatalf("旧口径 defer 应重判并改写,got %q", a)
	}
	if d := decisionOf(col, artist, track); d.Ext != lastfmCatalogExtVersion {
		t.Errorf("重判后应记下当前扩展口径,got Ext=%d", d.Ext)
	}
}

// keep / match 不因为没有 Ext 就重判 —— 已经发出去的写法不许变。
func TestCatalogExtLegacyKeepMatchStay(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{})
	col.cache["A\n歌"] = lastfmCatalogDecision{Verdict: verdictKeep, Artist: "A", TS: time.Now().Unix(),
		V: lastfmCatalogDecisionVersion, Scope: scopeAll.id()}
	col.cache["B\n歌"] = lastfmCatalogDecision{Verdict: verdictMatch, Artist: "B2", Track: "歌", TS: time.Now().Unix(),
		V: lastfmCatalogDecisionVersion, Scope: scopeAll.id()}
	if a, _, _ := col.resolve(context.Background(), "A", "歌", 0, scopeAll); a != "A" {
		t.Errorf("keep got %q", a)
	}
	if a, _, _ := col.resolve(context.Background(), "B", "歌", 0, scopeAll); a != "B2" {
		t.Errorf("match got %q", a)
	}
	if cs.total() != 0 {
		t.Errorf("keep / match 不该重查,却打了 %d 次", cs.total())
	}
}

func TestBilingualArtistHalves(t *testing.T) {
	cases := []struct {
		in, han, latin string
		ok             bool
	}{
		{"鹤 The Crane", "鹤", "The Crane", true},
		{"YELLOW黄宣", "黄宣", "YELLOW", true},
		{"CoCo李玟", "李玟", "CoCo", true},
		{"G.E.M.邓紫棋", "邓紫棋", "G.E.M.", true},
		{"五月天 Mayday", "五月天", "Mayday", true},
		{"陶喆", "", "", false},           // 只有中文
		{"The Crane", "", "", false},    // 只有英文
		{"9m88", "", "", false},         // 只有一段拉丁字母
		{"A吴B", "", "", false},          // 三段,说不清哪半是名字
		{"鹤 X", "", "", false},          // 拉丁那段只有一个字母
		{"杨丞琳 Rainie 杨", "", "", false}, // 三段
	}
	for _, c := range cases {
		han, latin, ok := bilingualArtistHalves(c.in)
		if ok != c.ok || han != c.han || latin != c.latin {
			t.Errorf("bilingualArtistHalves(%q) = %q, %q, %v; want %q, %q, %v", c.in, han, latin, ok, c.han, c.latin, c.ok)
		}
	}
}

func TestCatalogCreditNames(t *testing.T) {
	cases := map[string][]string{
		"HUSH, 孙盛希":          {"HUSH", "孙盛希"},
		"刘涛、蒋欣、王子文":          {"刘涛", "蒋欣", "王子文"},
		"Zion.T, Crush, 方大同": {"Zion.T", "Crush", "方大同"},
		"陶喆":                 nil,
		"AC/DC":              nil,
		"周杰伦、":               nil, // 切完只剩一段:不当合唱
	}
	for in, want := range cases {
		got := catalogCreditNames(in)
		if strings.Join(got, "|") != strings.Join(want, "|") {
			t.Errorf("catalogCreditNames(%q) = %q, want %q", in, got, want)
		}
	}
}

// Last.fm 不认识的歌手:artist.getTopTracks 回 error 6 + "could not be found"(实测措辞)。
// 这是确定的答案(这个名字下没有曲目),不是「没查成」—— 否则扩展搜索碰到任何一个 Last.fm
// 不认识的别名,整首歌就永远判不出结论。
func TestCatalogTopTracksUnknownArtistIsEmpty(t *testing.T) {
	const artist, track = "某人", "某歌"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: notFoundJSON},
		topKey(artist):         {body: `{"error":6,"message":"The artist you supplied could not be found","links":[]}`},
	})
	col.resolve(context.Background(), artist, track, 0, scopeAll)
	if d, ok := col.cache[artist+"\n"+track]; !ok || d.Verdict != verdictDefer {
		t.Errorf("歌手不在编目里应判 defer 并落盘,got %+v ok=%v", d, ok)
	}
}

// 按别名查到的条目被 autocorrect 归到了另一个写法(查 A-Mei Chang 回 張惠妹 那条):提交的是
// 那条条目自己的写法,不是查询串 —— 提交查询串能不能被同样纠正过去没有保证。
func TestCatalogExtSubmitsCorrectedSpelling(t *testing.T) {
	const artist, track = "张惠妹", "就是我想你"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):        {body: trackJSON("", 424, 0)},
		infoKey("A-Mei Chang", track): {body: namedTrackJSON("張惠妹", track, "mb-amei", 617, 252000)},
	})
	stubAliases(t, map[string][]string{"张惠妹": {"A-Mei Chang"}})
	a, tr, matched := col.resolve(context.Background(), artist, track, 253, scopeAll)
	if a != "張惠妹" || tr != track || !matched {
		t.Errorf("resolve = %q / %q matched=%v, want 張惠妹 / %s", a, tr, matched, track)
	}
}

// autocorrect 把曲名也换成了折叠键不同的另一个(比如纠到录音室版上):这条候选不收。
func TestCatalogExtRejectsCorrectionToOtherRecording(t *testing.T) {
	const artist, track = "张惠妹", "就是我想你 (Live)"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):        {body: trackJSON("", 10, 0)},
		infoKey("A-Mei Chang", track): {body: namedTrackJSON("張惠妹", "就是我想你", "mb-amei", 617, 252000)},
	})
	stubAliases(t, map[string][]string{"张惠妹": {"A-Mei Chang"}})
	if a, tr, _ := col.resolve(context.Background(), artist, track, 0, scopeAll); a != artist || tr != track {
		t.Errorf("纠正到录音室版的候选不该被采纳,got %q / %q", a, tr)
	}
}
