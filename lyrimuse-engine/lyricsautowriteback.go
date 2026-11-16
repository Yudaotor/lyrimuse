package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 实验室「自动写入歌曲文件」(features LyricsAutoWriteback,默认关):正在放的本地文件,这首的歌词定下来后(首次解析落定、
// 采纳候选、手改保存)写进文件。每一拍 poller 记下当前文件之后调 maybeAutoWritebackLyrics,真正读写文件在后台 goroutine
// 里、同一时刻只跑一份。规则(见 11 章决策 163):
//   - 格式范围、写法、自校验、拒写的位置同单首写入(lyricsWritebackFormats、writeLyricsToFile);
//   - 标了纯音乐、没有歌词、首次解析还在跑的不写;Apple Music 的曲目只写歌词文字(writebackWantsPlainText);
//   - 文件里原本有歌词、又不是 Lyrimuse 上次写进去的(fileLyricsAgainst 判成 fileLyricsForeign):默认不覆盖;打开「覆盖其他软件
//     写入的歌词」(features LyricsAutoWritebackOverwrite)时先把原歌词备份(backupForeignLyrics),备份成了才写,见 11 章决策 166;
//   - 文件里的歌词已经跟要写的一样,不重写;
//   - 同一个文件、同一份正文只试一次(不论成败),换了正文或换了歌再试;失败只记日志。

// lyricsWritebackRecord:Lyrimuse 写进各文件的歌词正文哈希(单首写入和自动写回都记),用来认出文件里那份是不是自己写的。
type lyricsWritebackRecord struct {
	Files map[string]lyricsWritebackRecordEntry `json:"files"`
}

type lyricsWritebackRecordEntry struct {
	SHA string `json:"sha256"`
	At  int64  `json:"at"`
}

// lyricsWritebackRecordMax:写入记录最多留这么多个文件,多了按写入时间丢最早的。
const lyricsWritebackRecordMax = 5000

var (
	lyricsWritebackRecordMu sync.Mutex
	// lyricsWritebackRecordPath 写入记录的位置;测试换成临时文件。
	lyricsWritebackRecordPath = func() string {
		dir := configDir()
		if dir == "" {
			return ""
		}
		return filepath.Join(dir, clientName+"-lyrics-writeback.json")
	}
)

func writebackTextSHA(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func loadLyricsWritebackRecordLocked() lyricsWritebackRecord {
	rec := lyricsWritebackRecord{Files: map[string]lyricsWritebackRecordEntry{}}
	path := lyricsWritebackRecordPath()
	if path == "" {
		return rec
	}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return rec
	}
	if err := json.Unmarshal(data, &rec); err != nil {
		noteFileErr("decode", path, err)
		return lyricsWritebackRecord{Files: map[string]lyricsWritebackRecordEntry{}}
	}
	if rec.Files == nil {
		rec.Files = map[string]lyricsWritebackRecordEntry{}
	}
	return rec
}

// noteLyricsWrittenBack 记下刚写进 path 的正文(normalizeWritebackLyrics 之后的那份)。
func noteLyricsWrittenBack(path, text string) {
	lyricsWritebackRecordMu.Lock()
	defer lyricsWritebackRecordMu.Unlock()
	file := lyricsWritebackRecordPath()
	if file == "" {
		return
	}
	rec := loadLyricsWritebackRecordLocked()
	rec.Files[path] = lyricsWritebackRecordEntry{SHA: writebackTextSHA(text), At: time.Now().Unix()}
	for len(rec.Files) > lyricsWritebackRecordMax {
		oldest, at := "", int64(0)
		for p, e := range rec.Files {
			if oldest == "" || e.At < at {
				oldest, at = p, e.At
			}
		}
		delete(rec.Files, oldest)
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return
	}
	_ = writeFileAtomic(file, data)
}

// lyricsWrittenBackSHA:Lyrimuse 上次写进 path 的正文哈希,没写过为空。
func lyricsWrittenBackSHA(path string) string {
	lyricsWritebackRecordMu.Lock()
	defer lyricsWritebackRecordMu.Unlock()
	return loadLyricsWritebackRecordLocked().Files[path].SHA
}

// lyricsWritebackBackupMax:覆盖前留下的原歌词备份最多这么多份,多了按备份时间删最早的。
const lyricsWritebackBackupMax = 200

// lyricsWritebackBackupIndexName:备份目录里的索引,记每份备份来自哪个歌曲文件。
const lyricsWritebackBackupIndexName = "index.json"

var (
	lyricsWritebackBackupMu sync.Mutex
	// lyricsWritebackBackupDir 原歌词备份的目录;测试换成临时目录。
	lyricsWritebackBackupDir = func() string {
		dir := configDir()
		if dir == "" {
			return ""
		}
		return filepath.Join(dir, clientName+"-lyrics-writeback-backups")
	}
)

type lyricsWritebackBackupIndex struct {
	Backups []lyricsWritebackBackupEntry `json:"backups"`
}

type lyricsWritebackBackupEntry struct {
	File string `json:"file"`   // 备份目录里的文件名,内容是原歌词一字不改
	Path string `json:"path"`   // 被覆盖的歌曲文件
	SHA  string `json:"sha256"` // 原歌词的 sha256
	At   int64  `json:"at"`
}

// backupForeignLyrics 把 path 里别的软件写的歌词原样存一份(有 LRC 时间标签存 .lrc,否则 .txt),同一个文件同一份歌词只存一次。
// 返回错误时不能覆盖。
func backupForeignLyrics(path, lyrics string) error {
	dir := lyricsWritebackBackupDir()
	if dir == "" {
		return fmt.Errorf("no backup directory")
	}
	lyricsWritebackBackupMu.Lock()
	defer lyricsWritebackBackupMu.Unlock()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	indexPath := filepath.Join(dir, lyricsWritebackBackupIndexName)
	var idx lyricsWritebackBackupIndex
	if data, err := os.ReadFile(indexPath); err == nil {
		if err := json.Unmarshal(data, &idx); err != nil {
			noteFileErr("decode", indexPath, err)
			idx = lyricsWritebackBackupIndex{}
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	sha := writebackTextSHA(lyrics)
	for _, e := range idx.Backups {
		if e.Path == path && e.SHA == sha {
			if _, err := os.Stat(filepath.Join(dir, e.File)); err == nil {
				return nil
			}
		}
	}
	now := time.Now()
	base := []rune(strings.TrimSuffix(filepath.Base(path), filepath.Ext(path)))
	if len(base) > 80 {
		base = base[:80]
	}
	ext := ".txt"
	if localFileLRCTimestamp.MatchString(lyrics) {
		ext = ".lrc"
	}
	name := fmt.Sprintf("%s %s-%s%s", string(base), now.Format("20060102-150405"), sha[:8], ext)
	if err := writeFileAtomic(filepath.Join(dir, name), []byte(lyrics)); err != nil {
		return err
	}
	idx.Backups = append(idx.Backups, lyricsWritebackBackupEntry{File: name, Path: path, SHA: sha, At: now.Unix()})
	if len(idx.Backups) > lyricsWritebackBackupMax {
		sort.SliceStable(idx.Backups, func(i, j int) bool { return idx.Backups[i].At < idx.Backups[j].At })
		drop := len(idx.Backups) - lyricsWritebackBackupMax
		for _, e := range idx.Backups[:drop] {
			if e.File != "" && e.File == filepath.Base(e.File) && e.File != lyricsWritebackBackupIndexName {
				_ = os.Remove(filepath.Join(dir, e.File))
			}
		}
		idx.Backups = append([]lyricsWritebackBackupEntry(nil), idx.Backups[drop:]...)
	}
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	if err := writeFileAtomic(indexPath, data); err != nil {
		_ = os.Remove(filepath.Join(dir, name))
		return err
	}
	return nil
}

// fileLyricsState:文件里原有的歌词跟这次要写的比。
type fileLyricsState int

const (
	fileLyricsNone    fileLyricsState = iota // 文件里没有歌词
	fileLyricsSame                           // 已经是这次要写的那份
	fileLyricsOwn                            // Lyrimuse 上次写进去的(写入记录的正文哈希对得上)
	fileLyricsForeign                        // 别的软件写的
)

// fileLyricsAgainst 判断 probe 那个文件里原有的歌词是哪一种(sha 是这次要写的正文哈希),顺带交回引擎读法读到的原歌词。
// 自动写入和单首写入共用:只有 fileLyricsForeign 要在覆盖前备份。
func fileLyricsAgainst(probe lyricsWritebackProbe, sha string) (fileLyricsState, string) {
	if !probe.hasLyrics {
		return fileLyricsNone, ""
	}
	existing := readLocalFileTags(probe.path).lyrics
	switch writebackTextSHA(normalizeWritebackLyrics(existing)) {
	case sha:
		return fileLyricsSame, existing
	case lyricsWrittenBackSHA(probe.path):
		return fileLyricsOwn, existing
	}
	return fileLyricsForeign, existing
}

// backupBeforeManualWriteback:单首写入要覆盖时,文件里是别的软件写的歌词就先备份(backupForeignLyrics),
// 备份不成交回 backup_failed、不能写。文件里没有歌词、已是这份、是 Lyrimuse 上次写的都不备份。见 11 章决策 166。
func backupBeforeManualWriteback(path, text string) error {
	probe, err := probeLyricsWriteback(path)
	if err != nil {
		return err
	}
	state, existing := fileLyricsAgainst(probe, writebackTextSHA(text))
	if state != fileLyricsForeign {
		return nil
	}
	if err := backupForeignLyrics(probe.path, existing); err != nil {
		return wbErr(wbErrBackupFailed, err)
	}
	log.Printf("lyrics writeback: backed up lyrics written by another app before replacing path=%s", tildeHome(probe.path))
	return nil
}

var (
	autoWritebackRunning atomic.Bool
	autoWritebackMu      sync.Mutex
	// autoWritebackLastTry:上一次试过的「文件 + 正文哈希」,同一份不再试。
	autoWritebackLastTry string
	// autoWritebackSync:测试里同步跑,不起 goroutine。
	autoWritebackSync bool
)

// maybeAutoWritebackLyrics 每拍调一次:开关关着、没在放本地文件时立刻返回;否则在后台试一次(已经有一份在跑就跳过)。
func maybeAutoWritebackLyrics() {
	if !features().LyricsAutoWriteback {
		return
	}
	if _, _, _, path := localFileCurrentTrack(); path == "" {
		return
	}
	if !autoWritebackRunning.CompareAndSwap(false, true) {
		return
	}
	if autoWritebackSync {
		defer autoWritebackRunning.Store(false)
		autoWritebackLyricsOnce()
		return
	}
	go func() {
		defer autoWritebackRunning.Store(false)
		autoWritebackLyricsOnce()
	}()
}

// autoWritebackOutcome:一次尝试的结论,测试按它断言。
type autoWritebackOutcome string

const (
	autoWBSkipped     autoWritebackOutcome = "skipped"      // 没有可写的(开关关、不是本地文件、没定下来、没歌词、不支持的格式)
	autoWBSeen        autoWritebackOutcome = "seen"         // 这个文件这份正文已经试过
	autoWBUpToDate    autoWritebackOutcome = "up_to_date"   // 文件里已经是这份
	autoWBForeign     autoWritebackOutcome = "foreign"      // 文件里有别人写的歌词,没开覆盖,不动
	autoWBWritten     autoWritebackOutcome = "written"      // 写进去了
	autoWBOverwrote   autoWritebackOutcome = "overwrote"    // 备份了别人写的歌词后覆盖
	autoWBWriteFailed autoWritebackOutcome = "write_failed" // 写失败(已记日志)
)

func autoWritebackLyricsOnce() autoWritebackOutcome {
	bundle, artist, title, path := localFileCurrentTrack()
	if path == "" || !lyricsWritebackSupported(path) {
		return autoWBSkipped
	}
	pk := enrichPlayingKey.Load()
	if pk == nil || !sameSongKey(*pk, enrichKey(artist, title, "")) {
		return autoWBSkipped
	}
	key := *pk
	enrichMu.Lock()
	e, ok := enrichCache[key]
	busy := enrichInflight[key]
	enrichMu.Unlock()
	if !ok || busy || e.TS == 0 {
		return autoWBSkipped
	}
	text, err := lyricsWritebackText(key, writebackWantsPlainText(bundle))
	if err != nil {
		return autoWBSkipped
	}
	sha := writebackTextSHA(text)
	overwrite := features().LyricsAutoWritebackOverwrite
	// 开关在这首放着时打开,同一份正文要能再试一次。
	try := path + "\x00" + sha
	if overwrite {
		try += "\x00overwrite"
	}
	autoWritebackMu.Lock()
	seen := autoWritebackLastTry == try
	autoWritebackLastTry = try
	autoWritebackMu.Unlock()
	if seen {
		return autoWBSeen
	}
	probe, err := probeLyricsWriteback(path)
	if err != nil {
		log.Printf("lyrics writeback: auto skipped path=%s: %v", tildeHome(path), err)
		return autoWBSkipped
	}
	foreign := false
	switch state, existing := fileLyricsAgainst(probe, sha); state {
	case fileLyricsSame:
		return autoWBUpToDate
	case fileLyricsForeign:
		if !overwrite {
			log.Printf("lyrics writeback: auto skipped path=%s: file already carries lyrics not written by lyrimuse", tildeHome(probe.path))
			return autoWBForeign
		}
		if err := backupForeignLyrics(probe.path, existing); err != nil {
			warnf("lyrics writeback: auto skipped path=%s: backing up existing lyrics failed: %v", tildeHome(probe.path), err)
			return autoWBWriteFailed
		}
		foreign = true
	}
	real, err := writeLyricsToFile(path, text, true)
	if err != nil {
		warnf("lyrics writeback: auto write failed path=%s: %v", tildeHome(path), err)
		return autoWBWriteFailed
	}
	noteLyricsWrittenBack(real, text)
	if foreign {
		log.Printf("lyrics writeback: auto replaced lyrics written by another app path=%s (original backed up)", tildeHome(real))
		return autoWBOverwrote
	}
	return autoWBWritten
}

// sameSongKey:两个缓存 key 的歌手和歌名不分大小写相同(专辑、时长变体不比)。
func sameSongKey(a, b string) bool {
	aa, at, _ := splitEnrichKey(a)
	ba, bt, _ := splitEnrichKey(b)
	return at != "" && strings.EqualFold(aa, ba) && strings.EqualFold(at, bt)
}
