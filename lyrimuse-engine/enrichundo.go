package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"time"
)

// 单首歌词改动的撤销(见 11 章决策 177)。save_edit / save_plain_text 带 undoable 时,在 enrichMu 里把这一笔会动到的东西
// 改之前的样子整份留下(enrichUndoRecord),结果里回一个 undo_id;undo_edit 带着它把这首原样放回去:
//   - 这首和开着歌曲实体同步时同一个共享组里跟着改了的写法,整条条目(没有这条就删掉);
//   - 那几条写法的同步留底文件(lyrimuse-song-entity-pre/,同步时新建或改了 synced);
//   - 导入库里这首被作废的记录文件原文和索引项(dropImportedLyricsForSongCapturing)。
// 歌词文件、正文小文件按放回去的条目重新导出、重新落盘,不另存。
// 放回之前核对:这几条在那一笔之后没被改动序号记过(enrichEditedSinceLocked),歌词选择(enrichUndoSameChoice)也还是那一笔
// 写下的;导入库里那几份没有又存进来。对不上、过期、找不到一律拒绝,不做部分恢复。
// 记录只在常驻进程内存里:一次性的 apply-enrich-edit 子命令不发 undo_id。
// 别的入口要接撤销:请求带 undoable、op 在 applyEnrichEditLocked 里照 save_edit 那样 begin / finish 一份记录即可。

const (
	// enrichUndoTTL:undo_id 多久之后不再认。App 那边的「撤销」按钮比它早消失。
	enrichUndoTTL = 60 * time.Second
	// enrichUndoMax:内存里最多留几份撤销记录,多了丢最早的。
	enrichUndoMax = 16
)

// 撤销失败的错误码(enrichEditResult.ErrorCode),App 按它给一句原因。
const (
	enrichUndoErrExpired = "undo_expired"
	enrichUndoErrChanged = "undo_changed"
)

// enrichUndoNow 测试换成可拨的时钟。
var enrichUndoNow = time.Now

// enrichUndos:undo_id → 记录。由 enrichMu 保护。
var enrichUndos = map[string]*enrichUndoRecord{}

// enrichUndoSlot:一条写法在那一笔之前、之后的样子。
type enrichUndoSlot struct {
	existed bool
	before  enrichEntry
	after   enrichEntry
}

// enrichUndoFile:一个文件改之前的原文;known 为假时没读成(不是不存在),撤销时不碰它。
type enrichUndoFile struct {
	known   bool
	existed bool
	data    []byte
}

type enrichUndoRecord struct {
	key string
	at  time.Time
	// seq:那一笔记下改动序号之后的序号,核对「之后有没有被改过」用。
	seq      uint64
	slots    map[string]*enrichUndoSlot
	pre      map[string]enrichUndoFile
	imported importedLyricsUndo
}

func readEnrichUndoFile(path string) enrichUndoFile {
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		return enrichUndoFile{known: true, existed: true, data: data}
	case errors.Is(err, fs.ErrNotExist):
		return enrichUndoFile{known: true}
	}
	noteFileErr("read", path, err)
	return enrichUndoFile{}
}

// restore 把文件放回改之前的样子。
func (f enrichUndoFile) restore(path string) {
	if !f.known {
		return
	}
	if !f.existed {
		noteFileErr("remove", path, removeIfExists(path))
		return
	}
	noteFileErr("mkdir", filepath.Dir(path), os.MkdirAll(filepath.Dir(path), 0o700))
	noteFileErr("write", path, writeFileAtomic(path, f.data))
}

// beginEnrichUndoLocked:改 key 之前调,留下 key(sharing 时连同共享组里的全部写法)现在的条目和同步留底。调用方持 enrichMu。
func beginEnrichUndoLocked(key string, sharing bool) *enrichUndoRecord {
	rec := &enrichUndoRecord{key: key, at: enrichUndoNow(), slots: map[string]*enrichUndoSlot{}, pre: map[string]enrichUndoFile{}}
	keys := []string{key}
	if e, ok := enrichCache[key]; ok && sharing && e.Song != "" {
		for k, x := range enrichCache {
			if k != key && x.Song == e.Song && x.SongShare == e.SongShare {
				keys = append(keys, k)
			}
		}
	}
	for _, k := range keys {
		e, ok := enrichCache[k]
		rec.slots[k] = &enrichUndoSlot{existed: ok, before: e}
		if sharing {
			rec.pre[k] = readEnrichUndoFile(songSharePrePath(k))
		}
	}
	return rec
}

