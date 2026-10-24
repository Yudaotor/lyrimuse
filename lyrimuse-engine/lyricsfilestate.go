package main

import (
	"encoding/json"
	"hash/crc32"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
)

// 歌词文件夹的「上次看到的样子」:每个文件的大小、修改时间、内容校验值,记的是引擎上一次写出或读进它时的状态。
//
// 启动时 importLyricsFromFiles 与 exportLyricsFiles 原来都要把 lyrics/ 下的每个文件读一遍(导入按文件头认身份、
// 比对正文;导出逐字节比对要不要重写),两万多个文件各读一遍,冷启动光这两步就十来秒,而且导入全程持着 enrichMu。
// 有了这份记录:大小和修改时间都跟记录一致的文件就是上次之后没人动过 —— 导入不读它;导出要写的内容校验值也一致
// 就不读不写。用户在 Finder / 编辑器里改过、歌词管理写过、从备份恢复出来的文件,修改时间都会变,照常读进来。
// 做不到的:改了内容又把大小和修改时间原样改回去的文件(rsync -t 同尺寸覆盖这类),会被当成没动过。
//
// 只在常驻进程里生效:记录跟 enrich 缓存放在同一个目录(enrichPath 所在目录),enrichPath 为空(一次性 CLI、
// 单测)时不读不写,导入导出退回全量比对,行为与没有这份记录时一样。记录按歌词文件夹路径区分,换了文件夹就作废。
// 只在全量导出结束时落盘;运行期单首导出改到的文件只更新内存,没落盘的那几个下次启动多读一遍而已。见 09 章决策 102。

type lyricsFileStamp struct {
	Size  int64  `json:"s"`
	ModNs int64  `json:"m"`
	CRC   uint32 `json:"c"`
	// Src:写出这份内容时用的缓存原文的指纹,只有要把背景人声接回去的文件记(parenBGFileSource)。文件没动过、指纹也一样,
	// 导出就不用再算一遍接回去的写法。
	Src uint32 `json:"r,omitempty"`
}

type lyricsFileStateFile struct {
	Dir   string                     `json:"dir"`
	Files map[string]lyricsFileStamp `json:"files"`
	// WordFormats:落盘那一刻文件夹里逐字按哪几种格式写的(lyricsWordFormatsInUse)。设置在引擎没跑的时候改了,启动时先按这个
	// 导入、再换成设置里的(switchLyricsWordFormats),主格式换了也不丢旧主格式文件里的手改。
	WordFormats []string `json:"word_formats,omitempty"`
}

var (
	lyricsFileStateMu    sync.Mutex
	lyricsFileStateDir   string
	lyricsFileStateFiles map[string]lyricsFileStamp
	lyricsFileStateReady bool // 已经按 lyricsFileStateDir 读过盘
	// lyricsFileStateTrusted:手上的记录描述的就是这个文件夹(从盘上读到了它的记录,或者这个进程对它做完过一次全量导出)。
	// 记录丢了、换了文件夹时为 false:导入把每个文件都当成可能改过,但不能当成「用户导出之后改过」。
	lyricsFileStateTrusted bool
)

func lyricsFileStatePath() string {
	if enrichPath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(enrichPath), clientName+"-lyrics-files-state.json")
}

// lyricsFileStateEnabled:这个歌词文件夹能不能用记录(常驻进程、且记录是这个文件夹的)。第一次调用时读盘。
func lyricsFileStateEnabled(dir string) bool {
	path := lyricsFileStatePath()
	if path == "" || dir == "" {
		return false
	}
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	if lyricsFileStateReady && lyricsFileStateDir == dir {
		return true
	}
	lyricsFileStateDir, lyricsFileStateFiles, lyricsFileStateReady = dir, map[string]lyricsFileStamp{}, true
	lyricsFileStateTrusted = false
	var f lyricsFileStateFile
	if raw, err := os.ReadFile(path); err == nil && json.Unmarshal(raw, &f) == nil && f.Dir == dir && f.Files != nil {
		lyricsFileStateFiles, lyricsFileStateTrusted = f.Files, true
		if len(f.WordFormats) > 0 && lyricsWordFormatsApplied.Load() == nil {
			applied := resolveLyricsWordFormats(f.WordFormats)
			lyricsWordFormatsApplied.Store(&applied)
		}
	}
	return true
}

// lyricsFileStateTrustedFor:记录描述的是 dir 这个文件夹,记录里没有、或者跟记录不一致的文件才是导出之后被动过的。
func lyricsFileStateTrustedFor(dir string) bool {
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	return lyricsFileStateReady && lyricsFileStateDir == dir && lyricsFileStateTrusted
}

