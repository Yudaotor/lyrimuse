package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

// setUpSongShareTest:临时配置目录、缓存、歌词目录,开关按 on,pinned 这几条写法进校准名单。返回配置目录。
func setUpSongShareTest(t *testing.T, entries map[string]enrichEntry, on bool, pinned ...string) string {
	t.Helper()
	setUpEnrichEditTest(t, entries)
	dir := filepath.Join(t.TempDir(), "cfg", clientName)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	setFeatures(featureFlags{SongEntityShadow: true, SongEntityShareLyrics: on})
	pins := map[string]int64{}
	for _, k := range pinned {
		pins[k] = 1
	}
	path := filepath.Join(dir, "pins.json")
	data, _ := json.Marshal(lyricsPinsFile{Version: 1, Pins: pins})
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	savedPins, savedInflight := lyricsPinsPath, enrichInflight
	t.Cleanup(func() { lyricsPinsPath, enrichInflight = savedPins, savedInflight })
	lyricsPinsPath = path
	enrichInflight = map[string]bool{}
	return dir
}

func songShareLRC(seed string) string { return songTestLRC(0, songTestWords(seed, 4)) }

func readPreEntry(t *testing.T, key string) (*songSharePre, enrichEntry) {
	t.Helper()
	p, err := readSongSharePre(songSharePrePath(key))
	if err != nil {
		t.Fatalf("%s 没有留底: %v", key, err)
	}
	var e enrichEntry
	if err := json.Unmarshal(p.Entry, &e); err != nil {
		t.Fatal(err)
	}
	return p, e
}

func hasPre(key string) bool {
	_, err := os.Stat(songSharePrePath(key))
	return err == nil
}

