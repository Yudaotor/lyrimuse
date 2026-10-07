package main

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

var (
	earlyTermWord  = scoreTerm{Kind: scoreTermWordTiming, Points: 400}
	earlyTermTitle = scoreTerm{Kind: scoreTermTitleMatch, Points: 120}
	earlyTermDur   = scoreTerm{Kind: scoreTermDuration, Points: 280}
	earlyTermLines = scoreTerm{Kind: scoreTermLines, Points: 40}
)

// earlyCand 拼一份带分项的候选,总分按分项加起来、跟打分一样夹到 1。
func earlyCand(source string, terms ...scoreTerm) scoredLyricCandidateResult {
	score := 0
	for _, t := range terms {
		score += t.Points
	}
	return scoredLyricCandidateResult{Source: source, Score: max(score, 1), ScoreTerms: terms, Lyrics: "[00:01.00]" + source}
}

// 保存并在收尾还原先上屏会读的包级状态:功能开关、当前播放器的同源、正在播的 key、宽限时长。
func isolateEarlyLyricsState(t *testing.T) {
	t.Helper()
	savedFeatures := features()
	nativeLyricSourcesMu.Lock()
	savedNative := nativeLyricSources
	nativeLyricSources = nil
	nativeLyricSourcesMu.Unlock()
	savedPlaying := enrichPlayingKey.Load()
	savedGrace := earlyLyricsGrace
	t.Cleanup(func() {
		setFeatures(savedFeatures)
		nativeLyricSourcesMu.Lock()
		nativeLyricSources = savedNative
		nativeLyricSourcesMu.Unlock()
		enrichPlayingKey.Store(savedPlaying)
		earlyLyricsGrace = savedGrace
	})
	featuresRef().LyricsSourceMode = lyricsModeSmart
	featuresRef().LyricsSources = nil
}

// 打分项不是加分就是扣分;扣分的那些先上屏时一律当作「可能不是这一版」。新加打分项时要在这里归一边。
func TestEarlyLyricsPenaltyTermsCoverEveryDeduction(t *testing.T) {
	bonuses := map[string]bool{
		scoreTermDuration: true, scoreTermCorroborated: true, scoreTermWordTiming: true, scoreTermNativeSource: true,
		scoreTermLines: true, scoreTermAlbum: true, scoreTermTitleMatch: true, scoreTermConsensus: true,
		scoreTermTranslation: true, scoreTermRoma: true,
	}
	kinds := lyricScoreTermKinds()
	for _, kind := range kinds {
		if bonuses[kind] == earlyLyricsPenaltyTerms[kind] {
			t.Errorf("打分项 %q 要么是加分项、要么在 earlyLyricsPenaltyTerms 里,只能占一边", kind)
		}
	}
	for kind := range earlyLyricsPenaltyTerms {
		if !slices.Contains(kinds, kind) {
			t.Errorf("earlyLyricsPenaltyTerms 里的 %q 不是打分项", kind)
		}
	}
	if titleMatchFullPoints <= 0 {
		t.Fatalf("titleMatch 满档的分值没取到: %d", titleMatchFullPoints)
	}
}

