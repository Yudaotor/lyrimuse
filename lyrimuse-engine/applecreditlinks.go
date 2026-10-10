package main

import (
	"context"
	"log"
	"slices"
	"sort"
	"time"
)

// 存量条目的 Apple 歌曲页按合作署名重核一遍(03 章决策 43)。本地署名点了合作者、链接那一轨当不了这条写法的歌曲页的
// (appleTrackCreditFits),按歌手 + 歌名再搜一次 iTunes;同一批结果里有一轨署名写全了,链接换成那一轨。存量 ISRC 补扫
// 是按链接的曲目 ID 取号的(recordingisrc.go),原来那一轨的 ISRC 一并从条目里拿掉,换成新那一轨的(时长对得上才收,
// 同 isrcFromAppleSong;新那一轨也是这个号时等于留着)。封面、专辑名不动:它们出自专辑对得上的那一轨,还是这张专辑的。
// 不动的:已校验的目录锚点页(appleCatalogLinkFor,Apple Music 自己放的那一轨);Spotify 本机记着的 ISRC 就是链接
// 那一轨的号的(用户放的就是这一份录音)。
//
// 要联网:先按商店把链接的曲目 ID 一次 appleCreditLinkBatch 首问 Apple 曲库(只要 developer token),拿署名、时长和
// ISRC;当不了的再各搜一次 iTunes。放后台跑、不挡启动;有一批没问成就不记水位,下次启动再来,问成了的那部分照常写。
const (
	migrationAppleCreditLinks        = "apple_credit_links"
	migrationAppleCreditLinksVersion = 1

	appleCreditLinkBatch = isrcSweepBatch
	// appleCreditLinkDelay:排在 apple_single_links(2 分钟)、apple_catalog_links 与 ISRC 补扫(都是 3 分钟)之后。
	appleCreditLinkDelay = 4 * time.Minute
	// appleCreditLinkPause:两次请求之间歇一下,别跟同一时刻的取词抢 iTunes 的限流额度。
	appleCreditLinkPause = 2 * time.Second
)

// appleCreditLinkItem:一条要重核的条目。co 是本地署名点名的合作者(creditCoArtists)。
type appleCreditLinkItem struct {
	key, url, artist, title, album, country, trackID string
	co                                               []string
	durationSecs                                     float64
	spotifyTrackID                                   string
}

// appleCreditLinkChange:一条要换的链接。dropISRC 是原来那一轨的号(要从条目里拿掉,空串不拿),addISRC 是新那一轨的。
// newAsked:新那一轨这一轮在曲库里问到了(曲库里没有也算问到)。
type appleCreditLinkChange struct {
	item              appleCreditLinkItem
	oldArtist, newURL string
	dropISRC, addISRC string
	newAsked          bool
}

// appleCreditLinkDeps:重核用到的几样查询,测试里换成假的。
type appleCreditLinkDeps struct {
	songsByID   func(ctx context.Context, storefront string, ids []string) (map[string]appleCatalogSong, bool)
	search      func(ctx context.Context, artist, title, album string, durationSecs float64) (appleMusicMatch, bool)
	spotifyISRC func(trackID string) (string, bool)
	anchor      func(artist, title, album string, durationSecs float64) string
}

var appleCreditLinkLiveDeps = appleCreditLinkDeps{
	songsByID: appleCatalogSongsByID,
	search: func(ctx context.Context, artist, title, album string, durationSecs float64) (appleMusicMatch, bool) {
		m, _, reached := searchAppleMusicMatch(ctx, artist, title, album, durationSecs)
		return m, reached
	},
	spotifyISRC: spotifyLocalISRC,
	anchor:      appleCatalogLinkFor,
}

