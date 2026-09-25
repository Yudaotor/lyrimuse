package main

import (
	"context"
	"errors"
)

// ---- 其余歌词源的备用地址 ----
//
// QQ / 网易云 / 酷狗各有自己的文件(qqfallback.go / neteasefallback.go / kugoufallback.go),
// 其余几个源的备用都是「同一个接口换一个主机或协议」,集中在这里。规矩跟那三个一样:只有没问成
// (传输失败 / 非 200 / 解不开 / 拒绝码)才换下一个,接口正常答了(包括查无结果)就停。
//
//   - 酷我:搜索 https → http;歌词 kuwo.cn → www.kuwo.cn → http://kuwo.cn(Referer 跟着主机走)
//   - 咪咕:搜索与专辑信息都在 pd.musicapp / app.c.nf / c.musicapp 三个主机上
//   - 汽水:歌词 beta-luna.douyin.com → api.qishui.com(同一个 /luna/h5/seo_track)
//   - YouTube Music:music.youtube.com → youtubei.googleapis.com → www.youtube.com(同一套 InnerTube)
//   - AMLL:raw.githubusercontent.com → jsDelivr 的两个镜像;404 是「库里没有这首」,不换镜像
//
// 没有备用的:lrclib(只有 lrclib.net 一个公共实例)、Deezer(api / pipe / auth 各只有一个主机)、
// Musixmatch(另一组 host + app_id 只给全零的占位 token)、Apple Music(amp-api 只有一个,还要登录)。
//
// 主机都逐个实测过,实测记录见 docs/features/09 第 90 条。

var (
	kuwoSearchBases = []string{"https://search.kuwo.cn", "http://search.kuwo.cn"}
	kuwoLyricBases  = []string{"https://kuwo.cn", "https://www.kuwo.cn", "http://kuwo.cn"}
	miguSearchHosts = []string{"pd.musicapp.migu.cn", "app.c.nf.migu.cn", "c.musicapp.migu.cn"}
	miguAlbumHosts  = []string{"app.c.nf.migu.cn", "pd.musicapp.migu.cn", "c.musicapp.migu.cn"}
	sodaSeoHosts    = []string{sodaSeoTrackHost, sodaSearchHost}
	ytmusicAPIBases = []string{ytmusicDomain, "https://youtubei.googleapis.com", "https://www.youtube.com"}
	amllBases       = []string{
		amllRawBase,
		"https://cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main",
		"https://fastly.jsdelivr.net/gh/amll-dev/amll-ttml-db@main",
	}
)

// errSourceNotReached:这次没问成(不是「查无」)。
var errSourceNotReached = errors.New("source: not reached")

// tryEach 按顺序对每个候选 i 调 try,第一个返回 nil 的就停;全部失败返回最后一个错误。ctx 已取消
// 时不再试下一个。try 只在没问成时返回错误。
func tryEach[T any](ctx context.Context, candidates []T, try func(c T) error) error {
	lastErr := errSourceNotReached
	for _, c := range candidates {
		err := try(c)
		if err == nil {
			return nil
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	return lastErr
}
