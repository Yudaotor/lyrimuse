//go:build devtools

package main

import (
	"fmt"
	"log"
	"path/filepath"
)

// loadEnrichForMaintenance 是维护命令(resync-lyrics / cross-album-reuse)读缓存的统一入口,顺序同常驻进程启动:先载 JSON,再让 lyrics/ 文件族
// 覆盖六个歌词字段(文件永远赢)。调用前要先 setFeatures(歌词文件夹的设置在里面)。
//
// 常驻进程只在启动时导入 lyrics/,它运行期间用户手改 / 删掉的文件只在文件里;跳过导入就拿过期的 JSON 去重新
// 导出,会把这些改动盖掉。反过来,改了歌词字段却不导出,常驻进程下次启动导入时文件赢,改动被还原 —— 所以
// 这几条命令改完歌词字段都要 exportLyricsFiles。
//
// apply=false 是预演,常驻进程可能正在跑:只读载入,不落盘,也不清歌词临时文件。歌词同步开着时 apply 直接退出
// (maintenanceSharingRefusal)。
func loadEnrichForMaintenance(cfgDir string, apply bool) {
	if err := maintenanceSharingRefusal(apply); err != nil {
		log.Fatal(err)
	}
	defaultLyricsDir = filepath.Join(cfgDir, "lyrics")
	setLyricsDir(resolveLyricsDir(features().LyricsDir))
	path := filepath.Join(cfgDir, clientName+"-enrich-cache.json")
	if apply {
		loadEnrichCache(path)
		importLyricsFromFiles()
		return
	}
	loadEnrichCacheReadOnly(path)
	importLyricsFromFilesReadOnly()
}

// importLyricsFromFilesReadOnly 同 importLyricsFromFiles,给常驻进程可能正在跑时的一次性命令预演用:只改内存,
// 不落盘,也不清歌词临时文件(可能是常驻进程写到一半的)。
func importLyricsFromFilesReadOnly() []string { return importLyricsFrom(lyricsDir(), false) }

// maintenanceSharingRefusal:歌词同步开着(songEntitySharing)时维护命令不许真写:它们按写法一条条重选或对齐歌词,会把同一首歌
// 同步好的歌词打散,改过的写法关开关时也不再按留底恢复(18 章决策 32)。预演照常。
func maintenanceSharingRefusal(apply bool) error {
	if apply && songEntitySharing() {
		return fmt.Errorf("lyrics sharing is on (song_entity_share_lyrics): turn it off before rewriting lyrics with -apply")
	}
	return nil
}