// appleCreditLinkCandidates:有 Apple 曲目页链接、本地署名点了合作者的条目,按键排。纯函数。
func appleCreditLinkCandidates(entries map[string]enrichEntry) []appleCreditLinkItem {
	var out []appleCreditLinkItem
	for k, e := range entries {
		country, id := appleTrackURLParts(e.AppleURL)
		if id == "" {
			continue
		}
		artist, title, album := splitEnrichKey(k)
		title = enrichKeyDurationVariantRe.ReplaceAllString(title, "")
		co := creditCoArtists(artist, title)
		if len(co) == 0 {
			continue
		}
		secs := e.DurationSecs
		if secs <= 0 {
			secs = e.ResolvedDurationSecs
		}
		out = append(out, appleCreditLinkItem{key: k, url: e.AppleURL, artist: artist, title: title, album: album,
			country: country, trackID: id, co: co, durationSecs: secs, spotifyTrackID: e.SpotifyTrackID})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].key < out[j].key })
	return out
}

// appleCreditLinkSongs:按商店分批问 Apple 曲库。ids 是条目键 → [商店, 曲目 ID];返回条目键 → 那一轨(曲库里没有的不在),
// 以及问成了的条目键。有一批没问成时 ok 为假。
func appleCreditLinkSongs(ctx context.Context, deps appleCreditLinkDeps, ids map[string][2]string, pause time.Duration) (songs map[string]appleCatalogSong, asked map[string]bool, ok bool) {
	songs, asked, ok = map[string]appleCatalogSong{}, map[string]bool{}, true
	byCountry := map[string][]string{}
	for key, ci := range ids {
		byCountry[ci[0]] = append(byCountry[ci[0]], key)
	}
	countries := make([]string, 0, len(byCountry))
	for c := range byCountry {
		countries = append(countries, c)
	}
	sort.Strings(countries)
	for _, country := range countries {
		keys := byCountry[country]
		sort.Strings(keys)
		for i := 0; i < len(keys); i += appleCreditLinkBatch {
			if ctx.Err() != nil {
				return songs, asked, false
			}
			batch := keys[i:min(i+appleCreditLinkBatch, len(keys))]
			trackIDs := make([]string, 0, len(batch))
			for _, k := range batch {
				if id := ids[k][1]; !slices.Contains(trackIDs, id) {
					trackIDs = append(trackIDs, id)
				}
			}
			found, got := deps.songsByID(ctx, country, trackIDs)
			if pause > 0 {
				time.Sleep(pause)
			}
			if !got {
				ok = false
				continue
			}
			for _, k := range batch {
				asked[k] = true
				if s, has := found[ids[k][1]]; has {
					songs[k] = s
				}
			}
		}
	}
	return songs, asked, ok
}

// startAppleCreditLinkRecheck:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startAppleCreditLinkRecheck(ctx context.Context) {
	scope := migrationScopeOf(migrationAppleCreditLinks, migrationAppleCreditLinksVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(appleCreditLinkDelay):
		}
		recheckAppleCreditLinks(ctx, scope, appleCreditLinkLiveDeps, appleCreditLinkPause)
	}()
}

