// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"encoding/json"
	"log"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Music.app 自己缓存下来的官方歌词 —— applemusic 源的快速路径。
//
// Apple Music 客户端**每播一首歌**就把这首歌的 amp-api 响应原样落进
// `~/Library/Caches/com.apple.Music/fsCachedData/<UUID>`,里头是完整的 song 对象
// (id / name / artistName / albumName / artwork / durationInMillis)外加
// `relationships["syllable-lyrics"].ttmlLocalizations` —— **官方 TTML 歌词全文**。
//
// # 这条路的价值有多大(先说清楚,免得被高估)
//
// **不是"拿到现在拿不到的逐字"**。这个仓库本来就有逐字:同样那 5 首歌,netease/qq/kugou
// 给出的 lyrics_yrc 分别是 11212 / 8058 / 6409 / 5826 字,量比 Apple 这份还大。
// (此处一度写成"lyrimuse 逐字 0 字、译文 0 字" —— 那是统计时读错了字段名
// (`yrc`/`translation`,真实字段是 `lyrics_yrc`/`lyrics_tr`)得出的结论,不成立。)
//
// 真实的增量是三条,都比"填补空白"小:
//
//  1. **官方人工译文**。现在的译文是 translate.go 的机器翻译(条目里
//     lyrics_tr_source=machine);Apple 的 type="subtitle" 那种是官方人工版。
//     ⚠️ 覆盖有限:实测 26 份带 <translations> 的里只有 6 份是真翻译,其余 20 份是
//     zh-Hant→zh-Hans 的繁简替换(见 applemusicSubtitleTranslation)。
//  2. **catalog id 权威**。网络那条要先用歌名去 amp-api 搜索,搜出来的候选未必是正在播
//     的这一版(那 5 首在 lyrimuse 的 apple catalog 缓存里一条都没有);这里的身份是
//     Music.app 自己认定的,零搜索、零歧义。
//  3. **零网络、零 token**。网络那条取词**必须**带 media-user-token(要用户在设置里手动
//     "连接 Apple Music");这条不需要。
//
// 换句话说:它是给 applemusic 这一路加一个更可靠、更便宜的入口,不是给整个引擎补空白。
//
// # 前提与边界(都实测过)
//
//   - **必须用 Apple Music 播放才有**。只在界面里选中(AppleScript `reveal`)会缓存封面
//     和专辑元数据、但**一条歌词都不写**;MusicKit 的 downloaded_catalog_data 库
//     (catalog_song 表)是空的。
//   - **写入延迟 0.5~1.0 秒**(三次实测 0.50 / 0.76 / 1.01,T0 取系统报出新曲目的时刻)。
//     collector 是 5 秒轮询、没有事件通知,实测两首的缓存分别比 collector 发现换歌早
//     3.4 秒和 1.7 秒 —— 竞态窗口存在但很小,miss 了照常走网络那条,零损失。
//   - **只留最近的**。实测缓存里的歌词文件都是最近两天的,更早的被清掉了。对"解析正在
//     播放的这首歌"这个场景正好够 —— 那份歌词是刚播时才写的。
//
// ⚠️ 全程 fail-soft:目录不在 / 读不动 / 格式变了,一律当没命中,照常走
// resolveApplemusicLyric。

// applemusicLocalDirOverride 让单测把目录指到临时路径。空 = 用真实路径。
var applemusicLocalDirOverride string

