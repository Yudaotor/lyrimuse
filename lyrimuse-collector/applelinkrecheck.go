package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// 存量条目里「专辑名只是曲名」的单曲,Apple 链接按 appleResultIdentityOK 的单曲规则重核一遍(03 章决策 26):
// 链接指的那首署名对不上、又认不出是同一份录音换了文字写法的,清掉链接;封面也来自 Apple(同一次匹配给的)时,
// 封面、主色、动态封面一起清。清掉的条目外围补全计数归零:下次播到时 needsPeripheralBackfill 把空链接算作缺,
// 按新规则重新匹配。
//
// 要联网(iTunes lookup,一次问 appleLinkRecheckBatch 个曲目 ID),放后台跑、不挡启动。有一批没问成就不记水位,
// 下次启动再来;都问成了才记。
const (
	migrationAppleSingleLinks        = "apple_single_links"
	migrationAppleSingleLinksVersion = 1

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
	key, url, artist, country, trackID string
	durationSecs                       float64
}

// appleSingleLinkCandidates 挑出要重核的条目:有 Apple 曲目页链接、专辑名只是曲名。纯函数。
func appleSingleLinkCandidates(entries map[string]enrichEntry) []appleLinkRecheckItem {
	var out []appleLinkRecheckItem
	for k, e := range entries {
		if e.AppleURL == "" {
			continue
		}
		artist, title, album := splitEnrichKey(k)
		title = enrichKeyDurationVariantRe.ReplaceAllString(title, "")
		if artist == "" || !appleAlbumIsJustTheTitle(album, title) {
			continue
		}
		country, id := appleTrackURLParts(e.AppleURL)
		if id == "" {
			continue
		}
		secs := e.DurationSecs
		if secs <= 0 {
			secs = e.ResolvedDurationSecs
		}
		out = append(out, appleLinkRecheckItem{key: k, url: e.AppleURL, artist: artist, country: country, trackID: id, durationSecs: secs})
	}
	return out
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

// clearStaleAppleLink 清掉错配的链接,以及跟它出自同一次匹配的封面一族。
func clearStaleAppleLink(e enrichEntry) enrichEntry {
	e.AppleURL = ""
	e.PeripheralRetryCount = 0
	if e.CoverSource == "apple" {
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = "", "", "", ""
		e.MotionCoverURL, e.MotionPreviewURL = "", ""
		e.MotionCoverChecked, e.MotionCoverIdentityVerified = false, false
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
			ArtistName      string  `json:"artistName"`
			TrackTimeMillis float64 `json:"trackTimeMillis"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, false
	}
	found := make(map[string]itunesResult, len(out.Results))
	for _, r := range out.Results {
		if r.WrapperType == "track" && r.TrackID != 0 {
			found[fmt.Sprint(r.TrackID)] = itunesResult{ArtistName: r.ArtistName, TrackTimeMillis: r.TrackTimeMillis}
		}
	}
	return found, true
}

// startAppleSingleLinkRecheck:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startAppleSingleLinkRecheck(ctx context.Context) {
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
		recheckAppleSingleLinks(ctx, scope, appleLinkRecheckPause)
	}()
}

// recheckAppleSingleLinks 是重核的本体,返回清掉了几条。查询在锁外;写回时链接还是当初查的那一个才改(期间被
// 外围补全换过的不动)。
func recheckAppleSingleLinks(ctx context.Context, scope migrationScope, pause time.Duration) int {
	enrichMu.Lock()
	withLinks := map[string]enrichEntry{}
	for k, e := range scope.entries() {
		if e.AppleURL != "" {
			withLinks[k] = e
		}
	}
	enrichMu.Unlock()
	items := appleSingleLinkCandidates(withLinks)
	byCountry := map[string][]appleLinkRecheckItem{}
	for _, it := range items {
		byCountry[it.country] = append(byCountry[it.country], it)
	}
	complete := true
	var stale []appleLinkRecheckItem
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
				if ok && appleSingleLinkStale(it.artist, it.durationSecs, r.ArtistName, r.TrackTimeMillis/1000) {
					log.Printf("apple link recheck: %q links to a track by %q (%.1fs vs %.1fs), clearing it", it.key, r.ArtistName, r.TrackTimeMillis/1000, it.durationSecs)
					stale = append(stale, it)
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
		enrichCache[it.key] = clearStaleAppleLink(e)
		cleared++
	}
	if cleared > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if cleared > 0 {
		saveEnrichCache()
	}
	log.Printf("apple link recheck: %d single entries checked, %d cleared, complete=%v", len(items), cleared, complete)
	if complete {
		markMigrationDone(migrationAppleSingleLinks, migrationAppleSingleLinksVersion)
	}
	return cleared
}
