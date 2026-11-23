package main

import (
	"context"
	"errors"
	"math"
	"slices"
	"strings"
	"sync"
	"time"
)

// 两段式歌词来源的通用适配器:后端只管「按检索词搜出一批条目」和「取某一条的歌词」,适配器把它包成引擎认的
// LyricProvider。一轮对一首歌是一个任务:搜索 → 过闸(twoStageGate)→ 没有条目过闸就换一种写法再搜 → 按名次取前几条
// 去取词 → 挑一份 → 摊成 SourceResult。任务的结论(TaskOutcome)连同「后端说没有,但它替这个任务发的上游请求没有一个
// 真得到了回答」的纠正都在这里定。歌词源插件经它接进来;形状相同的内置源以后也可以用。见 09 章决策 402。

// 任务结论的取值(TaskOutcome.Status、StageError.Status)。
const (
	taskFound        = "FOUND"
	taskInstrumental = "INSTRUMENTAL"
	taskNoLyrics     = "NO_LYRICS"
	taskNotFound     = "NOT_FOUND"
	taskSkipped      = "SKIPPED"
	taskRateLimited  = "RATE_LIMITED"
	taskUnavailable  = "UNAVAILABLE"
	taskAuthFailed   = "AUTH_FAILED"
	taskNeedsSetup   = "NEEDS_SETUP"
	taskBadResponse  = "BAD_RESPONSE"
	taskPluginError  = "PLUGIN_ERROR"
	taskTimeout      = "TIMEOUT"
	taskCancelled    = "CANCELLED"
)

// 换写法重搜的几种写法(SearchAttempt.Variant)。
const (
	searchVariantPrimary    = "primary"
	searchVariantTitleOnly  = "titleOnly"
	searchVariantRawTitle   = "rawTitle"
	searchVariantNormalized = "normalized"
)

// 查询所在轮次的写法(TwoStageQuery.Round)。
const (
	twoStageRoundPlaying    = "playing"
	twoStageRoundQueue      = "queue"
	twoStageRoundManual     = "manual"
	twoStageRoundBackground = "background"
)

// 两段式来源交给失败诊断的通用原因代码(FailureDiagnoser、QueryIndependentFailer)。App 那边的文案还没接。
const (
	twoStageFailureNeedsSetup = "plugin_needs_setup"
	twoStageFailureAuthFailed = "plugin_auth_failed"
	twoStageFailureError      = "plugin_error"
	// twoStageFailureRateLimited 只给补查轮看(这一轮被限流的来源不进补查轮),不显示。
	twoStageFailureRateLimited = "plugin_rate_limited"
)

const (
	// twoStageDurationTolerance / twoStageMaxDurationDiffSecs:时长闸。两边时长都知道时,差出这个比例或这么多秒就不是同一版。
	twoStageDurationTolerance   = 0.25
	twoStageMaxDurationDiffSecs = 8.0
)

// 闸没过时卡在哪一道(twoStageGate 的 reason)。
const (
	gateReasonTitle    = "title"
	gateReasonArtist   = "artist"
	gateReasonVersion  = "version"
	gateReasonLanguage = "language"
	gateReasonDuration = "duration"
)

// twoStageTrack 是闸对照的那一方:本地这首歌。
type twoStageTrack struct {
	Title, Artist, Album string
	DurationSecs         float64
	// Language:引擎已经知道的语种(songLanguageMandarin / songLanguageCantonese),不知道为空。
	Language string
}

// TrackItem 是后端搜出来的一条。
type TrackItem struct {
	ID                   string
	Title, Artist, Album string
	DurationSecs         float64
	ISRC                 string
	// Language:songLanguageMandarin / songLanguageCantonese,别的取值后端折成空。
	Language string
	// HasSynced:对方在搜索结果里标了有没有同步歌词时才有,nil = 没说。
	HasSynced *bool
	// Lyrics:搜索结果自带的正文;nil = 没带,要走第二段去取。
	Lyrics *LyricsPayload
	// Opaque:后端自己的东西,原样带回第二段,适配器不看。
	Opaque any
}

