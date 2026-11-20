package main

import (
	"context"
	"fmt"
	"net/http"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

// 本机类源加联网源一起跑的整轮对拍:同一份本机假数据、同一个假服务器,一边照迁移前收集循环的写法(开搜前手写读六路
// 本机来源,handwrittenLyricRound),一边走真的收集循环,比每一次 onUpdate 回调时的候选(顺序、全字段)和进度分子分母、
// 最终结果、发出的请求、这一轮记下的跳过。联网那一半用网易云、QQ、amll 三个源(lyricprovidertrackids_test.go 的假接口),
// 到达的先后由假服务器定死;其余十三个联网源关着,各交一份空结果、到得有早有晚,它们不改候选也不改进度,所以回调
// 按「连着几次一模一样的并成一次」之后再比。见 09 章决策 395。

// networkLyricProviders:登记表里联网源的实现。
func networkLyricProviders() []LyricProvider {
	var out []LyricProvider
	for _, p := range lyricProviders().providers {
		if p.Descriptor().Kind == providerKindNetwork {
			out = append(out, p)
		}
	}
	return out
}

// handwrittenLyricRound:迁移前的收集循环,原样留着当参照:调度只起联网源,六路本机来源在开搜之前手写同步读、直接放进
// raw,不进结果通道、不算进「回来了的源」。先上屏那一支(earlyWatch)只在首次解析正在放的那首时有,对拍的轮次里
// 是 nil,这里没抄。
func handwrittenLyricRound(ctx context.Context, artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)
	srcTitle := lyricSourceTitleFor(ctx, title)
	resultsCh := make(chan lyricSourceResult, len(lyricSourceNames))
	forPlaying := playerSignalApplies(ctx)
	lyricQueryLogFrom(ctx).record(artist, title, lyricQueryReasonFrom(ctx), lyricQueryOriginFrom(ctx), sortedLyricSourceOnly(ctx))
	breakerPlan := sharedLyricSourceBreaker().planRound(lyricSourceNames)
	providerPlan := newLyricRoundPlan(ctx, breakerPlan)
	providerQuery := ProviderQuery{Artist: artist, Title: title, Album: album, SourceTitle: srcTitle, DurationSecs: durationSecs}
	providerEnv := RoundEnv{ForPlayingTrack: forPlaying, identityArtist: idArtist, identityTitle: idTitle, identityAlbum: idAlbum}
	startLyricProviders(ctx, networkLyricProviders(), providerQuery, providerEnv, providerPlan, resultsCh)

	raw := handwrittenLocalSources(ctx, artist, title, album, durationSecs)
	scoreAndSort := func() []scoredLyricCandidateResult {
		return rankLyricSourceResults(artist, title, album, durationSecs, raw)
	}
	deadline := time.After(lyricSearchDeadline)
	doneSources := map[string]bool{}
	totalSources := enabledLyricSourceCount()
	enabledDone := func() int {
		n := 0
		for _, s := range lyricSourceNames {
			if doneSources[s] && lyricSourceEnabled(s) {
				n++
			}
		}
		return n
	}
	allLyricSourcesBack := func() bool {
		for _, s := range lyricSourceNames {
			if !doneSources[s] {
				return false
			}
		}
		return true
	}
collect:
	for !allLyricSourcesBack() {
		select {
		case r := <-resultsCh:
			doneSources[r.source] = true
			r = withoutPlayerIdentity(ctx, r)
			r.forPlayingTrack = forPlaying
			raw[r.source] = r
			if lyricSourceResultTap != nil {
				lyricSourceResultTap(r)
			}
			if onUpdate != nil {
				onUpdate(raw["netease"].ne, scoreAndSort(), enabledDone(), totalSources)
			}
		case <-deadline:
			for _, s := range lyricSourceNames {
				if !doneSources[s] {
					noteLyricDeadlineMiss(ctx, s)
				}
			}
			break collect
		case <-ctx.Done():
			break collect
		}
	}
	return raw["netease"].ne, scoreAndSort()
}

// lyricRoundUpdate:一次 onUpdate 回调拿到的东西。
type lyricRoundUpdate struct {
	ne          neteaseInfo
	scored      []scoredLyricCandidateResult
	done, total int
}

