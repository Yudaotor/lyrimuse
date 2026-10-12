package main

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// songIncrementalSynthetic:回归案例集之外专门凑的几组:检索 id 的「一个 id 一种歌名」闸(多一条少一条整组的边都变)、被否决的
// 合并连着的两首、只靠歌词连着的两条、跨文字靠名字连着的两条。
func songIncrementalSynthetic() map[string]enrichEntry {
	ne := func(id string) string { return "https://music.163.com/song?id=" + id }
	return map[string]enrichEntry{
		"Gate|Hello|One":       {DurationSecs: 201, NeteaseURL: ne("901")},
		"Gate|Hello|Two":       {DurationSecs: 201.4, NeteaseURL: ne("901")},
		"Gate|Hallo|Three":     {DurationSecs: 201.2, NeteaseURL: ne("901")},
		"Veto|Song|Studio":     {DurationSecs: 180, ISRCs: []string{"USVVV1100001"}, Lyrics: songShareLRC("v1")},
		"Veto|Song (Live)|Hk":  {DurationSecs: 180.5, ISRCs: []string{"USVVV1100009"}, Lyrics: songShareLRC("v1")},
		"Veto|Song|Best":       {DurationSecs: 180.3, ISRCs: []string{"USVVV1100001"}},
		"Lyr|晴天|Album":         {DurationSecs: 269, Lyrics: songShareLRC("ly"), LyricsSource: "qq"},
		"Lyr|Sunny Day|Album":  {DurationSecs: 269.3, Lyrics: songShareLRC("ly"), LyricsSource: "netease"},
		"Solo|Alone|One":       {DurationSecs: 99},
		"Pair|Twin|A":          {DurationSecs: 150, SpotifyTrackID: "4uLU6hMCjMI75M1A2tKUQC"},
		"Pair|Twin|B":          {DurationSecs: 150.2, SpotifyTrackID: "4uLU6hMCjMI75M1A2tKUQC", Lyrics: songShareLRC("tw")},
		"Pair|Twin (Remix)|C":  {DurationSecs: 210, SpotifyTrackID: "5uLU6hMCjMI75M1A2tKUQD"},
		"Gate|Hello (Live)|Hk": {DurationSecs: 230, NeteaseURL: ne("902")},
	}
}

// songIncrementalSource:回归案例集全部写法加上面那几组,按案例里给的登记歌名、当前歌词候选歌名摘写法。
func songIncrementalSource(t *testing.T) *songEntitySource {
	t.Helper()
	cache := songIncrementalSynthetic()
	over := map[string]songGoldenVariant{}
	ids := map[string]mbArtistIdentity{}
	splits := map[string]bool{}
	pins := map[string]bool{}
	for _, f := range songGoldenLoadAll(t) {
		for _, fv := range f.Variants {
			var e enrichEntry
			if err := json.Unmarshal(fv.Entry, &e); err != nil {
				t.Fatal(err)
			}
			cache[fv.Key] = e
			over[fv.Key] = fv
			pins[fv.Key] = fv.Pinned
		}
		for name, mbid := range f.Identities {
			ids[name] = mbArtistIdentity{Mbid: mbid}
		}
		for _, s := range f.Splits {
			splits[songPairKey(s[0], s[1])] = true
		}
	}
	artistIdentityMu.Lock()
	saved := artistIdentityCache
	artistIdentityCache = ids
	artistIdentityMu.Unlock()
	t.Cleanup(func() {
		artistIdentityMu.Lock()
		artistIdentityCache = saved
		artistIdentityMu.Unlock()
	})
	return &songEntitySource{cache: cache, pins: pins, splits: splits, prepare: func(vs []songVariant) {
		for i := range vs {
			base, _, _ := strings.Cut(vs[i].key, songIncrementalCopyMark)
			fv := over[base]
			vs[i].titlesDone, vs[i].registered, vs[i].winnerTitle = true, fv.Registered, fv.WinnerTitle
		}
	}}
}

// songIncrementalCopyMark:改动里「同一条录音多出一种写法」那种,新写法的专辑在原专辑后面接上它。
const songIncrementalCopyMark = " (Deluxe)"

