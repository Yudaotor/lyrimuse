package main

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"time"
)

// Kaset 读不到播放队列时的同专辑预取(albumprefetch.go 的兜底那一层)。Kaset 不报专辑,缓存键里专辑恒为空,按键里的
// 专辑走不了;改按这首在 YouTube Music 登记的那张专辑(kasetalbum.go 判出来的,带专辑页 id)拉专辑页的曲目表,按 Kaset
// 播到时会报的写法(键里不带专辑)预解析。
//
// 署名:跟当前这首在专辑页上那一行写法一样的,用当前这首的署名(App 整理过的那份,跟真播到时一字不差);只有一位艺人
// 的行原样用;别的(好几位艺人连在一起、跟当前这首写法不同)跳过 —— 那种署名要按 App 那套规则清理
// (KasetPlayerInfo.cleanedArtist),这里不另写一份。

// kasetAlbumVerdictWait:这首的专辑判出来之前最多等多久(换歌时登记信息常常还没问到)。
const kasetAlbumVerdictWait = 20 * time.Second

// prefetchKasetAlbumSiblings 见文件头注。整个在调用方起的 goroutine 里跑。
func prefetchKasetAlbumSiblings(currentArtist, currentTitle string) {
	videoID := kasetVideoIDFor(kasetBundleID, currentArtist, currentTitle)
	if videoID == "" {
		return
	}
	deadline := time.Now().Add(kasetAlbumVerdictWait)
	var verdict kasetAlbumVerdict
	for {
		v, settled := kasetAlbumVerdictFor(videoID, 0, currentArtist, currentTitle)
		if settled {
			verdict = v
			break
		}
		if time.Now().After(deadline) {
			return
		}
		time.Sleep(time.Second)
	}
	if verdict.albumBrowseID == "" {
		return
	}
	prefetchMu.Lock()
	if lastPrefetched == "ytmusic:"+verdict.albumBrowseID {
		prefetchMu.Unlock()
		return
	}
	lastPrefetched = "ytmusic:" + verdict.albumBrowseID
	prefetchMu.Unlock()
	ctx, cancel := context.WithTimeout(withBackgroundOutbound(context.Background()), ytmusicCreditFetchTimeout)
	defer cancel()
	rows, err := ytmusicAlbumRows(ctx, verdict.albumBrowseID, ytmusicDisplayLanguage())
	if err != nil {
		infoFailf("album prefetch: youtube music album %q not fetched: %v", verdict.album, err)
		return
	}
	tracks := kasetAlbumSiblingTracks(rows, videoID, kasetAudioVideoIDFor(videoID), currentArtist)
	if len(tracks) == 0 {
		log.Printf("album prefetch: youtube music album %q has no usable rows", verdict.album)
		return
	}
	prefetchAlbumTracks(verdict.album, tracks, currentArtist, currentTitle, "")
}

// ytmusicAlbumRow:专辑页上的一行。artist 是艺人那一列的原文(几段连起来;这一列空着时取专辑页头部的艺人),
// singleArtist = 那一列只有一段。
type ytmusicAlbumRow struct {
	title, artist string
	singleArtist  bool
	duration      float64
	videoID       string
}

// ytmusicAlbumRows:YouTube Music 专辑页(browse)上的曲目行,按 hl 那种界面语言取。没问成返回 err。
func ytmusicAlbumRows(ctx context.Context, browseID, hl string) ([]ytmusicAlbumRow, error) {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	if client, ok := body["context"].(map[string]any)["client"].(map[string]any); ok {
		client["hl"] = hl
	}
	body["browseId"] = browseID
	raw, err := ytmusicPost(ctx, "browse", body, ytmusicCachedVisitorID())
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		return nil, errYtmusicEmptyResponse
	}
	return ytmusicAlbumRowsFromBrowse(raw), nil
}

// ytmusicAlbumRowsFromBrowse 从专辑页应答里摘出曲目行(`musicResponsiveListItemRenderer`):歌名(第一列)、艺人(第二列)、
// 时长(固定列)、videoId(`playlistItemData`)。没有歌名或 videoId 的行不要。纯函数,单测覆盖。
func ytmusicAlbumRowsFromBrowse(raw []byte) []ytmusicAlbumRow {
	var root any
	if json.Unmarshal(raw, &root) != nil {
		return nil
	}
	var headerArtist string
	var headerSingle bool
	ytmusicWalkJSON(root, func(m map[string]any) {
		h, ok := m["musicResponsiveHeaderRenderer"].(map[string]any)
		if !ok || headerArtist != "" {
			return
		}
		headerArtist = strings.TrimSpace(ytmusicCreditRunsText(h["straplineTextOne"], false))
		headerSingle = ytmusicRunCount(h["straplineTextOne"]) == 1
	})
	var rows []ytmusicAlbumRow
	ytmusicWalkJSON(root, func(m map[string]any) {
		r, ok := m["musicResponsiveListItemRenderer"].(map[string]any)
		if !ok {
			return
		}
		flex, _ := r["flexColumns"].([]any)
		column := func(i int) any {
			if i >= len(flex) {
				return nil
			}
			c, _ := flex[i].(map[string]any)
			fr, _ := c["musicResponsiveListItemFlexColumnRenderer"].(map[string]any)
			return fr["text"]
		}
		title := strings.TrimSpace(ytmusicCreditRunsText(column(0), false))
		item, _ := r["playlistItemData"].(map[string]any)
		videoID, _ := item["videoId"].(string)
		if title == "" || videoID == "" {
			return
		}
		row := ytmusicAlbumRow{title: title, videoID: videoID}
		row.artist = strings.TrimSpace(ytmusicCreditRunsText(column(1), false))
		row.singleArtist = ytmusicRunCount(column(1)) == 1
		if row.artist == "" {
			row.artist, row.singleArtist = headerArtist, headerSingle
		}
		if fixed, _ := r["fixedColumns"].([]any); len(fixed) > 0 {
			c, _ := fixed[0].(map[string]any)
			fr, _ := c["musicResponsiveListItemFixedColumnRenderer"].(map[string]any)
			row.duration = ytmusicParseDurationText(ytmusicCreditRunsText(fr["text"], false))
		}
		rows = append(rows, row)
	})
	return rows
}

// ytmusicRunCount:一段 InnerTube 文字有几段 run。
func ytmusicRunCount(node any) int {
	m, _ := node.(map[string]any)
	runs, _ := m["runs"].([]any)
	return len(runs)
}

// kasetAlbumSiblingTracks 把专辑页的行换成预取用的曲目,署名按文件头注那条规则取。当前这首在专辑页上那一行按 videoId 认
// (放的那一版,或者它配对的音轨版本)。纯函数,单测覆盖。
func kasetAlbumSiblingTracks(rows []ytmusicAlbumRow, videoID, audioVideoID, currentArtist string) []albumTrack {
	var current *ytmusicAlbumRow
	for i := range rows {
		if rows[i].videoID == videoID || rows[i].videoID == audioVideoID {
			current = &rows[i]
			break
		}
	}
	var out []albumTrack
	for _, r := range rows {
		artist := ""
		switch {
		case current != nil && r.artist == current.artist:
			artist = currentArtist
		case r.singleArtist:
			artist = r.artist
		default:
			continue
		}
		out = append(out, albumTrack{title: r.title, artist: artist, duration: r.duration})
	}
	return out
}
