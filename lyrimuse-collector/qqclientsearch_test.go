package main

import (
	"encoding/json"
	"testing"
)

// realQQClientSearchBody 是 2026-09-02 从 client_search_cp 实际抓下来的响应(new_json=1,
// n=3,查询词 "Have Gun, Will Travel Gravity Blues"),只裁掉了本文件用不到的字段。
// 用真实响应而不是手搓 JSON:这个测试的头号目标就是守住 struct tag——mid/title/
// interval/singer[].name/album.name 任何一个写错,下游身份闸会整片静默失效,而那种失效
// 从外面看跟"QQ 没收录这首歌"一模一样(正是 smartbox 时代那个坑的形态)。
const realQQClientSearchBody = `{
 "code": 0,
 "data": {"song": {"list": [
  {"mid":"000ODthF4LlIAx","title":"Gravity Blues","interval":235,
   "singer":[{"name":"Have Gun"},{"name":"Will Travel"}],"album":{"name":"Voyager Golden EP"}},
  {"mid":"001Y5o1g4bpc1f","title":"Gravity Blues","interval":241,
   "singer":[{"name":"Geese"}],"album":{"name":"3D Country (Explicit)"}},
  {"mid":"000HR2ax3bcNu2","title":"Gravity Blues","interval":246,
   "singer":[{"name":"Walay"}],"album":{"name":"Gravity Blues"}}
 ]}}
}`

func decodeRealQQSearch(t *testing.T) []qqSearchItem {
	t.Helper()
	var resp qqClientSearchResp
	if err := json.Unmarshal([]byte(realQQClientSearchBody), &resp); err != nil {
		t.Fatalf("解析实抓响应失败: %v", err)
	}
	return qqClientSearchItems(resp)
}

