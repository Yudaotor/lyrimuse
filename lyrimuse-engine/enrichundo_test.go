package main

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// setUpEnrichUndoTest:编辑通道的临时环境,配置目录(导入库、同步留底)也放进去;先存一次盘、导出一次,之后比对的「采纳之前」
// 就是盘上已经落定的样子。返回整棵数据目录的根。
func setUpEnrichUndoTest(t *testing.T, entries map[string]enrichEntry, sharing bool) string {
	t.Helper()
	lyrics, _ := setUpEnrichEditTest(t, entries)
	root := filepath.Dir(lyrics)
	cfg := filepath.Join(root, "cfg")
	if err := os.MkdirAll(cfg, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LYRIMUSE_CONFIG_DIR", cfg)
	if sharing {
		setFeatures(featureFlags{SongEntityShadow: true, SongEntityShareLyrics: true, LyricsAutoUpgrade: true})
		savedPins, savedInflight := lyricsPinsPath, enrichInflight
		t.Cleanup(func() { lyricsPinsPath, enrichInflight = savedPins, savedInflight })
		lyricsPinsPath = filepath.Join(cfg, "pins.json")
		enrichInflight = map[string]bool{}
	}
	savedUndos, savedNow := enrichUndos, enrichUndoNow
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichUndos = savedUndos
		enrichMu.Unlock()
		enrichUndoNow = savedNow
	})
	enrichMu.Lock()
	enrichUndos = map[string]*enrichUndoRecord{}
	enrichDirty = true
	enrichMu.Unlock()
	if err := saveEnrichCacheChecked(); err != nil {
		t.Fatal(err)
	}
	exportLyricsFiles()
	return root
}

