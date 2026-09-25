package main

import (
	"bytes"
	"fmt"
	"hash/crc32"
	"log"
	"os"
	"path/filepath"
	"time"
)

// 撤回:一首歌播放中途身份被纠正(见 trustedlyricartist.go)之后,把它之前用过的那个错身份
// 留下的缓存条目收回来。
//
// 错身份在纠正落定之前已经被当成一首歌处理过:换歌那一拍就发起了整轮歌词搜索,搜完不管有没有
// 结果都会落一条缓存(commitEnrichEntry),有歌词还会导出成文件。不收回的话它会一直留在「歌词
// 管理」里,补空扫描之后还会在上面反复重搜。
//
// 收回三件事:还在搜的取消;TTL 内这个 key 一律不准再落盘(commitEnrichEntry 里查);since
// 之后写下的条目连同导出的歌词文件删掉。since 之前就有的条目不动 —— 那是这首歌开播前就存在的,
// 不归这次撤回管。歌词文件必须一起删:importLyricsFromFiles 启动时会按文件头把它重建成条目。

// enrichRetractTTL:撤回之后多久内拦着这个 key 落盘。要盖住一轮搜索的最长耗时(20 秒截止,
// 加外围补全),又不能永久拦 —— 同一个 key 以后正常播放到时要能照常建条目。
const enrichRetractTTL = 10 * time.Minute

// enrichRetracted:撤回的 key 到撤回时刻。由 enrichMu 保护。
var enrichRetracted = map[string]time.Time{}

// retractEnrichKeys 撤回这几个 key,见文件头。会取 enrichMu,别在持有它的时候调。
func retractEnrichKeys(keys []string, since time.Time) {
	if len(keys) == 0 {
		return
	}
	now := time.Now()
	var removed []string
	enrichMu.Lock()
	for k, at := range enrichRetracted {
		if now.Sub(at) > enrichRetractTTL {
			delete(enrichRetracted, k)
		}
	}
	for _, k := range keys {
		enrichRetracted[k] = now
		if cancel, ok := enrichCancelFuncs[k]; ok {
			cancel()
		}
		if e, ok := enrichCache[k]; ok && e.TS >= since.Unix() {
			delete(enrichCache, k)
			enrichDirty = true
			removed = append(removed, k)
		}
	}
	enrichMu.Unlock()
	for _, k := range keys {
		log.Printf("enrich: retracted %q (superseded by a corrected identity)", k)
	}
	if len(removed) == 0 {
		return
	}
	saveEnrichCache()
	for _, k := range removed {
		removeLyricsFilesFor(k)
		removeDecisionSidecar(k)
	}
}

// enrichKeyRetractedLocked:这个 key 此刻是否在撤回期内。调用方必须持有 enrichMu。
func enrichKeyRetractedLocked(key string) bool {
	at, ok := enrichRetracted[key]
	return ok && time.Since(at) <= enrichRetractTTL
}

// removeLyricsFilesFor 删掉这个 key 导出过的歌词文件,见 lyricsFilesOwnedBy。
func removeLyricsFilesFor(key string) {
	for _, path := range lyricsFilesOwnedBy(key) {
		_ = os.Remove(path)
	}
}

// lyricsFilesOwnedBy 列出这个 key 导出过、此刻还在的歌词文件。文件名有三种:普通名、撞车消歧时加
// `~<crc32 低 24 位>` 后缀的(见 exportLyricsFilesMatching)、加长度上限之前截断前的长名字,都试;只列文件头的 ar/ti/al 跟这个 key 对得上的,
// 别的 key 恰好落在同一个文件名上时不算。
func lyricsFilesOwnedBy(key string) []string {
	dir := lyricsDir()
	if dir == "" {
		return nil
	}
	artist, title, album := splitEnrichKey(key)
	want := []byte(fmt.Sprintf("[ar:%s]\n[ti:%s]\n[al:%s]\n", artist, title, album))
	base := sanitizeLyricsFilename(key)
	hashed := fmt.Sprintf("%s~%06x", base, crc32.ChecksumIEEE([]byte(key))&0xFFFFFF)
	bases := []string{base, hashed}
	// 加长度上限之前导出的存量文件用的是截断前那个更长的名字;漏掉它,下次启动导入会按文件头把条目复活。
	if untruncated := sanitizeLyricsFilenameUntruncated(key); untruncated != base {
		bases = append(bases, untruncated)
	}
	var out []string
	for _, b := range bases {
		for _, suffix := range lyricsFileSuffixes {
			path := filepath.Join(dir, b+suffix)
			data, err := os.ReadFile(path)
			if err != nil || !bytes.HasPrefix(data, want) {
				continue
			}
			out = append(out, path)
		}
	}
	return out
}
