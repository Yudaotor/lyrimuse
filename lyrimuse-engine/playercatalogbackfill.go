package main

import (
	"context"
	"log"
	"path/filepath"
	"slices"
	"strconv"
	"time"
)

// 存量条目的播放器 id 补记:在某个播放器上放过、当时没记下的(功能上线之前,或那一拍本机数据还没写好),按客户端本机缓存补一次,
// 读法跟播放时读同一份数据的那几处一样,只补没有的(18 章决策 66、67)。引擎起来 playerCatalogSweepDelay 之后跑一次;汽水另在
// 后台问到一批曲目信息之后再补(sodatrackmeta.go)。

// playerCatalogSweepDelay:引擎起来后等这么久再补,不跟启动那一阵抢。
const playerCatalogSweepDelay = 2 * time.Minute

func startPlayerCatalogSweep(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-time.After(playerCatalogSweepDelay):
	}
	backfillSodaPagesFromClientCache()
	backfillPlayerAlbumIDsFromClientCache()
	backfillNeteasePlayerSongsFromHistory(ctx)
	backfillKugouPlayerSongsFromLibrary()
}

// backfillPlayerAlbumIDsFromClientCache:记着 Spotify 曲目 id / Amazon ASIN 却没有那家专辑 id 的条目,按记下的 id 读客户端本机缓存
// 补专辑、歌手 id(读法与形状闸同播放时 spotifyPlayingCatalogIDs / amazonPlayingCatalogIDs,Amazon 的专辑名要跟这条写法的对得上,
// 报过原样写法的按它比)。返回补了几条。
func backfillPlayerAlbumIDsFromClientCache() int {
	type want struct{ key, bundleID, id, album string }
	enrichMu.Lock()
	var wants []want
	for k, e := range enrichCache {
		_, _, album := splitEnrichKey(k)
		if e.SpotifyAlbumID == "" && len(e.SpotifyTrackID) == 22 {
			wants = append(wants, want{k, spotifyBundleID, e.SpotifyTrackID, album})
		}
		if asin := amazonASINFromTrackURL(e.AmazonURL); asin != "" && e.AmazonAlbumASIN == "" {
			if r, ok := e.Reported[amazonMusicBundleID]; ok && r.Album != "" {
				album = r.Album
			}
			wants = append(wants, want{k, amazonMusicBundleID, asin, album})
		}
	}
	enrichMu.Unlock()
	if len(wants) == 0 {
		return 0
	}
	var spotifyKeys [][]byte
	var asins []string
	for _, w := range wants {
		if w.bundleID == spotifyBundleID {
			spotifyKeys = append(spotifyKeys, spotifyXmetaKey(spotifyTrackKind, w.id))
		} else {
			asins = append(asins, w.id)
		}
	}
	var spotifyVals map[string][]byte
	if dir := spotifyActiveUserDir(); dir != "" && len(spotifyKeys) > 0 {
		spotifyVals = ldbGet(filepath.Join(dir, "primary.ldb"), spotifyKeys)
	}
	var catalog map[string]amazonCatalogTrack
	if len(asins) > 0 {
		catalog = amazonCatalog(asins)
	}
	type fill struct {
		key, bundleID string
		ids           playerCatalogIDs
	}
	var fills []fill
	for _, w := range wants {
		var ids playerCatalogIDs
		switch w.bundleID {
		case spotifyBundleID:
			v := spotifyVals[string(spotifyXmetaKey(spotifyTrackKind, w.id))]
			ids = playerCatalogIDs{album: spotifyParseTrackAlbumID(v), artist: spotifyParseTrackArtistID(v)}
		case amazonMusicBundleID:
			t, ok := catalog[w.id]
			if !ok {
				continue
			}
			if name := t.albumName(); w.album != "" && name != "" && loosenEnrichKey(cleanMediaTag(name)) != loosenEnrichKey(cleanMediaTag(w.album)) {
				continue
			}
			ids = playerCatalogIDs{album: t.Album.ASIN, artist: t.Artist.ASIN}
		}
		if !playerCatalogIDOK(w.bundleID, ids.album) {
			continue
		}
		if !playerCatalogIDOK(w.bundleID, ids.artist) {
			ids.artist = ""
		}
		fills = append(fills, fill{w.key, w.bundleID, ids})
	}
	var changed []string
	enrichMu.Lock()
	for _, f := range fills {
		e, ok := enrichCache[f.key]
		if !ok || (f.bundleID == spotifyBundleID && e.SpotifyAlbumID != "") || (f.bundleID == amazonMusicBundleID && e.AmazonAlbumASIN != "") {
			continue
		}
		if applyPlayerCatalogIDsLocked(&e, f.bundleID, f.ids) {
			enrichCache[f.key] = e
			noteEnrichPendingLocked(f.key)
			changed = append(changed, f.key)
		}
	}
	if len(changed) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if len(changed) > 0 {
		log.Printf("player catalog: noted album ids on %d Spotify / Amazon Music entries from the clients' local caches", len(changed))
		saveEnrichPendingBatch(changed)
	}
	return len(changed)
}