func TestEarlyLyricsTrustedAndAcceptable(t *testing.T) {
	cases := []struct {
		name                        string
		c                           scoredLyricCandidateResult
		wantTrusted, wantAcceptable bool
	}{
		{"逐字、歌名满档、时长对得上", earlyCand("kugou", earlyTermWord, earlyTermTitle, earlyTermDur, earlyTermLines), true, true},
		{"曲长未知,打分里没有时长项", earlyCand("kugou", earlyTermWord, earlyTermTitle, earlyTermLines), false, true},
		{"没有逐字", earlyCand("netease", earlyTermTitle, earlyTermDur, earlyTermLines), false, true},
		{"歌名只差括号里的版本词", earlyCand("qq", earlyTermWord, scoreTerm{Kind: scoreTermTitleMatch, Points: 60}, earlyTermDur), false, true},
		{"歌名一个字都对不上", earlyCand("qq", earlyTermWord, earlyTermDur, earlyTermLines), false, false},
		{"版本词对不上", earlyCand("kugou", earlyTermWord, earlyTermTitle, earlyTermDur, scoreTerm{Kind: scoreTermVersionTags, Points: -600}), false, false},
		{"另一场演出", earlyCand("kugou", earlyTermWord, earlyTermTitle, earlyTermDur, scoreTerm{Kind: scoreTermLiveAlbumConflict, Points: -600}), false, false},
		{"时间轴整体平移", earlyCand("kugou", earlyTermWord, earlyTermTitle, earlyTermDur, scoreTerm{Kind: scoreTermTimelineOffset, Points: -600}), false, false},
		{"源自报的曲长对不上", earlyCand("qq", earlyTermWord, earlyTermTitle, earlyTermDur, scoreTerm{Kind: scoreTermSourceDurationOff, Points: -500}), false, false},
		{"时长对不上、别家印证了结尾", earlyCand("lrclib", earlyTermTitle, scoreTerm{Kind: scoreTermCorroborated, Points: 100}), false, true},
		{"判废", scoredLyricCandidateResult{Source: "qq", Score: -1, ScoreTerms: []scoreTerm{{Kind: scoreRejectNotTimed}}}, false, false},
	}
	for _, c := range cases {
		c := c
		if got := earlyLyricsTrusted(&c.c); got != c.wantTrusted {
			t.Errorf("%s: trusted=%v, want %v", c.name, got, c.wantTrusted)
		}
		if got := earlyLyricsAcceptable(&c.c); got != c.wantAcceptable {
			t.Errorf("%s: acceptable=%v, want %v", c.name, got, c.wantAcceptable)
		}
	}
	if earlyLyricsTrusted(nil) || earlyLyricsAcceptable(nil) {
		t.Error("没有候选时两条都不该放行")
	}
}

func TestEarlyLyricsVerdict(t *testing.T) {
	isolateEarlyLyricsState(t)
	trusted := earlyCand("kugou", earlyTermWord, earlyTermTitle, earlyTermDur, earlyTermLines)
	lineOnly := earlyCand("netease", earlyTermTitle, earlyTermDur, earlyTermLines)
	penalized := earlyCand("kugou", earlyTermWord, earlyTermTitle, earlyTermDur, scoreTerm{Kind: scoreTermVersionTags, Points: -600})
	answered := func(sources ...string) func(string) bool {
		return func(s string) bool { return slices.Contains(sources, s) }
	}
	verdict := func(c scoredLyricCandidateResult, ans func(string) bool, graceOver bool) earlyLyricsRule {
		return earlyLyricsVerdict([]scoredLyricCandidateResult{c}, &c, ans, graceOver)
	}

	if got := earlyLyricsVerdict(nil, nil, answered(), true); got != earlyLyricsWait {
		t.Errorf("没有可用候选: %q", got)
	}
	if got := verdict(trusted, answered("kugou"), false); got != earlyLyricsTrust {
		t.Errorf("靠得住的立刻上: %q", got)
	}
	if got := verdict(lineOnly, answered("netease"), false); got != earlyLyricsWait {
		t.Errorf("不够靠得住、还没等满: %q", got)
	}
	if got := verdict(lineOnly, answered("netease"), true); got != earlyLyricsGraced {
		t.Errorf("等满了、没有扣分项: %q", got)
	}
	if got := verdict(penalized, answered("kugou"), true); got != earlyLyricsWait {
		t.Errorf("带扣分项的等满了也不上: %q", got)
	}

	// 用 QQ 音乐放歌:QQ 没回话前「靠得住」那条不算,只走宽限那条。
	setNativeLyricSourcesForPlayer(qqMusicBundleID)
	if !isNativeLyricSource("qq") {
		t.Fatal("QQ 音乐的自家歌词源应是 qq")
	}
	if got := verdict(trusted, answered("kugou"), false); got != earlyLyricsWait {
		t.Errorf("自家源还没回话: %q", got)
	}
	if got := verdict(trusted, answered("kugou"), true); got != earlyLyricsGraced {
		t.Errorf("自家源没回话、等满了: %q", got)
	}
	if got := verdict(trusted, answered("kugou", "qq"), false); got != earlyLyricsTrust {
		t.Errorf("自家源回话了: %q", got)
	}
	featuresRef().LyricsSources = map[string]bool{"kugou": true, "netease": true}
	if got := verdict(trusted, answered("kugou"), false); got != earlyLyricsTrust {
		t.Errorf("自家源在设置里关掉了,不用等它: %q", got)
	}
	featuresRef().LyricsSources = nil
	setNativeLyricSourcesForPlayer("")

	// 顺序优先:只看排在前面的源回话了没有,不看分数,也不看宽限。
	featuresRef().LyricsSourceMode = lyricsModePriority
	featuresRef().LyricsSourceOrder = []string{"kugou", "netease", "qq"}
	if got := verdict(lineOnly, answered("netease"), true); got != earlyLyricsWait {
		t.Errorf("排在前面的酷狗还没回话: %q", got)
	}
	if got := verdict(lineOnly, answered("netease", "kugou"), false); got != earlyLyricsInOrder {
		t.Errorf("排在前面的都回话了: %q", got)
	}
	wrongLanguage := scoredLyricCandidateResult{Source: "kugou", Score: -1, ScoreTerms: []scoreTerm{{Kind: scoreRejectWrongLanguage}}}
	if got := earlyLyricsVerdict([]scoredLyricCandidateResult{lineOnly, wrongLanguage}, &lineOnly, answered("netease", "kugou"), true); got != earlyLyricsWait {
		t.Errorf("排在前面的那份因语言判废,后到的源可能解除它: %q", got)
	}
	featuresRef().LyricsSources = map[string]bool{"netease": true, "qq": true}
	if got := verdict(lineOnly, answered("netease"), false); got != earlyLyricsInOrder {
		t.Errorf("排在前面的酷狗关掉了,不用等它: %q", got)
	}
	local := earlyCand(kkboxLocalLyricsSource, earlyTermTitle, earlyTermDur, earlyTermLines)
	if got := verdict(local, answered("netease"), true); got != earlyLyricsWait {
		t.Errorf("本地歌词不在顺序里,要顺序里开着的源全部回话: %q", got)
	}
	if got := verdict(local, answered("netease", "qq"), false); got != earlyLyricsInOrder {
		t.Errorf("顺序里开着的源都回话了: %q", got)
	}
}

