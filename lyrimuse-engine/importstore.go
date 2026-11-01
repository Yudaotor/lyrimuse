package main

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

// 导入库:按「优先使用」「只补没有歌词的歌」导入的歌词按缓存 key 另存一份(importedLyricsRecord)。选词时它作为来源
// importLyricsSource 的候选放进候选池(importedLyricsFor),跟各源一起打分,另加 importedLyricsPoints:同等质量的普通
// LRC 比不过它,带逐字这类明显更好的还能换掉它。按「锁定为手动修改」导入的不进这里(条目锁着,选词不碰它)。
// 歌词库里还没有这首的(批量导入时匹配不上的文件)按身份存(Key 为空、Identities 记歌手和歌名),以后放到、预取到这首时
// 按歌名找、歌手对得上、知道时长时时长也吻合才用(importedLyricsRecordBySong)。
// 用户在这首上采用了别的歌词(save_edit / save_plain_text 的来源不是 import)时,按 key 存的和按身份对得上的一起作废
// (dropImportedLyricsForSong)。见 11 章决策 150、151。
//
// 落盘:<configDir>/<clientName>-imported-lyrics/ 下一个 index.json(key → 文件名、歌名 → 按身份存的文件名)加每首一个 <sha1>.json。

// importedLyricsPoints:导入的歌词在打分里另加的分。比逐字时间轴(wordTimingPoints)少:别的源给的带逐字、其余差不多时
// 换成那一份;比同源加权(250)多:跟别家普通 LRC 打平时留着导入的。
const importedLyricsPoints = 300

type importedLyricsRecord struct {
	Key        string   `json:"key"`
	Lyrics     string   `json:"lyrics"`
	Tr         string   `json:"tr,omitempty"`
	TrLang     string   `json:"tr_lang,omitempty"`
	Roma       string   `json:"roma,omitempty"`
	YRC        string   `json:"yrc,omitempty"`
	BG         string   `json:"bg,omitempty"`
	Title      string   `json:"title,omitempty"`
	Artist     string   `json:"artist,omitempty"`
	Album      string   `json:"album,omitempty"`
	Format     string   `json:"format,omitempty"`
	Files      []string `json:"files,omitempty"`
	ImportedAt int64    `json:"imported_at"`
	// Identities:按身份存的那种(Key 为空)认哪几种「歌手 + 歌名」。文件名「A - B」分不清谁是歌手时两种都记。
	Identities []importedIdentity `json:"identities,omitempty"`
	// WatchFiles:监视文件夹自动存进来的,来源文件的绝对路径;文件删了、挪走了这份跟着作废。
	WatchFiles []string `json:"watch_files,omitempty"`
}

type importedIdentity struct {
	Artist string `json:"artist"`
	Title  string `json:"title"`
}

type importedLyricsIndexFile struct {
	Keys   map[string]string   `json:"keys"`
	Titles map[string][]string `json:"titles,omitempty"`
}

// importedLyricsIndex:内存里的 index.json,按文件修改时间重读(常驻进程自己写的时候直接改内存;子命令每次起来读一遍)。
var importedLyricsIndex struct {
	sync.Mutex
	loadedFor string
	mtime     time.Time
	keys      map[string]string
	loose     map[string]string   // 宽松 key(去掉时长变体位)→ 原 key
	titles    map[string][]string // 歌名(importNormTitle)→ 按身份存的文件名
}

func importedLyricsDir() string {
	dir := configDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, clientName+"-imported-lyrics")
}

func importedLyricsFileName(key string) string {
	sum := sha1.Sum([]byte(key))
	return hex.EncodeToString(sum[:]) + ".json"
}

// importedLooseKey:宽松比对用的 key(繁简、大小写、空格、多歌手分隔符折平)。时长变体位(「~durN」)照留:那是另一个录音,
// 不借这一份。
func importedLooseKey(key string) string {
	return loosenEnrichKey(key)
}

// lookupImportedLyricsNameLocked:按 key 找记录;exact 为假表示按宽松 key 对上的(存的是另一种写法)。调用方持锁。
func lookupImportedLyricsNameLocked(key string) (stored, name string, exact, ok bool) {
	if name, ok := importedLyricsIndex.keys[key]; ok {
		return key, name, true, true
	}
	if orig, hit := importedLyricsIndex.loose[importedLooseKey(key)]; hit {
		if name, ok := importedLyricsIndex.keys[orig]; ok {
			return orig, name, false, true
		}
	}
	return "", "", false, false
}

