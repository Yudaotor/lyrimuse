package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"
)

const twoStageLRC = "[00:01.00]Paper lanterns in the rain\n[00:05.50]Drifting slowly down the lane\n[00:10.25]Every light a small refrain\n"

// fakeStageBackend:照脚本答的后端,记下适配器对它做了什么。
type fakeStageBackend struct {
	mu sync.Mutex
	// search / fetch:每次调用怎么答;fetch 为 nil 表示没有第二段。
	search func(ctx context.Context, q *TwoStageQuery) ([]TrackItem, error)
	fetch  func(ctx context.Context, q *TwoStageQuery, item TrackItem) (*LyricsPayload, error)
	// upstream:任务里上游请求的结果,宿主纠正读它。
	upstream []UpstreamAnswer
	beginErr error

	queries     []TwoStageQuery
	fetchedIDs  []string
	rateLimited []time.Duration
	locals      []twoStageTrack
	begun       int
	ended       int
}

func (b *fakeStageBackend) BeginTask(_ context.Context, local twoStageTrack) (SearchFetchTask, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.beginErr != nil {
		return nil, b.beginErr
	}
	b.begun++
	b.locals = append(b.locals, local)
	return fakeStageTask{b}, nil
}

type fakeStageTask struct{ b *fakeStageBackend }

func (t fakeStageTask) Search(ctx context.Context, q *TwoStageQuery) ([]TrackItem, error) {
	t.b.mu.Lock()
	t.b.queries = append(t.b.queries, *q)
	t.b.mu.Unlock()
	return t.b.search(ctx, q)
}

func (t fakeStageTask) CanFetch() bool { return t.b.fetch != nil }

func (t fakeStageTask) Fetch(ctx context.Context, q *TwoStageQuery, item TrackItem) (*LyricsPayload, error) {
	t.b.mu.Lock()
	t.b.fetchedIDs = append(t.b.fetchedIDs, item.ID)
	t.b.mu.Unlock()
	return t.b.fetch(ctx, q, item)
}

func (t fakeStageTask) Upstream() []UpstreamAnswer {
	t.b.mu.Lock()
	defer t.b.mu.Unlock()
	return slices.Clone(t.b.upstream)
}

func (t fakeStageTask) NoteRateLimited(d time.Duration) {
	t.b.mu.Lock()
	t.b.rateLimited = append(t.b.rateLimited, d)
	t.b.mu.Unlock()
}

func (t fakeStageTask) End() {
	t.b.mu.Lock()
	t.b.ended++
	t.b.mu.Unlock()
}

// searches:记下的各次搜索,写成「写法 第几次/共几次 歌名|歌手」。
func (b *fakeStageBackend) searches() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []string
	for _, q := range b.queries {
		out = append(out, fmt.Sprintf("%s %d/%d %s|%s", q.Attempt.Variant, q.Attempt.Index, q.Attempt.Count, q.SearchTitle, q.SearchArtist))
	}
	return out
}

// answeredOK:上游答过一次 200,后端说「没有」时照它说的记。
var answeredOK = []UpstreamAnswer{{Status: 200}}