// backfillNeteasePlayerSongsFromHistory:在网易云上放过的条目,按客户端的播放历史(historyTracks,客户端自己放过的歌)认出放的
// 是哪一首:还没有播放器歌曲 id 的按歌名歌手(报过原样写法的按它)与时长认(neteaseHistoryPick),记下歌曲 id 与专辑 id;认出的那首
// 是另一张专辑的、本机曲库重核又不认它(localLibraryLinkStale,同 locallibrarylinks.go)的不记;有歌曲 id、没专辑 id 的按 id 补专辑。本机曲库(dbTrack)是「见过的歌」,不用(18 章决策 42)。返回补了几条。
func backfillNeteasePlayerSongsFromHistory(ctx context.Context) int {
	type want struct {
		key, artist, title, album, songID string
		dur                               float64
	}
	enrichMu.Lock()
	var wants []want
	for k, e := range enrichCache {
		if !slices.Contains(e.Players, neteaseMusicBundleID) {
			continue
		}
		sid := e.PlayerSongIDs[neteaseMusicBundleID]
		if sid != "" && e.PlayerAlbumIDs[neteaseMusicBundleID] != "" {
			continue
		}
		artist, title, album := splitEnrichKey(k)
		if r, ok := e.Reported[neteaseMusicBundleID]; ok && r.Title != "" {
			artist, title = r.Artist, r.Title
			if r.Album != "" {
				album = r.Album
			}
		}
		wants = append(wants, want{k, artist, title, album, sid, e.DurationSecs})
	}
	enrichMu.Unlock()
	path := neteaseLocalDBPath()
	if len(wants) == 0 || path == "" {
		return 0
	}
	history, _, err := queryNeteaseLocalTable(ctx, path, neteaseLocalHistorySQL)
	if err != nil {
		return 0
	}
	byID := map[string]neteaseLocalTrack{}
	byName := map[string][]neteaseLocalTrack{}
	for _, h := range history {
		if h.ID <= 0 {
			continue
		}
		byID[strconv.FormatInt(int64(h.ID), 10)] = h
		for _, a := range h.Artists {
			if k := neteaseLocalKey(a.Name, h.Name); k != "" {
				byName[k] = append(byName[k], h)
			}
		}
	}
	type fill struct{ key, songID, albumID string }
	var fills []fill
	for _, w := range wants {
		h, ok := byID[w.songID]
		if w.songID == "" {
			h, ok = neteaseHistoryPick(byName, w.artist, w.title, w.dur)
			ok = ok && !localLibraryLinkStale(w.album, h.Album.Name, w.dur, h.Duration/1000)
		}
		if !ok {
			continue
		}
		songID, albumID := strconv.FormatInt(int64(h.ID), 10), strconv.FormatInt(int64(h.Album.ID), 10)
		if !playerSongIDOK(neteaseMusicBundleID, songID) {
			continue
		}
		if h.Album.ID <= 0 || !playerSongIDOK(neteaseMusicBundleID, albumID) {
			albumID = ""
		}
		fills = append(fills, fill{w.key, songID, albumID})
	}
	var changed []string
	enrichMu.Lock()
	for _, f := range fills {
		e, ok := enrichCache[f.key]
		if !ok {
			continue
		}
		if s := e.PlayerSongIDs[neteaseMusicBundleID]; s != "" && s != f.songID {
			continue
		}
		if notePlayerSongLocked(&e, neteaseMusicBundleID, f.songID, f.albumID) {
			enrichCache[f.key] = e
			noteEnrichPendingLocked(f.key)
			changed = append(changed, f.key)
		}
	}
	if len(changed) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if len(changed) > 0 {
		log.Printf("netease: noted the song the client played on %d entries, from its play history", len(changed))
		saveEnrichPendingBatch(changed)
	}
	return len(changed)
}

