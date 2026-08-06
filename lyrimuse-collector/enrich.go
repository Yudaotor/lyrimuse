// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	neturl "net/url"
	"os"
	"sort"
	"sync"
	"time"
)

// enrichEntry is a track's resolved metadata, persisted permanently once
// resolved (歌手|歌名|专辑 key) — there is no cache/TTL concept for the
// identity fields (Lyrics/CoverURL/CanonicalArtist/等): once a song is
// listened to and resolved, its data lives on local disk until the user
// explicitly deletes it via desktop-lyrics 的"歌词管理"窗口 (which clears the
// whole entry, letting the next play resolve fresh). TS is only used to
// throttle the one thing that still self-heals automatically — see
// needsPeripheralBackfill.
type enrichEntry struct {
	CoverURL    string `json:"cover_url,omitempty"`
	AccentColor string `json:"accent_color,omitempty"`
	NeteaseURL  string `json:"netease_url,omitempty"`
	AppleURL    string `json:"apple_music_url,omitempty"`
	QQURL       string `json:"qq_music_url,omitempty"`
	SpotifyURL  string `json:"spotify_url,omitempty"`
	Lyrics      string `json:"lyrics,omitempty"`
	LyricsTr    string `json:"lyrics_tr,omitempty"`   // 中文翻译(逐行 LRC)
	LyricsRoma  string `json:"lyrics_roma,omitempty"` // 罗马音(日文歌，逐行 LRC)
	LyricsYRC   string `json:"lyrics_yrc,omitempty"`  // 逐字(词级，网易云 yrc 格式)
	// CanonicalArtist 是网易云/QQ 音乐曲库核实过的官方歌手名(仅单一歌手时才有值)，
	// 用来把同一歌手在历史记录里时而中文时而英文、时而全大写的写法统一成一个版本
	// (如 PRINCE/Prince 统一成 Prince、David Tao/陶喆 统一成 陶喆——中文平台曲库通常
	// 就是这么标的，天然贴合"能识别就用中文名"的诉求，不需要额外维护中英文对照表)。
	// 识别不出时留空，lbMeta 原样使用本地(Apple Music)标签，不瞎猜。
	CanonicalArtist string `json:"canonical_artist,omitempty"`
	// CoverSource/LyricsSource 记录封面/歌词实际来自哪个平台("netease"/"qq"/"lrclib"),
	// 供网页页脚如实展示(而不是写死"来自网易云"——封面/歌词各自可能来自不同平台,或者
	// 干脆哪个平台都没有)。
	CoverSource  string `json:"cover_source,omitempty"`
	LyricsSource string `json:"lyrics_source,omitempty"`
	// ManualLyrics 标记这条歌词是用户在 desktop-lyrics 的"歌词管理"窗口里手动纠正/采纳
	// 过的——纯粹是给 UI 显示"人工修正"徽章用的溯源标记,不再影响任何自动刷新逻辑(已经
	// 没有自动刷新了,所有条目都是解析一次永久生效)。
	ManualLyrics bool `json:"manual_lyrics,omitempty"`
	// Instrumental 标记"联网查过了,至少一个源(目前是 lrclib)明确说这首歌是纯音乐"——
	// 跟"Lyrics 为空"要分开看:后者也可能是"五个源都没查到、真的没搜到"这种更含糊的
	// 情况(用户可能想手动重新搜索候选歌词试试),前者是有明确依据的结论,UI 上应该
	// 显示成"纯音乐"而不是笼统的"无歌词"。2026-08-03 补上——这个信号 lrclib.go 里
	// 原来读了就直接丢,见 lrclibResult 定义处的注释。
	Instrumental bool `json:"instrumental,omitempty"`
	// TS 只用来给"外围字段缺失时的短时重试"计时(见 needsPeripheralBackfill),不再是
	// "多久没刷新就整条过期重新解析"的依据、也不再驱动任何淘汰逻辑。
	TS int64 `json:"ts"`
}

func (e enrichEntry) fields() map[string]string {
	m := map[string]string{}
	put := func(k, v string) {
		if v != "" {
			m[k] = v
		}
	}
	put("cover_url", e.CoverURL)
	put("accent_color", e.AccentColor)
	put("netease_url", e.NeteaseURL)
	put("apple_music_url", e.AppleURL)
	put("qq_music_url", e.QQURL)
	put("spotify_url", e.SpotifyURL)
	put("lyrics", e.Lyrics)
	put("lyrics_tr", e.LyricsTr)
	put("lyrics_roma", e.LyricsRoma)
	put("lyrics_yrc", e.LyricsYRC)
	put("canonical_artist", e.CanonicalArtist)
	put("cover_source", e.CoverSource)
	put("lyrics_source", e.LyricsSource)
	return m
}

// enrichPeripheralRetryInterval 是唯一还保留的自动重试节流——网易云(封面/主色)、
// Apple Music、QQ 音乐三路外围链接各自独立请求,可能因限流/超时单独失败;只要有一路
// "该有却没拿到"就每隔这么久重试补一次,而不是永久卡在残缺状态。不影响歌词/封面来源
// 等身份字段——那些一旦解析出结果就不再自动变动,见 backfillPeripheralFields。
const enrichPeripheralRetryInterval = 10 * time.Minute