func stageItem(id string) TrackItem {
	return TrackItem{ID: id, Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", Album: "Fixtures", DurationSecs: 215}
}

func stageItemWith(id string, payload LyricsPayload) TrackItem {
	item := stageItem(id)
	item.Lyrics = &payload
	return item
}

func stageSearchReturns(items ...TrackItem) func(context.Context, *TwoStageQuery) ([]TrackItem, error) {
	return func(context.Context, *TwoStageQuery) ([]TrackItem, error) { return items, nil }
}

var stageTestQuery = ProviderQuery{Artist: "Lyrimuse Test Band", Title: "Paper Lanterns", Album: "Fixtures", SourceTitle: "Paper Lanterns", DurationSecs: 215}

func newStageProvider(b *fakeStageBackend, cfg TwoStageConfig) *twoStageProvider {
	return newTwoStageProvider(&ProviderDescriptor{Name: "plugin:test.stage", Assembly: &CandidateAssembly{}}, b, cfg)
}

func TestTwoStageGate(t *testing.T) {
	local := twoStageTrack{Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", Album: "Fixtures", DurationSecs: 200}
	item := func(edit func(*TrackItem)) TrackItem {
		it := TrackItem{ID: "1", Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", Album: "Fixtures", DurationSecs: 200}
		edit(&it)
		return it
	}
	for name, tc := range map[string]struct {
		local  twoStageTrack
		item   TrackItem
		reason string
	}{
		"一模一样":            {local, item(func(*TrackItem) {}), ""},
		"条目没给专辑和时长":       {local, item(func(it *TrackItem) { it.Album, it.DurationSecs = "", 0 }), ""},
		"本地不知道时长":         {twoStageTrack{Title: "Paper Lanterns", Artist: "Lyrimuse Test Band"}, item(func(it *TrackItem) { it.DurationSecs = 999 }), ""},
		"歌名不是这首":          {local, item(func(it *TrackItem) { it.Title = "Another Song" }), gateReasonTitle},
		"歌手不是这位":          {local, item(func(it *TrackItem) { it.Artist, it.Album = "Someone Else", "Elsewhere" }), gateReasonArtist},
		"歌手没给、专辑也对不上":     {local, item(func(it *TrackItem) { it.Artist, it.Album = "", "Elsewhere" }), gateReasonArtist},
		"歌手写法不同但专辑时长对得上":  {local, item(func(it *TrackItem) { it.Artist = "LTB" }), ""},
		"歌手对不上、专辑对得上但时长差": {local, item(func(it *TrackItem) { it.Artist, it.DurationSecs = "LTB", 205 }), gateReasonArtist},
		"条目是现场版":          {local, item(func(it *TrackItem) { it.Title = "Paper Lanterns (Live)" }), gateReasonVersion},
		"本地是现场版、条目不是":     {twoStageTrack{Title: "Paper Lanterns (Live)", Artist: "Lyrimuse Test Band", DurationSecs: 200}, item(func(it *TrackItem) { it.Album = "" }), gateReasonVersion},
		"语种不同":            {twoStageTrack{Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", Language: songLanguageCantonese}, item(func(it *TrackItem) { it.Language = songLanguageMandarin }), gateReasonLanguage},
		"语种相同":            {twoStageTrack{Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", Language: songLanguageCantonese}, item(func(it *TrackItem) { it.Language = songLanguageCantonese }), ""},
		"只有条目标了语种":        {local, item(func(it *TrackItem) { it.Language = songLanguageMandarin }), ""},
		"时长差 8 秒整":        {local, item(func(it *TrackItem) { it.DurationSecs = 208 }), ""},
		"时长差 8 秒多一点":      {local, item(func(it *TrackItem) { it.DurationSecs = 208.5 }), gateReasonDuration},
		"时长短了 9 秒":        {local, item(func(it *TrackItem) { it.DurationSecs = 191 }), gateReasonDuration},
		"短歌差出四分之一":        {twoStageTrack{Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", DurationSecs: 20}, item(func(it *TrackItem) { it.DurationSecs, it.Album = 26, "" }), gateReasonDuration},
		"短歌差四分之一整":        {twoStageTrack{Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", DurationSecs: 20}, item(func(it *TrackItem) { it.DurationSecs, it.Album = 25, "" }), ""},
		"歌名和时长都不对先报歌名":    {local, item(func(it *TrackItem) { it.Title, it.DurationSecs = "Another Song", 30 }), gateReasonTitle},
		"歌手和版本都不对先报歌手": {local, item(func(it *TrackItem) {
			it.Artist, it.Album, it.Title = "Someone Else", "Elsewhere", "Paper Lanterns (Live)"
		}), gateReasonArtist},
		"版本和时长都不对先报版本": {local, item(func(it *TrackItem) { it.Title, it.DurationSecs = "Paper Lanterns (Live)", 30 }), gateReasonVersion},
		"语种和时长都不对先报语种": {twoStageTrack{Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", Language: songLanguageCantonese, DurationSecs: 200}, item(func(it *TrackItem) { it.Language, it.DurationSecs, it.Album = songLanguageMandarin, 30, "" }), gateReasonLanguage},
	} {
		accepted, reason := twoStageGate(tc.local, tc.item)
		if accepted != (tc.reason == "") || reason != tc.reason {
			t.Errorf("%s:过闸 = %v、卡在 %q,期望卡在 %q", name, accepted, reason, tc.reason)
		}
	}
}

// 闸只有 twoStageGate 这一个入口:适配器里别处不直接调那几道闸的原件,搜索结果只在 runAttempt 里拿它过一次闸。
func TestTwoStageGateIsTheOnlyGateEntry(t *testing.T) {
	raw, err := os.ReadFile("lyrictwostage.go")
	if err != nil {
		t.Fatal(err)
	}
	gate := goFuncSource(t, "lyrictwostage.go", "twoStageGate")
	rest := strings.Replace(string(raw), gate, "", 1)
	for _, primitive := range []string{"lyricTitleAccepted(", "lyricSourceArtistMatches(", "lyricRecordingTriangleMatchesGuarded(", "versionTagsMismatch("} {
		if !containsCode(gate, primitive) {
			t.Errorf("twoStageGate 里该用到 %s", primitive)
		}
		if strings.Contains(rest, primitive) {
			t.Errorf("lyrictwostage.go 里 twoStageGate 之外不该再出现 %s:闸只留一个入口", primitive)
		}
	}
	if !containsCode(gate, "diff/local.DurationSecs > twoStageDurationTolerance || diff > twoStageMaxDurationDiffSecs") ||
		twoStageDurationTolerance != 0.25 || twoStageMaxDurationDiffSecs != 8 {
		t.Error("时长闸是比例 25% 加绝对 8 秒")
	}
	if !containsCode(rest, "if ok, _ := twoStageGate(local, item); ok {") || strings.Count(rest, "twoStageGate(") != 1 {
		t.Error("适配器只在 runAttempt 里拿 twoStageGate(local, item) 给搜索结果过闸")
	}
}

// 查询里每次搜索都一样的那部分:清理过的歌名、第一位歌手、歌手名单、界面语言、译文语言,轮次照 ctx。
func TestTwoStageQueryCarriesTheTrack(t *testing.T) {
	b := &fakeStageBackend{search: stageSearchReturns(), upstream: answeredOK}
	p := newStageProvider(b, TwoStageConfig{SelfRequery: true, UILanguage: func() string { return "ja" }, TranslationTarget: func() string { return "zh-Hans" }})
	q := ProviderQuery{Artist: "K/DA, Madison Beer & i-dle", Title: "POP/STARS (Remix)", Album: "POP/STARS", SourceTitle: "POP/STARS (Remix)", DurationSecs: 191.5}
	p.Resolve(context.Background(), q, RoundEnv{})
	want := TwoStageQuery{
		Title: "POP/STARS (Remix)", Artist: "K/DA, Madison Beer & i-dle", Album: "POP/STARS", DurationSecs: 191.5,
		CleanTitle: "POP/STARS", PrimaryArtist: "K/DA", Artists: []string{"K/DA", "Madison Beer", "i-dle"},
		SearchTitle: "POP/STARS", SearchArtist: "K/DA", Attempt: SearchAttempt{Index: 1, Count: 1, Variant: searchVariantPrimary},
		UILanguage: "ja", TranslationTarget: "zh-Hans", Round: twoStageRoundPlaying,
	}
	if len(b.queries) != 1 || !reflect.DeepEqual(b.queries[0], want) {
		t.Fatalf("查询\n%+v\n期望\n%+v", b.queries, want)
	}
	if b.locals[0] != (twoStageTrack{Title: "POP/STARS (Remix)", Artist: "K/DA, Madison Beer & i-dle", Album: "POP/STARS", DurationSecs: 191.5}) {
		t.Errorf("闸对照的那首歌 %+v", b.locals[0])
	}
	for round, ctx := range map[string]context.Context{
		twoStageRoundManual:     withManualLyricSearch(context.Background()),
		twoStageRoundQueue:      withPlayerQueueTrack(withBackgroundOutbound(context.Background())),
		twoStageRoundBackground: withBackgroundOutbound(context.Background()),
		twoStageRoundPlaying:    withOnDemandLyricRound(context.Background()),
	} {
		b.queries = nil
		p.Resolve(ctx, stageTestQuery, RoundEnv{})
		if len(b.queries) != 1 || b.queries[0].Round != round {
			t.Errorf("轮次 %s:查询里写的是 %+v", round, b.queries)
		}
	}
	// 歌名整个在括号里、没有歌手、带编号的歌名另有一份交给源的写法。
	b.queries = nil
	p.Resolve(context.Background(), ProviderQuery{Title: "(Untitled)", SourceTitle: "(Untitled) 2"}, RoundEnv{})
	if got := b.queries[0]; got.Title != "(Untitled) 2" || got.CleanTitle != "2" || got.PrimaryArtist != "" || len(got.Artists) != 0 || got.Artists == nil {
		t.Errorf("没有歌手、歌名带括号的查询:%+v", got)
	}
	if got := twoStageCleanTitle("(Untitled)"); got != "(Untitled)" {
		t.Errorf("整个歌名都在括号里时原样返回,得到 %q", got)
	}
	b.queries = nil
	if _, outcome := p.resolveTask(context.Background(), ProviderQuery{Artist: "x"}, RoundEnv{}); outcome.Status != taskSkipped || len(b.queries) != 0 || b.begun != 6 {
		t.Errorf("没有歌名的查询不该开任务:结论 %+v、搜了 %d 次、开过 %d 个任务", outcome, len(b.queries), b.begun)
	}
}

// 这一轮问的就是归一之前那组标签时,交给后端的是归一之前的写法,换写法的最后一种才是归一过的;闸照旧拿归一过的去比。
func TestTwoStageQueryUsesOriginalWritingWhenTheRoundAsksForIt(t *testing.T) {
	b := &fakeStageBackend{search: stageSearchReturns(), upstream: answeredOK}
	p := newStageProvider(b, TwoStageConfig{})
	qa, qt, qal := searchQueryFields("周杰倫", "聽媽媽的話", "依然范特西")
	ctx := withSearchQueryOriginal(context.Background(), "周杰倫", "聽媽媽的話", "依然范特西")
	p.Resolve(ctx, ProviderQuery{Artist: qa, Title: qt, Album: qal, SourceTitle: qt, DurationSecs: 265}, RoundEnv{})
	if got, want := b.searches(), []string{"primary 1/3 聽媽媽的話|周杰倫", "titleOnly 2/3 聽媽媽的話|", "normalized 3/3 听妈妈的话|周杰伦"}; !slices.Equal(got, want) {
		t.Errorf("搜索 %v\n期望 %v", got, want)
	}
	if q := b.queries[0]; q.Title != "聽媽媽的話" || q.Artist != "周杰倫" || q.Album != "依然范特西" || b.locals[0].Title != qt || b.locals[0].Artist != qa {
		t.Errorf("交给后端的该是归一之前的写法 %+v,闸对照的是归一过的 %+v", q, b.locals[0])
	}
	// 换了身份的轮次(这一轮的歌手不是那组标签归一出来的):ctx 上记的写法不是这一轮的,不用。
	b.queries = nil
	p.Resolve(ctx, ProviderQuery{Artist: "Jay Chou", Title: qt, Album: qal, SourceTitle: qt}, RoundEnv{})
	if got, want := b.searches(), []string{"primary 1/2 听妈妈的话|Jay Chou", "titleOnly 2/2 听妈妈的话|"}; !slices.Equal(got, want) {
		t.Errorf("换了身份的轮次搜索 %v\n期望 %v", got, want)
	}
}

// 平台曲目编号:来源声明了的键里引擎知道的才给,只在解析在播的歌时给。
func TestTwoStageExternalIDsOnlyDeclaredAndOnlyForPlayingTrack(t *testing.T) {
	known := map[string]string{"appleMusic": "1440000001", "spotify": "4uLU6hMCjMI75M1A2tKUQC", "netease": ""}
	asked := 0
	for name, tc := range map[string]struct {
		keys    []string
		playing bool
		source  bool
		want    map[string]string
	}{
		"声明了两个、知道其中一个": {[]string{"appleMusic", "youtube"}, true, true, map[string]string{"appleMusic": "1440000001"}},
		"声明了的都知道":      {[]string{"appleMusic", "spotify"}, true, true, map[string]string{"appleMusic": "1440000001", "spotify": "4uLU6hMCjMI75M1A2tKUQC"}},
		"没声明":          {nil, true, true, nil},
		"声明的一个都不知道":    {[]string{"youtube", "netease"}, true, true, nil},
		"不是在播的歌":       {[]string{"appleMusic"}, false, true, nil},
		"引擎这一侧没有来路":    {[]string{"appleMusic"}, true, false, nil},
	} {
		b := &fakeStageBackend{search: stageSearchReturns(), upstream: answeredOK}
		cfg := TwoStageConfig{SelfRequery: true, ExternalIDKeys: tc.keys}
		if tc.source {
			cfg.ExternalIDs = func(context.Context, ProviderQuery) map[string]string { asked++; return known }
		}
		before := asked
		newStageProvider(b, cfg).Resolve(context.Background(), stageTestQuery, RoundEnv{ForPlayingTrack: tc.playing})
		if got := b.queries[0].ExternalIDs; !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s:给了 %v,期望 %v", name, got, tc.want)
		}
		if (tc.want == nil && name != "声明的一个都不知道") && asked != before {
			t.Errorf("%s:不该去问引擎知道哪些编号", name)
		}
	}
}

// 换写法重搜:没有条目过闸就换下一种写法,哪一次有条目过闸就停;调用失败不换;后端自己管的只搜一次。
func TestTwoStageRequery(t *testing.T) {
	wrong := TrackItem{ID: "201", Title: "Another Song", Artist: "Someone Else", DurationSecs: 180}
	right := stageItemWith("202", LyricsPayload{Lines: twoStageLRC})
	live := ProviderQuery{Artist: "Lyrimuse Test Band", Title: "Paper Lanterns (Live at Fixture Hall)", SourceTitle: "Paper Lanterns (Live at Fixture Hall)", DurationSecs: 215}
	for name, tc := range map[string]struct {
		cfg     TwoStageConfig
		q       ProviderQuery
		search  func(ctx context.Context, q *TwoStageQuery) ([]TrackItem, error)
		want    []string
		outcome string
	}{
		"三种写法都没过闸": {TwoStageConfig{}, live, stageSearchReturns(wrong),
			[]string{"primary 1/3 Paper Lanterns|Lyrimuse Test Band", "titleOnly 2/3 Paper Lanterns|", "rawTitle 3/3 Paper Lanterns (Live at Fixture Hall)|"}, taskNotFound},
		"歌名没被清理过只有两种": {TwoStageConfig{}, stageTestQuery, stageSearchReturns(),
			[]string{"primary 1/2 Paper Lanterns|Lyrimuse Test Band", "titleOnly 2/2 Paper Lanterns|"}, taskNotFound},
		"没有歌手时前两种是同一个": {TwoStageConfig{}, ProviderQuery{Title: "Paper Lanterns (Demo)", SourceTitle: "Paper Lanterns (Demo)"}, stageSearchReturns(),
			[]string{"primary 1/2 Paper Lanterns|", "rawTitle 2/2 Paper Lanterns (Demo)|"}, taskNotFound},
		"第二次有条目过闸就停": {TwoStageConfig{}, live, func(_ context.Context, q *TwoStageQuery) ([]TrackItem, error) {
			if q.Attempt.Index == 2 {
				item := right
				item.Title = "Paper Lanterns (Live at Fixture Hall)"
				return []TrackItem{wrong, item}, nil
			}
			return []TrackItem{wrong}, nil
		}, []string{"primary 1/3 Paper Lanterns|Lyrimuse Test Band", "titleOnly 2/3 Paper Lanterns|"}, taskFound},
		"第一次就过闸不再搜": {TwoStageConfig{}, stageTestQuery, stageSearchReturns(right),
			[]string{"primary 1/2 Paper Lanterns|Lyrimuse Test Band"}, taskFound},
		"后端答没有也换写法": {TwoStageConfig{}, stageTestQuery, func(_ context.Context, q *TwoStageQuery) ([]TrackItem, error) {
			if q.Attempt.Index == 1 {
				return nil, &StageError{Status: taskNotFound}
			}
			return []TrackItem{right}, nil
		}, []string{"primary 1/2 Paper Lanterns|Lyrimuse Test Band", "titleOnly 2/2 Paper Lanterns|"}, taskFound},
		"调用失败不换写法": {TwoStageConfig{}, stageTestQuery, func(context.Context, *TwoStageQuery) ([]TrackItem, error) {
			return nil, &StageError{Status: taskUnavailable}
		}, []string{"primary 1/2 Paper Lanterns|Lyrimuse Test Band"}, taskUnavailable},
		"过了闸但没有歌词不换写法": {TwoStageConfig{}, stageTestQuery, stageSearchReturns(stageItemWith("1", LyricsPayload{})),
			[]string{"primary 1/2 Paper Lanterns|Lyrimuse Test Band"}, taskNotFound},
		"后端自己管换写法的只搜一次": {TwoStageConfig{SelfRequery: true}, live, stageSearchReturns(wrong),
			[]string{"primary 1/1 Paper Lanterns|Lyrimuse Test Band"}, taskNotFound},
	} {
		b := &fakeStageBackend{search: tc.search, upstream: answeredOK}
		_, outcome := newStageProvider(b, tc.cfg).resolveTask(context.Background(), tc.q, RoundEnv{})
		if got := b.searches(); !slices.Equal(got, tc.want) || outcome.Status != tc.outcome {
			t.Errorf("%s:搜索 %v、结论 %s\n期望 %v、%s", name, got, outcome.Status, tc.want, tc.outcome)
		}
		if b.begun != 1 || b.ended != 1 {
			t.Errorf("%s:一轮该恰好开一个任务、结束一次,得到 %d / %d", name, b.begun, b.ended)
		}
	}
}

// 四种写法都不一样时最多搜四次。
func TestTwoStageRequeryStopsAtFourAttempts(t *testing.T) {
	b := &fakeStageBackend{search: stageSearchReturns(), upstream: answeredOK}
	p := newStageProvider(b, TwoStageConfig{})
	qa, qt, qal := searchQueryFields("周杰倫", "聽媽媽的話 (現場)", "依然范特西")
	p.Resolve(withSearchQueryOriginal(context.Background(), "周杰倫", "聽媽媽的話 (現場)", "依然范特西"), ProviderQuery{Artist: qa, Title: qt, Album: qal, SourceTitle: qt}, RoundEnv{})
	want := []string{"primary 1/4 聽媽媽的話|周杰倫", "titleOnly 2/4 聽媽媽的話|", "rawTitle 3/4 聽媽媽的話 (現場)|", "normalized 4/4 听妈妈的话|周杰伦"}
	if got := b.searches(); !slices.Equal(got, want) {
		t.Errorf("搜索 %v\n期望 %v", got, want)
	}
}

// 过闸之后:没有第二段的后端,不带歌词的条目丢掉;标了没有同步歌词的先放一边;按名次取前几条,自带歌词的不再取。
func TestTwoStageFetchesTopItemsInRankOrder(t *testing.T) {
	no, yes := false, true
	plain := LyricsPayload{Plain: "plain text"}
	lines := LyricsPayload{Lines: twoStageLRC}
	withFlag := func(item TrackItem, flag *bool) TrackItem { item.HasSynced = flag; return item }
	fetchByID := func(payloads map[string]LyricsPayload) func(context.Context, *TwoStageQuery, TrackItem) (*LyricsPayload, error) {
		return func(_ context.Context, _ *TwoStageQuery, item TrackItem) (*LyricsPayload, error) {
			p, ok := payloads[item.ID]
			if !ok {
				return nil, &StageError{Status: taskNotFound}
			}
			return &p, nil
		}
	}
	wrong := TrackItem{ID: "x", Title: "Another Song", Artist: "Someone Else"}
	for name, tc := range map[string]struct {
		cfg     TwoStageConfig
		items   []TrackItem
		fetch   func(context.Context, *TwoStageQuery, TrackItem) (*LyricsPayload, error)
		fetched []string
		outcome string
		lyr     string
		plain   bool
	}{
		"取前三条、第一份同步的胜出": {TwoStageConfig{}, []TrackItem{wrong, stageItem("1"), stageItem("2"), stageItem("3"), stageItem("4")},
			fetchByID(map[string]LyricsPayload{"1": plain, "2": lines, "3": {Lines: "[00:01.00]other\n[00:02.00]other\n[00:03.00]other\n"}, "4": lines}),
			[]string{"1", "2", "3"}, taskFound, twoStageLRC, false},
		"都只有纯文本取名次最前的": {TwoStageConfig{}, []TrackItem{stageItem("1"), stageItem("2")},
			fetchByID(map[string]LyricsPayload{"1": {Plain: "first"}, "2": {Plain: "second"}}), []string{"1", "2"}, taskFound, "first", true},
		"fetchTop 是 1 只取一条": {TwoStageConfig{FetchTop: 1}, []TrackItem{stageItem("1"), stageItem("2")},
			fetchByID(map[string]LyricsPayload{"1": plain, "2": lines}), []string{"1"}, taskFound, "plain text", true},
		"fetchTop 是 5": {TwoStageConfig{FetchTop: 5}, []TrackItem{stageItem("1"), stageItem("2"), stageItem("3"), stageItem("4"), stageItem("5"), stageItem("6")},
			fetchByID(map[string]LyricsPayload{"5": lines}), []string{"1", "2", "3", "4", "5"}, taskFound, twoStageLRC, false},
		"自带歌词的不再取": {TwoStageConfig{}, []TrackItem{stageItemWith("1", plain), stageItem("2")},
			fetchByID(map[string]LyricsPayload{"2": lines}), []string{"2"}, taskFound, twoStageLRC, false},
		"标了没有同步歌词的先放一边": {TwoStageConfig{FetchTop: 1}, []TrackItem{withFlag(stageItem("1"), &no), withFlag(stageItem("2"), &yes), stageItem("3")},
			fetchByID(map[string]LyricsPayload{"1": plain, "2": lines}), []string{"2"}, taskFound, twoStageLRC, false},
		"全都标了没有同步歌词才用它们": {TwoStageConfig{}, []TrackItem{withFlag(stageItem("1"), &no), withFlag(stageItem("2"), &no)},
			fetchByID(map[string]LyricsPayload{"1": plain}), []string{"1", "2"}, taskFound, "plain text", true},
		"没有第二段:不带歌词的丢掉": {TwoStageConfig{}, []TrackItem{stageItem("1"), stageItemWith("2", lines), stageItem("3")}, nil,
			nil, taskFound, twoStageLRC, false},
		"没有第二段:一条带歌词的都不剩": {TwoStageConfig{}, []TrackItem{stageItem("1"), stageItem("2")}, nil, nil, taskNotFound, "", false},
		"取词都答没有":          {TwoStageConfig{}, []TrackItem{stageItem("1"), stageItem("2")}, fetchByID(nil), []string{"1", "2"}, taskNotFound, "", false},
	} {
		b := &fakeStageBackend{search: stageSearchReturns(tc.items...), fetch: tc.fetch, upstream: answeredOK}
		tc.cfg.SelfRequery = true
		result, outcome := newStageProvider(b, tc.cfg).resolveTask(context.Background(), stageTestQuery, RoundEnv{})
		slices.Sort(b.fetchedIDs)
		if !slices.Equal(b.fetchedIDs, tc.fetched) || outcome.Status != tc.outcome || result.lyr != tc.lyr || result.plainOnly != tc.plain {
			t.Errorf("%s:取了 %v、结论 %s、正文 %q(纯文本 %v)\n期望取 %v、%s、%q(纯文本 %v)",
				name, b.fetchedIDs, outcome.Status, result.lyr, result.plainOnly, tc.fetched, tc.outcome, tc.lyr, tc.plain)
		}
	}
}

// 前几条的取词是并发发出去的:三份都发出之后才放行第一份。
func TestTwoStageFetchesConcurrently(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		release := make(chan struct{})
		started := 0
		var mu sync.Mutex
		b := &fakeStageBackend{search: stageSearchReturns(stageItem("1"), stageItem("2"), stageItem("3")), upstream: answeredOK}
		b.fetch = func(context.Context, *TwoStageQuery, TrackItem) (*LyricsPayload, error) {
			mu.Lock()
			started++
			mu.Unlock()
			<-release
			return &LyricsPayload{Lines: twoStageLRC}, nil
		}
		done := make(chan TaskOutcome, 1)
		go func() {
			_, outcome := newStageProvider(b, TwoStageConfig{SelfRequery: true}).resolveTask(context.Background(), stageTestQuery, RoundEnv{})
			done <- outcome
		}()
		synctest.Wait()
		mu.Lock()
		n := started
		mu.Unlock()
		if n != 3 {
			t.Errorf("放行之前该有 3 份取词在途,得到 %d", n)
		}
		close(release)
		if outcome := <-done; outcome.Status != taskFound {
			t.Errorf("结论 %+v", outcome)
		}
	})
}

// 结论的先后:超时和后端自己出错压过别的;搜索失败就是它的失败;有歌词就是找到了;纯音乐、正文用不了、取词的失败、
// 有歌没词;最后拿上游请求的结果纠正「没有」。
func TestConcludeTwoStageRound(t *testing.T) {
	lines, plain := &LyricsPayload{Lines: twoStageLRC, YRC: "yrc", Background: "bg"}, &LyricsPayload{Plain: "plain"}
	fetched := func(payloads ...any) []twoStageFetched {
		var out []twoStageFetched
		for i, p := range payloads {
			f := twoStageFetched{item: stageItem(fmt.Sprint(i + 1))}
			switch v := p.(type) {
			case *LyricsPayload:
				f.payload = v
			case *StageError:
				f.err = v
			}
			out = append(out, f)
		}
		return out
	}
	fail := func(status string, retry int) *StageError {
		return &StageError{Status: status, RetryAfterSecs: retry}
	}
	for name, tc := range map[string]struct {
		round    twoStageRoundResult
		upstream []UpstreamAnswer
		want     TaskOutcome
	}{
		"搜索失败:限流带等待":        {twoStageRoundResult{failure: fail(taskRateLimited, 30)}, answeredOK, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 30}},
		"搜索失败:要先配置":         {twoStageRoundResult{failure: fail(taskNeedsSetup, 0)}, nil, TaskOutcome{Status: taskNeedsSetup}},
		"搜索失败:跳过":           {twoStageRoundResult{failure: fail(taskSkipped, 0)}, nil, TaskOutcome{Status: taskSkipped}},
		"搜索是后端报的超时":         {twoStageRoundResult{failure: fail(taskTimeout, 0)}, answeredOK, TaskOutcome{Status: taskTimeout}},
		"一份取词出错压过另一份的歌词":    {twoStageRoundResult{gated: 2, fetched: fetched(lines, fail(taskPluginError, 0))}, answeredOK, TaskOutcome{Status: taskPluginError}},
		"一份取词超时压过另一份的歌词":    {twoStageRoundResult{gated: 2, fetched: fetched(lines, fail(taskTimeout, 0))}, answeredOK, TaskOutcome{Status: taskTimeout}},
		"超时压过出错":            {twoStageRoundResult{gated: 2, fetched: fetched(fail(taskPluginError, 0), fail(taskTimeout, 0))}, answeredOK, TaskOutcome{Status: taskTimeout}},
		"同步的压过名次靠前的纯文本":     {twoStageRoundResult{gated: 2, fetched: fetched(plain, lines)}, nil, TaskOutcome{Status: taskFound}},
		"有歌词时别的取词失败不算":      {twoStageRoundResult{gated: 2, fetched: fetched(fail(taskUnavailable, 0), plain)}, nil, TaskOutcome{Status: taskFound}},
		"有歌词时纯音乐标记不算":       {twoStageRoundResult{gated: 2, fetched: fetched(&LyricsPayload{Instrumental: true}, plain)}, nil, TaskOutcome{Status: taskFound}},
		"纯音乐":               {twoStageRoundResult{gated: 2, fetched: fetched(&LyricsPayload{}, &LyricsPayload{Instrumental: true})}, nil, TaskOutcome{Status: taskInstrumental}},
		"纯音乐压过取词的失败":        {twoStageRoundResult{gated: 2, fetched: fetched(fail(taskUnavailable, 0), &LyricsPayload{Instrumental: true})}, nil, TaskOutcome{Status: taskInstrumental}},
		"正文一行都用不了":          {twoStageRoundResult{gated: 1, fetched: fetched(&LyricsPayload{Unusable: true})}, answeredOK, TaskOutcome{Status: taskBadResponse}},
		"名次在前的用不了、后面的是纯音乐":  {twoStageRoundResult{gated: 2, fetched: fetched(&LyricsPayload{Unusable: true}, &LyricsPayload{Instrumental: true})}, answeredOK, TaskOutcome{Status: taskBadResponse}},
		"名次在前的是纯音乐、后面的用不了":  {twoStageRoundResult{gated: 2, fetched: fetched(&LyricsPayload{Instrumental: true}, &LyricsPayload{Unusable: true})}, answeredOK, TaskOutcome{Status: taskInstrumental}},
		"取词的失败:名次最前的那个":     {twoStageRoundResult{gated: 3, fetched: fetched(fail(taskNotFound, 0), fail(taskAuthFailed, 0), fail(taskRateLimited, 9))}, answeredOK, TaskOutcome{Status: taskAuthFailed}},
		"取词被限流带等待":          {twoStageRoundResult{gated: 1, fetched: fetched(fail(taskRateLimited, 9))}, answeredOK, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 9}},
		"取词的失败压过有歌没词":       {twoStageRoundResult{gated: 2, fetched: fetched(&LyricsPayload{NoLyrics: true}, fail(taskUnavailable, 0))}, answeredOK, TaskOutcome{Status: taskUnavailable}},
		"有歌没词、上游答过":         {twoStageRoundResult{gated: 2, fetched: fetched(&LyricsPayload{}, &LyricsPayload{NoLyrics: true})}, []UpstreamAnswer{{Status: 503}, {Status: 200}}, TaskOutcome{Status: taskNoLyrics}},
		"没有条目、上游答的是 404":    {twoStageRoundResult{}, []UpstreamAnswer{{Status: 404}}, TaskOutcome{Status: taskNotFound}},
		"没有条目、上游答的是 410":    {twoStageRoundResult{}, []UpstreamAnswer{{Status: 410}}, TaskOutcome{Status: taskNotFound}},
		"没有条目、上游答的是 302":    {twoStageRoundResult{}, []UpstreamAnswer{{Status: 302}}, TaskOutcome{Status: taskNotFound}},
		"没有条目、上游答的是 399":    {twoStageRoundResult{}, []UpstreamAnswer{{Status: 399}}, TaskOutcome{Status: taskNotFound}},
		"取词都答没有、上游答过":       {twoStageRoundResult{gated: 1, fetched: fetched(fail(taskNotFound, 0))}, answeredOK, TaskOutcome{Status: taskNotFound}},
		"没有条目、一个请求都没发":      {twoStageRoundResult{}, nil, TaskOutcome{Status: taskSkipped, Corrected: true}},
		"没有条目、只见过 429":      {twoStageRoundResult{}, []UpstreamAnswer{{}, {Status: 429, RetryAfterSecs: 30}, {Status: 429, RetryAfterSecs: 5}}, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 30, Corrected: true}},
		"有歌没词、只见过 429":      {twoStageRoundResult{gated: 1, fetched: fetched(&LyricsPayload{NoLyrics: true})}, []UpstreamAnswer{{Status: 429, RetryAfterSecs: 12}}, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 12, Corrected: true}},
		"没有条目、只有 5xx":       {twoStageRoundResult{}, []UpstreamAnswer{{Status: 503}, {Status: 500}}, TaskOutcome{Status: taskUnavailable, Corrected: true}},
		"没有条目、只有 400 和 403": {twoStageRoundResult{}, []UpstreamAnswer{{Status: 400}, {Status: 403}}, TaskOutcome{Status: taskUnavailable, Corrected: true}},
		"没有条目、请求都没拿到应答":     {twoStageRoundResult{}, []UpstreamAnswer{{}, {}}, TaskOutcome{Status: taskUnavailable, Corrected: true}},
		"没有条目、199 不算答了":     {twoStageRoundResult{}, []UpstreamAnswer{{Status: 199}}, TaskOutcome{Status: taskUnavailable, Corrected: true}},
		"有歌词时上游结果怎样都照收":     {twoStageRoundResult{gated: 1, fetched: fetched(lines)}, []UpstreamAnswer{{Status: 503}}, TaskOutcome{Status: taskFound}},
		"纯音乐时上游结果怎样都照收":     {twoStageRoundResult{gated: 1, fetched: fetched(&LyricsPayload{Instrumental: true})}, []UpstreamAnswer{{Status: 429}}, TaskOutcome{Status: taskInstrumental}},
		"后端抛的失败不纠正":         {twoStageRoundResult{failure: fail(taskUnavailable, 0)}, nil, TaskOutcome{Status: taskUnavailable}},
		"取词的失败不纠正":          {twoStageRoundResult{gated: 1, fetched: fetched(fail(taskBadResponse, 0))}, nil, TaskOutcome{Status: taskBadResponse}},
	} {
		result, got := concludeTwoStageRound(tc.round, tc.upstream)
		if got != tc.want {
			t.Errorf("%s:结论 %+v,期望 %+v", name, got, tc.want)
		}
		carries := result.lyr != "" || result.instrumental || result.trackFoundNoLyrics
		if want := got.Status == taskFound || got.Status == taskInstrumental || got.Status == taskNoLyrics; carries != want {
			t.Errorf("%s:结论 %s 时结果带没带东西 = %v", name, got.Status, carries)
		}
	}
}

// 挑中的那一条和它的歌词怎么摊成 SourceResult。
func TestTwoStageSourceResult(t *testing.T) {
	item := TrackItem{ID: "9", Title: "Paper Lanterns", Artist: "Lyrimuse Test Band", Album: "Fixtures", DurationSecs: 215, ISRC: "QZTEST2600001", Language: songLanguageMandarin}
	full := &LyricsPayload{
		Lines: twoStageLRC, YRC: "[1000,4000](1000,800,0)Paper", Plain: "ignored when synced", Translation: "[00:01.00]雨中的纸灯笼", TranslationLang: "zh-Hans",
		Romanization: "[00:01.00]peipa", Background: "[1000,4000](3000,1500,0)(ooh)", Songwriters: []string{"A. Writer"}, PageURL: "https://lyrics.example/song/9",
	}
	want := SourceResult{
		lyr: twoStageLRC, yrc: full.YRC, bg: full.Background, tr: full.Translation, trLang: "zh-Hans", roma: full.Romanization,
		matchTitle: "Paper Lanterns", matchArtist: "Lyrimuse Test Band", matchAlbum: "Fixtures", srcDur: 215, isrc: "QZTEST2600001", language: songLanguageMandarin,
		songwriters: []string{"A. Writer"}, sourceURL: "https://lyrics.example/song/9",
	}
	if got := twoStageSourceResult(item, full); !reflect.DeepEqual(got, want) {
		t.Errorf("带同步歌词的结果\n%+v\n期望\n%+v", got, want)
	}
	plainOnly := twoStageSourceResult(item, &LyricsPayload{Plain: "just text", YRC: "stray", Background: "stray"})
	if plainOnly.lyr != "just text" || !plainOnly.plainOnly || plainOnly.yrc != "" || plainOnly.bg != "" {
		t.Errorf("只有纯文本时正文是纯文本、标 plainOnly、不带逐字和背景人声轨:%+v", plainOnly)
	}
	for name, payload := range map[string]*LyricsPayload{"纯音乐": {Instrumental: true}, "有歌没词": {NoLyrics: true}} {
		result, _ := concludeTwoStageRound(twoStageRoundResult{gated: 1, fetched: []twoStageFetched{{item: item, payload: payload}}}, answeredOK)
		want := SourceResult{instrumental: payload.Instrumental, trackFoundNoLyrics: payload.NoLyrics, matchTitle: item.Title, matchArtist: item.Artist, matchAlbum: item.Album, srcDur: 215}
		if !reflect.DeepEqual(result, want) {
			t.Errorf("%s 的结果\n%+v\n期望\n%+v", name, result, want)
		}
	}
}

// 前台被限流、对方只让等一下:等满(外加抖动,这里钉成两成)把同一次搜索原样再发一遍,只重发一次;冷却记在这个来源上。
func TestTwoStageWaitsOutShortRateLimitOnce(t *testing.T) {
	for name, tc := range map[string]struct {
		ctx      func() context.Context
		retry    []int // 各次搜索抛的 retryAfter,-1 = 这一次答了
		deadline time.Duration
		searches int
		outcome  TaskOutcome
		waited   time.Duration // 至少等了多久
	}{
		"等得到就重发":      {context.Background, []int{1, -1}, 0, 2, TaskOutcome{Status: taskFound}, time.Second},
		"重发还被限流就不再发":  {context.Background, []int{1, 1, -1}, 0, 2, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 1}, time.Second},
		"刚好两秒也等":      {context.Background, []int{2, -1}, 0, 2, TaskOutcome{Status: taskFound}, 2 * time.Second},
		"超过两秒不等":      {context.Background, []int{3, -1}, 0, 1, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 3}, 0},
		"没说等多久不等":     {context.Background, []int{0, -1}, 0, 1, TaskOutcome{Status: taskRateLimited}, 0},
		"后台不等":        {func() context.Context { return withBackgroundOutbound(context.Background()) }, []int{1, -1}, 0, 1, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 1}, 0},
		"等完就过了截止的不等":  {context.Background, []int{2, -1}, 2 * time.Second, 1, TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 2}, 0},
		"待播队列算前台,照样等": {func() context.Context { return withPlayerQueueTrack(context.Background()) }, []int{1, -1}, 0, 2, TaskOutcome{Status: taskFound}, time.Second},
	} {
		synctest.Test(t, func(t *testing.T) {
			saved := lrclibRetryJitter
			lrclibRetryJitter = func() float64 { return 0.2 }
			defer func() { lrclibRetryJitter = saved }()
			b := &fakeStageBackend{upstream: answeredOK}
			n := 0
			b.search = func(context.Context, *TwoStageQuery) ([]TrackItem, error) {
				retry := tc.retry[n]
				n++
				if retry >= 0 {
					return nil, &StageError{Status: taskRateLimited, RetryAfterSecs: retry}
				}
				return []TrackItem{stageItemWith("1", LyricsPayload{Lines: twoStageLRC})}, nil
			}
			start := time.Now()
			_, outcome := newStageProvider(b, TwoStageConfig{Deadline: tc.deadline}).resolveTask(tc.ctx(), stageTestQuery, RoundEnv{})
			waited := time.Since(start)
			if outcome != tc.outcome || len(b.queries) != tc.searches {
				t.Errorf("%s:结论 %+v、搜了 %d 次,期望 %+v、%d 次", name, outcome, len(b.queries), tc.outcome, tc.searches)
			}
			if waited != tc.waited+tc.waited/5 {
				t.Errorf("%s:等了 %s,期望 %s 加两成抖动", name, waited, tc.waited)
			}
			wantNotes := make([]time.Duration, 0, len(tc.retry))
			for _, r := range tc.retry[:len(b.queries)] {
				if r >= 0 {
					wantNotes = append(wantNotes, time.Duration(r)*time.Second)
				}
			}
			if !slices.Equal(b.rateLimited, wantNotes) {
				t.Errorf("%s:让后端冷却 %v,期望 %v", name, b.rateLimited, wantNotes)
			}
			if tc.searches == 2 && (b.queries[0].Attempt != b.queries[1].Attempt || b.queries[0].SearchArtist != b.queries[1].SearchArtist) {
				t.Errorf("%s:重发的该是同一次(写法和序号不变),得到 %+v 和 %+v", name, b.queries[0].Attempt, b.queries[1].Attempt)
			}
		})
	}
}

// 纠正出来的限流(后端交空、上游只见过 429)同样让来源冷却、同样只在等得到时重发。
func TestTwoStageCorrectedRateLimitCoolsTheSource(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		b := &fakeStageBackend{search: stageSearchReturns(), upstream: []UpstreamAnswer{{Status: 429, RetryAfterSecs: 12}}}
		_, outcome := newStageProvider(b, TwoStageConfig{SelfRequery: true}).resolveTask(context.Background(), stageTestQuery, RoundEnv{})
		if want := (TaskOutcome{Status: taskRateLimited, RetryAfterSecs: 12, Corrected: true}); outcome != want || len(b.queries) != 1 || !slices.Equal(b.rateLimited, []time.Duration{12 * time.Second}) {
			t.Errorf("结论 %+v、搜了 %d 次、冷却 %v", outcome, len(b.queries), b.rateLimited)
		}
	})
}

