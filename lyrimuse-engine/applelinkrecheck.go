package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// 存量条目的 Apple 链接(目录锚点给的那一页除外)按现在挑链接的规则重核一遍,判据见 appleLinkMismatch:
// 链接指的那一轨是别人的歌(专辑名只是曲名的单曲按 appleResultIdentityOK 的单曲规则,03 章决策 26;别的按身份闸加时长),
// 或同一首的另一个版本(版本词对不上、时长也对不上,03 章决策 64),清掉链接。别人的歌那种,封面也来自 Apple(同一次匹配
// 给的)时封面、主色、动态封面一起清;另一个版本那种,Apple 封面的专辑能当本地这张(candidateCoverAlbumFits)就留着
// (同一张专辑里的正曲和 Reprise 共用一张封面)。清掉的条目外围补全计数归零:下次播到时 needsPeripheralBackfill
// 把空链接算作缺,按新规则重新匹配。
//
// 要联网(iTunes lookup,一次问 appleLinkRecheckBatch 个曲目 ID),放后台跑、不挡启动。有一批没问成就不记水位,
// 下次启动再来;都问成了才记。
const (
	migrationAppleSingleLinks = "apple_single_links"
	// v2:从专辑名只是曲名的单曲扩到全部不是目录锚点给的链接,另核身份闸加时长、版本词加时长。
	migrationAppleSingleLinksVersion = 2

	appleLinkRecheckBatch = 100
	// appleLinkRecheckDelay:启动后等这么久再开始,让开启动那阵子的取词和扫库。
	appleLinkRecheckDelay = 2 * time.Minute
	// appleLinkRecheckPause:两批之间歇一下,别跟同一时刻的取词抢 iTunes 的限流额度。
	appleLinkRecheckPause = 2 * time.Second
)

// apple_music_url 形如 https://music.apple.com/us/album/<名>/<专辑 ID>?i=<曲目 ID>&uo=4
var appleTrackURLRe = regexp.MustCompile(`music\.apple\.com/([a-z]{2})/[^?#]*\?(?:[^#]*&)?i=(\d+)`)

// appleTrackURLParts 从 apple_music_url 取商店区和曲目 ID。不是曲目页返回空串。纯函数。
func appleTrackURLParts(u string) (country, trackID string) {
	m := appleTrackURLRe.FindStringSubmatch(u)
	if m == nil {
		return "", ""
	}
	return m[1], m[2]
}

var enrichKeyDurationVariantRe = regexp.MustCompile(`~dur\d+$`)

type appleLinkRecheckItem struct {
	key, url, artist, title, album, country, trackID string
	durationSecs                                     float64
}

// appleLinkRecheckCandidates 挑出要重核的条目:有 Apple 曲目页链接,链接不是这一条的目录锚点给的那一页(anchor 回锚点
// 链接,常驻进程里是 appleCatalogLinkFor;锚点是播放器报的目录 ID 按 ID 查回来的,不用按歌名的规则重核)。MV 标题
// 照封面那步(resolveTrackEnrichment)拆成「演唱者 / 歌名」来核,时长按那边的口径当未知(MV 比录音室版长)。纯函数。
func appleLinkRecheckCandidates(entries map[string]enrichEntry, anchor func(artist, title, album string, durationSecs float64) string) []appleLinkRecheckItem {
	var out []appleLinkRecheckItem
	for k, e := range entries {
		if e.AppleURL == "" {
			continue
		}
		country, id := appleTrackURLParts(e.AppleURL)
		if id == "" {
			continue
		}
		artist, title, album := splitEnrichKey(k)
		title = enrichKeyDurationVariantRe.ReplaceAllString(title, "")
		secs := e.DurationSecs
		if secs <= 0 {
			secs = e.ResolvedDurationSecs
		}
		if anchor != nil && anchor(artist, title, album, secs) == e.AppleURL {
			continue
		}
		if v := parseVideoTitle(artist, title); v.Kind == videoTitleMusicVideo {
			artist, title = v.Artist, v.Song
			if v.DurationUnknown {
				secs = 0
			}
		}
		out = append(out, appleLinkRecheckItem{key: k, url: e.AppleURL, artist: artist, title: title, album: album,
			country: country, trackID: id, durationSecs: secs})
	}
	return out
}

// appleLinkMismatch 的两种结论。
const (
	appleLinkAnotherArtist  = "another artist"
	appleLinkAnotherVersion = "another version"
)

