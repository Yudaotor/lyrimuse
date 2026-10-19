package main

import (
	"bytes"
	"context"
	"log"
	"maps"
	"slices"
	"time"
)

// 存量条目里 Amazon Music 的播放器封面(player_covers)是同名另一版那张专辑的,拿掉(03 章决策 63)。App 还没报当前曲目时
// amazonPlayingCoverURL 按歌手 + 歌名认 ASIN(amazonASINFor 的队列、整份缓存两条退路),单曲与专辑版分不开,记下的是另一张
// 专辑的图;同一条里记着的专辑 ASIN(amazon_album_asin)是那张专辑的也一起错。目录里这一轨的专辑名对不上就不认之后,运行期
// 不再产生。
//
// 判据:本机目录缓存里拿这张图当专辑图的曲目(buildAmazonCoverAlbums),所在专辑的名字都跟这一条的专辑(Amazon Music 报过
// 原样写法的按它)对不上。目录里没有哪一轨用这张图、这一条没有专辑时判不了,不动。拿掉的是这张播放器封面;正在用它当封面
// (cover_source=player,不是专辑定下的)时封面一族一起清、外围补全计数归零;amazon_album_asin 是那几张专辑之一时清掉,由
// backfillPlayerAlbumIDsFromClientCache 按这一条自己的曲目页重记。同专辑借了这张图的条目一起清(同 locallibrarylinks.go)。
//
// 要读 Amazon Music 的本机目录缓存,放后台跑、不挡启动。读不了不记水位,下次启动再来;没装过 Amazon Music 算读过。
const (
	migrationAmazonForeignPlayerCovers        = "amazon_foreign_player_covers"
	migrationAmazonForeignPlayerCoversVersion = 1

	// amazonForeignPlayerCoverDelay:启动后等这么久再开始,让开启动那阵子的取词和扫库。
	amazonForeignPlayerCoverDelay = 2 * time.Minute
)

// amazonCoverAlbum:目录缓存里拿某张图当专辑图的一轨所在的专辑。
type amazonCoverAlbum struct{ name, asin string }

// buildAmazonCoverAlbums 扫一遍目录缓存:单曲记录的专辑图(换成 amazonJPEGImage 那种地址,跟 player_covers 里记的同一种)→
// 拿它当专辑图的那几轨所在的专辑。
func buildAmazonCoverAlbums() map[string][]amazonCoverAlbum {
	prefix := []byte(amazonCatalogKeyPrefix)
	out := map[string][]amazonCoverAlbum{}
	for _, v := range ldbScan(amazonLocalStorageDir(), func(k []byte) bool { return bytes.HasPrefix(k, prefix) }) {
		if v.deleted {
			continue
		}
		var t amazonCatalogTrack
		if !amazonFirstJSONObject(v.value, &t) || t.Title == "" || t.Artist.Name == "" {
			continue
		}
		img, name := amazonJPEGImage(t.Album.Image), t.albumName()
		if img == "" || name == "" {
			continue
		}
		if a := (amazonCoverAlbum{name: name, asin: t.Album.ASIN}); !slices.Contains(out[img], a) {
			out[img] = append(out[img], a)
		}
	}
	return out
}

// amazonForeignPlayerCover:key / e 记着的 Amazon Music 播放器封面是不是另一张专辑的(见头注的判据);是的话给出目录里拿这张图
// 当专辑图的那几张专辑。纯函数。
func amazonForeignPlayerCover(key string, e enrichEntry, coverAlbums map[string][]amazonCoverAlbum) ([]amazonCoverAlbum, bool) {
	cover := e.PlayerCovers[amazonMusicBundleID]
	if cover == "" {
		return nil, false
	}
	_, _, album := splitEnrichKey(key)
	if r, ok := e.Reported[amazonMusicBundleID]; ok && r.Album != "" {
		album = r.Album
	}
	want, albums := amazonAlbumKey(album), coverAlbums[cover]
	if want == "" || len(albums) == 0 {
		return nil, false
	}
	if slices.ContainsFunc(albums, func(a amazonCoverAlbum) bool { return amazonAlbumKey(a.name) == want }) {
		return nil, false
	}
	return albums, true
}