type lyricRoundParityCase struct {
	name string
	ctx  func(context.Context) context.Context
	// enabled:三个联网源里设置中开着的。
	enabled              []string
	artist, title, album string
	durationSecs         float64
	// prepare:造本机假数据、当前播放器;两条路各调一次。
	prepare func(t *testing.T)
	fake    trackIDFake
	// wantOrder:三个联网源结果到达的先后(同 trackIDParityCase.wantOrder)。
	wantOrder [][]string
	// wantProgress:并掉重复之后每一次回调的进度「分子/分母」。
	wantProgress []string
	// wantFirst:第一次回调时候选里就该有的本机类源;wantNever:自始至终不该出现的。
	wantFirst, wantNever []string
	check                func(t *testing.T, o lyricRoundParityOutcome)
}

type lyricRoundParityOutcome struct {
	updates  []lyricRoundUpdate
	ne       neteaseInfo
	final    []scoredLyricCandidateResult
	order    []string
	requests []string
	round    []string
	skips    map[string]string
}

func runLyricRoundParityRound(t *testing.T, c lyricRoundParityCase, viaScheduler bool) lyricRoundParityOutcome {
	t.Helper()
	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
	neteaseParitySource.reset(t)
	resetQQParityState(t)
	amllParitySource.reset(t)
	g := newTrackIDRound()
	// 关着的 LRCLIB 的空结果也记到达:网易云的请求等它到了才放行(lyricRoundFakes 的 gate),第一次回调因此总在任何
	// 联网候选之前。
	g.arrived[lyricSourceLRCLIB] = make(chan struct{})
	handle := c.fake.handler()
	fake := withParityFake(t, trackIDParitySource, func(r parityRequest) parityReply { return handle(g, r) })
	enableOnlyLyricSources(t, c.enabled...)
	if c.prepare != nil {
		c.prepare(t)
	}
	base := context.Background()
	if c.ctx != nil {
		base = c.ctx(base)
	}
	ctx, round := withLyricSourceRound(base)
	var o lyricRoundParityOutcome
	onUpdate := func(ne neteaseInfo, scored []scoredLyricCandidateResult, done, total int) {
		o.updates = append(o.updates, lyricRoundUpdate{ne: ne, scored: scored, done: done, total: total})
	}
	saved := lyricSourceResultTap
	lyricSourceResultTap = g.note
	if viaScheduler {
		o.ne, o.final = fetchScoredLyricCandidatesStreaming(ctx, c.artist, c.title, c.album, c.durationSecs, onUpdate)
	} else {
		o.ne, o.final = handwrittenLyricRound(ctx, c.artist, c.title, c.album, c.durationSecs, onUpdate)
	}
	lyricSourceResultTap = saved
	waitLyricRoundGoroutinesGone(t)
	order, _ := g.snapshot()
	o.order = slices.DeleteFunc(order, func(s string) bool { return s == lyricSourceLRCLIB })
	o.updates = distinctLyricRoundUpdates(o.updates)
	o.requests, o.skips = fake.requests(), round.statsSkips()
	o.round = []string{fmt.Sprintf("skipped=%v", round.skippedSources()), fmt.Sprintf("enabled=%v", round.enabledSources())}
	return o
}

// distinctLyricRoundUpdates:连着几次一模一样的回调并成一次。
func distinctLyricRoundUpdates(updates []lyricRoundUpdate) []lyricRoundUpdate {
	var out []lyricRoundUpdate
	for _, u := range updates {
		if len(out) > 0 && reflect.DeepEqual(out[len(out)-1], u) {
			continue
		}
		out = append(out, u)
	}
	return out
}

func scoredSources(scored []scoredLyricCandidateResult) []string {
	var out []string
	for _, c := range scored {
		out = append(out, c.Source)
	}
	return out
}

