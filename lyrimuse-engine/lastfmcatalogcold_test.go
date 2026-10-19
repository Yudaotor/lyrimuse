package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// 编目匹配不许把收听挪到比原样更冷的条目上(colderThan),以及名字去重不折繁简(lastfmCatalogNameKey)。
// 都是真实数据里坐实的改写:Zico《SPOT!》、Fish Leong《Man Leng》、周杰伦《太陽之子》。

// Zico《SPOT!》:原样 345,859 听众、编目时长跟播放器差 26 秒被时长闸挡下;MB 别名「지코」名下那条没有 mbid、
// 只有 2,269 听众 —— 比原样冷,不挪过去。
func TestCatalogExtColderAliasEntryNotChosenOverBlockedOwn(t *testing.T) {
	const artist, track = "Zico", "SPOT!"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: namedTrackJSON("ZICO", track, "", 345859, 167000)},
		infoKey("지코", track):   {body: namedTrackJSON("지코", track, "", 2269, 0)},
	})
	stubAliases(t, map[string][]string{"Zico": {"지코"}})
	a, tr, matched := col.resolve(context.Background(), artist, track, 193, scopeAll)
	if a != artist || tr != track || matched {
		t.Fatalf("resolve = %q / %q matched=%v, want 原样 Zico / SPOT!", a, tr, matched)
	}
}

// 原样的编目时长跟播放器对不上时,没有编目时长、听众更多的候选照样能胜出:原样那条的时长不一定可信。
// 方大同《Gotta Make A Change (15 Khalil Live in HK 2011)》原样那条 1 个听众,Last.fm 记的 215 s 是录音室版的长度;
// 「Khalil Fong」名下 94 听众、没有时长的那条才是这份现场录音大家在用的条目(兜底档)。有 mbid 的同理(第 1 档)。
func TestCatalogExtDurationMismatchedOwnDoesNotBlockUndatedCandidate(t *testing.T) {
	cases := []struct {
		name, artist, alias, track, aliasTrack, mbid string
		own, aliasListeners, ownMS                   int
		dur                                          float64
		via                                          string
	}{
		{"兜底档", "方大同", "Khalil Fong", "Gotta Make A Change (15 Khalil Live in HK 2011)",
			"Gotta Make A Change - 15 Khalil Live in HK 2011", "", 1, 94, 215000, 290, "name+fallback"},
		{"第 1 档", "Zico", "지코", "SPOT!", "SPOT!", "mb-z", 600, 2269, 167000, 193, "name"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			col, _ := newCatalogServer(t, map[string]probeResp{
				infoKey(c.artist, c.track): {body: namedTrackJSON(c.artist, c.track, "", c.own, c.ownMS)},
				infoKey(c.alias, c.track):  {body: namedTrackJSON(c.alias, c.aliasTrack, c.mbid, c.aliasListeners, 0)},
			})
			stubAliases(t, map[string][]string{c.artist: {c.alias}})
			a, tr, matched := col.resolve(context.Background(), c.artist, c.track, c.dur, scopeAll)
			if a != c.alias || tr != c.aliasTrack || !matched {
				t.Fatalf("resolve = %q / %q matched=%v, want %s / %s", a, tr, matched, c.alias, c.aliasTrack)
			}
			if d := decisionOf(col, c.artist, c.track); d.Via != c.via {
				t.Errorf("via = %q, want %q", d.Via, c.via)
			}
		})
	}
}

// 没有 mbid、听众比原样少的条目,有编目时长也不选:Fish Leong《Man Leng》原样 335 听众,MB 别名「梁靜茹」名下
// 那条只有 1 个听众。有 mbid 的照选(冷门的正规条目)。
func TestCatalogExtColderEntryWithoutMBIDNotChosen(t *testing.T) {
	const artist, track = "Fish Leong", "Man Leng"
	cases := []struct {
		name string
		mbid string
		want string
	}{
		{"无 mbid 不选", "", artist},
		{"有 mbid 照选", "mb-f", "梁靜茹"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			col, _ := newCatalogServer(t, map[string]probeResp{
				infoKey(artist, track): {body: namedTrackJSON(artist, track, "", 335, 0)},
				infoKey("梁靜茹", track):  {body: namedTrackJSON("梁靜茹", track, c.mbid, 1, 290000)},
			})
			stubAliases(t, map[string][]string{artist: {"梁靜茹"}})
			if a, _, _ := col.resolve(context.Background(), artist, track, 290, scopeAll); a != c.want {
				t.Errorf("resolve = %q, want %q", a, c.want)
			}
		})
	}
}