var (
	enrichMu       sync.Mutex
	enrichCache    = map[string]enrichEntry{}
	enrichPath     string // 落盘路径；空则只用内存不持久化
	enrichDirty    bool
	enrichInflight = map[string]bool{} // 正在后台解析的 key,去重防止重复解析
	enrichNotify   chan struct{}       // 后台解析完成→通知 poll 立刻重推;run() 里初始化
)

// trackEnrichment returns a track's resolved fields, resolving (and persisting
// permanently) them on first sight. Safe for concurrent callers (poll+bridge).
// durationSecs(曲目真实时长,秒)只作为解析时的校验输入,不参与缓存 key——同一首歌哪怕
// 每次报的时长有几百毫秒抖动也应该命中同一份记录。已经解析过的条目永远直接返回,不会
// 自动整条重新解析——只有 needsPeripheralBackfill 命中时,会在后台补一次缺失的外围
// 字段(不碰歌词/封面来源等身份字段)。
func trackEnrichment(artist, title, album, bundleID string, durationSecs float64) map[string]string {
	if title == "" {
		return nil
	}
	// Spotify 广告插播:media-control 自己的文档确认广告播放时 album 字段恒为空字符串
	// (系统级 MediaRemote 本身就是这么报告的,不是我们没读到)。不能把广告的标题/歌手
	// 当成一首正常歌曲丢进下面的五源歌词搜索——qqMusicURL()/e.SpotifyURL 这两路兜底
	// 链接只要 title!="" 就会给出非空值,导致 resolveEnrichAsync 的"全空不写入"判断
	// 永远不成立,广告标题会被当成一首"歌"永久写进磁盘缓存,污染"歌词管理"列表,还
	// 白跑一轮网络搜索。这个信号只在 Spotify 广告上验证过(见 media-control README
	// "Skip Spotify ads" 一节),不影响 QQ 音乐/网易云音乐——那两个平台的正常曲目本来
	// 就该有专辑名,不会误伤。
	if bundleID == spotifyBundleID && album == "" {
		return nil
	}
	key := artist + "|" + title + "|" + album
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if ok {
		if needsPeripheralBackfill(e) && !enrichInflight[key] {
			enrichInflight[key] = true
			go backfillPeripheralFields(key, artist, title, album, durationSecs)
		}
		enrichMu.Unlock()
		return e.fields()
	}
	// 从没见过这首歌:首次解析(按 key 去重),不阻塞 poll 循环。
	if !enrichInflight[key] {
		enrichInflight[key] = true
		go resolveEnrichAsync(key, artist, title, album, durationSecs)
	}
	enrichMu.Unlock()
	return nil
}

// needsPeripheralBackfill 判断是否要补一次外围字段(主色/Apple/QQ/网易云链接)——这几路
// 各自独立请求,可能因限流/超时单独失败,漏了哪个就该重试哪个,不代表歌词/封面本身有问题。
// 用 TS 节流,避免同一首歌每次 poll(几秒一次)都重新发一遍网络请求。
func needsPeripheralBackfill(e enrichEntry) bool {
	missing := e.AccentColor == "" || e.AppleURL == "" || e.QQURL == "" || e.NeteaseURL == ""
	if !missing {
		return false
	}
	return time.Now().Unix()-e.TS >= int64(enrichPeripheralRetryInterval/time.Second)
}

// resolveEnrichAsync 首次解析一首歌的完整信息(封面/主色/链接/歌词),写入并永久保留,
// 直到用户在"歌词管理"里显式删除这条。由 trackEnrichment 在从没见过这个 key 时启动;
// 同一 key 同时只有一个在跑(enrichInflight 去重)。各外部请求自带 4~10s 超时,故本
// goroutine 有界、进程退出即止。
func resolveEnrichAsync(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	e := resolveTrackEnrichment(artist, title, album, durationSecs)
	e.TS = time.Now().Unix()
	// 只保留"解析到东西"的结果;全空(可能网络抽风)不写入,下次再试,别把偶发失败钉死。
	if e.CoverURL == "" && e.Lyrics == "" && e.AppleURL == "" && e.QQURL == "" && e.NeteaseURL == "" {
		return
	}
	enrichMu.Lock()
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	exportLyricsFiles() // 见 lyricsexport.go——刚解析出的新歌词额外导出成独立文件
	// 非阻塞通知 poll 立刻重推(带上刚解析好的封面/歌词);没人在听就跳过。
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
}

// backfillPeripheralFields 只补外围链接(Apple/QQ/网易云/主色),绝不动歌词/封面来源/
// 人工修正标记等身份字段——这些一旦解析出结果就永久生效,不该被这条自愈路径悄悄改掉。
func backfillPeripheralFields(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	fresh := resolveTrackEnrichment(artist, title, album, durationSecs)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		// 补的这段时间里,这条被用户在"歌词管理"里删掉了——不要把它复活回去。
		enrichMu.Unlock()
		return
	}
	// ⚠️ 只在这次真的拿到值时才覆盖 —— 原来是无条件赋值,一次网络抖动/某个源临时挂掉,
	// fresh 里这些字段就是空的,于是把之前已经解析好的封面、主色和各平台链接**抹成空**,
	// 而下面那行 e.TS = now 又把节流时间戳推进去,10 分钟内不会再补,封面就这么消失了。
	// 紧挨着的 CanonicalArtist 本来就有 `== ""` 守卫,这几行属于漏了同一层保护。
	//
	// 封面三件套一起判(主色是从这张封面算出来的,不能出现"新封面配旧主色"的错配)。
	if fresh.CoverURL != "" {
		e.CoverURL, e.CoverSource, e.AccentColor = fresh.CoverURL, fresh.CoverSource, fresh.AccentColor
	}
	if fresh.AppleURL != "" {
		e.AppleURL = fresh.AppleURL
	}
	if fresh.QQURL != "" {
		e.QQURL = fresh.QQURL
	}
	if fresh.SpotifyURL != "" {
		e.SpotifyURL = fresh.SpotifyURL
	}
	if fresh.NeteaseURL != "" {
		e.NeteaseURL = fresh.NeteaseURL
	}
	if e.CanonicalArtist == "" {
		e.CanonicalArtist = fresh.CanonicalArtist
	}
	e.TS = time.Now().Unix() // 推进节流时间戳,不管这次补没补全,10 分钟内不再重试
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
}

