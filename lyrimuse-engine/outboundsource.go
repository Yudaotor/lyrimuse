package main

import (
	"context"
	"net/http"
)

// 出站请求的归源:这个请求算在哪个歌词源名下。doHTTPTracked 入口算一次(withOutboundSource),挂在请求的 ctx 上;出站这一层
// 按源记账的地方都经 outboundSourceFor 读同一个结果:在途名额、小时额度、每日额度、出站闸里按源的冷却与排队拦截、这一轮
// 连上过哪个源、后台暂停与限速应答认不认它是歌词源的请求、请求合并、代理回退。
//
// 规则:ctx 上有显式的源标签就归给标签(发往哪个主机都一样),没有就按请求主机归(lyricSourceOwningHost,描述符的
// Hosts),都没有是空串,不属于任何歌词源。内置源和调度不打标签,一律按主机归:一个源借别家的接口时,请求归给主机的主人。
//
// 按主机记的状态不读这里:熔断器的失败与成功记在主机的主人头上(sourcebreaker.go),后台暂停、令牌桶、接口熔断的状态
// 按实际主机 / 端点记(hostguard.go),审计汇总按主机的主人分组(networkobs.go)。见 09 章决策 397。

type outboundOriginKey struct{}

// outboundOrigin 是挂在 ctx 上的归源结果。
type outboundOrigin struct {
	// source:归到的源名;空串 = 不属于任何歌词源。
	source string
	// tagged:source 是显式标的,发往哪个主机都算数。false 时 source 是按 host 归出来的,只对这个主机算数。
	tagged bool
	// host:按主机归的那一份是为哪个主机算的(guardHost 的写法)。
	host string
}

func outboundOriginFrom(ctx context.Context) *outboundOrigin {
	o, _ := ctx.Value(outboundOriginKey{}).(*outboundOrigin)
	return o
}

// covers:这份结果对发往 host 的请求算不算数。
func (o *outboundOrigin) covers(host string) bool {
	return o != nil && (o.tagged || o.host == host)
}

// withOutboundSource 算出 req 的归源,挂到它的 ctx 上。ctx 上已经有对这个请求算数的结果(显式标签,或同一个主机算过的)时
// 原样返回。
func withOutboundSource(req *http.Request) *http.Request {
	ctx, host := req.Context(), guardHost(req.URL)
	if outboundOriginFrom(ctx).covers(host) {
		return req
	}
	o := &outboundOrigin{source: lyricSourceOwningHost(host), host: host}
	return req.WithContext(context.WithValue(ctx, outboundOriginKey{}, o))
}

// outboundSourceFor:ctx 上发往 host(guardHost 的写法:小写、不带端口)的请求归哪个源。ctx 上挂着对它算数的结果就读那一份;
// 没挂(没经 doHTTPTracked 的调用方)、或者是为别的主机算的(跟随重定向跳到了另一个主机)时,按主机现归。
func outboundSourceFor(ctx context.Context, host string) string {
	if o := outboundOriginFrom(ctx); o.covers(host) {
		return o.source
	}
	return lyricSourceOwningHost(host)
}
