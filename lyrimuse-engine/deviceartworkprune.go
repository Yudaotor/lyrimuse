package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 设备直送封面目录(artwork/)的清理,和指向本机没有的设备封面的条目字段的修复。见 03 章决策 59。
//
// 删一张图要三条都满足:文件名是 saveDeviceArtwork 起的那种;没有任何地方引用它(缓存里每一条整条序列化之后找路径,
// 不按字段名挑:封面、按专辑定下的封面、视频帧、动态封面和公开封面「对着哪张封面核的」都存这个路径,以后多一个字段也
// 算得上;再加上歌曲实体同步的留底和正在播那一条的快照);deviceArtworkPruneMinAge 之内没被用过(saveDeviceArtwork
// 复用已有文件时刷新修改时间)。待采纳的恢复文件还在时这一轮不跑:那份里的路径还没进缓存。
//
// 修:cover_url / cover_settled / video_frame_url 指向一张本机不存在的设备封面时清空,后台补封面、借同专辑的封面、
// 下次播到时会重新取。配置搬家、恢复备份带进来的是别处的路径,不清的话这一条会一直指着一个不存在的文件。

const (
	deviceArtworkPruneDelay   = 3 * time.Minute
	deviceArtworkPruneEvery   = 24 * time.Hour
	deviceArtworkPruneMinAge  = 7 * 24 * time.Hour
	deviceArtworkPruneStamp   = ".last-prune"
	deviceArtworkRefSeparator = "/artwork/"
)

// startDeviceArtworkPrune 在常驻进程起来 deviceArtworkPruneDelay 之后跑一次清理(不到一天的话这次跳过)。
func startDeviceArtworkPrune(ctx context.Context) {
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(deviceArtworkPruneDelay):
		}
		pruneDeviceArtworkIfDue(time.Now())
	}()
}

// pruneDeviceArtworkIfDue 跑一轮修复和清理,返回清掉的失效字段数、删掉的文件数。上一轮不到 deviceArtworkPruneEvery 就不跑。
func pruneDeviceArtworkIfDue(now time.Time) (cleared, removed int) {
	if deviceArtworkDir == "" {
		return 0, 0
	}
	stamp := filepath.Join(deviceArtworkDir, deviceArtworkPruneStamp)
	if info, err := os.Stat(stamp); err == nil && now.Sub(info.ModTime()) < deviceArtworkPruneEvery {
		return 0, 0
	}
	if enrichRestorePath != "" {
		if _, err := os.Stat(enrichRestorePath); err == nil {
			return 0, 0
		}
	}
	entries, err := os.ReadDir(deviceArtworkDir)
	if err != nil {
		return 0, 0
	}

	// 锁里只修和拷一份,整条序列化在锁外做:几万条一起序列化要占住缓存锁好一阵。
	enrichMu.Lock()
	snapshot := make([]enrichEntry, 0, len(enrichCache))
	for key, e := range enrichCache {
		if clearMissingDeviceArtwork(&e) {
			enrichCache[key] = e
			cleared++
		}
		snapshot = append(snapshot, e)
	}
	if cleared > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if cleared > 0 {
		saveEnrichCache()
	}
	refs := map[string]bool{}
	for _, e := range snapshot {
		b, err := json.Marshal(e)
		if err != nil {
			return cleared, 0
		}
		collectDeviceArtworkRefs(b, refs)
	}
	if !collectDeviceArtworkRefsInFiles(refs) {
		return cleared, 0
	}

	var freed int64
	for _, ent := range entries {
		name := ent.Name()
		if ent.IsDir() || !isDeviceArtworkFileName(name) || refs[name] {
			continue
		}
		path := filepath.Join(deviceArtworkDir, name)
		// 修改时间现取:列目录之后 saveDeviceArtwork 可能刚复用过这张。
		info, err := os.Stat(path)
		if err != nil || now.Sub(info.ModTime()) < deviceArtworkPruneMinAge {
			continue
		}
		if os.Remove(path) == nil {
			removed++
			freed += info.Size()
		}
	}
	_ = writeFileAtomic(stamp, nil)
	if cleared > 0 || removed > 0 {
		log.Printf("device artwork: cleared %d field(s) pointing to missing files, removed %d unreferenced file(s), freed %d KB",
			cleared, removed, freed/1024)
	}
	return cleared, removed
}

// clearMissingDeviceArtwork 把指向本机不存在的设备封面的封面字段清空,返回有没有改。封面那张没了时来源、专辑、主色一起清
// (同 migrateKnownPlaceholderCovers):只清地址、来源还记着 device 的话,放歌时不再取设备封面,外围补全也换不进新封面。
func clearMissingDeviceArtwork(e *enrichEntry) bool {
	changed := false
	if deviceArtworkMissing(e.CoverURL) {
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = "", "", "", ""
		changed = true
	}
	for _, field := range []*string{&e.CoverSettled, &e.VideoFrameURL} {
		if deviceArtworkMissing(*field) {
			*field = ""
			changed = true
		}
	}
	return changed
}

// deviceArtworkMissing:url 是一张设备封面的 file:// 地址(在某台机器的 artwork/ 下),而这台机器上没有这个文件。
// 读不了文件、但不是「不存在」的(权限之类)不算缺。
func deviceArtworkMissing(url string) bool {
	_, path, ok := deviceArtworkRef(url)
	if !ok || filepath.Base(filepath.Dir(path)) != "artwork" {
		return false
	}
	_, err := os.Stat(path)
	return errors.Is(err, fs.ErrNotExist)
}

// collectDeviceArtworkRefsInFiles 把歌曲实体同步的留底和正在播那一条的快照里引用的设备封面也记进 refs。
// 留底目录读不了(不是不存在)时返回 false,这一轮不删。
func collectDeviceArtworkRefsInFiles(refs map[string]bool) bool {
	var paths []string
	if enrichPath != "" {
		paths = append(paths, playingEntryPathFor(enrichPath))
	}
	if dir := songSharePreDir(); dir != "" {
		names, err := os.ReadDir(dir)
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return false
		}
		for _, n := range names {
			if !n.IsDir() {
				paths = append(paths, filepath.Join(dir, n.Name()))
			}
		}
	}
	for _, p := range paths {
		b, err := os.ReadFile(p)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return false
		}
		collectDeviceArtworkRefs(b, refs)
	}
	return true
}

// collectDeviceArtworkRefs 在一段 JSON 里找 "/artwork/<16 位十六进制>.jpg|png",把文件名记进 refs。
func collectDeviceArtworkRefs(b []byte, refs map[string]bool) {
	sep := []byte(deviceArtworkRefSeparator)
	for {
		i := bytes.Index(b, sep)
		if i < 0 {
			return
		}
		b = b[i+len(sep):]
		end := 0
		for end < len(b) && end < 24 && b[end] != '"' && b[end] != '\\' {
			end++
		}
		if name := string(b[:end]); isDeviceArtworkFileName(name) {
			refs[name] = true
		}
	}
}

// isDeviceArtworkFileName:saveDeviceArtwork 起的名字,内容 sha256 前 8 字节的十六进制加 .jpg / .png。
func isDeviceArtworkFileName(name string) bool {
	ext := filepath.Ext(name)
	if ext != ".jpg" && ext != ".png" {
		return false
	}
	return isHex16(strings.TrimSuffix(name, ext))
}