func resolveTrackEnrichment(artist, title, album string, durationSecs float64) enrichEntry {
	// 统一转成简体再往下传给 NetEase/QQ/酷狗/LRCLIB 的搜索接口——这几个平台的曲库/搜索
	// 索引都是简体中文,本地 Apple Music 标签如果是繁体,拿繁体原文直接发起搜索请求会
	// 完全查不到候选(不是匹配质量差,是搜索接口本身没命中)。match.go 的 normLoose 里
	// 已经有一处 toSimplified,但那处解决的是"拿到候选之后比较标题/专辑字符串"这一步,
	// 跟这里"搜索关键词本身要先转换才发得出去"是两个不同阶段,不能互相替代。这里只转换
	// 本函数内部用来发起搜索请求的局部变量,不改 enrichCache 的 key(那个在更上层的
	// trackEnrichment 里用原始、未转换的 artist/title/album 构造,必须跟 Apple Music
	// 原始标签保持逐字节一致,否则同一首歌反复播放会对不上同一条缓存记录)。
	artist, title, album = toSimplified(artist), toSimplified(title), toSimplified(album)
	var e enrichEntry
	// 网易云:封面(国内可加载,苹果 mzstatic 国内已无 CDN)+ 单曲链接 + 带轴歌词,一次搜索出。
	// 无条件查一次——封面/跳转链接不管歌词功能开没开都要用。开着歌词功能时,这次网易云
	// 查询挪进了 scoredLyricCandidates 内部,跟 qq/酷狗/Musixmatch/LRCLIB 四个源一起
	// 并发发出去(不再是本函数单独先同步查一遍、查完了那四个才开始跑——之前这么写等于
	// 把网易云自己最坏能到小三十秒的串行耗时,原样叠加在了整体等待时间最前面);只有
	// 歌词功能关掉、根本不需要凑齐五个源时,才单独查这一次。
	var ne neteaseInfo
	var scored []scoredLyricCandidateResult
	if features.Lyrics {
		// 歌词:网易云/QQ音乐/酷狗/Musixmatch/LRCLIB 五个源全部并发查一遍,不是查到第一个
		// 能用的就停——一首歌只在缓存未命中时解析一次,后续都直接读缓存,五个源都查一遍
		// 换来更可信的结果性价比很高。取分/并发/超时兜底细节见 scoredLyricCandidates
		// (同一份逻辑也供 desktop-lyrics 的"重新搜索候选歌词"手动纠正功能复用,搜索用的
		// CLI 子命令见 searchcli.go)——那条手动路径故意不受下面 pickLyricCandidate 的
		// "启用哪些源"过滤,理由见它的注释。
		ne, scored = scoredLyricCandidates(artist, title, album, durationSecs)
	} else {
		ne = neteaseLookup(artist, title, album)
	}
	// 封面/主色/平台跳转链接是基础展示信息,不做成可关闭的开关,以下逻辑无条件执行。
	e.CoverURL = ne.Cover
	if e.CoverURL != "" {
		e.CoverSource = "netease"
	}
	e.NeteaseURL = ne.SongURL
	// canonical_artist 解析链路,依次尝试、命中就用:
	// ①MusicBrainz(按歌手整体查、按歌手整体缓存,不受"这一首曲目在网易云/QQ 搜不搜
	//   得到"影响,见 musicbrainz.go 顶部注释——2026-07-30 加,修的就是同一个歌手有的
	//   曲目匹配成功、有的失败这个问题);
	// ②网易云本次搜索这首歌带回的歌手名(ne.Artist,按曲目匹配,老逻辑);
	// ③QQ 音乐(同样按曲目匹配,只在网易云没给封面时才会去查,见下面);
	// ④手工登记的已知艺名表(knownArtistAlias)。
	e.CanonicalArtist = canonicalArtistViaMusicBrainz(artist)
	if e.CanonicalArtist == "" {
		e.CanonicalArtist = ne.Artist
	}
	// Apple Music/iTunes Search 的匹配结果反正下面第 ~272 行 e.AppleURL 也要用,这里
	// 提前算出来复用同一份(appleMusicMatchCached 本身按 key 缓存,提前调不会多打一次
	// 请求)——2026-08-03 实测排查坐实(Michael Jackson《Morphine》,本地专辑标签是
	// "BLOOD ON THE DANCE FLOOR/ HIStory In The Mix"):网易云曲库缺失该艺人(整个
	// 目录都查不到,推测版权原因,跟周杰伦同一类问题)时原来直接退到 QQ 音乐,而 QQ
	// 音乐对这首歌唯一收录的版本偏偏就是"The Indispensable Collection"精选集
	// (qqCoverFallback 已经会用 albumScore 判定这个不对版,但判定完也没有更好的 QQ
	// 候选可选,只能将就用它)。resolveAppleMusicMatch 的专辑感知匹配(先按
	// "歌手+专辑名"整体搜索定位到专辑,查不到再退化成拉专辑完整曲目表本地比对标题,
	// 见 apple.go 注释)明显更强,而且这份数据本来就要为跳转链接查一次——实测这首歌
	// 用这条路径能查到正确专辑封面(itunesLookupTracks 兜底分支命中),QQ 音乐反而
	// 查不到。改成:网易云没有 → 先试 Apple Music 的封面,Apple 也没有 → 才退到 QQ
	// (维持"至少给个官方封面"的兜底,不会比改之前更容易返回空)。
	appleMatch := appleMusicMatchCached(artist, title, album)
	if e.CoverURL == "" && appleMatch.cover != "" {
		e.CoverURL = appleMatch.cover
		e.CoverSource = "apple"
	}
	if e.CoverURL == "" {
		// 网易云、Apple Music 都没有(或都没能给出可信封面)时的最后一道兜底——QQ
		// 音乐同一首歌的官方版封面,双重校验歌手名(搜索结果+详情接口各查一次)避免
		// QQ 侧的仿冒号蒙混过关;传入 album 让 qqCoverFallback 内部按 albumScore
		// 避开精选集/合辑顶替原始专辑封面。
		qqCover, qqArtist := qqCoverFallback(artist, title, album)
		e.CoverURL = qqCover
		if e.CoverURL != "" {
			e.CoverSource = "qq"
		}
		if e.CanonicalArtist == "" {
			e.CanonicalArtist = qqArtist
		}
	}
	if e.CanonicalArtist == "" {
		// MusicBrainz/网易云/QQ 都没能给出统一歌手名(常见于 title/album 本身就跨语言
		// 对不上文本的 feat. 曲目,见 artistAliasTable 注释)——用手工登记的已知艺名表兜底。
		e.CanonicalArtist = knownArtistAlias(artist)
	}
	if e.CoverURL != "" {
		// 封面主色调,供网页按专辑动态配色(浏览器读跨域封面像素会被 CORS 挡,故服务端算)。
		e.AccentColor = dominantColor(e.CoverURL)
	}
	// 各平台单曲跳转链接。Apple Music 中国区优先(iTunes Search)、QQ 经 smartbox、Spotify 搜索链接。
	// 复用上面封面兜底那步已经算出来的 appleMatch(同一个 key 缓存,不是重新发请求),
	// 不用再单独调一次 appleMusicURL。
	e.AppleURL = appleMatch.url
	e.QQURL = qqMusicURL(artist, title, album)
	if title != "" {
		e.SpotifyURL = "https://open.spotify.com/search/" + neturl.QueryEscape(artist+" "+title)
	}
	if features.Lyrics {
		if picked := pickLyricCandidate(scored); picked != nil {
			e.Lyrics = picked.Lyrics
			e.LyricsSource = picked.Source
			e.LyricsTr, e.LyricsRoma, e.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
		} else {
			// 没有任何源给出可用歌词——查一下 scored 里是否搭车带着"lrclib 明确说是
			// 纯音乐"这条标记(见 Instrumental 字段定义处的注释),命中就记下来,UI 侧
			// 才能把这种情况跟"真的谁都没搜到"区分开显示。
			for _, c := range scored {
				if c.Instrumental {
					e.Instrumental = true
					break
				}
			}
		}
	}
	return e
}

