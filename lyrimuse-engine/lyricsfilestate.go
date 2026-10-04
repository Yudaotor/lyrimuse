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
}

type lyricsFileStateFile struct {
	Dir   string                     `json:"dir"`
	Files map[string]lyricsFileStamp `json:"files"`
}

var (
	lyricsFileStateMu    sync.Mutex
	lyricsFileStateDir   string
	lyricsFileStateFiles map[string]lyricsFileStamp
	lyricsFileStateReady bool // 已经按 lyricsFileStateDir 读过盘
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
	var f lyricsFileStateFile
	if raw, err := os.ReadFile(path); err == nil && json.Unmarshal(raw, &f) == nil && f.Dir == dir && f.Files != nil {
		lyricsFileStateFiles = f.Files
	}
	return true
}

func lyricsStampOf(info fs.FileInfo, crc uint32) lyricsFileStamp {
	return lyricsFileStamp{Size: info.Size(), ModNs: info.ModTime().UnixNano(), CRC: crc}
}

// lyricsFileUnchanged:name 的大小和修改时间跟记录一致,返回记录里的校验值。
func lyricsFileUnchanged(dir, name string, info fs.FileInfo) (uint32, bool) {
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	if !lyricsFileStateReady || lyricsFileStateDir != dir || info == nil {
		return 0, false
	}
	s, ok := lyricsFileStateFiles[name]
	if !ok || s.Size != info.Size() || s.ModNs != info.ModTime().UnixNano() {
		return 0, false
	}
	return s.CRC, true
}

func recordLyricsFile(dir, name string, info fs.FileInfo, crc uint32) {
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	if lyricsFileStateReady && lyricsFileStateDir == dir && info != nil {
		lyricsFileStateFiles[name] = lyricsStampOf(info, crc)
	}
}

func forgetLyricsFile(dir, name string) {
	lyricsFileStateMu.Lock()
	defer lyricsFileStateMu.Unlock()
	if lyricsFileStateReady && lyricsFileStateDir == dir {
		delete(lyricsFileStateFiles, name)
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
	}
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
		if info, err := e.Info(); err == nil {
			out[e.Name()] = info
		}
	}
	return out
}

func lyricsCRC(b []byte) uint32 { return crc32.ChecksumIEEE(b) }
