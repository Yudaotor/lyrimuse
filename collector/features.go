// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
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
	LyricsFiles          *bool `json:"lyrics_files,omitempty"`
	AlbumPrefetch        *bool `json:"album_prefetch,omitempty"`
	StateRelay           *bool `json:"state_relay,omitempty"`
	LastfmBridge         *bool `json:"lastfm_bridge,omitempty"`
	LastfmMirrorScrobble *bool `json:"lastfm_mirror_scrobble,omitempty"`
	WeeklyDigest         *bool `json:"weekly_digest,omitempty"`
	TopArtistsDigest     *bool `json:"top_artists_digest,omitempty"`
	BarkAlerts           *bool `json:"bark_alerts,omitempty"`
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
	// WebShowXxx 这五个跟上面所有字段都不一样:collector 自己的行为完全不受它们影响,
	// 纯粹是"路过"——collector 只负责把值原样透传进 pushRelayState 的 payload,真正
	// 消费方是网页前端的 JS,由它决定要不要渲染/请求"历史播放"“留言墙”“表情反应”
	// “访客数”“Top 艺人”这五个可选内容模块。跟这五个模块相对的"正在播放"核心区和
	// 歌词面板不是可选项,不受这组开关覆盖。
	WebShowHistory      *bool `json:"web_show_history,omitempty"`
	WebShowComments     *bool `json:"web_show_comments,omitempty"`
	WebShowReactions    *bool `json:"web_show_reactions,omitempty"`
	WebShowVisitorCount *bool `json:"web_show_visitor_count,omitempty"`
	WebShowTopArtists   *bool `json:"web_show_top_artists,omitempty"`
}

// featureFlags is the resolved (never-nil) form consulted at every gate site.
type featureFlags struct {
	Lyrics               bool
	LyricsFiles          bool
	AlbumPrefetch        bool
	StateRelay           bool
	LastfmBridge         bool
	LastfmMirrorScrobble bool
	WeeklyDigest         bool
	TopArtistsDigest     bool
	BarkAlerts           bool
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
	// WebShowXxx：见 featureFlagsFile 同名字段注释——只透传给网页,不影响 collector
	// 自身任何逻辑分支。
	WebShowHistory      bool
	WebShowComments     bool
	WebShowReactions    bool
	WebShowVisitorCount bool
	WebShowTopArtists   bool
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
// file / unparseable content / missing individual fields all resolve to
// "true",即今天的既有行为,这是一次纯增量的能力,不会在任何人还没打开过新设置
// 分组之前静默改变行为)。
func loadFeatureFlags(path string) featureFlags {
	var f featureFlagsFile
	if data, err := os.ReadFile(path); err == nil {
		if jerr := json.Unmarshal(data, &f); jerr != nil {
			log.Printf("parse feature flags %s: %v (使用默认全开)", path, jerr)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		log.Printf("read feature flags %s: %v (使用默认全开)", path, err)
	}
	return featureFlags{
		Lyrics:               boolOr(f.Lyrics, true),
		LyricsFiles:          boolOr(f.LyricsFiles, true),
		AlbumPrefetch:        boolOr(f.AlbumPrefetch, true),
		StateRelay:           boolOr(f.StateRelay, true),
		LastfmBridge:         boolOr(f.LastfmBridge, true),
		LastfmMirrorScrobble: boolOr(f.LastfmMirrorScrobble, true),
		WeeklyDigest:         boolOr(f.WeeklyDigest, true),
		TopArtistsDigest:     boolOr(f.TopArtistsDigest, true),
		BarkAlerts:           boolOr(f.BarkAlerts, true),
		LyricsSources:        resolveLyricsSources(f.LyricsSources),
		LyricsSourceMode:     resolveLyricsSourceMode(f.LyricsSourceMode),
		LyricsSourceOrder:    resolveLyricsSourceOrder(f.LyricsSourceOrder),
		LyricsDir:            f.LyricsDir,
		WebShowHistory:       boolOr(f.WebShowHistory, true),
		WebShowComments:      boolOr(f.WebShowComments, true),
		WebShowReactions:     boolOr(f.WebShowReactions, true),
		WebShowVisitorCount:  boolOr(f.WebShowVisitorCount, true),
		WebShowTopArtists:    boolOr(f.WebShowTopArtists, true),
	}
}

// webModules 把五个"网页可选模块"开关整理成网页前端消费的 map——键名故意用
// camelCase(跟 relayState 里 progressMs/lyricsTr 等既有 /push /now 载荷字段的
// 大小写惯例一致),跟本文件其余部分、以及磁盘上 features.json 用的 snake_case
// 是两套不同约定,分别对应两个不同的消费方(前者是 Cloudflare Worker/网页 JS,
// 后者是 desktop-lyrics 的设置界面写盘格式)。
func (f featureFlags) webModules() map[string]bool {
	return map[string]bool{
		"history":      f.WebShowHistory,
		"comments":     f.WebShowComments,
		"reactions":    f.WebShowReactions,
		"visitorCount": f.WebShowVisitorCount,
		"topArtists":   f.WebShowTopArtists,
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
