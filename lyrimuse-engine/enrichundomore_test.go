package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 歌词管理「保存修改」(含逐字只改字)、外部编辑器存回:手改走 save_edit(置人工修正)、存成纯文本走 save_plain_text,
// 带 undoable 时撤销后条目和整棵数据目录跟保存之前逐字节一致。
func TestUndoHandEditSave(t *testing.T) {
	plain := enrichKey("Hand", "Plain Song", "Album")
	words := enrichKey("Hand", "Word Song", "Album")
	text := enrichKey("Hand", "Text Song", "Album")
	root := setUpEnrichUndoTest(t, map[string]enrichEntry{
		plain: {TS: 100, Lyrics: bt("[00:01.00]原来一\n[00:02.00]原来二"), LyricsTr: bt("[00:01.00]tr"), LyricsTrLang: "en",
			LyricsSource: "qq", LyricsScore: 300, LyricsDecisionApplied: &lyricsDecision{Path: lyricsDecisionPathRescore, Winner: "qq"}},
		words: {TS: 100, Lyrics: bt("[00:01.00]逐字"), LyricsYRC: bt("[1000,800](1000,400,0)逐(1400,400,0)字"), LyricsSource: "netease"},
		text:  {TS: 100, Lyrics: bt("[00:01.00]有时间轴"), LyricsSource: "kugou"},
	}, false)
	cases := []struct {
		name string
		key  string
		req  enrichEditRequest
	}{
		{"保存修改", plain, enrichEditRequest{Op: "save_edit", Key: plain, Lyrics: "[00:01.00]改过一\n[00:02.00]原来二",
			Tr: "[00:01.00]tr", MarkManual: true, Undoable: true}},
		{"逐字只改字", words, enrichEditRequest{Op: "save_edit", Key: words, Lyrics: "[00:01.00]逐句",
			YRC: strPtr("[1000,800](1000,400,0)逐(1400,400,0)句"), MarkManual: true, Undoable: true}},
		{"外部编辑器存成纯文本", text, enrichEditRequest{Op: "save_plain_text", Key: text, PlainLyrics: "没有时间轴的", Undoable: true}},
	}
	for _, c := range cases {
		before, beforeJSON := undoTree(t, root), undoEntryJSON(t, c.key)
		res := applyEnrichEdit(c.req)
		if !res.OK || res.UndoID == "" {
			t.Fatalf("%s: %+v", c.name, res)
		}
		if undoEntryJSON(t, c.key) == beforeJSON {
			t.Fatalf("%s 没生效", c.name)
		}
		if r := undoEdit(res.UndoID); !r.OK {
			t.Fatalf("%s 撤销: %+v", c.name, r)
		}
		if got := undoEntryJSON(t, c.key); got != beforeJSON {
			t.Errorf("%s 条目:\n之前 %s\n之后 %s", c.name, beforeJSON, got)
		}
		diffUndoTree(t, c.name, before, undoTree(t, root))
	}

	// 保存之后又标了纯音乐:拒绝;过期:拒绝。都不改条目。
	res := applyEnrichEdit(cases[0].req)
	applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: plain, Value: true})
	after := undoEntryJSON(t, plain)
	if r := undoEdit(res.UndoID); r.OK || r.ErrorCode != enrichUndoErrChanged {
		t.Fatalf("保存之后又动过要拒绝: %+v", r)
	}
	if undoEntryJSON(t, plain) != after {
		t.Error("拒绝时不该改条目")
	}
	now := time.Unix(2_000_000, 0)
	enrichUndoNow = func() time.Time { return now }
	res = applyEnrichEdit(cases[1].req)
	now = now.Add(enrichUndoTTL + time.Second)
	if r := undoEdit(res.UndoID); r.OK || r.ErrorCode != enrichUndoErrExpired {
		t.Fatalf("过期要拒绝: %+v", r)
	}
}

