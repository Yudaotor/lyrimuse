package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 调度按描述符的特权位放行的那几样:没有对应那一位的源拿不到。见 09 章决策 392。

// offlineStubProvider:带本机那条腿的假源,记 ResolveOffline 被问了几次、拿到的查询。
type offlineStubProvider struct {
	stubLyricProvider
	offlineCalls atomic.Int32
	offlineQ     ProviderQuery
	offline      func() (SourceResult, bool)
}

func (p *offlineStubProvider) ResolveOffline(q ProviderQuery) (SourceResult, bool) {
	p.offlineCalls.Add(1)
	p.offlineQ = q
	return p.offline()
}

// 熔断冷却时的本机那条腿只给带 privOfflineLeg 的源:没有这一位的源实现了 ResolveOffline 也不问;名单外、关掉的源
// 本机那份也不读;本机命中算答了、不记跳过,本机没有照冷却跳过记。
func TestOfflineLegOnlyForPrivilegedProviders(t *testing.T) {
	local := SourceResult{source: "something else", lyr: "[00:01.00]本机那份", matchTitle: "T"}
	q := ProviderQuery{Artist: "A", Title: "T", Album: "Al", SourceTitle: "T (1)", DurationSecs: 200}
	for _, c := range []struct {
		name                 string
		privileges           builtinPrivileges
		cooling, enabled     bool
		only                 map[string]bool
		localHit             bool
		wantOffline, wantAsk int32
		wantLyrics, wantSkip bool
	}{
		{name: "有这一位、冷却、本机命中", privileges: privOfflineLeg, cooling: true, enabled: true, localHit: true, wantOffline: 1, wantLyrics: true},
		{name: "有这一位、冷却、本机没有", privileges: privOfflineLeg, cooling: true, enabled: true, wantOffline: 1, wantSkip: true},
		{name: "没有这一位、冷却", cooling: true, enabled: true, localHit: true, wantSkip: true},
		{name: "只有别的特权位、冷却", privileges: privLocalClientIdentity | privPlaybackTrackIDs, cooling: true, enabled: true, localHit: true, wantSkip: true},
		{name: "有这一位、没在冷却:照常问", privileges: privOfflineLeg, enabled: true, localHit: true, wantAsk: 1},
		{name: "有这一位、冷却、设置里关掉", privileges: privOfflineLeg, cooling: true, localHit: true},
		{name: "有这一位、冷却、别名轮名单外", privileges: privOfflineLeg, cooling: true, enabled: true, only: map[string]bool{"other": true}, localHit: true},
		{name: "有这一位、冷却、别名轮名单里", privileges: privOfflineLeg, cooling: true, enabled: true, only: map[string]bool{"stub": true}, localHit: true, wantOffline: 1, wantLyrics: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			stub := &offlineStubProvider{offline: func() (SourceResult, bool) {
				if c.localHit {
					return local, true
				}
				return SourceResult{lyr: "[00:01.00]没命中时不该被采用"}, false
			}}
			stub.desc = &ProviderDescriptor{Name: "stub", Privileges: c.privileges}
			_, round := withLyricSourceRound(context.Background())
			plan := lyricRoundPlan{only: c.only, enabled: func(string) bool { return c.enabled }, round: round}
			if c.cooling {
				plan.cooling = lyricSourceRoundPlan{"stub": time.Minute}
			}
			got := runLyricProvider(context.Background(), stub, q, RoundEnv{}, plan)
			if n := stub.offlineCalls.Load(); n != c.wantOffline {
				t.Errorf("ResolveOffline 被问了 %d 次,期望 %d 次", n, c.wantOffline)
			}
			if n := stub.calls.Load(); n != c.wantAsk {
				t.Errorf("Resolve 被问了 %d 次,期望 %d 次", n, c.wantAsk)
			}
			if c.wantOffline == 1 && stub.offlineQ != q {
				t.Errorf("交给 ResolveOffline 的查询 %+v,期望 %+v", stub.offlineQ, q)
			}
			want := SourceResult{source: "stub"}
			if c.wantLyrics {
				want.lyr, want.matchTitle = local.lyr, local.matchTitle
			}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("结果 %+v,期望 %+v", got, want)
			}
			if skipped := len(round.skippedSources()) > 0; skipped != c.wantSkip {
				t.Errorf("记没记跳过(%v)应是 %v", round.skippedSources(), c.wantSkip)
			}
		})
	}
	t.Run("有这一位、没实现 ResolveOffline:照冷却跳过记", func(t *testing.T) {
		stub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "stub", Privileges: privOfflineLeg}}
		_, round := withLyricSourceRound(context.Background())
		plan := lyricRoundPlan{enabled: func(string) bool { return true }, round: round, cooling: lyricSourceRoundPlan{"stub": time.Minute}}
		got := runLyricProvider(context.Background(), stub, q, RoundEnv{}, plan)
		if !reflect.DeepEqual(got, SourceResult{source: "stub"}) || stub.calls.Load() != 0 || len(round.skippedSources()) != 1 {
			t.Errorf("结果 %+v,Resolve %d 次,跳过 %v", got, stub.calls.Load(), round.skippedSources())
		}
	})
}

