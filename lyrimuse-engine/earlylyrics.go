package main

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// 首轮中途先上屏:正在播的这首首次解析时,第一轮各源还没回齐就先把歌词交给 App,不等最慢的那一两个源。
// 第一轮照样等齐(或到 lyricSearchDeadline),补查轮照跑,最终用哪份仍以收齐后的结果为准;收齐后挑出来的
// 跟先上屏的那份不同,再提交一次换过去(见 provisionallyrics.go)。见 09 章决策 193。
//
// 什么时候先上屏(earlyLyricsVerdict):
//   - 挑出来的这份单看自己就靠得住(earlyLyricsTrusted):立刻上;当前播放器自家的歌词源还没回话时这条不算,
//     它带着同源加权回来多半会换掉冠军;
//   - 第一份能用的候选到达后已经等满 earlyLyricsGrace,挑出来的这份没有扣分项、歌名沾得上边(earlyLyricsAcceptable):上;
//   - 「顺序优先」模式只看一条:排在它前面的源都回话了、谁也翻不了盘(priorityPickSettled)。
//
// 只在首次解析、正在播的这首、第一轮里起作用(newEarlyLyricsWatch);预取、补空、升级重试、手动搜索都不变。

// earlyLyricsGrace:第一份能用的候选到达后,最多再等多久就按手上最好的那份先上屏。
var earlyLyricsGrace = 2 * time.Second

// earlyLyricsPenaltyTerms:打分里的扣分项。候选带着任意一项,就可能是别的版本、别的录音或时间轴不对,不提前上屏。
// 新加打分项时这里要跟着判一次,TestEarlyLyricsPenaltyTermsCoverEveryDeduction 钉着。
var earlyLyricsPenaltyTerms = map[string]bool{
	scoreTermVersionTags:        true,
	scoreTermDurationOff:        true,
	scoreTermDurationOvershoot:  true,
	scoreTermSourceDurationOff:  true,
	scoreTermWordTimingOverride: true,
	scoreTermLiveAlbumConflict:  true,
	scoreTermTimelineOffset:     true,
	scoreTermTimelineIntrusion:  true,
}

// titleMatchFullPoints:titleMatch 满档(精确同名,或括号里只有不算版本的噪音)的分值,跟着 titleMatchTierPoints 走。
var titleMatchFullPoints = titleMatchTierPoints("a", "a")

// earlyLyricsAcceptable:没被判废、一项扣分都没有、歌名至少沾得上边(titleMatch 有分,含从正文互证伙伴继承的)。
func earlyLyricsAcceptable(c *scoredLyricCandidateResult) bool {
	if c == nil || c.Score < 0 {
		return false
	}
	for _, t := range c.ScoreTerms {
		if earlyLyricsPenaltyTerms[t.Kind] {
			return false
		}
	}
	return scoreTermPoints(c.ScoreTerms, scoreTermTitleMatch) > 0
}

// earlyLyricsTrusted:单看这一份就靠得住 —— 在 earlyLyricsAcceptable 之上,带逐字时间、歌名满档、末尾时间戳跟曲长对得上。
// 歌手由各源挑候选时的身份闸把关,打分里没有单独的歌手项。曲长未知时打分里没有时长项,这条也就不成立。
func earlyLyricsTrusted(c *scoredLyricCandidateResult) bool {
	return earlyLyricsAcceptable(c) &&
		scoreTermPoints(c.ScoreTerms, scoreTermWordTiming) > 0 &&
		scoreTermPoints(c.ScoreTerms, scoreTermTitleMatch) >= titleMatchFullPoints &&
		scoreTermPoints(c.ScoreTerms, scoreTermDuration) > 0
}

// earlyLyricsRule:先上屏是按哪一条放行的,进日志。空串 = 接着等。
type earlyLyricsRule string

const (
	earlyLyricsWait    earlyLyricsRule = ""
	earlyLyricsTrust   earlyLyricsRule = "trusted"
	earlyLyricsGraced  earlyLyricsRule = "grace"
	earlyLyricsInOrder earlyLyricsRule = "order"
)