// 字段归属里「歌词选择」那一类的每个字段,同步和恢复都要搬;精简索引才有的两个校验字段除外。
func TestSongShareFieldsCoverLyricsChoice(t *testing.T) {
	var src enrichEntry
	v := reflect.ValueOf(&src).Elem()
	field := map[string]int{}
	for i := 0; i < v.NumField(); i++ {
		name, _, _ := strings.Cut(v.Type().Field(i).Tag.Get("json"), ",")
		if name != "" && name != "-" {
			field[name] = i
		}
	}
	var keys []string
	for key, class := range songEntityFieldClasses {
		if class == songFieldLyricsChoice && key != "body_crc" && key != "body_fields" {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	for _, key := range keys {
		i, ok := field[key]
		if !ok {
			t.Fatalf("登记的 %s 在 enrichEntry 里找不到", key)
		}
		f := v.Field(i)
		switch f.Kind() {
		case reflect.String:
			f.SetString(key)
		case reflect.Int, reflect.Int64:
			f.SetInt(7)
		case reflect.Uint8, reflect.Uint32:
			f.SetUint(7)
		case reflect.Float64:
			f.SetFloat(1.5)
		case reflect.Bool:
			f.SetBool(true)
		case reflect.Pointer:
			f.Set(reflect.New(f.Type().Elem()))
		case reflect.Slice:
			f.Set(reflect.MakeSlice(f.Type(), 1, 1))
		default:
			t.Fatalf("%s: 没处理的类型 %s", key, f.Kind())
		}
	}
	var dst enrichEntry
	songShareLyricsFields(&dst, src)
	d := reflect.ValueOf(dst)
	for _, key := range keys {
		if !reflect.DeepEqual(d.Field(field[key]).Interface(), v.Field(field[key]).Interface()) {
			t.Errorf("%s 没跟着搬", key)
		}
	}
}

// 歌词管理里存手改:开关关着不同步;开着时同步到整个实体,对方自己的手改原件、校准、纯音乐、别的实体不动,副本带同样的
// 手改标记、记原件,覆盖前留底。直接改副本,它就成了原件。采纳候选(没锁定)同步出去的副本也不锁定。
func TestSongShareManualEdit(t *testing.T) {
	const a, b, c, d, e, f = "X|Song|A", "X|Song|B", "X|Song|C", "X|Song|D", "X|Song|E", "X|Other|F"
	entries := map[string]enrichEntry{
		a: {Song: "s1", Lyrics: songShareLRC("a"), LyricsSource: "qq"},
		b: {Song: "s1", Lyrics: songShareLRC("b"), LyricsYRC: "[0,500]b", LyricsSource: "kugou", LyricsScore: 900,
			LyricsDecisionApplied: &lyricsDecision{Path: lyricsDecisionPathRescore, Winner: "kugou"}},
		c: {Song: "s1", Lyrics: songShareLRC("c"), LyricsSource: "netease"},
		d: {Song: "s1", Lyrics: songShareLRC("d"), LyricsSource: "manual", ManualLyrics: true},
		e: {Song: "s1", Instrumental: true},
		f: {Song: "s2", Lyrics: songShareLRC("f"), LyricsSource: "qq"},
	}
	setUpSongShareTest(t, entries, false, c)
	applied := &lyricsDecision{Path: lyricsDecisionPathRescore, DecidedAt: 77, Winner: "kugou", DetailsExternal: true}
	enrichMu.Lock()
	eb := enrichCache[b]
	eb.LyricsDecisionApplied = applied
	enrichCache[b] = eb
	enrichMu.Unlock()
	if err := os.MkdirAll(decisionSidecarDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeDecisionSidecarFile(filepath.Join(decisionSidecarDir(), decisionSidecarName(b)), decisionSidecar{Key: b,
		Applied: &decisionDetails{Path: applied.Path, DecidedAt: 77, Winner: "kugou", Candidates: []lyricsDecisionCandidate{{Source: "kugou", Score: 900}}}}); err != nil {
		t.Fatal(err)
	}
	save := func(key, lyrics string) enrichEditResult {
		return applyEnrichEdit(enrichEditRequest{ID: "r", Op: "save_edit", Key: key, Lyrics: lyrics, Source: "manual", MarkManual: true, YRC: strPtr("")})
	}
	if res := save(a, songShareLRC("off")); !res.OK || res.Changed != 1 {
		t.Fatalf("开关关着: %+v", res)
	}
	if got, _ := cacheEntry(t, b); got.Lyrics != songShareLRC("b") || hasPre(b) {
		t.Fatalf("开关关着不该同步: %+v", got)
	}

	setFeatures(featureFlags{SongEntityShadow: true, SongEntityShareLyrics: true})
	fixed := songShareLRC("fixed")
	if res := save(a, fixed); !res.OK || res.Changed != 2 {
		t.Fatalf("开关开着: %+v", res)
	}
	got, _ := cacheEntry(t, b)
	if got.Lyrics != fixed || got.LyricsYRC != "" || got.LyricsSource != "manual" || !got.ManualLyrics || got.LyricsEntityOrigin != a {
		t.Errorf("副本: %+v", got)
	}
	if ap := got.LyricsDecisionApplied; ap == nil || ap.Path != lyricsDecisionPathSongEntityShare || ap.ReusedFrom != a {
		t.Errorf("副本的出处: %+v", ap)
	}
	pre, old := readPreEntry(t, b)
	if pre.Synced != songOffsetFingerprint(fixed, "") || old.Lyrics != songShareLRC("b") || old.LyricsYRC != "[0,500]b" ||
		old.LyricsDecisionApplied == nil || old.LyricsDecisionApplied.Winner != "kugou" || len(old.LyricsDecisionApplied.Candidates) != 1 {
		t.Errorf("留底(当前歌词的出处连候选明细一起): %+v / %+v", pre, old)
	}
	for _, k := range []string{c, d, e, f} {
		if got, _ := cacheEntry(t, k); got.Lyrics != entries[k].Lyrics || got.LyricsEntityOrigin != "" || hasPre(k) {
			t.Errorf("%s 不该动: %+v", k, got)
		}
	}
	if len(lyricsFilesOwnedBy(b)) == 0 {
		t.Error("副本的歌词文件要导出")
	}

	mine := songShareLRC("mine")
	if res := save(b, mine); !res.OK || res.Changed != 1 {
		t.Fatalf("改副本: %+v", res)
	}
	if got, _ := cacheEntry(t, b); got.LyricsEntityOrigin != "" || got.Lyrics != mine {
		t.Errorf("直接改的副本要成原件: %+v", got)
	}
	if got, _ := cacheEntry(t, a); got.Lyrics != fixed {
		t.Errorf("另一份原件留着自己的: %+v", got)
	}

	picked := songShareLRC("picked")
	res := applyEnrichEdit(enrichEditRequest{ID: "p", Op: "save_edit", Key: f, Lyrics: picked, Source: "qq", FromManualPick: true, YRC: strPtr("")})
	if !res.OK || res.Changed != 1 {
		t.Fatalf("别的实体只有一条写法,没东西可同步: %+v", res)
	}
	const g = "X|Other|G"
	enrichMu.Lock()
	enrichCache[g] = enrichEntry{Song: "s2", Lyrics: songShareLRC("g"), LyricsSource: "kuwo"}
	enrichMu.Unlock()
	res = applyEnrichEdit(enrichEditRequest{ID: "p2", Op: "save_edit", Key: f, Lyrics: picked, Source: "qq", FromManualPick: true, YRC: strPtr("")})
	if got, _ := cacheEntry(t, g); !res.OK || got.Lyrics != picked || got.ManualLyrics || !songSharePickHeld(got) || got.LyricsEntityOrigin != f {
		t.Errorf("采纳的副本: %+v / %+v", res, got)
	}
}

// 建表之后那一轮的手改同步:一份原件时其余写法(含过时的副本)跟它;两份内容不同的原件不替用户选;原件被删了,副本里挑键
// 最小的升成原件、删掉它的留底,其余跟它;原件改回了自动匹配,副本按留底恢复,没有留底的只去掉标记。
func TestShareManualLocked(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	m, old := songShareLRC("m"), songShareLRC("old")
	run := func(t *testing.T, entries map[string]enrichEntry) ([]string, bool) {
		t.Helper()
		keys := make([]string, 0, len(entries))
		for k := range entries {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return shareManualLocked(keys, "", nil, now)
	}

	t.Run("one", func(t *testing.T) {
		setUpSongShareTest(t, map[string]enrichEntry{
			"k1": {Lyrics: m, ManualLyrics: true, LyricsSource: "manual"},
			"k2": {Lyrics: songShareLRC("auto"), LyricsSource: "qq"},
			"k3": {Lyrics: old, ManualLyrics: true, LyricsEntityOrigin: "k1"},
		}, true)
		changed, conflict := run(t, map[string]enrichEntry{"k1": {}, "k2": {}, "k3": {}})
		if conflict || !slices.Equal(changed, []string{"k2", "k3"}) {
			t.Fatalf("changed=%v conflict=%v", changed, conflict)
		}
		for _, k := range changed {
			if got, _ := cacheEntry(t, k); got.Lyrics != m || got.LyricsEntityOrigin != "k1" || !got.ManualLyrics {
				t.Errorf("%s: %+v", k, got)
			}
		}
		if again, _ := run(t, map[string]enrichEntry{"k1": {}, "k2": {}, "k3": {}}); len(again) != 0 {
			t.Errorf("已经是副本的不再动: %v", again)
		}
		m2 := songShareLRC("m2")
		enrichMu.Lock()
		e := enrichCache["k1"]
		e.Lyrics = m2
		enrichCache["k1"] = e
		enrichMu.Unlock()
		if again, _ := run(t, map[string]enrichEntry{"k1": {}, "k2": {}, "k3": {}}); !slices.Equal(again, []string{"k2", "k3"}) {
			t.Fatalf("原件改了,副本跟着: %v", again)
		}
		if p, first := readPreEntry(t, "k2"); first.Lyrics != songShareLRC("auto") || p.Synced != songOffsetFingerprint(m2, "") {
			t.Errorf("留底只记第一次,synced 跟着最新的: %+v / %q", p, first.Lyrics)
		}
	})

	t.Run("stale pick", func(t *testing.T) {
		setUpSongShareTest(t, map[string]enrichEntry{
			"k1": {Lyrics: songShareLRC("auto"), ManualPickSHA: manualPickFingerprint(old), LyricsSource: "qq"},
			"k2": {Lyrics: songShareLRC("other"), LyricsSource: "kugou"},
		}, true)
		if changed, conflict := run(t, map[string]enrichEntry{"k1": {}, "k2": {}}); conflict || len(changed) != 0 {
			t.Fatalf("采纳的那份已经不在了,不算原件: changed=%v conflict=%v", changed, conflict)
		}
	})

	t.Run("conflict", func(t *testing.T) {
		setUpSongShareTest(t, map[string]enrichEntry{
			"k1": {Lyrics: m, ManualLyrics: true},
			"k2": {Lyrics: old, ManualLyrics: true},
			"k3": {Lyrics: songShareLRC("auto")},
		}, true)
		if changed, conflict := run(t, map[string]enrichEntry{"k1": {}, "k2": {}, "k3": {}}); !conflict || len(changed) != 0 {
			t.Fatalf("changed=%v conflict=%v", changed, conflict)
		}
	})

	t.Run("promote", func(t *testing.T) {
		setUpSongShareTest(t, map[string]enrichEntry{
			"k2": {Lyrics: m, ManualLyrics: true, LyricsEntityOrigin: "k1"},
			"k3": {Lyrics: m, ManualLyrics: true, LyricsEntityOrigin: "k1"},
			"k4": {Lyrics: songShareLRC("auto")},
		}, true)
		if _, err := writeSongSharePre("k2", enrichEntry{Lyrics: old}, songOffsetFingerprint(m, ""), now); err != nil {
			t.Fatal(err)
		}
		changed, _ := run(t, map[string]enrichEntry{"k2": {}, "k3": {}, "k4": {}})
		if !slices.Equal(changed, []string{"k2", "k3", "k4"}) {
			t.Fatalf("changed=%v", changed)
		}
		if got, _ := cacheEntry(t, "k2"); got.LyricsEntityOrigin != "" || hasPre("k2") {
			t.Errorf("升成原件、删掉留底: %+v", got)
		}
		for _, k := range []string{"k3", "k4"} {
			if got, _ := cacheEntry(t, k); got.Lyrics != m || got.LyricsEntityOrigin != "k2" {
				t.Errorf("%s 跟新原件: %+v", k, got)
			}
		}
	})

	t.Run("release", func(t *testing.T) {
		setUpSongShareTest(t, map[string]enrichEntry{
			"k1": {Lyrics: songShareLRC("rematched"), LyricsSource: "qq"},
			"k2": {Lyrics: m, ManualLyrics: true, LyricsEntityOrigin: "k1"},
			"k3": {Lyrics: m, ManualLyrics: true, ManualPickSHA: manualPickFingerprint(m), LyricsEntityOrigin: "k1"},
			"k4": {Lyrics: songShareLRC("since"), ManualLyrics: true, LyricsEntityOrigin: "k1"},
		}, true)
		for _, k := range []string{"k2", "k4"} {
			if _, err := writeSongSharePre(k, enrichEntry{Lyrics: old, LyricsSource: "kugou"}, songOffsetFingerprint(m, ""), now); err != nil {
				t.Fatal(err)
			}
		}
		changed, _ := run(t, map[string]enrichEntry{"k1": {}, "k2": {}, "k3": {}, "k4": {}})
		if !slices.Equal(changed, []string{"k2", "k3", "k4"}) {
			t.Fatalf("changed=%v", changed)
		}
		if got, _ := cacheEntry(t, "k4"); got.Lyrics != songShareLRC("since") || got.ManualLyrics || got.LyricsEntityOrigin != "" {
			t.Errorf("同步之后又变过的不按留底恢复: %+v", got)
		}
		if got, _ := cacheEntry(t, "k2"); got.Lyrics != old || got.LyricsSource != "kugou" || got.ManualLyrics || got.LyricsEntityOrigin != "" || hasPre("k2") {
			t.Errorf("按留底恢复: %+v", got)
		}
		if got, _ := cacheEntry(t, "k3"); got.Lyrics != m || got.ManualLyrics || got.ManualPickSHA != "" || got.LyricsEntityOrigin != "" {
			t.Errorf("没有留底的只去掉标记: %+v", got)
		}
		if got, _ := cacheEntry(t, "k1"); got.Lyrics != songShareLRC("rematched") {
			t.Errorf("改回自动匹配的原件不动: %+v", got)
		}
	})
}

// 一个共享组按这一轮的检索改:冠军写进要换、要补的写法(搜的那条出处里不记 reused_from,其余记它),先留底;自家源的、来源
// 没应答的留着,有来源没应答就到点再搜。开搜之后有写法被改过,整轮作废、这一轮新建的留底删掉。没有可用候选的隔 7 天再搜。
func TestApplyShareRound(t *testing.T) {
	now := time.Unix(3_000_000, 0)
	champ := songShareLRC("champ")
	keys := []string{"G|Song|1", "G|Song|2", "G|Song|3", "G|Song|4"}
	entries := func() map[string]enrichEntry {
		return map[string]enrichEntry{
			keys[0]: {Song: "s", Lyrics: songShareLRC("a"), LyricsSource: "qq"},
			keys[1]: {Song: "s", Lyrics: songShareLRC("n"), LyricsSource: "netease"},
			keys[2]: {Song: "s"},
			keys[3]: {Song: "s", Lyrics: songShareLRC("k"), LyricsSource: "kuwo"},
		}
	}
	own := []*songPlanLyrics{{}, {native: true}, nil, {}}
	round := songShareRound{
		shareEvalRound: shareEvalRound{Key: keys[0], Artist: "G", Title: "Song", Album: "1", Duration: 200, Scored: []scoredLyricCandidateResult{
			{Source: "netease", Lyrics: champ, LyricsYRC: "[0,500]c", Score: 1200},
			{Source: "qq", Lyrics: songShareLRC("a"), Score: 900},
		}},
		reached: true,
	}
	snapOf := func() []enrichEntry {
		enrichMu.Lock()
		defer enrichMu.Unlock()
		out := make([]enrichEntry, len(keys))
		for i, k := range keys {
			out[i] = enrichCache[k]
		}
		return out
	}

	setUpSongShareTest(t, entries(), true)
	snap := snapOf()
	enrichMu.Lock()
	stamp := enrichEditStampLocked()
	enrichMu.Unlock()
	out := applyShareRound(keys, own, snap, stamp, round, now)
	if out.changed != 1 || out.filled != 1 || out.kept != 2 || out.state == nil || out.state.RetryAfter != now.Add(songShareRetryIncomplete).Unix() {
		t.Fatalf("结局: %+v", out)
	}
	for i, k := range []string{keys[0], keys[2]} {
		got, _ := cacheEntry(t, k)
		if got.Lyrics != champ || got.LyricsYRC != "[0,500]c" || got.LyricsSource != "netease" || got.LyricsScore != 1200 ||
			got.lyricsScoring() != currentLyricsScoring || got.ResolvedDurationSecs != 200 {
			t.Errorf("%s: %+v", k, got)
		}
		wantFrom := ""
		if i == 1 {
			wantFrom = keys[0]
		}
		if ap := got.LyricsDecisionApplied; ap == nil || ap.Path != lyricsDecisionPathSongEntityShare || ap.ReusedFrom != wantFrom {
			t.Errorf("%s 的出处: %+v", k, ap)
		}
		if p, _ := readPreEntry(t, k); p.Synced != songOffsetFingerprint(champ, "[0,500]c") {
			t.Errorf("%s 的留底: %+v", k, p)
		}
	}
	for _, k := range []string{keys[1], keys[3]} {
		if got, _ := cacheEntry(t, k); got.Lyrics != entries()[k].Lyrics || hasPre(k) {
			t.Errorf("%s 留着: %+v", k, got)
		}
	}
	if out.state.Members[keys[0]] != songOffsetFingerprint(champ, "[0,500]c") || out.state.Members[keys[1]] != songOffsetFingerprint(songShareLRC("n"), "") {
		t.Errorf("组的记录要是改完之后的: %+v", out.state.Members)
	}

	setUpSongShareTest(t, entries(), true)
	snap = snapOf()
	enrichMu.Lock()
	stamp = enrichEditStampLocked()
	markEnrichEditedLocked(false, keys[3])
	enrichMu.Unlock()
	if out := applyShareRound(keys, own, snap, stamp, round, now); out.state != nil {
		t.Fatalf("开搜之后被改过要作废: %+v", out)
	}
	if got, _ := cacheEntry(t, keys[0]); got.Lyrics != songShareLRC("a") || hasPre(keys[0]) || hasPre(keys[2]) {
		t.Errorf("作废的一轮不改、不留底: %+v", got)
	}

	setUpSongShareTest(t, entries(), true)
	snap = snapOf()
	writeSongSharePins(t, map[string]string{keys[3]: ""})
	if out := applyShareRound(keys, own, snap, enrichEditNoStamp, round, now); out.state != nil {
		t.Fatalf("开搜之后钉住的要作废: %+v", out)
	}
	if got, _ := cacheEntry(t, keys[0]); got.Lyrics != songShareLRC("a") || hasPre(keys[0]) {
		t.Errorf("钉住之后作废的一轮不改、不留底: %+v", got)
	}

	setUpSongShareTest(t, entries(), true)
	snap = snapOf()
	partial := round
	partial.skipped = []string{"soda"}
	own2 := []*songPlanLyrics{{}, {}, nil, {native: true}}
	if out := applyShareRound(keys, own2, snap, enrichEditNoStamp, partial, now); out.state == nil || out.state.RetryAfter != now.Add(songShareRetryIncomplete).Unix() {
		t.Fatalf("有源被跳过要到点再搜: %+v", out)
	}
	if got, _ := cacheEntry(t, keys[0]); got.Lyrics != champ || got.LyricsScoringVersion != 0 || !slices.Equal(got.LyricsSourcesSkipped, lyricSourcesSkippedForRetry([]string{"soda"})) {
		t.Errorf("有源被跳过的一轮照换,不记打分版本: %+v", got)
	}

	none := round
	none.Scored = []scoredLyricCandidateResult{{Source: "qq", Lyrics: songShareLRC("x"), Score: -1}}
	if out := applyShareRound(keys, own, snap, enrichEditNoStamp, none, now); !out.noWinner || out.state == nil ||
		out.state.RetryAfter != now.Add(songShareRetryNoWinner).Unix() {
		t.Errorf("没有可用候选: %+v", out)
	}
}

// 组的记录:没有记录、打分版本变了、成员变了、哪条写法的歌词变了都要搜;都没变的不搜,到了约好的时刻再搜。
func TestSongShareStateDue(t *testing.T) {
	now := time.Unix(4_000_000, 0)
	st := &songShareState{Groups: map[string]songShareGroupState{}}
	fps := map[string]string{"a": "1", "b": "2"}
	sig := songShareGroupSig([]string{"b", "a"})
	if sig != songShareGroupSig([]string{"a", "b"}) || sig == songShareGroupSig([]string{"a", "c"}) {
		t.Fatal("签名只看成员")
	}
	if !st.due(sig, fps, now) {
		t.Error("没有记录要搜")
	}
	st.Groups[sig] = songShareGroupState{Scoring: currentLyricsScoring.String(), Members: map[string]string{"a": "1", "b": "2"}}
	if st.due(sig, fps, now) {
		t.Error("都没变不搜")
	}
	if !st.due(sig, map[string]string{"a": "1", "b": "3"}, now) {
		t.Error("歌词变了要搜")
	}
	if !st.due(songShareGroupSig([]string{"a", "b", "c"}), map[string]string{"a": "1", "b": "2", "c": ""}, now) {
		t.Error("成员变了要搜")
	}
	g := st.Groups[sig]
	g.Scoring = "v1"
	st.Groups[sig] = g
	if !st.due(sig, fps, now) {
		t.Error("打分版本变了要搜")
	}
	g.Scoring, g.RetryAfter = currentLyricsScoring.String(), now.Add(time.Hour).Unix()
	st.Groups[sig] = g
	if st.due(sig, fps, now) || !st.due(sig, fps, now.Add(time.Hour)) {
		t.Error("到点再搜")
	}
}

// 开关关掉:歌词还是同步写进去那份的按留底恢复;之后又被改过的留着,只去掉副本标记;存盘成功后留底和组的记录删掉,存盘
// 失败时都留着。
func TestRevertSongEntityShare(t *testing.T) {
	now := time.Unix(5_000_000, 0)
	synced, later := songShareLRC("synced"), songShareLRC("later")
	dir := setUpSongShareTest(t, map[string]enrichEntry{
		"r1": {Lyrics: synced, ManualLyrics: true, LyricsEntityOrigin: "r0", LyricsSource: "manual"},
		"r2": {Lyrics: later, LyricsSource: "qq"},
		"r3": {Lyrics: synced, ManualLyrics: true, LyricsEntityOrigin: "r0"},
		"r4": {Lyrics: songShareLRC("plain"), LyricsSource: "qq"},
	}, false)
	for _, k := range []string{"r1", "r2"} {
		if _, err := writeSongSharePre(k, enrichEntry{Lyrics: songShareLRC("orig-" + k), LyricsSource: "kugou", LyricsScore: 800},
			songOffsetFingerprint(synced, ""), now); err != nil {
			t.Fatal(err)
		}
	}
	if err := writeSongShareState(songShareStatePath(), &songShareState{Version: songShareStateVersion, FullBackup: dir}); err != nil {
		t.Fatal(err)
	}
	saved, blocker := enrichPath, filepath.Join(dir, "blocker")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	enrichPath = filepath.Join(blocker, "cache.json")
	revertSongEntityShare()
	if !hasPre("r1") || !hasPre("r2") {
		t.Fatal("存盘失败时留底不删")
	}
	if _, err := os.Stat(songShareStatePath()); err != nil {
		t.Fatalf("存盘失败时组的记录不删: %v", err)
	}
	enrichPath = saved
	revertSongEntityShare()
	if got, _ := cacheEntry(t, "r1"); got.Lyrics != songShareLRC("orig-r1") || got.LyricsSource != "kugou" || got.LyricsScore != 800 ||
		got.ManualLyrics || got.LyricsEntityOrigin != "" {
		t.Errorf("r1 按留底恢复: %+v", got)
	}
	if got, _ := cacheEntry(t, "r2"); got.Lyrics != later {
		t.Errorf("r2 同步之后又改过,留着: %+v", got)
	}
	if got, _ := cacheEntry(t, "r3"); got.Lyrics != synced || got.LyricsEntityOrigin != "" {
		t.Errorf("r3 没有留底,只去掉副本标记: %+v", got)
	}
	if hasPre("r1") || hasPre("r2") {
		t.Error("留底要删掉")
	}
	if _, err := os.Stat(songShareStatePath()); !os.IsNotExist(err) {
		t.Errorf("组的记录要删掉: %v", err)
	}
	if data, err := os.ReadFile(enrichPath); err != nil || !strings.Contains(string(data), `"lyrics_score":800`) {
		t.Errorf("恢复的要落盘: %v", err)
	}
}

// 整轮:第一次先整份备份;手改同步;要换词的共享组搜一轮、按结果改,记下组的样子;再跑一轮,改好的组不再搜,记着没变的组
// 也不搜;开关中途关掉停在两组之间;关掉之后那一步把同步过的恢复回去。
func TestSongEntitySharePass(t *testing.T) {
	champ := songShareLRC("champ")
	entries := map[string]enrichEntry{
		"A|Song|One":   {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}, Lyrics: songShareLRC("a1"), LyricsSource: "qq"},
		"A|Song|Two":   {DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}, Lyrics: songShareLRC("a2"), LyricsSource: "kugou"},
		"A|Song|Three": {DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}},
		"B|Tune|One":   {DurationSecs: 180, ISRCs: []string{"USAAA1100002"}, Lyrics: songShareLRC("b1"), LyricsSource: "qq"},
		"B|Tune|Two":   {DurationSecs: 180.1, ISRCs: []string{"USAAA1100002"}, Lyrics: songShareLRC("b2"), LyricsSource: "kuwo"},
		"C|Air|One":    {DurationSecs: 150, ISRCs: []string{"USAAA1100003"}, Lyrics: songShareLRC("m"), LyricsSource: "manual", ManualLyrics: true},
		"C|Air|Two":    {DurationSecs: 150.1, ISRCs: []string{"USAAA1100003"}, Lyrics: songShareLRC("c2"), LyricsSource: "qq"},
	}
	dir := setUpSongShareTest(t, entries, true)
	savedSearch, savedWait := searchShareRound, songShareWait
	t.Cleanup(func() { searchShareRound, songShareWait = savedSearch, savedWait })
	songShareWait = func(context.Context, time.Duration) {}
	var searched []string
	searchShareRound = func(_ context.Context, key, artist, title, album string, dur float64) songShareRound {
		searched = append(searched, key)
		return songShareRound{
			shareEvalRound: shareEvalRound{Key: key, Artist: artist, Title: title, Album: album, Duration: dur, Scored: []scoredLyricCandidateResult{
				{Source: "netease", Lyrics: champ, Score: 1200},
				{Source: "qq", Lyrics: songShareLRC("a1"), Score: 900},
				{Source: "kugou", Lyrics: songShareLRC("a2"), Score: 800},
			}},
			reached: true,
		}
	}
	ctx := context.Background()
	b := rebuildSongEntityTable(time.Now())
	if b == nil {
		t.Fatal("建表失败")
	}
	runSongEntitySharePass(ctx, b)

	st := readSongShareState(songShareStatePath())
	if st.FullBackup == "" || !strings.HasPrefix(st.FullBackup, filepath.Join(filepath.Dir(dir), clientName+"-backups")) {
		t.Fatalf("整份备份: %+v", st)
	}
	if _, err := os.Stat(filepath.Join(st.FullBackup, filepath.Base(enrichPath))); err != nil {
		t.Errorf("备份里要有主缓存: %v", err)
	}
	if len(searched) != 2 || !strings.HasPrefix(searched[0], "A|Song|") || !strings.HasPrefix(searched[1], "B|Tune|") {
		t.Fatalf("搜了 %v", searched)
	}
	for _, k := range []string{"A|Song|One", "A|Song|Two", "A|Song|Three"} {
		if got, _ := cacheEntry(t, k); got.Lyrics != champ {
			t.Errorf("%s 跟冠军: %+v", k, got)
		}
	}
	if got, _ := cacheEntry(t, "B|Tune|Two"); got.Lyrics != songShareLRC("b2") {
		t.Errorf("来源没应答的留着: %+v", got)
	}
	if got, _ := cacheEntry(t, "C|Air|Two"); got.Lyrics != songShareLRC("m") || got.LyricsEntityOrigin != "C|Air|One" {
		t.Errorf("手改同步: %+v", got)
	}
	if len(st.Groups) != 2 {
		t.Errorf("搜过的两组都记下: %+v", st.Groups)
	}

	searched = nil
	b = rebuildSongEntityTable(time.Now())
	runSongEntitySharePass(ctx, b)
	if len(searched) != 0 {
		t.Errorf("没变的组不再搜: %v", searched)
	}
	if st := readSongShareState(songShareStatePath()); len(st.Groups) != 1 {
		t.Errorf("换好、不再挑出来的那组要从记录里去掉: %+v", st.Groups)
	}

	enrichMu.Lock()
	e := enrichCache["B|Tune|Two"]
	e.Lyrics = songShareLRC("b3")
	enrichCache["B|Tune|Two"] = e
	e = enrichCache["A|Song|Two"]
	e.Lyrics = songShareLRC("a9")
	enrichCache["A|Song|Two"] = e
	enrichMu.Unlock()
	searched = nil
	searchShareRound = func(_ context.Context, key, artist, title, album string, dur float64) songShareRound {
		searched = append(searched, key)
		setFeatures(featureFlags{SongEntityShadow: true})
		return songShareRound{shareEvalRound: shareEvalRound{Key: key, Scored: []scoredLyricCandidateResult{{Source: "netease", Lyrics: champ, Score: 1200}}}, reached: true}
	}
	b = rebuildSongEntityTable(time.Now())
	runSongEntitySharePass(ctx, b)
	if len(searched) != 1 {
		t.Errorf("开关中途关掉要停在两组之间: %v", searched)
	}

	if songEntityShareStep(ctx, nil) {
		t.Fatal("开关关着要按关着做")
	}
	if got, _ := cacheEntry(t, "A|Song|One"); got.Lyrics != songShareLRC("a1") {
		t.Errorf("关掉之后要恢复: %+v", got)
	}
	if got, _ := cacheEntry(t, "C|Air|Two"); got.Lyrics != songShareLRC("c2") || got.ManualLyrics || got.LyricsEntityOrigin != "" {
		t.Errorf("手改的副本要恢复: %+v", got)
	}
	if entries, _ := os.ReadDir(songSharePreDir()); len(entries) != 0 {
		t.Errorf("留底要删光: %d", len(entries))
	}
}

// 歌词文件夹里副本的正文或逐字被改过:导入之后它是用户自己的,不再记原件;只改了译文的还是副本。
func TestImportClearsEntityOrigin(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	edited, kept := enrichKey("A", "B", "C"), enrichKey("A", "B", "D")
	write("A - B - C.lrc", "[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]edited")
	write("A - B - D.lrc", "[ar:A]\n[ti:B]\n[al:D]\n\n[00:01.00]same")
	write("A - B - D.tr.lrc", "[ar:A]\n[ti:B]\n[al:D]\n\n[00:01.00]新译文")
	savedDir, savedCache := lyricsDir(), enrichCache
	t.Cleanup(func() {
		enrichMu.Lock()
		setLyricsDir(savedDir)
		enrichCache = savedCache
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	setLyricsDir(dir)
	enrichCache = map[string]enrichEntry{
		edited: {Lyrics: "[00:01.00]synced", LyricsEntityOrigin: "A|B|X"},
		kept:   {Lyrics: "[00:01.00]same", LyricsTr: "[00:01.00]旧译文", LyricsEntityOrigin: "A|B|X"},
	}
	enrichMu.Unlock()
	importLyricsFromOpts(dir, false, false)
	if got, _ := cacheEntry(t, edited); got.Lyrics != "[00:01.00]edited" || got.LyricsEntityOrigin != "" {
		t.Errorf("正文改过的成了原件: %+v", got)
	}
	if got, _ := cacheEntry(t, kept); got.LyricsTr != "[00:01.00]新译文" || got.LyricsEntityOrigin != "A|B|X" {
		t.Errorf("只改译文的还是副本: %+v", got)
	}
}

// 常驻进程启动时清掉缓存里已经没有的写法的留底,还在的留着。
func TestStartupSweepsOrphanSongSharePre(t *testing.T) {
	setUpSongShareTest(t, map[string]enrichEntry{"live": {Lyrics: songShareLRC("l")}}, true)
	enrichMu.Lock()
	enrichDirty = true
	enrichMu.Unlock()
	if err := saveEnrichCacheChecked(); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(6_000_000, 0)
	for _, k := range []string{"live", "gone"} {
		if _, err := writeSongSharePre(k, enrichEntry{Lyrics: "x"}, "fp", now); err != nil {
			t.Fatal(err)
		}
	}
	refreshEnrichIndexAtStartup()
	if !hasPre("live") || hasPre("gone") {
		t.Errorf("live=%v gone=%v", hasPre("live"), hasPre("gone"))
	}
}

// 删掉、清空条目时同步留底跟着删:不然这条写法再放回来又被同步时沿用删之前那份,恢复成删掉的旧词。
func TestDeleteAndClearDropSongSharePre(t *testing.T) {
	setUpSongShareTest(t, map[string]enrichEntry{
		"a|x|1": {Lyrics: songShareLRC("a")},
		"b|x|1": {Lyrics: songShareLRC("b")},
		"c|x|1": {Lyrics: songShareLRC("c")},
	}, true)
	now := time.Unix(6_000_000, 0)
	for _, k := range []string{"a|x|1", "b|x|1", "c|x|1"} {
		if _, err := writeSongSharePre(k, enrichEntry{Lyrics: "old"}, "fp", now); err != nil {
			t.Fatal(err)
		}
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "delete", Keys: []string{"a|x|1"}}); !res.OK {
		t.Fatalf("delete: %+v", res)
	}
	if hasPre("a|x|1") || !hasPre("b|x|1") || !hasPre("c|x|1") {
		t.Errorf("删一条只删它的留底 a=%v b=%v c=%v", hasPre("a|x|1"), hasPre("b|x|1"), hasPre("c|x|1"))
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "clear_all"}); !res.OK {
		t.Fatalf("clear_all: %+v", res)
	}
	if hasPre("b|x|1") || hasPre("c|x|1") {
		t.Errorf("清空之后留底还在 b=%v c=%v", hasPre("b|x|1"), hasPre("c|x|1"))
	}
}

// 组里有写法正在被别的任务处理:这一轮不搜、不改,下一轮再来。
func TestShareGroupSkipsInflight(t *testing.T) {
	entries := map[string]enrichEntry{
		"A|Song|One": {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}, Lyrics: songShareLRC("a1"), LyricsSource: "qq"},
		"A|Song|Two": {DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}, Lyrics: songShareLRC("a2"), LyricsSource: "kugou"},
	}
	setUpSongShareTest(t, entries, true)
	saved := searchShareRound
	t.Cleanup(func() { searchShareRound = saved })
	calls := 0
	searchShareRound = func(context.Context, string, string, string, string, float64) songShareRound {
		calls++
		return songShareRound{reached: true}
	}
	vs := []songVariant{songTestVariant("A|Song|One", entries["A|Song|One"], nil), songTestVariant("A|Song|Two", entries["A|Song|Two"], nil)}
	b, _ := songTestBuild(t, vs, nil)
	own := []*songPlanLyrics{b.songPlanLyricsOf(0, nil), b.songPlanLyricsOf(1, nil)}
	enrichMu.Lock()
	enrichInflight["A|Song|Two"] = true
	enrichMu.Unlock()
	if out := b.shareGroup(context.Background(), []int{0, 1}, own); out.state != nil || calls != 0 {
		t.Fatalf("在途的组不搜: %+v calls=%d", out, calls)
	}
	enrichMu.Lock()
	delete(enrichInflight, "A|Song|Two")
	enrichMu.Unlock()
	b.shareGroup(context.Background(), []int{0, 1}, own)
	enrichMu.Lock()
	held := enrichInflight["A|Song|One"] || enrichInflight["A|Song|Two"]
	enrichMu.Unlock()
	if calls != 1 || held {
		t.Errorf("搜完要放开: calls=%d held=%v", calls, held)
	}
}