// 「标为纯音乐」一次几首(多选「全部标为纯音乐」):一份记录、每首一条,撤销后几首和整棵目录都跟标之前一样;缓存里还没有的那首
// 本来就没标上,撤销不碰它。「取消纯音乐标记」同样能撤,连「用户说过不是纯音乐」那个记号一起放回。
func TestUndoSetInstrumentalBatch(t *testing.T) {
	a := enrichKey("Inst", "With Lyrics", "Album")
	b := enrichKey("Inst", "No Lyrics", "Album")
	c := enrichKey("Inst", "Already", "Album")
	missing := enrichKey("Inst", "Not Cached", "Album")
	root := setUpEnrichUndoTest(t, map[string]enrichEntry{
		a: {TS: 1, Lyrics: bt("[00:01.00]有词"), LyricsSource: "qq", InstrumentalCleared: true},
		b: {TS: 1, LyricsFillCount: 2},
		c: {TS: 1, Instrumental: true},
	}, false)
	before := undoTree(t, root)
	beforeJSON := map[string]string{a: undoEntryJSON(t, a), b: undoEntryJSON(t, b), c: undoEntryJSON(t, c)}
	res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Keys: []string{a, b, c, missing}, Value: true, Undoable: true})
	if !res.OK || res.UndoID == "" || res.Changed != 3 {
		t.Fatalf("标纯音乐: %+v", res)
	}
	if got, _ := cacheEntry(t, a); !got.Instrumental || got.InstrumentalCleared {
		t.Fatalf("a 应标上: %+v", got)
	}
	if r := undoEdit(res.UndoID); !r.OK {
		t.Fatalf("撤销: %+v", r)
	}
	for k, want := range beforeJSON {
		if got := undoEntryJSON(t, k); got != want {
			t.Errorf("%s 条目:\n之前 %s\n之后 %s", k, want, got)
		}
	}
	if _, ok := cacheEntry(t, missing); ok {
		t.Error("缓存里没有的那首撤销后也不该凭空出现")
	}
	diffUndoTree(t, "标纯音乐", before, undoTree(t, root))

	before, cJSON := undoTree(t, root), undoEntryJSON(t, c)
	res = applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: c, Value: false, Undoable: true})
	if got, _ := cacheEntry(t, c); !res.OK || got.Instrumental || !got.InstrumentalCleared {
		t.Fatalf("取消标记: %+v %+v", res, got)
	}
	if r := undoEdit(res.UndoID); !r.OK {
		t.Fatalf("撤销取消标记: %+v", r)
	}
	if got := undoEntryJSON(t, c); got != cJSON {
		t.Errorf("取消标记撤销后:\n之前 %s\n之后 %s", cJSON, got)
	}
	diffUndoTree(t, "取消标记", before, undoTree(t, root))

	if r := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: a, Value: true}); !r.OK || r.UndoID != "" {
		t.Errorf("不带 undoable 不发 undo_id: %+v", r)
	}
}

// 歌词同步开着时标一首纯音乐,同组写法跟着标;撤销一起放回。
func TestUndoSetInstrumentalShareGroup(t *testing.T) {
	const a, b, other = "X|UndoI|A", "X|UndoI|B", "X|UndoI|Other"
	root := setUpEnrichUndoTest(t, map[string]enrichEntry{
		a:     {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("a")), LyricsSource: "qq"},
		b:     {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("b")), LyricsSource: "kugou"},
		other: {Song: "s2", TS: 1, Lyrics: bt(songShareLRC("o")), LyricsSource: "qq"},
	}, true)
	before := undoTree(t, root)
	beforeJSON := map[string]string{a: undoEntryJSON(t, a), b: undoEntryJSON(t, b), other: undoEntryJSON(t, other)}
	res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: a, Value: true, Undoable: true})
	if got, _ := cacheEntry(t, b); !res.OK || !got.Instrumental {
		t.Fatalf("同组写法跟着标: %+v %+v", res, got)
	}
	if r := undoEdit(res.UndoID); !r.OK {
		t.Fatalf("撤销: %+v", r)
	}
	for k, want := range beforeJSON {
		if got := undoEntryJSON(t, k); got != want {
			t.Errorf("%s 条目:\n之前 %s\n之后 %s", k, want, got)
		}
	}
	diffUndoTree(t, "同组标纯音乐", before, undoTree(t, root))
}

