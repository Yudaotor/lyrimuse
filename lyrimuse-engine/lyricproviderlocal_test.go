package main

import (
	"context"
	"fmt"
	"reflect"
	"slices"
	"sort"
	"testing"
	"time"
)

// 本机类源(KKBOX / Spotify / Amazon Music 本地歌词、文件旁的 .lrc、洛雪、导入库)接到 LyricProvider 之后的对拍夹具,
// 和调度同步段的单测。对拍:同一份本机假数据、同一张场景表,一边照迁移前收集循环里开搜前同步读的写法
// (handwrittenLocalSources),一边经调度问(schedulerLocalSources),比放进 raw 的每一份的全字段、在不在场、这一轮记下的
// 跳过和各来源自己的状态。见 09 章决策 395。

// handwrittenLocalSources:迁移前收集循环里开搜之前同步读六路本机来源的那一段,原样留着当参照。返回的是那一段放进
// raw 的东西。
func handwrittenLocalSources(ctx context.Context, artist, title, album string, durationSecs float64) map[string]lyricSourceResult {
	idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)
	forPlaying := playerSignalApplies(ctx)
	raw := map[string]lyricSourceResult{}
	if lyricQueryReasonFrom(ctx) == lyricQueryReasonPrimary {
		if r, ok := kkboxLocalLyricsFor(idArtist, idTitle, durationSecs); ok {
			raw[kkboxLocalLyricsSource] = r
		}
		if r, ok := spotifyLocalLyricsFor(idArtist, idTitle, idAlbum); ok {
			raw[spotifyLocalLyricsSource] = r
		}
		if forPlaying && playingPlayer() == playerSpotify && spotifyLocalNoVocals(spotifyTrackIDHintFor(idArtist, idTitle)) {
			r := raw[spotifyLocalLyricsSource]
			r.source, r.noVocals, r.identityFromLocalClient, r.forPlayingTrack = spotifyLocalLyricsSource, true, true, true
			raw[spotifyLocalLyricsSource] = r
		}
		if r, ok := amazonLocalLyricsFor(idArtist, idTitle, idAlbum); ok {
			raw[amazonLocalLyricsSource] = r
		}
		if r, ok := localFileLyricsFor(idArtist, idTitle, durationSecs); ok {
			raw[localFileLyricsSource] = r
		}
		if r, ok := lxMusicLocalLyricsFor(ctx, idArtist, idTitle, durationSecs); ok {
			raw[lxMusicLocalLyricsSource] = r
		}
		if r, ok := importedLyricsFor(idArtist, idTitle, idAlbum, durationSecs); ok {
			raw[importLyricsSource] = r
		}
		for s, r := range raw {
			raw[s] = withoutPlayerIdentity(ctx, r)
		}
	}
	return raw
}

// schedulerLocalSources:照收集循环的写法建这一轮的查询、环境和判据(TestMigratedLyricSourcesAreWiredThroughProviders、
// TestLyricIdentityFieldsIsWired 钉着循环里那几行),经调度起一轮,交回同步段的结果照循环那样放成的 raw。联网源都关着,
// 它们各交一份空结果,收齐了丢掉。
func schedulerLocalSources(t *testing.T, ctx context.Context, artist, title, album string, durationSecs float64) map[string]lyricSourceResult {
	t.Helper()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)
	plan := newLyricRoundPlan(ctx, sharedLyricSourceBreaker().planRound(lyricSourceNames))
	q := ProviderQuery{Artist: artist, Title: title, Album: album, SourceTitle: lyricSourceTitleFor(ctx, title), DurationSecs: durationSecs}
	env := RoundEnv{ForPlayingTrack: playerSignalApplies(ctx), identityArtist: idArtist, identityTitle: idTitle, identityAlbum: idAlbum}
	out := make(chan SourceResult, len(lyricSourceNames))
	raw := map[string]lyricSourceResult{}
	for _, r := range startLyricProviders(ctx, lyricProviders().providers, q, env, plan, out) {
		raw[r.source] = withoutPlayerIdentity(ctx, r)
	}
	for range lyricSourceNames {
		select {
		case r := <-out:
			if !reflect.DeepEqual(r, SourceResult{source: r.source}) {
				t.Fatalf("联网源都关着,%s 却交了东西:%+v", r.source, r)
			}
			if lyricProviders().descriptor(r.source).Kind != providerKindNetwork {
				t.Fatalf("本机类源 %s 的结果不该走结果通道", r.source)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("联网源没有各交一份结果")
		}
	}
	return raw
}