// 第一次同步之前的整份备份做不成,这一轮什么都不同步。
func TestSongEntitySharePassNeedsFullBackup(t *testing.T) {
	entries := map[string]enrichEntry{
		"C|Air|One": {DurationSecs: 150, ISRCs: []string{"USAAA1100003"}, Lyrics: songShareLRC("m"), LyricsSource: "manual", ManualLyrics: true},
		"C|Air|Two": {DurationSecs: 150.1, ISRCs: []string{"USAAA1100003"}, Lyrics: songShareLRC("c2"), LyricsSource: "qq"},
	}
	dir := setUpSongShareTest(t, entries, true)
	if err := os.WriteFile(filepath.Join(filepath.Dir(dir), clientName+"-backups"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	b := rebuildSongEntityTable(time.Now())
	runSongEntitySharePass(context.Background(), b)
	if got, _ := cacheEntry(t, "C|Air|Two"); got.Lyrics != songShareLRC("c2") || got.LyricsEntityOrigin != "" {
		t.Errorf("备份不成不同步: %+v", got)
	}
	if _, err := os.Stat(songShareStatePath()); !os.IsNotExist(err) {
		t.Errorf("不记组: %v", err)
	}
}

// writeSongSharePins:改写校准名单。content 是写法键 → 那条 pin 的校准对着的歌词指纹,空串是钉着、没记。
func writeSongSharePins(t *testing.T, content map[string]string) {
	t.Helper()
	f := lyricsPinsFile{Version: 1, Pins: map[string]int64{}, Content: map[string]string{}}
	for k, fp := range content {
		f.Pins[k] = 1
		if fp != "" {
			f.Content[k] = fp
		}
	}
	data, _ := json.Marshal(f)
	if err := os.WriteFile(lyricsPinsPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	lyricsPinsMu.Lock()
	lyricsPinsRead = false
	lyricsPinsMu.Unlock()
}

// 组里钉着的写法、校准正对着它现在这份歌词的,组里其余写法跟着用这一份;校准对着别的歌词的、两份不同的校准、实体里有手改的
// 都不跟。跟着换过来的写法后台不再自动换词,开关关掉就不护着、按留底恢复。组里有校准的都不搜。
func TestSharePinnedPass(t *testing.T) {
	p1, p5 := songShareLRC("p1"), songShareLRC("p5")
	entries := map[string]enrichEntry{
		"P|Song|One":   {DurationSecs: 200, ISRCs: []string{"USAAA1100010"}, Lyrics: p1, LyricsSource: "qq"},
		"P|Song|Two":   {DurationSecs: 200.1, ISRCs: []string{"USAAA1100010"}, Lyrics: songShareLRC("p2"), LyricsSource: "kugou"},
		"P|Song|Three": {DurationSecs: 200.2, ISRCs: []string{"USAAA1100010"}},
		"P|Song|Four":  {DurationSecs: 200.3, ISRCs: []string{"USAAA1100010"}, Instrumental: true},
		"P|Song|Five":  {DurationSecs: 200.4, ISRCs: []string{"USAAA1100010"}, Lyrics: p5, LyricsYRC: "[0,500]w", LyricsSource: "netease"},
		"P|Song|Six":   {DurationSecs: 200.5, ISRCs: []string{"USAAA1100010"}, Lyrics: songShareLRC("p6"), LyricsSource: "kuwo"},
		"Q|Tune|One":   {DurationSecs: 180, ISRCs: []string{"USAAA1100011"}, Lyrics: songShareLRC("q1"), LyricsSource: "qq"},
		"Q|Tune|Two":   {DurationSecs: 180.1, ISRCs: []string{"USAAA1100011"}, Lyrics: songShareLRC("q2"), LyricsSource: "kuwo"},
		"R|Air|One":    {DurationSecs: 150, ISRCs: []string{"USAAA1100012"}, Lyrics: songShareLRC("r1"), LyricsSource: "qq"},
		"R|Air|Two":    {DurationSecs: 150.1, ISRCs: []string{"USAAA1100012"}, Lyrics: songShareLRC("r2"), LyricsSource: "kuwo"},
		"R|Air|Three":  {DurationSecs: 150.2, ISRCs: []string{"USAAA1100012"}, Lyrics: songShareLRC("r3"), LyricsSource: "kugou"},
		"M|Hit|One":    {DurationSecs: 120, ISRCs: []string{"USAAA1100013"}, Lyrics: songShareLRC("m1"), LyricsSource: "manual", ManualLyrics: true},
		"M|Hit|Two":    {DurationSecs: 120.1, ISRCs: []string{"USAAA1100013"}, Lyrics: songShareLRC("m2"), LyricsSource: "qq"},
		"M|Hit|Three":  {DurationSecs: 120.2, ISRCs: []string{"USAAA1100013"}, Lyrics: songShareLRC("m3"), LyricsSource: "kuwo"},
		"N|Two|One":    {DurationSecs: 110, ISRCs: []string{"USAAA1100014"}, Lyrics: songShareLRC("n1"), LyricsSource: "manual", ManualLyrics: true},
		"N|Two|Two":    {DurationSecs: 110.1, ISRCs: []string{"USAAA1100014"}, Lyrics: songShareLRC("n2"), LyricsSource: "manual", ManualLyrics: true},
		"N|Two|Three":  {DurationSecs: 110.2, ISRCs: []string{"USAAA1100014"}, Lyrics: songShareLRC("n3"), LyricsSource: "qq"},
		"N|Two|Four":   {DurationSecs: 110.3, ISRCs: []string{"USAAA1100014"}, Lyrics: songShareLRC("n4"), LyricsSource: "kuwo"},
		"E|Mt|One":     {DurationSecs: 100, ISRCs: []string{"USAAA1100015"}, Lyrics: songShareLRC("e1"), LyricsSource: "qq"},
		"E|Mt|Two":     {DurationSecs: 100.1, ISRCs: []string{"USAAA1100015"}},
	}
	setUpSongShareTest(t, entries, true)
	fp1 := songOffsetFingerprint(p1, "")
	writeSongSharePins(t, map[string]string{
		"P|Song|One":  fp1,
		"Q|Tune|One":  "0123456789ab",
		"R|Air|One":   songOffsetFingerprint(songShareLRC("r1"), ""),
		"R|Air|Two":   songOffsetFingerprint(songShareLRC("r2"), ""),
		"M|Hit|Two":   songOffsetFingerprint(songShareLRC("m2"), ""),
		"P|Song|Six":  "0123456789ab",
		"N|Two|Three": songOffsetFingerprint(songShareLRC("n3"), ""),
		"E|Mt|One":    "",
	})
	savedSearch := searchShareRound
	t.Cleanup(func() { searchShareRound = savedSearch })
	var searched []string
	searchShareRound = func(_ context.Context, key, _, _, _ string, _ float64) songShareRound {
		searched = append(searched, key)
		return songShareRound{reached: true}
	}
	ctx := context.Background()
	runSongEntitySharePass(ctx, rebuildSongEntityTable(time.Now()))

	if len(searched) != 0 {
		t.Errorf("组里有校准的都不搜: %v", searched)
	}
	for _, k := range []string{"P|Song|Two", "P|Song|Three"} {
		got, _ := cacheEntry(t, k)
		if got.Lyrics != p1 || got.LyricsSource != "qq" || got.ManualLyrics || got.LyricsEntityOrigin != "" {
			t.Errorf("%s 跟着校准那份: %+v", k, got)
		}
		if ap := got.LyricsDecisionApplied; ap == nil || ap.Path != lyricsDecisionPathSongEntityShare || ap.ReusedFrom != "P|Song|One" {
			t.Errorf("%s 的出处: %+v", k, ap)
		}
		if p, _ := readPreEntry(t, k); p.Synced != fp1 {
			t.Errorf("%s 的留底: %+v", k, p)
		}
	}
	for k, why := range map[string]string{
		"P|Song|One": "钉着的那条", "P|Song|Four": "纯音乐", "P|Song|Five": "有逐字", "Q|Tune|Two": "校准对着别的歌词",
		"R|Air|Three": "两份不同的校准", "M|Hit|Two": "钉着", "P|Song|Six": "自己钉着、校准对着别的歌词",
		"N|Two|Four": "两份手改不替用户选,校准那组也不跟", "E|Mt|Two": "钉着的没记校准对着哪份歌词",
	} {
		if got, _ := cacheEntry(t, k); got.Lyrics != entries[k].Lyrics || hasPre(k) {
			t.Errorf("%s(%s)不动: %+v", k, why, got)
		}
	}
	if got, _ := cacheEntry(t, "M|Hit|Three"); got.Lyrics != songShareLRC("m1") || got.LyricsEntityOrigin != "M|Hit|One" {
		t.Errorf("实体里有手改时跟手改: %+v", got)
	}

	enrichMu.Lock()
	calibrated := map[string]bool{}
	for k := range entries {
		calibrated[k] = lyricsCalibratedLocked(k)
	}
	enrichMu.Unlock()
	for k, want := range map[string]bool{
		"P|Song|One": true, "P|Song|Two": true, "P|Song|Three": true, "P|Song|Five": false, "Q|Tune|One": true,
		"Q|Tune|Two": false, "R|Air|One": true, "R|Air|Three": false, "E|Mt|Two": false,
	} {
		if calibrated[k] != want {
			t.Errorf("%s 算不算校准过: %v", k, calibrated[k])
		}
	}
	if got := lyricsFullScanCandidates(); slices.Contains(got, "P|Song|Two") || !slices.Contains(got, "P|Song|Five") {
		t.Errorf("全量扫库不碰读穿着校准的写法: %v", got)
	}

	runSongEntitySharePass(ctx, rebuildSongEntityTable(time.Now()))
	if got, _ := cacheEntry(t, "P|Song|Two"); got.Lyrics != p1 {
		t.Errorf("再跑一轮不变: %+v", got)
	}

	setFeatures(featureFlags{SongEntityShadow: true})
	enrichMu.Lock()
	held := lyricsCalibratedLocked("P|Song|Two")
	enrichMu.Unlock()
	if held {
		t.Error("开关关着时只认自己钉着的")
	}
	songEntityShareStep(ctx, nil)
	if got, _ := cacheEntry(t, "P|Song|Two"); got.Lyrics != songShareLRC("p2") || got.LyricsSource != "kugou" {
		t.Errorf("关掉之后恢复: %+v", got)
	}
	if got, _ := cacheEntry(t, "P|Song|Three"); got.Lyrics != "" {
		t.Errorf("补上的恢复成没词: %+v", got)
	}
}

// 跟着校准换词写回前持锁核对:建表之后校准那条的歌词变了,整组不动;某条写法的歌词变了,只跳过它。
func TestSharePinnedGroupLiveChecks(t *testing.T) {
	p1 := songShareLRC("p1")
	entries := map[string]enrichEntry{
		"P|Song|One":   {Song: "s", Lyrics: p1, LyricsSource: "qq"},
		"P|Song|Two":   {Song: "s", Lyrics: songShareLRC("p2"), LyricsSource: "kugou"},
		"P|Song|Three": {Song: "s", Lyrics: songShareLRC("p3"), LyricsSource: "kuwo"},
		"P|Song|Four":  {Song: "s"},
		"P|Song|Five":  {Song: "s", Lyrics: songShareLRC("p5"), LyricsSource: "qq"},
		"P|Song|Six":   {Song: "s", Lyrics: songShareLRC("p6"), LyricsSource: "qq"},
		"P|Song|Seven": {Song: "s", Lyrics: songShareLRC("p7"), LyricsSource: "qq"},
	}
	setUpSongShareTest(t, entries, true)
	var vs []songVariant
	for k, e := range entries {
		vs = append(vs, songTestVariant(k, e, nil))
	}
	b, _ := songTestBuild(t, vs, nil)
	ms := make([]int, len(b.variants))
	own := make([]*songPlanLyrics, len(b.variants))
	for i := range b.variants {
		ms[i], own[i] = i, b.songPlanLyricsOf(i, nil)
	}
	pins := map[string]bool{"P|Song|One": true, "P|Song|Seven": true}
	content := map[string]string{"P|Song|One": songOffsetFingerprint(p1, "")}
	edit := func(k string, f func(*enrichEntry)) {
		enrichMu.Lock()
		e := enrichCache[k]
		f(&e)
		enrichCache[k] = e
		enrichMu.Unlock()
	}
	setLyrics := func(k, lyrics string) { edit(k, func(e *enrichEntry) { e.Lyrics = lyrics }) }
	now := time.Unix(5_000_000, 0)

	setLyrics("P|Song|One", songShareLRC("p1b"))
	if changed, _, _ := b.sharePinnedGroup(ms, own, pins, content, now); len(changed) != 0 {
		t.Fatalf("校准那条的歌词在建表之后变了,整组不动: %v", changed)
	}
	setLyrics("P|Song|One", p1)
	edit("P|Song|One", func(e *enrichEntry) { e.ManualLyrics = true })
	if changed, _, _ := b.sharePinnedGroup(ms, own, pins, content, now); len(changed) != 0 {
		t.Fatalf("校准那条在建表之后改成了手改,交给手改同步: %v", changed)
	}
	edit("P|Song|One", func(e *enrichEntry) { e.ManualLyrics = false })
	setLyrics("P|Song|Three", songShareLRC("p3b"))
	setLyrics("P|Song|Four", songShareLRC("p4"))
	edit("P|Song|Five", func(e *enrichEntry) { e.ManualLyrics = true })
	edit("P|Song|Six", func(e *enrichEntry) { e.ManualPickSHA = manualPickFingerprint(e.Lyrics) })
	if changed, _, _ := b.sharePinnedGroup(ms, own, pins, content, now); !slices.Equal(changed, []string{"P|Song|Two"}) {
		t.Fatalf("建表之后歌词变过、改成手改或采纳、钉住的写法这一轮跳过: %v", changed)
	}
	if got, _ := cacheEntry(t, "P|Song|Three"); got.Lyrics != songShareLRC("p3b") || hasPre("P|Song|Three") {
		t.Errorf("跳过的不动: %+v", got)
	}
}

// 后台自动换词的几道闸认读穿来的校准(lyricsCalibratedLocked):播放时起的重试 / 重评、全量扫库逐条那一步。
func TestLyricsCalibratedGatesWired(t *testing.T) {
	for file, needles := range map[string][]string{
		"enrich.go": {"\t\tpinned := lyricsCalibratedLocked(key)\n"},
		"lyricsfullscan.go": {
			"\tcalibrated := pins[key] || songShareCalibrationsLocked(pins, content).holds(before)\n\tenrichMu.Unlock()\n",
			"\tif calibrated {\n\t\treturn lyricsSweepOutcome{skipped: true}\n\t}\n",
			"lyricsFullScanTier(e, pins[key] || calibrated.holds(e), false, passStart)",
		},
	} {
		src := string(mustRead(t, file))
		for _, n := range needles {
			if !strings.Contains(src, n) {
				t.Errorf("%s 里少了: %q", file, n)
			}
		}
	}
}

// 没有实体 id 的写法不读穿,也就不护着跟它歌词相同的写法。
func TestSongShareCalibrationsNeedEntity(t *testing.T) {
	x := songShareLRC("x")
	setUpSongShareTest(t, map[string]enrichEntry{"X|A|1": {Lyrics: x}, "X|A|2": {Lyrics: x}}, true)
	writeSongSharePins(t, map[string]string{"X|A|1": songOffsetFingerprint(x, "")})
	enrichMu.Lock()
	own, other := lyricsCalibratedLocked("X|A|1"), lyricsCalibratedLocked("X|A|2")
	enrichMu.Unlock()
	if !own || other {
		t.Errorf("自己钉着的算、没有实体 id 的同词写法不算: %v %v", own, other)
	}
}

// 读穿按整首歌算:别的共享组里一条写法的歌词正是校准对着的那份,后台不换它,按共享组重搜时也留着,同组别的写法照换。
func TestSharePassKeepsInheritedCalibration(t *testing.T) {
	words := songTestWords("inherit", 30)
	lrc, other, champ := songTestLRC(1000, words), songShareLRC("other"), songShareLRC("champ")
	ne := "https://music.163.com/song?id=42"
	reg := map[string]string{"netease_song:42": "Tune"}
	entries := map[string]enrichEntry{
		"Singer|Tune|One":   {Song: "s", NeteaseURL: ne, Lyrics: lrc, LyricsSource: "qq"},
		"Singer|Tune|Two":   {Song: "s", DurationSecs: 300, NeteaseURL: ne, ISRCs: []string{"HKA351501001"}, Lyrics: lrc, LyricsSource: "qq"},
		"Singer|Tune|Three": {Song: "s", DurationSecs: 300.1, ISRCs: []string{"HKA351501001"}, Lyrics: other, LyricsSource: "kugou"},
	}
	setUpSongShareTest(t, entries, true)
	writeSongSharePins(t, map[string]string{"Singer|Tune|One": songOffsetFingerprint(lrc, "")})
	var vs []songVariant
	for k, e := range entries {
		vs = append(vs, songTestVariant(k, e, reg))
	}
	b, _ := songTestBuild(t, vs, nil)
	idx := map[string]int{}
	for i, v := range b.variants {
		idx[v.key] = i
	}
	if b.shareOf[idx["Singer|Tune|One"]] == b.shareOf[idx["Singer|Tune|Two"]] || b.shareOf[idx["Singer|Tune|Two"]] != b.shareOf[idx["Singer|Tune|Three"]] {
		t.Fatalf("前提: One 单独一组, Two、Three 一组: %v", b.shareOf)
	}
	enrichMu.Lock()
	held := lyricsCalibratedLocked("Singer|Tune|Two")
	enrichMu.Unlock()
	if !held {
		t.Error("别的共享组里校准对着的那份歌词也护着")
	}
	saved := searchShareRound
	t.Cleanup(func() { searchShareRound = saved })
	searchShareRound = func(_ context.Context, key, artist, title, album string, dur float64) songShareRound {
		return songShareRound{shareEvalRound: shareEvalRound{Key: key, Artist: artist, Title: title, Album: album, Duration: dur,
			Scored: []scoredLyricCandidateResult{
				{Source: "netease", Lyrics: champ, Score: 1200},
				{Source: "qq", Lyrics: lrc, Score: 900},
				{Source: "kugou", Lyrics: other, Score: 800},
			}}, reached: true}
	}
	runSongEntitySharePass(context.Background(), b)
	if got, _ := cacheEntry(t, "Singer|Tune|Two"); got.Lyrics != lrc || hasPre("Singer|Tune|Two") {
		t.Errorf("读穿着校准的留着: %+v", got)
	}
	if got, _ := cacheEntry(t, "Singer|Tune|Three"); got.Lyrics != champ {
		t.Errorf("同组别的写法照换: %+v", got)
	}
}
