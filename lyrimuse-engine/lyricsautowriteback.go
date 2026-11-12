package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 实验室「自动写入歌曲文件」(features LyricsAutoWriteback,默认关):正在放的本地文件,这首的歌词定下来后(首次解析落定、
// 采纳候选、手改保存)写进文件。每一拍 poller 记下当前文件之后调 maybeAutoWritebackLyrics,真正读写文件在后台 goroutine
// 里、同一时刻只跑一份。规则(见 11 章决策 163):
//   - 只写 MP3 / FLAC,写法、自校验、拒写的位置同单首写入(writeLyricsToFile);
//   - 标了纯音乐、没有歌词、首次解析还在跑的不写;Apple Music 的曲目只写歌词文字(writebackWantsPlainText);
//   - 文件里原本有歌词、又不是 Lyrimuse 上次写进去的(写入记录里这个文件的正文哈希对不上),不覆盖;
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
	autoWBForeign     autoWritebackOutcome = "foreign"      // 文件里有别人写的歌词,不覆盖
	autoWBWritten     autoWritebackOutcome = "written"      // 写进去了
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
	try := path + "\x00" + sha
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
	if probe.hasLyrics {
		existing := normalizeWritebackLyrics(readLocalFileTags(probe.path).lyrics)
		switch writebackTextSHA(existing) {
		case sha:
			return autoWBUpToDate
		case lyricsWrittenBackSHA(probe.path):
		default:
			log.Printf("lyrics writeback: auto skipped path=%s: file already carries lyrics not written by lyrimuse", tildeHome(probe.path))
			return autoWBForeign
		}
	}
	real, err := writeLyricsToFile(path, text, true)
	if err != nil {
		warnf("lyrics writeback: auto write failed path=%s: %v", tildeHome(path), err)
		return autoWBWriteFailed
	}
	noteLyricsWrittenBack(real, text)
	return autoWBWritten
}

// sameSongKey:两个缓存 key 的歌手和歌名不分大小写相同(专辑、时长变体不比)。
func sameSongKey(a, b string) bool {
	aa, at, _ := splitEnrichKey(a)
	ba, bt, _ := splitEnrichKey(b)
	return at != "" && strings.EqualFold(aa, ba) && strings.EqualFold(at, bt)
}
