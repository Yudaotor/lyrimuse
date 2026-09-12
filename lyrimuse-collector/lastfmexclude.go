package main

import (
	"encoding/json"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

// 按播放器决定要不要 scrobble 到 Last.fm(2026-09-10,借鉴清单 S10)。
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
// **改这一项不重启 collector**(2026-09-10 第二轮,用户「1 吧」拍板):这份名单按 features.json 的 mtime 热重读,
// 写法照搬 lyricspins.go 的 lyricsPinned —— 每次调用只 Stat 一下,mtime 或大小任一变了才重新解析。
// 起因是量出「点一下芯片」的真实代价:App 写盘后走 launchctl kickstart -k 重启 collector,而 collector 每次启动
// 要在 74MB 歌词缓存之上跑九道迁移 + 全量导入导出 14307 个歌词文件,当天四次重启从收到 SIGTERM 到打出启动横幅
// 分别是 68 / 37 / 40 / 43 秒 —— 这段时间里歌词与"正在播放"推送整个停摆,只为送一个 bundle id 列表。
// ⚠️ 只热读**这一个键**,不是整份 featureFlags:别的键(播放器集合、歌词源顺序、lyricsDir)在启动时就被展开进
// 包级变量 / 决定了读取路径,中途换掉是没人验证过的行为。App 侧对称的判据见 CollectorRestartPolicy.hotReloadedKeys。
// ⚠️ 判定仍在**开会话那一拍**取一次(playSession.lastfmExcluded 不变):一首歌播到一半改设置不该把同一次收听
// 切成两半。区别只是"下一首就生效"而不再是"等 collector 重启完(约 40 秒)才生效"。
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
	excluded := currentLastfmExcludedBundles()
	if bundleID == "" || len(excluded) == 0 {
		return false
	}
	if excluded[bundleID] {
		return true
	}
	if owner, ok := mediaProxyOwners[bundleID]; ok && excluded[owner] {
		return true
	}
	return false
}

// ---- features.json 里这一个键的热重读(2026-09-10)----

var (
	// 由 main() 跟其余路径一起设定。为空(一次性 CLI 子命令那些提前返回的分支)时退回启动时解析好的
	// features.LastfmExcludedBundles —— 那些子命令不长跑,没有"中途被改"这回事。
	lastfmExcludePath  string
	lastfmExcludeMu    sync.Mutex
	lastfmExcludeSet   map[string]bool
	lastfmExcludeMTime time.Time
	lastfmExcludeSize  int64
	lastfmExcludeRead  bool
)

// setLastfmExcludePath 登记 features.json 的位置(main() 调,跟 loadFeatureFlags 同一处)。
func setLastfmExcludePath(path string) {
	lastfmExcludeMu.Lock()
	defer lastfmExcludeMu.Unlock()
	lastfmExcludePath = path
	lastfmExcludeRead = false
}

// currentLastfmExcludedBundles 取当前这份名单。每次调用只 Stat 一下 features.json,mtime 或大小
// 任一变了才重新解析整份 —— 这道判定只挂在"开一个新会话"那一拍上,每首歌最多跑一次,一次 Stat 可忽略。
func currentLastfmExcludedBundles() map[string]bool {
	lastfmExcludeMu.Lock()
	defer lastfmExcludeMu.Unlock()
	if lastfmExcludePath == "" {
		return features.LastfmExcludedBundles
	}
	st, err := os.Stat(lastfmExcludePath)
	if err != nil {
		// 文件不存在 = 从没保存过任何设置,一律不排除(跟"缺失 / 空 = 全部上送"同一口径)。
		lastfmExcludeSet, lastfmExcludeRead = nil, true
		lastfmExcludeMTime, lastfmExcludeSize = time.Time{}, 0
		return nil
	}
	if !lastfmExcludeRead || !st.ModTime().Equal(lastfmExcludeMTime) || st.Size() != lastfmExcludeSize {
		lastfmExcludeSet = readLastfmExcludedBundles(lastfmExcludePath)
		lastfmExcludeMTime, lastfmExcludeSize, lastfmExcludeRead = st.ModTime(), st.Size(), true
	}
	return lastfmExcludeSet
}

// readLastfmExcludedBundles 只取 features.json 里的这一个键。解析失败一律当"没有排除项"(fail-open),
// 理由同 readLyricsPins:这份文件是 App 写的(它拒绝写坏文件),读坏了最坏是这一轮该拦的没拦住,
// 下一次写入会把 mtime 推新、自然重试;而沿用旧内存态会让"全部重新勾上"在坏文件下永久不生效。
func readLastfmExcludedBundles(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var f struct {
		LastfmExcludedBundles []string `json:"lastfm_excluded_bundles"`
	}
	if err := json.Unmarshal(data, &f); err != nil {
		log.Printf("lastfm exclude: cannot parse %s, treating as empty: %v", path, err)
		return nil
	}
	return resolveLastfmExcludedBundles(f.LastfmExcludedBundles)
}