// implementedLocalSources:登记了实现、由调度同步问的本机类源。
func implementedLocalSources() []string {
	var out []string
	for _, p := range lyricProviders().providers {
		if d := p.Descriptor(); d.Kind != providerKindNetwork {
			out = append(out, d.Name)
		}
	}
	return out
}

type localParityCase struct {
	name string
	// ctx:这一轮的 ctx 在前台首轮的基础上再加什么标记;nil = 不加。
	ctx                  func(context.Context) context.Context
	artist, title, album string
	durationSecs         float64
	// prepare:造这个场景的本机假数据、当前播放器;两条路各调一次。
	prepare func(t *testing.T)
	// present:这个场景里被测的来源在不在 raw 里。
	present bool
	check   func(t *testing.T, r lyricSourceResult)
}

type localParityOutcome struct {
	raw   map[string]lyricSourceResult
	round []string
	skips map[string]string
	state []string
}

func runLocalParityRound(t *testing.T, c localParityCase, state func() []string, viaScheduler bool) localParityOutcome {
	t.Helper()
	// 导入库在配置目录下:每一趟一个空的,要它的场景在 prepare 里往里放。
	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
	enableOnlyLyricSources(t)
	savedBreaker := sharedLyricSourceBreaker()
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	t.Cleanup(func() { setSharedLyricSourceBreaker(savedBreaker) })
	if c.prepare != nil {
		c.prepare(t)
	}
	base := context.Background()
	if c.ctx != nil {
		base = c.ctx(base)
	}
	ctx, round := withLyricSourceRound(base)
	var o localParityOutcome
	if viaScheduler {
		o.raw = schedulerLocalSources(t, ctx, c.artist, c.title, c.album, c.durationSecs)
	} else {
		o.raw = handwrittenLocalSources(ctx, c.artist, c.title, c.album, c.durationSecs)
	}
	o.skips = round.statsSkips()
	o.round = []string{fmt.Sprintf("skipped=%v", round.skippedSources()), fmt.Sprintf("enabled=%v", round.enabledSources())}
	if state != nil {
		o.state = state()
	}
	return o
}

// runLocalParity 逐个场景比两条路:接到调度上的本机类源,每一路在不在 raw 里、在的话全字段都要一样;再核对场景本身
// 是它标题说的那种情形(source 这一路在不在场)。
func runLocalParity(t *testing.T, source string, state func() []string, cases []localParityCase) {
	t.Helper()
	migrated := implementedLocalSources()
	if !slices.Contains(migrated, source) {
		t.Fatalf("%s 没有登记实现", source)
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			old := runLocalParityRound(t, c, state, false)
			got := runLocalParityRound(t, c, state, true)
			for _, name := range migrated {
				o, inOld := old.raw[name]
				g, inGot := got.raw[name]
				if inOld != inGot {
					t.Errorf("%s 在不在 raw 里不一样:经调度 %v,手写的 %v", name, inGot, inOld)
				}
				if !reflect.DeepEqual(g, o) {
					t.Errorf("%s 的结果不一样\n经调度 %+v\n手写的 %+v", name, g, o)
				}
			}
			for name := range got.raw {
				if !slices.Contains(migrated, name) {
					t.Errorf("调度交回了没登记实现的来源 %s", name)
				}
			}
			if !slices.Equal(got.round, old.round) || !reflect.DeepEqual(got.skips, old.skips) {
				t.Errorf("这一轮记下的不一样\n经调度 %v %v\n手写的 %v %v", got.round, got.skips, old.round, old.skips)
			}
			if !slices.Equal(got.state, old.state) {
				t.Errorf("来源自己的状态不一样\n经调度 %v\n手写的 %v", got.state, old.state)
			}
			r, present := got.raw[source]
			if present != c.present {
				t.Fatalf("%s 在不在 raw 里(%v)跟场景不符:%+v", source, present, r)
			}
			if present && r.source != source {
				t.Errorf("源名 %q", r.source)
			}
			if c.check != nil {
				c.check(t, r)
			}
		})
	}
}

