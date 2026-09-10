package main

import "strings"

// 按播放器排除收听历史(2026-09-10,借鉴清单 S10:Sleeve 的「选择哪些 App scrobble 到 Last.fm」)。
//
// 设置 → 播放器 →「收听历史」卡上取消勾选的播放器写进 features.json 的 history_excluded_bundles
// (bundle id 列表;内置播放器用各自的 bundle id,信任列表里的 App / 浏览器用它们自己的)。缺失 / 空 =
// 全部计入 —— 跟其余"缺字段 = 沿用现有行为"的键同一口径,新装机与老配置都不会突然少记。
//
// 挡的是**收听**:LB single、Last.fm 镜像、本地收听日志、relay 最近播放(全挂在 submitSingleAsync 后面)、
// 以及 LB playing_now / Last.fm now-playing(announce)、退出兜底那条同步刷写。**不挡**歌词显示与解析、
// 网页中继的「正在播放」状态卡(那是状态不是历史)、iPhone 桥接。判定在开会话那一拍算一次存进
// playSession.historyExcluded(跟 isAd 同一个位置):一首歌中途改设置不该把同一次收听切成两半,
// 也不该让挂着等 scrobble 时点的那条 Last.fm 收听在 settle 时凭空消失 —— 何况 collector 只在启动时
// 读一次这份文件,改设置本来就伴随一次重启。
//
// 粒度是 bundle:collector 侧没有网页平台身份(平台 ↔ 浏览器配对只在 App 侧),配对的浏览器只能整个
// 开或关。Safari 的播放报的是媒体代理进程 com.apple.WebKit.GPU,设置里存的是宿主 com.apple.Safari,
// 查之前先按 mediaProxyOwners 归一(跟 isTrustedPlayerBundleID / mediaPlayerLabel 同一个坑)。

// resolveHistoryExcludedBundles 把文件里的列表清洗成集合:去首尾空白、丢空串、去重。nil / 空 → 空 map
// (不是 nil,调用方可以直接 m[x] 查)。不校验"是不是认识的播放器":信任列表里的 bundle id 本来就是任意的。
func resolveHistoryExcludedBundles(raw []string) map[string]bool {
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

// historyExcluded 报告这个 bundle 的播放是否被用户排除在收听历史之外。空 bundle 不算排除
// (没有播放可言,由调用方的 key() 判空兜着)。
func historyExcluded(bundleID string) bool {
	if bundleID == "" || len(features.HistoryExcludedBundles) == 0 {
		return false
	}
	if features.HistoryExcludedBundles[bundleID] {
		return true
	}
	if owner, ok := mediaProxyOwners[bundleID]; ok && features.HistoryExcludedBundles[owner] {
		return true
	}
	return false
}