// 一次标了几首,之后其中一首被动过(又取消了标记、存了手改、后台换了正文):整笔拒绝,几首一个字都不改。过期同样拒绝。
func TestUndoSetInstrumentalBatchRefusesWhenOneChanged(t *testing.T) {
	a := enrichKey("Batch", "One", "Album")
	b := enrichKey("Batch", "Two", "Album")
	setUpEnrichUndoTest(t, map[string]enrichEntry{
		a: {TS: 1, Lyrics: bt("[00:01.00]一"), LyricsSource: "qq"},
		b: {TS: 1, Lyrics: bt("[00:01.00]二"), LyricsSource: "qq"},
	}, false)
	mark := func() string {
		res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Keys: []string{a, b}, Value: true, Undoable: true})
		if !res.OK || res.UndoID == "" {
			t.Fatalf("标纯音乐: %+v", res)
		}
		return res.UndoID
	}
	refused := func(label, id string) {
		t.Helper()
		snapA, snapB := undoEntryJSON(t, a), undoEntryJSON(t, b)
		if r := undoEdit(id); r.OK || r.ErrorCode != enrichUndoErrChanged {
			t.Fatalf("%s 要整笔拒绝: %+v", label, r)
		}
		if undoEntryJSON(t, a) != snapA || undoEntryJSON(t, b) != snapB {
			t.Errorf("%s:拒绝时两首都不该动", label)
		}
	}

	id := mark()
	applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: b, Value: false})
	refused("其中一首又取消了标记", id)

	id = mark()
	applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: a, Lyrics: "[00:01.00]手改", MarkManual: true})
	refused("其中一首存了手改", id)

	id = mark()
	enrichMu.Lock()
	e := enrichCache[b]
	e.Lyrics = bt("[00:01.00]后台换的")
	enrichCache[b] = e
	enrichMu.Unlock()
	refused("其中一首后台换了正文", id)

	now := time.Unix(3_000_000, 0)
	enrichUndoNow = func() time.Time { return now }
	id = mark()
	now = now.Add(enrichUndoTTL + time.Second)
	if r := undoEdit(id); r.OK || r.ErrorCode != enrichUndoErrExpired {
		t.Fatalf("过期要拒绝: %+v", r)
	}
}

// setUpRematchUndoTest:重新匹配撤销的环境:只开假 deezer 的重评(setupRescoreTest)+ 落盘的编辑通道(setUpEnrichUndoTest)。
// 次序不能反:setupRescoreTest 把缓存路径换成自己的临时目录,放在后面的话重新匹配写到别处去,整棵目录比了个空。
func setUpRematchUndoTest(t *testing.T, entries map[string]enrichEntry, sharing bool) string {
	t.Helper()
	setupRescoreTest(t, []string{"deezer"}, func(ctx context.Context) {
		lyricSourceRoundFrom(ctx).markReached("deezer")
	})
	root := setUpEnrichUndoTest(t, entries, sharing)
	featuresRef().LyricsSources = map[string]bool{"deezer": true}
	featuresRef().LyricsAutoUpgrade = true
	return root
}