// importedLyricsFitsDuration:知道时长时(durationSecs > 0)末句时间要跟时长吻合。
func importedLyricsFitsDuration(rec importedLyricsRecord, durationSecs float64) bool {
	if durationSecs <= 0 {
		return true
	}
	last, ok := lastLRCTimestampSecs(rec.Lyrics)
	return !ok || durationFits(last, durationSecs)
}

// loadImportedLyricsIndexLocked:index.json 改过(或换了配置目录)才重读。调用方持 importedLyricsIndex 的锁。
func loadImportedLyricsIndexLocked() {
	dir := importedLyricsDir()
	path := filepath.Join(dir, "index.json")
	info, err := os.Stat(path)
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			noteFileErr("stat", path, err)
		}
		importedLyricsIndex.loadedFor, importedLyricsIndex.mtime = dir, time.Time{}
		importedLyricsIndex.keys, importedLyricsIndex.loose, importedLyricsIndex.titles = nil, nil, nil
		return
	}
	if importedLyricsIndex.loadedFor == dir && info.ModTime().Equal(importedLyricsIndex.mtime) && importedLyricsIndex.keys != nil {
		return
	}
	var idx importedLyricsIndexFile
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return
	}
	if err := json.Unmarshal(data, &idx); err != nil {
		// 读不出来就按各记录文件自带的 key、身份重建一份,坏的那份留着(index.json.corrupt);不重建的话下一次存入
		// 会拿空索引整份覆盖,原有的记录就成了查不到、删不掉的孤儿。
		noteFileErr("decode", path, err)
		if err := os.Rename(path, path+".corrupt"); err != nil {
			noteFileErr("rename", path, err)
		}
		rebuildImportedLyricsIndexLocked(dir)
		return
	}
	setImportedLyricsIndexLocked(dir, info.ModTime(), idx.Keys)
	importedLyricsIndex.titles = idx.Titles
}

// importedLyricsRecordFiles:导入库目录里的记录文件名(不含 index.json)。
func importedLyricsRecordFiles(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			noteFileErr("read", dir, err)
		}
		return nil
	}
	var out []string
	for _, e := range entries {
		if n := e.Name(); !e.IsDir() && strings.HasSuffix(n, ".json") && n != "index.json" {
			out = append(out, n)
		}
	}
	return out
}

// rebuildImportedLyricsIndexLocked:按各记录文件自带的 key、身份重建索引并写回。调用方持锁。
func rebuildImportedLyricsIndexLocked(dir string) {
	keys := map[string]string{}
	importedLyricsIndex.titles = map[string][]string{}
	for _, name := range importedLyricsRecordFiles(dir) {
		rec, ok := readImportedLyricsRecord(dir, name)
		if !ok {
			continue
		}
		if rec.Key != "" {
			keys[rec.Key] = name
			continue
		}
		for _, id := range rec.Identities {
			t := importNormTitle(id.Title)
			if !slices.Contains(importedLyricsIndex.titles[t], name) {
				importedLyricsIndex.titles[t] = append(importedLyricsIndex.titles[t], name)
			}
		}
	}
	setImportedLyricsIndexLocked(dir, time.Time{}, keys)
	writeImportedLyricsIndexLocked(dir)
}

func setImportedLyricsIndexLocked(dir string, mtime time.Time, keys map[string]string) {
	if keys == nil {
		keys = map[string]string{}
	}
	if importedLyricsIndex.titles == nil {
		importedLyricsIndex.titles = map[string][]string{}
	}
	loose := make(map[string]string, len(keys))
	for k := range keys {
		loose[importedLooseKey(k)] = k
	}
	importedLyricsIndex.loadedFor, importedLyricsIndex.mtime = dir, mtime
	importedLyricsIndex.keys, importedLyricsIndex.loose = keys, loose
}

func writeImportedLyricsIndexLocked(dir string) {
	path := filepath.Join(dir, "index.json")
	data, err := json.Marshal(importedLyricsIndexFile{Keys: importedLyricsIndex.keys, Titles: importedLyricsIndex.titles})
	if err != nil {
		return
	}
	if writeFileAtomic(path, data) != nil {
		return
	}
	if info, err := os.Stat(path); err == nil {
		importedLyricsIndex.mtime = info.ModTime()
	}
}