func TestEarlyLyricsWatch(t *testing.T) {
	isolateEarlyLyricsState(t)
	earlyLyricsGrace = 20 * time.Millisecond
	noteEnrichPlayingKey("A|T|Al")
	var calls []string
	record := func(_ neteaseInfo, r []scoredLyricCandidateResult) {
		calls = append(calls, pickLyricCandidate(r).Source)
	}
	target := withEarlyLyricsTarget(context.Background(), "A|T|Al")

	if newEarlyLyricsWatch(withProvisionalLyrics(withEarlyLyricsTarget(context.Background(), "B|T|Al"), record), "B", "T") != nil {
		t.Error("不是正在播的这首,不该提前上屏")
	}
	if newEarlyLyricsWatch(target, "A", "T") != nil {
		t.Error("没挂首轮先上屏的回调(不是首次解析),不该提前上屏")
	}
	if newEarlyLyricsWatch(withLyricQueryReason(withProvisionalLyrics(target, record), lyricQueryReasonAliasMissing), "A", "T") != nil {
		t.Error("不是第一轮,不该提前上屏")
	}
	var none *earlyLyricsWatch
	none.observe(neteaseInfo{}, nil, nil)
	none.endGrace()
	none.finish(0, 0)
	if none.active() || none.graceC() != nil {
		t.Error("nil 的各个方法应是空操作")
	}

	// 逐行那份不够靠得住:第一份能用的到了就起计时,等满之后才上;首轮收齐还是它就不再提交。
	ctx := withProvisionalLyrics(target, record)
	w := newEarlyLyricsWatch(ctx, "A", "T")
	if w == nil {
		t.Fatal("正在播的这首、首次解析、第一轮,应该起作用")
	}
	lineOnly := []scoredLyricCandidateResult{earlyCand("netease", earlyTermTitle, earlyTermDur, earlyTermLines)}
	if w.graceC() != nil {
		t.Fatal("还没有能用的候选,不该起计时")
	}
	w.observe(neteaseInfo{}, lineOnly, map[string]bool{"netease": true})
	if len(calls) != 0 {
		t.Fatalf("没等满就上了: %v", calls)
	}
	ch := w.graceC()
	if ch == nil {
		t.Fatal("第一份能用的到了就该起计时")
	}
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("宽限计时没到点")
	}
	w.endGrace()
	w.observe(neteaseInfo{}, lineOnly, map[string]bool{"netease": true})
	if !slices.Equal(calls, []string{"netease"}) {
		t.Fatalf("等满后该上一次: %v", calls)
	}
	if w.active() || w.graceC() != nil {
		t.Fatal("上过之后不再等")
	}
	w.observe(neteaseInfo{}, lineOnly, map[string]bool{"netease": true})
	notifyProvisionalLyrics(ctx, neteaseInfo{}, lineOnly)
	notifyProvisionalLyrics(ctx, neteaseInfo{}, lineOnly)
	if len(calls) != 1 {
		t.Fatalf("收齐后还是同一份,不该再提交: %v", calls)
	}
	w.finish(12, 12)

	// 靠得住的立刻上;收齐后换了一份就再提交一次,之后不再提交。
	calls = nil
	ctx = withProvisionalLyrics(target, record)
	w = newEarlyLyricsWatch(ctx, "A", "T")
	kugou := earlyCand("kugou", earlyTermWord, earlyTermTitle, earlyTermDur, earlyTermLines)
	w.observe(neteaseInfo{}, []scoredLyricCandidateResult{kugou}, map[string]bool{"kugou": true})
	if !slices.Equal(calls, []string{"kugou"}) {
		t.Fatalf("靠得住的该立刻上: %v", calls)
	}
	qq := earlyCand("qq", earlyTermWord, earlyTermTitle, earlyTermDur, earlyTermLines, scoreTerm{Kind: scoreTermConsensus, Points: 250})
	full := []scoredLyricCandidateResult{qq, kugou}
	notifyProvisionalLyrics(ctx, neteaseInfo{}, full)
	notifyProvisionalLyrics(ctx, neteaseInfo{}, full)
	if !slices.Equal(calls, []string{"kugou", "qq"}) {
		t.Fatalf("收齐后换了一份,该再提交且只提交一次: %v", calls)
	}

	// 收齐后挑出来的是别的源、内容跟先上屏的一样(只差元信息标签):不再提交。
	calls = nil
	ctx = withProvisionalLyrics(target, record)
	w = newEarlyLyricsWatch(ctx, "A", "T")
	w.observe(neteaseInfo{}, []scoredLyricCandidateResult{kugou}, map[string]bool{"kugou": true})
	qqSame := qq
	qqSame.Lyrics = "[offset:0]\n" + kugou.Lyrics
	notifyProvisionalLyrics(ctx, neteaseInfo{}, []scoredLyricCandidateResult{qqSame, kugou})
	if !slices.Equal(calls, []string{"kugou"}) {
		t.Fatalf("换了个源但内容一样,不该再提交: %v", calls)
	}

	// 已经回调过(首轮收齐时那一次)之后,中途先上屏不再起作用:同一个 ctx 上合计至多两次。
	calls = nil
	ctx = withProvisionalLyrics(target, record)
	notifyProvisionalLyrics(ctx, neteaseInfo{}, []scoredLyricCandidateResult{kugou})
	h, _ := ctx.Value(provisionalLyricsKey{}).(*provisionalLyricsHook)
	if h.showEarly(ctx, neteaseInfo{}, []scoredLyricCandidateResult{qq}, &qq) || !slices.Equal(calls, []string{"kugou"}) {
		t.Fatalf("回调过之后不该再先上屏: %v", calls)
	}

	// 切到了别的歌、或者取消了:这一首不再提前上屏。
	calls = nil
	w = newEarlyLyricsWatch(withProvisionalLyrics(target, record), "A", "T")
	noteEnrichPlayingKey("B|T2|Al")
	w.observe(neteaseInfo{}, []scoredLyricCandidateResult{kugou}, map[string]bool{"kugou": true})
	if len(calls) != 0 || w.active() {
		t.Fatalf("切走了还在提前上屏: %v", calls)
	}
	noteEnrichPlayingKey("A|T|Al")
	cancelled, cancel := context.WithCancel(withProvisionalLyrics(target, record))
	w = newEarlyLyricsWatch(cancelled, "A", "T")
	cancel()
	w.observe(neteaseInfo{}, []scoredLyricCandidateResult{kugou}, map[string]bool{"kugou": true})
	if len(calls) != 0 || w.active() {
		t.Fatalf("取消了还在提前上屏: %v", calls)
	}
}