// LyricsPayload 是一份取回来的歌词,各栏已经是引擎内部的写法。
type LyricsPayload struct {
	// Lines:逐行 LRC。有逐字(YRC)时它是同一份时间轴的整行写法。
	Lines, YRC string
	// Plain:不带时间轴的正文,Lines 为空时才用。
	Plain string
	// Translation / TranslationLang / Romanization:逐行 LRC 写法的译文和它的语言、读音。
	Translation, TranslationLang, Romanization string
	// Background:背景人声轨,YRC 语法。
	Background             string
	Instrumental, NoLyrics bool
	Songwriters            []string
	PageURL                string
	// Unusable:后端交了带时间轴的正文,但校验下来一行都用不了。没有别的歌词时任务按 BAD_RESPONSE 记。
	Unusable bool
}

func (p *LyricsPayload) synced() bool { return p.Lines != "" }

func (p *LyricsPayload) hasPlain() bool { return p.Plain != "" }

// SearchAttempt:这是这一轮第几次搜、最多几次、哪种写法。
type SearchAttempt struct {
	Index, Count int
	Variant      string
}

// TwoStageQuery 是交给后端的一次查询。
type TwoStageQuery struct {
	// Title / Artist / Album:这首歌的歌名、歌手、专辑,没经过归一的写法。
	Title, Artist, Album string
	DurationSecs         float64
	// CleanTitle:去掉括号段的歌名;PrimaryArtist:第一位歌手;Artists:拆开的歌手名单。
	CleanTitle, PrimaryArtist string
	Artists                   []string
	// SearchTitle / SearchArtist:这一次建议用的检索词,SearchArtist 可能为空。
	SearchTitle, SearchArtist string
	Attempt                   SearchAttempt
	// ExternalIDs:播放器报的平台曲目编号,只有来源声明过、引擎又知道的键;没有时为 nil。
	ExternalIDs map[string]string
	// Language:引擎已经知道的语种,不知道为空。
	Language                      string
	TranslationTarget, UILanguage string
	// Round:twoStageRound* 之一。
	Round string
}

// StageError:后端的一次调用没成。Status 是任务结论里表示失败的那几种之一。
type StageError struct {
	Status         string
	RetryAfterSecs int
	Detail         string
}

func (e *StageError) Error() string {
	if e.Detail == "" {
		return e.Status
	}
	return e.Status + ": " + e.Detail
}

// stageErrorOf:err 里的 StageError;别的错误一律当成后端自己出了错。
func stageErrorOf(err error) *StageError {
	var se *StageError
	if errors.As(err, &se) {
		return se
	}
	return &StageError{Status: taskPluginError, Detail: err.Error()}
}

// UpstreamAnswer:后端替一个任务发的一个上游请求得到了什么。Status 为 0 是没拿到对方的应答(被拒、连不上、超时)。
type UpstreamAnswer struct {
	Status         int
	RetryAfterSecs int
}

// answered:对方确实答了。
func (a UpstreamAnswer) answered() bool {
	return (a.Status >= 200 && a.Status < 400) || a.Status == 404 || a.Status == 410
}

// SearchFetcher 是两段式来源的后端。
type SearchFetcher interface {
	// BeginTask 开一个任务。ctx 带任务的截止,任务里的每次调用都不会晚于它;local 是这个任务里闸对照的那首歌。
	BeginTask(ctx context.Context, local twoStageTrack) (SearchFetchTask, error)
}

// SearchFetchTask 是一个任务里后端的那一头。Search、Fetch 可以并发调;错误是 *StageError。
type SearchFetchTask interface {
	Search(ctx context.Context, q *TwoStageQuery) ([]TrackItem, error)
	// CanFetch:后端有没有第二段。没有时,过闸的条目里不带歌词的直接丢掉。
	CanFetch() bool
	Fetch(ctx context.Context, q *TwoStageQuery, item TrackItem) (*LyricsPayload, error)
	// Upstream:这个任务到现在为止,后端替它发的上游请求各得到了什么。
	Upstream() []UpstreamAnswer
	// NoteRateLimited:这个任务的结论是被限流,要这个来源冷却 d。
	NoteRateLimited(d time.Duration)
	// End:任务结束,恰好调一次。
	End()
}

// TaskOutcome 是一个任务的结论。
type TaskOutcome struct {
	Status string
	// RetryAfterSecs:Status 是 RATE_LIMITED 时对方要等多久,不知道为 0。
	RetryAfterSecs int
	// Corrected:结论是拿上游请求的结果纠正出来的,不是后端自报的。
	Corrected bool
}