// localRoundCtx 的几种轮次标记,各来源的场景表共用。
var (
	localAliasRound = func(ctx context.Context) context.Context {
		return withLyricQueryReason(ctx, lyricQueryReasonAliasMissing)
	}
	localOnlyListRound = func(ctx context.Context) context.Context {
		return withLyricSourceOnly(ctx, []string{lyricSourceQQ})
	}
	localOtherTrackRound  = withOtherTrackRound
	localManualRound      = withManualLyricSearch
	localBackgroundRound  = withBackgroundOutbound
	localIdentityNotGiven = func(t *testing.T, r lyricSourceResult) {
		t.Helper()
		if r.identityFromLocalClient {
			t.Errorf("这个场景里身份不算播放器本机数据给定:%+v", r)
		}
	}
	localIdentityGiven = func(t *testing.T, r lyricSourceResult) {
		t.Helper()
		if !r.identityFromLocalClient || r.forPlayingTrack {
			t.Errorf("这个场景里身份由播放器本机数据给定,forPlayingTrack 不填:%+v", r)
		}
	}
)

// ---- KKBOX 本地歌词 ----

// kkboxParityCache 造一份 KKBOX 的本机缓存(临时目录),当前播放器设成 player。entries 是「缓存文件名、地址、正文」三个一组。
func kkboxParityCache(player string, entries ...string) func(t *testing.T) {
	return func(t *testing.T) {
		t.Helper()
		withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
		for i := 0; i+2 < len(entries); i += 3 {
			testChromiumCacheEntry(t, kkboxCacheDirOverride, entries[i], entries[i+1], entries[i+2])
		}
		setNativeLyricSourcesForPlayer(player)
		t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
	}
}

const (
	kkboxParityTrackURL  = "https://api-webapps.kkbox.com.tw/v2/tracks/AH1?terr=tw"
	kkboxParityLyricsURL = "https://api-webapps.kkbox.com.tw/v2/lyrics/AH1?terr=tw"
	kkboxParityTrack     = `{"data":{"id":"AH1","name":"Anti-Hero","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[]},"album":{"name":"Midnights"},"duration_ms":200690}}`
	// kkboxParityAliasTrack:歌手带括号别名,别的写法只能靠「去掉别名后沾边 + 时长对得上」认。
	kkboxParityAliasTrack = `{"data":{"id":"AH1","name":"突然好想你","artist_roles":{"main_artists":[{"name":"五月天 (Mayday)"}]},"album":{"name":"后青春期的诗"},"duration_ms":265400}}`
	// kkboxParityPromoTrack:歌名带宣传尾段,检索词里会被去掉。
	kkboxParityPromoTrack = `{"data":{"id":"AH1","name":"如果可以 - 電影《月老》主題曲","artist_roles":{"main_artists":[{"name":"韋禮安"}]},"album":{"name":"如果可以"},"duration_ms":272000}}`
	kkboxParityCoarseBody = `{"status":"OK","data":{"info":{"lyrics":[{"start":12000,"end":15000,"text":"a"},{"start":16000,"end":18000,"text":"b"},{"start":20000,"end":22000,"text":"c"}]}}}`
)