// 「重新自动匹配」换了词:结论带 undo_id,撤销后条目(人工修正、选定源两个标记)、判决旁路、歌词文件和整棵目录跟重新匹配之前逐字节一致;
// 没词补上的(走补空那条路)同样。算下来还是这一份、什么都没换的不发 undo_id。
func TestUndoManualRematch(t *testing.T) {
	hand := enrichKey(rescoreTestArtist, "Undo Hand", "Some Album")
	empty := enrichKey(rescoreTestArtist, "Undo Empty", "Some Album")
	same := enrichKey(rescoreTestArtist, "Undo Same", "Some Album")
	root := setUpRematchUndoTest(t, map[string]enrichEntry{
		hand: {TS: 1, Lyrics: bt("[00:05.00]My own first line\n[00:15.00]My own second line"), ManualLyrics: true,
			LyricsSourceChoice: "qq", LyricsScoringVersion: lyricsScoringVersion - 1,
			LyricsDecision: &lyricsDecision{Path: lyricsDecisionPathRescore, Winner: "qq", Candidates: []lyricsDecisionCandidate{{Source: "qq", Score: 10}}}},
		empty: {TS: 1},
		same:  {TS: 1, Lyrics: bt(rescoreTestNewBody), LyricsSource: "deezer", LyricsScoringVersion: lyricsScoringVersion - 1},
	}, false)
	for _, key := range []string{hand, empty} {
		before, beforeJSON := undoTree(t, root), undoEntryJSON(t, key)
		got := runLyricsRematchOne(context.Background(), key, nil)
		if got.Outcome != lyricsRematchChanged || got.UndoID == "" {
			t.Fatalf("%s 重新匹配: %+v", key, got)
		}
		if undoEntryJSON(t, key) == beforeJSON {
			t.Fatalf("%s 没换", key)
		}
		if r := undoEdit(got.UndoID); !r.OK {
			t.Fatalf("%s 撤销: %+v", key, r)
		}
		if after := undoEntryJSON(t, key); after != beforeJSON {
			t.Errorf("%s 条目:\n之前 %s\n之后 %s", key, beforeJSON, after)
		}
		after := undoTree(t, root)
		if key == empty {
			// 放回去之后这首没有正文:正文小文件跟别的把正文改空的保存一样留在盘上,精简索引里 body_crc 为 0,读的一方不认它。
			orphan := filepath.Join(filepath.Base(enrichBodiesDir()), filepath.Base(bodySidePath(enrichBodiesDir(), key)))
			if _, ok := after[orphan]; !ok {
				t.Errorf("没找到这条的正文小文件 %s,换了位置要改这里", orphan)
			}
			delete(after, orphan)
		}
		diffUndoTree(t, key, before, after)
	}
	if got := runLyricsRematchOne(context.Background(), same, nil); got.Outcome != lyricsRematchUnchanged || got.UndoID != "" {
		t.Errorf("什么都没换不发 undo_id: %+v", got)
	}
}

// 重新匹配之后这首被动过(存了手改、标了纯音乐、后台换了正文):拒绝、不动;过期同样拒绝。写回之后、发 undo_id 之前就被
// 改动序号记过的,不发 undo_id。
func TestUndoManualRematchRefusesAndExpires(t *testing.T) {
	key := enrichKey(rescoreTestArtist, "Undo Refuse", "Some Album")
	const old = "[00:05.00]Old line one\n[00:15.00]Old line two"
	setUpRematchUndoTest(t, map[string]enrichEntry{
		key: {TS: 1, Lyrics: bt(old), LyricsSource: "deezer", LyricsScore: 1, ManualLyrics: true, LyricsScoringVersion: lyricsScoringVersion - 1},
	}, false)
	reset := func() {
		enrichMu.Lock()
		enrichCache[key] = enrichEntry{TS: 1, Lyrics: bt(old), LyricsSource: "deezer", LyricsScore: 1, ManualLyrics: true,
			LyricsScoringVersion: lyricsScoringVersion - 1}
		enrichMu.Unlock()
	}
	rematch := func() string {
		t.Helper()
		reset()
		got := runLyricsRematchOne(context.Background(), key, nil)
		if got.UndoID == "" {
			t.Fatalf("重新匹配: %+v", got)
		}
		return got.UndoID
	}
	for _, c := range []struct {
		label  string
		change func()
	}{
		{"存了手改", func() {
			applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: key, Lyrics: "[00:01.00]手改", MarkManual: true})
		}},
		{"标了纯音乐", func() { applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: key, Value: true}) }},
		{"后台换了正文", func() {
			enrichMu.Lock()
			e := enrichCache[key]
			e.Lyrics = bt("[00:01.00]后台换的")
			enrichCache[key] = e
			enrichMu.Unlock()
		}},
	} {
		id := rematch()
		c.change()
		snap := undoEntryJSON(t, key)
		if r := undoEdit(id); r.OK || r.ErrorCode != enrichUndoErrChanged {
			t.Fatalf("%s 要拒绝: %+v", c.label, r)
		}
		if undoEntryJSON(t, key) != snap {
			t.Errorf("%s:拒绝时不该改条目", c.label)
		}
	}

	now := time.Unix(4_000_000, 0)
	enrichUndoNow = func() time.Time { return now }
	id := rematch()
	now = now.Add(enrichUndoTTL + time.Second)
	if r := undoEdit(id); r.OK || r.ErrorCode != enrichUndoErrExpired {
		t.Fatalf("过期要拒绝: %+v", r)
	}

	// 写回之后、收下记录之前被别的改动记过:不发。
	reset()
	var rec *enrichUndoRecord
	enrichMu.Lock()
	rec = beginRematchUndoLocked(key)
	e := enrichCache[key]
	e.Lyrics = bt(rescoreTestNewBody)
	enrichCache[key] = e
	rec.finishLocked(nil)
	rec.seq = enrichEditSeq
	markEnrichEditedLocked(false, key)
	enrichMu.Unlock()
	if id := keepRematchUndo(rec); id != "" {
		t.Errorf("写回之后被改过不发 undo_id: %q", id)
	}
}