// 任务的截止和取消:到了截止按超时记,被取消按取消记,之后后端交回什么都不看;截止从排队起算。
func TestTwoStageDeadlineAndCancel(t *testing.T) {
	blocked := func(ctx context.Context, _ *TwoStageQuery) ([]TrackItem, error) {
		<-ctx.Done()
		return []TrackItem{stageItemWith("1", LyricsPayload{Lines: twoStageLRC})}, nil
	}
	synctest.Test(t, func(t *testing.T) {
		b := &fakeStageBackend{search: blocked, upstream: answeredOK}
		start := time.Now()
		result, outcome := newStageProvider(b, TwoStageConfig{}).resolveTask(context.Background(), stageTestQuery, RoundEnv{})
		if outcome.Status != taskTimeout || time.Since(start) != lyricSearchDeadline || result.lyr != "" || b.ended != 1 {
			t.Errorf("默认截止:结论 %+v、过了 %s、正文 %q", outcome, time.Since(start), result.lyr)
		}
	})
	synctest.Test(t, func(t *testing.T) {
		b := &fakeStageBackend{search: blocked, upstream: answeredOK}
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan TaskOutcome, 1)
		go func() {
			_, outcome := newStageProvider(b, TwoStageConfig{Deadline: time.Minute}).resolveTask(ctx, stageTestQuery, RoundEnv{})
			done <- outcome
		}()
		synctest.Wait()
		cancel()
		if outcome := <-done; outcome.Status != taskCancelled || b.ended != 1 {
			t.Errorf("取消:结论 %+v", outcome)
		}
	})
	synctest.Test(t, func(t *testing.T) {
		b := &fakeStageBackend{search: blocked, upstream: answeredOK}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		start := time.Now()
		_, outcome := newStageProvider(b, TwoStageConfig{}).resolveTask(ctx, stageTestQuery, RoundEnv{})
		if outcome.Status != taskTimeout || time.Since(start) != 3*time.Second {
			t.Errorf("调用方的截止更早:结论 %+v、过了 %s", outcome, time.Since(start))
		}
	})
	b := &fakeStageBackend{beginErr: errors.New("host is gone")}
	if _, outcome := newStageProvider(b, TwoStageConfig{}).resolveTask(context.Background(), stageTestQuery, RoundEnv{}); outcome.Status != taskPluginError {
		t.Errorf("任务开不起来按后端出错记,得到 %+v", outcome)
	}
	b = &fakeStageBackend{beginErr: &StageError{Status: taskNeedsSetup}}
	if _, outcome := newStageProvider(b, TwoStageConfig{}).resolveTask(context.Background(), stageTestQuery, RoundEnv{}); outcome.Status != taskNeedsSetup {
		t.Errorf("任务开不起来时后端给了结论的照它记,得到 %+v", outcome)
	}
}