// appleLinkMismatch:链接查回来的那一轨 r 已经不能算这一条的录音时给原因,能算或判不了给空串。纯函数。按顺序:
//  1. 本地专辑名只是曲名的单曲:appleSingleLinkStale(署名对不上、认不出是同一份录音换了写法)→ 别人的歌。
//  2. 别的条目:过不了身份闸 appleResultIdentityOK(署名对不上、专辑名也不逐字相等),两边时长都知道且超出
//     isrcDurationFits 的容差 → 别人的歌。时长对得上的多是同一份录音换了署名写法(JJ林俊傑 / 林俊杰),不动;两边署名
//     一边是拉丁字母、一边不是的(陈粒 / Chen Li,商店换了文字写法),本地时长又常取自别的平台,容差放宽到
//     appleStorefrontCrossScriptToleranceSecs;超出了也还要曲名(繁简折过)或专辑对不上才判(appleCrossScriptLinkOtherSong):
//     方大同《春风吹》链到 Khalil Fong《春風吹》、本地时长差 19 秒,是同一首,只是本地时长取自别的版本。
//  3. 另一个版本(appleOtherVersion,同新匹配那道闸),两边时长都知道且超出容差 → 另一个版本。时长对得上的不动:可能
//     只是一家把版本写进了曲名、另一家没写(同 neteaseLinkMismatch 第 1 条)。
//
// 时长缺一边的判不了,不动(新匹配那边版本词对不上就不认、署名对不上又没有专辑证据就不认,见 appleTitleResultOK)。
func appleLinkMismatch(it appleLinkRecheckItem, r itunesResult) string {
	secs := r.TrackTimeMillis / 1000
	durationOff := it.durationSecs > 0 && secs > 0 && !isrcDurationFits(it.durationSecs, secs)
	if appleAlbumIsJustTheTitle(it.album, it.title) {
		if appleSingleLinkStale(it.artist, it.durationSecs, r.ArtistName, secs) {
			return appleLinkAnotherArtist
		}
	} else if durationOff && !appleResultIdentityOK(r.ArtistName, r.CollectionName, it.artist, it.album, it.title, secs, it.durationSecs) &&
		(hasNonLatinLetter(r.ArtistName) == hasNonLatinLetter(it.artist) ||
			(math.Abs(secs-it.durationSecs) > appleStorefrontCrossScriptToleranceSecs && appleCrossScriptLinkOtherSong(it, r))) {
		return appleLinkAnotherArtist
	}
	if durationOff && appleOtherVersion(it.title, it.album, r.TrackName, r.CollectionName) {
		return appleLinkAnotherVersion
	}
	return ""
}

// appleSingleLinkStale:链接查回来的那首(署名 linkArtist、时长 linkSecs)已经不能算这一条的录音。判据同
// appleResultIdentityOK 的单曲分支。署名或时长缺一边时无从判定,不算(新匹配那边时长未知就不认,存量这边判不了就不动)。
// 纯函数。
func appleSingleLinkStale(entryArtist string, entrySecs float64, linkArtist string, linkSecs float64) bool {
	if strings.TrimSpace(entryArtist) == "" || strings.TrimSpace(linkArtist) == "" || entrySecs <= 0 || linkSecs <= 0 {
		return false
	}
	if lyricSourceArtistMatches(linkArtist, entryArtist) {
		return false
	}
	return !appleSameSingleByAnotherName(linkArtist, entryArtist, linkSecs, entrySecs)
}

// appleCrossScriptLinkOtherSong:署名换了文字写法的那一轨,曲名或专辑也对不上:曲名 normLoose 后不相等(繁简已折);
// 或本地报了专辑、跟那一轨的专辑一个词都不沾(albumScore 0)。本地没报专辑、曲名又一样的认不出是另一首,不判。纯函数。
func appleCrossScriptLinkOtherSong(it appleLinkRecheckItem, r itunesResult) bool {
	if normLoose(it.title) != normLoose(r.TrackName) {
		return true
	}
	return strings.TrimSpace(coverAlbumOrNone(it.album)) != "" && albumScore(r.CollectionName, it.album) == 0
}

// clearMismatchedAppleLink 按 appleLinkMismatch 的结论清链接。另一个版本、封面来自 Apple 而且那张专辑能当本地这张
// (本地报了专辑、candidateCoverAlbumFits)的,只清链接、留封面;别的同 clearStaleAppleLink。
func clearMismatchedAppleLink(e enrichEntry, reason, album string) enrichEntry {
	if reason == appleLinkAnotherVersion && (e.CoverSource != "apple" ||
		(strings.TrimSpace(coverAlbumOrNone(album)) != "" && candidateCoverAlbumFits(e.CoverAlbum, album))) {
		e.AppleURL = ""
		e.PeripheralRetryCount = 0
		return e
	}
	return clearStaleAppleLink(e)
}

// clearStaleAppleLink 清掉错配的链接,以及跟它出自同一次匹配的封面一族。
func clearStaleAppleLink(e enrichEntry) enrichEntry {
	e.AppleURL = ""
	e.PeripheralRetryCount = 0
	if e.CoverSource == "apple" {
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = "", "", "", ""
		e.clearMotionVerdict()
	}
	return e
}

