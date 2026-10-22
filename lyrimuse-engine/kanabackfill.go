package main

import (
	"context"
	"log"
	"strings"
)

// 存量条目补借假名标注(lyrics_kana,见 kanadonor.go),并让引擎生成的罗马音用上它。
//
// 借来的标注从 lyricsKanaVersion 起才有,之前解析过的日文歌一首都没有。符合条件的条目播放到时,这一进程里每首只做一次:
//   - 还没问过带标注的源(LyricsKanaChecked 落后):只问 kanaDonorSources 里开着的那几家搜一轮,跟正常解析同一套打分
//     过身份关,借到就存。有带标注的源给出过身份关的候选才记 LyricsKanaChecked(refreshKana 的规则);一个都没问到
//     不记,下次启动后播放再试。
//   - 条目有借来的标注、罗马音是引擎生成的:交给 helper 按借来的标注重算(stale_roma 判是不是我们生成的),换掉。
//     写正文的各条路径只刷新标注、不管罗马音,都在这里补齐;算出来跟存着的一样就什么都不写。
// 不重新选源、不动正文。

// kanaBackfillTimeout:一轮限定源的搜索,同正常解析的总截止。
const kanaBackfillTimeout = lyricSearchDeadline

// kanaBackfillTried:这一进程里已经补过的 key。调用方持 enrichMu。
var kanaBackfillTried = map[string]bool{}

// kanaBackfillSearch 是补问实际调用的搜索;测试换成假实现。
var kanaBackfillSearch = func(ctx context.Context, artist, title, album string, durationSecs float64) []scoredLyricCandidateResult {
	_, scored := scoredLyricCandidates(ctx, artist, title, album, durationSecs)
	return scored
}

// kanaSongNeedsReading:正文自己不带 `[kana:]`、像日文、有待标字的有词条目。
func kanaSongNeedsReading(e enrichEntry) bool {
	if e.Lyrics.IsZero() || e.Instrumental {
		return false
	}
	l := e.Lyrics.String()
	return !strings.Contains(l, "[kana:") && kanaRatio(l) >= kanaDonorMinKanaRatio && strings.ContainsFunc(l, kanaNeedsAnnotation)
}

// enabledKanaDonorSources:kanaDonorSources 里开着的源。
func enabledKanaDonorSources() []string {
	var out []string
	for _, s := range lyricSourceNames {
		if kanaDonorSources[s] && lyricSourceEnabled(s) {
			out = append(out, s)
		}
	}
	return out
}

// needsLyricsKanaAsk:该补问一次带标注的源。
func needsLyricsKanaAsk(e enrichEntry) bool {
	return e.LyricsKanaChecked < lyricsKanaVersion && kanaSongNeedsReading(e) && len(enabledKanaDonorSources()) > 0
}

// needsKanaRomaRefresh:有借来的标注、罗马音可能是不用它生成的。
func needsKanaRomaRefresh(e enrichEntry) bool {
	return e.LyricsKana != "" && isStaleRomaCandidate(e)
}

func needsLyricsKanaBackfill(e enrichEntry) bool {
	return needsLyricsKanaAsk(e) || needsKanaRomaRefresh(e)
}

// kanaBackfillOnce:这一进程里第一次问到这个 key 时返回 true。调用方持 enrichMu。
func kanaBackfillOnce(key string) bool {
	if kanaBackfillTried[key] {
		return false
	}
	kanaBackfillTried[key] = true
	return true
}

// backfillLyricsKana 补借假名标注、重算罗马音,见文件头注。调用方已置 enrichInflight[key]。
func backfillLyricsKana(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok || !needsLyricsKanaBackfill(e) {
		return
	}
	next := enrichEntry{Lyrics: e.Lyrics, LyricsYRC: e.LyricsYRC, LyricsKana: e.LyricsKana, LyricsKanaChecked: e.LyricsKanaChecked}
	if needsLyricsKanaAsk(e) {
		sources := enabledKanaDonorSources()
		ctx, cancel := withCancelAfter(withLyricSourceOnly(withBackgroundOutbound(context.Background()), sources), kanaBackfillTimeout)
		scored := kanaBackfillSearch(ctx, artist, title, album, durationSecs)
		cancel()
		refreshKana(&next, scored)
		log.Printf("kana backfill: %s  sources=%v candidates=%d borrowed=%t", key, sources, len(scored), next.LyricsKana != e.LyricsKana)
	}
	var roma string
	if next.LyricsKana != "" && isStaleRomaCandidate(e) {
		r, err := staleRomaRegenerator(e.Lyrics.String(), e.LyricsRoma.String(), next.LyricsKana)
		if err != nil {
			warnf("kana backfill: %s  romanize helper failed: %v", key, err)
		}
		roma = r
	}

	enrichMu.Lock()
	cur, ok := enrichCache[key]
	// 补问这段时间里正文、读音或标注被别的路径改过,这一份不再对应它。
	if !ok || !cur.Lyrics.Equal(e.Lyrics) || !cur.LyricsYRC.Equal(e.LyricsYRC) || !cur.LyricsRoma.Equal(e.LyricsRoma) ||
		cur.LyricsKana != e.LyricsKana || cur.LyricsKanaChecked != e.LyricsKanaChecked {
		enrichMu.Unlock()
		return
	}
	romaChanged := roma != "" && !cur.LyricsRoma.EqualString(roma)
	if cur.LyricsKana == next.LyricsKana && cur.LyricsKanaChecked == next.LyricsKanaChecked && !romaChanged {
		enrichMu.Unlock()
		return
	}
	cur.LyricsKana, cur.LyricsKanaChecked = next.LyricsKana, next.LyricsKanaChecked
	if romaChanged {
		cur.LyricsRoma = bt(roma)
		log.Printf("kana backfill: %s  romanization regenerated with borrowed kana", key)
	}
	enrichCache[key] = cur
	enrichDirty = true
	// 必须先解锁:requestEnrichSaveFor 可能当场保存,保存要取 enrichMu。
	enrichMu.Unlock()
	requestEnrichSaveFor(key)
	if romaChanged {
		exportLyricsFilesFor(key)
	}
}
