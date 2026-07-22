// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
)

// featureFlagsFile is the on-disk shape written by desktop-lyrics's "设置" →
// "功能开关" section and read once at collector startup — same "Swift 写共享
// 文件 → launchctl kickstart 重启 collector → collector 下次启动读到新内容"
// 约定,已经在 enrichCache/lyrics 文件夹这两处验证过(见 main.go 顶部注释),collector
// 没有文件监听,状态只在启动时读一次。用 *bool 而不是 bool——文件不存在、或者文件里
// 缺某个字段,都要解读成"沿用现有行为"(默认开启),而不是"关闭";bool 零值会把两者
// 都错误地解读成"关闭",导致这个改动从"纯增量开关"变成"静默改变现有行为"。
//
// 这里的开关跟 config.go 里已有的凭据判断是 AND 关系,不是替代:没配凭据的功能,
// 开关打开也没用;已经配了凭据的功能,现在才第一次有独立的"关"(尤其是
// lastfm_bridge/weekly_digest/top_artists_digest 这三个,过去共用同一对
// lastfm_user/lastfm_api_key 凭据当唯一开关,逻辑上是三个独立能力)。
// 四个歌词源的 key——跟 enrich.go 里 lyricCandidate.source/scoredLyricCandidateResult.
// Source 的取值、以及 desktop-lyrics「歌词管理」窗口 LyricsManagerView.swift 的
// sourceDisplayName 逐字对应,这是整个项目里"歌词源"唯一的一套 id,不是这里新起的。
const (
	lyricSourceNetease = "netease"
	lyricSourceQQ      = "qq"
	lyricSourceKugou   = "kugou"
	lyricSourceLRCLIB  = "lrclib"
)

const (
	lyricsModeSmart    = "smart"
	lyricsModePriority = "priority"
)

// lyricsSourceDefaultOrder 是"顺序优先"模式缺省的顺序——照抄 enrich.go
// scoredLyricCandidates 里 candidates 列表本来的 append 顺序,不是这里凭空定的。
var lyricsSourceDefaultOrder = []string{lyricSourceNetease, lyricSourceQQ, lyricSourceKugou, lyricSourceLRCLIB}

type featureFlagsFile struct {
	Lyrics               *bool `json:"lyrics,omitempty"`
	AlbumPrefetch        *bool `json:"album_prefetch,omitempty"`
	LastfmBridge         *bool `json:"lastfm_bridge,omitempty"`
	LastfmMirrorScrobble *bool `json:"lastfm_mirror_scrobble,omitempty"`
	WeeklyDigest         *bool `json:"weekly_digest,omitempty"`
	// DailyDigest：见 daily.go。跟 WeeklyDigest 是独立开关，两个可以同时开、只开一个、
	// 或都不开。
	DailyDigest *bool `json:"daily_digest,omitempty"`
	// WeeklyDigestSource/DailyDigestSource："lastfm"/"listenbrainz"/空。空值(用户
	// 从没在设置里手动选过)交给 resolveDigestSource(digest.go)按"两个账号都配了→
	// lastfm,只配了一个→用那个,都没配→跳过"自动判定,不是"缺省当 lastfm 处理"这么
	// 简单——所以这里特意留空字符串而不是给一个非空的默认值常量。
	WeeklyDigestSource string `json:"weekly_digest_source,omitempty"`
	DailyDigestSource  string `json:"daily_digest_source,omitempty"`
	// LyricsSources：启用的歌词源集合(lyricSourceXxx 常量的子集)。nil/缺失 = 全部
	// 启用,维持这个字段加之前的既有行为不变。
	LyricsSources []string `json:"lyrics_sources,omitempty"`
	// LyricsSourceMode："smart"(默认,四源全查+打分取最高分,见 enrich.go 的
	// scoredLyricCandidates/pickLyricCandidate)或"priority"(按 LyricsSourceOrder
	// 的顺序,取第一个通过质量校验(score>=0)的源,不比较分数高低)。空值按 smart 处理。
	LyricsSourceMode string `json:"lyrics_source_mode,omitempty"`
	// LyricsSourceOrder：只有 LyricsSourceMode == "priority" 时才生效。缺失时按
	// lyricsSourceDefaultOrder 兜底。
	LyricsSourceOrder []string `json:"lyrics_source_order,omitempty"`
	// LyricsDir：歌词文件夹("歌词文件夹作为权威源"读写的那个文件夹)的自定义位置。
	// 留空则用默认位置(config.json 同目录下的 lyrics/,main.go 里兜底)。
	LyricsDir string `json:"lyrics_dir,omitempty"`
}

