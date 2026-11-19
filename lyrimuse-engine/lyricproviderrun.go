package main

import (
	"context"
	"log"
	"time"
)

// 接到 LyricProvider 上的源怎么起、这一轮问不问它。见 09 章决策 390。

// lyricRoundPlan 是调度判「这一轮问不问这个源」要看的东西,一轮开搜时拍一次。
type lyricRoundPlan struct {
	// only:别名轮「只查这些源」的名单(withLyricSourceOnly),nil = 不限。
	only map[string]bool
	// onDemand:这一轮是为用户此刻在听、在找的那首问的(isOnDemandLyricRound)。
	onDemand bool
	// enabled:这个源在设置里开着没有。
	enabled func(source string) bool
	// cooling:这一轮在熔断冷却里的源和各自还要冷却多久(lyricSourceBreaker.planRound)。
	cooling lyricSourceRoundPlan
	// round:记这一轮被冷却跳过的源,nil 时不记。
	round *lyricSourceRound
}

func newLyricRoundPlan(ctx context.Context, cooling lyricSourceRoundPlan) lyricRoundPlan {
	return lyricRoundPlan{
		only: lyricSourceOnlyFrom(ctx), onDemand: isOnDemandLyricRound(ctx), enabled: lyricSourceEnabled,
		cooling: cooling, round: lyricSourceRoundFrom(ctx),
	}
}

// providerRoundDecision:这一轮对一个源的处置。
type providerRoundDecision int

const (
	// providerRoundQuery:照常问。
	providerRoundQuery providerRoundDecision = iota
	// providerRoundSkipSilent:不发请求、不记跳过、不打日志(别名轮名单外、这种轮次不问它、设置里关掉了)。
	providerRoundSkipSilent
	// providerRoundSkipCooling:熔断冷却中,不发请求,记进这一轮的跳过名单。
	providerRoundSkipCooling
)

// decide 的判据和先后同 lyricSourceSkippedThisRound:名单外、轮次不许、关掉都先于冷却,一个既关掉又在冷却的源不记跳过。
func (p lyricRoundPlan) decide(d *ProviderDescriptor) providerRoundDecision {
	if p.only != nil && !p.only[d.Name] {
		return providerRoundSkipSilent
	}
	if d.Rounds == roundsOnDemand && !p.onDemand {
		return providerRoundSkipSilent
	}
	switch lyricSourceSkipFor(d.Name, p.enabled, p.cooling) {
	case lyricSourceSkipDisabled:
		return providerRoundSkipSilent
	case lyricSourceSkipCooling:
		return providerRoundSkipCooling
	}
	return providerRoundQuery
}

// runLyricProvider 问一个源一轮,不管问没问都恰好交回一份结果,源名是描述符里的名字。被跳过的交只带源名的空结果:
// 收集循环按源名数「都回来了没有」,少交一份这一轮就会等到截止。ctx 原样传给 Resolve,循环返回时靠它取消还在飞的请求。
// 熔断冷却的那一轮,带 privOfflineLeg 的源仍读本机那一份(offlineLegResult):本机命中算这一轮它答了,不记跳过;
// 名单外、关掉的源本机那份也不读。交给 Resolve 的环境按描述符的特权位放行(RoundEnv.grantedTo)。
func runLyricProvider(ctx context.Context, p LyricProvider, q ProviderQuery, env RoundEnv, plan lyricRoundPlan) SourceResult {
	d := p.Descriptor()
	switch plan.decide(d) {
	case providerRoundSkipSilent:
		return SourceResult{source: d.Name}
	case providerRoundSkipCooling:
		if r, ok := offlineLegResult(p, d, q); ok {
			return r
		}
		plan.round.markSkippedBecause(d.Name, sharedLyricSourceBreaker().cooldownReason(d.Name))
		log.Printf("lyrics: source %s skipped this round, cooling down for another %s", d.Name, plan.cooling[d.Name].Round(time.Second))
		return SourceResult{source: d.Name}
	}
	r := p.Resolve(ctx, q, env.grantedTo(d))
	return sealProviderResult(d, r)
}

// offlineLegResult:描述符带 privOfflineLeg 的源读客户端下在本机的那一份(OfflineResolver),不发请求。没有这一位的源
// 不问,实现了 OfflineResolver 也一样。见 09 章决策 392。
func offlineLegResult(p LyricProvider, d *ProviderDescriptor, q ProviderQuery) (SourceResult, bool) {
	if !d.Privileges.has(privOfflineLeg) {
		return SourceResult{}, false
	}
	offline, ok := p.(OfflineResolver)
	if !ok {
		return SourceResult{}, false
	}
	r, ok := offline.ResolveOffline(q)
	if !ok {
		return SourceResult{}, false
	}
	return sealProviderResult(d, r), true
}

// sealProviderResult:源交回的结果进收集循环之前,源名按描述符填;没有 privLocalClientIdentity 的源交的结果不算
// 「身份由播放器本机数据给定」(两处:identityFromLocalClient 和 ne.FromLocalClient);没有 privPeripheral 的源顺带交的
// 封面、平台链接、规范歌手名(ne.Cover / ne.SongURL / ne.Artist)不收。
func sealProviderResult(d *ProviderDescriptor, r SourceResult) SourceResult {
	r.source = d.Name
	if !d.Privileges.has(privLocalClientIdentity) {
		r.identityFromLocalClient, r.ne.FromLocalClient = false, false
	}
	if !d.Privileges.has(privPeripheral) {
		r.ne.Cover, r.ne.SongURL, r.ne.Artist = "", "", ""
	}
	return r
}

// startLyricProviders 给每个源起一个 goroutine,各往 out 送一份结果。out 的缓冲必须放得下每个源各一份:
// 收集循环到截止或被取消后不再读 out,晚到的结果要能不阻塞地送进去。这一轮源之间递曲目编号的地方在这里建,
// 返回给还没接到调度上、要等编号的调用方。
func startLyricProviders(ctx context.Context, providers []LyricProvider, q ProviderQuery, env RoundEnv, plan lyricRoundPlan, out chan<- SourceResult) *roundTrackIDs {
	env.trackIDs = newRoundTrackIDs(providers)
	for _, p := range providers {
		go func() { out <- runLyricProviderInRound(ctx, p, q, env, plan) }()
	}
	return env.trackIDs
}

// runLyricProviderInRound 是一个源在一轮里的那一趟:runLyricProvider 之外管源之间递曲目编号的先后。往外递编号的源
// (这一轮有它的一格)返回之前一定递过:被跳过的、Resolve 里没递的,在这里代递空串,先于交结果;漏了这一步,等它的源会
// 挂到这一轮截止。源在 Resolve 中途递出去的编号先到先算,这里只兜没递的。见 09 章决策 393。
func runLyricProviderInRound(ctx context.Context, p LyricProvider, q ProviderQuery, env RoundEnv, plan lyricRoundPlan) SourceResult {
	defer env.trackIDs.slot(p.Descriptor().Name).publish("")
	return runLyricProvider(ctx, p, q, env, plan)
}