// 结果上的「身份由播放器本机数据给定」只认带 privLocalClientIdentity 的源交的:没有这一位的源交了也清掉,Resolve 和
// ResolveOffline 两个产出点都一样。
func TestLocalClientIdentityOnlyFromPrivilegedProviders(t *testing.T) {
	claimed := SourceResult{lyr: "[00:01.00]a", identityFromLocalClient: true, noVocals: true}
	for _, c := range []struct {
		name       string
		privileges builtinPrivileges
		cooling    bool
		want       bool
	}{
		{name: "照常问、有这一位", privileges: privLocalClientIdentity, want: true},
		{name: "照常问、没有特权位"},
		{name: "照常问、只有别的特权位", privileges: privOfflineLeg | privPlaybackTrackIDs | privPlayerNoVocals},
		{name: "冷却时读本机、有这一位", privileges: privOfflineLeg | privLocalClientIdentity, cooling: true, want: true},
		{name: "冷却时读本机、没有这一位", privileges: privOfflineLeg, cooling: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			stub := &offlineStubProvider{offline: func() (SourceResult, bool) { return claimed, true }}
			stub.desc = &ProviderDescriptor{Name: "stub", Privileges: c.privileges}
			stub.resolve = func() SourceResult { return claimed }
			plan := lyricRoundPlan{enabled: func(string) bool { return true }}
			if c.cooling {
				plan.cooling = lyricSourceRoundPlan{"stub": time.Minute}
			}
			got := runLyricProvider(context.Background(), stub, ProviderQuery{}, RoundEnv{}, plan)
			want := claimed
			want.source, want.identityFromLocalClient = "stub", c.want
			if !reflect.DeepEqual(got, want) {
				t.Errorf("结果 %+v,期望 %+v", got, want)
			}
		})
	}
}