// featureFlags is the resolved (never-nil) form consulted at every gate site.
//
// 2026-07-20:StateRelay 总开关 + 5 个 WebShowXxx 网页展示模块开关已删掉——用户
// 反馈"网页推送是附加功能，配好 state-relay 地址+令牌就该默认全推，不用逐项配置"。
// pushRelayState 现在只看 cfg.StateRelayURL 是否非空(config.go)来决定推不推；
// webModules()/payload["modules"] 也一并删掉——网页前端(web/index.html
// normalizeModules)本来就把 modules 字段缺失当"全部启用"处理,不推这个字段跟
// 推一份全 true 的字段，网页那边看到的效果完全一样，没有必要维护一份形同虚设的
// 可配置项。同一天还删掉了 TopArtistsDigest(同样改成"三个真实前置条件满足就自动
// 跑",见 topArtistsDigest())和 BarkAlerts(故障告警——用户反馈"压根不需要告警
// 故障了",这个是彻底删掉能力,见 alerter.go)。
type featureFlags struct {
	Lyrics               bool
	AlbumPrefetch        bool
	LastfmBridge         bool
	LastfmMirrorScrobble bool
	WeeklyDigest         bool
	DailyDigest          bool
	WeeklyDigestSource   string
	DailyDigestSource    string
	// 只被 pickLyricCandidate(enrich.go)读取,自动解析路径专用——手动的
	// `collector search-lyrics` CLI 子命令故意不看这三个字段(见 pickLyricCandidate
	// 注释),该子命令的 main() 分支也从不调用 loadFeatureFlags,这三个字段在那条
	// 路径上永远是零值,不会被误用。
	LyricsSources     map[string]bool
	LyricsSourceMode  string
	LyricsSourceOrder []string
	// LyricsDir 空字符串表示"用默认位置",由 main.go 里设置包级变量 lyricsDir 时兜底,
	// 不在这里(loadFeatureFlags)展开成绝对路径——那时候 *cfgPath 还没解析完。
	LyricsDir string
}

// features is set once in main() before run() starts; every gate site reads
// this package-level value (same style as enrichCache/lyricsDir等既有包级状态)。
var features featureFlags

func boolOr(p *bool, def bool) bool {
	if p == nil {
		return def
	}
	return *p
}

// loadFeatureFlags reads the shared feature-toggle file (best-effort — missing
// file / unparseable content all resolve to defaults below). Core behavior
// toggles (lyrics/albumPrefetch) miss-field-defaults to true — a
// pure increment that never silently changes existing behavior. The 3 toggles
// that each require an external account (Last.fm bridge+mirror / weekly
// digest) default to false instead (2026-07-18): turning them on by default
// for a stranger who never opened Settings would silently start network
// calls to services they never configured.
func loadFeatureFlags(path string) featureFlags {
	var f featureFlagsFile
	if data, err := os.ReadFile(path); err == nil {
		if jerr := json.Unmarshal(data, &f); jerr != nil {
			log.Printf("parse feature flags %s: %v (使用默认值)", path, jerr)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		log.Printf("read feature flags %s: %v (使用默认值)", path, err)
	}
	return featureFlags{
		Lyrics:               boolOr(f.Lyrics, true),
		AlbumPrefetch:        boolOr(f.AlbumPrefetch, true),
		LastfmBridge:         boolOr(f.LastfmBridge, false),
		LastfmMirrorScrobble: boolOr(f.LastfmMirrorScrobble, false),
		WeeklyDigest:         boolOr(f.WeeklyDigest, false),
		DailyDigest:          boolOr(f.DailyDigest, false),
		WeeklyDigestSource:   f.WeeklyDigestSource,
		DailyDigestSource:    f.DailyDigestSource,
		LyricsSources:        resolveLyricsSources(f.LyricsSources),
		LyricsSourceMode:     resolveLyricsSourceMode(f.LyricsSourceMode),
		LyricsSourceOrder:    resolveLyricsSourceOrder(f.LyricsSourceOrder),
		LyricsDir:            f.LyricsDir,
	}
}

func resolveLyricsSources(list []string) map[string]bool {
	if len(list) == 0 {
		return map[string]bool{lyricSourceNetease: true, lyricSourceQQ: true, lyricSourceKugou: true, lyricSourceLRCLIB: true}
	}
	m := make(map[string]bool, len(list))
	for _, s := range list {
		m[s] = true
	}
	return m
}

func resolveLyricsSourceMode(mode string) string {
	if mode == lyricsModePriority {
		return lyricsModePriority
	}
	return lyricsModeSmart
}

func resolveLyricsSourceOrder(order []string) []string {
	if len(order) == 0 {
		return append([]string(nil), lyricsSourceDefaultOrder...)
	}
	return order
}
