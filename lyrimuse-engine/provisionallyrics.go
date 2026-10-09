package main

import (
	"context"
	"log"
	"log/slog"
	"slices"
	"strconv"
	"strings"
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
// 只有挑出来的那份上屏后看得出跟先上屏的不同(sameShownLyrics)才再回调,同一个 ctx 上合计至多两次。
type provisionalLyricsKey struct{}

type provisionalLyricsHook struct {
	mu    sync.Mutex
	fired bool
	// early:首轮中途已经先上屏过,shown 是那一份;rechecked:首轮收齐后已经比过一次。
	early, rechecked bool
	shown            scoredLyricCandidateResult
	fn               func(neteaseInfo, []scoredLyricCandidateResult)
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
	h.shown = *picked
	h.mu.Unlock()
	h.fn(ne, results)
	return true
}

// notifyProvisionalLyrics 在每个补查轮的入口调用。没先上屏过时至多回调一次;首轮中途先上屏过时,
// 第一次调用比一下挑出来的那份上屏后看不看得出跟先上屏的不同(sameShownLyrics,换了个源但内容一样不算),
// 不同才回调,之后不再回调。见 09 章决策 203。
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
		if p := pickLyricCandidate(results); p == nil || sameShownLyrics(*p, h.shown) {
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
//
// onScreen 是最近一次提交上屏的那一份(nil = 没有)。最终定案挑出来的是别的源、上屏后却看不出差别时,
// 留在屏上那个源(keepShownLyrics),日志带 kept_on_screen_over。
func lyricsEntryFromScored(decisionPath, artist, title, album string, durationSecs float64, ne neteaseInfo,
	scored []scoredLyricCandidateResult, skipped []string, queries []lyricQueryRecord,
	provisional bool, shownFirst string, onScreen *scoredLyricCandidateResult) (enrichEntry, *scoredLyricCandidateResult) {
	e := neteasePeripheralFields(ne, durationSecs)
	// 不管选没选中,都记下这一轮到底有哪些源真的给出了可用候选 —— needsLyricsRetry
	// 靠"有启用的源这轮没露面"来判断这次结果是不是在信息不全的情况下做的决定。
	e.LyricsSourcesSeen = lyricSourcesWithCandidates(scored)
	e.LyricsSourcesResponded = lyricSourcesResponded(scored)
	e.LyricsSourcesSkipped = lyricSourcesSkippedForRetry(skipped)
	e.LyricsSongwriters = songwritersFromScored(scored)
	picked := pickLyricCandidate(scored)
	var extra []any
	if !provisional {
		if kept := keepShownLyrics(scored, picked, onScreen); kept != picked {
			extra = append(extra, "kept_on_screen_over", picked.Source)
			picked = kept
		}
	}
	e.LyricsDecision = newLyricsDecision(
		decisionPath, artist, title, album, durationSecs, scored, picked, picked != nil)
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
	e.stampLyricsScoring()
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

// keepShownLyrics:picked 是另一个源、上屏后却跟 onScreen 看不出差别时,换成 scored 里 onScreen 那个源、
// 内容也一样的那一条;找不到就照旧用 picked。见 09 章决策 203。
func keepShownLyrics(scored []scoredLyricCandidateResult, picked, onScreen *scoredLyricCandidateResult) *scoredLyricCandidateResult {
	if picked == nil || onScreen == nil || picked.Source == onScreen.Source || !sameShownLyrics(*picked, *onScreen) {
		return picked
	}
	usable := lyricCandidateUsable(scored)
	for i := range scored {
		if scored[i].Source == onScreen.Source && usable(scored[i]) && sameShownLyrics(scored[i], *onScreen) {
			return &scored[i]
		}
	}
	return picked
}

// sameShownLyrics:两份候选上屏后看不看得出差别。整行正文、逐字、译文、罗马音、背景人声逐一按 shownLyricsForm 比,
// 任何一处不同(时间差 1 毫秒也算)都是不同。
func sameShownLyrics(a, b scoredLyricCandidateResult) bool {
	return slices.Equal(shownLyricsForm(a.Lyrics), shownLyricsForm(b.Lyrics)) &&
		slices.Equal(shownLyricsForm(a.LyricsYRC), shownLyricsForm(b.LyricsYRC)) &&
		slices.Equal(shownLyricsForm(a.LyricsTr), shownLyricsForm(b.LyricsTr)) &&
		slices.Equal(shownLyricsForm(a.LyricsRoma), shownLyricsForm(b.LyricsRoma)) &&
		slices.Equal(shownLyricsForm(a.LyricsBG), shownLyricsForm(b.LyricsBG))
}

// lyricsCandidateAddsNothingShown:把条目现存这份换成候选 c,屏上看不出多了或改了什么 —— 整行正文与时间轴上屏后一样
// (shownLyricsForm 的口径);逐字、译文、罗马音、背景人声这几份,c 要么没给、要么跟现存那份一样。现存那份多出来的
// (机翻补的译文、引擎生成的罗马音、c 没给的逐字)不算差别:不换就不会丢。
func lyricsCandidateAddsNothingShown(e enrichEntry, c scoredLyricCandidateResult) bool {
	if e.Lyrics == "" || !slices.Equal(shownLyricsForm(e.Lyrics), shownLyricsForm(c.Lyrics)) {
		return false
	}
	covered := func(current, candidate string) bool {
		return candidate == "" || slices.Equal(shownLyricsForm(current), shownLyricsForm(candidate))
	}
	return covered(e.LyricsYRC, c.LyricsYRC) && covered(e.LyricsTr, c.LyricsTr) &&
		covered(e.LyricsRoma, c.LyricsRoma) && covered(e.LyricsBG, c.LyricsBG)
}

// keepsShownLyricsOver:重评、升级重试的冠军跟条目现存这份原文不同,换上去屏上却看不出差别(lyricsCandidateAddsNothingShown)
// 时留着现存这份。原文相同的不归这里管(补逐字、换源记账照旧)。见 09 章决策 203。
func keepsShownLyricsOver(e enrichEntry, picked *scoredLyricCandidateResult) bool {
	return picked != nil && picked.Lyrics != e.Lyrics && lyricsCandidateAddsNothingShown(e, *picked)
}

// shownLyricsForm 把一份歌词换成只留上屏看得出的部分:LRC 行的时间标签换算成毫秒(`[00:01.5]` 与 `[00:01.500]` 相同),
// 逐字行(`[1000,500]…`)原样;[offset:] 不为 0 时单记一项;元信息行(`[ti:]`、`[id:]`)、不带时间的行、行首尾空白都不算。
func shownLyricsForm(s string) []string {
	var out []string
	if off := lrcOffsetTagMs(s); off != 0 {
		out = append(out, "offset:"+strconv.Itoa(off))
	}
	for _, raw := range strings.Split(s, "\n") {
		line := strings.TrimSpace(raw)
		if m := lrcLinePattern.FindStringSubmatch(line); m != nil {
			var b strings.Builder
			for _, tag := range lrcTimeTagPattern.FindAllString(m[1], -1) {
				if st := lrcTimestampCaptureRe.FindStringSubmatch(tag); st != nil {
					b.WriteString("[" + strconv.Itoa(lrcStampMs(st)) + "]")
				} else {
					b.WriteString(tag)
				}
			}
			out = append(out, b.String()+strings.TrimSpace(m[2]))
		} else if len(line) > 1 && line[0] == '[' && line[1] >= '0' && line[1] <= '9' {
			out = append(out, line)
		}
	}
	return out
}