// 环境里带特权的读取(播放侧记下的平台曲目编号、等在放的这首的 Apple 目录 id、播放器自己的无人声信号)按调度填的特权位
// 放行:没有对应那一位的源经调度拿到的环境读出来是零值,收集循环建的那份(还没交给任何源)也一样。
func TestRoundEnvPrivilegedReadsNeedPrivilege(t *testing.T) {
	withCleanPlaybackHints(t)
	withAppleNoVocalsWait(t, 2*time.Second)
	const artist, title, album = "原样歌手", "原样歌名", "原样专辑"
	notePlayingAppleCatalogID(artist, title, album, 4242)
	notePlayingSpotifyTrackID(artist, title, album, "sp4242")
	full := RoundEnv{ForPlayingTrack: true, identityArtist: artist, identityTitle: title, identityAlbum: album}
	ctx := context.Background()
	read := func(env RoundEnv, ctx context.Context) (apple, spotify, awaited string, signal bool) {
		apple, spotify = env.PlaybackTrackIDs(ctx)
		return apple, spotify, env.AwaitPlayingAppleCatalogID(ctx), env.PlayerNoVocalsSignalApplies()
	}
	if apple, spotify, awaited, signal := read(full, ctx); apple != "" || spotify != "" || awaited != "" || signal {
		t.Errorf("还没经调度交给源的环境不放行:%q %q %q %v", apple, spotify, awaited, signal)
	}
	for _, c := range []struct {
		name       string
		privileges builtinPrivileges
		wantIDs    bool
		wantSignal bool
	}{
		{name: "没有特权位"},
		{name: "只有不相干的位", privileges: privLocalClientIdentity | privOfflineLeg | privTrackIDPublish | privTrackIDConsume | privPeripheral | privBorrowFromPeers | privRefetchByID | privBreakerControl},
		{name: "读播放侧编号", privileges: privPlaybackTrackIDs, wantIDs: true},
		{name: "播放器无人声信号", privileges: privPlayerNoVocals, wantSignal: true},
		{name: "两位都有", privileges: privPlaybackTrackIDs | privPlayerNoVocals, wantIDs: true, wantSignal: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			enableOnlyLyricSources(t, "stub")
			stub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "stub", Privileges: c.privileges}}
			runLyricProvider(ctx, stub, ProviderQuery{}, full, newLyricRoundPlan(ctx, nil))
			if stub.calls.Load() != 1 {
				t.Fatalf("Resolve 应被问一次,实际 %d 次", stub.calls.Load())
			}
			start := time.Now()
			apple, spotify, awaited, signal := read(stub.gotEnv, ctx)
			wantApple, wantSpotify := "", ""
			if c.wantIDs {
				wantApple, wantSpotify = "4242", "sp4242"
			}
			if apple != wantApple || spotify != wantSpotify || awaited != wantApple || signal != c.wantSignal {
				t.Errorf("读到 apple=%q spotify=%q 等到=%q 信号=%v,期望 %q %q %q %v", apple, spotify, awaited, signal, wantApple, wantSpotify, wantApple, c.wantSignal)
			}
			// 别的歌那一轮,有这一位也不给(playbackTrackIDsForRound)。
			if apple, spotify := stub.gotEnv.PlaybackTrackIDs(withOtherTrackRound(ctx)); apple != "" || spotify != "" {
				t.Errorf("别的歌那一轮不该给播放侧编号:%q %q", apple, spotify)
			}
			// 没记过编号的另一首:没有这一位的源不等锚点,立刻拿到空串。
			other := stub.gotEnv
			other.identityTitle = "还没核对的曲目"
			if !c.wantIDs {
				if got := other.AwaitPlayingAppleCatalogID(ctx); got != "" || time.Since(start) > time.Second {
					t.Errorf("没有这一位不该等:%q,用时 %v", got, time.Since(start))
				}
			}
			noSignal := stub.gotEnv
			noSignal.ForPlayingTrack = false
			if noSignal.PlayerNoVocalsSignalApplies() {
				t.Error("不是在放的那首时,有这一位也没有信号")
			}
		})
	}
}

// 各源的 Resolve 不直接读播放侧编号、不直接判播放器信号能不能用:这几样只经 RoundEnv 的方法,特权位只由调度填。
func TestProviderPrivilegedReadsGoThroughRoundEnv(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	resolves, granters, grantWrites := 0, []string{}, []string{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(raw)
		if n := countCode(src, ".grantedTo("); n > 0 {
			granters = append(granters, f+":"+strings.Repeat("x", n))
		}
		if containsCode(src, ".granted = ") {
			grantWrites = append(grantWrites, f)
		}
		for rest := src; ; {
			i := strings.Index(rest, "Provider) Resolve(ctx context.Context, q ProviderQuery,")
			if i < 0 {
				break
			}
			rest = rest[i:]
			end := strings.Index(rest, "\n}\n")
			if end < 0 {
				t.Fatalf("%s 里有一个 Resolve 没有收尾", f)
			}
			body := rest[:end]
			rest = rest[end:]
			resolves++
			for _, direct := range []string{"playbackTrackIDsForRound", "playbackTrackIDsFor", "waitPlayingAppleCatalogID", "playerSignalApplies", "lyricIdentityFields", "playingPlayer"} {
				if regexp.MustCompile(`\b` + direct + `\(`).MatchString(body) {
					t.Errorf("%s 的 Resolve 直接调了 %s():这类读取只经 RoundEnv 的方法", f, direct)
				}
			}
		}
	}
	// 两段式适配器(twoStageProvider)不在内置登记表里:运行时登记的来源经它接进来,它的 Resolve 同样在上面扫过。
	if want := len(builtinLyricRegistry().providers) + 1; resolves != want {
		t.Errorf("扫到 %d 个 Resolve,该是登记的内置实现 %d 个加两段式适配器", resolves, want-1)
	}
	if len(granters) != 1 || granters[0] != "lyricproviderrun.go:x" {
		t.Errorf("环境的特权位只该由调度在 runLyricProvider 里填一次:%v", granters)
	}
	if len(grantWrites) != 1 || grantWrites[0] != "lyricprovider.go" {
		t.Errorf("granted 只该在 RoundEnv.grantedTo 里写:%v", grantWrites)
	}
	run := goFuncSource(t, "lyricproviderrun.go", "runLyricProvider")
	if !containsCode(run, "r := p.Resolve(ctx, q, env.grantedTo(d))") {
		t.Error("runLyricProvider 交给 Resolve 的环境要按这个源的描述符放行")
	}
}