func TestQQClientSearchItemsDecodesRealResponse(t *testing.T) {
	got := decodeRealQQSearch(t)
	want := []qqSearchItem{
		{Mid: "000ODthF4LlIAx", Name: "Gravity Blues", Singer: "Have Gun/Will Travel", Album: "Voyager Golden EP", Interval: 235},
		{Mid: "001Y5o1g4bpc1f", Name: "Gravity Blues", Singer: "Geese", Album: "3D Country (Explicit)", Interval: 241},
		{Mid: "000HR2ax3bcNu2", Name: "Gravity Blues", Singer: "Walay", Album: "Gravity Blues", Interval: 246},
	}
	if len(got) != len(want) {
		t.Fatalf("条目数 = %d, want %d (%+v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("第 %d 条 = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// TestQQClientSearchItemsJoinsCollabWithSlash 守住"多个 singer 用 / 拼"这个选择。
// client_search_cp 的 singer 是数组,而下游三道身份闸(artistMatches /
// lyricSourceArtistMatches / looseContains)吃的是一个字符串,靠 isArtistCreditSep 切段。
// "/" 是它认识的分隔符,也正是 smartbox 对合唱本来就返回的形态("UMI/V")——换成空格拼
// 会把两段塌成一段,身份闸当场失配,所以这里连"拼完还过不过得了闸"一起断言,不只是比字符串。
func TestQQClientSearchItemsJoinsCollabWithSlash(t *testing.T) {
	var resp qqClientSearchResp
	body := `{"data":{"song":{"list":[
	 {"mid":"002YjLbV1VxwFi","title":"wherever u r (ft. V of BTS)","interval":153,
	  "singer":[{"name":"UMI"},{"name":"V"}],"album":{"name":"wherever u r (ft. V of BTS)"}}]}}}`
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	got := qqClientSearchItems(resp)
	if len(got) != 1 {
		t.Fatalf("条目数 = %d, want 1", len(got))
	}
	if got[0].Singer != "UMI/V" {
		t.Fatalf("合唱署名 = %q, want %q", got[0].Singer, "UMI/V")
	}
	// 乐队名本身带逗号的那一类(本次排查的 Have Gun, Will Travel):QQ 把它拆成两个 singer
	// 条目返回,拼回 "Have Gun/Will Travel" 之后必须仍能跟本地标签 "Have Gun, Will Travel"
	// 对上——这是本次改动能不能真正救回这类歌的前提。
	if !qqArtistOK(true, "Have Gun/Will Travel", "Have Gun, Will Travel") {
		t.Error("strict 身份闸拒了 Have Gun/Will Travel vs Have Gun, Will Travel")
	}
	if qqArtistOK(true, "Have Gun Will Travel", "Have Gun, Will Travel") {
		t.Error("用空格拼本该失配(段数塌成 1),这个断言若失效说明分隔符选择不再被守住")
	}
}

func TestQQClientSearchItemsSkipsUnusableRows(t *testing.T) {
	var resp qqClientSearchResp
	body := `{"data":{"song":{"list":[
	 {"mid":"","title":"没有 mid 的行","interval":100,"singer":[{"name":"X"}],"album":{"name":"A"}},
	 {"mid":"okmid","title":"正常","interval":0,"singer":[{"name":"  "},{"name":"Y"}],"album":{"name":""}}]}}}`
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	got := qqClientSearchItems(resp)
	if len(got) != 1 {
		t.Fatalf("条目数 = %d, want 1(没有 mid 的行该被丢掉): %+v", len(got), got)
	}
	if got[0].Mid != "okmid" || got[0].Singer != "Y" {
		t.Errorf("got %+v, want mid=okmid singer=Y(空白歌手名不该拼进去、也不该留下空段)", got[0])
	}
	if got[0].Album != "" || got[0].Interval != 0 {
		t.Errorf("缺字段该留零值,got album=%q interval=%v", got[0].Album, got[0].Interval)
	}
}

// TestQQSearchItemsFromSmartboxLeavesAlbumAndIntervalZero:smartbox 兜底路线拿不到
// 专辑名/时长,必须留零值——零值是给下游的信号("这条路线没给,该查还得自己查",见
// resolveQQMusicMatch 里 candAlbum 那段)。填上假值会让 albumScore 拿错的专辑打分。
func TestQQSearchItemsFromSmartboxLeavesAlbumAndIntervalZero(t *testing.T) {
	got := qqSearchItemsFromSmartbox([]qqSmartboxItem{
		{Mid: "m1", Name: "稻香", Singer: "周杰伦"},
	})
	if len(got) != 1 {
		t.Fatalf("条目数 = %d, want 1", len(got))
	}
	want := qqSearchItem{Mid: "m1", Name: "稻香", Singer: "周杰伦"}
	if got[0] != want {
		t.Errorf("got %+v, want %+v", got[0], want)
	}
}

// TestQQCollectCandidatesCarriesAlbumAndInterval 是这次改动的核心透传断言:搜索结果
// 自带的专辑名/时长要一路带到候选上。它们分别喂给 albumScore / versionTagsMismatch 和
// sourceDurationMismatchPenalty——半路掉了不会报错,只会让打分少两个信号,静默劣化。
func TestQQCollectCandidatesCarriesAlbumAndInterval(t *testing.T) {
	items := decodeRealQQSearch(t)
	got := qqCollectCandidates(items, "Have Gun, Will Travel", "Gravity Blues", true)
	if len(got) != 1 {
		t.Fatalf("strict 档候选数 = %d, want 1(另两条是同名不同歌手,该被身份闸拦掉): %+v", len(got), got)
	}
	c := got[0]
	if c.mid != "000ODthF4LlIAx" {
		t.Errorf("mid = %q, want 000ODthF4LlIAx", c.mid)
	}
	if c.album != "Voyager Golden EP" {
		t.Errorf("album = %q, want Voyager Golden EP(专辑名没透传下来)", c.album)
	}
	if c.interval != 235 {
		t.Errorf("interval = %v, want 235(时长没透传下来)", c.interval)
	}
	if !c.exact {
		t.Error("曲名与本地标题完全相同,exact 该为 true")
	}
}

// TestQQCollectCandidatesArtistGateFilters:身份闸真的在起作用,不是照单全收。同一份
// 搜索结果换个歌手名,应当挑出另一条;歌手完全不相干时 strict 档应当一条都不留。
func TestQQCollectCandidatesArtistGateFilters(t *testing.T) {
	items := decodeRealQQSearch(t)

	geese := qqCollectCandidates(items, "Geese", "Gravity Blues", true)
	if len(geese) != 1 || geese[0].mid != "001Y5o1g4bpc1f" {
		t.Fatalf("Geese 档 = %+v, want 唯一一条 001Y5o1g4bpc1f", geese)
	}
	if geese[0].album != "3D Country (Explicit)" {
		t.Errorf("Geese 候选 album = %q", geese[0].album)
	}

	if got := qqCollectCandidates(items, "周杰伦", "Gravity Blues", true); len(got) != 0 {
		t.Errorf("完全不相干的歌手 strict 档该 0 条,got %+v", got)
	}
}

// TestQQCollectCandidatesTitleGateFilters:标题闸也要真的在起作用——搜索接口的召回比
// smartbox 宽得多(一次回 10 条相关曲目),标题闸是挡住"同歌手另一首歌"的那道门。
func TestQQCollectCandidatesTitleGateFilters(t *testing.T) {
	items := decodeRealQQSearch(t)
	if got := qqCollectCandidates(items, "Have Gun, Will Travel", "Mission to Nowhere", true); len(got) != 0 {
		t.Errorf("标题对不上时该 0 条,got %+v", got)
	}
}

// TestQQCollectCandidatesSkipsEmptyMid:mid 为空的条目拿不到歌词/链接,不该进候选。
func TestQQCollectCandidatesSkipsEmptyMid(t *testing.T) {
	items := []qqSearchItem{
		{Mid: "", Name: "Gravity Blues", Singer: "Have Gun/Will Travel", Album: "Voyager Golden EP", Interval: 235},
		{Mid: "good", Name: "Gravity Blues", Singer: "Have Gun/Will Travel", Album: "Voyager Golden EP", Interval: 235},
	}
	got := qqCollectCandidates(items, "Have Gun, Will Travel", "Gravity Blues", true)
	if len(got) != 1 || got[0].mid != "good" {
		t.Errorf("got %+v, want 只剩 mid=good", got)
	}
}

// TestQQCandAlbumNamePrefersInline:搜索结果自带专辑名时**不该**再打一次详情请求。
// fetch 里直接 t.Fatal——回落被误触发时测试当场失败,不是靠比对返回值间接推断。
func TestQQCandAlbumNamePrefersInline(t *testing.T) {
	got := qqCandAlbumName("Voyager Golden EP", func() string {
		t.Fatal("自带了专辑名,不该再回落去查详情")
		return ""
	})
	if got != "Voyager Golden EP" {
		t.Errorf("got %q, want Voyager Golden EP", got)
	}
}

// TestQQCandAlbumNameFallsBackWhenEmpty:smartbox 兜底路线自带为空,必须回落去查,
// 不能把空专辑名喂给 albumScore(那会让所有候选的专辑分都是 0,专辑感知整体失效)。
func TestQQCandAlbumNameFallsBackWhenEmpty(t *testing.T) {
	calls := 0
	got := qqCandAlbumName("", func() string {
		calls++
		return "魔杰座"
	})
	if got != "魔杰座" || calls != 1 {
		t.Errorf("got %q (fetch 调用 %d 次), want 魔杰座 / 1 次", got, calls)
	}
}

// TestQQMatchFromCandCarriesAlbumAndInterval 守住三个出口共用的那一处装配:候选身上
// 的专辑名/时长必须原样进 qqMusicMatch。漏字段不会报错,只会静默少一个打分信号。
func TestQQMatchFromCandCarriesAlbumAndInterval(t *testing.T) {
	c := qqCand{mid: "000ODthF4LlIAx", title: "Gravity Blues", artist: "Have Gun/Will Travel",
		album: "Voyager Golden EP", interval: 235, exact: true}
	got := qqMatchFromCand(c, false)
	if got.album != "Voyager Golden EP" {
		t.Errorf("album = %q, want Voyager Golden EP", got.album)
	}
	if got.interval != 235 {
		t.Errorf("interval = %v, want 235", got.interval)
	}
	if got.title != "Gravity Blues" || got.artist != "Have Gun/Will Travel" {
		t.Errorf("title/artist 没带上: %+v", got)
	}
	if got.url != qqSongURL("000ODthF4LlIAx") {
		t.Errorf("url = %q, want %q", got.url, qqSongURL("000ODthF4LlIAx"))
	}
	if got.unreliable {
		t.Error("unreliable 该按入参走")
	}
	if !qqMatchFromCand(c, true).unreliable {
		t.Error("unreliable=true 没透传")
	}
}

// TestQQPickCandidatePrefersExact:标题精确同名的要赢过排在它前面的非精确条目——
// 搜索接口一次回 10 条,首条只是"相关度最高",不代表是规范版。
func TestQQPickCandidatePrefersExact(t *testing.T) {
	cands := []qqCand{
		{mid: "live", title: "Gravity Blues (Live)", exact: false},
		{mid: "studio", title: "Gravity Blues", exact: true},
	}
	got, ok := qqPickCandidate(cands, "周杰伦")
	if !ok || got.mid != "studio" {
		t.Fatalf("got %+v (ok=%v), want mid=studio", got, ok)
	}
}

func TestQQPickCandidateFallsBackToFirst(t *testing.T) {
	cands := []qqCand{{mid: "a", exact: false}, {mid: "b", exact: false}}
	got, ok := qqPickCandidate(cands, "周杰伦")
	if !ok || got.mid != "a" {
		t.Fatalf("got %+v (ok=%v), want mid=a", got, ok)
	}
	if _, ok := qqPickCandidate(nil, "周杰伦"); ok {
		t.Error("空候选该返回 ok=false")
	}
}

// TestQQSearchNeedsSmartboxSupplement 守住"什么时候值得多打一次 smartbox"这条判据。
// 背景见 qqSearchSongs 的 ② 段:两个索引互补,smartbox 的价值是补最规范的那条原版。
func TestQQSearchNeedsSmartboxSupplement(t *testing.T) {
	// PRINCE《Little Red Corvette》的真实形状:正式搜索 n 开到 30 也只有四个带限定词的
	// 版本,原版专辑《1999》那条一次都不出现——必须补 smartbox。
	prince := []qqSearchItem{
		{Mid: "a", Name: "Little Red Corvette (Explicit)", Album: "The Hits / The B-Sides (Explicit)"},
		{Mid: "b", Name: "Little Red Corvette (Single Version)", Album: "4Ever"},
		{Mid: "c", Name: "Little Red Corvette (2019 Remaster|Explicit)", Album: "1999 (Remastered) [Explicit]"},
		{Mid: "d", Name: "Little Red Corvette (Live Broadcast)", Album: "Live in Tokyo 1990 (Live Broadcast)"},
	}
	if !qqSearchNeedsSmartboxSupplement(prince, "Little Red Corvette") {
		t.Error("一条精确同名都没有,该补 smartbox")
	}
	// 有精确同名候选 → 省掉这次请求。
	if qqSearchNeedsSmartboxSupplement(append(prince,
		qqSearchItem{Mid: "e", Name: "Little Red Corvette", Album: "1999"}), "Little Red Corvette") {
		t.Error("已有精确同名候选,不该再补 smartbox")
	}
	// 正式接口空手而回(被反爬打死的降级路径)→ 必须补。
	if !qqSearchNeedsSmartboxSupplement(nil, "Little Red Corvette") {
		t.Error("正式接口一条都没回时必须补 smartbox,这是降级路径")
	}
	// 本地曲名为空 → 无从判断,保守地补。
	if !qqSearchNeedsSmartboxSupplement(prince, "") {
		t.Error("本地曲名为空时该保守地补")
	}
	// 精确同名的判定走 normLoose,大小写/空格差异不该逼出一次多余请求。
	if qqSearchNeedsSmartboxSupplement(
		[]qqSearchItem{{Mid: "x", Name: "little red  corvette"}}, "Little Red Corvette") {
		t.Error("normLoose 下已经同名,不该判为需要补")
	}
	// 带 (Live) 的本地曲名:候选里有一条同样带 (Live) 的精确同名 → 不补。
	// 这一档对应周杰伦《七里香 (Live)》——两个演唱会版本曲名都叫"七里香 (Live)",
	// 该由 albumScore 去分胜负,不该再多打一次 smartbox 把录音室版混进来。
	if qqSearchNeedsSmartboxSupplement(
		[]qqSearchItem{{Mid: "y", Name: "七里香 (Live)", Album: "周杰伦 2004 无与伦比 演唱会 Live CD"}},
		"七里香 (Live)") {
		t.Error("已有同名 (Live) 候选,不该补 smartbox")
	}
}

// TestQQCreditSetEqual:同一组人才算相等。它只做 tiebreak,不是准入闸——所以宁可严格。
func TestQQCreditSetEqual(t *testing.T) {
	cases := []struct {
		singer, artist string
		want           bool
	}{
		{"陶喆", "陶喆", true},
		{"陶喆/卢广仲", "陶喆", false},                                 // 合唱 vs 独唱:本次回归的形状
		{"陶喆", "陶喆/卢广仲", false},                                 // 反向同理
		{"陶喆/卢广仲", "卢广仲/陶喆", true},                              // 顺序无关
		{"Have Gun/Will Travel", "Have Gun, Will Travel", true}, // 分隔符差异不算不同
		{"UMI/V", "UMI/V", true},
		{"UMI/V", "UMI & 金泰亨", false}, // 跨平台译名不同 → 不给这档加分,也不该误判为相等
		{"", "陶喆", false},
		{"陶喆", "", false},
	}
	for _, c := range cases {
		if got := qqCreditSetEqual(c.singer, c.artist); got != c.want {
			t.Errorf("qqCreditSetEqual(%q, %q) = %v, want %v", c.singer, c.artist, got, c.want)
		}
	}
}

// TestQQPickCandidatePrefersExactCreditOnTie:标题、专辑都打平时,署名恰好同一组人的
// 那条要赢。对应陶喆《逗阵兄弟 (独唱版)》——独唱与合唱同名同专辑,只能靠署名区分,
// 靠"谁排在前面"是不可靠的(见 qqCreditSetEqual 头注)。
func TestQQPickCandidatePrefersExactCreditOnTie(t *testing.T) {
	// 合唱版排在前面,独唱版排在后面:仍应选中独唱版。
	cands := []qqCand{
		{mid: "duet", title: "逗阵兄弟", artist: "陶喆/卢广仲", album: "再见你好吗", interval: 306},
		{mid: "solo", title: "逗阵兄弟", artist: "陶喆", album: "再见你好吗", interval: 335},
	}
	got, ok := qqPickCandidate(cands, "陶喆")
	if !ok || got.mid != "solo" {
		t.Fatalf("got %+v, want mid=solo(署名恰好同一组人)", got)
	}
	// 本地就是合唱时,反过来选合唱那条。
	got, ok = qqPickCandidate(cands, "陶喆/卢广仲")
	if !ok || got.mid != "duet" {
		t.Fatalf("got %+v, want mid=duet", got)
	}
}

// TestQQPickCandidateExactTitleBeatsCredit:署名这一档只是 tiebreak,不能翻过
// "标题精确同名"那一档——否则纯音乐/伴奏/串烧这些同署名的变体会靠署名分上位。
func TestQQPickCandidateExactTitleBeatsCredit(t *testing.T) {
	cands := []qqCand{
		{mid: "instrumental", title: "逗阵兄弟 (消音伴奏)", artist: "陶喆", exact: false},
		{mid: "real", title: "逗阵兄弟", artist: "陶喆/卢广仲", exact: true},
	}
	got, ok := qqPickCandidate(cands, "陶喆")
	if !ok || got.mid != "real" {
		t.Fatalf("got %+v, want mid=real(标题精确同名优先于署名 tiebreak)", got)
	}
}
