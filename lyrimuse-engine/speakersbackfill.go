package main

import (
	"context"
	"log"
	"slices"
	"time"
)

// 存量条目补演唱者标注(lyrics_speakers,见 lyricspeakers.go)。
//
// 标注从 lyricsSpeakersVersion 起才有,之前解析过的条目一个都没有。符合条件的条目播放到时只问一次 Musixmatch:
// 按录音 ID 或歌名取一份带标注的 macro.subtitles.get(不取译文、罗马音),换算到现有正文上;不重新选源、不动正文。
// 不管换算出没出标注都记下 LyricsSpeakersChecked,之后不再来;没问成(网络失败、没认出这首)不记,同一进程里每首
// 只试一次,下次启动后播放再试。

// lyricsSpeakersVersion:演唱者标注的版本。一轮解析里 Musixmatch 给出过身份关的候选、或者补过一次,条目的
// LyricsSpeakersChecked 记成它。
const lyricsSpeakersVersion = 1

// speakersBackfillTimeout:一次回填最多两次 macro 请求(先按 ID、再按歌名)。
const speakersBackfillTimeout = 20 * time.Second

// speakersBackfillTried:这一进程里已经试过回填的 key。调用方持 enrichMu。
var speakersBackfillTried = map[string]bool{}

// needsLyricSpeakersBackfill:值得补问一次 Musixmatch 的有词条目 —— 还没补过、当前没有对得上正文的标注、
// Musixmatch 以前给过可用候选(多半认得这首)、像是好几个人唱的(署名里有好几位,或曲名带 feat.)、正文自己
// 不带演唱者标记,而且 Musixmatch 这个源开着。手改过的、标了纯音乐的不动。
func needsLyricSpeakersBackfill(e enrichEntry, artist, title string) bool {
	if e.LyricsSpeakersChecked >= lyricsSpeakersVersion || e.Lyrics == "" || e.Instrumental || e.lyricsHandEdited() ||
		!lyricSourceEnabled("musixmatch") {
		return false
	}
	if e.LyricsSpeakers != nil && e.LyricsSpeakers.For == lyricSpeakersFingerprint(e.Lyrics, e.LyricsYRC) {
		return false
	}
	if !slices.Contains(e.LyricsSourcesSeen, "musixmatch") {
		return false
	}
	if len(artistCreditParts(artist)) < 2 && !featCreditSepRe.MatchString(title) {
		return false
	}
	return len(lyricSpeakerLabels(e.Lyrics)) == 0 && len(lyricSpeakerLabels(yrcPlainLines(e.LyricsYRC))) == 0
}

// speakersBackfillOnce:这一进程里第一次问到这个 key 时返回 true。调用方持 enrichMu。
func speakersBackfillOnce(key string) bool {
	if speakersBackfillTried[key] {
		return false
	}
	speakersBackfillTried[key] = true
	return true
}

// backfillLyricSpeakers 补问一次 Musixmatch 补演唱者标注,见文件头注。调用方已置 enrichInflight[key]。
func backfillLyricSpeakers(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok || !needsLyricSpeakersBackfill(e, artist, title) {
		return
	}
	ctx, cancel := context.WithTimeout(withBackgroundOutbound(context.Background()), speakersBackfillTimeout)
	defer cancel()
	appleID, spotifyID := musixmatchTrackIDsFor(artist, title, album)
	m, ok := musixmatchMacroByID(ctx, musixmatchTrackIDs{appleCatalogID: appleID, spotifyTrackID: spotifyID}, artist, title, durationSecs)
	if !ok {
		m, ok = musixmatchMacroByName(ctx, artist, title, "", durationSecs)
	}
	if !ok {
		log.Printf("speakers backfill: %s  musixmatch returned nothing", key)
		return
	}
	mx := []scoredLyricCandidateResult{{Source: "musixmatch", Lyrics: m.lrc, Performers: m.performers}}

	enrichMu.Lock()
	cur, ok := enrichCache[key]
	// 问 Musixmatch 这段时间里正文被换了(重新选源、用户编辑),或者别的路径已经补过。
	if !ok || cur.Lyrics != e.Lyrics || cur.LyricsYRC != e.LyricsYRC || cur.LyricsSpeakersChecked >= lyricsSpeakersVersion {
		enrichMu.Unlock()
		return
	}
	if sp := speakersFromScored(cur.Lyrics, cur.LyricsYRC, mx); sp != nil {
		cur.LyricsSpeakers = sp
		log.Printf("speakers backfill: %s  %d lines tagged", key, countSpeakerLines(sp))
	} else {
		log.Printf("speakers backfill: %s  no speakers (%d tagged spans)", key, len(m.performers))
	}
	cur.LyricsSpeakersChecked = lyricsSpeakersVersion
	enrichCache[key] = cur
	enrichDirty = true
	// 必须先解锁:requestEnrichSave 可能当场保存,保存要取 enrichMu。
	enrichMu.Unlock()
	requestEnrichSave()
}

// countSpeakerLines:标上了的行数(整行、逐字两份取多的那份),只给日志用。
func countSpeakerLines(sp *lyricSpeakers) int {
	n := 0
	for _, labels := range [][]string{sp.LRC, sp.YRC} {
		c := 0
		for _, l := range labels {
			if l != "" {
				c++
			}
		}
		n = max(n, c)
	}
	return n
}