// ---- 源之间递曲目编号、网易云顺带交的周边信息:同样按描述符的特权位放行。见 09 章决策 393。 ----

// trackIDBoardFor:一轮里这几个假源的递编号的地方,连同交给调度的那份环境。
func trackIDBoardFor(stubs ...*stubLyricProvider) RoundEnv {
	providers := make([]LyricProvider, 0, len(stubs))
	for _, s := range stubs {
		providers = append(providers, s)
	}
	return RoundEnv{trackIDs: newRoundTrackIDs(providers)}
}

// publishedTrackID:这一格递出来没有,递的是什么。不等。
func publishedTrackID(s *roundTrackID) (string, bool) {
	if s == nil {
		return "", false
	}
	select {
	case <-s.done:
		return s.id, true
	default:
		return "", false
	}
}

// 往外递曲目编号要 privTrackIDPublish:这一轮只给带这一位的源留格子;没有这一位的源调了 PublishTrackID 没有效果,
// 哪怕手上的环境里有别人的格子;收集循环建的那份环境(还没交给任何源)也递不出去。一格只有第一次递的算数。
func TestTrackIDPublishNeedsPrivilege(t *testing.T) {
	enabled := lyricRoundPlan{enabled: func(string) bool { return true }}
	ctx := context.Background()
	t.Run("带这一位的源在 Resolve 里递,先递的算数", func(t *testing.T) {
		pub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "pub", Privileges: privTrackIDPublish}}
		pub.resolve = func() SourceResult {
			pub.gotEnv.PublishTrackID("123")
			pub.gotEnv.PublishTrackID("456")
			return SourceResult{lyr: "[00:01.00]a"}
		}
		env := trackIDBoardFor(pub)
		got := runLyricProviderInRound(ctx, pub, ProviderQuery{}, env, enabled)
		if id, ok := publishedTrackID(env.trackIDs.slot("pub")); !ok || id != "123" || got.lyr == "" {
			t.Errorf("应递出 123:%q %v,结果 %+v", id, ok, got)
		}
	})
	t.Run("没有这一位的源这一轮没有格子,调了没有效果", func(t *testing.T) {
		pub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "pub", Privileges: privTrackIDPublish}}
		plain := &stubLyricProvider{desc: &ProviderDescriptor{Name: "plain", Privileges: privLocalClientIdentity | privPlaybackTrackIDs | privTrackIDConsume | privPeripheral}}
		plain.resolve = func() SourceResult {
			plain.gotEnv.PublishTrackID("999")
			return SourceResult{}
		}
		env := trackIDBoardFor(pub, plain)
		runLyricProviderInRound(ctx, plain, ProviderQuery{}, env, enabled)
		if env.trackIDs.slot("plain") != nil || plain.gotEnv.ownTrackID != nil {
			t.Error("没有 privTrackIDPublish 的源不该有格子")
		}
		if id, ok := publishedTrackID(env.trackIDs.slot("pub")); ok {
			t.Errorf("别人的格子不该被它递进去:%q", id)
		}
	})
	t.Run("手上有格子、没有这一位:照样递不出去", func(t *testing.T) {
		pub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "pub", Privileges: privTrackIDPublish}}
		env := trackIDBoardFor(pub)
		for _, privileges := range []builtinPrivileges{0, privTrackIDConsume | privPeripheral | privLocalClientIdentity} {
			forged := env.grantedTo(&ProviderDescriptor{Name: "pub", Privileges: privileges})
			if forged.ownTrackID == nil {
				t.Fatal("这个用例要的是手上有格子")
			}
			forged.PublishTrackID("999")
		}
		env.PublishTrackID("999")
		if id, ok := publishedTrackID(env.trackIDs.slot("pub")); ok {
			t.Errorf("没有 privTrackIDPublish 不该递得出去:%q", id)
		}
		env.grantedTo(pub.desc).PublishTrackID("123")
		if id, ok := publishedTrackID(env.trackIDs.slot("pub")); !ok || id != "123" {
			t.Errorf("带这一位的应递得出去:%q %v", id, ok)
		}
	})
	t.Run("这一轮没有递编号的地方:调了不出错", func(t *testing.T) {
		RoundEnv{}.grantedTo(&ProviderDescriptor{Name: "pub", Privileges: privTrackIDPublish}).PublishTrackID("123")
	})
}