// 金标集回放:按常见到达顺序陆续到齐、以及只到一个源时,先上屏放行的那份,在全部到齐后不能是被判废或带扣分项的
// (别的版本、别的录音、时长对不上)。例外只有时间轴整体平移、间奏插入两项:都要等时长对得上的那几家到齐才判得出来,
// 首轮中途判不了(见 09 章决策 193)。例外必须真的出现,出现不了就该删掉。
func TestEarlyLyricsGoldenNeverShowsAPenalizedCandidate(t *testing.T) {
	arrival := []string{"netease", "kugou", "migu", "kuwo", "applemusic", "lrclib", "soda", "musixmatch", "lyricfind", "deezer", "qq", "amll"}
	batchOnly := map[string]bool{scoreTermTimelineOffset: true, scoreTermTimelineIntrusion: true}
	seen := map[string]bool{}
	for _, fx := range loadGoldenFixtures(t) {
		fx := fx
		t.Run(fx.ID, func(t *testing.T) {
			applyGoldenSettings(t, fx)
			raw := goldenRawRound(fx)
			q := fx.Query
			full := rankLyricSourceResults(q.Artist, q.Title, q.Album, q.DurationSecs, raw)
			var subsets [][]string
			var prefix []string
			for _, s := range arrival {
				if _, ok := raw[s]; ok {
					prefix = append(prefix, s)
					subsets = append(subsets, slices.Clone(prefix))
				}
			}
			for s := range raw {
				subsets = append(subsets, []string{s})
			}
			for _, sub := range subsets {
				part := map[string]lyricSourceResult{}
				for _, s := range sub {
					part[s] = raw[s]
				}
				scored := rankLyricSourceResults(q.Artist, q.Title, q.Album, q.DurationSecs, part)
				picked := pickLyricCandidate(scored)
				for _, graceOver := range []bool{false, true} {
					if earlyLyricsVerdict(scored, picked, func(s string) bool { return slices.Contains(sub, s) }, graceOver) == earlyLyricsWait {
						continue
					}
					i := slices.IndexFunc(full, func(c scoredLyricCandidateResult) bool { return c.Source == picked.Source && c.Lyrics != "" })
					if i < 0 || full[i].Score < 0 {
						t.Errorf("到了 %v 时先上屏 %s,全部到齐后它被判废", sub, picked.Source)
						continue
					}
					for _, term := range full[i].ScoreTerms {
						if !earlyLyricsPenaltyTerms[term.Kind] {
							continue
						}
						if batchOnly[term.Kind] {
							seen[term.Kind] = true
							continue
						}
						t.Errorf("到了 %v 时先上屏 %s(宽限已满=%v),全部到齐后它带着扣分项 %s %d", sub, picked.Source, graceOver, term.Kind, term.Points)
					}
				}
			}
		})
	}
	for kind := range batchOnly {
		if !seen[kind] {
			t.Errorf("例外 %s 没有出现:先上屏已经挡得住它了,把它从 batchOnly 里删掉", kind)
		}
	}
}