// backfillKugouPlayerSongsFromLibrary:在酷狗上放过、还没有酷狗歌曲 id 的条目,按客户端曲库里放过的歌(Allmusic 里 totalPlayCount
// 大于 0 的)认放的是哪一首:歌名(musicname 去掉「歌手 - 」那一半)、署名(报过原样写法的按它)与时长对得上且只有一首时,记下
// mixId 与专辑 id(18 章决策 69)。返回补了几条。
func backfillKugouPlayerSongsFromLibrary() int {
	type want struct {
		key, artist, title string
		dur                float64
	}
	enrichMu.Lock()
	var wants []want
	for k, e := range enrichCache {
		if !slices.Contains(e.Players, kugouMusicBundleID) || e.PlayerSongIDs[kugouMusicBundleID] != "" {
			continue
		}
		artist, title, _ := splitEnrichKey(k)
		if r, ok := e.Reported[kugouMusicBundleID]; ok && r.Title != "" {
			artist, title = r.Artist, r.Title
		}
		wants = append(wants, want{k, artist, title, e.DurationSecs})
	}
	enrichMu.Unlock()
	if len(wants) == 0 {
		return 0
	}
	var rows []kugouLibraryRow
	if !kugouLibraryQuery("SELECT ifnull(musicname, '') AS n, ifnull(singer, '') AS s, ifnull(musictime, 0) AS t, mixId AS m, albumId AS a "+
		"FROM Allmusic WHERE totalPlayCount > 0", &rows) {
		return 0
	}
	byTitle := map[string][]kugouLibraryRow{}
	for _, r := range rows {
		if _, t := kugouUpcomingSplit(r.Name); t != "" {
			byTitle[normLoose(t)] = append(byTitle[normLoose(t)], r)
		}
	}
	type fill struct{ key, songID, albumID string }
	var fills []fill
	for _, w := range wants {
		var hit kugouLibraryRow
		seen := map[string]bool{}
		for _, r := range byTitle[normLoose(w.title)] {
			credit, _ := kugouUpcomingSplit(r.Name)
			mix := rawDigitsID(r.Mix)
			if mix == "" || seen[mix] || !kugouCreditMatches(credit, r.Singer, w.artist) || !sourceDurationFits(w.dur, r.Time) {
				continue
			}
			seen[mix] = true
			hit = r
		}
		if len(seen) != 1 {
			continue
		}
		songID, albumID := rawDigitsID(hit.Mix), rawDigitsID(hit.Album)
		if !playerSongIDOK(kugouMusicBundleID, songID) {
			continue
		}
		if !playerSongIDOK(kugouMusicBundleID, albumID) {
			albumID = ""
		}
		fills = append(fills, fill{w.key, songID, albumID})
	}
	var changed []string
	enrichMu.Lock()
	for _, f := range fills {
		e, ok := enrichCache[f.key]
		if !ok || e.PlayerSongIDs[kugouMusicBundleID] != "" {
			continue
		}
		if notePlayerSongLocked(&e, kugouMusicBundleID, f.songID, f.albumID) {
			enrichCache[f.key] = e
			noteEnrichPendingLocked(f.key)
			changed = append(changed, f.key)
		}
	}
	if len(changed) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if len(changed) > 0 {
		log.Printf("kugou: noted the song the client played on %d entries, from its library", len(changed))
		saveEnrichPendingBatch(changed)
	}
	return len(changed)
}

// neteaseHistoryPick:播放历史里歌名、歌手(署名拆开逐个查)对得上,两边都知道时长时时长也对得上的那一首;对上的不止一首
// (同名的几个版本)时不认。
func neteaseHistoryPick(byName map[string][]neteaseLocalTrack, artist, title string, durationSecs float64) (neteaseLocalTrack, bool) {
	var hit neteaseLocalTrack
	seen := map[flexID]bool{}
	for _, a := range sodaArtistCandidates(artist) {
		for _, h := range byName[neteaseLocalKey(a, title)] {
			if seen[h.ID] || !sourceDurationFits(durationSecs, h.Duration/1000) {
				continue
			}
			seen[h.ID] = true
			hit = h
		}
	}
	if len(seen) != 1 {
		return neteaseLocalTrack{}, false
	}
	return hit, true
}
