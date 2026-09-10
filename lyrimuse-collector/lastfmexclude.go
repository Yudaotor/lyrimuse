package main

import "strings"

// 按播放器决定要不要 scrobble 到 Last.fm(2026-09-10,借鉴清单 S10:Sleeve 的「选择哪些 App scrobble 到 Last.fm」)。
//
// 设置 → 账号 → Last.fm → 设置 →「Scrobble 的播放器」取消勾选的写进 features.json 的 lastfm_excluded_bundles
// (bundle id 列表;内置播放器用各自的 bundle id,信任列表里的 App / 浏览器用它们自己的)。缺失 / 空 = 全部上送,
// 跟其余"缺字段 = 沿用现有行为"的键同一口径,新装机与老配置都不会突然少记。
//
// **只管 Last.fm**(用户 2026-09-10 原话「只控制 lastfm 的上送」,与短曲目 / scrobble 时点 / 合唱歌手三项同一口径,
// 见 12 章决策 9):挡的是 track.scrobble 的镜像(recordLastfmListen → settleLastfmPending)、给它兜底的本地收听日志与
// 回填、以及 track.updateNowPlaying(announce)。ListenBrainz 的 single / playing_now、网页中继、歌词、iPhone 桥接
// 一律不受影响。判定在开会话那一拍算一次存进 playSession.lastfmExcluded(跟 isAd 同一个位置):一首歌中途改设置
// 不该把同一次收听切成两半;何况 collector 只在启动时读一次这份文件,改设置本来就伴随一次重启。
//
// 粒度是 bundle:collector 侧没有网页平台身份(平台 ↔ 浏览器配对只在 App 侧),配对的浏览器只能整个开或关。
// Safari 的播放报的是媒体代理进程 com.apple.WebKit.GPU,设置里存的是宿主 com.apple.Safari,查之前先按
// mediaProxyOwners 归一(跟 isTrustedPlayerBundleID / mediaPlayerLabel 同一个坑)。

// resolveLastfmExcludedBundles 把文件里的列表清洗成集合:去首尾空白、丢空串、去重。nil / 空 → 空 map
// (不是 nil,调用方可以直接 m[x] 查)。不校验"是不是认识的播放器":信任列表里的 bundle id 本来就是任意的。
func resolveLastfmExcludedBundles(raw []string) map[string]bool {
	out := map[string]bool{}
	for _, b := range raw {
		b = strings.TrimSpace(b)
		if b == "" {
			continue
		}
		out[b] = true
	}
	return out
}

// lastfmExcluded 报告这个 bundle 的播放是否被用户排除在 Last.fm 上送之外。空 bundle 不算排除
// (没有播放可言,由调用方的 key() 判空兜着)。
func lastfmExcluded(bundleID string) bool {
	if bundleID == "" || len(features.LastfmExcludedBundles) == 0 {
		return false
	}
	if features.LastfmExcludedBundles[bundleID] {
		return true
	}
	if owner, ok := mediaProxyOwners[bundleID]; ok && features.LastfmExcludedBundles[owner] {
		return true
	}
	return false
}
