package main

import (
	"context"
	"reflect"
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