func TestKKBOXLocalProviderMatchesHandwrittenRead(t *testing.T) {
	const artist, title, secs = "Taylor Swift", "Anti-Hero", 200.7
	hit := kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, kkboxParityTrack, "l2_0", kkboxParityLyricsURL, testKKBOXLyricsBody)
	alias := kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, kkboxParityAliasTrack, "l2_0", kkboxParityLyricsURL, testKKBOXLyricsBody)
	promo := kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, kkboxParityPromoTrack, "l2_0", kkboxParityLyricsURL, testKKBOXLyricsBody)
	const promoTitle = "如果可以 - 電影《月老》主題曲"
	promoQueryArtist, promoQueryTitle, _ := searchQueryFields("韋禮安", promoTitle, "")
	if promoQueryTitle == promoTitle {
		t.Fatal("这个用例要检索词跟原样标签不一样")
	}
	runLocalParity(t, kkboxLocalLyricsSource, nil, []localParityCase{
		{
			name: "命中:歌名歌手都对上", artist: artist, title: title, durationSecs: secs, prepare: hit, present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				want := lyricSourceResult{
					source: kkboxLocalLyricsSource, lyr: "[00:12.34]I have this thing where I get older\n[00:15.02]but just never wiser\n[01:01.00]\n[01:05.01]It's me, hi\n",
					matchTitle: "Anti-Hero", matchArtist: "Taylor Swift", matchAlbum: "Midnights", srcDur: 200.69, identityFromLocalClient: true,
				}
				if !reflect.DeepEqual(r, want) {
					t.Errorf("结果 %+v\n期望 %+v", r, want)
				}
			},
		},
		{name: "命中:时长没给,歌手逐字对上照认", artist: artist, title: title, prepare: hit, present: true, check: localIdentityGiven},
		{
			name: "歌手写法不同:靠别名加时长认出,不算本机身份", artist: "五月天", title: "突然好想你", durationSecs: 265.9, prepare: alias, present: true,
			check: localIdentityNotGiven,
		},
		{name: "歌手写法不同、时长对不上:没有", artist: "五月天", title: "突然好想你", durationSecs: 240, prepare: alias},
		{name: "歌手写法不同、时长没给:没有", artist: "五月天", title: "突然好想你", prepare: alias},
		{
			name: "每一句都是整秒:不算本机身份", artist: artist, title: title, durationSecs: secs, present: true,
			prepare: kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, kkboxParityTrack, "l2_0", kkboxParityLyricsURL, kkboxParityCoarseBody),
			check:   localIdentityNotGiven,
		},
		{
			name: "缓存里这首只有详情没有歌词:没有", artist: artist, title: title, durationSecs: secs,
			prepare: kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, kkboxParityTrack),
		},
		{name: "没用 KKBOX 放过这首:没有", artist: artist, title: "Lavender Haze", durationSecs: 202, prepare: hit},
		{
			name: "不是 KKBOX 在放:不读", artist: artist, title: title, durationSecs: secs,
			prepare: kkboxParityCache(spotifyBundleID, "l1_0", kkboxParityTrackURL, kkboxParityTrack, "l2_0", kkboxParityLyricsURL, testKKBOXLyricsBody),
		},
		{
			name: "歌词条目损坏:没有", artist: artist, title: title, durationSecs: secs,
			prepare: kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, kkboxParityTrack, "l2_0", kkboxParityLyricsURL, `{"status":"OK","data":{"info":`),
		},
		{
			name: "歌词不够三句:没有", artist: artist, title: title, durationSecs: secs,
			prepare: kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, kkboxParityTrack, "l2_0", kkboxParityLyricsURL,
				`{"status":"OK","data":{"info":{"lyrics":[{"start":12340,"end":15000,"text":"a"}]}}}`),
		},
		{
			name: "单曲详情损坏:没有", artist: artist, title: title, durationSecs: secs,
			prepare: kkboxParityCache(kkboxBundleID, "l1_0", kkboxParityTrackURL, `{"data":`, "l2_0", kkboxParityLyricsURL, testKKBOXLyricsBody),
		},
		{
			name: "缓存目录读不到:没有", artist: artist, title: title, durationSecs: secs,
			prepare: func(t *testing.T) {
				hit(t)
				kkboxCacheDirOverride = kkboxCacheDirOverride + "-gone"
			},
		},
		{
			name: "按播放器原样标签认,不按检索词",
			ctx: func(ctx context.Context) context.Context {
				return withSearchQueryOriginal(ctx, "韋禮安", promoTitle, "")
			},
			artist: promoQueryArtist, title: promoQueryTitle, durationSecs: 272, prepare: promo, present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				if r.matchTitle != promoTitle {
					t.Errorf("认到的应是带宣传尾段的那一条:%+v", r)
				}
			},
		},
		{name: "检索词对不上、也没记原样标签:没有", artist: promoQueryArtist, title: promoQueryTitle, durationSecs: 272, prepare: promo},
		{name: "别名轮不读", ctx: localAliasRound, artist: artist, title: title, durationSecs: secs, prepare: hit},
		{name: "带「只查这些源」名单的首轮照样读", ctx: localOnlyListRound, artist: artist, title: title, durationSecs: secs, prepare: hit, present: true, check: localIdentityGiven},
		{name: "别的歌那一轮:读到,身份不算播放器给定", ctx: localOtherTrackRound, artist: artist, title: title, durationSecs: secs, prepare: hit, present: true, check: localIdentityNotGiven},
		{name: "手动搜索照样读", ctx: localManualRound, artist: artist, title: title, durationSecs: secs, prepare: hit, present: true, check: localIdentityGiven},
		{name: "后台轮次照样读", ctx: localBackgroundRound, artist: artist, title: title, durationSecs: secs, prepare: hit, present: true, check: localIdentityGiven},
	})
}