// TwoStageConfig:一个两段式来源的配置。
type TwoStageConfig struct {
	// SelfRequery:后端自己管换不换写法,适配器每轮只搜一次。
	SelfRequery bool
	// FetchTop:过闸之后按名次取前几条去取词。
	FetchTop int
	// ExternalIDKeys:这个来源声明要用的平台曲目编号的键。
	ExternalIDKeys []string
	// ExternalIDs:播放器为这一首报的平台曲目编号,键同 ExternalIDKeys;nil = 引擎这一侧还没有来路。只在解析在播的歌
	// (RoundEnv.ForPlayingTrack)时问。
	ExternalIDs func(ctx context.Context, q ProviderQuery) map[string]string
	// UILanguage / TranslationTarget:界面语言、用户要的译文语言。
	UILanguage, TranslationTarget func() string
	// Probe:这个来源自己的探测曲,描述符带 Probe 时要有。
	Probe *twoStageTrack
	// Deadline:一个任务最多多久,0 = lyricSearchDeadline。排队等名额的时间算在里面。
	Deadline time.Duration
}

// twoStageGate 判一条搜索结果是不是本地这首:歌名、歌手(对不上时退到「同名、专辑对得上、时长吻合」的三角验证)、版本、
// 语种、时长,按这个先后,卡在哪一道就交哪一道。适配器对搜索结果过闸、后端回答「哪些条目能过闸」的提问,都只许调
// 这一个入口,参数是同一个 local:后端问到的结论不能比最后过闸时宽。
func twoStageGate(local twoStageTrack, item TrackItem) (accepted bool, reason string) {
	if !lyricTitleAccepted(item.Title, local.Title) {
		return false, gateReasonTitle
	}
	if !lyricSourceArtistMatches(item.Artist, local.Artist) &&
		!lyricRecordingTriangleMatchesGuarded(item.Title, item.Album, item.Artist, item.DurationSecs, local.Title, local.Album, local.Artist, local.DurationSecs) {
		return false, gateReasonArtist
	}
	if versionTagsMismatch(local.Title, local.Album, item.Title, item.Album) {
		return false, gateReasonVersion
	}
	if local.Language != "" && item.Language != "" && local.Language != item.Language {
		return false, gateReasonLanguage
	}
	if local.DurationSecs > 0 && item.DurationSecs > 0 {
		diff := math.Abs(item.DurationSecs - local.DurationSecs)
		if diff/local.DurationSecs > twoStageDurationTolerance || diff > twoStageMaxDurationDiffSecs {
			return false, gateReasonDuration
		}
	}
	return true, ""
}

// twoStageSlots:一个来源同时最多两个任务,其中一个只给前台(正在放的、手动搜索),后台只能用另一个。
type twoStageSlots struct {
	shared, foreground chan struct{}
}

func newTwoStageSlots() twoStageSlots {
	return twoStageSlots{shared: make(chan struct{}, 1), foreground: make(chan struct{}, 1)}
}

// acquire 等一个名额,ctx 先结束返回 nil。返回的函数还名额。
func (s twoStageSlots) acquire(ctx context.Context, background bool) (release func()) {
	foreground := s.foreground
	if background {
		foreground = nil
	}
	select {
	case foreground <- struct{}{}:
		return func() { <-s.foreground }
	case s.shared <- struct{}{}:
		return func() { <-s.shared }
	case <-ctx.Done():
		return nil
	}
}

// twoStageProvider 把一个 SearchFetcher 包成 LyricProvider。
type twoStageProvider struct {
	desc    *ProviderDescriptor
	backend SearchFetcher
	cfg     TwoStageConfig
	slots   twoStageSlots

	mu sync.Mutex
	// last:最近一个任务的结论。
	last TaskOutcome
}

// newTwoStageProvider:desc 是这个来源的描述符,backend 是它的后端。
func newTwoStageProvider(desc *ProviderDescriptor, backend SearchFetcher, cfg TwoStageConfig) *twoStageProvider {
	if cfg.FetchTop <= 0 {
		cfg.FetchTop = pluginDefaultFetchTop
	}
	if cfg.Deadline <= 0 {
		cfg.Deadline = lyricSearchDeadline
	}
	return &twoStageProvider{desc: desc, backend: backend, cfg: cfg, slots: newTwoStageSlots()}
}

