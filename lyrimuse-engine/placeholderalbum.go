package main

import (
	"log"
	"strings"
)

// 播放器报的专辑名是占位、不是一张专辑:咪咕把没归进专辑的歌记在「单曲发行」名下(洛雪列表里那一条的 albumId 是 1),
// 播放器给这些歌的图是歌手照片。封面这几步按没报专辑处理:不拿它跟各源报的专辑比(candidateCoverAlbumFits),
// 选封面时按 Apple 目录回填的专辑(coverAlbumForTrack),不按它把几首归成一张专辑(entryListedAlbum),播放器给的那张不当封面
// (playerCoverURLFor)。跟 App 的 PlaceholderAlbum.swift 同一份名单(selftest 对着这里核)。见 03 章决策 54。
var placeholderAlbumNames = map[string]bool{"单曲发行": true}

// albumIsPlaceholder:这个专辑名是占位名(去掉首尾空白比)。
func albumIsPlaceholder(album string) bool {
	return placeholderAlbumNames[strings.TrimSpace(album)]
}

// coverAlbumOrNone:封面这几步认的专辑名:占位名算没有。
func coverAlbumOrNone(album string) string {
	if albumIsPlaceholder(album) {
		return ""
	}
	return album
}

// migratePlaceholderAlbumCovers:写法键里的专辑是占位名的条目,播放器记下的图(player_covers)是占位名下那张歌手照片,清掉;
// 封面就是它(cover_source=player)的,换成歌词判决里头一个自带封面、跟那张照片不是同一个地址的候选(winnerCandidateCoverSkipping,
// 专辑按没报算),没有就清空,等外围补全或后台补封面按 Apple 目录回填的专辑重选。运行期 playerCoverURLFor 不再给这张图,
// 清完再跑一条都不匹配,不用水位。
func migratePlaceholderAlbumCovers() {
	type pending struct {
		key, cover string
		decision   *lyricsDecision
	}
	var list []pending
	enrichMu.Lock()
	for k, e := range enrichCache {
		if _, _, album := splitEnrichKey(k); !albumIsPlaceholder(album) {
			continue
		}
		if len(e.PlayerCovers) == 0 && e.CoverSource != "player" {
			continue
		}
		list = append(list, pending{k, e.CoverURL, e.LyricsDecision})
	}
	enrichMu.Unlock()
	if len(list) == 0 {
		return
	}
	var changed []string
	for _, p := range list {
		cover, source, coverAlbum := "", "", ""
		if d := withDecisionDetails(p.key, p.decision); d != nil {
			cover, source, coverAlbum = winnerCandidateCoverSkipping(d, "", map[string]bool{p.cover: true})
		}
		enrichMu.Lock()
		e, ok := enrichCache[p.key]
		if !ok || e.CoverURL != p.cover || enrichInflight[p.key] {
			enrichMu.Unlock()
			continue
		}
		e.PlayerCovers = nil
		if e.CoverSource == "player" {
			e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = cover, source, coverAlbum, ""
		}
		enrichCache[p.key] = e
		enrichDirty = true
		enrichMu.Unlock()
		changed = append(changed, p.key)
	}
	if len(changed) == 0 {
		return
	}
	log.Printf("placeholder album migration: dropped the player's picture on %d entries: %q", len(changed), changed)
	saveEnrichCache()
}