// pickLyricCandidate 从 scoredLyricCandidates 返回的全量候选里,按用户在"歌词"设置
// 分类里配置的"启用哪些源"+"挑选算法"选出最终采用的一条——只用于自动解析路径
// (resolveTrackEnrichment,上面)。手动的 `collector search-lyrics` CLI 子命令("歌词
// 管理"窗口的"重新搜索候选歌词"功能)不复用这个函数(它需要保留完整排序列表给用户挑,
// 不是只要一个赢家),但对"启用哪些源"这条设置口径一致——两条路径都只看你在设置里开着
// 的那几个源,只是手动搜索用的是 searchcli.go 里单独的 filterEnabledLyricSources,
// 不是直接调这个函数。
func pickLyricCandidate(scored []scoredLyricCandidateResult) *scoredLyricCandidateResult {
	if features.LyricsSourceMode == lyricsModePriority {
		for _, source := range features.LyricsSourceOrder {
			if !features.LyricsSources[source] {
				continue
			}
			for i := range scored {
				if scored[i].Source == source && scored[i].Score >= 0 {
					return &scored[i]
				}
			}
		}
		return nil
	}
	var picked *scoredLyricCandidateResult
	bestScore := -1
	for i := range scored {
		if !features.LyricsSources[scored[i].Source] {
			continue
		}
		if scored[i].Score < 0 || scored[i].Score <= bestScore {
			continue
		}
		bestScore = scored[i].Score
		picked = &scored[i]
	}
	return picked
}

