package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	neturl "net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// 存量条目里从本机曲库记下的曲目 id 按 localLibraryEntryFits 重核一遍(09 章决策 221):网易云链接、QQ 链接(连同
// 专辑 / 歌手 mid)、汽水链接(连同专辑 / 歌手 id)、网易云的播放器封面。记下的那条是本机曲库里这一条(歌手 + 歌名)
// 的候选之一、专辑跟这一条对不上、两边时长都知道、localLibraryEntryFits 不认它的,那一组清掉。时长缺一边时判不了,
// 不动。专辑对得上(或缺一边)的不判:那一支时长未知照认,清了下次播放还是记回同一条;条目时长也可能只是试听段。
//
// 这几样记错了都不会自己改对:链接只在空着时补,播放器封面和汽水的 id 读不到新值时留着旧的。清掉网易云或 QQ 链接的
// 条目外围补全计数归零:下次播到时 needsPeripheralBackfill 把空链接算作缺,按现在的判据重查。播放器封面、汽水的 id
// 下次用那个播放器放这首时重记。
//
// 要读别的 App 的本机数据(sqlite3 子进程、队列文件),放后台跑、不挡启动。有一家这一轮读不了就不记水位,下次启动
// 再来;没装的那家算读过。
const (
	migrationLocalLibraryLinks        = "local_library_links"
	migrationLocalLibraryLinksVersion = 1

	// localLibraryLinkRecheckDelay:启动后等这么久再开始,让开启动那阵子的取词和扫库。
	localLibraryLinkRecheckDelay = 2 * time.Minute
)

// localLibraryIndexes 是重核用的三家本机索引,跟各自的 *LocalIndex 是同一份(刷新时整份换、不原地改,所以放锁之后
// 照样能读)。某一家是 nil 时那一家什么都判不出来。
type localLibraryIndexes struct {
	netease map[string][]neteaseLocalTrack
	qq      map[string][]qqLocalEntry
	soda    map[string][]sodaLocalTrack
}

// localLibraryLinkVerdict:一条里哪几组要清。notes 给日志看:哪一家、记下的是哪一条、那条的专辑和时长。
type localLibraryLinkVerdict struct {
	neteaseSong, neteaseCover, qqSong, sodaSong bool
	notes                                       []string
}

func (v localLibraryLinkVerdict) any() bool {
	return v.neteaseSong || v.neteaseCover || v.qqSong || v.sodaSong
}

// localLibraryLinkStale:条目(专辑 album、时长 secs)记下的那条本机曲目(专辑 entryAlbum、时长 entrySecs)是另一张专辑
// 里的、现在不认。专辑对得上或缺一边、时长缺一边时都不算(见头注)。纯函数。
func localLibraryLinkStale(album, entryAlbum string, secs, entrySecs float64) bool {
	if album == "" || entryAlbum == "" || normLoose(album) == normLoose(entryAlbum) {
		return false
	}
	return secs > 0 && entrySecs > 0 && !localLibraryEntryFits(album, entryAlbum, secs, entrySecs)
}

// staleLocalLibraryLinks 判一条:key / e 里记下的 id 是不是本机曲库里这一条(歌手 + 歌名)的候选、又不被认。候选的
// 取法同 neteaseLocalEntry / qqLocalMatch / sodaLocalCatalogTrack。纯函数。
func staleLocalLibraryLinks(key string, e enrichEntry, idx localLibraryIndexes) localLibraryLinkVerdict {
	var v localLibraryLinkVerdict
	secs := e.DurationSecs
	if secs <= 0 {
		secs = e.ResolvedDurationSecs
	}
	if secs <= 0 {
		return v
	}
	artist, title, album := splitEnrichKey(key)
	title = enrichKeyDurationVariantRe.ReplaceAllString(title, "")
	note := func(lib, id, entryAlbum string, entrySecs float64) {
		v.notes = append(v.notes, fmt.Sprintf("%s %s %q %.1fs vs %.1fs", lib, id, entryAlbum, entrySecs, secs))
	}

	netease := idx.netease[neteaseLocalKey(artist, title)]
	if id := neteaseSongIDFromURL(e.NeteaseURL); id != "" {
		for _, t := range netease {
			if strconv.FormatInt(int64(t.ID), 10) == id && localLibraryLinkStale(album, t.Album.Name, secs, t.Duration/1000) {
				v.neteaseSong = true
				note("netease", id, t.Album.Name, t.Duration/1000)
				break
			}
		}
	}
	// 播放器封面是专辑图,同一张图可能挂在好几条候选上:有一条认得(或判不了)就不清。
	if cover := e.PlayerCovers[neteaseMusicBundleID]; cover != "" {
		var rejected *neteaseLocalTrack
		kept := false
		for i := range netease {
			t := &netease[i]
			if neteaseHTTPSImage(t.Album.PicURL) != cover {
				continue
			}
			if localLibraryLinkStale(album, t.Album.Name, secs, t.Duration/1000) {
				rejected = t
			} else {
				kept = true
			}
		}
		if rejected != nil && !kept {
			v.neteaseCover = true
			note("netease cover", strconv.FormatInt(int64(rejected.ID), 10), rejected.Album.Name, rejected.Duration/1000)
		}
	}
	if mid := qqMidFromURL(e.QQURL); mid != "" {
		for _, c := range idx.qq[qqLocalKey(artist, title)] {
			if c.mid == mid && localLibraryLinkStale(album, c.album, secs, c.duration) {
				v.qqSong = true
				note("qq", mid, c.album, c.duration)
				break
			}
		}
	}
	if id := sodaTrackIDFromURL(e.SodaURL); id != "" {
	soda:
		for _, a := range sodaArtistCandidates(artist) {
			for _, t := range idx.soda[sodaLocalKey(a, title)] {
				entrySecs := float64(t.Duration) / 1000
				if strings.TrimSpace(t.ID) == id && localLibraryLinkStale(album, t.Album.Name, secs, entrySecs) {
					v.sodaSong = true
					note("soda", id, t.Album.Name, entrySecs)
					break soda
				}
			}
		}
	}
	return v
}

