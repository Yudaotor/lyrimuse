package main

import (
	"sort"
	"strconv"
	"strings"
)

// 两家网页版的播放队列(YouTube Music、Spotify 网页版,由 App 代跑)只对 **用户在「网页播放器」里配对过
// 这个平台** 的浏览器去读。配对关系由 App 镜像进 features.json 的
// browser_platform_pairs:平台 id → 浏览器 bundle id 列表,平台 id 跟 Swift 侧 BrowserPositionProbe.supportedPlatforms
// 同一套。
//
// 没配对就不跑:没配对的浏览器多半没打开「允许 Apple 事件中的 JavaScript」,每换一首都让 App 跑一次注定失败的
// 脚本。App 侧 YouTubeMusicAdProbe / SpotifyWebAdProbe 的入口与 PlayerQueryServer 判的是同一件事。这道门是
// collector 发请求前唯一的筛选:浏览器能不能驱动、用哪种脚本方言由 App 判。
//
// 键缺失(App 还没写过这个键的配置)时沿用原来的行为:所有浏览器都探。
const (
	browserPlatformYouTubeMusic = "youtubeMusic"
	browserPlatformSpotifyWeb   = "spotifyWeb"
)

// resolveBrowserPlatformPairs:nil = 文件里没有这个键;否则去掉首尾空白和空串,没有浏览器的平台不留。
func resolveBrowserPlatformPairs(raw map[string][]string) map[string]map[string]bool {
	if raw == nil {
		return nil
	}
	out := make(map[string]map[string]bool, len(raw))
	for platform, bundles := range raw {
		platform = strings.TrimSpace(platform)
		if platform == "" {
			continue
		}
		for _, b := range bundles {
			b = strings.TrimSpace(b)
			if b == "" {
				continue
			}
			if out[platform] == nil {
				out[platform] = map[string]bool{}
			}
			out[platform][b] = true
		}
	}
	return out
}

// browserPlatformPaired:这个浏览器配对过这个平台没有。host 是浏览器本体的 bundle id —— Safari 报的媒体代理进程
// 要先换回宿主(调用方都已经按 mediaProxyOwners 换过),配对记的是宿主。
func browserPlatformPaired(platformID, host string) bool {
	pairs := features().BrowserPlatformPairs
	if pairs == nil {
		return true
	}
	return pairs[platformID][host]
}

// browserPlatformPairsSummary 给启动快照日志用:"legacy" = 没有这个键,否则「平台:浏览器个数」按平台排序。
func browserPlatformPairsSummary(pairs map[string]map[string]bool) string {
	if pairs == nil {
		return "legacy"
	}
	parts := make([]string, 0, len(pairs))
	for platform, bundles := range pairs {
		parts = append(parts, platform+":"+strconv.Itoa(len(bundles)))
	}
	sort.Strings(parts)
	return orDash(strings.Join(parts, ","))
}