// itunesLookupTrackIDs 一次按曲目 ID 查一批,返回 ID → 结果。ok = 这一批真的问成了(限流冷却中、网络失败、
// 非 200 都不算)。
func itunesLookupTrackIDs(ctx context.Context, ids []string, country string) (map[string]itunesResult, bool) {
	if itunesSearchCoolingDown(time.Now()) {
		return nil, false
	}
	cli := &http.Client{Timeout: 10 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		fmt.Sprintf("%s?id=%s&country=%s", itunesLookupTracksURL, strings.Join(ids, ","), country), nil)
	if err != nil {
		return nil, false
	}
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		// 调用方自己取消 / 超时,或本地出站闸拦下(没发出去),都不是 Apple 的状态。
		if ctx.Err() == nil && !errors.Is(err, errHostGuarded) {
			noteITunesSearchStatus(0, "", time.Now())
		}
		return nil, false
	}
	defer resp.Body.Close()
	// 跟 itunesSearch 共用一份限流冷却:lookup 与 search 是同一个主机、同一份额度。
	noteITunesSearchStatus(resp.StatusCode, resp.Header.Get("Retry-After"), time.Now())
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	var out struct {
		Results []struct {
			WrapperType     string  `json:"wrapperType"`
			TrackID         int64   `json:"trackId"`
			TrackName       string  `json:"trackName"`
			CollectionName  string  `json:"collectionName"`
			ArtistName      string  `json:"artistName"`
			TrackTimeMillis float64 `json:"trackTimeMillis"`
			TrackViewURL    string  `json:"trackViewUrl"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, false
	}
	found := make(map[string]itunesResult, len(out.Results))
	for _, r := range out.Results {
		if r.WrapperType == "track" && r.TrackID != 0 {
			found[fmt.Sprint(r.TrackID)] = itunesResult{TrackName: r.TrackName, CollectionName: r.CollectionName,
				ArtistName: r.ArtistName, TrackTimeMillis: r.TrackTimeMillis, TrackViewURL: r.TrackViewURL}
		}
	}
	return found, true
}

// startAppleLinkRecheck:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startAppleLinkRecheck(ctx context.Context) {
	scope := migrationScopeOf(migrationAppleSingleLinks, migrationAppleSingleLinksVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(appleLinkRecheckDelay):
		}
		recheckAppleLinks(withBackgroundOutbound(ctx), scope, appleCatalogLinkFor, appleLinkRecheckPause)
	}()
}

// recheckAppleLinks 是重核的本体,返回清掉了几条。anchor 同 appleLinkRecheckCandidates。查询在锁外;写回时链接还是
// 当初查的那一个才改(期间被外围补全换过的不动)。
func recheckAppleLinks(ctx context.Context, scope migrationScope, anchor func(artist, title, album string, durationSecs float64) string,
	pause time.Duration) int {
	enrichMu.Lock()
	withLinks := map[string]enrichEntry{}
	for k, e := range scope.entries() {
		if e.AppleURL != "" {
			withLinks[k] = e
		}
	}
	enrichMu.Unlock()
	items := appleLinkRecheckCandidates(withLinks, anchor)
	byCountry := map[string][]appleLinkRecheckItem{}
	for _, it := range items {
		byCountry[it.country] = append(byCountry[it.country], it)
	}
	complete := true
	type staleLink struct {
		appleLinkRecheckItem
		reason string
	}
	var stale []staleLink
	for country, list := range byCountry {
		for i := 0; i < len(list); i += appleLinkRecheckBatch {
			if ctx.Err() != nil {
				return 0
			}
			batch := list[i:min(i+appleLinkRecheckBatch, len(list))]
			ids := make([]string, len(batch))
			for j, it := range batch {
				ids[j] = it.trackID
			}
			found, ok := itunesLookupTrackIDs(ctx, ids, country)
			if !ok {
				complete = false
				continue
			}
			for _, it := range batch {
				r, ok := found[it.trackID]
				if !ok {
					continue
				}
				if reason := appleLinkMismatch(it, r); reason != "" {
					log.Printf("apple link recheck: %q links to %q by %q (%.1fs vs %.1fs), %s, clearing it",
						it.key, r.TrackName, r.ArtistName, r.TrackTimeMillis/1000, it.durationSecs, reason)
					stale = append(stale, staleLink{it, reason})
				}
			}
			if pause > 0 {
				time.Sleep(pause)
			}
		}
	}
	cleared := 0
	enrichMu.Lock()
	for _, it := range stale {
		e, ok := enrichCache[it.key]
		if !ok || e.AppleURL != it.url {
			continue
		}
		enrichCache[it.key] = clearMismatchedAppleLink(e, it.reason, it.album)
		cleared++
	}
	if cleared > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if cleared > 0 {
		saveEnrichCache()
	}
	log.Printf("apple link recheck: %d entries checked, %d cleared, complete=%v", len(items), cleared, complete)
	if complete {
		scope.markDone(migrationAppleSingleLinks, migrationAppleSingleLinksVersion)
	}
	return cleared
}