// earlyLyricsVerdict 判断首轮这一刻能不能先上屏。scored 是这一刻到手结果的打分排序,picked 是 pickLyricCandidate(scored);
// answered 报某个歌词源这一轮回话了没有(跳过、关掉的源也会回一份空结果);graceOver:第一份能用的候选到达后是否已经等满。
func earlyLyricsVerdict(scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult,
	answered func(string) bool, graceOver bool) earlyLyricsRule {
	if picked == nil {
		return earlyLyricsWait
	}
	if features().LyricsSourceMode == lyricsModePriority {
		if priorityPickSettled(scored, picked, answered) {
			return earlyLyricsInOrder
		}
		return earlyLyricsWait
	}
	if earlyLyricsTrusted(picked) && !nativeLyricSourcePending(answered) {
		return earlyLyricsTrust
	}
	if graceOver && earlyLyricsAcceptable(picked) {
		return earlyLyricsGraced
	}
	return earlyLyricsWait
}

// priorityPickSettled:「顺序优先」模式下,排在 picked 前面的源是不是都回话了、而且谁也翻不了盘。
// 排在前面的源有一份因语言不符被判废的候选时不算:后到的源跟它正文一致,判废就会解除(语言闸看正文互证)。
// picked 是播放器本地歌词(不在顺序里)时,顺序里开着的源要全部回话。
func priorityPickSettled(scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult, answered func(string) bool) bool {
	for _, source := range features().LyricsSourceOrder {
		if source == picked.Source {
			return true
		}
		if !lyricSourceEnabled(source) {
			continue
		}
		if !answered(source) {
			return false
		}
		for i := range scored {
			c := &scored[i]
			if c.Source == source && c.Score < 0 && len(c.ScoreTerms) > 0 && c.ScoreTerms[0].Kind == scoreRejectWrongLanguage {
				return false
			}
		}
	}
	return true
}

// nativeLyricSourcePending:当前播放器自家的歌词源开着、这一轮还没回话。播放器本地歌词(KKBOX 等)开搜前就放进来了,不在此列。
func nativeLyricSourcePending(answered func(string) bool) bool {
	for _, s := range lyricSourceNames {
		if isNativeLyricSource(s) && lyricSourceEnabled(s) && !answered(s) {
			return true
		}
	}
	return false
}

type earlyLyricsTargetKey struct{}

// withEarlyLyricsTarget 记下这次首次解析是哪一首:按播放器原样标签算的 key,poller 记正在播那首(noteEnrichPlayingKey)用的就是它。
func withEarlyLyricsTarget(ctx context.Context, key string) context.Context {
	return context.WithValue(ctx, earlyLyricsTargetKey{}, key)
}

// earlyLyricsTargetPlaying:这次首次解析的那一首此刻是不是正在播。
func earlyLyricsTargetPlaying(ctx context.Context) bool {
	key, _ := ctx.Value(earlyLyricsTargetKey{}).(string)
	if key == "" {
		return false
	}
	cur := enrichPlayingKey.Load()
	return cur != nil && *cur == key
}

// earlyLyricsWatch 挂在 fetchScoredLyricCandidatesStreaming 的收集循环上,只在收集 goroutine 里用。
// newEarlyLyricsWatch 不该起作用时返回 nil,下面的方法对 nil 都是空操作。
type earlyLyricsWatch struct {
	ctx           context.Context
	hook          *provisionalLyricsHook
	artist, title string
	start         time.Time
	grace         *time.Timer // 第一份能用的候选到达时起;nil = 还没有能用的
	graceOver     bool
	done          bool
	firstUsable   time.Duration
	shown         time.Duration
	shownSource   string
	rule          earlyLyricsRule
	// holdForNative:播放器的本机数据开搜前就说这一条没有人声(playerLocalNoVocalsHint)。这时宽限期那条也等播放器自家的源回话:
	// 它多半带着播放器的纯音乐标记回来,先上屏的别家的词马上又会被撤掉。
	holdForNative bool
}