// saveImportedLyrics 记下(或换掉)这几首的导入歌词。正文一首一个文件,index.json 整批只写一次。
func saveImportedLyrics(recs ...importedLyricsRecord) error {
	dir := importedLyricsDir()
	if dir == "" {
		return errors.New("imported lyrics: no config dir")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	saved := map[string]string{}
	bySong := map[string][]string{}
	var firstErr error
	for _, rec := range recs {
		var name string
		switch {
		case rec.Key != "":
			name = importedLyricsFileName(rec.Key)
		case len(rec.Identities) > 0:
			name = importedLyricsFileName("identity:" + rec.Identities[0].Artist + "|" + rec.Identities[0].Title)
		default:
			continue
		}
		data, err := json.Marshal(rec)
		if err != nil {
			continue
		}
		if err := writeFileAtomic(filepath.Join(dir, name), data); err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if rec.Key != "" {
			saved[rec.Key] = name
			continue
		}
		for _, id := range rec.Identities {
			t := importNormTitle(id.Title)
			if !slices.Contains(bySong[t], name) {
				bySong[t] = append(bySong[t], name)
			}
		}
	}
	if len(saved) == 0 && len(bySong) == 0 {
		return firstErr
	}
	importedLyricsIndex.Lock()
	defer importedLyricsIndex.Unlock()
	loadImportedLyricsIndexLocked()
	keys := importedLyricsIndex.keys
	if keys == nil {
		keys = map[string]string{}
	}
	for k, name := range saved {
		keys[k] = name
	}
	setImportedLyricsIndexLocked(dir, importedLyricsIndex.mtime, keys)
	for t, names := range bySong {
		for _, name := range names {
			if !slices.Contains(importedLyricsIndex.titles[t], name) {
				importedLyricsIndex.titles[t] = append(importedLyricsIndex.titles[t], name)
			}
		}
	}
	writeImportedLyricsIndexLocked(dir)
	return firstErr
}

// dropImportedLyrics 作废这几首的导入歌词;没有的不管。
func dropImportedLyrics(keys ...string) {
	dir := importedLyricsDir()
	if dir == "" || len(keys) == 0 {
		return
	}
	importedLyricsIndex.Lock()
	defer importedLyricsIndex.Unlock()
	loadImportedLyricsIndexLocked()
	changed := false
	for _, k := range keys {
		// 跟读的时候(importedLyricsRecordLookup)同一套找法,宽松 key 对上的也删,不然删不掉、下一轮又被挑回来。
		stored, name, _, ok := lookupImportedLyricsNameLocked(k)
		if !ok {
			continue
		}
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			noteFileErr("remove", filepath.Join(dir, name), err)
		}
		delete(importedLyricsIndex.keys, stored)
		changed = true
	}
	if changed {
		setImportedLyricsIndexLocked(dir, importedLyricsIndex.mtime, importedLyricsIndex.keys)
		writeImportedLyricsIndexLocked(dir)
	}
}

// dropImportedLyricsFiles:导入库管理界面删掉的那几份(按文件名);all 为真时整个导入库清空。返回删了几份。
func dropImportedLyricsFiles(names []string, all bool) int {
	dir := importedLyricsDir()
	if dir == "" {
		return 0
	}
	importedLyricsIndex.Lock()
	defer importedLyricsIndex.Unlock()
	loadImportedLyricsIndexLocked()
	gone := map[string]bool{}
	if all {
		for _, name := range importedLyricsIndex.keys {
			gone[name] = true
		}
		for _, list := range importedLyricsIndex.titles {
			for _, name := range list {
				gone[name] = true
			}
		}
	} else {
		for _, name := range names {
			if name == filepath.Base(name) && strings.HasSuffix(name, ".json") && name != "index.json" {
				gone[name] = true
			}
		}
	}
	removed := 0
	for name := range gone {
		err := os.Remove(filepath.Join(dir, name))
		switch {
		case err == nil:
			removed++
		case !errors.Is(err, fs.ErrNotExist):
			noteFileErr("remove", filepath.Join(dir, name), err)
		}
	}
	for k, name := range importedLyricsIndex.keys {
		if gone[name] {
			delete(importedLyricsIndex.keys, k)
		}
	}
	for t, list := range importedLyricsIndex.titles {
		kept := slices.DeleteFunc(slices.Clone(list), func(n string) bool { return gone[n] })
		if len(kept) == 0 {
			delete(importedLyricsIndex.titles, t)
		} else {
			importedLyricsIndex.titles[t] = kept
		}
	}
	setImportedLyricsIndexLocked(dir, importedLyricsIndex.mtime, importedLyricsIndex.keys)
	writeImportedLyricsIndexLocked(dir)
	return removed
}