// recheckAppleCreditLinks 是重核的本体,返回换了几条。查询都在锁外(planAppleCreditLinks);写回时链接还是当初查的那一个
// 才改(期间被外围补全、目录锚点换过的不动)。
func recheckAppleCreditLinks(ctx context.Context, scope migrationScope, deps appleCreditLinkDeps, pause time.Duration) int {
	enrichMu.Lock()
	withLinks := map[string]enrichEntry{}
	for k, e := range scope.entries() {
		if e.AppleURL != "" {
			withLinks[k] = e
		}
	}
	enrichMu.Unlock()
	var items []appleCreditLinkItem
	for _, it := range appleCreditLinkCandidates(withLinks) {
		if deps.anchor(it.artist, it.title, it.album, it.durationSecs) != it.url {
			items = append(items, it)
		}
	}
	changes, suspects, complete, ok := planAppleCreditLinks(ctx, items, deps, pause)
	if !ok {
		return 0
	}

	changed := 0
	enrichMu.Lock()
	for _, c := range changes {
		e, ok := enrichCache[c.item.key]
		if !ok || e.AppleURL != c.item.url {
			continue
		}
		lookedUp := e.ISRCLookup == isrcLookupKey(e)
		e.AppleURL = c.newURL
		if c.dropISRC != "" {
			removeISRCs(&e, func(code string) bool { return code == c.dropISRC })
		}
		if c.addISRC != "" {
			recordISRCs(&e, []recordedISRC{{c.addISRC, isrcLevelVerified}})
		}
		// 原来按这几个 id 补齐过、新那一轨这一轮又问到了,才记成补过;否则留给补扫按新的 id 再取。
		if lookedUp && c.newAsked {
			e.ISRCLookup = isrcLookupKey(e)
		}
		enrichCache[c.item.key] = e
		changed++
		log.Printf("apple credit links: %q linked a track credited to %q, replacing it with %s (isrc dropped %q, added %q)",
			c.item.key, c.oldArtist, c.newURL, c.dropISRC, c.addISRC)
	}
	if changed > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if changed > 0 {
		saveEnrichCache()
	}
	log.Printf("apple credit links: %d entries checked, %d linked tracks miss a credited artist, %d replaced, complete=%v",
		len(items), suspects, changed, complete)
	if complete {
		markMigrationDone(migrationAppleCreditLinks, migrationAppleCreditLinksVersion)
	}
	return changed
}

// planAppleCreditLinks:items 里哪几条要换、换成什么(只联网,不碰缓存)。suspects:链接那一轨当不了歌曲页、搜过的条数;
// complete 为假:有一批没问成;ok 为假:ctx 取消了,结果作废。
func planAppleCreditLinks(ctx context.Context, items []appleCreditLinkItem, deps appleCreditLinkDeps, pause time.Duration) (changes []appleCreditLinkChange, suspects int, complete, ok bool) {
	linked := map[string][2]string{}
	for _, it := range items {
		linked[it.key] = [2]string{it.country, it.trackID}
	}
	old, _, complete := appleCreditLinkSongs(ctx, deps, linked, pause)
	if ctx.Err() != nil {
		return nil, 0, false, false
	}
	for _, it := range items {
		s, found := old[it.key]
		if !found || appleTrackCreditFits(it.co, s.artist, s.title, s.durationSecs, it.durationSecs) {
			continue
		}
		if it.spotifyTrackID != "" && s.isrc != "" {
			if code, ok := deps.spotifyISRC(it.spotifyTrackID); ok && normalizeISRC(code) == normalizeISRC(s.isrc) {
				continue
			}
		}
		suspects++
		if ctx.Err() != nil {
			return nil, 0, false, false
		}
		m, reached := deps.search(ctx, it.artist, it.title, it.album, it.durationSecs)
		if pause > 0 {
			time.Sleep(pause)
		}
		if !reached {
			complete = false
			continue
		}
		newURL := m.creditedURL()
		if _, id := appleTrackURLParts(newURL); id == "" || id == it.trackID {
			continue
		}
		changes = append(changes, appleCreditLinkChange{item: it, oldArtist: s.artist, newURL: newURL, dropISRC: normalizeISRC(s.isrc)})
	}

	replaced := map[string][2]string{}
	for _, c := range changes {
		country, id := appleTrackURLParts(c.newURL)
		replaced[c.item.key] = [2]string{country, id}
	}
	fresh, asked, got := appleCreditLinkSongs(ctx, deps, replaced, pause)
	if !got {
		complete = false
	}
	if ctx.Err() != nil {
		return nil, 0, false, false
	}
	for i := range changes {
		c := &changes[i]
		if s, has := fresh[c.item.key]; has {
			c.addISRC = isrcFromAppleSong(s, true, c.item.durationSecs)
		}
		c.newAsked = asked[c.item.key]
	}
	return changes, suspects, complete, true
}