func (p *twoStageProvider) Descriptor() *ProviderDescriptor { return p.desc }

func (p *twoStageProvider) Resolve(ctx context.Context, q ProviderQuery, env RoundEnv) SourceResult {
	r, _ := p.resolveTask(ctx, q, env)
	return r
}

// QueryIndependentFailure:最近一个任务是鉴权被拒、要先配置或者被限流时非空,补查轮不问它。
func (p *twoStageProvider) QueryIndependentFailure() string {
	switch p.lastOutcome().Status {
	case taskAuthFailed:
		return twoStageFailureAuthFailed
	case taskNeedsSetup:
		return twoStageFailureNeedsSetup
	case taskRateLimited:
		return twoStageFailureRateLimited
	}
	return ""
}

// DiagnosedFailure:最近一个任务没问成时,界面上显示的通用原因代码。
func (p *twoStageProvider) DiagnosedFailure() string {
	switch p.lastOutcome().Status {
	case taskAuthFailed:
		return twoStageFailureAuthFailed
	case taskNeedsSetup:
		return twoStageFailureNeedsSetup
	case taskBadResponse, taskPluginError:
		return twoStageFailureError
	}
	return ""
}

// ProbeOwnTrack:拿这个来源自己的探测曲问一次,问出了歌词返回 true。
func (p *twoStageProvider) ProbeOwnTrack(ctx context.Context) bool {
	probe := p.cfg.Probe
	if probe == nil {
		return false
	}
	q := ProviderQuery{Artist: probe.Artist, Title: probe.Title, Album: probe.Album, SourceTitle: probe.Title, DurationSecs: probe.DurationSecs}
	_, outcome := p.resolveTask(ctx, q, RoundEnv{})
	return outcome.Status == taskFound
}

func (p *twoStageProvider) lastOutcome() TaskOutcome {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.last
}

// resolveTask 跑一个任务,交结果和结论。结论不是「找到了 / 纯音乐 / 有歌没词」时结果是空的。
func (p *twoStageProvider) resolveTask(ctx context.Context, q ProviderQuery, env RoundEnv) (SourceResult, TaskOutcome) {
	result, outcome := p.runTask(ctx, q, env)
	p.mu.Lock()
	p.last = outcome
	p.mu.Unlock()
	if outcome.Status == taskRateLimited {
		lyricSourceRoundFrom(ctx).markSkippedBecause(p.desc.Name, lyricSourceSkipReasonPaused)
	}
	return result, outcome
}

func (p *twoStageProvider) runTask(parent context.Context, q ProviderQuery, env RoundEnv) (SourceResult, TaskOutcome) {
	base, local := p.baseQuery(parent, q, env)
	if local.Title == "" {
		return SourceResult{}, TaskOutcome{Status: taskSkipped}
	}
	ctx, cancel := context.WithTimeout(parent, p.cfg.Deadline)
	defer cancel()
	background := isBackgroundOutbound(parent)
	release := p.slots.acquire(ctx, background)
	if release == nil {
		return SourceResult{}, TaskOutcome{Status: ctxTaskStatus(ctx)}
	}
	defer release()
	// 名额和截止同时到的时候可能两个都拿到:排到时已经过了截止的不调后端。截止按表判,不等 ctx 的定时器轮到。
	if deadline, _ := ctx.Deadline(); !time.Now().Before(deadline) {
		return SourceResult{}, TaskOutcome{Status: taskTimeout}
	}
	if ctx.Err() != nil {
		return SourceResult{}, TaskOutcome{Status: taskCancelled}
	}
	task, err := p.backend.BeginTask(ctx, local)
	if err != nil {
		se := stageErrorOf(err)
		return SourceResult{}, TaskOutcome{Status: se.Status, RetryAfterSecs: se.RetryAfterSecs}
	}
	defer task.End()

	attempts := p.attempts(base, q)
	retried := false
	for i := 0; ; {
		tq := base
		tq.SearchTitle, tq.SearchArtist = attempts[i].title, attempts[i].artist
		tq.Attempt = SearchAttempt{Index: i + 1, Count: len(attempts), Variant: attempts[i].variant}
		round := p.runAttempt(ctx, task, local, &tq)
		if ctx.Err() != nil {
			return SourceResult{}, TaskOutcome{Status: ctxTaskStatus(ctx)}
		}
		if round.failure == nil && round.gated == 0 && i+1 < len(attempts) {
			i++
			continue
		}
		result, outcome := concludeTwoStageRound(round, task.Upstream())
		if outcome.Status != taskRateLimited {
			return result, outcome
		}
		wait := time.Duration(outcome.RetryAfterSecs) * time.Second
		task.NoteRateLimited(wait)
		if retried || background || !twoStageWaitOutRateLimit(ctx, wait) {
			return result, outcome
		}
		retried = true
	}
}