// undoTree:root 下全部文件的内容(废纸篓、整份格式的一次性备份除外)。
func undoTree(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if d.IsDir() {
			if rel == "home" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(rel, ".full-format.bak") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		out[rel] = string(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func diffUndoTree(t *testing.T, label string, before, after map[string]string) {
	t.Helper()
	var keys []string
	for k := range before {
		keys = append(keys, k)
	}
	for k := range after {
		if _, ok := before[k]; !ok {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		b, inB := before[k]
		a, inA := after[k]
		switch {
		case !inA:
			t.Errorf("%s: %s 没放回来", label, k)
		case !inB:
			t.Errorf("%s: 多出 %s", label, k)
		case a != b:
			t.Errorf("%s: %s 跟采纳之前不一样\n之前 %q\n之后 %q", label, k, b, a)
		}
	}
}

func undoEntryJSON(t *testing.T, key string) string {
	t.Helper()
	e, ok := cacheEntry(t, key)
	if !ok {
		return "<absent>"
	}
	data, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func adoptUndoable(key, lyrics, source string) enrichEditResult {
	return applyEnrichEdit(enrichEditRequest{ID: "a", Op: "save_edit", Key: key, Lyrics: lyrics, Tr: "[00:01.00]译文",
		YRC: strPtr("[1000,800](1000,800,0)新"), Source: source, SourceChoice: strPtr(""), FromManualPick: true,
		BG: strPtr(""), TrLang: strPtr("zh-Hans"), Undoable: true})
}

func undoEdit(id string) enrichEditResult {
	return applyEnrichEdit(enrichEditRequest{ID: "u", Op: "undo_edit", UndoID: id})
}

// 采纳 → 撤销:普通自动匹配的、手改过的、缓存里还没有的,条目序列化和整棵数据目录(主缓存、正文小文件、歌词文件)跟采纳之前逐字节一致。
func TestUndoAdoptRestoresEverything(t *testing.T) {
	auto := enrichKey("Undo Artist", "Auto Song", "Album")
	hand := enrichKey("Undo Artist", "Hand Song", "Album")
	fresh := enrichKey("Undo Artist", "Fresh Song", "Album")
	other := enrichKey("Undo Artist", "Other Song", "Album")
	root := setUpEnrichUndoTest(t, map[string]enrichEntry{
		auto: {TS: 100, Lyrics: bt("[00:01.00]自动"), LyricsTr: bt("[00:01.00]auto tr"), LyricsTrLang: "en", LyricsTrSource: "machine",
			TranslationTS: 5, LyricsRoma: bt("[00:01.00]zi dong"), LyricsSource: "qq", LyricsScore: 420, LyricsKana: "[00:01.00]x",
			LyricsKanaChecked: 2, LyricsDecisionApplied: &lyricsDecision{Path: lyricsDecisionPathRescore, Winner: "qq"}},
		hand:  {TS: 100, Lyrics: bt("[00:01.00]我改过的"), LyricsSource: "manual", ManualLyrics: true, LyricsYRC: bt("[1000,500](1000,500,0)我")},
		other: {TS: 100, Lyrics: bt("[00:01.00]别的歌"), LyricsSource: "kugou"},
	}, false)
	for _, key := range []string{auto, hand, fresh} {
		before, beforeJSON := undoTree(t, root), undoEntryJSON(t, key)
		res := adoptUndoable(key, "[00:01.00]新", "netease")
		if !res.OK || res.UndoID == "" {
			t.Fatalf("%s 采纳: %+v", key, res)
		}
		if undoEntryJSON(t, key) == beforeJSON {
			t.Fatalf("%s 采纳没生效", key)
		}
		if res := undoEdit(res.UndoID); !res.OK || res.Changed != 1 {
			t.Fatalf("%s 撤销: %+v", key, res)
		}
		if got := undoEntryJSON(t, key); got != beforeJSON {
			t.Errorf("%s 条目:\n之前 %s\n之后 %s", key, beforeJSON, got)
		}
		after := undoTree(t, root)
		if key == fresh {
			// 之前没有的这条跟「删除」一样只删条目和歌词文件:它的正文小文件留到下次启动由 sweepKeyedDir 清掉。
			orphan := filepath.Join(filepath.Base(enrichBodiesDir()), filepath.Base(bodySidePath(enrichBodiesDir(), key)))
			if _, ok := after[orphan]; !ok {
				t.Errorf("没找到这条的正文小文件 %s,换了位置要改这里", orphan)
			}
			delete(after, orphan)
		}
		diffUndoTree(t, key, before, after)
	}
}

// 导入的版本:采纳别的歌词作废导入库里按 key 存的和按身份存的两份,撤销后记录文件、index.json 逐字节放回,选词又认得出这份。
func TestUndoAdoptRestoresImportedLyrics(t *testing.T) {
	key := enrichKey("Imp Artist", "Imp Song", "Imp Album")
	root := setUpEnrichUndoTest(t, map[string]enrichEntry{
		key: {TS: 100, Lyrics: bt("[00:01.00]导入的"), LyricsSource: importLyricsSource},
	}, false)
	keep := importedLyricsRecord{Identities: []importedIdentity{{Artist: "Someone", Title: "Imp Song"}}, Lyrics: "[00:01.00]别人的", ImportedAt: 7}
	if err := saveImportedLyrics(
		importedLyricsRecord{Key: key, Lyrics: "[00:01.00]导入的", Tr: "[00:01.00]tr", Files: []string{"/x/a.lrc"}, ImportedAt: 9},
		importedLyricsRecord{Identities: []importedIdentity{{Artist: "Imp Artist", Title: "Imp Song"}}, Lyrics: "[00:01.00]按身份", ImportedAt: 8},
		keep,
	); err != nil {
		t.Fatal(err)
	}
	before, beforeJSON := undoTree(t, root), undoEntryJSON(t, key)
	res := adoptUndoable(key, "[00:01.00]换掉", "qq")
	if !res.OK {
		t.Fatalf("采纳: %+v", res)
	}
	if _, ok := importedLyricsRecordFor(key); ok {
		t.Fatal("采纳别的歌词应作废导入库里那份")
	}
	if _, ok := importedLyricsRecordBySong("Imp Artist", "Imp Song", 0); ok {
		t.Fatal("按身份存的那份也应作废")
	}
	if res := undoEdit(res.UndoID); !res.OK {
		t.Fatalf("撤销: %+v", res)
	}
	if got := undoEntryJSON(t, key); got != beforeJSON {
		t.Errorf("条目:\n之前 %s\n之后 %s", beforeJSON, got)
	}
	diffUndoTree(t, "导入", before, undoTree(t, root))
	if rec, ok := importedLyricsRecordFor(key); !ok || rec.Tr != "[00:01.00]tr" {
		t.Errorf("按 key 存的那份要认得出: %+v", rec)
	}
	if _, ok := importedLyricsRecordBySong("Imp Artist", "Imp Song", 0); !ok {
		t.Error("按身份存的那份要认得出")
	}
}

// 歌曲实体同步开着:采纳同步到同组写法、新建 / 改了留底;撤销把同组写法、留底一起放回,整棵目录逐字节一致。
func TestUndoAdoptRestoresShareGroup(t *testing.T) {
	const a, b, c, d = "X|Undo|A", "X|Undo|B", "X|Undo|C", "X|Undo|D"
	root := setUpEnrichUndoTest(t, map[string]enrichEntry{
		a: {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("a")), LyricsSource: "qq"},
		b: {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("b")), LyricsYRC: bt("[0,500]b"), LyricsSource: "kugou", LyricsScore: 900},
		c: {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("c")), LyricsSource: "netease"},
		d: {Song: "s2", TS: 1, Lyrics: bt(songShareLRC("d")), LyricsSource: "qq"},
	}, true)
	// c 之前被同步过一次:留底已经在,采纳只改它的 synced。
	enrichMu.Lock()
	ec := enrichCache[c]
	enrichMu.Unlock()
	if _, err := writeSongSharePre(c, ec, "old", time.Unix(5, 0)); err != nil {
		t.Fatal(err)
	}
	before := undoTree(t, root)
	beforeJSON := map[string]string{}
	for _, k := range []string{a, b, c, d} {
		beforeJSON[k] = undoEntryJSON(t, k)
	}
	picked := songShareLRC("picked")
	res := applyEnrichEdit(enrichEditRequest{ID: "p", Op: "save_edit", Key: a, Lyrics: picked, Source: "qq", FromManualPick: true,
		YRC: strPtr(""), Undoable: true})
	if !res.OK || res.Changed != 3 {
		t.Fatalf("采纳(b、c 跟着同步): %+v", res)
	}
	if got, _ := cacheEntry(t, b); !got.Lyrics.EqualString(picked) || got.LyricsEntityOrigin != a || !hasPre(b) {
		t.Fatalf("b 应跟着同步: %+v", got)
	}
	if res := undoEdit(res.UndoID); !res.OK || res.Changed != 1 {
		t.Fatalf("撤销: %+v", res)
	}
	for _, k := range []string{a, b, c, d} {
		if got := undoEntryJSON(t, k); got != beforeJSON[k] {
			t.Errorf("%s 条目:\n之前 %s\n之后 %s", k, beforeJSON[k], got)
		}
	}
	diffUndoTree(t, "同步", before, undoTree(t, root))
}

// 纯文本采纳也能撤。
func TestUndoPlainTextAdopt(t *testing.T) {
	key := enrichKey("Plain", "Song", "Album")
	root := setUpEnrichUndoTest(t, map[string]enrichEntry{key: {TS: 1, Lyrics: bt("[00:01.00]有"), LyricsSource: "qq", Instrumental: false}}, false)
	before, beforeJSON := undoTree(t, root), undoEntryJSON(t, key)
	res := applyEnrichEdit(enrichEditRequest{Op: "save_plain_text", Key: key, PlainLyrics: "纯文本", PlainLyricsSource: "lrclib", Undoable: true})
	if !res.OK || res.UndoID == "" {
		t.Fatalf("采纳: %+v", res)
	}
	if res := undoEdit(res.UndoID); !res.OK {
		t.Fatalf("撤销: %+v", res)
	}
	if got := undoEntryJSON(t, key); got != beforeJSON {
		t.Errorf("条目:\n之前 %s\n之后 %s", beforeJSON, got)
	}
	diffUndoTree(t, "纯文本", before, undoTree(t, root))
}

// 采纳之后这首被别的改动动过(又存了一次、后台换了正文、同组写法被改)、这首又导入了一次:拒绝,一个字都不改。
// 只是机翻补上了译文:照常撤。不带 undoable 的保存不发 undo_id。
func TestUndoRefusesWhenChangedAfterAdopt(t *testing.T) {
	key := enrichKey("Ch", "Song", "Album")
	setUpEnrichUndoTest(t, map[string]enrichEntry{key: {TS: 1, Lyrics: bt("[00:01.00]原来"), LyricsSource: "qq"}}, false)
	if res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: key, Lyrics: "[00:01.00]x", Source: "qq"}); !res.OK || res.UndoID != "" {
		t.Fatalf("不带 undoable 不发 undo_id: %+v", res)
	}

	res := adoptUndoable(key, "[00:01.00]采纳", "netease")
	applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: key, Lyrics: "[00:01.00]又改", Source: "manual", MarkManual: true})
	after := undoEntryJSON(t, key)
	if res := undoEdit(res.UndoID); res.OK || res.ErrorCode != enrichUndoErrChanged {
		t.Fatalf("又存过一次要拒绝: %+v", res)
	}
	if undoEntryJSON(t, key) != after {
		t.Error("拒绝时不该改条目")
	}

	// 用户在歌词管理里只改了译文(歌词选择没变):照样算动过,改动序号挡住。
	res = adoptUndoable(key, "[00:01.00]采纳", "netease")
	applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: key, Lyrics: "[00:01.00]采纳", Tr: "[00:01.00]手改译文",
		YRC: strPtr("[1000,800](1000,800,0)新"), Source: "netease", FromManualPick: true})
	if res := undoEdit(res.UndoID); res.OK || res.ErrorCode != enrichUndoErrChanged {
		t.Fatalf("只改了译文也要拒绝: %+v", res)
	}

	res = adoptUndoable(key, "[00:01.00]采纳", "netease")
	enrichMu.Lock()
	e := enrichCache[key]
	e.Lyrics = bt("[00:01.00]后台换的")
	enrichCache[key] = e
	enrichMu.Unlock()
	if res := undoEdit(res.UndoID); res.OK || res.ErrorCode != enrichUndoErrChanged {
		t.Fatalf("正文被换过要拒绝: %+v", res)
	}

	beforeJSON := undoEntryJSON(t, key)
	res = adoptUndoable(key, "[00:01.00]采纳", "netease")
	enrichMu.Lock()
	e = enrichCache[key]
	e.LyricsTr, e.LyricsTrSource, e.TranslationTS = bt("[00:01.00]机翻"), "machine", 99
	enrichCache[key] = e
	enrichMu.Unlock()
	if res := undoEdit(res.UndoID); !res.OK {
		t.Fatalf("只补了译文照常撤: %+v", res)
	}
	if got := undoEntryJSON(t, key); got != beforeJSON {
		t.Errorf("条目:\n之前 %s\n之后 %s", beforeJSON, got)
	}

	if err := saveImportedLyrics(importedLyricsRecord{Key: key, Lyrics: "[00:01.00]导入一", ImportedAt: 1}); err != nil {
		t.Fatal(err)
	}
	res = adoptUndoable(key, "[00:01.00]采纳", "netease")
	if err := saveImportedLyrics(importedLyricsRecord{Key: key, Lyrics: "[00:01.00]导入二", ImportedAt: 2}); err != nil {
		t.Fatal(err)
	}
	if res := undoEdit(res.UndoID); res.OK || res.ErrorCode != enrichUndoErrChanged {
		t.Fatalf("又导入了一次要拒绝: %+v", res)
	}
	if rec, _ := importedLyricsRecordFor(key); rec.Lyrics != "[00:01.00]导入二" {
		t.Errorf("新导入的那份不该被冲掉: %+v", rec)
	}
}