func runLyricRoundParity(t *testing.T, cases []lyricRoundParityCase) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			old := runLyricRoundParityRound(t, c, false)
			got := runLyricRoundParityRound(t, c, true)
			if len(got.updates) != len(old.updates) {
				t.Fatalf("回调次数不一样:经调度 %d 次,手写的 %d 次", len(got.updates), len(old.updates))
			}
			for i := range got.updates {
				g, o := got.updates[i], old.updates[i]
				if g.done != o.done || g.total != o.total {
					t.Errorf("第 %d 次回调的进度不一样:经调度 %d/%d,手写的 %d/%d", i+1, g.done, g.total, o.done, o.total)
				}
				if !slices.Equal(scoredSources(g.scored), scoredSources(o.scored)) {
					t.Errorf("第 %d 次回调的候选和顺序不一样:经调度 %v,手写的 %v", i+1, scoredSources(g.scored), scoredSources(o.scored))
				}
				if !reflect.DeepEqual(g.scored, o.scored) || !reflect.DeepEqual(g.ne, o.ne) {
					t.Errorf("第 %d 次回调的内容不一样\n经调度 %+v\n手写的 %+v", i+1, g.scored, o.scored)
				}
			}
			if !reflect.DeepEqual(got.final, old.final) || !reflect.DeepEqual(got.ne, old.ne) {
				t.Errorf("最终结果不一样\n经调度 %+v\n手写的 %+v", got.final, old.final)
			}
			if !slices.Equal(got.requests, old.requests) {
				t.Errorf("发出的请求不一样\n经调度 %v\n手写的 %v", got.requests, old.requests)
			}
			if !slices.Equal(got.round, old.round) || !reflect.DeepEqual(got.skips, old.skips) {
				t.Errorf("这一轮记下的不一样\n经调度 %v %v\n手写的 %v %v", got.round, got.skips, old.round, old.skips)
			}
			for label, o := range map[string]lyricRoundParityOutcome{"经调度": got, "手写的": old} {
				if !trackIDOrderMatches(o.order, c.wantOrder) {
					t.Errorf("%s:联网源结果到达的先后 %v,这个场景应是 %v", label, o.order, c.wantOrder)
				}
				var progress []string
				for _, u := range o.updates {
					progress = append(progress, fmt.Sprintf("%d/%d", u.done, u.total))
				}
				if !slices.Equal(progress, c.wantProgress) {
					t.Errorf("%s:各次回调的进度 %v,这个场景应是 %v(本机类源不算进分子分母)", label, progress, c.wantProgress)
				}
			}
			if len(got.updates) > 0 {
				first := scoredSources(got.updates[0].scored)
				for _, s := range c.wantFirst {
					if !slices.Contains(first, s) {
						t.Errorf("第一次回调时 %s 应已在候选里:%v", s, first)
					}
				}
			}
			for _, s := range c.wantFirst {
				if !slices.Contains(scoredSources(got.final), s) {
					t.Errorf("最终结果里应有 %s:%v", s, scoredSources(got.final))
				}
			}
			for _, s := range c.wantNever {
				for i, u := range got.updates {
					if slices.Contains(scoredSources(u.scored), s) {
						t.Errorf("第 %d 次回调里不该有 %s:%v", i+1, s, scoredSources(u.scored))
					}
				}
				if slices.Contains(scoredSources(got.final), s) {
					t.Errorf("最终结果里不该有 %s:%v", s, scoredSources(got.final))
				}
			}
			if c.check != nil {
				c.check(t, got)
			}
		})
	}
}

// lyricRoundFakes:整轮对拍用的三个联网源的假接口。hit 三个源都有这首(amll 库里有网易云编号那份),miss 都没有。
func lyricRoundFakes(t *testing.T) (hit, miss trackIDFake) {
	t.Helper()
	neFound := neParitySong{id: 386538, name: "突然好想你", artist: "五月天", album: "后青春期的诗", albumID: 38285, ms: 265400, picID: neParityPicID}
	neSearch := func(songs ...neParitySong) func(parityRequest, string, string) parityReply {
		return func(_ parityRequest, path, _ string) parityReply {
			if path == "search/get" {
				return neParitySearch(songs...)
			}
			return parityStatus(http.StatusNotFound)
		}
	}
	qrc := `{"lyric":"` + qqEncryptQRCForTest(t, qqTestQRCXML(qqTestQRCContent)) + `","qrc_t":1,"lrc_t":0,"trans":"","roma":""}`
	hit = trackIDFake{
		ne: neParityFake{
			search: neSearch(neFound),
			lyric: func(_ parityRequest, path string) parityReply {
				if path == "song/lyric/v1" {
					return neParityLyric(neV1Lyric, neParityTrans, "", "", false)
				}
				return parityStatus(http.StatusNotFound)
			},
		},
		qq: qqParityFake{
			search: func(parityRequest, string) parityReply {
				return qqParitySearch(qqParityHit{qqParityMid, "突然好想你", "五月天", "后青春期的诗", 265})
			},
			detail:    func(parityRequest, string) parityReply { return qqParityDetail(97773, 265, 0) },
			lineLyric: func(parityRequest, string) parityReply { return qqParityLine(qqTestLRC) },
			musicu: func(_ parityRequest, method string, param map[string]any) parityReply {
				switch {
				case method == "GetSession":
					return parityOK(musicuOK(qqParitySession))
				case method == "GetPlayLyricInfo" && param["songID"] != nil:
					return parityOK(musicuOK(qrc))
				}
				return parityStatus(http.StatusNotFound)
			},
		},
		amll: func(r parityRequest) parityReply {
			if strings.HasSuffix(r.URL.Path, "/ncm-lyrics/386538.ttml") {
				return parityOK(amllTestTTML)
			}
			return parityStatus(http.StatusNotFound)
		},
		gate: trackIDGate(map[string]string{lyricSourceNetease: lyricSourceLRCLIB, lyricSourceQQ: lyricSourceNetease, lyricSourceAMLL: lyricSourceQQ}),
	}
	miss = trackIDFake{
		ne: neParityFake{
			search: neSearch(),
			albums: func(parityRequest, string, string) parityReply {
				return parityOK(`{"code":200,"result":{"albums":[]}}`)
			},
		},
		qq: qqParityFake{
			search:   func(parityRequest, string) parityReply { return parityOK(qqParityNoSongs) },
			smartbox: func(parityRequest, string) parityReply { return parityOK(qqParityNoBox) },
		},
		gate: trackIDGate(map[string]string{lyricSourceNetease: lyricSourceLRCLIB, lyricSourceQQ: lyricSourceNetease}),
	}
	return hit, miss
}