// scoredLyricCandidateResult is one scored lyric candidate — exported shape (JSON
// tags) so it doubles as the `collector search-lyrics` CLI subcommand's stdout
// format for desktop-lyrics's manual "重新搜索候选歌词" picker.
type scoredLyricCandidateResult struct {
	Source        string `json:"source"`
	Lyrics        string `json:"lyrics"`
	LyricsTr      string `json:"lyrics_tr,omitempty"`
	LyricsRoma    string `json:"lyrics_roma,omitempty"`
	LyricsYRC     string `json:"lyrics_yrc,omitempty"`
	HasWordTiming bool   `json:"has_word_timing"`
	Score         int    `json:"score"`
	// Title/Artist/Album/CoverURL 是这个源实际匹配到的歌名/歌手/专辑/封面(不参与
	// 打分,见 lyricCandidate 的同名字段注释)——"搜索候选歌词"弹窗靠这几个字段展示
	// 每条候选具体对应哪首歌/哪个版本,不是只看来源名字。不是每个源都能给全:LRCLIB
	// 没有封面这个概念,QQ 这条路径也没查封面,留空是"这个源确实没有",不是 bug。
	Title    string `json:"title,omitempty"`
	Artist   string `json:"artist,omitempty"`
	Album    string `json:"album,omitempty"`
	CoverURL string `json:"cover_url,omitempty"`
	// Instrumental 标记这不是一条真正的歌词候选,是"lrclib 明确说这首歌是纯音乐"这个
	// 信号本身,借这个结构体的 Score:-1(pickLyricCandidate/priority 模式都会跳过负分)
	// 混进 scored 列表里"搭车"传出去,不需要为了传这一个 bool 单独改
	// fetchScoredLyricCandidatesStreaming 的返回值签名(它被 searchcli.go 的手动搜索
	// CLI 和 resolveTrackEnrichment 两条路径共用,改签名影响面更大)。手动搜索那边会把
	// 这条标记过滤掉,不会当成一条空歌词的候选显示给用户,见 searchcli.go
	// filterEnabledLyricSources 旁边的过滤。
	Instrumental bool `json:"instrumental,omitempty"`
}

// lyricSearchDeadline 给 fetchScoredLyricCandidates 整体加一个上限——五个源各自的
// HTTP client 都有自己的超时(4~10秒不等),但单个源内部可能串行链好几次请求才死心
// (网易云最多试 4 个搜索变体+详情+歌词,最坏能吃掉小三十秒;Musixmatch 的鉴权 token
// 每 9 分钟过期一次,过期后重新申请若被限流会主动 sleep 10 秒再试一次)——五个源本身
// 已经改成完全并发(见下面 fetchScoredLyricCandidates),但极端情况下(比如恰好赶上
// Musixmatch token 冷启动)仍可能让这一轮搜索卡到快一分钟。20秒给足了每个源自己独立
// 超时的空间,同时把最坏情况砍掉大半——到点还没回来的源,这一轮就不参与候选(不影响
// 它自己继续跑完、下次同一首歌缓存命中时照常能用上,只是这一次不等它)。这个常量同时
// 覆盖自动解析(resolveTrackEnrichment)和"歌词管理"的手动联网搜索(searchcli.go)两条
// 路径,因为它俩共用这同一个函数。
const lyricSearchDeadline = 20 * time.Second

// scoredLyricCandidates fetches netease/qq/kugou/musixmatch/lrclib concurrently
// (见 fetchScoredLyricCandidates),scores every candidate via scoreLyricCandidate,
// and returns all of them sorted best-first (not just the winner) — this is the
// one place both the auto-resolve path (resolveTrackEnrichment, above) and the
// on-demand `search-lyrics` CLI subcommand (searchcli.go) gather/score
// candidates, so there is exactly one implementation of "how do we rank lyric
// sources" in the whole project. Also returns the primary (non-alias) netease
// lookup — resolveTrackEnrichment needs it for cover/URL purposes regardless of
// whether the alias fallback below ends up supplying the returned lyric results.
//
// Apple Music 有时把歌手标签写成该歌手的英文/罗马化艺名,但网易云/QQ/酷狗/LRCLIB
// 这四个源都是按歌手的中文舞台名索引/检索的——拿英文艺名去查,返回的候选是彻底的空
// (不是排序/打分选不出好结果,是检索关键词本身就没命中任何东西)。Musixmatch 是
// 例外(国际曲库,英文/罗马化艺名反而更容易命中),不受这条别名兜底针对的问题影响,
// 但它跟其它四个源共用同一个"全空才兜底"的判断——如果 Musixmatch 已经查到候选,
// results 就不是空的,不会触发下面的别名重试(该重试本来也没必要,问题不在它身上)。
// 五个源全空(len(results)==0,不是"候选都被判负分")才触发兜底:用 artistAliasTable
// 里已经手工登记过的别名换关键词、原样重新查一遍——没有登记别名、或别名跟原名相同,
// 就不重试;只重试这一次,不做别名的别名(表里也没有这种链式登记),换别名查到的结果
// 为空就仍然如实返回原来那份空结果,不伪造候选。别名重试只影响歌词候选,不影响返回
// 的 ne(见下面 return ne, results 那一行,不是 aliasNe)——封面/跳转链接这些字段永远
// 用原始歌手名查出来的结果,这是重构前就有的行为,这里保持不变。
func scoredLyricCandidates(artist, title, album string, durationSecs float64) (neteaseInfo, []scoredLyricCandidateResult) {
	return scoredLyricCandidatesStreaming(artist, title, album, durationSecs, func(neteaseInfo, []scoredLyricCandidateResult) {})
}