// ctxTaskStatus:任务的 ctx 结束了,是到了截止还是被取消。
func ctxTaskStatus(ctx context.Context) string {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return taskTimeout
	}
	return taskCancelled
}

// twoStageWaitOutRateLimit:对方只让等一下(不超过 lyricSourceShortRetryMax)、等完还在截止之前时,等满它再加一点随机
// 抖动,返回 true;等不到或 ctx 先结束返回 false。
func twoStageWaitOutRateLimit(ctx context.Context, wait time.Duration) bool {
	if wait <= 0 || wait > lyricSourceShortRetryMax {
		return false
	}
	wait = lrclibJittered(wait)
	if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) <= wait {
		return false
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}

// twoStageAttempt:一次搜索用的检索词。
type twoStageAttempt struct {
	variant, title, artist string
}

// attempts:这一轮按先后要搜的几种写法(一共四种,所以一轮最多搜四次),跟前面某一次检索词完全相同的跳过。后端自己管
// 换写法的只有第一种。
func (p *twoStageProvider) attempts(base TwoStageQuery, q ProviderQuery) []twoStageAttempt {
	all := []twoStageAttempt{{searchVariantPrimary, base.CleanTitle, base.PrimaryArtist}}
	if !p.cfg.SelfRequery {
		all = append(all,
			twoStageAttempt{searchVariantTitleOnly, base.CleanTitle, ""},
			twoStageAttempt{searchVariantRawTitle, base.Title, ""},
			twoStageAttempt{searchVariantNormalized, twoStageCleanTitle(twoStageSourceTitle(q)), firstCreditedArtist(q.Artist)})
	}
	var out []twoStageAttempt
	for _, a := range all {
		if a.title == "" || slices.ContainsFunc(out, func(b twoStageAttempt) bool { return b.title == a.title && b.artist == a.artist }) {
			continue
		}
		out = append(out, a)
	}
	return out
}

// twoStageSourceTitle:这一轮交给源去搜、去比的歌名。
func twoStageSourceTitle(q ProviderQuery) string {
	if q.SourceTitle != "" {
		return q.SourceTitle
	}
	return q.Title
}

// twoStageCleanTitle:去掉括号段的歌名;整个歌名都在括号里时原样返回。
func twoStageCleanTitle(title string) string {
	if clean := strings.TrimSpace(stripParens(title)); clean != "" {
		return clean
	}
	return strings.TrimSpace(title)
}

// twoStageArtists:把署名拆成歌手名单,第一位照 firstCreditedArtist,保持原来的大小写。
func twoStageArtists(artist string) []string {
	artist = strings.TrimSpace(artist)
	first := firstCreditedArtist(artist)
	if first == "" {
		return []string{}
	}
	out := []string{first}
	rest := strings.TrimPrefix(normalizeArtistCreditHanAnd(artist), first)
	for _, part := range strings.FieldsFunc(rest, isArtistCreditSep) {
		if part = strings.TrimSpace(part); part != "" && !slices.Contains(out, part) {
			out = append(out, part)
		}
	}
	return out
}

// twoStageRound:这一轮是为什么问的。
func twoStageRound(ctx context.Context) string {
	switch {
	case manualLyricSearch(ctx):
		return twoStageRoundManual
	case isPlayerQueueTrack(ctx):
		return twoStageRoundQueue
	case isBackgroundOutbound(ctx):
		return twoStageRoundBackground
	}
	return twoStageRoundPlaying
}

