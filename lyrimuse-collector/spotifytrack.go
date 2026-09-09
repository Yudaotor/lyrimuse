// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import "strings"

// Spotify 原生客户端这一次播放的**真曲目 ID**(2026-09-09)。
//
// 来路:换曲那一拍 detectAdAtSessionStart 本来就要 fork 一次 osascript 问 `spotify url` 判广告,
// 拿到的 `spotify:track:<22 位 ID>` 以前判完前缀就丢了。现在留下来,做两件事:
//
//  1. 歌词缓存条目的 spotify_url 从本地拼的**搜索页**链接(open.spotify.com/search/歌手 歌名)换成
//     真曲目链接 open.spotify.com/track/<id> —— 网页中继那排「平台跳转」里的 Spotify 按钮点开就是这首;
//  2. ListenBrainz 上送按标准字段带上 spotify_id / origin_url / music_service(见 spotifyListenFields),
//     LB 拿 spotify_id 做曲目匹配与元数据补全,原来那个非标准键 spotify_url 装的是搜索页,对它没有用。
//
// 提示表按 enrichKey(原始 artist/title/album)暂存,由 trackEnrichment(缓存命中)与 resolveEnrichAsync
// (首次解析)在写条目时消费 —— trackEnrichment 的调用方很多(poller / lb / relay / 专辑预取),不改它的签名,
// 跟 setNativeLyricSourcesForPlayer 那份包级状态是同一个先例。**受 enrichMu 保护**。
//
// 边界:广告(`spotify:ad:`)、本地文件(`spotify:local:`)、播客(`spotify:episode:`)都不是曲目,取不出 ID,
// 什么都不记。ID 是录音级身份:同一条目之后在 Apple Music 上再放,链接照样可用;但「在哪个服务听的」按当次
// 播放的 bundle 算,所以 LB 那三个键只在 Spotify 原生播放时写(lb.go)。
var spotifyTrackIDHints = map[string]string{}

// spotifyTrackIDHintCap 防无界增长:超过就整个清掉 —— 提示只在换曲后几秒内有用,丢了也只是这首歌
// 这次没记上 ID,下次播到再记。
const spotifyTrackIDHintCap = 512

// spotifyTrackIDFromURI 从 `spotify:track:<id>` 取 ID;不是曲目 URI 或形状不对 → 空串。
// Spotify ID 是 22 位 base62,别的一律不认(别把 `missing value` 这种脚本回声当 ID)。
func spotifyTrackIDFromURI(uri string) string {
	const prefix = "spotify:track:"
	u := strings.TrimSpace(uri)
	if !strings.HasPrefix(u, prefix) {
		return ""
	}
	id := u[len(prefix):]
	if len(id) != 22 {
		return ""
	}
	for _, r := range id {
		isDigit := r >= '0' && r <= '9'
		isLower := r >= 'a' && r <= 'z'
		isUpper := r >= 'A' && r <= 'Z'
		if !isDigit && !isLower && !isUpper {
			return ""
		}
	}
	return id
}

// spotifyURIIsAd:AppleScript `spotify url` 对广告返回 `spotify:ad:…`,这是唯一的权威分类(字段启发式
// 打不完地鼠:广告可以带全 artist/title/album)。
func spotifyURIIsAd(uri string) bool {
	return strings.HasPrefix(strings.TrimSpace(uri), "spotify:ad")
}

// spotifyTrackURL 拼真曲目链接;没有 ID 给空串,让调用方退回搜索链接。
func spotifyTrackURL(id string) string {
	if id == "" {
		return ""
	}
	return "https://open.spotify.com/track/" + id
}

// spotifyLink 是对外(fields → relay / LB)那个 spotify_url 的唯一取值点:有真 ID 用真链接,否则退回
// resolveTrackEnrichment 拼的搜索页链接。放在读侧而不是写侧,是为了让 backfillPeripheralFields /
// 重复条目合并这些会重写 SpotifyURL 的路径不必各自关心 ID —— 它们照旧只管搜索链接。
func (e enrichEntry) spotifyLink() string {
	if u := spotifyTrackURL(e.SpotifyTrackID); u != "" {
		return u
	}
	return e.SpotifyURL
}

// noteSpotifyTrackID 由 poller 在换曲那一拍调用(不持 enrichMu)。
func noteSpotifyTrackID(artist, title, album, id string) {
	if id == "" || title == "" {
		return
	}
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if len(spotifyTrackIDHints) >= spotifyTrackIDHintCap {
		spotifyTrackIDHints = map[string]string{}
	}
	spotifyTrackIDHints[key] = id
}

// applySpotifyTrackIDHintLocked 把提示写进条目,返回是否真的改了(调用方据此决定要不要落盘)。
// **调用方必须持有 enrichMu**(名字里的 Locked 就是这个意思,同 siblingCoverLocked 的约定)。
func applySpotifyTrackIDHintLocked(key string, e *enrichEntry) bool {
	id := spotifyTrackIDHints[key]
	if id == "" || e.SpotifyTrackID == id {
		return false
	}
	e.SpotifyTrackID = id
	return true
}

// spotifyListenFields 给 ListenBrainz 的 additional_info 补标准字段。纯函数,单测直接覆盖。
//
// 只在**这次播放来自 Spotify 原生客户端**且有 ID 时给:spotify_id 官方定义是「这条录音的 Spotify 曲目 URL」,
// origin_url 是「这条录音在网上的位置」,music_service 是「听的服务的规范域名」—— 三个键的形状跟 LB 自家的
// Spotify 导入一致。别的播放器放同一首歌时缓存里也有这个 ID,但那时「在 spotify.com 听的」就不成立了,一个都不写。
func spotifyListenFields(bundleID, trackID string) map[string]string {
	if bundleID != spotifyBundleID || trackID == "" {
		return nil
	}
	u := spotifyTrackURL(trackID)
	return map[string]string{
		"spotify_id":    u,
		"origin_url":    u,
		"music_service": "spotify.com",
	}
}
