package main

import (
	"log"
	"sync"
	"sync/atomic"
	"time"
)

// 歌词文件夹(features.json 的 lyrics_dir)在常驻进程里热切换。
//
// 切换 = 先把新目录里已有的文件导入缓存(新目录的文件赢,规则同启动时的 importLyricsFromFiles),
// 再把 lyricsDir() 指过去,最后整份导出一遍,让新目录与缓存对齐。旧目录里的文件原样留着,不搬也不删。
// 顺序不能换:先指过去再导入的话,这段时间里写进新目录的导出会被导入那一步当成用户文件读回来,
// 而导入开头清临时文件那一步可能删掉正在写的那一份。

// defaultLyricsDir 是 lyrics_dir 留空时的位置(config.json 同目录下的 lyrics/),由 main() 设好。
var defaultLyricsDir string

// lyricsDirSwitchReady 在启动迁移跑完之后才置上。在那之前切换会跟启动路径上的导入导出、存量迁移
// 同时改缓存和文件夹,所以一律跳过,由 enableLyricsDirSwitch 收尾时补一次。
var lyricsDirSwitchReady atomic.Bool

// lyricsDirSwitchMu 让切换一次只跑一趟;连着改了几次时,后面排队的那趟会先看自己是不是已经过时。
var lyricsDirSwitchMu sync.Mutex

// resolveLyricsDir 把设置值换成实际目录:留空 = 默认位置。
func resolveLyricsDir(setting string) string {
	if setting == "" {
		return defaultLyricsDir
	}
	return setting
}

// switchLyricsDir 把歌词文件夹换到 setting 指的位置。setting 已经不是当前设置(期间又改过)时什么都不做,
// 交给最新那一趟。
func switchLyricsDir(setting string) {
	if !lyricsDirSwitchReady.Load() {
		return
	}
	lyricsDirSwitchMu.Lock()
	defer lyricsDirSwitchMu.Unlock()
	if features().LyricsDir != setting {
		return
	}
	dir := resolveLyricsDir(setting)
	if dir == "" || dir == lyricsDir() {
		return
	}
	start := time.Now()
	adopted := importLyricsFromDir(dir)
	if adopted > 0 {
		// 新目录里的文件是外来数据,可能停在更早的形态:下次启动让存量迁移照常全量跑一遍。
		invalidateMigrationState("lyrics dir switched")
	}
	setLyricsDir(dir)
	exportLyricsFiles()
	log.Printf("lyrics dir: switched without a restart adopted=%d took=%s", adopted, time.Since(start).Round(10*time.Millisecond))
}

// enableLyricsDirSwitch 放开热切换,并补上启动期间可能漏掉的那次改动(没改过就是空操作)。
func enableLyricsDirSwitch() {
	lyricsDirSwitchReady.Store(true)
	switchLyricsDir(features().LyricsDir)
}