// baseQuery:这一轮查询里每次搜索都一样的部分,和闸对照的那首歌。闸照内置源的口径拿这一轮归一过的写法去比;交给后端的
// 歌名、歌手、专辑是归一之前的写法(这一轮问的就是那组标签时),检索词的第一种写法也照它。
func (p *twoStageProvider) baseQuery(ctx context.Context, q ProviderQuery, env RoundEnv) (TwoStageQuery, twoStageTrack) {
	title := twoStageSourceTitle(q)
	local := twoStageTrack{Title: title, Artist: q.Artist, Album: q.Album, DurationSecs: q.DurationSecs}
	base := TwoStageQuery{Title: title, Artist: q.Artist, Album: q.Album, DurationSecs: q.DurationSecs, Round: twoStageRound(ctx)}
	if oa, ot, oal, ok := searchQueryOriginalFrom(ctx); ok && title == q.Title {
		if qa, qt, qal := searchQueryFields(oa, ot, oal); qa == q.Artist && qt == q.Title && qal == q.Album {
			base.Artist, base.Title, base.Album = oa, ot, oal
		}
	}
	base.CleanTitle, base.PrimaryArtist, base.Artists = twoStageCleanTitle(base.Title), firstCreditedArtist(base.Artist), twoStageArtists(base.Artist)
	if p.cfg.UILanguage != nil {
		base.UILanguage = p.cfg.UILanguage()
	}
	if p.cfg.TranslationTarget != nil {
		base.TranslationTarget = p.cfg.TranslationTarget()
	}
	if env.ForPlayingTrack && p.cfg.ExternalIDs != nil && len(p.cfg.ExternalIDKeys) > 0 {
		known := p.cfg.ExternalIDs(ctx, q)
		for _, key := range p.cfg.ExternalIDKeys {
			if id := known[key]; id != "" {
				if base.ExternalIDs == nil {
					base.ExternalIDs = map[string]string{}
				}
				base.ExternalIDs[key] = id
			}
		}
	}
	return base, local
}

// twoStageFetched:取了词的一条和取回来的东西。
type twoStageFetched struct {
	item    TrackItem
	payload *LyricsPayload
	err     *StageError
}

// twoStageRoundResult:一次搜索和它带出来的取词。
type twoStageRoundResult struct {
	// failure:搜索那次调用没成。后端答「没有」不算失败,当成空结果。
	failure *StageError
	// gated:过闸的条目数。
	gated int
	// fetched:按名次,取了词的那几条。
	fetched []twoStageFetched
}

// runAttempt:搜一次,过闸,按名次取前几条的歌词。几份取词并发,条目自带歌词的不再取。
func (p *twoStageProvider) runAttempt(ctx context.Context, task SearchFetchTask, local twoStageTrack, q *TwoStageQuery) twoStageRoundResult {
	items, err := task.Search(ctx, q)
	if err != nil {
		if se := stageErrorOf(err); se.Status != taskNotFound {
			return twoStageRoundResult{failure: se}
		}
		items = nil
	}
	var passed []TrackItem
	for _, item := range items {
		if ok, _ := twoStageGate(local, item); ok {
			passed = append(passed, item)
		}
	}
	round := twoStageRoundResult{gated: len(passed)}
	if !task.CanFetch() {
		passed = slices.DeleteFunc(passed, func(item TrackItem) bool { return item.Lyrics == nil })
	}
	// 对方标了「没有同步歌词」的条目先放一边,一条别的都不剩才回头用它们。
	if synced := slices.DeleteFunc(slices.Clone(passed), func(item TrackItem) bool { return item.HasSynced != nil && !*item.HasSynced }); len(synced) > 0 {
		passed = synced
	}
	passed = passed[:min(len(passed), p.cfg.FetchTop)]
	round.fetched = make([]twoStageFetched, len(passed))
	var wg sync.WaitGroup
	for i, item := range passed {
		round.fetched[i].item = item
		if item.Lyrics != nil {
			round.fetched[i].payload = item.Lyrics
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			payload, err := task.Fetch(ctx, q, item)
			if err != nil {
				round.fetched[i].err = stageErrorOf(err)
				return
			}
			round.fetched[i].payload = payload
		}()
	}
	wg.Wait()
	return round
}