// 接线守卫:收集循环第一轮挂上先上屏、不在等的时候不为它打分;首次解析按原样标签的 key 认正在播的这首;
// 最终那行决策日志记最早上屏的那份。整条检索要联网,单测跑不了,只能钉源码。
func TestEarlyLyricsIsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, needle := range []string{
		"\tearlyWatch := newEarlyLyricsWatch(ctx, artist, title)\n\tif earlyWatch != nil && forPlaying {\n\t\tearlyWatch.holdForNative = playerLocalNoVocalsHint(artist, srcTitle, album, durationSecs)\n\t}\ncollect:\n",
		"\t\t\tif onUpdate != nil || earlyWatch.active() {\n\t\t\t\tscored := scoreAndSort()\n",
		"\t\t\t\tearlyWatch.observe(raw[\"netease\"].ne, scored, doneSources)\n",
		"\t\tcase <-earlyWatch.graceC():\n\t\t\tearlyWatch.endGrace()\n\t\t\tearlyWatch.observe(raw[\"netease\"].ne, scoreAndSort(), doneSources)\n",
		"\tearlyWatch.finish(enabledDone(), totalSources)\n",
		"context.WithCancel(withEarlyLyricsTarget(withYouTubeMusicVideoID(context.Background(), kasetVideoID), hintKey))",
		"\t\t\t\tif shownFirst == \"\" {\n\t\t\t\t\tshownFirst = picked.Source\n\t\t\t\t}\n",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("enrich.go 缺 %q", needle)
		}
	}
}