// applemusicLocalCacheDir 是 Music.app 的 HTTP 响应缓存目录。⚠️ 外部 App 的路径。
func applemusicLocalCacheDir() string {
	if applemusicLocalDirOverride != "" {
		return applemusicLocalDirOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Caches/com.apple.Music/fsCachedData")
}

// applemusicLocalRescanMin:重扫节流。比另外几条本地路径短一个数量级,是被实测逼出来的 ——
// 这个目录**每播一首歌就多一个文件**,而我们要找的恰恰是刚写进去的那一份。
//
// 最早设 5 秒,结果是:collector 在换歌那一拍解析,而 Music.app 要 0.5~1 秒才把歌词写下来;
// 只要 collector 抢先扫过一次,后面 5 秒都不再重扫,这首歌就整轮查不到(实测「自以为」
// 播放时整轮落空,同一份缓存事后用 CLI 查却一击命中)。
//
// 扫一轮的实际成本是**毫秒级**(实测 48 条歌词、174 个文件、4.7MB,日志时间戳前后差 1ms),
// 所以这里几乎没有省的价值,1 秒只是防同一拍里的重复调用。
const applemusicLocalRescanMin = time.Second

// applemusicLocalMaxFileBytes:单个响应的读入上限。实测最大的一份逐字 TTML 约 53KB,
// 整份 JSON 也就百 KB 量级;4MB 是防同目录下的封面图/视频片段被整个读进来。
const applemusicLocalMaxFileBytes = 4 << 20

// applemusicLocalMaxTotalBytes:一轮扫描读入的总量上限。
const applemusicLocalMaxTotalBytes = 128 << 20

type applemusicLocalEntry struct {
	song applemusicSong
	ttml string
	kind string // "syllable-lyrics"(逐字) 或 "lyrics"(逐行)
}

// applemusicLocalPayload 是缓存文件的形状。song 部分直接内嵌 applemusicSong —— 缓存的
// 就是 amp-api 的原样响应,跟搜索那条走的是同一个结构,不另起一套解析。
type applemusicLocalPayload struct {
	Data []struct {
		applemusicSong
		Relationships map[string]struct {
			Data []struct {
				Attributes struct {
					TTMLLocalizations string `json:"ttmlLocalizations"`
				} `json:"attributes"`
			} `json:"data"`
		} `json:"relationships"`
	} `json:"data"`
}

var (
	applemusicLocalMu    sync.Mutex
	applemusicLocalIndex map[string]applemusicLocalEntry // catalog id -> 歌词
	// applemusicLocalByName:normLoose(歌手)|normLoose(曲名) -> 歌词。
	//
	// ⚠️ 为什么光有 catalog id 那份不够(实测坐实):**从资料库播放时 MediaRemote 给的
	// uniqueIdentifier 是负数持久 ID,不是目录 ID** —— 订阅曲目也一样(实测「四人游」
	// -4948493007864231856、「Just Friends (Sunny)」-401989708068864810)。
	// appleCatalogPlausibleID 要求 >0,于是 appleCatalogAnchor 必然不成立、
	// platformtrackid.go 那份 catalog id 拿不到。而 Music.app 自己**知道**对应的目录条目,
	// 歌词照缓存不误(那两首的歌词缓存都在盘上)。
	// 只按 id 查的话,这条路在"从资料库播放"这个主要场景下等于不存在。
	applemusicLocalByName  map[string][]applemusicLocalEntry
	applemusicLocalDirMod  time.Time
	applemusicLocalScanned time.Time
	applemusicLocalReady   bool
)

// applemusicLocalNameKey 与 kugou/qq/netease 三条本地路径同一把尺子(normLoose)。
func applemusicLocalNameKey(artist, title string) string {
	na, nt := normLoose(artist), normLoose(title)
	if na == "" || nt == "" {
		return ""
	}
	return na + "|" + nt
}

// scanApplemusicLocalFile 解析一个缓存文件,有歌词就写进 idx。
func scanApplemusicLocalFile(path string, idx map[string]applemusicLocalEntry, byName map[string][]applemusicLocalEntry) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	// 快速预筛:同目录下绝大多数是封面图等二进制,没必要送进 JSON 解析器。
	if !bytes.Contains(data, []byte("itunes:timing")) {
		return
	}
	data = bytes.TrimRight(data, "\x00")
	if len(data) == 0 || data[0] != '{' {
		return
	}
	var p applemusicLocalPayload
	if json.Unmarshal(data, &p) != nil {
		return
	}
	for _, item := range p.Data {
		if item.ID == "" {
			continue
		}
		// 逐字优先:它同时给得出逐行(applemusicParseTTML 一趟解析出 lrc+yrc+tr),
		// 口径跟网络那条的"逐字优先"完全一致。
		for _, kind := range []string{"syllable-lyrics", "lyrics"} {
			rel, ok := item.Relationships[kind]
			if !ok || len(rel.Data) == 0 {
				continue
			}
			ttml := rel.Data[0].Attributes.TTMLLocalizations
			if ttml == "" {
				continue
			}
			if cur, seen := idx[item.ID]; seen && cur.kind == "syllable-lyrics" {
				break // 已经有逐字了,不让逐行把它盖掉
			}
			e := applemusicLocalEntry{song: item.applemusicSong, ttml: ttml, kind: kind}
			idx[item.ID] = e
			if k := applemusicLocalNameKey(item.Attributes.ArtistName, item.Attributes.Name); k != "" {
				byName[k] = append(byName[k], e)
			}
			break
		}
	}
}