// scoredLyricCandidatesStreaming 是 scoredLyricCandidates 的流式版本(见
// fetchScoredLyricCandidatesStreaming 顶部注释)——onUpdate 一路透传给主查询和(如果
// 触发了)别名重试查询,所以手动搜索(searchcli.go)在别名重试这条冷门路径上也能看到
// 陆续到达的候选,不会因为切换成了 alias 重试就突然掉回"等全部查完才展示"。
func scoredLyricCandidatesStreaming(artist, title, album string, durationSecs float64, onUpdate func(neteaseInfo, []scoredLyricCandidateResult)) (neteaseInfo, []scoredLyricCandidateResult) {
	ne, results := fetchScoredLyricCandidatesStreaming(artist, title, album, durationSecs, onUpdate)
	if len(results) > 0 {
		return ne, results
	}
	alias := knownArtistAlias(artist)
	if alias == "" || alias == artist {
		return ne, results
	}
	_, aliasResults := fetchScoredLyricCandidatesStreaming(alias, title, album, durationSecs, onUpdate)
	if len(aliasResults) > 0 {
		log.Printf("lyrics: artist alias fallback succeeded: original_artist=%q alias=%q title=%q candidates=%d", artist, alias, title, len(aliasResults))
		return ne, aliasResults
	}
	return ne, results
}

// fetchScoredLyricCandidates 是真正"拿这一个具体的歌手名字符串,去查网易云/QQ/酷狗/
// Musixmatch/LRCLIB 五个源、给查到的候选打分"的实现——从 scoredLyricCandidates 里
// 拆出来,是为了在第一次用原始歌手名查询彻底查无候选时,能原封不动地对已知别名再
// 调用一遍(见 scoredLyricCandidates 上面的注释),而不必把并发抓取/打分这套逻辑抄
// 第二遍。只关心最终这一批结果的调用方(resolveTrackEnrichment/别名重试)走这个
// 薄封装;真正的实现在下面 fetchScoredLyricCandidatesStreaming,onUpdate 传空函数。
func fetchScoredLyricCandidates(artist, title, album string, durationSecs float64) (neteaseInfo, []scoredLyricCandidateResult) {
	return fetchScoredLyricCandidatesStreaming(artist, title, album, durationSecs, func(neteaseInfo, []scoredLyricCandidateResult) {})
}

