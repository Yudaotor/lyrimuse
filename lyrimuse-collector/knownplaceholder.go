package main

import (
	"log"
	"path/filepath"
	"strings"
)

// 播放器自己推给 MediaRemote 的**内置占位图**登记表,跟 App 侧 LyrimuseCore/Local/KnownPlaceholderArtwork.swift
// 同一份指纹(两边必须同步改,TestKnownPlaceholderArtworkMatchesSwift 盯着)。
//
// 有的播放器换歌后先推一张自带的通用图,几秒后才换成真封面(登记表里的 player 记着是谁)。新播放的封面由 App 拦:
// 认出占位图就不写进当前封面文件,collector 拿不到它。这里只用来清掉早先已经存成设备封面的占位图
// (migrateKnownPlaceholderCovers):设备封面落成 cover_source == "device" 就不再换源(见 coverSwapAllowed),
// 不清的话那张图会一直挂在那首歌上。
//
// 判据是整份字节的 SHA-256(设备封面落盘的文件名是它的前 8 字节,见 saveDeviceArtwork),只登记亲手量过指纹的图。
type knownPlaceholder struct {
	byteCount int
	sha256Hex string
	player    string // 只作记录,判定不看它
}

var knownPlaceholderArtwork = []knownPlaceholder{
	{byteCount: 35427, sha256Hex: "56301adc2c97955b3af286bb51f109cab83278da94b9bdb101374159fc866996", player: "com.kugou.mac.Music"},
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
// 组合),这首歌下次被播到时由设备封面升级(applyDeviceCoverUpgrade)换上真图,占位图本身 App
// 不会再交过来。清完再跑一条都不匹配,不需要版本标记。
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