// concludeTwoStageRound 给最后一次搜索和它带出来的取词下结论。调用方已经看过任务的 ctx(被取消、到了截止先于这里)。
// 先后是硬约束:
//  1. 有一次调用是后端报的超时,任务按超时记;有一次是后端自己出错,任务按出错记,别的调用拿到了什么都不看。
//  2. 搜索那次调用没成,结论就是它的失败。
//  3. 按名次取第一份带同步歌词的;都没有同步的,取第一份纯文本。
//  4. 没有歌词时按名次看各份:标了纯音乐的,结论是纯音乐;交了正文却一行都用不了的,结论是 BAD_RESPONSE,先碰到哪个
//     算哪个。都没有、取词又有别的失败的,结论是名次最前的那一个失败。
//  5. 剩下的是后端说「没有」或「有歌没词」:拿这个任务里上游请求的结果核一遍(upstream),至少有一个对方确实答了才
//     照它说的记;一个请求都没发按 SKIPPED,见过 429 按 RATE_LIMITED,其余按 UNAVAILABLE。
func concludeTwoStageRound(round twoStageRoundResult, upstream []UpstreamAnswer) (SourceResult, TaskOutcome) {
	failures := make([]*StageError, 0, len(round.fetched)+1)
	if round.failure != nil {
		failures = append(failures, round.failure)
	}
	for _, f := range round.fetched {
		if f.err != nil {
			failures = append(failures, f.err)
		}
	}
	for _, status := range []string{taskTimeout, taskPluginError} {
		if slices.ContainsFunc(failures, func(e *StageError) bool { return e.Status == status }) {
			return SourceResult{}, TaskOutcome{Status: status}
		}
	}
	if round.failure != nil {
		return SourceResult{}, TaskOutcome{Status: round.failure.Status, RetryAfterSecs: round.failure.RetryAfterSecs}
	}
	for _, want := range []func(*LyricsPayload) bool{(*LyricsPayload).synced, (*LyricsPayload).hasPlain} {
		for _, f := range round.fetched {
			if f.payload != nil && want(f.payload) {
				return twoStageSourceResult(f.item, f.payload), TaskOutcome{Status: taskFound}
			}
		}
	}
	for _, f := range round.fetched {
		switch {
		case f.payload == nil:
		case f.payload.Instrumental:
			return SourceResult{instrumental: true, matchTitle: f.item.Title, matchArtist: f.item.Artist, matchAlbum: f.item.Album, srcDur: f.item.DurationSecs},
				TaskOutcome{Status: taskInstrumental}
		case f.payload.Unusable:
			return SourceResult{}, TaskOutcome{Status: taskBadResponse}
		}
	}
	for _, f := range round.fetched {
		if f.err != nil && f.err.Status != taskNotFound {
			return SourceResult{}, TaskOutcome{Status: f.err.Status, RetryAfterSecs: f.err.RetryAfterSecs}
		}
	}
	claimed := SourceResult{}
	claim := TaskOutcome{Status: taskNotFound}
	for _, f := range round.fetched {
		if f.payload != nil && f.payload.NoLyrics {
			claimed = SourceResult{trackFoundNoLyrics: true, matchTitle: f.item.Title, matchArtist: f.item.Artist, matchAlbum: f.item.Album, srcDur: f.item.DurationSecs}
			claim.Status = taskNoLyrics
			break
		}
	}
	if slices.ContainsFunc(upstream, UpstreamAnswer.answered) {
		return claimed, claim
	}
	if len(upstream) == 0 {
		return SourceResult{}, TaskOutcome{Status: taskSkipped, Corrected: true}
	}
	if i := slices.IndexFunc(upstream, func(a UpstreamAnswer) bool { return a.Status == 429 }); i >= 0 {
		return SourceResult{}, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: upstream[i].RetryAfterSecs, Corrected: true}
	}
	return SourceResult{}, TaskOutcome{Status: taskUnavailable, Corrected: true}
}

// twoStageSourceResult 把挑中的那一条和它的歌词摊成 SourceResult。只有纯文本时正文是纯文本、标 plainOnly。
func twoStageSourceResult(item TrackItem, payload *LyricsPayload) SourceResult {
	r := SourceResult{
		matchTitle: item.Title, matchArtist: item.Artist, matchAlbum: item.Album, srcDur: item.DurationSecs,
		isrc: item.ISRC, language: item.Language,
		tr: payload.Translation, trLang: payload.TranslationLang, roma: payload.Romanization,
		songwriters: payload.Songwriters, sourceURL: payload.PageURL,
	}
	if payload.synced() {
		r.lyr, r.yrc, r.bg = payload.Lines, payload.YRC, payload.Background
		return r
	}
	r.lyr, r.plainOnly = payload.Plain, true
	return r
}