// dropImportedLyricsWhere:逐个读记录文件,符合 drop 的删掉、从索引里摘掉,返回删了几份。要读整个目录,只给少见的操作用
// (监视文件夹里删了文件、从快照恢复)。
func dropImportedLyricsWhere(drop func(importedLyricsRecord) bool) int {
	dir := importedLyricsDir()
	if dir == "" {
		return 0
	}
	importedLyricsIndex.Lock()
	defer importedLyricsIndex.Unlock()
	loadImportedLyricsIndexLocked()
	gone := map[string]bool{}
	for _, name := range importedLyricsRecordFiles(dir) {
		rec, ok := readImportedLyricsRecord(dir, name)
		if !ok || !drop(rec) {
			continue
		}
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			noteFileErr("remove", filepath.Join(dir, name), err)
			continue
		}
		gone[name] = true
	}
	if len(gone) == 0 {
		return 0
	}
	for k, name := range importedLyricsIndex.keys {
		if gone[name] {
			delete(importedLyricsIndex.keys, k)
		}
	}
	for t, list := range importedLyricsIndex.titles {
		kept := slices.DeleteFunc(slices.Clone(list), func(n string) bool { return gone[n] })
		if len(kept) == 0 {
			delete(importedLyricsIndex.titles, t)
		} else {
			importedLyricsIndex.titles[t] = kept
		}
	}
	setImportedLyricsIndexLocked(dir, importedLyricsIndex.mtime, importedLyricsIndex.keys)
	writeImportedLyricsIndexLocked(dir)
	return len(gone)
}

// dropImportedLyricsFromWatchFiles:监视文件夹里删掉、挪走了这几个文件(绝对路径),从它们存进来的记录作废。
func dropImportedLyricsFromWatchFiles(paths []string) int {
	gone := map[string]bool{}
	for _, p := range paths {
		gone[filepath.Clean(p)] = true
	}
	return dropImportedLyricsWhere(func(rec importedLyricsRecord) bool {
		for _, f := range rec.WatchFiles {
			if gone[filepath.Clean(f)] {
				return true
			}
		}
		return false
	})
}

// dropImportedLyricsSince:这个时刻(Unix 秒)之后存进导入库的记录作废(从这之前打的快照恢复)。
func dropImportedLyricsSince(t int64) int {
	return dropImportedLyricsWhere(func(rec importedLyricsRecord) bool { return rec.ImportedAt > t })
}

// importedLyricsRecordFor:这首有没有导入的歌词。先按原 key 找,找不到按宽松 key(繁简、大小写、空格、多歌手分隔符、
// 时长变体位)找。
func importedLyricsRecordFor(key string) (importedLyricsRecord, bool) {
	rec, _, ok := importedLyricsRecordLookup(key)
	return rec, ok
}

// importedLyricsRecordLookup:同 importedLyricsRecordFor,另报是不是按原 key 对上的。
func importedLyricsRecordLookup(key string) (importedLyricsRecord, bool, bool) {
	dir := importedLyricsDir()
	if dir == "" || key == "" {
		return importedLyricsRecord{}, false, false
	}
	importedLyricsIndex.Lock()
	loadImportedLyricsIndexLocked()
	_, name, exact, ok := lookupImportedLyricsNameLocked(key)
	importedLyricsIndex.Unlock()
	if !ok {
		return importedLyricsRecord{}, false, false
	}
	rec, ok := readImportedLyricsRecord(dir, name)
	return rec, exact, ok
}

// importedIdentityMatches:按身份存的这份认不认这首:歌名对得上,歌手对得上(importArtistFits,合作署名只看第一位也算)。
func importedIdentityMatches(rec importedLyricsRecord, artist, title string) bool {
	t := importNormTitle(title)
	for _, id := range rec.Identities {
		if importNormTitle(id.Title) == t && importArtistFits(id.Artist, artist) {
			return true
		}
	}
	return false
}

// importTitleVariants:按身份找时试哪几种歌名:原样,带合作署名的再加去掉署名的(存的时候文件名多半没写「feat. X」)。
// 读(importedLyricsRecordBySong)和删(dropImportedLyricsForSong)用同一份。
func importTitleVariants(title string) []string {
	if bare := titleWithoutFeatCredit(title); bare != "" {
		return []string{title, bare}
	}
	return []string{title}
}

func readImportedLyricsRecord(dir, name string) (importedLyricsRecord, bool) {
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			noteFileErr("read", filepath.Join(dir, name), err)
		}
		return importedLyricsRecord{}, false
	}
	var rec importedLyricsRecord
	if err := json.Unmarshal(data, &rec); err != nil || strings.TrimSpace(rec.Lyrics) == "" {
		return importedLyricsRecord{}, false
	}
	return rec, true
}