// clearAmazonForeignPlayerCover 拿掉 e 里那张另一张专辑的 Amazon 播放器封面,连同正在用它的封面一族、记成那几张专辑之一的
// 专辑 ASIN。播放器封面换整张表、不原地改(同 applyPlayerCoverLocked)。纯函数。
func clearAmazonForeignPlayerCover(e enrichEntry, albums []amazonCoverAlbum) enrichEntry {
	if staleLocalPlayerCoverInUse(e, e.PlayerCovers[amazonMusicBundleID]) {
		e = withoutCover(e)
		e.PeripheralRetryCount = 0
	}
	covers := maps.Clone(e.PlayerCovers)
	delete(covers, amazonMusicBundleID)
	if len(covers) == 0 {
		covers = nil
	}
	e.PlayerCovers = covers
	if e.AmazonAlbumASIN != "" && slices.ContainsFunc(albums, func(a amazonCoverAlbum) bool { return a.asin == e.AmazonAlbumASIN }) {
		e.AmazonAlbumASIN = ""
	}
	return e
}

// startAmazonForeignPlayerCoverCleanup:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startAmazonForeignPlayerCoverCleanup(ctx context.Context) {
	scope := migrationScopeOf(migrationAmazonForeignPlayerCovers, migrationAmazonForeignPlayerCoversVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(amazonForeignPlayerCoverDelay):
		}
		if !amazonCatalogReadable(amazonLocalStorageDir()) {
			log.Printf("amazon player covers: catalog cache unreadable, retrying next launch")
			return
		}
		cleanAmazonForeignPlayerCovers(scope, buildAmazonCoverAlbums())
	}()
}

// cleanAmazonForeignPlayerCovers 按 coverAlbums 拿掉 scope 里另一张专辑的 Amazon 播放器封面、记水位,返回改了几条。判和清在
// 同一段 enrichMu 里;解析中、提前提交的条目这一轮不动(不记水位,下次启动再来)。改过的几条走待落盘小文件。
func cleanAmazonForeignPlayerCovers(scope migrationScope, coverAlbums map[string][]amazonCoverAlbum) int {
	checked, skipped := 0, false
	var cleared []string
	staleCovers := map[string]map[string]bool{}
	enrichMu.Lock()
	for k, e := range scope.entries() {
		albums, ok := amazonForeignPlayerCover(k, e, coverAlbums)
		checked++
		if !ok {
			continue
		}
		if enrichInflight[k] || enrichProvisional[k] {
			skipped = true
			continue
		}
		cover := e.PlayerCovers[amazonMusicBundleID]
		log.Printf("amazon player covers: %q kept the cover of %q from a same-named track, dropping it", k, albums[0].name)
		if staleLocalPlayerCoverInUse(e, cover) {
			if album := entryListedAlbum(k, e); album != "" {
				simp := toSimplified(album)
				if staleCovers[simp] == nil {
					staleCovers[simp] = map[string]bool{}
				}
				staleCovers[simp][playerCoverDisplayURL(cover)] = true
			}
		}
		enrichCache[k] = clearAmazonForeignPlayerCover(e, albums)
		noteEnrichPendingLocked(k)
		cleared = append(cleared, k)
	}
	if borrowed := clearBorrowedStaleLocalPlayerCoversLocked(staleCovers); len(borrowed) > 0 {
		log.Printf("amazon player covers: cleared the borrowed copies of the dropped covers: %q", borrowed)
		for _, k := range borrowed {
			noteEnrichPendingLocked(k)
		}
		cleared = append(cleared, borrowed...)
	}
	if len(cleared) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if len(cleared) > 0 {
		saveEnrichPendingBatch(cleared)
	}
	log.Printf("amazon player covers: %d entries checked, %d cleared", checked, len(cleared))
	if !skipped {
		scope.markDone(migrationAmazonForeignPlayerCovers, migrationAmazonForeignPlayerCoversVersion)
	}
	return len(cleared)
}
