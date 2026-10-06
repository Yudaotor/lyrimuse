package main

import (
	"context"
	"log"
	"log/slog"
	"sync"
)

// 首轮先上屏:scoredLyricCandidatesStreaming 首轮检索完、接着要跑补查轮(别名 / 主唱变体 / 标题反查)
// 之前,把首轮结果交给 ctx 上挂的回调一次。首次解析拿它先提交一份歌词,补查轮跑完后最终结果整条覆盖。
// 补查轮要先联网找别名、再逐个别名重查,首轮之后常常还要几秒到十几秒;首轮已经挑得出歌词时,
// 不让显示等这几秒。见 09 章决策 102。
//
// 首轮一个可用候选都没有时不回调,也不消耗这一次:救急轮(标题拆分 / 翻唱者 / 别名救急)
// 进到递归调用里拿到结果时,由递归那一层的补查轮入口回调。
//
// 正在播的这首还可能在首轮中途就先上屏一次(showEarly,见 earlylyrics.go)。那样的话首轮收齐时
// 只有挑出来的跟先上屏的那份不同才再回调,同一个 ctx 上合计至多两次。
type provisionalLyricsKey struct{}

type provisionalLyricsHook struct {
	mu    sync.Mutex
	fired bool
	// early:首轮中途已经先上屏过,shownSource / shownLyrics 是那一份;rechecked:首轮收齐后已经比过一次。
	early, rechecked         bool
	shownSource, shownLyrics string
	fn                       func(neteaseInfo, []scoredLyricCandidateResult)
}

// withProvisionalLyrics 挂回调。fn 在检索 goroutine 里同步执行,只该做提交这种快操作。
func withProvisionalLyrics(ctx context.Context, fn func(neteaseInfo, []scoredLyricCandidateResult)) context.Context {
	return context.WithValue(ctx, provisionalLyricsKey{}, &provisionalLyricsHook{fn: fn})
}

// showEarly 由 earlyLyricsWatch 在首轮中途调用:同一个 ctx 上至多一次,而且只在还没有回调过时。picked 是 results 挑出来的那份。
func (h *provisionalLyricsHook) showEarly(ctx context.Context, ne neteaseInfo, results []scoredLyricCandidateResult,
	picked *scoredLyricCandidateResult) bool {
	if ctx.Err() != nil || picked == nil {
		return false
	}
	h.mu.Lock()
	if h.fired {
		h.mu.Unlock()
		return false
	}
	h.fired, h.early = true, true
	h.shownSource, h.shownLyrics = picked.Source, picked.Lyrics
	h.mu.Unlock()
	h.fn(ne, results)
	return true
}

// notifyProvisionalLyrics 在每个补查轮的入口调用。没先上屏过时至多回调一次;首轮中途先上屏过时,
// 第一次调用比一下挑出来的是不是还是那一份(源与正文),不同才回调,之后不再回调。
func notifyProvisionalLyrics(ctx context.Context, ne neteaseInfo, results []scoredLyricCandidateResult) {
	h, _ := ctx.Value(provisionalLyricsKey{}).(*provisionalLyricsHook)
	if h == nil || ctx.Err() != nil || !hasUsableLyricCandidate(results) {
		return
	}
	h.mu.Lock()
	switch {
	case !h.fired:
		h.fired = true
	case h.early && !h.rechecked:
		h.rechecked = true
		if p := pickLyricCandidate(results); p == nil || p.Source == h.shownSource && p.Lyrics == h.shownLyrics {
			h.mu.Unlock()
			return
		}
	default:
		h.mu.Unlock()
		return
	}
	h.mu.Unlock()
	h.fn(ne, results)
}

// neteasePeripheralFields 网易云这一趟带回的外围字段(封面、单曲链接)和曲长。
func neteasePeripheralFields(ne neteaseInfo, durationSecs float64) enrichEntry {
	var e enrichEntry
	e.CoverURL = ne.Cover
	if e.CoverURL != "" {
		e.CoverSource = "netease"
		e.CoverAlbum = ne.Album
	}
	e.NeteaseURL = ne.SongURL
	e.DurationSecs = durationSecs
	return e
}

