package main

import (
	"context"
	"errors"
	"io/fs"
	"log"
	"os"
	"slices"
	"sort"
	"time"
)

// 存量条目里记着同名另一条写法(用 Amazon 放过的)那个 ASIN 的 ISRC 的,拿掉(09 章决策 225)。按歌手 + 歌名认 ASIN
// (amazonASINFor 的队列、整份缓存索引两条退路)分不开同名的几版,那个号又排在第一个、不过时长闸。只拿能确定不是这一条
// 录音的:两条写法一条标明删减版、一条标明不删减版(explicitnessConflict)。其余的(单曲与专辑版、没标的与标了的)多半
// 是同一份录音,留着。
//
// 要读 Amazon Music 的本机目录缓存,放后台跑、不挡启动。读不了不记水位,下次启动再来;没装过 Amazon Music 算读过。
const (
	migrationAmazonBorrowedISRCs        = "amazon_borrowed_isrcs"
	migrationAmazonBorrowedISRCsVersion = 1

	// amazonBorrowedISRCDelay:启动后等这么久再开始,让开启动那阵子的取词和扫库。
	amazonBorrowedISRCDelay = 2 * time.Minute
)

// amazonBorrowedISRCs:targets 里每条写法要拿掉的 ISRC(去重、排好序)。owners 是找「同名另一条写法」的范围(整份缓存),
// isrcOf 是本机目录缓存里曲目 ASIN → ISRC(buildAmazonISRCIndex)。纯函数。
func amazonBorrowedISRCs(targets, owners map[string]enrichEntry, isrcOf map[string]string) map[string][]string {
	type owner struct{ key, asin string }
	byIdentity := map[string][]owner{}
	for k, e := range owners {
		if asin := amazonASINFromTrackURL(e.AmazonURL); asin != "" {
			artist, title, _ := splitEnrichKey(k)
			id := amazonTrackIdentity(artist, title)
			byIdentity[id] = append(byIdentity[id], owner{k, asin})
		}
	}
	out := map[string][]string{}
	for k, e := range targets {
		if len(e.ISRCs) == 0 {
			continue
		}
		artist, title, album := splitEnrichKey(k)
		own := isrcOf[amazonASINFromTrackURL(e.AmazonURL)]
		var drop []string
		for _, w := range byIdentity[amazonTrackIdentity(artist, title)] {
			code := isrcOf[w.asin]
			if w.key == k || code == "" || code == own || slices.Contains(drop, code) ||
				!slices.ContainsFunc(e.ISRCs, func(c string) bool { return normalizeISRC(c) == code }) {
				continue
			}
			if _, wt, wal := splitEnrichKey(w.key); explicitnessConflict(title, album, wt, wal) {
				drop = append(drop, code)
			}
		}
		if len(drop) > 0 {
			sort.Strings(drop)
			out[k] = drop
		}
	}
	return out
}

// amazonCatalogReadable:Amazon Music 的本机目录缓存这一轮读得了。目录不存在(没装、没用过)也算读过:没有可比的号,
// 什么都不用改。
func amazonCatalogReadable(dir string) bool {
	if dir == "" {
		return true
	}
	_, err := os.ReadDir(dir)
	return err == nil || errors.Is(err, fs.ErrNotExist)
}

// startAmazonBorrowedISRCCleanup:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startAmazonBorrowedISRCCleanup(ctx context.Context) {
	scope := migrationScopeOf(migrationAmazonBorrowedISRCs, migrationAmazonBorrowedISRCsVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(amazonBorrowedISRCDelay):
		}
		if !amazonCatalogReadable(amazonLocalStorageDir()) {
			log.Printf("amazon isrc cleanup: catalog cache unreadable, retrying next launch")
			return
		}
		cleanAmazonBorrowedISRCs(scope, buildAmazonISRCIndex())
	}()
}

// cleanAmazonBorrowedISRCs 按 isrcOf 拿掉 scope 里借来的号、记水位,返回改了几条。
func cleanAmazonBorrowedISRCs(scope migrationScope, isrcOf map[string]string) int {
	enrichMu.Lock()
	targets := map[string]enrichEntry{}
	for k, e := range scope.entries() {
		if len(e.ISRCs) > 0 {
			targets[k] = e
		}
	}
	drops := amazonBorrowedISRCs(targets, enrichCache, isrcOf)
	keys := make([]string, 0, len(drops))
	for k := range drops {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		e := enrichCache[k]
		removeISRCs(&e, func(c string) bool { return slices.Contains(drops[k], c) })
		enrichCache[k] = e
		log.Printf("amazon isrc cleanup: %q carried %v from another entry's Amazon track, dropping it", k, drops[k])
	}
	if len(keys) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if len(keys) > 0 {
		saveEnrichCache()
	}
	log.Printf("amazon isrc cleanup: %d entries with isrcs checked, %d cleaned", len(targets), len(keys))
	markMigrationDone(migrationAmazonBorrowedISRCs, migrationAmazonBorrowedISRCsVersion)
	return len(keys)
}