// refreshApplemusicLocalIndexLocked 在目录变过、且距上次扫描超过节流间隔时重建索引。
// 调用方必须持有 applemusicLocalMu。
func refreshApplemusicLocalIndexLocked() {
	dir := applemusicLocalCacheDir()
	if dir == "" {
		applemusicLocalIndex, applemusicLocalReady = nil, true
		return
	}
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		// 没装 / 没用过 Apple Music —— 正常情况,不记日志。
		applemusicLocalIndex, applemusicLocalReady = nil, true
		return
	}
	now := time.Now()
	if applemusicLocalReady && st.ModTime().Equal(applemusicLocalDirMod) {
		return
	}
	if applemusicLocalReady && now.Sub(applemusicLocalScanned) < applemusicLocalRescanMin {
		return
	}
	applemusicLocalDirMod, applemusicLocalScanned, applemusicLocalReady = st.ModTime(), now, true

	ents, err := os.ReadDir(dir)
	if err != nil {
		return // 保留上一次的索引
	}
	idx := map[string]applemusicLocalEntry{}
	byName := map[string][]applemusicLocalEntry{}
	budget := int64(applemusicLocalMaxTotalBytes)
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil || info.Size() > applemusicLocalMaxFileBytes || budget <= 0 {
			continue
		}
		budget -= info.Size()
		scanApplemusicLocalFile(filepath.Join(dir, e.Name()), idx, byName)
	}
	applemusicLocalIndex, applemusicLocalByName = idx, byName
	if len(idx) > 0 {
		log.Printf("applemusic local: indexed %d lyrics from client cache", len(idx))
	}
}

// pickApplemusicLocalEntry 在同名同歌手的多条记录里挑一条。判据与 qq/netease 两条本地
// 路径一致:先过时长闸(sourceDurationFits,与打分层 sourceDurationOff 同 12% 口径),
// 全过不了就不命中;再按时长差最小挑。
//
// 时长闸在这条路上尤其要紧:按名字匹配本来就比按 id 松,而缓存里同时躺着同一首歌的
// 现场版 / 原版是常态(本机缓存里就有整张周杰伦演唱会)。
func pickApplemusicLocalEntry(entries []applemusicLocalEntry, durationSecs float64) (applemusicLocalEntry, bool) {
	var best applemusicLocalEntry
	var bestDiff float64
	found := false
	for _, e := range entries {
		d := float64(e.song.Attributes.DurationInMillis) / 1000
		if !sourceDurationFits(durationSecs, d) {
			continue
		}
		diff := 0.0
		if durationSecs > 0 && d > 0 {
			diff = math.Abs(d - durationSecs)
		}
		if !found || diff < bestDiff {
			best, bestDiff, found = e, diff, true
		}
	}
	return best, found
}

// applemusicLocalLyric 取 Music.app 缓存下来的官方歌词。第二个返回值 false = 没命中,
// 调用方照常走网络那条。
//
// 两条路,按可靠性排:
//
//	① catalogID 非空时按 id 精确取。那是 platformtrackid.go 记下的、过了
//	   appleCatalogAnchor 校验的目录 id,零歧义。
//	② 否则按 (歌手, 曲名) + 时长闸匹配。**这条才是主力** —— 实测从资料库播放时
//	   MediaRemote 给的 uniqueIdentifier 是负数持久 ID,anchor 压根不成立(见
//	   applemusicLocalByName 处的注释),只认 id 的话这条路基本用不上。
func applemusicLocalLyric(catalogID, artist, title, album string, durationSecs float64) (applemusicResult, bool) {
	applemusicLocalMu.Lock()
	refreshApplemusicLocalIndexLocked()
	e, ok := applemusicLocalIndex[catalogID]
	via := "id"
	if !ok {
		if k := applemusicLocalNameKey(artist, title); k != "" {
			cands := append([]applemusicLocalEntry(nil), applemusicLocalByName[k]...)
			applemusicLocalMu.Unlock()
			e, ok = pickApplemusicLocalEntry(cands, durationSecs)
			via = "name"
			goto done
		}
	}
	applemusicLocalMu.Unlock()
done:
	if !ok {
		return applemusicResult{}, false
	}
	lrc, yrc, tr, parsed := applemusicParseTTML(e.ttml)
	if !parsed || lrc == "" {
		return applemusicResult{}, false
	}
	// plainOnly 的判据跟网络那条一致:逐字那份必然带时间轴;逐行那份要看解析出来的
	// LRC 到底有没有时间戳。
	plainOnly := e.kind != "syllable-lyrics" && !isTimedLRC(lrc)
	log.Printf("applemusic local: hit via %s %q - %q (%s%s)", via,
		e.song.Attributes.ArtistName, e.song.Attributes.Name, e.kind,
		map[bool]string{true: " +译文", false: ""}[tr != ""])
	return applemusicResultFrom(e.song, lrc, yrc, tr, plainOnly), true
}