// 往外递编号的源不管这一轮问没问它、Resolve 里递没递,交结果之前一定递过:被跳过的(设置里关掉、别名轮名单外、
// 这种轮次不问、熔断冷却)和没递就返回的由调度代递空串。漏了这一步,等它编号的源会挂到这一轮截止。
func TestSkippedPublisherStillPublishesEmptyTrackID(t *testing.T) {
	for _, c := range []struct {
		name    string
		plan    func(round *lyricSourceRound) lyricRoundPlan
		rounds  RoundPolicy
		resolve func(p *stubLyricProvider) SourceResult
		wantAsk int32
		wantID  string
	}{
		{name: "设置里关掉", plan: func(*lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{enabled: func(string) bool { return false }}
		}},
		{name: "别名轮名单外", plan: func(*lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{only: map[string]bool{"other": true}, enabled: func(string) bool { return true }}
		}},
		{name: "这种轮次不问它", rounds: roundsOnDemand, plan: func(*lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{enabled: func(string) bool { return true }}
		}},
		{name: "熔断冷却中", plan: func(round *lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{enabled: func(string) bool { return true }, cooling: lyricSourceRoundPlan{"pub": time.Minute}, round: round}
		}},
		{name: "问了、Resolve 里没递", wantAsk: 1, plan: func(*lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{enabled: func(string) bool { return true }}
		}},
		{name: "问了、Resolve 里递了:代递的空串不盖掉它", wantAsk: 1, wantID: "123",
			plan: func(*lyricSourceRound) lyricRoundPlan {
				return lyricRoundPlan{enabled: func(string) bool { return true }}
			},
			resolve: func(p *stubLyricProvider) SourceResult {
				p.gotEnv.PublishTrackID("123")
				return SourceResult{}
			}},
	} {
		t.Run(c.name, func(t *testing.T) {
			pub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "pub", Rounds: c.rounds, Privileges: privTrackIDPublish}}
			if c.resolve != nil {
				pub.resolve = func() SourceResult { return c.resolve(pub) }
			}
			env := trackIDBoardFor(pub)
			_, round := withLyricSourceRound(context.Background())
			got := runLyricProviderInRound(context.Background(), pub, ProviderQuery{}, env, c.plan(round))
			if got.source != "pub" || pub.calls.Load() != c.wantAsk {
				t.Errorf("结果 %+v,Resolve 被问了 %d 次,期望 %d 次", got, pub.calls.Load(), c.wantAsk)
			}
			if id, ok := publishedTrackID(env.trackIDs.slot("pub")); !ok || id != c.wantID {
				t.Errorf("返回时应已递出 %q:%q 递了=%v", c.wantID, id, ok)
			}
		})
	}
}

