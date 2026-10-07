package main

import (
	"context"
	"encoding/json"
	"log"
	"math"
	"net/http"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

// 这条录音的 ISRC(国际标准录音编码)。一份录音一个,不随商店语言、上架的专辑变;同一份录音也可能被不同发行商各登记
// 过一个。记进条目的 isrcs,App 合并收听写法时按它认「是不是同一首」(EnrichTitleAliases),见 12 章决策 61。
//
// 来路:Spotify 原生客户端在播时报的(playbackISRC,就是这一条录音);这一轮已被认可(分数 >= 0)、自报时长跟播放器报的
// 对得上(isrcDurationFits)的 applemusic / deezer 候选报的;存量条目由 startRecordingISRCSweep 按已存的 Apple 歌曲 id、
// Spotify 曲目 id 补。ISRC 有脏数据(占位符样式的编号被注册给了不相干的歌),候选报的都要过时长闸,占位符样式的直接丢掉。

// recordingISRCMax:一条最多记几个。
const recordingISRCMax = 4

// isrcDurationToleranceSecs:候选自报时长跟播放器报的最多差多少才认它报的 ISRC。Apple 报毫秒,同一份录音差不到
// 0.01 秒;Deezer 报整秒,差不到 1 秒。
const isrcDurationToleranceSecs = 1.5

var isrcFormatRe = regexp.MustCompile(`^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$`)

// normalizeISRC:去掉连字符和空白、转大写。格式不对(国家码两位 + 登记者三位 + 年份两位 + 序号五位),或是占位符样式
// (后七位是同一个数字,如 ZZZZZ9999999)时返回空串。
func normalizeISRC(code string) string {
	c := strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(code)))
	if !isrcFormatRe.MatchString(c) {
		return ""
	}
	if digits := c[5:]; strings.Count(digits, digits[:1]) == len(digits) {
		return ""
	}
	return c
}

// isrcDurationFits:两边时长都知道,且差在 isrcDurationToleranceSecs 以内。
func isrcDurationFits(localSecs, sourceSecs float64) bool {
	return localSecs > 0 && sourceSecs > 0 && math.Abs(localSecs-sourceSecs) <= isrcDurationToleranceSecs
}

// recordingISRCsFromScored:这一轮认出来的这条录音的 ISRC。playback 是播放器报的(没有传空串),排在前面;候选报的按
// 候选顺序接在后面,去重。
func recordingISRCsFromScored(playback string, scored []scoredLyricCandidateResult, durationSecs float64) []string {
	out := mergeRecordingISRCs(nil, []string{playback})
	for _, r := range scored {
		if (r.Source != "applemusic" && r.Source != "deezer") || r.Score < 0 ||
			!isrcDurationFits(durationSecs, r.SourceReportedDurationSecs) {
			continue
		}
		out = mergeRecordingISRCs(out, []string{r.ISRC})
	}
	return out
}

// mergeRecordingISRCs:已有的在前,新的接在后面,去重,最多 recordingISRCMax 个。
func mergeRecordingISRCs(have, add []string) []string {
	out := slices.Clone(have)
	for _, raw := range add {
		c := normalizeISRC(raw)
		if c == "" || slices.Contains(out, c) {
			continue
		}
		if len(out) >= recordingISRCMax {
			break
		}
		out = append(out, c)
	}
	return out
}

// ---- 存量条目补 ISRC ----

// isrcSweepDelay:引擎起来后多久开始补;isrcSweepPace:两次请求之间隔多久;isrcSweepBatch:一次问 Apple 几个歌曲 id。
const (
	isrcSweepDelay = 3 * time.Minute
	isrcSweepPace  = time.Second
	isrcSweepBatch = 100
)

var appleStorefrontInURLRe = regexp.MustCompile(`music\.apple\.com/([a-z]{2})/`)

// appleStorefrontFromURL:Apple Music 链接里的商店(两位小写字母),没有返回空串。
func appleStorefrontFromURL(u string) string {
	if m := appleStorefrontInURLRe.FindStringSubmatch(u); m != nil {
		return m[1]
	}
	return ""
}

// isrcLookupKey:这条按哪几个 id 补 ISRC,形如 `apple:us:1587171823 spotify:7HuBDWi18s4aJM8UFnNheH`。两个都没有返回空串。
// 记在 enrichEntry.ISRCLookup:id 没变就不再问,链接换了(重新匹配)会再补一次。
func isrcLookupKey(e enrichEntry) string {
	var parts []string
	if id, sf := appleCatalogIDFromURL(e.AppleURL), appleStorefrontFromURL(e.AppleURL); id != "" && sf != "" {
		parts = append(parts, "apple:"+sf+":"+id)
	}
	if len(e.SpotifyTrackID) == 22 {
		parts = append(parts, "spotify:"+e.SpotifyTrackID)
	}
	return strings.Join(parts, " ")
}

// isrcSweepJob:一条要补的条目,lookup 是拿出来那一刻的 isrcLookupKey。
type isrcSweepJob struct {
	key, lookup, appleID, storefront, spotifyID string
	durationSecs                                float64
}

// isrcSweepJobsLocked:有 Apple 歌曲 id 或 Spotify 曲目 id、按现在这几个 id 还没补过的条目,按 key 排序。调用方持有 enrichMu。
func isrcSweepJobsLocked() []isrcSweepJob {
	var jobs []isrcSweepJob
	for k, e := range enrichCache {
		lookup := isrcLookupKey(e)
		if lookup == "" || lookup == e.ISRCLookup {
			continue
		}
		job := isrcSweepJob{key: k, lookup: lookup, durationSecs: e.DurationSecs}
		if id, sf := appleCatalogIDFromURL(e.AppleURL), appleStorefrontFromURL(e.AppleURL); id != "" && sf != "" {
			job.appleID, job.storefront = id, sf
		}
		if len(e.SpotifyTrackID) == 22 {
			job.spotifyID = e.SpotifyTrackID
		}
		jobs = append(jobs, job)
	}
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].key < jobs[j].key })
	return jobs
}