// kkboxParityRoundTrack:整轮对拍里 KKBOX 缓存中的那一首,跟三个联网源的假接口是同一首。
const kkboxParityRoundTrack = `{"data":{"id":"AH1","name":"突然好想你","artist_roles":{"main_artists":[{"name":"五月天"}]},"album":{"name":"后青春期的诗"},"duration_ms":265400}}`

// lyricRoundOrder:三个联网源照 lyricRoundFakes 的 gate 到达的先后;lyricRoundProgress:三个都开着时各次回调的进度,
// 头一次是关着的源的空结果到达时那一次(候选里只有本机那几份)。
var (
	lyricRoundOrder    = [][]string{{lyricSourceNetease}, {lyricSourceQQ}, {lyricSourceAMLL}}
	lyricRoundProgress = []string{"0/3", "1/3", "2/3", "3/3"}
)

func TestLocalSourcesInFullRoundMatchHandwrittenRound(t *testing.T) {
	const artist, title, album, secs = "五月天", "突然好想你", "后青春期的诗", 265.4
	all := trackIDSources
	hit, miss := lyricRoundFakes(t)
	kkbox := kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, kkboxParityRoundTrack, "l2_0", kkboxParityLyricsURL, testKKBOXLyricsBody)
	nativeBonus := func(want bool) func(t *testing.T, o lyricRoundParityOutcome) {
		return func(t *testing.T, o lyricRoundParityOutcome) {
			t.Helper()
			for _, c := range o.final {
				if c.Source == kkboxLocalLyricsSource && c.hasScoreTerm(scoreTermNativeSource) != want {
					t.Errorf("KKBOX 那份带不带同源加权(应是 %v)跟场景不符:%+v", want, c.ScoreTerms)
				}
			}
		}
	}
	// playerInstrumental:每一次回调和最终结果是不是都按「播放器自己说这一条没有人声」处理。
	playerInstrumental := func(want bool) func(t *testing.T, o lyricRoundParityOutcome) {
		return func(t *testing.T, o lyricRoundParityOutcome) {
			t.Helper()
			for i, u := range o.updates {
				if playerSaysInstrumental(u.scored) != want {
					t.Errorf("第 %d 次回调:播放器无人声信号(应是 %v)跟场景不符:%v", i+1, want, scoredSources(u.scored))
				}
			}
			if playerSaysInstrumental(o.final) != want || (pickLyricCandidate(o.final) == nil) != want {
				t.Errorf("最终结果:播放器无人声信号(应是 %v)跟场景不符:%v", want, scoredSources(o.final))
			}
		}
	}
	runLyricRoundParity(t, []lyricRoundParityCase{
		{
			name: "KKBOX 在放、缓存里有这首,三个联网源也都有", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: kkbox, fake: hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantFirst: []string{kkboxLocalLyricsSource}, check: nativeBonus(true),
		},
		{
			name: "本机没有这首,三个联网源都有", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: kkboxParityCache(kkboxBundleID), fake: hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantNever: []string{kkboxLocalLyricsSource},
		},
		{
			name: "不是 KKBOX 在放", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: kkboxParityCache(spotifyBundleID, "l1_0", kkboxParityTrackURL, kkboxParityRoundTrack, "l2_0", kkboxParityLyricsURL, testKKBOXLyricsBody),
			fake:    hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantNever: []string{kkboxLocalLyricsSource},
		},
		{
			name: "联网源都没有这首,只有本机那份", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: kkbox, fake: miss, wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ, lyricSourceAMLL}}, wantProgress: lyricRoundProgress,
			wantFirst: []string{kkboxLocalLyricsSource},
			check: func(t *testing.T, o lyricRoundParityOutcome) {
				if got := scoredSources(o.final); !slices.Equal(got, []string{kkboxLocalLyricsSource}) {
					t.Errorf("最终只该有 KKBOX 那份:%v", got)
				}
			},
		},
		{
			name: "别名轮:本机类源不读", ctx: localAliasRound, enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: kkbox, fake: hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantNever: []string{kkboxLocalLyricsSource},
		},
		{
			name: "别的歌那一轮:本机那份在场,不带同源加权", ctx: localOtherTrackRound, enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: kkbox, fake: hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantFirst: []string{kkboxLocalLyricsSource}, check: nativeBonus(false),
		},
		{
			name: "只开着网易云:本机那份照样在场", enabled: []string{lyricSourceNetease}, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: kkbox, fake: hit, wantOrder: [][]string{{lyricSourceNetease, lyricSourceQQ}, {lyricSourceAMLL}}, wantProgress: []string{"0/1", "1/1"},
			wantFirst: []string{kkboxLocalLyricsSource},
		},
		{
			name: "Spotify 在放、它说这一条没有人声:从第一次回调起就按纯音乐处理", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: spotifyParityData{player: spotifyBundleID, hint: true, languages: []string{"zxx"}}.prepare(artist, title, album),
			fake:    hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, check: playerInstrumental(true),
		},
		{
			name: "Spotify 说没有人声、但这一轮是手动搜索:照常给词", ctx: localManualRound, enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: spotifyParityData{player: spotifyBundleID, hint: true, languages: []string{"zxx"}}.prepare(artist, title, album),
			fake:    hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantNever: []string{spotifyLocalLyricsSource}, check: playerInstrumental(false),
		},
		{
			name: "Spotify 缓存里有这首的词", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: spotifyParityData{player: spotifyBundleID, hint: true, lyrics: spotifyLyricsTestJSON}.prepare(artist, title, album),
			fake:    hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantFirst: []string{spotifyLocalLyricsSource}, check: playerInstrumental(false),
		},
		{
			name: "正在放的文件旁有双语行的 .lrc", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: localFileParityData{player: reampBundleID, sidecar: []byte("[00:01.00]突然好想你\n[00:01.00]Suddenly I miss you\n[00:05.00]你会在哪里\n[00:05.00]Where would you be\n[00:09.00]过得快乐或委屈\n[00:09.00]Happy or wronged\n")}.prepare(artist, title),
			fake:    hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantFirst: []string{localFileLyricsSource},
		},
		{
			name: "洛雪库里有这首", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				withLXMusicData(t, []lxTestTrack{{"temp", "kw_1", "突然好想你", "五月天", "04:25", "后青春期的诗"}},
					[]lxTestLyric{{"kw_1", "raw", "lyric", "[00:01.00]突然好想你\n[00:05.00]你会在哪里\n[00:09.00]过得快乐或委屈"}}, "temp", 0, "")
				setNativeLyricSourcesForPlayer(lxMusicBundleID)
				t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
			},
			fake: hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantFirst: []string{lxMusicLocalLyricsSource},
		},
		{
			name: "导入库和 KKBOX 都有这首:两份都在场", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				kkbox(t)
				importParityRecords(nil, importedLyricsRecord{Key: enrichKey(artist, title, album), Lyrics: lrcBody(20, 10)})(t)
			},
			fake: hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantFirst: []string{kkboxLocalLyricsSource, importLyricsSource},
		},
		{
			name: "导入库有这首、别名轮:不读", ctx: localAliasRound, enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: importParityRecords(nil, importedLyricsRecord{Key: enrichKey(artist, title, album), Lyrics: lrcBody(20, 10)}),
			fake:    hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantNever: []string{importLyricsSource},
		},
		{
			name: "Amazon Music 在放、缓存里有这首", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			prepare: amazonParityData{player: amazonMusicBundleID, currentASIN: "B0TESTMD01",
				hammer: []string{"B0TESTMD01-ATVPDKIKX0DER", amazonParityLyrics("B0TESTMD01", 1500, "突然好想你", 5500, "你会在哪里", 9500, "过得快乐或委屈")}}.prepare(artist, title),
			fake: hit, wantOrder: lyricRoundOrder, wantProgress: lyricRoundProgress, wantFirst: []string{amazonLocalLyricsSource},
		},
	})
}