// 编号在 Resolve 中途递出去就能被等的一方拿到,不用等 Resolve 返回(QQ 认出这首之后还要取词,amll 只要 songmid)。
func TestTrackIDPublishedBeforeResolveReturns(t *testing.T) {
	release, returned := make(chan struct{}), make(chan SourceResult, 1)
	pub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "pub", Privileges: privTrackIDPublish}}
	pub.resolve = func() SourceResult {
		pub.gotEnv.PublishTrackID("123")
		<-release
		return SourceResult{lyr: "[00:01.00]取完词才返回"}
	}
	env := trackIDBoardFor(pub)
	go func() {
		returned <- runLyricProviderInRound(context.Background(), pub, ProviderQuery{}, env, lyricRoundPlan{enabled: func(string) bool { return true }})
	}()
	got := make(chan string, 1)
	go func() { got <- env.trackIDs.slot("pub").await() }()
	select {
	case id := <-got:
		if id != "123" {
			t.Errorf("等到的编号 %q", id)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("Resolve 还没返回时等不到它中途递出来的编号")
	}
	select {
	case r := <-returned:
		t.Fatalf("Resolve 还挂着,不该已经交了结果:%+v", r)
	default:
	}
	close(release)
	select {
	case r := <-returned:
		if r.lyr == "" {
			t.Errorf("结果 %+v", r)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("放行后没交结果")
	}
}

// 网易云那份结果(ne)里顺带交的封面、平台链接、规范歌手名只收带 privPeripheral 的源交的;「身份由播放器本机数据给定」
// 在 ne 上的那一位(FromLocalClient)同 identityFromLocalClient,只认带 privLocalClientIdentity 的源交的。歌词、曲目
// id 这些不受这两位管。
func TestPeripheralAndNeteaseLocalIdentityOnlyFromPrivilegedProviders(t *testing.T) {
	claimed := SourceResult{ne: neteaseInfo{
		Cover: "https://p1.music.126.net/x.jpg", SongURL: "https://music.163.com/song?id=1", Artist: "规范歌手名",
		Lyrics: "[00:01.00]a", Title: "歌名", Album: "专辑", SongID: 1, AlbumID: 2, DurationSecs: 200, FromLocalClient: true, NoVocals: true,
	}}
	for _, c := range []struct {
		name                      string
		privileges                builtinPrivileges
		wantPeripheral, wantLocal bool
	}{
		{name: "两位都有", privileges: privPeripheral | privLocalClientIdentity, wantPeripheral: true, wantLocal: true},
		{name: "只有周边信息", privileges: privPeripheral, wantPeripheral: true},
		{name: "只有本机身份", privileges: privLocalClientIdentity, wantLocal: true},
		{name: "没有特权位"},
		{name: "只有不相干的位", privileges: privTrackIDPublish | privTrackIDConsume | privPlaybackTrackIDs | privPlayerNoVocals | privOfflineLeg | privBorrowFromPeers | privRefetchByID | privBreakerControl},
	} {
		t.Run(c.name, func(t *testing.T) {
			stub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "stub", Privileges: c.privileges}, resolve: func() SourceResult { return claimed }}
			got := runLyricProvider(context.Background(), stub, ProviderQuery{}, RoundEnv{}, lyricRoundPlan{enabled: func(string) bool { return true }})
			want := claimed
			want.source = "stub"
			if !c.wantPeripheral {
				want.ne.Cover, want.ne.SongURL, want.ne.Artist = "", "", ""
			}
			want.ne.FromLocalClient = c.wantLocal
			if !reflect.DeepEqual(got, want) {
				t.Errorf("结果 %+v\n期望 %+v", got.ne, want.ne)
			}
		})
	}
}

// 递编号只经调度和 RoundEnv:格子只在起这一轮的源时建(startLyricProviders)、不交到调度外面,各源的 goroutine 走
// runLyricProviderInRound(它先替等编号的源等齐、兜底代递空串),往格子里写只有 PublishTrackID 和那一处兜底,从格子里等
// 只有 TrackIDFrom 和调度那一处,「自己的格子」只在 grantedTo 里填。
func TestTrackIDsOnlyTravelThroughScheduler(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	where := map[string][]string{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(raw)
		for _, needle := range []string{".publish(", ".await()", "newRoundTrackIDs(", ".ownTrackID = ", "runLyricProviderInRound(", "&roundTrackID{", "*roundTrackIDs {"} {
			if n := countCode(src, needle); n > 0 {
				where[needle] = append(where[needle], fmt.Sprintf("%s×%d", f, n))
			}
		}
	}
	for needle, want := range map[string][]string{
		".publish(":                {"lyricprovider.go×1", "lyricproviderrun.go×1"},
		".await()":                 {"lyricprovider.go×1", "lyricproviderrun.go×1"},
		"*roundTrackIDs {":         {"lyricprovider.go×1"},
		"newRoundTrackIDs(":        {"lyricprovider.go×1", "lyricproviderrun.go×1"},
		".ownTrackID = ":           {"lyricprovider.go×1"},
		"runLyricProviderInRound(": {"lyricproviderrun.go×2"},
		"&roundTrackID{":           {"lyricprovider.go×1"},
	} {
		if !reflect.DeepEqual(where[needle], want) {
			t.Errorf("%q 出现在 %v,应只在 %v", needle, where[needle], want)
		}
	}
	run := string(mustRead(t, "lyricproviderrun.go"))
	for _, n := range []string{
		"env.trackIDs = newRoundTrackIDs(providers)\n\tvar local []LyricProvider\n\tfor _, p := range providers {\n\t\tif p.Descriptor().Kind != providerKindNetwork {\n\t\t\tlocal = append(local, p)\n\t\t\tcontinue\n\t\t}\n\t\tgo func() { out <- runLyricProviderInRound(ctx, p, q, env, plan) }()\n\t}\n\treturn runLocalLyricProviders(ctx, local, q, env, plan)",
		"d := p.Descriptor()\n\tfor _, from := range d.DependsOnIDsFrom {\n\t\tenv.trackIDs.slot(from).await()\n\t}\n\tdefer env.trackIDs.slot(d.Name).publish(\"\")\n\treturn runLyricProvider(ctx, p, q, env, plan)",
	} {
		if !containsCode(run, n) {
			t.Errorf("lyricproviderrun.go 缺 %q", n)
		}
	}
	provider := string(mustRead(t, "lyricprovider.go"))
	for _, n := range []string{
		"if !e.granted.has(privTrackIDPublish) {\n\t\treturn\n\t}\n\te.ownTrackID.publish(id)",
		"if !e.granted.has(privTrackIDConsume) {\n\t\treturn \"\"\n\t}\n\treturn e.trackIDs.slot(source).await()",
		"e.ownTrackID = e.trackIDs.slot(d.Name)",
		"if d := p.Descriptor(); d.Privileges.has(privTrackIDPublish) {\n\t\t\tb.slots[d.Name] = &roundTrackID{done: make(chan struct{})}",
	} {
		if !containsCode(provider, n) {
			t.Errorf("lyricprovider.go 缺 %q", n)
		}
	}
}