type songIncrementalChange struct {
	name  string
	apply func(cache map[string]enrichEntry, k, other string)
}

var songIncrementalChanges = []songIncrementalChange{
	{"删掉", func(c map[string]enrichEntry, k, _ string) { delete(c, k) }},
	{"时长没了", func(c map[string]enrichEntry, k, _ string) { e := c[k]; e.DurationSecs = 0; c[k] = e }},
	{"时长多 3 秒", func(c map[string]enrichEntry, k, _ string) { e := c[k]; e.DurationSecs += 3; c[k] = e }},
	{"ISRC 没了", func(c map[string]enrichEntry, k, _ string) { e := c[k]; e.ISRCs, e.ISRCLevels = nil, nil; c[k] = e }},
	{"歌词没了", func(c map[string]enrichEntry, k, _ string) { e := c[k]; e.Lyrics, e.LyricsYRC = "", ""; c[k] = e }},
	{"检索链接没了", func(c map[string]enrichEntry, k, _ string) {
		e := c[k]
		e.NeteaseURL, e.AppleURL, e.QQURL = "", "", ""
		c[k] = e
	}},
	{"多出一种写法", func(c map[string]enrichEntry, k, _ string) {
		e := c[k]
		e.Song, e.SongShare = "", 0
		c[k+songIncrementalCopyMark] = e
	}},
	{"拿了另一条的 ISRC 和时长", func(c map[string]enrichEntry, k, o string) {
		e, f := c[k], c[o]
		e.ISRCs, e.ISRCLevels, e.DurationSecs = f.ISRCs, f.ISRCLevels, f.DurationSecs
		c[k] = e
	}},
	{"拿了另一条的检索链接", func(c map[string]enrichEntry, k, o string) {
		e, f := c[k], c[o]
		e.NeteaseURL, e.AppleURL, e.QQURL = f.NeteaseURL, f.AppleURL, f.QQURL
		c[k] = e
	}},
	{"拿了另一条的 Spotify id", func(c map[string]enrichEntry, k, o string) {
		e := c[k]
		e.SpotifyTrackID = c[o].SpotifyTrackID
		c[k] = e
	}},
}

// 每条写法逐种改一遍(再加上跟下一条一起改),增量重算出的实体表跟按改完的数据全量建的逐条写法一样;不该退回全量建表。
func TestSongEntityIncrementalMatchesFull(t *testing.T) {
	src := songIncrementalSource(t)
	now := time.Unix(1_800_000_000, 0)
	_, _, base := buildSongEntityState(src, nil, now)
	keys := songSortedKeys(src.cache)
	runs := 0
	for i, k := range keys {
		other := keys[(i+len(keys)/2)%len(keys)]
		next := keys[(i+1)%len(keys)]
		for ci, c := range songIncrementalChanges {
			cache := maps.Clone(src.cache)
			c.apply(cache, k, other)
			if ci%3 == 0 {
				songIncrementalChanges[(ci+4)%len(songIncrementalChanges)].apply(cache, next, k)
			}
			changed := *src
			changed.cache = cache
			st := base.clone()
			up, err := st.update(&changed, now)
			if err != nil {
				t.Fatalf("%s %s: 退回全量建表: %v", k, c.name, err)
			}
			_, want, _ := buildSongEntityState(&changed, nil, now)
			if diff := songEntityTableDiff(st.table, want); len(diff) > 0 {
				t.Fatalf("%s %s: 增量跟全量不一样的写法 %v", k, c.name, diff)
			}
			if up != nil {
				runs++
				for _, v := range up.build.variants {
					if _, ok := cache[v.key]; !ok {
						t.Fatalf("%s %s: 重算的那一块里有已经没了的写法 %s", k, c.name, v.key)
					}
				}
			}
			// 再算一次:没有新改动,不重算。
			if again, err := st.update(&changed, now); again != nil || err != nil {
				t.Fatalf("%s %s: 没有改动还重算了: %v", k, c.name, err)
			}
		}
	}
	if runs < len(keys)*len(songIncrementalChanges)/2 {
		t.Errorf("大部分改动应当真的重算: %d 次", runs)
	}
}