// sodaTrackIDFromURL 取汽水分享页地址(sodaTrackPageURL 拼的那种)里的曲目 id,取不到或形状不对返回空串。
func sodaTrackIDFromURL(u string) string {
	p, err := neturl.Parse(u)
	if err != nil {
		return ""
	}
	id := p.Query().Get("track_id")
	if !playerCatalogIDOK(sodaMusicBundleID, id) {
		return ""
	}
	return id
}

// clearStaleLocalLibraryLinks 清掉判定不认的那几组。清了网易云或 QQ 链接时外围补全计数归零,needsPeripheralBackfill
// 才会把空链接算作缺。播放器封面换整张表、不原地改:表跟落盘那份快照共用(同 applyPlayerCoverLocked)。
func clearStaleLocalLibraryLinks(e enrichEntry, v localLibraryLinkVerdict) enrichEntry {
	if v.neteaseSong {
		e.NeteaseURL = ""
	}
	if v.neteaseCover {
		var covers map[string]string
		for k, c := range e.PlayerCovers {
			if k == neteaseMusicBundleID {
				continue
			}
			if covers == nil {
				covers = make(map[string]string, len(e.PlayerCovers))
			}
			covers[k] = c
		}
		e.PlayerCovers = covers
	}
	if v.qqSong {
		e.QQURL, e.QQAlbumMid, e.QQSingerMid = "", "", ""
	}
	if v.sodaSong {
		e.SodaURL, e.SodaAlbumID, e.SodaArtistID = "", "", ""
	}
	if v.neteaseSong || v.qqSong {
		e.PeripheralRetryCount = 0
	}
	return e
}

// localLibraryReadable:刷新过一次之后,这一家拿得出能判的索引吗。没装(没有路径、文件不在)算拿得出,本来就没有要判
// 的;读成过一次(readAt 非零)也算。撞锁、被系统拒、格式不认识、一次都没读成的不算。
func localLibraryReadable(path string, readAt time.Time) bool {
	if path == "" {
		return true
	}
	if st, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) || (err == nil && st.IsDir()) {
		return true
	}
	return !readAt.IsZero()
}

func neteaseLocalIndexForRecheck(ctx context.Context) (map[string][]neteaseLocalTrack, bool) {
	neteaseLocalMu.Lock()
	defer neteaseLocalMu.Unlock()
	refreshNeteaseLocalIndexLocked(ctx)
	return neteaseLocalIndex, localLibraryReadable(neteaseLocalDBPath(), neteaseLocalDBMod)
}

func qqLocalIndexForRecheck(ctx context.Context) (map[string][]qqLocalEntry, bool) {
	qqLocalMu.Lock()
	defer qqLocalMu.Unlock()
	refreshQQLocalIndexLocked(ctx)
	return qqLocalIndex, localLibraryReadable(qqLocalDBPath(), qqLocalDBMod)
}

func sodaLocalIndexForRecheck() (map[string][]sodaLocalTrack, bool) {
	sodaLocalMu.Lock()
	defer sodaLocalMu.Unlock()
	refreshSodaLocalIndexLocked()
	return sodaLocalIndex, localLibraryReadable(sodaLocalQueuePath(), sodaLocalMod)
}

// startLocalLibraryLinkRecheck:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startLocalLibraryLinkRecheck(ctx context.Context) {
	scope := migrationScopeOf(migrationLocalLibraryLinks, migrationLocalLibraryLinksVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(localLibraryLinkRecheckDelay):
		}
		recheckLocalLibraryLinks(ctx, scope)
	}()
}

// recheckLocalLibraryLinks 是重核的本体,返回清掉了几条。读本机数据在锁外;判和清在同一段 enrichMu 里,中间不放锁。
func recheckLocalLibraryLinks(ctx context.Context, scope migrationScope) int {
	var idx localLibraryIndexes
	var neteaseOK, qqOK, sodaOK bool
	idx.netease, neteaseOK = neteaseLocalIndexForRecheck(ctx)
	idx.qq, qqOK = qqLocalIndexForRecheck(ctx)
	idx.soda, sodaOK = sodaLocalIndexForRecheck()
	if ctx.Err() != nil {
		return 0
	}
	complete := neteaseOK && qqOK && sodaOK

	checked, cleared := 0, 0
	var neteaseSongs, neteaseCovers, qqSongs, sodaSongs int
	enrichMu.Lock()
	for k, e := range scope.entries() {
		checked++
		v := staleLocalLibraryLinks(k, e, idx)
		if !v.any() {
			continue
		}
		log.Printf("local library links: %q recorded another version (%s), clearing it", k, strings.Join(v.notes, "; "))
		enrichCache[k] = clearStaleLocalLibraryLinks(e, v)
		cleared++
		if v.neteaseSong {
			neteaseSongs++
		}
		if v.neteaseCover {
			neteaseCovers++
		}
		if v.qqSong {
			qqSongs++
		}
		if v.sodaSong {
			sodaSongs++
		}
	}
	if cleared > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if cleared > 0 {
		saveEnrichCache()
	}
	log.Printf("local library links: %d entries checked, %d cleared (netease %d, netease cover %d, qq %d, soda %d), complete=%v",
		checked, cleared, neteaseSongs, neteaseCovers, qqSongs, sodaSongs, complete)
	if complete {
		markMigrationDone(migrationLocalLibraryLinks, migrationLocalLibraryLinksVersion)
	}
	return cleared
}
