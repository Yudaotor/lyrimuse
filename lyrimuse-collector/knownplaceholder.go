package main

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"path/filepath"
	"strings"
)

// 播放器自己推给 MediaRemote 的**内置占位图**登记表,跟 App 侧 LyrimuseCore/Local/KnownPlaceholderArtwork.swift
// 同一份指纹(两边必须同步改,TestKnownPlaceholderArtworkMatchesSwift 盯着)。
//
// 有的播放器换歌后先推一张自带的通用图(酷狗 3.3.2:35427 字节的蓝底黑胶唱片,几秒后才换成真封面)。
// 它是一张合法的 600×600 JPEG,decodeDeviceArtwork 的边长 / 长宽比门槛拦不住。设备封面一旦落成
// cover_source == "device" 就不再换源(见 coverSwapAllowed),真图没在 settleDeviceCover 那几档里
// 出现的话,这张唱片就永久挂在这首歌上。
//
// 判据是整份字节的 SHA-256,只登记亲手量过指纹的图。播放器换一版内置图就对不上,失效是无害的:
// 退回没有这张表时的行为(靠 settleDeviceCover 按时间多问几次)。
type knownPlaceholder struct {
	byteCount int
	sha256Hex string
	player    string // 只作记录,判定不看它
}

var knownPlaceholderArtwork = []knownPlaceholder{
	{byteCount: 35427, sha256Hex: "56301adc2c97955b3af286bb51f109cab83278da94b9bdb101374159fc866996", player: "com.kugou.mac.Music"},
}

// isKnownPlaceholderArtwork:这份封面字节是不是登记在案的占位图。先比字节数,对不上就不算哈希。
func isKnownPlaceholderArtwork(data []byte) bool {
	var sum string
	for _, p := range knownPlaceholderArtwork {
		if p.byteCount != len(data) {
			continue
		}
		if sum == "" {
			h := sha256.Sum256(data)
			sum = hex.EncodeToString(h[:])
		}
		if sum == p.sha256Hex {
			return true
		}
	}
	return false
}

// isKnownPlaceholderCoverURL:设备封面落盘的文件名是内容 SHA-256 的前 8 字节(见 saveDeviceArtwork),
// 按文件名认出已经存成封面的占位图。
func isKnownPlaceholderCoverURL(coverURL string) bool {
	if !strings.HasPrefix(coverURL, "file://") {
		return false
	}
	name := filepath.Base(coverURL)
	stem := strings.TrimSuffix(name, filepath.Ext(name))
	for _, p := range knownPlaceholderArtwork {
		if len(p.sha256Hex) >= 16 && stem == p.sha256Hex[:16] {
			return true
		}
	}
	return false
}

// migrateKnownPlaceholderCovers 把已经存成设备封面的占位图清掉:封面四件套一起清(不留新图配旧主色的
// 组合),这首歌下次被播到时由设备封面升级(applyDeviceCoverUpgrade)换上真图,占位图本身已被
// deviceCoverURLIfFresh 拦在外面。清完再跑一条都不匹配,不需要版本标记。
func migrateKnownPlaceholderCovers() {
	enrichMu.Lock()
	var cleared []string
	for k, e := range enrichCache {
		if e.CoverSource != "device" || !isKnownPlaceholderCoverURL(e.CoverURL) {
			continue
		}
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = "", "", "", ""
		enrichCache[k] = e
		cleared = append(cleared, k)
	}
	if len(cleared) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if len(cleared) == 0 {
		return
	}
	log.Printf("placeholder cover migration: cleared a player's built-in placeholder cover on %d entries: %q", len(cleared), cleared)
	saveEnrichCache()
}
