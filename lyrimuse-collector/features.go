// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"strings"
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
// 五个歌词源的 key——跟 enrich.go 里 lyricCandidate.source/scoredLyricCandidateResult.
// Source 的取值、以及 desktop-lyrics「歌词管理」窗口 LyricsManagerView.swift 的
// sourceDisplayName 逐字对应,这是整个项目里"歌词源"唯一的一套 id,不是这里新起的。
const (
	lyricSourceNetease    = "netease"
	lyricSourceQQ         = "qq"
	lyricSourceKugou      = "kugou"
	lyricSourceMusixmatch = "musixmatch"
	lyricSourceLRCLIB     = "lrclib"
)

const (
	lyricsModeSmart    = "smart"
	lyricsModePriority = "priority"
)

// lyricsSourceDefaultOrder 是"顺序优先"模式缺省的顺序——照抄 enrich.go
// scoredLyricCandidates 里 candidates 列表本来的 append 顺序,不是这里凭空定的。
var lyricsSourceDefaultOrder = []string{lyricSourceNetease, lyricSourceQQ, lyricSourceKugou, lyricSourceMusixmatch, lyricSourceLRCLIB}

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
	// LyricsSourceMode："smart"(默认,五源全查+打分取最高分,见 enrich.go 的
	// scoredLyricCandidates/pickLyricCandidate)或"priority"(按 LyricsSourceOrder
	// 的顺序,取第一个通过质量校验(score>=0)的源,不比较分数高低)。空值按 smart 处理。
	LyricsSourceMode string `json:"lyrics_source_mode,omitempty"`
	// LyricsSourceOrder：只有 LyricsSourceMode == "priority" 时才生效。缺失时按
	// lyricsSourceDefaultOrder 兜底。
	LyricsSourceOrder []string `json:"lyrics_source_order,omitempty"`
	// LyricsDir：歌词文件夹("歌词文件夹作为权威源"读写的那个文件夹)的自定义位置。
	// 留空则用默认位置(config.json 同目录下的 lyrics/,main.go 里兜底)。
	LyricsDir string `json:"lyrics_dir,omitempty"`
	// LyricsTranslationLanguage："auto"(跟随系统语言,默认)或 ISO 639-1 两位小写代码
	// (如"en"/"es"/"ja")——Musixmatch 译文(crowd.track.translations.get)的目标语言。
	// 网易云/QQ 音乐的译文固定是中文,只有 Musixmatch 这个源支持指定任意语言。
	// resolveLyricsTranslationLanguage 负责把"auto"/空值解析成具体代码,见其注释。
	LyricsTranslationLanguage string `json:"lyrics_translation_language,omitempty"`
	// LaunchLyrimuseOnMusicOpen：检测到 Music.app 从没运行变成运行时,顺带启动/唤起
	// Lyrimuse.app(见 companionlaunch.go)。反方向("打开 Lyrimuse 时唤起 Music")
	// 不在这份共享文件里,是 Swift 侧 AppSettings 自己的纯本地设置,不需要 collector
	// 知道。
	LaunchLyrimuseOnMusicOpen *bool `json:"launch_lyrimuse_on_music_open,omitempty"`
}

// featureFlags is the resolved (never-nil) form consulted at every gate site.
//
// 推送类模块(网页展示子开关、TopArtistsDigest、故障告警)不在这里出现:前两者已
// 改成"配置齐了就默认全跑"(pushRelayState 只看 cfg.StateRelayURL 是否非空,见
// config.go;TopArtistsDigest 见 topArtistsDigest()),不需要单独开关;故障告警
// 已整个下线,见 alerter.go。
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
	// LyricsTranslationLanguage 是已经解析过的具体 ISO 639-1 代码(不会是"auto"或空值,
	// 见 resolveLyricsTranslationLanguage)。只被 musixmatchTranslationLRC
	// (musixmatch.go)读取。
	LyricsTranslationLanguage string
	// LaunchLyrimuseOnMusicOpen 只被 companionlaunch.go 读取。
	LaunchLyrimuseOnMusicOpen bool
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
// digest) default to false instead: turning them on by default for a stranger
// who never opened Settings would silently start network calls to services
// they never configured.
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
		Lyrics:                    boolOr(f.Lyrics, true),
		AlbumPrefetch:             boolOr(f.AlbumPrefetch, true),
		LastfmBridge:              boolOr(f.LastfmBridge, false),
		LastfmMirrorScrobble:      boolOr(f.LastfmMirrorScrobble, false),
		WeeklyDigest:              boolOr(f.WeeklyDigest, false),
		DailyDigest:               boolOr(f.DailyDigest, false),
		WeeklyDigestSource:        f.WeeklyDigestSource,
		DailyDigestSource:         f.DailyDigestSource,
		LyricsSources:             resolveLyricsSources(f.LyricsSources),
		LyricsSourceMode:          resolveLyricsSourceMode(f.LyricsSourceMode),
		LyricsSourceOrder:         resolveLyricsSourceOrder(f.LyricsSourceOrder),
		LyricsDir:                 f.LyricsDir,
		LyricsTranslationLanguage: resolveLyricsTranslationLanguage(f.LyricsTranslationLanguage),
		LaunchLyrimuseOnMusicOpen: boolOr(f.LaunchLyrimuseOnMusicOpen, false),
	}
}

func resolveLyricsSources(list []string) map[string]bool {
	if len(list) == 0 {
		return map[string]bool{
			lyricSourceNetease: true, lyricSourceQQ: true, lyricSourceKugou: true,
			lyricSourceMusixmatch: true, lyricSourceLRCLIB: true,
		}
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

// resolveLyricsTranslationLanguage 把共享文件里的"auto"/空值解析成一个具体的 ISO
// 639-1 代码——collector 是长驻后台进程(launchd gui/$(id -u) 用户级 agent,跟登录用户
// 的 Aqua 会话同一身份运行),用 `defaults read -g AppleLocale` 能可靠读到这台 Mac 当前
// 的系统语言,不依赖 launchd 环境变量(环境变量对用户级 agent 不一定完整继承登录 shell
// 的 locale 设置)。读不到/查不到对应语言代码时兜底 "en"——总比整段不请求译文更有用。
// 只在启动时解析一次(跟这个文件里其它字段同一个"读一次,重启才生效"的既定约定),运行
// 中途切系统语言不会实时生效。
func resolveLyricsTranslationLanguage(lang string) string {
	if lang != "" && lang != "auto" {
		return lang
	}
	if code := systemLanguageCode(); code != "" {
		return code
	}
	return "en"
}

// systemLanguageCode 读 macOS 当前系统语言,取 AppleLocale("zh_Hans_CN"/"en_US"/
// "ja_JP"这类形式)下划线前的两位语言代码并转小写。查询失败(命令不存在/超时/返回值
// 解析不出下划线分隔的语言段)一律返回空串,交给调用方兜底,不 panic、不重试。
func systemLanguageCode() string {
	out, err := exec.Command("defaults", "read", "-g", "AppleLocale").Output()
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(out))
	if i := strings.IndexByte(s, '_'); i > 0 {
		s = s[:i]
	}
	if s == "" {
		return ""
	}
	return strings.ToLower(s)
}