// 等别的源递来的编号要 privTrackIDConsume:没有这一位的源不等、拿到空串,收集循环建的那份环境(还没交给任何源)也一样。
// 要等的那个源这一轮没起、或者它不往外递编号时,带这一位的也不等,立刻拿到空串。
func TestTrackIDConsumeNeedsPrivilege(t *testing.T) {
	pub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "pub", Privileges: privTrackIDPublish}}
	silent := &stubLyricProvider{desc: &ProviderDescriptor{Name: "silent", Privileges: privTrackIDPublish}}
	plain := &stubLyricProvider{desc: &ProviderDescriptor{Name: "plain"}}
	env := trackIDBoardFor(pub, silent, plain)
	env.grantedTo(pub.desc).PublishTrackID("123")
	// read:在限定时间里读一次;挂住了(在等一个没人递的格子)返回 ok=false。
	read := func(e RoundEnv, source string) (id string, ok bool) {
		got := make(chan string, 1)
		go func() { got <- e.TrackIDFrom(source) }()
		select {
		case id := <-got:
			return id, true
		case <-time.After(4 * time.Second):
			return "", false
		}
	}
	for _, c := range []struct {
		name       string
		privileges builtinPrivileges
		want       string
	}{
		{name: "带这一位", privileges: privTrackIDConsume, want: "123"},
		{name: "没有特权位"},
		{name: "只有不相干的位", privileges: privTrackIDPublish | privPlaybackTrackIDs | privLocalClientIdentity | privPeripheral | privBorrowFromPeers | privRefetchByID},
	} {
		t.Run(c.name, func(t *testing.T) {
			granted := env.grantedTo(&ProviderDescriptor{Name: "consumer", Privileges: c.privileges})
			if id, ok := read(granted, "pub"); !ok || id != c.want {
				t.Errorf("读到 %q(读完=%v),期望 %q", id, ok, c.want)
			}
			if c.privileges.has(privTrackIDConsume) {
				return
			}
			// 没有这一位:对着一个还没人递的格子也不等。
			if id, ok := read(granted, "silent"); !ok || id != "" {
				t.Errorf("没有 privTrackIDConsume 不该等:%q 读完=%v", id, ok)
			}
		})
	}
	consumer := env.grantedTo(&ProviderDescriptor{Name: "consumer", Privileges: privTrackIDConsume})
	for _, source := range []string{"plain", "not-started-this-round"} {
		if id, ok := read(consumer, source); !ok || id != "" {
			t.Errorf("%s 这一轮没有格子,应立刻拿到空串:%q 读完=%v", source, id, ok)
		}
	}
	if id, ok := read(env, "pub"); !ok || id != "" {
		t.Errorf("还没交给源的环境不放行:%q 读完=%v", id, ok)
	}
	if id, ok := read(RoundEnv{}.grantedTo(&ProviderDescriptor{Name: "consumer", Privileges: privTrackIDConsume}), "pub"); !ok || id != "" {
		t.Errorf("这一轮没有递编号的地方时应立刻拿到空串:%q 读完=%v", id, ok)
	}
}

