package main

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
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
			for _, direct := range []string{"playbackTrackIDsForRound", "playbackTrackIDsFor", "waitPlayingAppleCatalogID", "playerSignalApplies", "lyricIdentityFields"} {
				if regexp.MustCompile(`\b` + direct + `\(`).MatchString(body) {
					t.Errorf("%s 的 Resolve 直接调了 %s():这类读取只经 RoundEnv 的方法", f, direct)
				}
			}
		}
	}
	if resolves != len(lyricProviders().providers) {
		t.Errorf("扫到 %d 个 Resolve,登记的实现有 %d 个", resolves, len(lyricProviders().providers))
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
