package main

import "time"

// 各歌词源单个请求的整体超时(含读完响应体),交给 lyricHTTPClient。一轮搜索另有 20 秒总截止(lyricSearchDeadline)。
// 自带超时常量的源不在这里:网易云的在各调用点按接口传(neteaseFetchBody 的 timeout 参数)、Musixmatch 用 musixmatchHTTPClient、
// 汽水用 sodaLyricTimeout、YouTube Music 的接口用 ytmusicHTTPTimeout。
const (
	// qqHTTPTimeout:QQ 网页接口(搜索、歌词、lyric_download)。
	qqHTTPTimeout = 6 * time.Second
	// qqMusicuTimeout:QQ 客户端网关 musicu.fcg 的 POST。
	qqMusicuTimeout  = 8 * time.Second
	kugouHTTPTimeout = 6 * time.Second
	kuwoHTTPTimeout  = 6 * time.Second
	miguHTTPTimeout  = 6 * time.Second
	vibeHTTPTimeout  = 6 * time.Second
	genieHTTPTimeout = 6 * time.Second
	// miguAlbumInfoTimeout:咪咕按专辑 ID 取专辑信息。
	miguAlbumInfoTimeout = 4 * time.Second
	// ytmusicHomePageTimeout:取 YouTube Music 首页拿 VISITOR_DATA。
	ytmusicHomePageTimeout = 8 * time.Second
	// sodaAlbumPageTimeout:汽水专辑页。
	sodaAlbumPageTimeout = 10 * time.Second
)