func TestUndoRefusesSharedCopyChanged(t *testing.T) {
	const a, b = "X|UndoC|A", "X|UndoC|B"
	setUpEnrichUndoTest(t, map[string]enrichEntry{
		a: {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("a")), LyricsSource: "qq"},
		b: {Song: "s1", TS: 1, Lyrics: bt(songShareLRC("b")), LyricsSource: "kugou"},
	}, true)
	res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: a, Lyrics: songShareLRC("p"), Source: "qq", FromManualPick: true, YRC: strPtr(""), Undoable: true})
	if !res.OK {
		t.Fatal(res)
	}
	applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: b, Lyrics: songShareLRC("mine"), Source: "manual", MarkManual: true, YRC: strPtr("")})
	if res := undoEdit(res.UndoID); res.OK || res.ErrorCode != enrichUndoErrChanged {
		t.Fatalf("同组写法改过要拒绝: %+v", res)
	}
	if got, _ := cacheEntry(t, a); !got.Lyrics.EqualString(songShareLRC("p")) {
		t.Errorf("拒绝时原件不动: %+v", got)
	}
}

// 过期、不认识的 id、撤过一次的都拒绝,错误码 undo_expired;清空 / 从快照恢复之后也撤不了。
func TestUndoExpiredAndSingleUse(t *testing.T) {
	key := enrichKey("Ex", "Song", "Album")
	setUpEnrichUndoTest(t, map[string]enrichEntry{key: {TS: 1, Lyrics: bt("[00:01.00]原来"), LyricsSource: "qq"}}, false)
	now := time.Unix(1_000_000, 0)
	enrichUndoNow = func() time.Time { return now }

	res := adoptUndoable(key, "[00:01.00]采纳", "netease")
	now = now.Add(enrichUndoTTL + time.Second)
	if res := undoEdit(res.UndoID); res.OK || res.ErrorCode != enrichUndoErrExpired {
		t.Fatalf("过期要拒绝: %+v", res)
	}
	if res := undoEdit("nope"); res.OK || res.ErrorCode != enrichUndoErrExpired {
		t.Fatalf("不认识的 id: %+v", res)
	}

	res = adoptUndoable(key, "[00:01.00]再采纳", "netease")
	now = now.Add(enrichUndoTTL - time.Second)
	if r := undoEdit(res.UndoID); !r.OK {
		t.Fatalf("时限之内能撤: %+v", r)
	}
	if r := undoEdit(res.UndoID); r.OK || r.ErrorCode != enrichUndoErrExpired {
		t.Fatalf("只能撤一次: %+v", r)
	}

	res = adoptUndoable(key, "[00:01.00]三采纳", "netease")
	applyEnrichEdit(enrichEditRequest{Op: "clear_all"})
	if r := undoEdit(res.UndoID); r.OK || r.ErrorCode != enrichUndoErrChanged {
		t.Fatalf("清空之后撤不了: %+v", r)
	}

	enrichMu.Lock()
	enrichUndos = map[string]*enrichUndoRecord{}
	enrichMu.Unlock()
	for i := 0; i < enrichUndoMax+3; i++ {
		applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: key, Lyrics: "[00:01.00]n", Source: "qq", Undoable: true})
	}
	enrichMu.Lock()
	n := len(enrichUndos)
	enrichMu.Unlock()
	if n != enrichUndoMax {
		t.Errorf("最多留 %d 份,留了 %d", enrichUndoMax, n)
	}
}