// lyricsEntryFromScored 按一轮检索结果拼出条目里歌词那部分:网易云封面与链接、各源到场情况、决策存档、
// 选中的歌词。首次解析的最终结果和首轮先上屏的那一份都走这里,两份字段口径一致。选不出歌词时 picked 为 nil,
// 纯音乐 / 纯文本兜底由调用方处理。
//
// 决策日志一首只记一行:provisional(先上屏那一份)落 Debug,它跟最终定案通常一模一样;最终定案时
// shownFirst 是先上屏那份的源("" = 没有先上屏),跟最终胜者不同就带上 provisional_winner,开头几秒
// 显示的是另一份歌词这件事照样看得到。
func lyricsEntryFromScored(decisionPath, artist, title, album string, durationSecs float64, ne neteaseInfo,
	scored []scoredLyricCandidateResult, skipped []string, queries []lyricQueryRecord,
	provisional bool, shownFirst string) (enrichEntry, *scoredLyricCandidateResult) {
	e := neteasePeripheralFields(ne, durationSecs)
	// 不管选没选中,都记下这一轮到底有哪些源真的给出了可用候选 —— needsLyricsRetry
	// 靠"有启用的源这轮没露面"来判断这次结果是不是在信息不全的情况下做的决定。
	e.LyricsSourcesSeen = lyricSourcesWithCandidates(scored)
	e.LyricsSourcesResponded = lyricSourcesResponded(scored)
	e.LyricsSourcesSkipped = skipped
	e.LyricsSongwriters = songwritersFromScored(scored)
	picked := pickLyricCandidate(scored)
	e.LyricsDecision = newLyricsDecision(
		decisionPath, artist, title, album, durationSecs, scored, picked, picked != nil)
	var extra []any
	if !provisional && shownFirst != "" && (picked == nil || picked.Source != shownFirst) {
		extra = append(extra, "provisional_winner", shownFirst)
	}
	logLyricsDecision(e.LyricsDecision, picked, provisional, extra...)
	e.LyricsDecision.SourcesSkipped = skipped
	e.LyricsDecision.QueriesTried = queries
	if picked == nil {
		return e, nil
	}
	// 选中了 → 这一轮就是当前歌词的出处(分槽语义见 LyricsDecisionApplied)。
	e.LyricsDecisionApplied = e.LyricsDecision
	e.Lyrics = picked.Lyrics
	e.LyricsSource = picked.Source
	e.LyricsScore = picked.Score
	e.LyricsScoringVersion = lyricsScoringVersion
	e.ResolvedDurationSecs = durationSecs
	e.LyricsTr, e.LyricsRoma, e.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
	e.LyricsBG, e.LyricsBGChecked = picked.LyricsBG, lyricsBGParserVersion
	refreshSpeakers(&e, scored)
	e.SongLanguage = entrySongLanguage(picked.Lyrics, scored)
	e.dropHokkienRoma()
	e.dropUnusableCantoneseRoma()
	// 这里只做粤拼(纯查表)。helper 那一步要起子进程,排在出词之后由 resolveTrackEnrichment 补。
	e.maybeGenerateJyutpingRoma()
	// 译文换人了,描述译文的两个字段必须跟着换:语言(否则拿旧语言判新译文),
	// 来源(否则上一轮机翻留下的 "machine" 会让新来的社区译文被标成机翻)。
	e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, ""
	return e, picked
}

// earlyCommitLog 给「歌词先上屏」那个回调记日志。首轮先上屏(首轮中途或收齐时)也走同一个回调,一首歌回调一到三次、
// 多半是同一份:第一次、或来源换了的那一次落 Info,同一来源的落 Debug。回调可能来自检索的并发协程,加锁。
type earlyCommitLog struct {
	mu     sync.Mutex
	source string
}

func (l *earlyCommitLog) note(key, source string) {
	l.mu.Lock()
	prev := l.source
	l.source = source
	l.mu.Unlock()
	switch {
	case prev == "":
		log.Printf("lyrics: committed early for %q (source=%s), peripheral fields still resolving", key, source)
	case prev != source:
		log.Printf("lyrics: committed early for %q (source=%s, replacing the first-round %s), peripheral fields still resolving",
			key, source, prev)
	default:
		slog.Debug("lyrics: committed early again, same source", "key", key, "source", source)
	}
}