// fetchScoredLyricCandidatesStreaming 是实际实现:五个歌词源(含网易云)+ 一路
// Apple Music/iTunes 封面兜底,真正一起并发发出去,用带缓冲的 channel 收集结果——
// 之前网易云是在这个函数之外单独同步查一遍(resolveTrackEnrichment 为了封面/跳转
// 链接需要它),等它查完了才轮到这里的 qq/酷狗/Musixmatch/LRCLIB 四个开始并发,相当
// 于白白把网易云自己最坏能到小三十秒的串行耗时,原样叠加在了整体等待时间最前面——
// 搬进同一批 goroutine 后,网易云的耗时不再阻塞其它源起步,只跟它们一起被下面的
// lyricSearchDeadline 兜底。用 channel 而不是"WaitGroup+共享变量"是为了让超时后
// "放弃继续等、先用已经到手的候选"这件事是并发安全的:哪怕某个源在超时之后才真正
// 返回,它往 channel 送结果这个动作本身不会阻塞(channel 容量=goroutine 数量),
// 也不会跟已经不再读取的这边产生数据竞争,那个晚到的结果就单纯被丢弃,不影响这一轮
// 的候选列表。
//
// Apple Music/iTunes 这一路不产生候选歌词,只提供一个"通用封面兜底"——QQ 这条路径
// 没查封面(会多一次网络请求,不值得为了封面拖慢刚优化好的并发搜索)、酷狗接口压根
// 没有可靠的封面字段、LRCLIB 没有封面这个概念,但 iTunes Search 曲库覆盖面很广(实测
// 中文流行曲目也查得到),而且这个查询本来就要为"App 联动跳转链接"发一遍(见
// resolveTrackEnrichment 的 appleMusicURL 调用,两处共用同一份 appleURLCache,见
// apple.go),这里顺路复用,不算额外成本。哪个候选自己有封面(网易云/Musixmatch)
// 就用自己的,没有的(QQ/酷狗/LRCLIB)才用这个兜底,见下面 scoreAndSort 里的
// coverOrFallback。
//
// onUpdate 在每个源的结果到达(不只是全部到齐那一刻)后都会被调用一次,携带当前已知
// 全部候选重新算出的完整排序结果——这是给 search-lyrics CLI 的"手动搜索陆续展示"
// 用的(searchcli.go),让用户不用等最慢的那个源(或者等到 20 秒兜底超时)才看到任何
// 结果,谁先回来就先看到谁,列表随后续到达的源继续刷新。之所以每次都重新算完整列表、
// 而不是"只把这一个新来源追加进去",是因为 corroboratedEndings(见 match.go)是跨候选
// 互相印证的信号——后到的源可能会让已经展示出来的某条候选的可信度分数往上修正,重新
// 算一遍整个列表才能让分数/排序始终反映"目前已知的全部信息",不会出现"先看到的候选
// 分数再也不会变"这种半截状态。fetchScoredLyricCandidates(上面)只关心最终结果,传一
// 个空函数复用这同一份实现。
func fetchScoredLyricCandidatesStreaming(artist, title, album string, durationSecs float64, onUpdate func(neteaseInfo, []scoredLyricCandidateResult)) (neteaseInfo, []scoredLyricCandidateResult) {
	type sourceResult struct {
		source                  string
		ne                      neteaseInfo
		lyr, yrc, tr            string
		matchTitle, matchArtist string
		matchAlbum, matchCover  string
		instrumental            bool // 目前只有 lrclib 这个源会给出这个信号,见 lrclibResult 注释
	}
	resultsCh := make(chan sourceResult, 6)

	go func() {
		resultsCh <- sourceResult{source: "netease", ne: neteaseLookup(artist, title, album)}
	}()
	go func() {
		// qqMusicMatchCached 本身也是一次网络请求(smartbox 搜索,6秒超时,按
		// artist|title|album 缓存)——挪进这个 goroutine 一起并发,不再是这个函数最
		// 前面的一步单独阻塞;resolveTrackEnrichment 那边为封面/跳转链接另外调用
		// qqMusicURL 时会命中这里可能已经写热的缓存,反过来也一样,谁先算出来谁写
		// 缓存,不要求哪边一定在前(两者共用同一份 qqURLCache,见 qq.go)。
		match := qqMusicMatchCached(artist, title, album)
		qqMid := qqMidFromURL(match.url)
		var lyr, yrc string
		if qqMid != "" {
			lyr = qqLyric(qqMid)
			// 逐字(QRC)是完全独立的一套接口/密钥,自己失败不影响上面整行歌词——
			// 见 qq.go 顶部注释。
			yrc = qqQRCLyric(qqMid, artist, title, album, durationSecs)
		}
		resultsCh <- sourceResult{source: "qq", lyr: lyr, yrc: yrc, matchTitle: match.title, matchArtist: match.artist, matchAlbum: match.album}
	}()
	go func() {
		r := kugouLyric(artist, title, durationSecs)
		resultsCh <- sourceResult{source: "kugou", lyr: r.lrc, yrc: r.yrc, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album}
	}()
	go func() {
		r := lrclibLyric(artist, title, album, durationSecs)
		resultsCh <- sourceResult{source: "lrclib", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, instrumental: r.instrumental}
	}()
	go func() {
		r := musixmatchLyric(artist, title, durationSecs, features.LyricsTranslationLanguage)
		resultsCh <- sourceResult{source: "musixmatch", lyr: r.lrc, yrc: r.yrc, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover}
	}()
	go func() {
		// 跟 resolveTrackEnrichment 里 e.AppleURL = appleMatch.url 共用同一份
		// appleURLCache——谁先查到谁写缓存,这里不重复消耗一次网络请求。
		resultsCh <- sourceResult{source: "applecover", matchCover: appleMusicMatchCached(artist, title, album).cover}
	}()

	var ne neteaseInfo
	var qqLyr, qqYRC, qqTitle, qqArtist, qqAlbum string
	var kugouLyr, kugouYRC, kugouTitle, kugouArtist, kugouAlbum string
	var lrclibLyr, lrclibTitle, lrclibArtist, lrclibAlbum string
	var lrclibInstrumental bool
	var mxLyr, mxYRC, mxTr, mxTitle, mxArtist, mxAlbum, mxCover string
	var appleCover string
	// scoreAndSort 用目前为止已经到手的原始结果重新构建候选、算 corroboratedEndings、
	// 打分、排序——每次有新结果到达都会重新跑一遍(而不是缓存增量),因为一份候选的
	// corroborated 状态可能随后到的源变化(见上面 onUpdate 的注释),分数不是只增不改
	// 的东西,不能靠增量更新蒙混过去。
	scoreAndSort := func() []scoredLyricCandidateResult {
		// coverOrFallback:候选自己的源有封面就用自己的(网易云/Musixmatch),没有就用
		// Apple Music/iTunes 那路通用兜底(QQ/酷狗/LRCLIB)——即使 appleCover 这一刻
		// 还没到(还在并发查),先留空,后面 applecover 到达触发的下一轮 onUpdate/最终
		// 返回会自然补上,不需要特殊处理"到达顺序"。
		coverOrFallback := func(own string) string {
			if own != "" {
				return own
			}
			return appleCover
		}
		var candidates []lyricCandidate
		if ne.Lyrics != "" {
			candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.Lyrics, wordTimingYRC: ne.YRC, hasWordTiming: ne.YRC != "", title: ne.Title, artist: ne.Artist, album: ne.Album, cover: coverOrFallback(ne.Cover)})
		}
		if qqLyr != "" {
			candidates = append(candidates, lyricCandidate{source: "qq", lyrics: qqLyr, wordTimingYRC: qqYRC, hasWordTiming: qqYRC != "", title: qqTitle, artist: qqArtist, album: qqAlbum, cover: coverOrFallback("")})
		}
		if kugouLyr != "" {
			candidates = append(candidates, lyricCandidate{source: "kugou", lyrics: kugouLyr, wordTimingYRC: kugouYRC, hasWordTiming: kugouYRC != "", title: kugouTitle, artist: kugouArtist, album: kugouAlbum, cover: coverOrFallback("")})
		}
		if mxLyr != "" {
			candidates = append(candidates, lyricCandidate{source: "musixmatch", lyrics: mxLyr, wordTimingYRC: mxYRC, hasWordTiming: mxYRC != "", title: mxTitle, artist: mxArtist, album: mxAlbum, cover: coverOrFallback(mxCover)})
		}
		if lrclibLyr != "" {
			candidates = append(candidates, lyricCandidate{source: "lrclib", lyrics: lrclibLyr, title: lrclibTitle, artist: lrclibArtist, album: lrclibAlbum, cover: coverOrFallback("")})
		}
		corroborated := corroboratedEndings(candidates)
		// lrclib 明确说这首歌是纯音乐、且没有真的歌词候选(lrclibLyr=="")时,搭车塞一条
		// Score:-1 的标记进 results——见 Instrumental 字段定义处的注释,不参与打分/排序,
		// 不会被 pickLyricCandidate 选中,只是把这个信号原样带出这个函数。
		var instrumentalMarker *scoredLyricCandidateResult
		if lrclibLyr == "" && lrclibInstrumental {
			instrumentalMarker = &scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true}
		}

		results := make([]scoredLyricCandidateResult, 0, len(candidates))
		for _, c := range candidates {
			r := scoredLyricCandidateResult{
				Source:        c.source,
				Lyrics:        c.lyrics,
				LyricsYRC:     c.wordTimingYRC,
				HasWordTiming: c.hasWordTiming,
				Score:         scoreLyricCandidate(artist, title, durationSecs, c, corroborated[c.source]),
				Title:         c.title,
				Artist:        c.artist,
				Album:         c.album,
				CoverURL:      c.cover,
			}
			switch c.source {
			case "netease":
				// 翻译/罗马音网易云固定给中文;QQ/酷狗这次只接了逐字,不接翻译/罗马音,
				// 见计划"刻意不做的"。
				r.LyricsTr, r.LyricsRoma = ne.Trans, ne.Roma
			case "musixmatch":
				// Musixmatch 的译文语言是用户在"歌词"设置里配的
				// LyricsTranslationLanguage(ISO 639-1 代码),不像网易云固定中文——
				// 见 musixmatchTranslationLRC 注释。没配置/没查到社区翻译时 mxTr 是
				// 空串,r.LyricsTr 保持空,不影响这条候选本身的原文歌词。
				r.LyricsTr = mxTr
			}
			results = append(results, r)
		}
		if instrumentalMarker != nil {
			results = append(results, *instrumentalMarker)
		}
		sort.Slice(results, func(i, j int) bool { return results[i].Score > results[j].Score })
		return results
	}

	deadline := time.After(lyricSearchDeadline)