// importedLyricsRecordBySong:按身份存的里面有没有这首。知道时长时(durationSecs > 0)末句时间要跟时长吻合,
// 同名的现场版、剪辑版不借这份。
func importedLyricsRecordBySong(artist, title string, durationSecs float64) (importedLyricsRecord, bool) {
	dir := importedLyricsDir()
	if dir == "" || title == "" || artist == "" {
		return importedLyricsRecord{}, false
	}
	for _, t := range importTitleVariants(title) {
		importedLyricsIndex.Lock()
		loadImportedLyricsIndexLocked()
		names := slices.Clone(importedLyricsIndex.titles[importNormTitle(t)])
		importedLyricsIndex.Unlock()
		for _, name := range names {
			rec, ok := readImportedLyricsRecord(dir, name)
			if !ok || !importedIdentityMatches(rec, artist, t) || !importedLyricsFitsDuration(rec, durationSecs) {
				continue
			}
			return rec, true
		}
	}
	return importedLyricsRecord{}, false
}

// dropImportedLyricsForSong:用户在这首上采用了别的歌词:按 key 存的、按身份对得上的一起作废。
func dropImportedLyricsForSong(key string) {
	dropImportedLyrics(key)
	if strings.Count(key, "|") < 2 {
		return
	}
	artist, title, _ := splitEnrichKey(key)
	title = strings.TrimSuffix(title, enrichKeyDurationVariantRe.FindString(title))
	dir := importedLyricsDir()
	if dir == "" {
		return
	}
	importedLyricsIndex.Lock()
	defer importedLyricsIndex.Unlock()
	loadImportedLyricsIndexLocked()
	changed := false
	for _, variant := range importTitleVariants(title) {
		t := importNormTitle(variant)
		var kept []string
		hit := false
		for _, name := range importedLyricsIndex.titles[t] {
			rec, ok := readImportedLyricsRecord(dir, name)
			if ok && !importedIdentityMatches(rec, artist, variant) {
				kept = append(kept, name)
				continue
			}
			if err := os.Remove(filepath.Join(dir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
				noteFileErr("remove", filepath.Join(dir, name), err)
			}
			hit = true
		}
		if !hit {
			continue
		}
		changed = true
		if len(kept) == 0 {
			delete(importedLyricsIndex.titles, t)
		} else {
			importedLyricsIndex.titles[t] = kept
		}
	}
	if changed {
		writeImportedLyricsIndexLocked(dir)
	}
}

// importedLyricsFor:选词的候选池用。先按这首的 key、再按宽松 key、最后按身份找(importedLyricsRecordBySong)。身份按这首本地的
// 歌名歌手专辑,不算「播放器给定」(不吃同源加权)。传进来的歌名不带时长变体位,key 按时长换成这首真正的那条
// (resolveEnrichKeyForDuration):现场版、剪辑版拿自己的那份,不拿同名另一个录音按原 key 存的。调用方别持 enrichMu。
func importedLyricsFor(artist, title, album string, durationSecs float64) (lyricSourceResult, bool) {
	key := enrichKey(artist, title, album)
	if durationSecs > 0 {
		enrichMu.Lock()
		key, _, _ = resolveEnrichKeyForDuration(enrichCache, key, durationSecs)
		enrichMu.Unlock()
	}
	rec, exact, ok := importedLyricsRecordLookup(key)
	// 按宽松 key 对上的(存的是另一种写法)跟按身份存的一样,知道时长时末句要吻合。
	if ok && !exact && !importedLyricsFitsDuration(rec, durationSecs) {
		ok = false
	}
	if !ok {
		rec, ok = importedLyricsRecordBySong(artist, title, durationSecs)
	}
	if !ok {
		return lyricSourceResult{}, false
	}
	return lyricSourceResult{
		source: importLyricsSource, lyr: rec.Lyrics, yrc: rec.YRC, tr: rec.Tr, roma: rec.Roma, bg: rec.BG, trLang: rec.TrLang,
		matchTitle: title, matchArtist: artist, matchAlbum: album,
	}, true
}

// importedTrLang:导入的译文标了语言就用它,没标按设置里的译文语言(用户导入的译文多半就是想看的那种)。
func importedTrLang(lang string) string {
	if lang != "" {
		return lang
	}
	return features().LyricsTranslationLanguage
}