// importedCapture:导入库那一份的去处;rec 为 nil(这一笔不撤销)时返回 nil。
func (rec *enrichUndoRecord) importedCapture() *importedLyricsUndo {
	if rec == nil {
		return nil
	}
	return &rec.imported
}

// finishLocked:改完之后调,changed 是这一笔改了的写法(key 自己总算)。只留它们,并记下改完的样子。调用方持 enrichMu。
func (rec *enrichUndoRecord) finishLocked(changed []string) {
	if rec == nil {
		return
	}
	keep := map[string]bool{rec.key: true}
	for _, k := range changed {
		keep[k] = true
	}
	for k, s := range rec.slots {
		if !keep[k] {
			delete(rec.slots, k)
			delete(rec.pre, k)
			continue
		}
		s.after = enrichCache[k]
	}
}

// enrichUndoSameChoice:两条的歌词选择一样(正文、逐字、纯文本、来源、手改与采纳标记、纯音乐、同步原件)。译文、罗马音不比:
// 采纳之后机翻、读音补全会往上填,那是跟着这一笔来的,撤销时一起回去。
func enrichUndoSameChoice(a, b enrichEntry) bool {
	return a.Lyrics.Equal(b.Lyrics) && a.LyricsYRC.Equal(b.LyricsYRC) && a.PlainLyrics.Equal(b.PlainLyrics) &&
		a.PlainLyricsSource == b.PlainLyricsSource && a.LyricsSource == b.LyricsSource && a.ManualLyrics == b.ManualLyrics &&
		a.ManualPickSHA == b.ManualPickSHA && a.Instrumental == b.Instrumental && a.LyricsEntityOrigin == b.LyricsEntityOrigin
}

// changedSinceLocked:那一笔之后被别的改动动过的第一条写法(按键排序),没有为空串。调用方持 enrichMu。
func (rec *enrichUndoRecord) changedSinceLocked() string {
	for _, k := range rec.sortedKeys() {
		cur, ok := enrichCache[k]
		if !ok || enrichEditedSinceLocked(k, rec.seq) || !enrichUndoSameChoice(cur, rec.slots[k].after) {
			return k
		}
	}
	return ""
}