// 并发:撤销跟别的歌的保存、存盘同时跑,同一个 id 同时撤两次只成一次,结果跟采纳之前一样。
func TestUndoConcurrentWithOtherEdits(t *testing.T) {
	key := enrichKey("Co", "Song", "Album")
	entries := map[string]enrichEntry{key: {TS: 1, Lyrics: bt("[00:01.00]原来"), LyricsSource: "qq"}}
	for i := 0; i < 8; i++ {
		entries[enrichKey("Co", "Other "+string(rune('a'+i)), "Album")] = enrichEntry{TS: 1, Lyrics: bt("[00:01.00]o"), LyricsSource: "qq"}
	}
	setUpEnrichUndoTest(t, entries, false)
	beforeJSON := undoEntryJSON(t, key)
	res := adoptUndoable(key, "[00:01.00]采纳", "netease")
	var wg sync.WaitGroup
	oks := make(chan bool, 2)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			k := enrichKey("Co", "Other "+string(rune('a'+i)), "Album")
			if r := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: k, Lyrics: "[00:01.00]并发", Source: "qq", Undoable: true}); !r.OK {
				t.Errorf("并发保存: %+v", r)
			}
			_ = saveEnrichCacheChecked()
		}(i)
	}
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			oks <- undoEdit(res.UndoID).OK
		}()
	}
	wg.Wait()
	close(oks)
	n := 0
	for ok := range oks {
		if ok {
			n++
		}
	}
	if n != 1 {
		t.Errorf("同一个 id 撤两次应只成一次,成了 %d 次", n)
	}
	if got := undoEntryJSON(t, key); got != beforeJSON {
		t.Errorf("条目:\n之前 %s\n之后 %s", beforeJSON, got)
	}
	for i := 0; i < 8; i++ {
		if got, _ := cacheEntry(t, enrichKey("Co", "Other "+string(rune('a'+i)), "Album")); got.Lyrics.String() != "[00:01.00]并发" {
			t.Errorf("别的歌的保存不受影响: %+v", got)
		}
	}
}