// ---- 调度的同步段 ----

// 本机类源这一轮问不问只看轮次:别名轮的名单、设置里的开关、熔断都不管它。
func TestLyricRoundPlanDecidesLocalKindsByRoundOnly(t *testing.T) {
	asked, skipped := 0, 0
	for _, kind := range []ProviderKind{providerKindPlayerLocal, providerKindUserLibrary} {
		for _, rounds := range []RoundPolicy{roundsAll, roundsOnDemand, roundsPrimaryOnly} {
			d := &ProviderDescriptor{Name: "stub-local", Kind: kind, Rounds: rounds}
			for _, only := range []map[string]bool{nil, {"stub-local": true}, {"other": true}} {
				for _, primary := range []bool{true, false} {
					for _, onDemand := range []bool{true, false} {
						for _, enabled := range []bool{true, false} {
							for _, cooling := range []bool{false, true} {
								_, round := withLyricSourceRound(context.Background())
								plan := lyricRoundPlan{only: only, primary: primary, onDemand: onDemand, round: round,
									enabled: func(string) bool { return enabled }}
								if cooling {
									plan.cooling = lyricSourceRoundPlan{"stub-local": time.Minute}
								}
								stub := &stubLyricProvider{desc: d, resolve: func() SourceResult { return SourceResult{lyr: "[00:01.00]a"} }}
								got := runLyricProvider(context.Background(), stub, ProviderQuery{}, RoundEnv{}, plan)
								want := rounds != roundsPrimaryOnly || primary
								label := fmt.Sprintf("kind=%v rounds=%v only=%v primary=%v onDemand=%v enabled=%v cooling=%v", kind, rounds, only, primary, onDemand, enabled, cooling)
								if queried := stub.calls.Load() == 1; queried != want {
									t.Errorf("%s:问了=%v,应是 %v", label, queried, want)
								}
								if !want && !reflect.DeepEqual(got, SourceResult{source: "stub-local"}) {
									t.Errorf("%s:不问时应交只带源名的空结果,得到 %+v", label, got)
								}
								if len(round.statsSkips()) != 0 || len(round.skippedSources()) != 0 {
									t.Errorf("%s:本机类源不记跳过:%v", label, round.statsSkips())
								}
								if want {
									asked++
								} else {
									skipped++
								}
							}
						}
					}
				}
			}
		}
	}
	if asked == 0 || skipped == 0 {
		t.Fatalf("问和不问都该出现:问 %d、不问 %d", asked, skipped)
	}
	// 联网源不受这一支影响:只在首轮问的联网源(现在没有)在别的轮次同样静默跳过,名单外的照旧跳过。
	network := &ProviderDescriptor{Name: "stub-net"}
	for _, c := range []struct {
		plan lyricRoundPlan
		want providerRoundDecision
	}{
		{lyricRoundPlan{only: map[string]bool{"other": true}, primary: true, enabled: func(string) bool { return true }}, providerRoundSkipSilent},
		{lyricRoundPlan{primary: true, enabled: func(string) bool { return false }}, providerRoundSkipSilent},
		{lyricRoundPlan{primary: true, enabled: func(string) bool { return true }, cooling: lyricSourceRoundPlan{"stub-net": time.Minute}}, providerRoundSkipCooling},
		{lyricRoundPlan{enabled: func(string) bool { return true }}, providerRoundQuery},
	} {
		if got := c.plan.decide(network); got != c.want {
			t.Errorf("联网源在 %+v 下的处置 %v,应是 %v", c.plan, got, c.want)
		}
	}
}

