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
func runLyricProvider(ctx context.Context, p LyricProvider, q ProviderQuery, env RoundEnv, plan lyricRoundPlan) SourceResult {
	d := p.Descriptor()
	switch plan.decide(d) {
	case providerRoundSkipSilent:
		return SourceResult{source: d.Name}
	case providerRoundSkipCooling:
		plan.round.markSkippedBecause(d.Name, sharedLyricSourceBreaker().cooldownReason(d.Name))
		log.Printf("lyrics: source %s skipped this round, cooling down for another %s", d.Name, plan.cooling[d.Name].Round(time.Second))
		return SourceResult{source: d.Name}
	}
	r := p.Resolve(ctx, q, env)
	r.source = d.Name
	return r
}

// startLyricProviders 给每个源起一个 goroutine,各往 out 送一份结果。out 的缓冲必须放得下每个源各一份:
// 收集循环到截止或被取消后不再读 out,晚到的结果要能不阻塞地送进去。
func startLyricProviders(ctx context.Context, providers []LyricProvider, q ProviderQuery, env RoundEnv, plan lyricRoundPlan, out chan<- SourceResult) {
	for _, p := range providers {
		go func() { out <- runLyricProvider(ctx, p, q, env, plan) }()
	}
}
