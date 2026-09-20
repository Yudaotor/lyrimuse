package main

import (
	"encoding/json"
	"log"
	"maps"
	"os"
	"sync"
	"time"
)

// 「歌词来源」的勾选**不重启 collector**:这份集合按 features.json 的 mtime 热重读,写法与
// lastfmexclude.go 的 currentLastfmExcludedBundles、lyricspins.go 的 lyricsPinned 一致 ——
// 每次调用只 Stat 一下,mtime 或大小任一变了才重新解析。
//
// 重启的真实代价量过:collector 每次启动要在 74MB 歌词缓存之上跑九道迁移 + 全量导入导出 14307 个
// 歌词文件,四次重启从收到 SIGTERM 到打出启动横幅分别是 68 / 37 / 40 / 43 秒,这段时间歌词与
// "正在播放"推送整个停摆;而设置页那句「正在应用到后台服务…」只转 1~3 秒就收起(它把"launchd 报出
// 了一个新 pid"当成完成)。两者相差半分多钟,勾一下源看起来像"提示说应用完了、实际很久才生效"。
//
// ⚠️ 只热读 lyrics_sources 这一个键,不是整份 featureFlags。同一张卡片上的「匹配算法」
// (lyrics_source_mode)和拖拽出来的顺序(lyrics_source_order)仍然要重启才生效:它们在启动时就被
// 展开进包级变量、决定了走哪条取词路径,中途换掉是没人验证过的行为。App 侧对称的判据见
// CollectorRestartPolicy.hotReloadedKeys,加键前两边都要改。
//
// ⚠️ 刻意**不**在"一轮搜索"上做快照(与 lastfmExcluded 挂在开会话那一拍不同):同一轮里
// planRound 与收结果各自调 lyricSourceEnabled,中途改设置会让两次判定不一致。后果封顶是这一轮
// 多查一个源、或某个源的候选不被采用,下一轮自然恢复,不写坏任何缓存 —— 比为它停摆 40 秒轻得多。

var (
	// 由 main() 跟其余路径一起登记。为空(一次性 CLI 子命令那些提前返回的分支)时退回启动时
	// 解析好的 features.LyricsSources —— 那些子命令不长跑,没有"中途被改"这回事。
	lyricSourcesPath  string
	lyricSourcesMu    sync.Mutex
	lyricSourcesSet   map[string]bool
	lyricSourcesMTime time.Time
	lyricSourcesSize  int64
	lyricSourcesRead  bool
)

// setLyricSourcesPath 登记 features.json 的位置(main() 调,跟 loadFeatureFlags 同一处)。
func setLyricSourcesPath(path string) {
	lyricSourcesMu.Lock()
	defer lyricSourcesMu.Unlock()
	lyricSourcesPath = path
	lyricSourcesRead = false
}

// currentLyricSources 取这一刻启用的源集合。路径没登记、文件读不到、解析失败三种情况一律退回
// 启动时那份 features.LyricsSources —— 那是用户最后一次成功保存的意图,比任何默认都准。
// ⚠️ 别把失败分支改成"返回空集合":lyricSourceEnabled 把空集合当全开,用户刻意关掉的源会悄悄复活。
func currentLyricSources() map[string]bool {
	lyricSourcesMu.Lock()
	defer lyricSourcesMu.Unlock()
	if lyricSourcesPath == "" {
		return features.LyricsSources
	}
	st, err := os.Stat(lyricSourcesPath)
	if err != nil {
		// 文件不存在 = 从没保存过任何设置。启动时 loadFeatureFlags 对同一份缺失文件也走
		// resolveLyricsSources 的全集兜底,退回它就是同一个答案。
		lyricSourcesSet, lyricSourcesRead = nil, true
		lyricSourcesMTime, lyricSourcesSize = time.Time{}, 0
		return features.LyricsSources
	}
	if !lyricSourcesRead || !st.ModTime().Equal(lyricSourcesMTime) || st.Size() != lyricSourcesSize {
		next := readLyricSources(lyricSourcesPath)
		// 只在**换掉一份已经读过的**集合时打这一行:首次读发生在启动那一拍,启动横幅已经把
		// lyrics_sources 打过一遍了。没有这行,"改了源到底有没有生效"在日志里无从证实 ——
		// 而这条路径的全部意义就是让它在不重启的情况下生效。
		if next != nil && lyricSourcesRead && !maps.Equal(lyricSourcesSet, next) {
			log.Printf("lyrics sources: reloaded without a restart, now %v", sortedEnabledKeys(next))
		}
		lyricSourcesSet = next
		lyricSourcesMTime, lyricSourcesSize, lyricSourcesRead = st.ModTime(), st.Size(), true
	}
	if lyricSourcesSet == nil {
		return features.LyricsSources
	}
	return lyricSourcesSet
}

// readLyricSources 只取 features.json 里跟"哪些源开着"有关的那几个键。解析失败返回 nil,由调用方
// 退回启动时那份;下一次 App 写入会把 mtime 推新、自然重试。
func readLyricSources(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	// 六个迁移标记必须跟着列表一起读、一起交给 resolveLyricsSources:少读一个,老配置(那个源
	// 还不存在的年代写的)就会被白名单静默关掉 —— 这正是 resolveLyricsSources 里那段 ⚠️ 讲的坑。
	var f struct {
		LyricsSources    []string `json:"lyrics_sources"`
		AMLLLyrics       *bool    `json:"amll_lyrics"`
		LyricFindLyrics  *bool    `json:"lyricfind_lyrics"`
		KuwoLyrics       *bool    `json:"kuwo_lyrics"`
		MiguLyrics       *bool    `json:"migu_lyrics"`
		DeezerLyrics     *bool    `json:"deezer_lyrics"`
		AppleMusicLyrics *bool    `json:"applemusic_lyrics"`
		SodaLyrics       *bool    `json:"soda_lyrics"`
	}
	if err := json.Unmarshal(data, &f); err != nil {
		log.Printf("lyrics sources: cannot parse %s, keeping the set loaded at startup: %v", path, err)
		return nil
	}
	return resolveLyricsSources(f.LyricsSources, f.AMLLLyrics, f.LyricFindLyrics, f.KuwoLyrics, f.MiguLyrics, f.DeezerLyrics, f.AppleMusicLyrics, f.SodaLyrics)
}