// 增量重算只动受影响的那一块:改一条单独成首的写法,不碰别的歌;实体 id 延续,别的歌的 id 不变。
func TestSongEntityIncrementalTouchesOnlyItsBlock(t *testing.T) {
	src := songIncrementalSource(t)
	now := time.Unix(1_800_000_000, 0)
	_, table, st := buildSongEntityState(src, nil, now)
	cache := maps.Clone(src.cache)
	e := cache["Solo|Alone|One"]
	e.DurationSecs = 100
	cache["Solo|Alone|One"] = e
	changed := *src
	changed.cache = cache
	up, err := st.update(&changed, now)
	if err != nil || up == nil {
		t.Fatalf("应当重算: %v", err)
	}
	if got := len(up.build.variants); got != 1 {
		t.Errorf("只重算这一条: %d 条", got)
	}
	for id, rec := range table.Songs {
		if got, ok := up.table.Songs[id]; !ok || !slices.Equal(got.Variants, rec.Variants) {
			t.Errorf("实体 %s 的 id 或写法变了: %v → %v", id, rec.Variants, got.Variants)
		}
	}
}

// 留下的写法跟扔掉的写法之间有证据边时,restrict 不给结果。
func TestSongEntityRestrictRefusesEdgesLeavingTheBlock(t *testing.T) {
	vs := []songVariant{
		songTestVariant("A|Song|One", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("A|Song|Two", enrichEntry{DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("B|Tune|One", enrichEntry{DurationSecs: 100}, nil),
	}
	b := buildSongEntities(vs, nil, "")
	if _, ok := b.restrict(func(i int) bool { return i == 0 }); ok {
		t.Error("同一首拆在两边不该给结果")
	}
	r, ok := b.restrict(func(i int) bool { return i < 2 })
	if !ok || !r.partial || len(r.variants) != 2 || len(r.clusters) != 1 || len(r.edges) != len(b.edges) {
		t.Fatalf("整首留下: ok=%v %+v", ok, r)
	}
}

// 指纹覆盖建表读的全部条目字段:songVariantOf、songVariantIDs 里读的 e.X,songEntityPrintOf 里都要有。
func TestSongEntityPrintCoversVariantFields(t *testing.T) {
	read := func(file string, funcs ...string) map[string]bool {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]bool{}
		for _, fn := range funcs {
			body := string(src)
			i := strings.Index(body, "func "+fn+"(")
			if i < 0 {
				// 方法:func (v *songVariant) fn(
				if loc := regexp.MustCompile(`func \([^)]*\) ` + fn + `\(`).FindStringIndex(body); loc != nil {
					i = loc[0]
				}
			}
			if i < 0 {
				t.Fatalf("找不到 %s", fn)
			}
			body = body[i:]
			if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
				body = body[:j+1]
			}
			for _, m := range regexp.MustCompile(`\be\.([A-Z]\w*)`).FindAllStringSubmatch(body, -1) {
				out[m[1]] = true
			}
		}
		return out
	}
	used := read("songentityvariant.go", "songVariantOf", "songVariantIDs", "setEvidenceLyrics", "songOwnLyricsEntry")
	printed := read("songentityincremental.go", "songEntityPrintOf")
	if len(used) < 10 {
		t.Fatalf("没扫到字段: %v", used)
	}
	for f := range used {
		if !printed[f] {
			t.Errorf("songEntityPrintOf 漏了 %s", f)
		}
	}
	a := songEntityPrintOf(enrichEntry{Lyrics: "x"}, false)
	for _, b := range []songEntityPrint{songEntityPrintOf(enrichEntry{Lyrics: "y"}, false), songEntityPrintOf(enrichEntry{Lyrics: "x"}, true),
		songEntityPrintOf(enrichEntry{Lyrics: "x", LyricsDecision: &lyricsDecision{DecidedAt: 1}}, false)} {
		if a == b {
			t.Errorf("正文、校准、解析决策变了指纹要变: %+v", b)
		}
	}
	if songEntityPrintOf(enrichEntry{Lyrics: "x", Players: []string{"p"}, Song: "s_1"}, false) != a {
		t.Error("建表不读的字段不进指纹")
	}
}

// 常驻循环:第一次全量建表之后,缓存落盘几秒就增量重算,新写法认进同一首、写回 song,不等每天那一次。
func TestSongEntityUpdatesAfterCacheSave(t *testing.T) {
	dir := setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}},
	}, false)
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	saved := songEntityUpdateDelay
	t.Cleanup(func() { songEntityUpdateDelay = saved })
	songEntityUpdateDelay = 10 * time.Millisecond
	if rebuildSongEntityTable(time.Now()) == nil {
		t.Fatal("建表失败")
	}
	select {
	case <-songEntityCacheSaved:
	default:
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { startSongEntityShadow(ctx); close(done) }()
	defer func() { cancel(); <-done }()
	commitEnrichEntrySince("A|Song|Two", enrichEntry{DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}}, enrichEditNoStamp)
	saveEnrichCache()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		one, _ := cacheEntry(t, "A|Song|One")
		two, _ := cacheEntry(t, "A|Song|Two")
		// 先把 song 写回条目、落盘,再写实体表(决策 8):看到 song 之后实体表可能还差一拍,接着等。
		if two.Song != "" && two.Song == one.Song {
			if tbl := readSongEntityTable(songEntityTablePath()); tbl != nil && len(tbl.Songs[one.Song].Variants) == 2 {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("落盘之后没有增量重算(或实体表没跟上)")
}

// 增量重算的那一块跑同步时,不在这一块里的组的同步状态留着。
func TestSongEntitySharePassPartialKeepsOtherGroups(t *testing.T) {
	entries := map[string]enrichEntry{
		"A|Song|One": {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}, Lyrics: songShareLRC("a1"), LyricsSource: "qq"},
		"A|Song|Two": {DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}, Lyrics: songShareLRC("a1"), LyricsSource: "qq"},
	}
	setUpSongShareTest(t, entries, true)
	savedSearch, savedWait := searchShareRound, songShareWait
	t.Cleanup(func() { searchShareRound, songShareWait = savedSearch, savedWait })
	songShareWait = func(context.Context, time.Duration) {}
	searchShareRound = func(_ context.Context, key, artist, title, album string, dur float64) songShareRound {
		return songShareRound{shareEvalRound: shareEvalRound{Key: key, Artist: artist, Title: title, Album: album, Duration: dur}, reached: true}
	}
	b := rebuildSongEntityTable(time.Now())
	if b == nil {
		t.Fatal("建表失败")
	}
	st := readSongShareState(songShareStatePath())
	st.FullBackup = "x"
	st.Groups["other"] = songShareGroupState{}
	if err := writeSongShareState(songShareStatePath(), st); err != nil {
		t.Fatal(err)
	}
	part, ok := b.restrict(func(int) bool { return false })
	if !ok {
		t.Fatal("restrict")
	}
	runSongEntitySharePass(context.Background(), part)
	if _, ok := readSongShareState(songShareStatePath()).Groups["other"]; !ok {
		t.Error("只算了一块时别的组不清")
	}
	runSongEntitySharePass(context.Background(), b)
	if _, ok := readSongShareState(songShareStatePath()).Groups["other"]; ok {
		t.Error("全量那一轮清掉不在了的组")
	}
}