collect:
	for i := 0; i < 6; i++ {
		select {
		case r := <-resultsCh:
			switch r.source {
			case "netease":
				ne = r.ne
			case "qq":
				qqLyr, qqYRC, qqTitle, qqArtist, qqAlbum = r.lyr, r.yrc, r.matchTitle, r.matchArtist, r.matchAlbum
			case "kugou":
				kugouLyr, kugouYRC, kugouTitle, kugouArtist, kugouAlbum = r.lyr, r.yrc, r.matchTitle, r.matchArtist, r.matchAlbum
			case "lrclib":
				lrclibLyr, lrclibTitle, lrclibArtist, lrclibAlbum = r.lyr, r.matchTitle, r.matchArtist, r.matchAlbum
				lrclibInstrumental = r.instrumental
			case "musixmatch":
				mxLyr, mxYRC, mxTr, mxTitle, mxArtist, mxAlbum, mxCover = r.lyr, r.yrc, r.tr, r.matchTitle, r.matchArtist, r.matchAlbum, r.matchCover
			case "applecover":
				appleCover = r.matchCover
			}
			onUpdate(ne, scoreAndSort())
		case <-deadline:
			log.Printf("lyrics: search deadline (%s) hit for artist=%q title=%q, proceeding with %d/6 sources back", lyricSearchDeadline, artist, title, i)
			break collect
		}
	}

	return ne, scoreAndSort()
}

// loadEnrichCache reads the persisted enrichment cache (best-effort) and sets the
// path future saves write to. Call once at startup.
func loadEnrichCache(path string) {
	enrichPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]enrichEntry
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		enrichMu.Lock()
		enrichCache = m
		enrichMu.Unlock()
		log.Printf("loaded %d cached track enrichments from %s", len(m), path)
	}
}

// saveEnrichCache atomically writes the cache when dirty (temp file + rename).
func saveEnrichCache() {
	enrichMu.Lock()
	if !enrichDirty || enrichPath == "" {
		enrichMu.Unlock()
		return
	}
	data, err := json.Marshal(enrichCache)
	enrichDirty = false
	enrichMu.Unlock()
	if err != nil {
		return
	}
	// 临时文件名带进程号:固定的 ".tmp" 一旦有两个写入方(collector 自己 + 未来任何别的
	// 写入者,或同一进程里并发走到这里)就会互相覆盖同一个临时文件,rename 出去的可能是
	// 半份别人的内容 —— 那样"先写 tmp 再 rename"这套原子性就白做了。
	tmp := fmt.Sprintf("%s.tmp.%d", enrichPath, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, enrichPath); err != nil {
		log.Printf("save enrich cache: %v", err)
	}
}