// 首轮与否从 ctx 上的来路读:没挂来路的是首轮,别名轮、反查轮这些追加的轮次不是。
func TestLyricRoundPlanReadsPrimaryFromQueryReason(t *testing.T) {
	if !newLyricRoundPlan(context.Background(), nil).primary {
		t.Error("没挂来路的一轮是首轮")
	}
	for _, reason := range []string{lyricQueryReasonAliasMissing, lyricQueryReasonAliasRescue, lyricQueryReasonTitleSplit, lyricQueryReasonPrimaryVar, lyricQueryReasonISRC} {
		if newLyricRoundPlan(withLyricQueryReason(context.Background(), reason), nil).primary {
			t.Errorf("来路 %q 的一轮不是首轮", reason)
		}
	}
	// 名单不影响是不是首轮。
	if !newLyricRoundPlan(withLyricSourceOnly(context.Background(), []string{lyricSourceQQ}), nil).primary {
		t.Error("带「只查这些源」名单的首轮仍是首轮")
	}
}

// 调度按 Kind 分两段:联网源各起一个 goroutine、结果走通道;本机类源在 startLyricProviders 返回之前按登记的先后同步问完,
// 结果作为返回值交回、不走通道,交空结果的(本机没有这一首、这种轮次不问)不交回。结果照样封口。
func TestStartLyricProvidersRunsLocalKindsSynchronously(t *testing.T) {
	enableOnlyLyricSources(t, "stub-net")
	release := make(chan struct{})
	var order []string
	net := &stubLyricProvider{desc: &ProviderDescriptor{Name: "stub-net"}}
	net.resolve = func() SourceResult {
		<-release
		return SourceResult{lyr: "[00:01.00]net"}
	}
	local := func(name string, kind ProviderKind, privileges builtinPrivileges, r SourceResult) *stubLyricProvider {
		p := &stubLyricProvider{desc: &ProviderDescriptor{Name: name, Kind: kind, Rounds: roundsPrimaryOnly, Privileges: privileges}}
		p.resolve = func() SourceResult {
			order = append(order, name)
			return r
		}
		return p
	}
	claimed := SourceResult{source: "someone else", lyr: "[00:01.00]local", identityFromLocalClient: true}
	first := local("stub-first", providerKindPlayerLocal, privLocalClientIdentity, claimed)
	empty := local("stub-empty", providerKindPlayerLocal, privLocalClientIdentity, SourceResult{})
	named := local("stub-named-only", providerKindPlayerLocal, privLocalClientIdentity, SourceResult{source: "stub-named-only"})
	library := local("stub-library", providerKindUserLibrary, 0, claimed)
	flagOnly := local("stub-flag", providerKindPlayerLocal, privLocalClientIdentity, SourceResult{identityFromLocalClient: true})
	providers := []LyricProvider{first, net, empty, named, library, flagOnly}

	ctx := context.Background()
	out := make(chan SourceResult, 1)
	env := RoundEnv{identityArtist: "原样歌手", identityTitle: "原样歌名", identityAlbum: "原样专辑"}
	got := startLyricProviders(ctx, providers, ProviderQuery{}, env, newLyricRoundPlan(ctx, nil), out)
	// 返回时本机类源都问完了,联网源还挂着:同步段不等联网源。
	if want := []string{"stub-first", "stub-empty", "stub-named-only", "stub-library", "stub-flag"}; !slices.Equal(order, want) {
		t.Fatalf("返回时本机类源应已按登记的先后各问一次:%v", order)
	}
	select {
	case r := <-out:
		t.Fatalf("联网源还没放行,通道里不该有结果:%+v", r)
	default:
	}
	want := []SourceResult{
		{source: "stub-first", lyr: "[00:01.00]local", identityFromLocalClient: true},
		{source: "stub-library", lyr: "[00:01.00]local"},
		{source: "stub-flag", identityFromLocalClient: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("同步段交回 %+v\n期望 %+v", got, want)
	}
	if a, ti, al := first.gotEnv.IdentityFields(); a != "原样歌手" || ti != "原样歌名" || al != "原样专辑" {
		t.Errorf("带 privLocalClientIdentity 的本机类源应读得到播放器原样标签:%q %q %q", a, ti, al)
	}
	if a, ti, al := library.gotEnv.IdentityFields(); a != "" || ti != "" || al != "" {
		t.Errorf("没有 privLocalClientIdentity 的读不到播放器原样标签:%q %q %q", a, ti, al)
	}
	close(release)
	select {
	case r := <-out:
		if !reflect.DeepEqual(r, SourceResult{source: "stub-net", lyr: "[00:01.00]net"}) {
			t.Errorf("联网源的结果 %+v", r)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("联网源的结果没到")
	}
	select {
	case r := <-out:
		t.Errorf("通道里多了一份 %+v:本机类源的结果不走通道", r)
	case <-time.After(20 * time.Millisecond):
	}

	// 不是首轮:本机类源不问、什么都不交回;联网源照常问。
	order = nil
	aliasCtx := withLyricQueryReason(ctx, lyricQueryReasonAliasMissing)
	out = make(chan SourceResult, 1)
	if got := startLyricProviders(aliasCtx, providers, ProviderQuery{}, env, newLyricRoundPlan(aliasCtx, nil), out); len(got) != 0 || len(order) != 0 {
		t.Errorf("别名轮不该问本机类源:交回 %+v,问了 %v", got, order)
	}
	if r := <-out; r.source != "stub-net" || r.lyr == "" {
		t.Errorf("别名轮联网源照常问:%+v", r)
	}
	// 带名单的首轮:名单外的联网源静默跳过,本机类源照样问。
	order = nil
	onlyCtx := withLyricSourceOnly(ctx, []string{"other"})
	out = make(chan SourceResult, 1)
	got = startLyricProviders(onlyCtx, providers, ProviderQuery{}, env, newLyricRoundPlan(onlyCtx, nil), out)
	if !reflect.DeepEqual(got, want) || len(order) != 5 {
		t.Errorf("带名单的首轮本机类源照样问:交回 %+v,问了 %v", got, order)
	}
	if r := <-out; !reflect.DeepEqual(r, SourceResult{source: "stub-net"}) {
		t.Errorf("名单外的联网源应交空结果:%+v", r)
	}
}

// 读播放器原样标签要 privLocalClientIdentity:没有这一位的源经调度拿到的环境读出来是三个空串,收集循环建的那份
// (还没交给任何源)也一样。
func TestRoundEnvIdentityFieldsNeedPrivilege(t *testing.T) {
	full := RoundEnv{ForPlayingTrack: true, identityArtist: "原样歌手", identityTitle: "原样歌名", identityAlbum: "原样专辑"}
	if a, ti, al := full.IdentityFields(); a != "" || ti != "" || al != "" {
		t.Errorf("还没经调度交给源的环境不放行:%q %q %q", a, ti, al)
	}
	ctx := context.Background()
	for _, c := range []struct {
		name       string
		privileges builtinPrivileges
		want       bool
	}{
		{name: "没有特权位"},
		{name: "只有不相干的位", privileges: privPlaybackTrackIDs | privOfflineLeg | privTrackIDPublish | privTrackIDConsume | privPeripheral | privPlayerNoVocals | privBorrowFromPeers | privRefetchByID | privBreakerControl},
		{name: "本机客户端身份", privileges: privLocalClientIdentity, want: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			enableOnlyLyricSources(t, "stub")
			for _, kind := range []ProviderKind{providerKindNetwork, providerKindPlayerLocal, providerKindUserLibrary} {
				stub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "stub", Kind: kind, Privileges: c.privileges}}
				runLyricProvider(ctx, stub, ProviderQuery{}, full, newLyricRoundPlan(ctx, nil))
				if stub.calls.Load() != 1 {
					t.Fatalf("Resolve 应被问一次,实际 %d 次", stub.calls.Load())
				}
				a, ti, al := stub.gotEnv.IdentityFields()
				if got := a == "原样歌手" && ti == "原样歌名" && al == "原样专辑"; got != c.want || (!c.want && (a != "" || ti != "" || al != "")) {
					t.Errorf("kind=%v:读到 %q %q %q,放行应是 %v", kind, a, ti, al, c.want)
				}
			}
		})
	}
}