// 基础判定同一条规矩:第一位歌手名下那条只有编目时长、听众比原样少,不选。
func TestCatalogBaseColderEntryWithoutMBIDNotChosen(t *testing.T) {
	const artist, track = "A & B", "T"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 300, 0)},
		infoKey("A", track):    {body: trackJSON("", 5, 200000)},
		infoKey("B", track):    {body: notFoundJSON},
	})
	if a, _, matched := col.resolve(context.Background(), artist, track, 200, scopeAll); a != artist || matched {
		t.Fatalf("resolve = %q matched=%v, want 原样 A & B", a, matched)
	}
}

// 名字去重不折繁简:原样「周杰伦」,Apple 区服对照给的「周杰倫」在 Last.fm 是另一个歌手页,名下有 mbid 的正规条目。
// 按折繁简的键去重会把它当成原样丢掉,结果兜底到 32 听众的「ジェイ・チョウ」。
func TestCatalogExtQueriesOtherHanScriptOfArtist(t *testing.T) {
	const artist, track = "周杰伦", "太陽之子"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):    {body: namedTrackJSON(artist, track, "", 4, 0)},
		infoKey("ジェイ・チョウ", track): {body: namedTrackJSON("ジェイ・チョウ", track, "", 32, 0)},
		infoKey("周杰倫", track):     {body: namedTrackJSON("周杰倫", track, "mb-j", 1051, 297000)},
	})
	stubAliases(t, map[string][]string{artist: {"ジェイ・チョウ"}})
	stubCatalogNameSources(t, catalogNameSources{appleTitle: map[string][]string{artist + "\n" + track: {"周杰倫"}}})
	a, tr, matched := col.resolve(context.Background(), artist, track, 297, scopeAll)
	if a != "周杰倫" || tr != track || !matched {
		t.Fatalf("resolve = %q / %q matched=%v, want 周杰倫 / 太陽之子", a, tr, matched)
	}
	if d := decisionOf(col, artist, track); d.Via != "name" {
		t.Errorf("via = %q, want name", d.Via)
	}
}

// 只差繁简的名字是同一个人的另一种字形:从弱身份那一路(歌词署名)来也按强身份算,不要求两边都有时长。
func TestCatalogExtOtherHanScriptIsStrongIdentity(t *testing.T) {
	const artist, track = "周杰伦", "太陽之子"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: namedTrackJSON(artist, track, "", 4, 0)},
		infoKey("周杰倫", track):  {body: namedTrackJSON("周杰倫", track, "mb-j", 1051, 297000)},
	})
	stubCatalogNameSources(t, catalogNameSources{lyrics: map[string][]string{artist + "\n" + track: {"周杰倫"}}})
	if a, _, matched := col.resolve(context.Background(), artist, track, 0, scopeAll); a != "周杰倫" || !matched {
		t.Fatalf("resolve = %q matched=%v, want 周杰倫", a, matched)
	}
}

// Apple 区服对照留下只差繁简的写法,另算名额,不挤掉换名的那两个。
func TestPickAppleLinkedNamesKeepsOtherHanScript(t *testing.T) {
	results := []itunesResult{
		{TrackID: 1, ArtistName: "周杰伦"},
		{TrackID: 1, ArtistName: "Jay Chou"},
		{TrackID: 1, ArtistName: "ジェイ・チョウ"},
		{TrackID: 1, ArtistName: "周杰倫"},
		{TrackID: 9, ArtistName: "周杰倫 Band"},
	}
	want := []string{"Jay Chou", "ジェイ・チョウ", "周杰倫"}
	if got := pickAppleLinkedNames(results, "周杰伦"); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
	if got := pickAppleLinkedNames(results[:2], "周杰伦"); !reflect.DeepEqual(got, []string{"Jay Chou"}) {
		t.Errorf("没有字形变体时只收换名的,got %v", got)
	}
}

func TestStorefrontArtistAliasesKeepOtherHanScript(t *testing.T) {
	appleStorefrontArtistMu.Lock()
	saved := appleStorefrontArtistCache
	appleStorefrontArtistCache = map[string][]string{
		normLoose("周杰伦") + "|" + normLoose("范特西"): {"周杰倫", "周杰伦"},
	}
	appleStorefrontArtistMu.Unlock()
	t.Cleanup(func() {
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache = saved
		appleStorefrontArtistMu.Unlock()
	})
	if got := storefrontArtistAliasesCached("周杰伦"); !reflect.DeepEqual(got, []string{"周杰倫"}) {
		t.Errorf("繁体写法该留下、原样本身去掉,got %v", got)
	}
}