// appleCatalogSong:按 id 取回来的一首,只留补 ISRC 用得上的两项。
type appleCatalogSong struct {
	isrc         string
	durationSecs float64
}

// isrcFromAppleSong:这首报的 ISRC 时长跟播放器报的对得上才认,不认返回空串。没取到这首(这个商店没有)也是空串。
func isrcFromAppleSong(song appleCatalogSong, found bool, durationSecs float64) string {
	if !found || !isrcDurationFits(durationSecs, song.durationSecs) {
		return ""
	}
	return normalizeISRC(song.isrc)
}

// applyISRCSweepResultLocked:把一条的结果写回。条目还在、id 没变才写;isrcs 合进已有的,ISRCLookup 记成这次的 id。
// 返回有没有改动。调用方持有 enrichMu。
func applyISRCSweepResultLocked(job isrcSweepJob, isrcs []string) bool {
	cur, ok := enrichCache[job.key]
	if !ok || isrcLookupKey(cur) != job.lookup {
		return false
	}
	cur.ISRCs = mergeRecordingISRCs(cur.ISRCs, isrcs)
	cur.ISRCLookup = job.lookup
	enrichCache[job.key] = cur
	return true
}

// appleCatalogSongsByID:按歌曲 id 一次取一批(storefront 这个商店的曲库,只要 developer token)。返回 id → 这首;
// ok=false 表示这一批没问成(网络、令牌),调用方别把这批记成补过。
func appleCatalogSongsByID(ctx context.Context, storefront string, ids []string) (map[string]appleCatalogSong, bool) {
	devToken := applemusicEnsureDeveloperToken(ctx)
	if devToken == "" {
		return nil, false
	}
	path := storefront + "/songs?ids=" + strings.Join(ids, ",")
	raw, status, err := applemusicAPIGet(ctx, path, devToken, "")
	if err == nil && (status == http.StatusUnauthorized || status == http.StatusForbidden) {
		// developer token 失效,作废重取一次,同 appleMusicRecordingByISRC。
		applemusicClearDevToken()
		if newTok := applemusicEnsureDeveloperToken(ctx); newTok != "" && newTok != devToken {
			raw, status, err = applemusicAPIGet(ctx, path, newTok, "")
		}
	}
	if err != nil || status != http.StatusOK {
		return nil, false
	}
	var resp struct {
		Data []applemusicSong `json:"data"`
	}
	if json.Unmarshal(raw, &resp) != nil {
		return nil, false
	}
	out := make(map[string]appleCatalogSong, len(resp.Data))
	for _, s := range resp.Data {
		out[s.ID] = appleCatalogSong{isrc: s.Attributes.Isrc, durationSecs: float64(s.Attributes.DurationInMillis) / 1000}
	}
	return out, true
}

// startRecordingISRCSweep:引擎起来后给存量条目补一次 ISRC。存过 Spotify 曲目 id 的从本机 Spotify 缓存读(不联网);存过
// Apple 歌曲 id 的按商店分批问 Apple Music 曲库,时长跟播放器报的对得上才记(没有播放器时长的不记,只标成补过)。
// 没问成、没轮到(引擎在退出)的那几批不标,下次起来再补。
func startRecordingISRCSweep(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-time.After(isrcSweepDelay):
	}
	enrichMu.Lock()
	jobs := isrcSweepJobsLocked()
	enrichMu.Unlock()
	if len(jobs) == 0 {
		return
	}
	found := map[string][]string{}
	settled := map[string]bool{}
	byStorefront := map[string][]isrcSweepJob{}
	for _, job := range jobs {
		if job.spotifyID != "" {
			if code, ok := spotifyLocalISRC(job.spotifyID); ok {
				found[job.key] = append(found[job.key], code)
			}
		}
		if job.appleID == "" {
			settled[job.key] = true
		} else {
			byStorefront[job.storefront] = append(byStorefront[job.storefront], job)
		}
	}
	storefronts := make([]string, 0, len(byStorefront))
	for sf := range byStorefront {
		storefronts = append(storefronts, sf)
	}
	sort.Strings(storefronts)
	requests := 0
sweep:
	for _, sf := range storefronts {
		group := byStorefront[sf]
		for start := 0; start < len(group); start += isrcSweepBatch {
			if ctx.Err() != nil {
				break sweep
			}
			batch := group[start:min(start+isrcSweepBatch, len(group))]
			ids := make([]string, len(batch))
			for i, job := range batch {
				ids[i] = job.appleID
			}
			songs, ok := appleCatalogSongsByID(ctx, sf, ids)
			requests++
			if ok {
				for _, job := range batch {
					song, has := songs[job.appleID]
					if code := isrcFromAppleSong(song, has, job.durationSecs); code != "" {
						found[job.key] = append(found[job.key], code)
					}
					settled[job.key] = true
				}
			}
			select {
			case <-ctx.Done():
				break sweep
			case <-time.After(isrcSweepPace):
			}
		}
	}
	updated, withISRC := 0, 0
	enrichMu.Lock()
	for _, job := range jobs {
		if !settled[job.key] || !applyISRCSweepResultLocked(job, found[job.key]) {
			continue
		}
		updated++
		if len(found[job.key]) > 0 {
			withISRC++
		}
	}
	if updated > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if updated > 0 {
		requestEnrichBackgroundSave()
	}
	log.Printf("isrc sweep: %d of %d entries checked, %d with isrc, %d apple requests, %d left for the next run",
		updated, len(jobs), withISRC, requests, len(jobs)-len(settled))
}