// 排序层分不出「raw 里有一份只带源名的空结果」和「raw 里没有这个来源」:金标集每个样本各加六路本机来源的空结果再排,
// 结果逐字段一样;播放器自己的无人声信号(playerInstrumentalSource)同样不认空结果。调度仍然不把空结果放进 raw。
func TestEmptyLocalResultRanksSameAsAbsent(t *testing.T) {
	var localNames []string
	for _, d := range registryDescriptors() {
		if d.Kind != providerKindNetwork {
			localNames = append(localNames, d.Name)
		}
	}
	sort.Strings(localNames)
	if len(localNames) != 6 {
		t.Fatalf("本机类源应是六路:%v", localNames)
	}
	fixtures := loadGoldenFixtures(t)
	if len(fixtures) == 0 {
		t.Fatal("没有金标样本")
	}
	for _, fx := range fixtures {
		applyGoldenSettings(t, fx)
		for _, player := range []string{"", playerSpotify, playerKKBOX} {
			setNativeLyricSourcesForPlayer(playerBundleIDs[player])
			absent := goldenRawRound(fx)
			present := goldenRawRound(fx)
			for _, name := range localNames {
				if _, has := present[name]; !has {
					present[name] = lyricSourceResult{source: name}
				}
			}
			q := fx.Query
			a := rankLyricSourceResults(q.Artist, q.Title, q.Album, q.DurationSecs, absent)
			b := rankLyricSourceResults(q.Artist, q.Title, q.Album, q.DurationSecs, present)
			if !reflect.DeepEqual(a, b) {
				t.Errorf("%s(播放器 %q):raw 里多了本机类源的空结果,排序结果变了", fx.ID, player)
			}
			if x, y := playerInstrumentalSource(absent, a), playerInstrumentalSource(present, b); x != y {
				t.Errorf("%s(播放器 %q):播放器无人声信号的来源 %q 变成 %q", fx.ID, player, x, y)
			}
		}
	}
	setNativeLyricSourcesForPlayer("")
}