func TestLastfmCatalogStaleMatch(t *testing.T) {
	probe := func(mbid string, listeners, dur int) *lastfmCatalogProbe {
		return &lastfmCatalogProbe{Found: true, MBID: mbid, Listeners: listeners, DurationMS: dur}
	}
	match := func(via string, ext int, own, chosen *lastfmCatalogProbe) lastfmCatalogDecision {
		return lastfmCatalogDecision{Verdict: verdictMatch, Via: via, Ext: ext, Own: own, Chosen: chosen}
	}
	cases := []struct {
		name string
		key  string
		d    lastfmCatalogDecision
		want bool
	}{
		{"冷条目(Fish Leong)", "Fish Leong\nMan Leng", match("name", 2, probe("", 335, 0), probe("", 1, 290000)), true},
		{"冷条目(Zico)", "Zico\nSPOT!", match("top", 1, probe("", 345859, 167000), probe("", 2269, 0)), true},
		{"冷条目也走基础判定", "A & B\nT", match("", 2, probe("", 300, 0), probe("", 5, 200000)), true},
		{"有 mbid 的冷门条目不算", "X\nT", match("name", 2, probe("", 335, 0), probe("mb", 1, 290000)), false},
		{"原样有时长、选中的没时长但听众更多不算", "方大同\nGotta Make A Change (15 Khalil Live in HK 2011)",
			match("search+fallback", 2, probe("", 1, 215000), probe("", 94, 0)), false},
		{"基础判定的没时长候选不算", "Lukas Graham\nHappy For You", match("", 2, probe("", 628, 200000), probe("", 30931, 0)), false},
		{"旧口径兜底、歌手名有繁简写法", "周杰伦\n太陽之子", match("name+fallback", 2, probe("", 4, 0), probe("", 32, 0)), true},
		{"新口径兜底不再删", "周杰伦\n太陽之子", match("name+fallback", 3, probe("", 4, 0), probe("", 32, 0)), false},
		{"旧口径兜底、歌手名没有繁简写法", "方大同\n公园 [Timeless Live 2009]", match("search+fallback", 2, probe("", 1, 0), probe("", 52, 0)), false},
		{"旧口径非兜底不删", "张震岳\n搬家", match("search", 2, probe("", 139, 0), probe("", 850, 0)), false},
		{"曲名尾巴那一路不比", "A\nT (Remastered)", match("tail", 2, probe("", 500, 0), probe("", 300, 0)), false},
		{"keep 不删", "A\nT", lastfmCatalogDecision{Verdict: verdictKeep, Own: probe("", 1, 0)}, false},
	}
	for _, c := range cases {
		if got := lastfmCatalogStaleMatch(c.key, c.d); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 迁移按水位只跑一次,只删认出的那几条,其余条目原样(含结构体里没有的字段)写回,并留一份备份。
func TestMigrateLastfmCatalogStaleMatches(t *testing.T) {
	savedState, savedStatePath, savedCatalog := migrationState, migrationStatePath, lastfmCatalogPath
	t.Cleanup(func() {
		migrationState, migrationStatePath, lastfmCatalogPath = savedState, savedStatePath, savedCatalog
	})
	dir := t.TempDir()
	loadMigrationState(filepath.Join(dir, "migrations.json"))
	lastfmCatalogPath = filepath.Join(dir, "catalog.json")
	original := `{"Fish Leong\nMan Leng":{"verdict":"match","artist":"梁靜茹","track":"Man Leng","v":2,"scope":"at","via":"name","ext":2,` +
		`"own":{"found":true,"listeners":335},"chosen":{"found":true,"listeners":1,"duration_ms":290000}},` +
		`"陶喆\n那个女孩":{"verdict":"match","artist":"陶喆","track":"那個女孩","v":2,"scope":"at","future":1,` +
		`"own":{"found":true,"listeners":126},"chosen":{"found":true,"listeners":889,"duration_ms":267000}}}`
	if err := os.WriteFile(lastfmCatalogPath, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}
	migrateLastfmCatalogStaleMatches()
	var got map[string]map[string]any
	data, err := os.ReadFile(lastfmCatalogPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if _, ok := got["Fish Leong\nMan Leng"]; ok {
		t.Error("冷条目那条该删掉")
	}
	if e, ok := got["陶喆\n那个女孩"]; !ok || e["future"] != float64(1) {
		t.Errorf("正常那条该原样留着(含未知字段),got %v", e)
	}
	if b, err := os.ReadFile(lastfmCatalogPath + ".bak-stale-matches"); err != nil || string(b) != original {
		t.Errorf("该留一份原文备份,err=%v", err)
	}
	if !migrationDone(migrationLastfmCatalogStale, migrationLastfmCatalogStaleVersion) {
		t.Error("跑完该记水位")
	}
	// 水位到了:再放进一条同类的也不动(运行期 decide 不会再判出这一类)。
	if err := os.WriteFile(lastfmCatalogPath, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}
	migrateLastfmCatalogStaleMatches()
	if data, _ := os.ReadFile(lastfmCatalogPath); string(data) != original {
		t.Error("水位到了不该再改缓存")
	}
}