// 歌词同步开着:重新匹配之后同组写法跟着换(写留底、判决出处改成同步);撤销把这首、跟着换的写法、它们的留底和判决旁路一起放回,
// 整棵目录逐字节一致。跟着换的写法之后又被改过:整笔拒绝。
func TestUndoManualRematchShareGroupFollowers(t *testing.T) {
	lead := enrichKey(rescoreTestArtist, "Undo Lead", "Some Album")
	mate := enrichKey(rescoreTestArtist, "Undo Lead", "Other Album")
	entries := func() map[string]enrichEntry {
		return map[string]enrichEntry{
			lead: {Song: "s_undo", TS: 1, Lyrics: bt(songShareLRC("lead")), LyricsSource: "deezer", LyricsScore: 1,
				LyricsScoringVersion: lyricsScoringVersion - 1},
			mate: {Song: "s_undo", TS: 1, Lyrics: bt(songShareLRC("mate")), LyricsSource: "kugou",
				LyricsDecisionApplied: &lyricsDecision{Path: lyricsDecisionPathRescore, Winner: "kugou", Candidates: []lyricsDecisionCandidate{{Source: "kugou"}}}},
		}
	}
	root := setUpRematchUndoTest(t, entries(), true)
	before := undoTree(t, root)
	beforeJSON := map[string]string{lead: undoEntryJSON(t, lead), mate: undoEntryJSON(t, mate)}
	got := runLyricsRematchOne(context.Background(), lead, nil)
	if got.Outcome != lyricsRematchChanged || got.Followers != 1 || got.UndoID == "" {
		t.Fatalf("重新匹配、同组跟上: %+v", got)
	}
	if !hasPre(mate) {
		t.Fatal("跟着换的写法应写了留底")
	}
	if r := undoEdit(got.UndoID); !r.OK {
		t.Fatalf("撤销: %+v", r)
	}
	for k, want := range beforeJSON {
		if after := undoEntryJSON(t, k); after != want {
			t.Errorf("%s 条目:\n之前 %s\n之后 %s", k, want, after)
		}
	}
	diffUndoTree(t, "同组跟上", before, undoTree(t, root))

	got = runLyricsRematchOne(context.Background(), lead, nil)
	if got.Followers != 1 || got.UndoID == "" {
		t.Fatalf("再跑一次: %+v", got)
	}
	applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: mate, Value: true})
	if r := undoEdit(got.UndoID); r.OK || r.ErrorCode != enrichUndoErrChanged {
		t.Fatalf("跟着换的写法又被改过要拒绝: %+v", r)
	}
	if e, _ := cacheEntry(t, lead); !strings.HasPrefix(e.Lyrics.String(), "[00:05.00]Brand new") {
		t.Errorf("拒绝时这首不动: %q", e.Lyrics)
	}
}