// 几种只靠一般改动扫不到的情形,各凑一组:改之前、改之后各全量建一次,确认这一改真的让结果变了,再比增量跟全量。
func TestSongEntityIncrementalScenarios(t *testing.T) {
	ne := func(id string) string { return "https://music.163.com/song?id=" + id }
	lyrics := songTestLRC(0, songTestWords("sunny", 14))
	type scenario struct {
		name    string
		entries map[string]enrichEntry
		splits  [][2]string
		names   map[string][]songCatalogName
		change  func(c map[string]enrichEntry)
		// same:这一改不改变结果,要验的是增量那一块收得对。
		same bool
	}
	for _, sc := range []scenario{{
		// 新拿到的检索 id 让整组过不了「一个 id 一种歌名」:组里原来那两条之间的检索 id 边没了,它们跟改动之间没有边。
		name: "加入检索 id 组让整组的边失效",
		entries: map[string]enrichEntry{
			"Flip|Hello|One":   {DurationSecs: 201, NeteaseURL: ne("903")},
			"Flip|Hello|Two":   {DurationSecs: 201.3, NeteaseURL: ne("903")},
			"Flip|Hallo|Three": {DurationSecs: 201.1, NeteaseURL: ne("904")},
		},
		change: func(c map[string]enrichEntry) {
			e := c["Flip|Hallo|Three"]
			e.NeteaseURL = ne("903")
			c["Flip|Hallo|Three"] = e
		},
	}, {
		// 块里两条同一个检索 id,同组还有一条在块外、歌名不同:单拿块里的建表会多出一条检索 id 边。
		name: "块外同组的写法",
		entries: map[string]enrichEntry{
			"Ctx|Song|A": {DurationSecs: 200, ISRCs: []string{"USCCC1100001"}, NeteaseURL: ne("905")},
			"Ctx|Song|B": {DurationSecs: 200.2, ISRCs: []string{"USCCC1100001"}, NeteaseURL: ne("905")},
			"Ctx|Sang|C": {DurationSecs: 200.1, NeteaseURL: ne("905")},
			"Ctx|Song|D": {DurationSecs: 200.3},
		},
		splits: [][2]string{{"Ctx|Song|A", "Ctx|Song|D"}},
		change: func(c map[string]enrichEntry) { e := c["Ctx|Song|D"]; e.DurationSecs = 200.4; c["Ctx|Song|D"] = e },
		same:   true,
	}, {
		// 名字边:改动是 x(写法族跟 y 的目录名字一样),y 的主歌手跟 x 不同,只能按目录名字找到。
		name: "目录名字连上",
		entries: map[string]enrichEntry{
			"Name|晴天|Y":            {},
			"Name Eng|Sunny Day|X": {DurationSecs: 269.4},
		},
		names: map[string][]songCatalogName{"Name Eng|Sunny Day|X": {{name: "晴天", artist: "Name", kind: songEvidenceAppleName, id: "1"}}},
		change: func(c map[string]enrichEntry) {
			e := c["Name|晴天|Y"]
			e.DurationSecs = 269.2
			c["Name|晴天|Y"] = e
		},
	}, {
		// 时长 + 歌词边:两条写法族不同、没有 id,只能按主歌手找到。
		name: "歌词连上",
		entries: map[string]enrichEntry{
			"Lyr|晴天|A":        {Lyrics: lyrics, LyricsSource: "qq"},
			"Lyr|Sunny Day|B": {DurationSecs: 269.3, Lyrics: lyrics, LyricsSource: "netease"},
		},
		change: func(c map[string]enrichEntry) { e := c["Lyr|晴天|A"]; e.DurationSecs = 269.3; c["Lyr|晴天|A"] = e },
	}} {
		t.Run(sc.name, func(t *testing.T) {
			splits := map[string]bool{}
			for _, s := range sc.splits {
				splits[songPairKey(s[0], s[1])] = true
			}
			src := &songEntitySource{cache: sc.entries, splits: splits, prepare: func(vs []songVariant) {
				for i := range vs {
					vs[i].titlesDone = true
					for _, n := range sc.names[vs[i].key] {
						vs[i].addCatalogName(n)
					}
				}
			}}
			now := time.Unix(1_800_000_000, 0)
			_, before, st := buildSongEntityState(src, nil, now)
			changed := *src
			changed.cache = maps.Clone(src.cache)
			sc.change(changed.cache)
			_, want, _ := buildSongEntityState(&changed, nil, now)
			if changedResult := len(songEntityTableDiff(before, want)) > 0; changedResult == sc.same {
				t.Fatalf("这一改让全量建表的结果变了吗:%v,情形没凑对", changedResult)
			}
			if _, err := st.update(&changed, now); err != nil {
				t.Fatal(err)
			}
			if diff := songEntityTableDiff(st.table, want); len(diff) > 0 {
				t.Errorf("增量跟全量不一样的写法 %v", diff)
			}
		})
	}
}
