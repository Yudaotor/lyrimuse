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
//   - 酷我:搜索 search.kuwo.cn/r.s(https → http)→ kuwo.cn / www.kuwo.cn 的 /search/searchMusicBykeyWord(同一套参数、
//     同一份 JSON);逐行歌词 kuwo.cn → www.kuwo.cn → http://kuwo.cn(Referer 跟着主机走),都没问成再退到
//     mlyric.kuwo.cn 的 lrcx=0(kuwolrcx.go kuwoFetchMobiLRC)
//   - 咪咕:搜索与专辑信息都在 pd.musicapp / app.c.nf / c.musicapp 三个主机上;搜索三个主机都没问成再问 jadeite 的
//     另一套搜索服务(migu.go miguJadeiteSearch);歌词文件 https 没取到按 http 再取一次(miguFetchFile)
//   - 汽水:搜索 api.qishui.com → beta-luna.douyin.com(同一个 /luna/search/track);歌词 beta-luna.douyin.com →
//     api.qishui.com(同一个 /luna/h5/seo_track),两个都没问成或应答认不出形状时取曲目分享页(soda.go sodaFetchSharePage)
//   - YouTube Music:music.youtube.com → youtubei.googleapis.com → www.youtube.com(同一套 InnerTube)
//   - AMLL:raw.githubusercontent.com → jsDelivr 的两个镜像;404 是「库里没有这首」,不换镜像
//   - Musixmatch:apic-appmobile → apic(同一个 app_id,token 互认,同一请求答的内容一致)。换不换、先问哪个
//     见 musixmatchDo;答了 captcha 不换,token.get 的限流按 IP 算,两个主机共用
//
// 没有备用的:lrclib(只有 lrclib.net 一个公共实例)、Deezer(api / pipe / auth 各只有一个主机)、
// Apple Music(amp-api 只有一个,还要登录)。Musixmatch 的 apic-desktop 不能当备用:换 token 只给全零的占位值,
// macro 答 200 却是诱饵数据。
//
// 主机都逐个实测过,实测记录见 docs/features/09 第 90 条;Musixmatch 的备用主机见第 135 条。

var (
	kuwoSearchEndpoints = []string{
		"https://search.kuwo.cn/r.s", "http://search.kuwo.cn/r.s",
		"https://kuwo.cn/search/searchMusicBykeyWord", "https://www.kuwo.cn/search/searchMusicBykeyWord",
	}
	kuwoLyricBases  = []string{"https://kuwo.cn", "https://www.kuwo.cn", "http://kuwo.cn"}
	miguSearchHosts = []string{"pd.musicapp.migu.cn", "app.c.nf.migu.cn", "c.musicapp.migu.cn"}
	miguAlbumHosts  = []string{"app.c.nf.migu.cn", "pd.musicapp.migu.cn", "c.musicapp.migu.cn"}
	sodaSeoHosts    = []string{sodaSeoTrackHost, sodaSearchHost}
	sodaSearchHosts = []string{sodaSearchHost, sodaSeoTrackHost}
	ytmusicAPIBases = []string{ytmusicDomain, "https://youtubei.googleapis.com", "https://www.youtube.com"}
	amllBases       = []string{
		amllRawBase,
		"https://cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main",
		"https://fastly.jsdelivr.net/gh/amll-dev/amll-ttml-db@main",
	}
	// musixmatchBases:主用在前。单测会把它整个换成本地假服务器。
	musixmatchBases = []string{"https://apic-appmobile.musixmatch.com/ws/1.1/", "https://apic.musixmatch.com/ws/1.1/"}
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