// 一个来源同时最多两个任务,其中一个只给前台:后台的第二个要等,前台的照样进得来;排到时过了截止的不调后端。
func TestTwoStageTaskSlots(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		release := make(chan struct{})
		b := &fakeStageBackend{upstream: answeredOK}
		b.search = func(ctx context.Context, _ *TwoStageQuery) ([]TrackItem, error) {
			select {
			case <-release:
			case <-ctx.Done():
			}
			return nil, nil
		}
		p := newStageProvider(b, TwoStageConfig{SelfRequery: true, Deadline: 10 * time.Second})
		outcomes := make(chan string, 16)
		run := func(name string, ctx context.Context) {
			go func() {
				_, outcome := p.resolveTask(ctx, stageTestQuery, RoundEnv{})
				outcomes <- name + " " + outcome.Status
			}()
			synctest.Wait()
		}
		begun := func() int {
			b.mu.Lock()
			defer b.mu.Unlock()
			return b.begun
		}
		background := withBackgroundOutbound(context.Background())
		run("后台一", background)
		run("后台二", background)
		if begun() != 1 {
			t.Fatalf("后台只能用一个名额:第二个后台任务该在排队,已经开了 %d 个", begun())
		}
		run("前台一", context.Background())
		if begun() != 2 {
			t.Fatalf("留给前台的名额该让前台任务马上进来,已经开了 %d 个", begun())
		}
		run("前台二", context.Background())
		if begun() != 2 {
			t.Fatalf("两个名额都占着时第三个任务该排队,已经开了 %d 个", begun())
		}
		// 再排上十个:名额在截止那一刻才空出来,排队的不管有几个都不该再调后端。
		for i := range 10 {
			run(fmt.Sprintf("排队%d", i), context.Background())
		}
		time.Sleep(10 * time.Second)
		synctest.Wait()
		timedOut := 0
		for range 14 {
			if strings.HasSuffix(<-outcomes, " "+taskTimeout) {
				timedOut++
			}
		}
		// 这些任务的截止都是开始排队之后 10 秒:占着名额的两个到点超时,排队的到点时还没排到,同样按超时记、不调后端。
		if timedOut != 14 || begun() != 2 {
			t.Errorf("%d 个任务按超时记、开过 %d 个任务,期望 14 个、2 个", timedOut, begun())
		}
		close(release)
	})
	// 名额还回来之后排队的接着跑;前台任务在留给前台的名额被占时用共用的那一个。
	synctest.Test(t, func(t *testing.T) {
		gate := make(chan struct{})
		b := &fakeStageBackend{upstream: answeredOK}
		b.search = func(context.Context, *TwoStageQuery) ([]TrackItem, error) { <-gate; return nil, nil }
		p := newStageProvider(b, TwoStageConfig{SelfRequery: true})
		done := make(chan struct{}, 3)
		for range 3 {
			go func() {
				p.Resolve(context.Background(), stageTestQuery, RoundEnv{})
				done <- struct{}{}
			}()
		}
		synctest.Wait()
		if b.begun != 2 {
			t.Fatalf("三个前台任务:两个占住名额、一个排队,已经开了 %d 个", b.begun)
		}
		gate <- struct{}{}
		<-done
		synctest.Wait()
		if b.begun != 3 {
			t.Errorf("名额还回来之后排队的该接着跑,开了 %d 个", b.begun)
		}
		close(gate)
		<-done
		<-done
	})
}