func (rec *enrichUndoRecord) sortedKeys() []string {
	keys := make([]string, 0, len(rec.slots))
	for k := range rec.slots {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// pruneEnrichUndosLocked 丢掉过期的记录。调用方持 enrichMu。
func pruneEnrichUndosLocked(now time.Time) {
	for id, rec := range enrichUndos {
		if now.Sub(rec.at) > enrichUndoTTL {
			delete(enrichUndos, id)
		}
	}
}

// storeEnrichUndoLocked 收下一份记录,返回它的 undo_id。seq 是这一笔记下改动序号之后的序号。调用方持 enrichMu。
func storeEnrichUndoLocked(rec *enrichUndoRecord, seq uint64) string {
	pruneEnrichUndosLocked(enrichUndoNow())
	for len(enrichUndos) >= enrichUndoMax {
		oldest := ""
		for id, r := range enrichUndos {
			if oldest == "" || r.at.Before(enrichUndos[oldest].at) {
				oldest = id
			}
		}
		delete(enrichUndos, oldest)
	}
	var b [12]byte
	_, _ = rand.Read(b[:])
	id := hex.EncodeToString(b[:])
	rec.seq = seq
	enrichUndos[id] = rec
	return id
}

// undoEnrichEditLocked:undo_edit。核对通过就把记录里的条目、同步留底、导入库记录放回去,记录作废(只能撤一次);
// 放回去的条目由调用方照常存盘、重新导出歌词文件,那一笔之前不存在的这条连歌词文件一起删掉。调用方持 enrichMu。
func undoEnrichEditLocked(id string) enrichEditOutcome {
	pruneEnrichUndosLocked(enrichUndoNow())
	rec, ok := enrichUndos[id]
	if !ok {
		return enrichEditOutcome{err: fmt.Errorf("undo_edit: %q expired or unknown", id), errCode: enrichUndoErrExpired}
	}
	delete(enrichUndos, id)
	if k := rec.changedSinceLocked(); k != "" {
		return enrichEditOutcome{err: fmt.Errorf("undo_edit: %q changed after the edit", k), errCode: enrichUndoErrChanged}
	}
	if importedLyricsUndoConflict(rec.imported) {
		return enrichEditOutcome{err: fmt.Errorf("undo_edit: imported lyrics of %q were stored again", rec.key), errCode: enrichUndoErrChanged}
	}
	var exports, trash []string
	for _, k := range rec.sortedKeys() {
		s := rec.slots[k]
		cancelInFlightEnrichLocked(k)
		if s.existed {
			enrichCache[k] = s.before
			exports = append(exports, k)
		} else {
			delete(enrichCache, k)
			trash = append(trash, k)
		}
	}
	for k, f := range rec.pre {
		f.restore(songSharePrePath(k))
	}
	if err := restoreImportedLyrics(rec.imported); err != nil {
		warnf("enrich edit: undo could not put back imported lyrics key=%s: %v", rec.key, err)
	}
	n := len(exports) + len(trash)
	return enrichEditOutcome{changed: n, exports: exports, trash: trash, followers: n - 1}
}

// importedLyricsUndo:dropImportedLyricsForSongCapturing 删掉的东西:记录文件原文、从索引 keys 摘掉的项、titles 里改过的列表改之前的样子。
// 方法对 nil 接收者什么都不做。
type importedLyricsUndo struct {
	files  map[string][]byte
	keys   map[string]string
	titles map[string][]string
}

func (u *importedLyricsUndo) noteFile(dir, name string) {
	if u == nil {
		return
	}
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		noteFileErr("read", filepath.Join(dir, name), err)
		return
	}
	if u.files == nil {
		u.files = map[string][]byte{}
	}
	u.files[name] = data
}

func (u *importedLyricsUndo) noteKey(stored, name string) {
	if u == nil {
		return
	}
	if u.keys == nil {
		u.keys = map[string]string{}
	}
	u.keys[stored] = name
}

func (u *importedLyricsUndo) noteTitles(t string, before []string) {
	if u == nil {
		return
	}
	if u.titles == nil {
		u.titles = map[string][]string{}
	}
	if _, seen := u.titles[t]; !seen {
		u.titles[t] = slices.Clone(before)
	}
}

// importedLyricsUndoConflict:要放回的记录文件删掉之后又有同名的存进来了(这首又导入了一次)。
func importedLyricsUndoConflict(u importedLyricsUndo) bool {
	dir := importedLyricsDir()
	if dir == "" {
		return false
	}
	for name := range u.files {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			return true
		}
	}
	return false
}

// restoreImportedLyrics 把 u 记下的记录文件原样写回、索引项放回去。titles 里按改之前的次序,之后新加的接在后面。
func restoreImportedLyrics(u importedLyricsUndo) error {
	dir := importedLyricsDir()
	if dir == "" || (len(u.files) == 0 && len(u.keys) == 0 && len(u.titles) == 0) {
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	var firstErr error
	for name, data := range u.files {
		if err := writeFileAtomic(filepath.Join(dir, name), data); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	importedLyricsIndex.Lock()
	defer importedLyricsIndex.Unlock()
	loadImportedLyricsIndexLocked()
	keys := importedLyricsIndex.keys
	if keys == nil {
		keys = map[string]string{}
	}
	for k, name := range u.keys {
		keys[k] = name
	}
	setImportedLyricsIndexLocked(dir, importedLyricsIndex.mtime, keys)
	for t, before := range u.titles {
		list := slices.Clone(before)
		for _, name := range importedLyricsIndex.titles[t] {
			if !slices.Contains(list, name) {
				list = append(list, name)
			}
		}
		importedLyricsIndex.titles[t] = list
	}
	writeImportedLyricsIndexLocked(dir)
	return firstErr
}