func lyricsStampOf(info fs.FileInfo, crc uint32) lyricsFileStamp {
	return lyricsFileStamp{Size: info.Size(), ModNs: info.ModTime().UnixNano(), CRC: crc}
}

// lyricsFileUnchanged:name 的大小和修改时间跟记录一致,返回记录里的校验值。
// lyricsStateName:记录和目录列表里文件名的键,一律转成 NFC。引擎按缓存键算出的文件名是 NFC,目录里的却可能是
// 分解写法(NFD,带重音字母、浊点假名的名字):APFS 按规范等价认文件,不改写名字,覆盖写入也留着旧名。按原样当键的话,
// 这些文件每次全量导出都被当成不在、重写一遍,修改时间刷成最新(歌词管理按更新时间排就总排最前)。见 09 章决策 247。
func lyricsStateName(name string) string { return composeNFC(name) }

func lyricsFileUnchanged(dir, name string, info fs.FileInfo) (uint32, bool) {
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	if !lyricsFileStateReady || lyricsFileStateDir != dir || info == nil {
		return 0, false
	}
	s, ok := lyricsFileStateFiles[lyricsStateName(name)]
	if !ok || s.Size != info.Size() || s.ModNs != info.ModTime().UnixNano() {
		return 0, false
	}
	return s.CRC, true
}

func recordLyricsFile(dir, name string, info fs.FileInfo, crc uint32) {
	recordLyricsFileFrom(dir, name, info, crc, 0)
}

func recordLyricsFileFrom(dir, name string, info fs.FileInfo, crc, src uint32) {
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	if lyricsFileStateReady && lyricsFileStateDir == dir && info != nil {
		s := lyricsStampOf(info, crc)
		s.Src = src
		lyricsFileStateFiles[lyricsStateName(name)] = s
	}
}

// lyricsFileUnchangedFrom:name 跟记录一致,而且记录的是按指纹 src 那份缓存原文写出的。src 为 0 时一律不算。
func lyricsFileUnchangedFrom(dir, name string, info fs.FileInfo, src uint32) bool {
	if src == 0 {
		return false
	}
	if _, same := lyricsFileUnchanged(dir, name, info); !same {
		return false
	}
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	return lyricsFileStateFiles[lyricsStateName(name)].Src == src
}

func forgetLyricsFile(dir, name string) {
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	if lyricsFileStateReady && lyricsFileStateDir == dir {
		delete(lyricsFileStateFiles, lyricsStateName(name))
	}
}

// saveLyricsFileState:全量导出结束时落盘。只留目录里真实存在的文件(present),删掉的不带着。
func saveLyricsFileState(dir string, present map[string]fs.FileInfo) {
	path := lyricsFileStatePath()
	if path == "" {
		return
	}
	lyricsFileStateMu.Lock()
	if !lyricsFileStateReady || lyricsFileStateDir != dir {
		lyricsFileStateMu.Unlock()
		return
	}
	out := lyricsFileStateFile{Dir: dir, Files: make(map[string]lyricsFileStamp, len(lyricsFileStateFiles))}
	for _, f := range lyricsWordFormatsInUse() {
		out.WordFormats = append(out.WordFormats, string(f))
	}
	for name, s := range lyricsFileStateFiles {
		if _, ok := present[name]; ok {
			out.Files[name] = s
		}
	}
	lyricsFileStateMu.Unlock()
	raw, err := json.Marshal(out)
	if err != nil {
		return
	}
	if err := writeFileAtomic(path, raw); err != nil {
		slog.Warn("lyrics file state: save failed", "err", err)
		return
	}
	lyricsFileStateMu.Lock()
	if lyricsFileStateReady && lyricsFileStateDir == dir {
		lyricsFileStateTrusted = true
	}
	lyricsFileStateMu.Unlock()
}

// listLyricsDir:目录里每个文件的状态(一次 ReadDir + 每项一次 lstat),给全量导出判断「在不在、动没动」。
func listLyricsDir(dir string) map[string]fs.FileInfo {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	out := make(map[string]fs.FileInfo, len(ents))
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		// 键按 NFC(见 lyricsStateName)。同一个名字两种写法各有一份时留新的那份。
		key := lyricsStateName(e.Name())
		if prev, ok := out[key]; ok && !info.ModTime().After(prev.ModTime()) {
			continue
		}
		out[key] = info
	}
	return out
}

func lyricsCRC(b []byte) uint32 { return crc32.ChecksumIEEE(b) }