// 「重新自动匹配」接线:手动那条路给 undo,同组跟上时一起记;后台路径不给。
func TestManualRematchUndoWired(t *testing.T) {
	src, err := os.ReadFile("lyricsrematch.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func runLyricsRematchOne(")
	if i < 0 {
		t.Fatal("找不到 runLyricsRematchOne")
	}
	for _, want := range []string{
		"opts := lyricsRescoreOpts{manual: true, progress: progress, result: &result, undo: &undo}",
		"shareFollowWritingCapturing(key, time.Now(), undo)",
		"result.UndoID = keepRematchUndo(undo)",
	} {
		if !containsCode(body[i:], want) {
			t.Errorf("runLyricsRematchOne 里找不到: %q", want)
		}
	}
	enrich, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if n := countCode(string(enrich), "undo := opts.beginUndoLocked(key)\n\tenrichCache[key] = e\n\tenrichDirty = true\n\topts.finishUndoLocked(undo)"); n != 2 {
		t.Errorf("rescoreLyricsWith、retryLyricsUpgradeWith 写回那一刻都要留撤销记录,找到 %d 处", n)
	}
}

// 同组写法这一笔没跟着改(标了纯音乐的不同步手改):记录里不留它,撤销不碰它之后才有的留底。
func TestUndoSkipsShareMateNotChanged(t *testing.T) {
	const a, m = "X|UndoS|A", "X|UndoS|M"
	setUpEnrichUndoTest(t, map[string]enrichEntry{
		a: {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("a")), LyricsSource: "qq"},
		m: {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("m")), LyricsSource: "kugou", Instrumental: true},
	}, true)
	res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: a, Lyrics: songShareLRC("mine"), Source: "manual", MarkManual: true,
		YRC: strPtr(""), Undoable: true})
	if got, _ := cacheEntry(t, m); !res.OK || !got.Lyrics.EqualString(songShareLRC("m")) {
		t.Fatalf("前提:标了纯音乐的同组写法不跟着改: %+v %+v", res, got)
	}
	later := []byte(`{"key":"X|UndoS|M","saved_at":9}`)
	if err := os.MkdirAll(songSharePreDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(songSharePrePath(m), later, 0o600); err != nil {
		t.Fatal(err)
	}
	if r := undoEdit(res.UndoID); !r.OK {
		t.Fatalf("撤销: %+v", r)
	}
	if data, err := os.ReadFile(songSharePrePath(m)); err != nil || string(data) != string(later) {
		t.Errorf("没跟着改的写法之后的留底不该被撤销改掉: %q %v", data, err)
	}
}

// 重新匹配之后同组写法的留底写不成(那个文件是别的写法的):这条没跟着换,记录里不留它,这一首照常能撤。
func TestUndoManualRematchFollowerBackupFailed(t *testing.T) {
	lead := enrichKey(rescoreTestArtist, "Undo Fail", "Some Album")
	mate := enrichKey(rescoreTestArtist, "Undo Fail", "Other Album")
	setUpRematchUndoTest(t, map[string]enrichEntry{
		lead: {Song: "s_fail", TS: 1, Lyrics: bt(songShareLRC("lead")), LyricsSource: "deezer", LyricsScore: 1,
			LyricsScoringVersion: lyricsScoringVersion - 1},
		mate: {Song: "s_fail", TS: 1, Lyrics: bt(songShareLRC("mate")), LyricsSource: "kugou"},
	}, true)
	if err := os.MkdirAll(songSharePreDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(songSharePrePath(mate), []byte(`{"key":"someone else","entry":{"ts":1}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	beforeJSON := undoEntryJSON(t, lead)
	got := runLyricsRematchOne(context.Background(), lead, nil)
	if got.Outcome != lyricsRematchChanged || got.Followers != 0 || got.UndoID == "" {
		t.Fatalf("留底写不成时同组不跟,这一首照样给 undo_id: %+v", got)
	}
	if r := undoEdit(got.UndoID); !r.OK {
		t.Fatalf("撤销: %+v", r)
	}
	if after := undoEntryJSON(t, lead); after != beforeJSON {
		t.Errorf("条目:\n之前 %s\n之后 %s", beforeJSON, after)
	}
}
