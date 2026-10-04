package main

import (
	"context"
	"log"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// 存量条目补背景人声与词曲作者名单。
//
// 解析器从 lyricsBGParserVersion 1 起产出背景人声轨、2 起产出词曲作者名单,之前选出 amll / applemusic 歌词的
// 条目都没有它们。这些条目播放到时只重取胜出的那一个源(不重新选源、不动正文),取回来的背景人声逐行核对能挂到
// 现有主句上才写入,词曲作者名单取到就写;不管有没有写入都记下 LyricsBGChecked,之后不再来。没取到(网络失败、库里下架)不记,
// 同一进程里每首只试一次,下次启动后播放再试。

// bgBackfillTimeout:一次回填只问一个源,给足一次 Apple 搜索 + 取词的时间。
const bgBackfillTimeout = 20 * time.Second

// bgBackfillAlignToleranceMs:背景人声行头跟主句行头的最大差值。两者都来自同一行 <p> 的 begin,正常完全
// 相等;逐行 LRC 只有 10ms 精度,留出这点余量。
const bgBackfillAlignToleranceMs = 30

// bgBackfillTried:这一进程里已经试过回填的 key。调用方持 enrichMu。
var bgBackfillTried = map[string]bool{}

// needsBackgroundVocalsBackfill:胜出源是 amll / applemusic、还没按当前 TTML 附属内容解析器取过的有词条目。
// 手改过的不动(背景人声对不上用户改过的正文)。
func needsBackgroundVocalsBackfill(e enrichEntry) bool {
	return e.LyricsBGChecked < lyricsBGParserVersion && e.Lyrics != "" && !e.lyricsHandEdited() &&
		(e.LyricsSource == "amll" || e.LyricsSource == "applemusic")
}

// bgBackfillOnce:这一进程里第一次问到这个 key 时返回 true。调用方持 enrichMu。
func bgBackfillOnce(key string) bool {
	if bgBackfillTried[key] {
		return false
	}
	bgBackfillTried[key] = true
	return true
}

// backfillBackgroundVocals 重取胜出源补背景人声,见文件头注。调用方已置 enrichInflight[key]。
func backfillBackgroundVocals(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok || !needsBackgroundVocalsBackfill(e) {
		return
	}
	ctx, cancel := context.WithTimeout(withBackgroundOutbound(context.Background()), bgBackfillTimeout)
	defer cancel()
	appleID, spotifyID := playbackTrackIDsFor(artist, title, album)
	if spotifyID == "" {
		spotifyID = e.SpotifyTrackID
	}
	var bg string
	var songwriters []string
	switch e.LyricsSource {
	case "amll":
		// 只按 ID 重取:要的是当初选中的那一份,在索引里按歌名另找的未必是它。
		r := amllLyric(ctx, amllQuery{neteaseID: neteaseSongIDFromURL(e.NeteaseURL), qqID: qqMidFromURL(e.QQURL),
			appleCatalogID: appleID, spotifyTrackID: spotifyID})
		if r.empty() {
			log.Printf("bg backfill: %s  amll returned nothing", key)
			return
		}
		bg, songwriters = r.bg, r.songwriters
	case "applemusic":
		r := applemusicLyric(ctx, artist, title, album, durationSecs, appleID, lyricSourceISRC(ctx, artist, title, album))
		if r.lyrics == "" {
			log.Printf("bg backfill: %s  applemusic returned nothing", key)
			return
		}
		bg, songwriters = r.bg, r.songwriters
	}

	enrichMu.Lock()
	cur, ok := enrichCache[key]
	// 取词这段时间里正文被换了(重新选源、用户编辑),取回来的背景人声不再对应它。
	if !ok || cur.Lyrics != e.Lyrics || cur.LyricsYRC != e.LyricsYRC || cur.LyricsSource != e.LyricsSource ||
		cur.LyricsBGChecked >= lyricsBGParserVersion {
		enrichMu.Unlock()
		return
	}
	switch {
	case bg == "":
		log.Printf("bg backfill: %s  %s has no background vocals", key, cur.LyricsSource)
	case !backgroundAlignsWithLyrics(bg, cur.LyricsYRC, cur.Lyrics):
		log.Printf("bg backfill: %s  %s background vocals don't line up with the cached lyrics, skipped", key, cur.LyricsSource)
	default:
		cur.LyricsBG = bg
		log.Printf("bg backfill: %s  %s +%d background lines", key, cur.LyricsSource, strings.Count(bg, "\n"))
	}
	if len(songwriters) > 0 {
		cur.LyricsSongwriters = songwriters
		log.Printf("bg backfill: %s  %s %d songwriters", key, cur.LyricsSource, len(songwriters))
	}
	cur.LyricsBGChecked = lyricsBGParserVersion
	enrichCache[key] = cur
	enrichDirty = true
	// 必须先解锁:requestEnrichSave 可能当场保存,保存要取 enrichMu。
	enrichMu.Unlock()
	requestEnrichSave()
}

// yrcLineHeadRe:YRC 一行开头的 `[行始,行长]`。
var yrcLineHeadRe = regexp.MustCompile(`^\[(\d+),\d+\]`)

// backgroundAlignsWithLyrics:背景人声的每一行都能按行头挂到一行主句上(差值不超过
// bgBackfillAlignToleranceMs)。主句行头优先取逐字轨,没有逐字时取逐行 LRC 的时间戳。
func backgroundAlignsWithLyrics(bg, yrc, lrc string) bool {
	var heads []int
	for _, line := range strings.Split(yrc, "\n") {
		if m := yrcLineHeadRe.FindStringSubmatch(line); m != nil {
			if ms, err := strconv.Atoi(m[1]); err == nil {
				heads = append(heads, ms)
			}
		}
	}
	if len(heads) == 0 {
		for _, line := range strings.Split(lrc, "\n") {
			for _, m := range lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1) {
				heads = append(heads, lrcStampMs(m))
			}
		}
	}
	matched := 0
	for _, line := range strings.Split(bg, "\n") {
		m := yrcLineHeadRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		ms, err := strconv.Atoi(m[1])
		if err != nil {
			return false
		}
		ok := false
		for _, h := range heads {
			if d := h - ms; d <= bgBackfillAlignToleranceMs && d >= -bgBackfillAlignToleranceMs {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
		matched++
	}
	return matched > 0
}

// neteaseSongIDFromURL 取网易云歌曲页地址(music.163.com/song?id=<id>)里的 id,取不到返回空串。
func neteaseSongIDFromURL(u string) string {
	p, err := url.Parse(u)
	if err != nil || !strings.Contains(p.Host, "163.com") {
		return ""
	}
	id := p.Query().Get("id")
	if _, err := strconv.ParseInt(id, 10, 64); err != nil {
		return ""
	}
	return id
}