// 「自动写入歌曲文件」开着:撤销之后下一拍按放回去的歌词把文件再写一次(跟采纳之后同一条路)。
func TestUndoAdoptAutoWritebackRewritesFile(t *testing.T) {
	const artist, title, album = "周杰伦", "晴天", "叶惠美"
	key := enrichKey(artist, title, album)
	setUpAutoWriteback(t, map[string]enrichEntry{key: {Lyrics: bt(writebackLRC), TS: 1, LyricsSource: "qq"}})
	path := writeTemp(t, "song.mp3", writebackAudio(3000))
	playLocalFile(reampBundleID, artist, title, album, path)
	if got := autoWritebackLyricsOnce(); got != autoWBWritten {
		t.Fatalf("采纳之前: %s", got)
	}
	res := adoptUndoable(key, "[00:01.00]采纳的", "netease")
	if got := autoWritebackLyricsOnce(); got != autoWBWritten || !strings.Contains(readLocalFileTags(path).lyrics, "采纳的") {
		t.Fatalf("采纳之后写进文件: %s", got)
	}
	if r := undoEdit(res.UndoID); !r.OK {
		t.Fatalf("撤销: %+v", r)
	}
	if got := autoWritebackLyricsOnce(); got != autoWBWritten {
		t.Fatalf("撤销之后再写一次: %s", got)
	}
	if got := readLocalFileTags(path).lyrics; got != writebackLRC {
		t.Errorf("文件里是放回去的歌词: %q", got)
	}
}

// 一次性子命令不发 undo_id:进程一退记录就没了。
func TestApplyEnrichEditCLIDropsUndoable(t *testing.T) {
	src, err := os.ReadFile("enrichedit.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func runApplyEnrichEditCLI(")
	if i < 0 || !containsCode(body[i:], "req.Undoable = false") || !bytes.Contains(src[i:], []byte("res := applyEnrichEdit(req)")) ||
		strings.Index(body[i:], "req.Undoable = false") > strings.Index(body[i:], "res := applyEnrichEdit(req)") {
		t.Error("apply-enrich-edit 子命令执行之前要把 undoable 关掉")
	}
}