// 失败诊断的两个可选接口、被限流那一轮记成跳过、探测曲。
func TestTwoStageFailureReporting(t *testing.T) {
	for status, want := range map[string][2]string{
		taskAuthFailed:  {twoStageFailureAuthFailed, twoStageFailureAuthFailed},
		taskNeedsSetup:  {twoStageFailureNeedsSetup, twoStageFailureNeedsSetup},
		taskRateLimited: {twoStageFailureRateLimited, ""},
		taskBadResponse: {"", twoStageFailureError},
		taskPluginError: {"", twoStageFailureError},
		taskUnavailable: {"", ""},
		taskSkipped:     {"", ""},
		taskTimeout:     {"", ""},
	} {
		b := &fakeStageBackend{search: func(context.Context, *TwoStageQuery) ([]TrackItem, error) {
			return nil, &StageError{Status: status, RetryAfterSecs: 30}
		}}
		p := newStageProvider(b, TwoStageConfig{})
		ctx, round := withLyricSourceRound(context.Background())
		p.Resolve(ctx, stageTestQuery, RoundEnv{})
		if got := [2]string{p.QueryIndependentFailure(), p.DiagnosedFailure()}; got != want {
			t.Errorf("%s:补查轮看到 %q、界面显示 %q,期望 %q、%q", status, got[0], got[1], want[0], want[1])
		}
		if skipped := slices.Contains(round.skippedSources(), "plugin:test.stage"); skipped != (status == taskRateLimited) {
			t.Errorf("%s:这一轮记没记成跳过 = %v", status, skipped)
		}
	}
	// 下一个任务问成了,上一次的失败不再报。
	fail := true
	b := &fakeStageBackend{upstream: answeredOK}
	b.search = func(context.Context, *TwoStageQuery) ([]TrackItem, error) {
		if fail {
			return nil, &StageError{Status: taskAuthFailed}
		}
		return []TrackItem{stageItemWith("1", LyricsPayload{Lines: twoStageLRC})}, nil
	}
	p := newTwoStageProvider(&ProviderDescriptor{Name: "plugin:test.stage"}, b, TwoStageConfig{SelfRequery: true, Probe: &twoStageTrack{Title: "Probe Song", Artist: "Probe Artist", Album: "Probe Album", DurationSecs: 99}})
	if p.ProbeOwnTrack(context.Background()) || p.DiagnosedFailure() == "" {
		t.Error("鉴权被拒时探测该失败,并留下失败原因")
	}
	fail = false
	b.queries = nil
	if p.Resolve(context.Background(), stageTestQuery, RoundEnv{}).lyr == "" || p.DiagnosedFailure() != "" || p.QueryIndependentFailure() != "" {
		t.Error("问成之后不该再报上一次的失败")
	}
	b.search = stageSearchReturns(TrackItem{ID: "1", Title: "Probe Song", Artist: "Probe Artist", Album: "Probe Album", DurationSecs: 99, Lyrics: &LyricsPayload{Lines: twoStageLRC}})
	if !p.ProbeOwnTrack(context.Background()) {
		t.Error("探测曲问出了歌词,探测该成功")
	}
	if q := b.queries[len(b.queries)-1]; q.Title != "Probe Song" || q.Artist != "Probe Artist" || q.Album != "Probe Album" || q.DurationSecs != 99 {
		t.Errorf("探测用的该是配置里的探测曲,得到 %+v", q)
	}
	if newStageProvider(b, TwoStageConfig{}).ProbeOwnTrack(context.Background()) {
		t.Error("没配探测曲时探测返回 false")
	}
	if p.Descriptor().Name != "plugin:test.stage" {
		t.Error("Descriptor 交的是构造时给的描述符")
	}
}