// waitGoroutineParkedIn 等到有 goroutine 在名字里带 frame 的函数里阻塞着等通道(只是路过这个函数、还没停下的不算)。
func waitGoroutineParkedIn(t *testing.T, frame string) {
	t.Helper()
	buf := make([]byte, 8<<20)
	for deadline := time.Now().Add(4 * time.Second); ; time.Sleep(time.Millisecond) {
		for _, g := range bytes.Split(buf[:runtime.Stack(buf, true)], []byte("\n\n")) {
			header, _, _ := bytes.Cut(g, []byte("\n"))
			if bytes.Contains(header, []byte("[chan receive")) && bytes.Contains(g, []byte(frame)) {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("4 秒里没有 goroutine 停在 %s 里", frame)
		}
	}
}

// 等别的源递编号的源(描述符的 DependsOnIDsFrom)先把那几个编号都等齐,再判这一轮问不问它:照常问的、设置里关掉的、别名轮
// 名单外的、熔断冷却的都一样,还差一个编号没递出来的时候它没被问、没交结果、没记跳过;都递出来之后才各走各的。
func TestTrackIDConsumerWaitsBeforeItsRoundIsDecided(t *testing.T) {
	for _, c := range []struct {
		name     string
		plan     func(round *lyricSourceRound) lyricRoundPlan
		wantAsk  bool
		wantSkip bool
	}{
		{name: "照常问", wantAsk: true, plan: func(*lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{enabled: func(string) bool { return true }}
		}},
		{name: "设置里关掉", plan: func(*lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{enabled: func(source string) bool { return source != "consumer" }}
		}},
		{name: "别名轮名单外", plan: func(*lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{only: map[string]bool{"quick": true, "slow": true}, enabled: func(string) bool { return true }}
		}},
		{name: "熔断冷却中", wantSkip: true, plan: func(round *lyricSourceRound) lyricRoundPlan {
			return lyricRoundPlan{enabled: func(string) bool { return true }, cooling: lyricSourceRoundPlan{"consumer": time.Minute}, round: round}
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			release := make(chan struct{})
			quick := &stubLyricProvider{desc: &ProviderDescriptor{Name: "quick", Privileges: privTrackIDPublish}}
			quick.resolve = func() SourceResult {
				quick.gotEnv.PublishTrackID("q1")
				return SourceResult{}
			}
			slow := &stubLyricProvider{desc: &ProviderDescriptor{Name: "slow", Privileges: privTrackIDPublish}}
			slow.resolve = func() SourceResult {
				<-release
				slow.gotEnv.PublishTrackID("s2")
				return SourceResult{}
			}
			var gotIDs atomic.Value
			consumer := &stubLyricProvider{desc: &ProviderDescriptor{Name: "consumer", Privileges: privTrackIDConsume, DependsOnIDsFrom: []string{"quick", "slow"}}}
			consumer.resolve = func() SourceResult {
				gotIDs.Store(consumer.gotEnv.TrackIDFrom("quick") + "+" + consumer.gotEnv.TrackIDFrom("slow"))
				return SourceResult{}
			}
			_, round := withLyricSourceRound(context.Background())
			out := make(chan SourceResult, 3)
			startLyricProviders(context.Background(), []LyricProvider{quick, slow, consumer}, ProviderQuery{}, RoundEnv{}, c.plan(round), out)
			// 先收到快的那个源的结果(它的编号已经递出来),再等到有 goroutine 停在等编号里:那只能是在等慢的那个。
			select {
			case r := <-out:
				if r.source != "quick" {
					t.Fatalf("慢的那个源还没放行,先到的应是 quick,得到 %q", r.source)
				}
			case <-time.After(4 * time.Second):
				t.Fatal("quick 没交结果")
			}
			waitGoroutineParkedIn(t, "(*roundTrackID).await")
			if consumer.calls.Load() != 0 || len(out) != 0 || len(round.skippedSources()) != 0 {
				t.Errorf("还差一个编号没递出来:不该已经问了它(%d 次)、交了结果(%d 份)或记了跳过(%v)", consumer.calls.Load(), len(out), round.skippedSources())
			}
			close(release)
			var names []string
			for range 2 {
				select {
				case r := <-out:
					names = append(names, r.source)
				case <-time.After(4 * time.Second):
					t.Fatalf("只收到 %v", names)
				}
			}
			if asked := consumer.calls.Load() == 1; asked != c.wantAsk {
				t.Errorf("问没问它(%v)应是 %v", asked, c.wantAsk)
			}
			if ids, _ := gotIDs.Load().(string); c.wantAsk && ids != "q1+s2" {
				t.Errorf("它等到的编号 %q", ids)
			}
			if skipped := len(round.skippedSources()) == 1; skipped != c.wantSkip {
				t.Errorf("记没记跳过(%v)应是 %v", round.skippedSources(), c.wantSkip)
			}
		})
	}
}