// newEarlyLyricsWatch:ctx 上挂着首轮先上屏的回调(首次解析才挂)、这是第一轮、这首此刻正在播,三样都满足才返回非 nil。
func newEarlyLyricsWatch(ctx context.Context, artist, title string) *earlyLyricsWatch {
	h, _ := ctx.Value(provisionalLyricsKey{}).(*provisionalLyricsHook)
	if h == nil || lyricQueryReasonFrom(ctx) != lyricQueryReasonPrimary || !earlyLyricsTargetPlaying(ctx) {
		return nil
	}
	return &earlyLyricsWatch{ctx: ctx, hook: h, artist: artist, title: title, start: time.Now()}
}

// active:还在等先上屏的时机。为假时收集循环不用为它打分。
func (w *earlyLyricsWatch) active() bool {
	return w != nil && !w.done
}

// graceC 是等满 earlyLyricsGrace 的那一拍;没起计时、已经等满或不再等时是 nil(select 里永远不就绪)。
func (w *earlyLyricsWatch) graceC() <-chan time.Time {
	if !w.active() || w.grace == nil || w.graceOver {
		return nil
	}
	return w.grace.C
}

// endGrace 在 graceC 就绪后调,紧接着用这一刻的结果再 observe 一次。
func (w *earlyLyricsWatch) endGrace() {
	if w != nil {
		w.graceOver = true
	}
}

// observe 在每个源回话之后、以及等满 earlyLyricsGrace 那一拍各调一次。answered 是收集循环的 doneSources。
func (w *earlyLyricsWatch) observe(ne neteaseInfo, scored []scoredLyricCandidateResult, answered map[string]bool) {
	if !w.active() {
		return
	}
	if w.ctx.Err() != nil || !earlyLyricsTargetPlaying(w.ctx) {
		w.stop()
		return
	}
	picked := pickLyricCandidate(scored)
	if picked == nil {
		return
	}
	if w.grace == nil {
		w.firstUsable = time.Since(w.start)
		w.grace = time.NewTimer(earlyLyricsGrace)
	}
	isAnswered := func(s string) bool { return answered[s] }
	rule := earlyLyricsVerdict(scored, picked, isAnswered, w.graceOver)
	if rule == earlyLyricsWait || (rule == earlyLyricsGraced && w.holdForNative && nativeLyricSourcePending(isAnswered)) {
		return
	}
	if w.hook.showEarly(w.ctx, ne, scored, picked) {
		w.shown, w.shownSource, w.rule = time.Since(w.start), picked.Source, rule
	}
	w.stop()
}

func (w *earlyLyricsWatch) stop() {
	w.done = true
	if w.grace != nil {
		w.grace.Stop()
	}
}

// finish 在第一轮收集循环结束时调,记一行:第一份能用的候选、先上屏、这一轮结束各在开搜后多久。没先上屏的落 Debug。
func (w *earlyLyricsWatch) finish(answered, total int) {
	if w == nil {
		return
	}
	w.stop()
	if w.shownSource == "" {
		if w.grace != nil {
			slog.Debug("lyrics: first round finished before anything was shown early", "artist", w.artist, "title", w.title,
				"first_usable_ms", w.firstUsable.Milliseconds(), "round_ms", time.Since(w.start).Milliseconds(),
				"sources", fmt.Sprintf("%d/%d", answered, total))
		}
		return
	}
	slog.Info("lyrics: shown before every source answered", "artist", w.artist, "title", w.title,
		"source", w.shownSource, "rule", string(w.rule), "first_usable_ms", w.firstUsable.Milliseconds(),
		"shown_ms", w.shown.Milliseconds(), "round_ms", time.Since(w.start).Milliseconds(),
		"sources", fmt.Sprintf("%d/%d", answered, total))
}
