// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"math"
	neturl "net/url"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
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
	// CoverSource/LyricsSource 记录封面/歌词实际来自哪个平台("netease"/"qq"/"lrclib"/"amll"…),
	// 供网页页脚如实展示(而不是写死"来自网易云"——封面/歌词各自可能来自不同平台,或者
	// 干脆哪个平台都没有)。
	CoverSource  string `json:"cover_source,omitempty"`
	LyricsSource string `json:"lyrics_source,omitempty"`
	// CoverAlbum 是这张封面在**来源平台上所属的专辑名**。存它是为了事后能判断
	// "这张封面对不上正在播的这张专辑" —— 见 preferAppleCoverOverNetease 与
	// coverNeedsAlbumCheck。老条目没有这个字段(读成空 = 不详)。
	//
	// ⚠️ 这是 enrichEntry 里唯一一个"记录另一个实体的名字"的字段,别拿它当展示用:
	// 网页页脚要显示的是 CoverSource(封面来自哪个平台),不是这个。
	CoverAlbum string `json:"cover_album,omitempty"`
	// LyricsScore/LyricsSourcesSeen 记录"这条歌词是在什么情况下选出来的",给
	// needsLyricsRetry 判断值不值得再搜一次用。
	//
	// 背景(2026-08-07 实测复现):五源搜索有 20 秒总上限(lyricSearchDeadline),到点没回来
	// 的源这一轮直接不参与候选;而网易云恰恰是最慢、也最可能带逐字歌词的那个。实测同一首
	// 「悟空 2003 Demo」连查两次:一次 3 秒返回、候选里**根本没有网易云**,lrclib 以 83 分
	// 胜出;另一次跑满 20 秒,网易云回来了、525 分带逐字。也就是说选中哪个源有相当大的运气
	// 成分 —— 而缓存又是"解析一次永久保留",于是那一瞬间的运气被永久固化。
	LyricsScore       int      `json:"lyrics_score,omitempty"`
	LyricsSourcesSeen []string `json:"lyrics_sources_seen,omitempty"`
	// 这一轮**应答过**的源(哪怕候选被判负分)。跟上面 SourcesSeen 的区别、以及为什么
	// 两个都要存,见 lyricSourcesResponded 的注释和 decision.go —— "回了烂候选"和
	// "超时没露面"是两种不同的坏,以前只有前者的口径落盘,事后分不出。
	LyricsSourcesResponded []string `json:"lyrics_sources_responded,omitempty"`
	// 最近一次完整评估的决策记录(候选表+得分明细,只存元数据),见 decision.go。
	// ⚠️ 只写不读:解析逻辑不许拿它当输入。
	LyricsDecision *lyricsDecision `json:"lyrics_decision,omitempty"`
	// **当前生效歌词的出处**:最近一次"胜者内容成为(或确认仍是)当前歌词"的那轮评估。
	// 跟上面 LyricsDecision(最近一次评估,可能维持原状、甚至输入本身是脏的)分槽存,
	// 详情页才能永远解释"现在这份词是谁、凭什么选的"。2026-08-22 实测坐实必须分槽:
	// 一轮被换曲窗口串扰时长(见 observeWrongDuration)的 upgrade 评估把 first-resolve
	// 的存档盖掉了,用户在「解析决策」里看到的记录跟生效歌词完全对不上号。
	// 同样只写不读。
	LyricsDecisionApplied *lyricsDecision `json:"lyrics_decision_applied,omitempty"`
	// 升级重试的节流与上限,见 needsLyricsRetry。
	LyricsRetryTS    int64 `json:"lyrics_retry_ts,omitempty"`
	LyricsRetryCount int   `json:"lyrics_retry_count,omitempty"`
	// "当初一条歌词都没搜到"那条重试路径的节流与计数,见 needsLyricsFirstFill。
	// 跟上面那两个字段刻意分开:那一对记的是"有歌词、想升级到更好的源",这一对记的是
	// "压根没有歌词、还在等第一次填上"。混用一个计数器会让一首歌先耗完补空的次数、
	// 以后真需要升级时无从判断。
	LyricsFillTS    int64 `json:"lyrics_fill_ts,omitempty"`
	LyricsFillCount int   `json:"lyrics_fill_count,omitempty"`
	// 这份歌词是按多少秒的曲目时长校验选出来的(0 = 旧条目/当时不知道时长)。
	// 存在的理由:专辑预取(albumprefetch.go)拿的是**网易云版本**的时长,跟用户实际
	// 播放的版本可能是两个版本 —— 2026-08-16 实锤:网易云《梦想家》里 Tango 是 2:44,
	// Spotify 播的是 ~4:06,预取按 164s 校验选了给短版对轴的歌词(末行 2:01),整首歌
	// 歌词提前、唱到一半歌词就放完了。真播放时长跟这个值对不上 → 按真实时长重选一次。
	ResolvedDurationSecs float64 `json:"resolved_duration_secs,omitempty"`
	// LyricsScoringVersion 记录这条歌词是按哪一版打分规则选出来的(见 lyricsScoringVersion),
	// LyricsRescoreCount/LyricsRescoreTS 是按新规则重选的已尝试次数与上次尝试时间
	// (见 needsLyricsRescore)。没有这些字段的老条目会读成 0,一律落后于当前版本 ——
	// 正是想要的:它们确实是按更老的规则选的。
	LyricsScoringVersion int   `json:"lyrics_scoring_version,omitempty"`
	LyricsRescoreCount   int   `json:"lyrics_rescore_count,omitempty"`
	LyricsRescoreTS      int64 `json:"lyrics_rescore_ts,omitempty"`
	// 外围字段补全的已尝试次数,见 needsPeripheralBackfill 的上限说明。
	PeripheralRetryCount int `json:"peripheral_retry_count,omitempty"`
	// 解析这条时用的曲目真实时长(秒)。存下来是给"歌词管理"的手动搜索用的:打分里
	// 时长匹配那一档权重很重,而手动搜索以前只能传 0(浏览的是任意历史缓存条目、拿不到
	// 时长),于是弹窗里显示的排名跟当初真正做决定用的那组分数不是一回事 —— 2026-08-07
	// 用户就是这么被误导的:弹窗显示 qq 482 最高,而自动决策时(带时长)是 Musixmatch 962
	// 胜出。存下来之后两边口径就一致了。
	DurationSecs float64 `json:"duration_secs,omitempty"`
	// LyricsTrSource 记录 lyrics_tr 是哪来的:空 = 歌词源自带的社区翻译(网易云/Musixmatch),
	// "machine" = translate.go 机翻补的。UI 据此如实标注,不让机翻冒充社区翻译 —— 跟页脚
	// "歌词来自 XX" 是同一个原则。老条目没有这个字段,读成空 = 社区翻译,正是事实。
	LyricsTrSource string `json:"lyrics_tr_source,omitempty"`
	// LyricsTrLang 是 lyrics_tr 实际所用的语言(ISO 639-1,可带地区)。
	//
	// 存它是因为**译文的语言未必是用户当前想要的那个**:网易云的社区译文永远是中文,
	// Musixmatch 的是抓取当时设置里的那个语言,机翻的是当时的目标语言 —— 三者都可能跟
	// 现在的设置对不上。没有这个字段就只能"有译文就当数",于是设成日语的用户拿到一首
	// 网易云歌词时,永远只会看到那份中文社区译文(见 needsTranslationBackfill)。
	//
	// 空 = 语言不详(老条目,或用户在 lyrics/ 目录里手改过译文),此时退回文本判别。
	LyricsTrLang string `json:"lyrics_tr_lang,omitempty"`
	// 机翻补全的已尝试次数与上次尝试时间,见 needsTranslationBackfill。
	// TranslationLang 是这些次数**针对哪个目标语言**累计的:换了语言以后,上一门语言的
	// 失败次数(比如那时语言包没装)不该继续把新语言的尝试挡在门外。
	TranslationRetryCount int    `json:"translation_retry_count,omitempty"`
	TranslationTS         int64  `json:"translation_ts,omitempty"`
	TranslationLang       string `json:"translation_lang,omitempty"`
	// ManualLyrics 标记这条歌词是用户在 desktop-lyrics 的"歌词管理"窗口里手动纠正/采纳
	// 过的。除了给 UI 显示"人工修正"徽章,它还是**所有自动重搜路径的一道否决闸**:
	// needsLyricsRetry / needsLyricsRescore 都必须先看它。用户手改过的歌词是这套缓存里
	// 唯一删了就找不回来的东西(重新解析只会又抓到当初那份不准的),自动逻辑没有任何理由
	// 觉得自己比人工更懂。
	ManualLyrics bool `json:"manual_lyrics,omitempty"`
	// LyricsSourceChoice 记「用户在「联网搜索候选歌词」里选定了哪个源」——**只是选源,
	// 不是手改内容**。2026-08-22 加。
	//
	// 加它是为了把此前压在 ManualLyrics 一个标记上的两件事拆开:
	//   - "我手工改过正文" → 一票否决所有自动路径(那份内容删了就找不回来,自动逻辑没有
	//     任何理由觉得自己比人工更懂)—— 这才是 ManualLyrics 的本意;
	//   - "我不同意这次自动选择,换个源" → 只该约束**选哪个源**。
	// 采纳一条候选就置 ManualLyrics 的代价是:这首歌从此永久冻结,以后打分规则改进、
	// 那个源后来开始给逐字时间轴,都再也不会被采纳 —— 而用户当初只是想换个源。
	//
	// 语义:非空时,自愈路径(升级重试 / rescore)**照常跑**,但重选被约束在这个源内
	// (pickLyricCandidatePreferring)。于是"同一个源给出了更好的内容"仍然能升上来,
	// "被换成另一个源"不会发生。那个源这一轮没给出候选时就不换,而不是退回全局最优。
	LyricsSourceChoice string `json:"lyrics_source_choice,omitempty"`
	// Instrumental 标记"联网查过了,至少一个源(lrclib 的 instrumental,或网易云的
	// pureMusic / 纯音乐占位正文)明确说这首歌是纯音乐"——
	// 跟"Lyrics 为空"要分开看:后者也可能是"五个源都没查到、真的没搜到"这种更含糊的
	// 情况(用户可能想手动重新搜索候选歌词试试),前者是有明确依据的结论,UI 上应该
	// 显示成"纯音乐"而不是笼统的"无歌词"。2026-08-03 补上——这个信号 lrclib.go 里
	// 原来读了就直接丢,见 lrclibResult 定义处的注释。
	Instrumental bool `json:"instrumental,omitempty"`
	// TS 是**这条记录当初被解析出来的时刻**,不再是任何一种节流时间戳。它现在只被
	// needsLyricsRetry 当作"歌词重搜"6 小时间隔的起算点。
	//
	// 2026-08-09 把外围补全的节流拆到 PeripheralTS 之前,这一个字段同时担着两个互不相干
	// 的职责:外围补全每跑一次就把它推到当下(最多 5 次、每次隔 10 分钟),而歌词重搜的
	// 起算点正是它 —— 于是补个封面主色就能把"去别的源再搜一遍歌词"这件事整体往后推近
	// 一小时。两者本来毫无关系,只是恰好共用了一个字段。
	TS int64 `json:"ts"`
	// PeripheralTS 是外围字段补全**上一次尝试**的时刻,只给 needsPeripheralBackfill 节流用。
	// 老条目没有这个字段(读成 0),此时回退到 TS —— 那正是拆分之前的语义,不会让存量条目
	// 在升级后一股脑全部立刻重试一遍。
	PeripheralTS int64 `json:"peripheral_ts,omitempty"`
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
// canonicalEnrichKey 在已有缓存里找一个"只差大小写"的等价 key。
//
// 同一首歌会被不同来源报成不同大小写:本机 Apple Music 给的是专辑元数据的原始写法
// (PRINCE / "Get on the Boat"),而 Last.fm 桥接(bridge → remoteTrack → relayState →
// lbMeta → 这里)给的是 Last.fm 自己规范化过的写法(Prince / "Get On The Boat")。
// key 是 artist|title|album 拼出来的、大小写敏感,于是同一首歌被存成两条:
//
//   - "歌词管理"列表里出现重复行(2026-08-13 用户实测:Prince 的 3121 专辑 12 首歌
//     存成了 15 条,重复的三对差别只在 PRINCE/Prince 和 "on the"/"On The")
//   - 第二条要白跑一轮五源歌词搜索
//   - lyrics/ 里多出一份内容几乎相同的 .lrc 导出文件
//
// 线性扫而不是维护一份小写索引:写入点分散在四条补全路径里,维护索引得每处都记得同步
// (这个仓库里已经有过几次"漏同步一处"的教训),而这里的规模是几百条、每轮轮询扫一遍
// 也就几十微秒。
//
// ⚠️ 调用方必须已经持有 enrichMu。
//
// 2026-08-16 从"只差大小写"扩到"大小写 + 空格 + 繁简"。起因是用户在「歌词管理」里看到
// 成对的重复,全库 108 条实测有 14 组 29 条:
//
//	陶喆|Susan 说|太平盛世        vs  陶喆|Susan说|太平盛世          (差一个半角空格)
//	方大同|千纸鹤|回到未來        vs  方大同|千紙鶴|回到未來          (繁简)
//	孙燕姿|我怀念的|逆光 / 孙燕姿|我懷念的|逆光 / 孫燕姿|我懷念的|逆光  (三条,歌手名也繁简不一)
//
// 空格和繁简这两档正好漏在既有的两道防线中间:cleanMediaTag 只统一不可见空白、折叠
// **连续**空白(单个半角空格既不删也不插),而这里原来只 ToLower(不动任何空白、更不动字形)。
func canonicalEnrichKey(key string) (string, bool) {
	loose := loosenEnrichKey(key)
	// ⚠️ 必须挑出**确定的**那一条,不能"遍历时撞见谁就用谁"—— Go 的 map 遍历顺序是随机的,
	// 而缓存里真的存在一个宽松键对应多条的情况(上面孙燕姿那组是三条)。随机命中的后果是
	// 同一首歌这次读到 A 的歌词、下次读到 B 的,时间轴还可能不一样,排查起来像见了鬼。
	// 用 betterEnrichEntry 挑最好的那条 —— 跟迁移合并时的胜者规则同一套,两处结论一致。
	best := ""
	for existing, e := range enrichCache {
		if existing == key || loosenEnrichKey(existing) != loose {
			continue
		}
		if best == "" || betterEnrichEntry(e, enrichCache[best], existing, best) {
			best = existing
		}
	}
	if best == "" {
		return "", false
	}
	return best, true
}

// looseInflightKey 在**正在后台解析**的队列里找宽松等价的 key。
//
// ⚠️ 光有 canonicalEnrichKey 挡不住重复,这是 2026-08-16 被真实数据打脸后补的:
// 那天下午刚把 14 组重复合并干净,晚上 19:57 和 19:58 又新长出一对
// `方大同|春風吹之吹吹風mix|愛愛愛` / `方大同|春风吹之吹吹风mix|愛愛愛`(相隔 18 秒)。
//
// 机制是竞态:canonicalEnrichKey 查的是 enrichCache,而第一条这时还**只在
// enrichInflight 里**、解析没回来、一个字都还没写进 enrichCache。第二条(另一个写入
// 路径报了另一种拼法)来查,缓存里当然找不到等价条目,于是各自起一路解析、各自写入。
// 两条路径先后差十几秒,正好落在这个窗口里。
//
// 所以"要不要发起解析"的判断必须**同时**宽松地查缓存和在途队列,少一个就还会漏。
//
// ⚠️ 调用方必须已经持有 enrichMu。
func looseInflightKey(key string) (string, bool) {
	if enrichInflight[key] {
		return key, true
	}
	loose := loosenEnrichKey(key)
	for k := range enrichInflight {
		if loosenEnrichKey(k) == loose {
			return k, true
		}
	}
	return "", false
}

// loosenEnrichKey 把 key 压成"用来判断是不是同一首歌"的宽松形态。
//
// ⚠️ 结果**只用于比对**,绝不写进 enrichCache 当 key、绝不用于显示、绝不用于文件名。
// 这条边界是整个修法的关键:
//   - 归一化写进 **key**,就要求 Swift 侧 EnrichCacheKeys 逐字节复刻同一套规则,否则两边
//     算出的 key 对不上,表现是「悬浮窗整首歌没词」(EnrichCacheReader 是纯精确命中,
//     那边注释自己写过这个后果)。而繁简这一档 Go 走内嵌 OpenCC 词典、Swift 走
//     CFStringTransform(ICU),两者对部分字本来就不一致,根本复刻不了。
//   - 归一化只用于**查询兜底**,两侧不一致的后果就温和得多:某个字兜不到,退化成改动前的
//     行为(多一条重复),而不是查不到歌词。
//
// 所以:key 一个字节不改,宽松只活在比对这一层。
func loosenEnrichKey(key string) string {
	// 合 credit 的分隔符也折平(2026-08-20 加):同一次播放里两条路径对多歌手串的写法
	// 系统性不同 —— 播放器(media-control)报 `VALORANT/Grabbitz/bbno$`,而专辑预取从
	// Apple Music 自己的曲目表(AppleScript `artist of t`)拿到的是
	// `VALORANT & Grabbitz & bbno$`。实测缓存里因此长出 12 组、24 条只差分隔符的重复
	// (Arcane 原声带、VALORANT、K/DA… 全是多歌手曲目),而且两条相隔只有 2~8 秒:
	// 预取本来有 canonicalEnrichKey + looseInflightKey 两道宽松查重,但它们都建立在
	// 这个函数上,折不平分隔符就一起失效。
	//
	// 分隔符集合直接复用 isArtistCreditSep(match.go),别在这里再抄一份 —— 那边加了
	// 新分隔符,这边要跟着生效。全部映射成 '&'(挑哪个字符不重要,只要唯一)。
	folded := strings.Map(func(r rune) rune {
		if isArtistCreditSep(r) {
			return '&'
		}
		return r
	}, toSimplified(key))
	return strings.ToLower(strings.ReplaceAll(folded, " ", ""))
}

func trackEnrichment(artist, title, album, bundleID string, durationSecs float64) map[string]string {
	if title == "" {
		return nil
	}
	// 广告不能拿去搜歌词:qqMusicURL()/e.SpotifyURL 这两路兜底链接只要 title!="" 就会给出
	// 非空值,导致 resolveEnrichAsync 的"全空不写入"判断永远不成立,广告标题会被当成一首
	// "歌"永久写进磁盘缓存、污染"歌词管理"列表,还白跑一轮网络搜索。判据见 isAdBreak。
	if isAdBreak(bundleID, artist, title, album) {
		return nil
	}
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		// 精确没命中时,再看看已有条目里有没有"只差大小写/空格/繁简"的同一首歌 —— 有就
		// 复用那个 key,别另存一份。理由见 canonicalEnrichKey。
		if alt, found := canonicalEnrichKey(key); found {
			log.Printf("enrich: reusing existing entry %q for %q (loose match)", alt, key)
			key, e, ok = alt, enrichCache[alt], true
		}
	}
	if ok {
		// 用户校准过这首歌的歌词时间轴吗 —— 两条"自动重选歌词源"的路径共用这一次判定
		// (见 lyricspins.go)。放在这里而不是各自函数里面:那两个判定要保持纯函数,
		// 好让单测不碰文件系统就能覆盖"被 pin 住就不重选"。
		pinned := lyricsPinned(key)
		// 「时长对不上」的原始观察值先过稳定性去抖再交给重试判定 —— 换曲/预载窗口里的
		// 混合快照(当前标题 + 下一首的时长)是一次性的脏值,直接当真会白烧重试预算、
		// 还把决策记录盖掉,见 observeWrongDuration。每次进来都要喂一口(包括时长又对上
		// 的观察,它负责清零),所以放在分支链外面。
		wrongDuration := observeWrongDuration(key,
			durationMismatch(e.ResolvedDurationSecs, durationSecs), durationSecs, time.Now().Unix())
		// 一次只跑一路后台任务(都会重新取锁改同一条记录),下次播放时轮到下一个。
		// 重选排在升级重试前面:后者用旧分做"严格更高"的比较,而版本落后的条目那个旧分
		// 本来就作废了,先按新规则重选一次再谈升级才有意义。
		if needsPeripheralBackfill(e, artist, album) && !enrichInflight[key] {
			enrichInflight[key] = true
			go backfillPeripheralFields(key, artist, title, album, durationSecs)
		} else if needsLyricsFirstFill(e) && !enrichInflight[key] {
			// "条目已存在但一条歌词都没有" —— 这条 2026-08-17 才补上,在此之前它落在所有
			// 路径之外、一首歌搜砸一次就永久卡住,见 needsLyricsFirstFill 的注释。
			// 排在下面两条前面无所谓先后:那两条对空歌词条目都直接 return false。
			enrichInflight[key] = true
			go retryLyricsUpgrade(key, artist, title, album, durationSecs, true)
		} else if needsLyricsRescore(e, pinned) && !enrichInflight[key] {
			enrichInflight[key] = true
			go rescoreLyrics(key, artist, title, album, durationSecs)
		} else if needsLyricsRetry(e, wrongDuration, pinned) && !enrichInflight[key] {
			enrichInflight[key] = true
			go retryLyricsUpgrade(key, artist, title, album, durationSecs, false)
		} else if needsTranslationBackfill(e) && !enrichInflight[key] {
			enrichInflight[key] = true
			go backfillTranslation(key)
		}
		enrichMu.Unlock()
		return e.fields()
	}
	// 从没见过这首歌:首次解析,不阻塞 poll 循环。
	// 去重要连**在途**的一起查(不只是 enrichInflight[key] 这一个精确键)——理由见
	// looseInflightKey,少这一道就会在十几秒的窗口里长出繁简/空格重复。
	if _, busy := looseInflightKey(key); !busy {
		enrichInflight[key] = true
		go resolveEnrichAsync(key, artist, title, album, durationSecs)
	}
	enrichMu.Unlock()
	return nil
}

// needsPeripheralBackfill 判断是否要补一次外围字段(主色/Apple/QQ/网易云链接)——这几路
// 各自独立请求,可能因限流/超时单独失败,漏了哪个就该重试哪个,不代表歌词/封面本身有问题。
// 用 TS 节流,避免同一首歌每次 poll(几秒一次)都重新发一遍网络请求。
// peripheralBackfillMaxAttempts 给外围字段补全设的硬上限。
//
// 以前只有 10 分钟节流、**没有次数上限**:某个字段如果是真的补不上(这首歌在网易云压根
// 没有、Apple Music 没收录……),这条记录会每 10 分钟重发一轮网络请求,只要它还在被播放
// 就永远停不下来。5 次 ≈ 给足偶发网络抖动恢复的机会,之后认账。
const peripheralBackfillMaxAttempts = 5

// needsPeripheralBackfill 判断是否要补一次外围字段。artist 用来判断"canonical 为空"到底
// 算不算缺 —— collector 只在**单一歌手**时才给 canonical_artist,合唱曲目为空是正常的,
// 不该为它反复重试。
func needsPeripheralBackfill(e enrichEntry, artist, album string) bool {
	// canonical_artist 2026-08-07 加进这个条件。它本来就在 backfillPeripheralFields 里有
	// `== ""` 的补全分支,但触发条件不看它 —— 于是只要那四个字段都齐了,一条缺 canonical 的
	// 记录就再也没机会补上。实测撞到过:同一张专辑里一半曲目报 "Leah Dou"、一半报"窦靖童",
	// 而前者靠 canonical 归一成功、后者其中两条 canonical 是空的。
	missingCanonical := e.CanonicalArtist == "" && len(artistCreditParts(artist)) <= 1
	missing := e.AccentColor == "" || e.AppleURL == "" || e.QQURL == "" || e.NeteaseURL == "" ||
		missingCanonical || coverNeedsAlbumCheck(e, album)
	if !missing {
		return false
	}
	if e.PeripheralRetryCount >= peripheralBackfillMaxAttempts {
		return false
	}
	base := e.PeripheralTS
	if base == 0 {
		base = e.TS // 老条目:拆分之前两者是同一个值
	}
	return time.Now().Unix()-base >= int64(enrichPeripheralRetryInterval/time.Second)
}

// preferAppleCoverOverNetease 判断该不该用 Apple 的封面顶掉网易云那张:网易云那张明确
// 属于另一次发行(专辑分 0),而 Apple 那张对得上正在播的这张专辑(专辑分 > 0)。
//
// 本地专辑名为空(单曲/播放器没给专辑标签)时一律 false —— 那时候"对不对版"无从判断,
// 不能拿一个判不出来的条件去掀掉已有封面。理由与出处见调用处的长注释。
func preferAppleCoverOverNetease(neteaseAlbum, appleAlbum, appleCover, localAlbum string) bool {
	if appleCover == "" || localAlbum == "" {
		return false
	}
	return albumScore(neteaseAlbum, localAlbum) == 0 && albumScore(appleAlbum, localAlbum) > 0
}

// coverNeedsAlbumCheck 判断这条记录的封面值不值得重新解析一次 —— 只针对网易云那档:
//
//   - cover_album 有值、但对不上正在播的这张专辑 → 明确是另一次发行的封面,该重解析;
//   - cover_album 为空(老条目,这个字段 2026-08-20 才加)→ 判不出来,补一次重解析顺便
//     把这个字段写上。
//
// Apple/QQ 两档不查:Apple 那档的封面本来就是按 albumScore 择优选出来的,QQ 那档
// qqCoverFallback 内部也按 albumScore 避开了精选集。
//
// 一条最多查 5 次(peripheralBackfillMaxAttempts)、每次隔 10 分钟,跟其它几个缺字段
// 共用同一套节流与上限,所以存量条目不会在升级后一股脑全部重跑。
func coverNeedsAlbumCheck(e enrichEntry, album string) bool {
	if album == "" || e.CoverSource != "netease" {
		return false
	}
	if e.CoverAlbum == "" {
		return true
	}
	return albumScore(e.CoverAlbum, album) == 0
}

// coverSwapAllowed 判断外围补全这一轮该不该用 fresh 的封面顶掉已经存着的那张。
//
// 三档:
//  1. 这一轮没拿到封面 → 不换。老守卫,防一次网络抖动把已解析好的封面抹成空。
//  2. 本来没有封面 / 新旧同源 → 换。同一路解析的刷新,顺带把 cover_album 补上。
//  3. 跨源替换 → 要有**正面证据**:这一轮网易云真的应答过(fresh.NeteaseURL 非空),
//     而且新封面对得上本地专辑。
//
// 第 3 档是必须的:网易云被限流时照样回 HTTP 200(body code 405,见 netease.go),这一轮
// 就没有网易云封面,fresh 里剩下的是 Apple 那张 —— 少了这道闸,一次限流就能把一张本来
// 对版、国内加载得出来的网易云封面换成 mzstatic 的(国内无 CDN)。而 coverNeedsAlbumCheck
// 会让存量的网易云封面条目每条都补查一次,撞上限流的概率不低。
func coverSwapAllowed(old, fresh enrichEntry, album string) bool {
	if fresh.CoverURL == "" {
		return false
	}
	if old.CoverURL == "" || old.CoverSource == fresh.CoverSource {
		return true
	}
	return fresh.NeteaseURL != "" && album != "" && albumScore(fresh.CoverAlbum, album) > 0
}

// lyricSourcesWithCandidates 挑出这一轮真的给出了可用候选的源(负分是"纯音乐"这类搭车
// 标记,不算候选,见 scoredLyricCandidateResult.Instrumental)。
func lyricSourcesWithCandidates(scored []scoredLyricCandidateResult) []string {
	return distinctLyricSources(scored, true)
}

// lyricSourcesResponded 跟上面的区别是**不看分数**:只要这个源在这一轮里给出过候选就算,
// 哪怕那个候选被判成无效(Score<0)。用来回答"这一轮五源是不是都回来了",而不是"哪些源
// 给出了能用的东西" —— 一个源明确给出了一份烂候选,跟它超时没露面,是两回事。
func lyricSourcesResponded(scored []scoredLyricCandidateResult) []string {
	return distinctLyricSources(scored, false)
}

func distinctLyricSources(scored []scoredLyricCandidateResult, onlyValid bool) []string {
	seen := make([]string, 0, len(scored))
	for _, c := range scored {
		if onlyValid && c.Score < 0 {
			continue
		}
		dup := false
		for _, s := range seen {
			if s == c.Source {
				dup = true
				break
			}
		}
		if !dup {
			seen = append(seen, c.Source)
		}
	}
	return seen
}

// allEnabledLyricSourcesResponded 判断这一轮搜索是不是"信息完整"的:每个启用的源都给出了
// 候选(能不能用另说)。
func allEnabledLyricSourcesResponded(scored []scoredLyricCandidateResult) bool {
	responded := lyricSourcesResponded(scored)
	for source, enabled := range features.LyricsSources {
		if !enabled {
			continue
		}
		if !containsString(responded, source) {
			return false
		}
	}
	return true
}

// rescoreDecidable 判断这一轮的结果够不够格推翻当初那次决定。
//
// 一开始写的是"所有启用的源都回来了才算数",2026-08-07 上线当天就被真机日志打脸:五源搜索
// 有 20 秒总上限,**有源超时是常态**,连着两次都是 `rescore deferred (source missing)`,
// 等于这条路对绝大多数条目静默失效。
//
// 真正要防的不是"信息不完整",而是"把手上这份好的换成更差的"。只要**当前这份歌词的来源**
// 这一轮也回来了,它自己就参与了新规则下的重新比较 —— 输了就是真输了,这是有依据的替换,
// 缺不缺别的源不影响这个结论(当初那次解析同样可能是在缺源的情况下做的)。反过来,如果
// 恰恰是它没回来,那就什么都别动。
//
// 兜底:老条目可能压根没记 lyrics_source,或者那个源后来被用户关掉了 —— 这种情况下无从
// 判断"手上这份"参没参与,退回原来那条更严的"所有启用的源都回来了"。
//
// noCurrentLyrics:调用方明确知道"手上压根没有歌词"时传 true,这道闸直接放行。
//
// 为什么需要它(2026-08-22,用户报「手动搜索能搜到,点『重新自动匹配』却搜不到」):这道闸
// 存在的意义是"别把手上这份好的换成更差的"。**手上什么都没有时,它保护的是虚空**,而退回
// "所有启用的源都回来了"的后果是:一首歌只要有任何一个源永远不收录它(五源里有几个源
// 确实没有某些冷门/串烧曲目,那个源就永远不会出现在 responded 里),这颗按钮就**永远**
// 不可能成功——用户看到的是「这一轮「」没应答」这种主语为空的话。实测案例
// 「枫+退后+搁浅 (Live)」:酷狗给出 799 分带逐字的正确候选,只有它一个源应答,
// Decidable 恒为 false,App 按约定什么都不改。
//
// 同一个洞见这个文件里早就写过一遍,只是 rescoreDecidable 没享受到 ——
// 见 lyricsUpgradeBaseline 对空歌词条目那一支:「没有旧分要保护,任何真候选都是改进」。
//
// **刻意做成参数而不是就地推断** `currentSource == ""`:同一个空串在两条调用路径上语义
// 不同。自动 rescore 那条路(rescoreLyrics)的前置 needsLyricsRescore 第一行就要求
// `e.Lyrics != ""`,所以那里的空串只可能是"老条目有歌词但没记来源",必须保持严格;而手动
// `-pick` 那条路(searchcli.go)的空串就是"这条没有歌词"。做成参数,两条路各自说清自己
// 的处境,不靠巧合。(顺带实测过:294 条去重缓存条目里,"有歌词但没记 lyrics_source" 是
// **0 条** —— 那条兜底分支在现实数据里已经是死路,但保留它不花钱。)
//
// 放行之后仍有两道下游闸挡着,不是无保护:冠军为空时 App 走 keptNoCandidate 什么都不写;
// 现有这份有逐字而冠军没有时走 keptWouldLoseWordTiming(见 LyricsRematchDecision)。
func rescoreDecidable(scored []scoredLyricCandidateResult, currentSource string, noCurrentLyrics bool) bool {
	if noCurrentLyrics {
		return true
	}
	if currentSource != "" && lyricSourceEnabled(currentSource) {
		return containsString(lyricSourcesResponded(scored), currentSource)
	}
	return allEnabledLyricSourcesResponded(scored)
}

func containsString(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

// lyricsRetryInterval / lyricsRetryMaxAttempts 给"歌词升级重试"设的节流和上限。
//
// 6 小时 + 最多 3 次:重试只在这首歌又被播放时才可能发生,所以这两个数控制的是"最坏情况下
// 一首歌总共会多跑几轮五源搜索"。缺席的源可能是真的没有这首歌(那样永远补不上),所以必须
// 有硬上限,不能无限重试。
const (
	lyricsRetryInterval    = 6 * time.Hour
	lyricsRetryMaxAttempts = 3
)

// lyricsFillBaseInterval 是"补空歌词"重试的起始间隔,见 needsLyricsFirstFill。
const lyricsFillBaseInterval = 24 * time.Hour

// lyricsFillBackoff 给"补空歌词"算这一条现在该等多久:按已尝试次数指数退避,
// 1 天 → 2 → 4 → 8 → 16 天,之后恒为 16 天。
//
// 刻意**不设次数上限**(跟 needsLyricsRetry 那条不一样)。理由就是这条路径存在的意义:
// 搜索/匹配逻辑以后每一次改进,都得能自愈地覆盖到"当初没搜到"的存量歌 —— 一旦有硬上限,
// 存量失败就又变成永久失败了,而那正是 2026-08-17 用户报「这首歌找不到歌词」时发现的问题
// (`Medley: ` 前缀那个 bug 修好之后,已经在缓存里的那首歌永远不会自己好起来)。
//
// 指数退避替代次数上限:真的哪里都没有歌词的歌,浪费的网络随时间衰减到"每 16 天一次、
// 且只在你真的又播到它的时候",而任何时候上线的改进最多等 16 天就能生效。
func lyricsFillBackoff(count int) time.Duration {
	shift := count
	if shift > 4 {
		shift = 4
	}
	return lyricsFillBaseInterval << shift
}

// needsLyricsFirstFill 判断这条缓存该不该为"一条歌词都没有"再搜一次。
//
// 为什么必须单独有这一条:resolveTrackEnrichment 里缓存命中之后只可能触发四种后台任务,
// 而 needsLyricsRescore 和 needsLyricsRetry **两个的第一行都是 `if e.Lyrics == "" 就
// return false`**,另两个只管外围字段和译文 —— 于是"条目已存在但歌词为空"落在所有路径
// 之外,**一首歌解析失败过一次就永久卡住**。2026-08-17 实测坐实:修好 `Medley: ` 前缀那个
// bug、五个源都能搜到之后,盯了 48 秒那条缓存仍然是 0 字,因为压根没有任何代码会去重试它。
//
// 三道闸:
//   - 有歌词了就不是这条路径的事(交给 needsLyricsRetry 去谈升级);
//   - 用户手改过的绝不自动重搜(跟其余几条路径同一个理由,见 ManualLyrics 注释);
//   - **明确判定为纯音乐的不重搜** —— 那是有依据的结论(lrclib 的 instrumental 标记),
//     不是"没搜到"这种含糊状态,重搜一万次也不会有歌词。
func needsLyricsFirstFill(e enrichEntry) bool {
	if e.Lyrics != "" || e.ManualLyrics || e.Instrumental {
		return false
	}
	// 从"上次补空尝试"和"当初解析"里取更晚的那个当起算点,理由跟 needsLyricsRetry 同款:
	// 免得刚写进缓存的新条目立刻又被重搜一遍。
	base := e.LyricsFillTS
	if e.TS > base {
		base = e.TS
	}
	return time.Now().Unix()-base >= int64(lyricsFillBackoff(e.LyricsFillCount)/time.Second)
}

// needsLyricsRetry 判断这条缓存的歌词值不值得再搜一次、试着升级到更好的源。
//
// 只在"这次决定是在信息不全的情况下做出来的"时才重试 —— 即有**已启用**的源在当初那一轮
// 里压根没露面(超时/失败,见 lyricSearchDeadline 的注释)。所有源都回来了、lrclib 是货真价实
// 赢的,就不折腾。
//
// 三道闸门缺一不可:
//   - 已经有逐字歌词(LyricsYRC)就不再重试:逐字是这套打分里最值钱的东西(scoreLyricCandidate
//     给它加 400 分),已经拿到就没什么可升级的了,没必要为了几分之差再跑一轮网络搜索。
//   - 重试次数上限:缺席的源可能真的没有这首歌,那样永远补不上,必须有硬上限。
//   - 时间节流:同一首歌被反复播放时不能每次都重搜。
//
// 老条目(这个功能上线前写入的)没有 LyricsSourcesSeen,会被判成"所有启用的源都缺席"从而
// 获得一次升级机会 —— 这是有意的:它们当初正是在没有这层保护的情况下定下来的。
// lyricsUpgradeBaseline 给"歌词升级重试"算出该跟谁比大小,以及这一轮到底能不能比。
//
// 跨打分版本**不能**直接比大小:v3 给同一份候选普遍多算几百分(专辑/标题/共识/增值),
// 拿 v3 新分去比存量的 v2 旧分,"严格更高才替换"这道闸就形同虚设 —— 一份更差的候选
// 只因为按新规则算就轻松超过旧分,把好歌词换掉。版本落后的条目本该由 rescoreLyrics
// 收编(它是版本感知的、压根不比大小),但 rescore 有 1 小时节流 + 3 次上限,节流窗口里
// retry 照样会跑到这儿(2026-08-12 审阅确认)。
//
// 解法是把基准换成**同尺度**的量:现存这份歌词若还在这一轮候选里,就用它这一轮的分数
// 当基准(like-for-like);它没出现(源这轮没答、或内容变了)就这轮不换,等 rescore 收编。
func lyricsUpgradeBaseline(e enrichEntry, scored []scoredLyricCandidateResult) (baseline int, comparable bool) {
	// 空歌词条目("第一次填上"那条路径,见 needsLyricsFirstFill):没有旧分要保护,任何
	// 真候选都是改进。上面那段"跨打分版本不能比大小"的顾虑在这里不成立 —— 压根没有旧分。
	//
	// ⚠️ 必须有这一支,不能指望下面两条。LyricsScoringVersion 对这类条目通常是 0
	// (从来没写过),于是第一条不成立;而第二条要在候选里找 Source/Lyrics 都等于现存值的
	// 那一份,空歌词条目这两个字段都是空串、永远找不到 —— 结果 comparable=false、
	// upgraded 恒为 false,搜出来的歌词一个字都不会被写回去(白跑一轮网络)。
	if e.Lyrics == "" {
		return 0, true
	}
	if e.LyricsScoringVersion == lyricsScoringVersion {
		return e.LyricsScore, true
	}
	for i := range scored {
		if scored[i].Source == e.LyricsSource && scored[i].Lyrics == e.Lyrics {
			return scored[i].Score, true
		}
	}
	return 0, false
}

// durationMismatch:这条歌词当初按 resolved 秒校验,现在真播的版本是 actual 秒 ——
// 差超过 12% 就当作"给另一个版本选的",值得按真实时长重选。这里只是"要不要重跑一轮"
// 的闸门,重跑之后选谁仍由打分定;卡太紧会为几秒的标注差异白跑网络。两边都得知道时长
// 才可比,任一方为 0 不触发(旧条目没这个字段,一律不回溯 —— 别让一次升级把全库歌都
// 重新解析一遍)。
func durationMismatch(resolved, actual float64) bool {
	if resolved <= 0 || actual <= 0 {
		return false
	}
	larger := math.Max(resolved, actual)
	return math.Abs(resolved-actual)/larger > 0.12
}

// observeWrongDuration:「时长对不上」这个观察值必须**同值稳定满一个窗口**才可信。
//
// 2026-08-22 实测坐实的串扰:换曲/预载窗口里 media-control 会把**下一首**的时长和当前
// 曲目的标题拼进同一份快照 ——「开不了口 (Live)」(272.973s)开播 6 秒后,relay 推送的
// 快照携带同专辑下一首「床边故事 (Live)」的 220.23899841308594s,跟那条缓存里的时长
// **逐位一致**。这样一次性的脏观察值直接喂给 durationMismatch 就会白烧一轮升级重试
// (3 次预算之一),重跑时所有候选按错误时长全吃 durationOvershoot -700,还把决策记录
// 盖掉(那次事故正是用户问"决策记录怎么跟手动搜索对不上"的根源)。
//
// 判定规则:mismatch 消失(时长又对上了)就清掉观察记录;换了个不同的脏值、或观察断流
// 超过 wrongDurationObsMaxGapSecs(记录已陈旧,见下)就重新计时;同一个脏值(±1s)持续
// 观察满 wrongDurationConfirmSecs 才确认为真。确认放行的同时也清掉记录 —— 这一轮重试
// 如果没换成(ResolvedDurationSecs 不变),下一次要重新攒满窗口才会再触发,不会每次调用
// 连发重试把预算一口气烧光。
//
// nowUnix 由调用方传入而不是自己取 time.Now():去抖语义全靠时间差,单测要能钉死。
func observeWrongDuration(key string, mismatch bool, actualDurationSecs float64, nowUnix int64) bool {
	if !mismatch {
		delete(wrongDurationSeen, key)
		return false
	}
	obs, ok := wrongDurationSeen[key]
	if !ok || math.Abs(obs.durationSecs-actualDurationSecs) > 1.0 ||
		nowUnix-obs.lastSeen > wrongDurationObsMaxGapSecs {
		wrongDurationSeen[key] = wrongDurationObs{durationSecs: actualDurationSecs, firstSeen: nowUnix, lastSeen: nowUnix}
		return false
	}
	obs.lastSeen = nowUnix
	wrongDurationSeen[key] = obs
	if nowUnix-obs.firstSeen < wrongDurationConfirmSecs {
		return false
	}
	delete(wrongDurationSeen, key)
	return true
}

// 串扰通常几秒内自愈(下一次 poll/relay 快照就恢复了),30 秒足以把它筛掉;真正的版本
// 时长差在整首播放期间恒定,代价只是把重试推迟半分钟。
const wrongDurationConfirmSecs = 30

// 观察断流的陈旧上限。堵的是"跨播放残留"(2026-08-22 审阅指出):脏快照落在曲目**切出**
// 侧(标题还是当前曲、时长已被预载成下一首)时,切歌后该 key 再收不到清零观察,记录
// 会一直挂着;几天后重放同曲若第一口又是同值脏观察,拿着陈旧 firstSeen 一步就凑满
// 30 秒窗口。上限必须盖过稳定播放期的正常喂食间隔 —— trackEnrichment 在同曲存活期
// 的调用来自 relay 心跳(≤4 分钟)和 LB 的 playing_now/listen 提交(≤4 分钟),不是每拍
// poll 都调,取 60 秒会把合法确认饿死,5 分钟刚好双覆盖。残余风险(有意接受):切出侧
// 恰好被心跳采到脏值(尾窗几秒,概率很低)且几分钟内快速重放同曲、第一口又是同值脏
// 观察 —— 代价有界(白烧一轮重试,Applied 槽已保住决策记录)。
const wrongDurationObsMaxGapSecs = 300

type wrongDurationObs struct {
	durationSecs float64
	firstSeen    int64
	lastSeen     int64
}

// wrongDurationSeen 只在 enrichMu 临界区内读写(trackEnrichment 是唯一调用方)。
var wrongDurationSeen = map[string]wrongDurationObs{}

func needsLyricsRetry(e enrichEntry, wrongDuration, pinned bool) bool {
	if e.Lyrics == "" {
		return false
	}
	// 用户手动校准过时间轴的绝不自动重选歌词源(见 lyricspins.go)。必须排在**所有**其它
	// 判定前面:下面 nativeMissedOut / wrongDuration 那两条是刻意越过"已经有逐字就不重试"
	// 那道闸的,pin 要是排在它们后面就会被同样越过。
	if pinned {
		return false
	}
	// 换了播放器(或同源加权刚上线):这首歌当初**见过**当前播放器自家那个源的候选,却选了
	// 别家 —— 按新规则它多半该翻盘,给一次重来的机会。
	//
	// ⚠️ 这一条必须排在下面"已经有逐字就不重试"**之前**。2026-08-15 实测:用户放 QQ 音乐
	// 听《太阳之子》,缓存里是酷狗那份、而酷狗那份正好带逐字,于是被那道闸原地挡死 ——
	// 同源加权对**所有存量歌词**等于没上线,只有以后新解析的歌才享受得到。
	//
	// 判据只用缓存里已有的两个字段(LyricsSource + LyricsSourcesSeen),所以**不需要**把
	// 播放器加进缓存 key。加进 key 的话,换一次播放器全部歌词集体失效、每首都要重打四个源;
	// 而真正该重来的只是"当初见过同源候选却没选它"的那一小撮。
	//
	// 下面的手改保护/重试上限/时间节流照常生效 —— 同源候选要是每次都赢不了(比如它质量
	// 实在差,250 分也翻不过来),重试次数上限会兜住,不会没完没了地重搜。
	nativeMissedOut := nativeLyricSource != "" && e.LyricsSource != nativeLyricSource &&
		slices.Contains(e.LyricsSourcesSeen, nativeLyricSource)
	// 版本时长对不上(预取用了另一个版本的时长做校验)跟"同源落选"一样,本身就是重来
	// 一次的理由,同样要越过下面"已经有逐字就不重试"那道闸。wrongDuration 由调用方
	// (trackEnrichment)算好传进来:durationMismatch 的原始观察值必须先过
	// observeWrongDuration 的稳定性确认 —— 换曲/预载窗口里 media-control 会把下一首的
	// 时长和当前曲目的标题拼进同一份快照,一次性的脏观察值不能直接当真(这个函数保持
	// 纯函数,时间态的去抖状态留在调用方那层,单测才不用碰包级状态)。
	if e.LyricsYRC != "" && !nativeMissedOut && !wrongDuration {
		return false
	}
	// 用户手改过的绝不自动重搜,理由见 ManualLyrics 字段的注释。这道闸 2026-08-07 补上:
	// 这个升级重试刚上线时漏了它,而 saveEdit 只写 manual_lyrics、不动 lyrics_score,于是
	// 一条人工修正过的记录仍挂着当初自动选出来那份的分数,后台重搜一旦拿到更高分就会把
	// 用户手改的内容直接覆盖掉 —— 而这是整个缓存里唯一不可恢复的东西。
	if e.ManualLyrics {
		return false
	}
	if e.LyricsRetryCount >= lyricsRetryMaxAttempts {
		return false
	}
	// 同源候选当初落选:这本身就是重来一次的理由,不必再要求"有源缺席"。下面那段找的是
	// "有源当初没答上话",跟这里说的"答了但没选它"是两回事 —— 混在一起会让这条路径
	// 永远返回 false(这个 bug 2026-08-15 当天就被断言逮住了)。
	if nativeMissedOut || wrongDuration {
		return true
	}
	missing := false
	for source, enabled := range features.LyricsSources {
		if !enabled {
			continue
		}
		found := false
		for _, s := range e.LyricsSourcesSeen {
			if s == source {
				found = true
				break
			}
		}
		if !found {
			missing = true
			break
		}
	}
	if !missing {
		return false
	}
	// 从"上次重试"和"当初解析"里取更晚的那个当基准,免得老条目刚升级完又立刻符合条件。
	base := e.LyricsRetryTS
	if e.TS > base {
		base = e.TS
	}
	return time.Now().Unix()-base >= int64(lyricsRetryInterval/time.Second)
}

// retryLyricsUpgrade 后台重跑一轮五源搜索,只有分数**严格更高**才替换歌词。
//
// 跟 backfillPeripheralFields 同一个范式(inflight 去重 + 重新取锁 + 条目可能已被删)。
// 不管有没有升级成功都要记一次重试(次数+时间戳),否则缺席的源如果是真的没有这首歌,
// 这条会每 6 小时被重搜一次、永远停不下来。
//
// firstFill=true 时走的是"这条压根没有歌词、还在等第一次填上"那条路径
// (needsLyricsFirstFill)。刻意复用这同一个函数而不是另写一个:两者要做的事完全一样
// (重跑一轮五源搜索 → 取赢家 → 写回 + 落盘 + 导出 + 通知),只有三处不同 ——
// 记到哪一对节流字段、决策记录里标成什么路径、以及"够不够好才替换"那个基准
// (见 lyricsUpgradeBaseline 里空歌词那一支)。另写一份必然跟这边漂,而这个函数尾部那一
// 长串"解锁→落盘→导出→通知"的顺序正是这个仓库反复踩过坑的地方。
func retryLyricsUpgrade(key, artist, title, album string, durationSecs float64, firstFill bool) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	sourceChoice := enrichCache[key].LyricsSourceChoice
	enrichMu.Unlock()

	_, scored := scoredLyricCandidates(artist, title, album, durationSecs)
	// 用户选定过源就只在那个源内重选,见 LyricsSourceChoice 字段注释。
	picked := pickLyricCandidatePreferring(scored, sourceChoice)
	seen := lyricSourcesWithCandidates(scored)

	enrichMu.Lock()
	// 解锁之后再落盘 —— App 侧读的是**磁盘上**这份缓存文件(EnrichCacheReader 每次直读
	// 文件),只把 enrichDirty 标成 true 是不够的:补出来的东西只活在 collector 内存里,
	// 界面永远看不到。2026-08-08 用户报"译文语言切成英文了还是没有翻译",日志里译文明明
	// 一首首翻出来了,而缓存文件停在两小时前——就是这里漏了这一步。resolveEnrichAsync /
	// backfillPeripheralFields 一直是"解锁→saveEnrichCache",另外三条补全路径全漏了。
	//
	// 顺序不能反:saveEnrichCache 和 exportLyricsFiles 自己都要拿同一把 enrichMu,
	// 在持锁期间调用会死锁。
	//
	// 导出只在歌词族字段真的变了的时候做:它每次都要全量扫一遍 enrichCache,而这几条
	// 路径就算什么都没补上也会推进重试计数/时间戳(那些只要落盘、不涉及 lyrics/ 文件)。
	lyricsChanged := false
	defer func() {
		enrichMu.Unlock()
		saveEnrichCache()
		if !lyricsChanged {
			return
		}
		exportLyricsFiles()
		// 非阻塞通知 poll 立刻重推。跟 saveEnrichCache 一样,原来只有 resolveEnrichAsync /
		// backfillPeripheralFields 做了这一步,这三条补全路径全漏了 —— 于是同一首歌播到
		// 中途才补出来的译文,要等下一次换歌才会被推出去(2026-08-09 用户问"为什么当前这
		// 歌没有英文译文",译文其实早就翻好、也落盘了,只是没人通知)。
		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
	}()
	e, ok := enrichCache[key]
	if !ok {
		// 重搜这段时间里这条被用户在"歌词管理"里删掉了 —— 不要把它复活回去。
		return
	}
	if e.ManualLyrics {
		// 重搜这几秒里用户刚好在"歌词管理"里手改了这条 —— 进来时的快照已经过期,以拿锁
		// 这一刻的实际状态为准(跟 rescoreLyrics 里同一道判断)。
		return
	}
	if firstFill {
		e.LyricsFillCount++
		e.LyricsFillTS = time.Now().Unix()
	} else {
		e.LyricsRetryCount++
		e.LyricsRetryTS = time.Now().Unix()
	}
	if len(seen) > 0 {
		e.LyricsSourcesSeen = seen
	}
	if responded := lyricSourcesResponded(scored); len(responded) > 0 {
		e.LyricsSourcesResponded = responded
	}
	baseline, comparable := lyricsUpgradeBaseline(e, scored)
	upgraded := picked != nil && comparable && picked.Score > baseline
	path := lyricsDecisionPathUpgrade
	if firstFill {
		path = lyricsDecisionPathRefill
	}
	// 无论换没换,这一轮完整评估都值得留证(Applied 区分两种含义,见 decision.go)。
	e.LyricsDecision = buildLyricsDecision(
		path, artist, title, album, durationSecs, scored, picked, upgraded)
	traceLyricsDecision(key, e.LyricsDecision)
	// 换上了新的、或胜者就是现存这份(分数没严格更高所以没"升级",但等于再次确认了当前
	// 选择):两种都算"当前歌词的出处"(分槽语义见 LyricsDecisionApplied)。注意此刻
	// e.Lyrics/e.LyricsSource 还是旧值,判的是"胜者=现存"。刻意源+正文双比(跟
	// lyricsUpgradeBaseline 同一口径):LRCLIB 镜像别家正文逐字节相同很常见,只比正文
	// 会让出处槽的 Winner 记成另一个源、跟缓存 lyrics_source 对不上号 —— 那正是分槽
	// 要消除的那类困惑(2026-08-22 审阅指出)。
	if upgraded || (picked != nil && picked.Source == e.LyricsSource && picked.Lyrics == e.Lyrics) {
		e.LyricsDecisionApplied = e.LyricsDecision
	}
	if upgraded {
		log.Printf("lyrics upgrade: %s  %s(%d) -> %s(%d)", key, e.LyricsSource, e.LyricsScore, picked.Source, picked.Score)
		e.Lyrics = picked.Lyrics
		e.LyricsSource = picked.Source
		e.LyricsScore = picked.Score
		e.LyricsScoringVersion = lyricsScoringVersion
		e.ResolvedDurationSecs = durationSecs
		e.LyricsTr, e.LyricsRoma, e.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
		lyricsChanged = true
		// 译文换人了,描述译文的两个字段必须跟着换:语言(否则拿旧语言判新译文),
		// 来源(否则上一轮机翻留下的 "machine" 会让新来的社区译文被标成机翻)。
		e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, ""
	}
	// 纯音乐结论也要在这条路径上落地(2026-08-20 补)。first-resolve 那边一直有这段
	// (见 resolveEnrichAsync 里读 c.Instrumental 的分支),而重搜/补空这条**从来没有**:
	// 于是"当初那一轮没有任何源给出这个信号、后来给出了"的条目永远拿不到「纯音乐」标记,
	// 只能一直显示「无歌词」,而 needsLyricsFirstFill 还要每隔 24 小时(退避后翻倍)白搜
	// 一轮 —— 标记一旦落地它就直接 return,连重搜都省了。
	//
	// 只在**没选出歌词**时看:选出了歌词还标纯音乐是自相矛盾(合并轮的
	// hasRealFromMarkerSource 已经挡住同源那种,这里再挡跨源那种)。
	if picked == nil && !e.Instrumental {
		for _, c := range scored {
			if c.Instrumental {
				e.Instrumental = true
				log.Printf("lyrics: %s marked instrumental by %s (no lyrics from any source)", key, c.Source)
				break
			}
		}
	}
	enrichCache[key] = e
	enrichDirty = true
}

// lyricsRescoreMaxAttempts / lyricsRescoreDeferInterval 给"按新打分规则重选"设的上限和节流。
//
// 正常情况下一次就够:重选成功就盖上当前版本号,这条以后再也不会进这条路径。会用到后面
// 几次的只有"当前这份歌词的来源这一轮没回来、不敢动"(见 rescoreDecidable)那种情况。
//
// 节流是 2026-08-07 上线当天补的:原来只有次数上限、没有时间间隔,以为"次数兜得住"。
// 真机日志显示同一首歌在**一秒之内**连着重选了两次(第一次跑完清掉 inflight 标记,下一次
// poll 立刻又符合条件),两次尝试烧在同一个网络时机上,而重试的全部意义正是"换个时机再
// 试一次"。
const (
	lyricsRescoreMaxAttempts   = 3
	lyricsRescoreDeferInterval = time.Hour
)

// needsLyricsRescore 判断这条缓存的歌词是不是按**过时的**打分规则选出来的、该重选一次。
//
// 跟 needsLyricsRetry 是两件不同的事,别合并:
//   - needsLyricsRetry 处理的是"当初信息不全"(有源超时没露面),规则没变、只是运气不好,
//     所以它只在**新分严格更高**时才替换;
//   - 这个处理的是"规则本身改了",当初那次决定用的标尺已经作废。两边的分数不可比
//     (旧分是旧规则算出来的),所以重选走的是"新规则下重新选一次最优",而不是比大小。
//
// 五道闸:手改过的不碰(见 ManualLyrics)、用户校准过时间轴的不碰(见 lyricspins.go ——
// 换一份歌词就等于把人家手工听出来的校正值作废)、版本已经是最新的不碰、次数用尽不碰、离上次尝试
// 太近不碰。第一次尝试没有时间门槛(LyricsRescoreTS 为 0)—— 这条路径的目的就是让存量条目
// 尽快跟上新规则;只有需要再试时才拉开间隔,见 lyricsRescoreDeferInterval。
func needsLyricsRescore(e enrichEntry, pinned bool) bool {
	if e.Lyrics == "" || e.ManualLyrics || pinned {
		return false
	}
	if e.LyricsScoringVersion >= lyricsScoringVersion {
		return false
	}
	if e.LyricsRescoreCount >= lyricsRescoreMaxAttempts {
		return false
	}
	if e.LyricsRescoreTS > 0 &&
		time.Now().Unix()-e.LyricsRescoreTS < int64(lyricsRescoreDeferInterval/time.Second) {
		return false
	}
	return true
}

// rescoreLyrics 按当前打分规则重跑一轮搜索并重新选一次歌词。
//
// 跟 retryLyricsUpgrade 同一个范式(inflight 去重 + 重新取锁 + 条目可能已被删),两点不同:
//  1. 不跟旧分比大小 —— 旧分是按旧规则算的,不可比(见 needsLyricsRescore)。
//  2. 只有这一轮的结果够格推翻旧决定才认并盖版本号(见 rescoreDecidable);不够格就只记
//     一次尝试、隔一段时间再来。
func rescoreLyrics(key, artist, title, album string, durationSecs float64) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	currentSource := enrichCache[key].LyricsSource
	sourceChoice := enrichCache[key].LyricsSourceChoice
	enrichMu.Unlock()

	_, scored := scoredLyricCandidates(artist, title, album, durationSecs)
	// 用户选定过源就只在那个源内重选,见 LyricsSourceChoice 字段注释。
	picked := pickLyricCandidatePreferring(scored, sourceChoice)
	// 传 false:走到这里的前置是 needsLyricsRescore,它第一行就要求 e.Lyrics != "",
	// 所以自动 rescore 永远不是"手上没歌词"的处境,这一支的口径一字不变。
	decidable := rescoreDecidable(scored, currentSource, false)
	seen := lyricSourcesWithCandidates(scored)

	enrichMu.Lock()
	// 解锁之后再落盘 —— App 侧读的是**磁盘上**这份缓存文件(EnrichCacheReader 每次直读
	// 文件),只把 enrichDirty 标成 true 是不够的:补出来的东西只活在 collector 内存里,
	// 界面永远看不到。2026-08-08 用户报"译文语言切成英文了还是没有翻译",日志里译文明明
	// 一首首翻出来了,而缓存文件停在两小时前——就是这里漏了这一步。resolveEnrichAsync /
	// backfillPeripheralFields 一直是"解锁→saveEnrichCache",另外三条补全路径全漏了。
	//
	// 顺序不能反:saveEnrichCache 和 exportLyricsFiles 自己都要拿同一把 enrichMu,
	// 在持锁期间调用会死锁。
	//
	// 导出只在歌词族字段真的变了的时候做:它每次都要全量扫一遍 enrichCache,而这几条
	// 路径就算什么都没补上也会推进重试计数/时间戳(那些只要落盘、不涉及 lyrics/ 文件)。
	lyricsChanged := false
	defer func() {
		enrichMu.Unlock()
		saveEnrichCache()
		if !lyricsChanged {
			return
		}
		exportLyricsFiles()
		// 非阻塞通知 poll 立刻重推。跟 saveEnrichCache 一样,原来只有 resolveEnrichAsync /
		// backfillPeripheralFields 做了这一步,这三条补全路径全漏了 —— 于是同一首歌播到
		// 中途才补出来的译文,要等下一次换歌才会被推出去(2026-08-09 用户问"为什么当前这
		// 歌没有英文译文",译文其实早就翻好、也落盘了,只是没人通知)。
		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
	}()
	e, ok := enrichCache[key]
	if !ok {
		// 重搜这段时间里这条被用户在"歌词管理"里删掉了 —— 不要把它复活回去。
		return
	}
	// 期间用户可能刚好手改了这条(重搜是异步的,进来时的快照已经过期)。跟删除同理:
	// 以拿锁这一刻的实际状态为准,不能用几秒前的判断结果去覆盖人工修正。
	if e.ManualLyrics {
		return
	}
	e.LyricsRescoreCount++
	e.LyricsRescoreTS = time.Now().Unix()
	if len(seen) > 0 {
		e.LyricsSourcesSeen = seen
	}
	if responded := lyricSourcesResponded(scored); len(responded) > 0 {
		e.LyricsSourcesResponded = responded
	}
	// 不可判(当前源这轮没应答)时不写决策记录 —— 那一轮没有做出任何决定,盖掉上一份
	// 完整评估的证据反而是损失。可判的两个分支都写(见 decision.go 的 Applied 语义)。
	if decidable {
		e.LyricsDecision = buildLyricsDecision(
			lyricsDecisionPathRescore, artist, title, album, durationSecs, scored, picked,
			picked != nil && picked.Lyrics != e.Lyrics)
		traceLyricsDecision(key, e.LyricsDecision)
		// rescore 可判且有胜者:无论内容换没换,这一轮之后当前歌词就是 picked 那份
		// (见下面 default 分支),它就是新的出处(分槽语义见 LyricsDecisionApplied)。
		if picked != nil {
			e.LyricsDecisionApplied = e.LyricsDecision
		}
	}
	switch {
	case !decidable:
		log.Printf("lyrics rescore deferred: %s  current source %q did not answer this round (responded: %v)",
			key, currentSource, lyricSourcesResponded(scored))
	case picked == nil:
		// 够格判断、但新规则下一个能用的候选都没有(比如全被"超出曲目时长"判掉)。
		// 保留现有歌词不动 —— 有一份存疑的歌词也好过没有 —— 但版本号照盖:结论已经
		// 在完整信息下得出过了,再重搜一次也是同样的结果。
		e.LyricsScoringVersion = lyricsScoringVersion
		e.ResolvedDurationSecs = durationSecs
		log.Printf("lyrics rescore: %s  no valid candidate under v%d, keeping %s", key, lyricsScoringVersion, e.LyricsSource)
	default:
		if picked.Lyrics != e.Lyrics {
			log.Printf("lyrics rescore: %s  %s(v%d) -> %s(%d)", key, e.LyricsSource, e.LyricsScoringVersion, picked.Source, picked.Score)
			e.Lyrics = picked.Lyrics
			e.LyricsTr, e.LyricsRoma, e.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
			lyricsChanged = true
			// 译文换人了,描述译文的两个字段必须跟着换:语言(否则拿旧语言判新译文),
			// 来源(否则上一轮机翻留下的 "machine" 会让新来的社区译文被标成机翻)。
			e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, ""
		}
		if picked.Source != e.LyricsSource {
			// 正文一样但冠军换了源:导出的 .lrc 里 [source:] 头也得跟着重写。lyrics/
			// 文件夹是 6 字段权威源,importLyricsFromFiles 下次启动会拿文件头把缓存里的
			// LyricsSource 静默改回旧值,rescore 的结论被回滚(2026-08-12 审阅)。
			lyricsChanged = true
		}
		e.LyricsSource = picked.Source
		e.LyricsScore = picked.Score
		e.LyricsScoringVersion = lyricsScoringVersion
		e.ResolvedDurationSecs = durationSecs
	}
	enrichCache[key] = e
	enrichDirty = true
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
	// 观察这一轮的网络成败 —— 全空时要能区分"查过了,这首歌没有"和"根本没查成"。
	// 必须用 per-round 的差值,不能用 networkLooksDown():那个读的是进程启动以来的累计
	// 值,在常驻采集器里一旦早期有过成功就永远报"正常"(见 networkobs.go)。
	roundStat := beginNetworkRound()
	e := resolveTrackEnrichment(artist, title, album, durationSecs)
	e.TS = time.Now().Unix()

	// 网络结论**独立于**下面写不写缓存来下 —— 别把它挂在守卫分支里。
	// 挂进去的话,只要有任何一个字段碰巧非空(下面那个搜索链接兜底就是),这条判断就再也
	// 不会执行,而那恰恰是断网时必然发生的情况。
	attempts, failures := roundStat()
	switch {
	case roundLooksNetworkDown(attempts, failures):
		// 界面据此把"搜索歌词中…"换成"网络连接失败" —— 不然它会一直转下去,而断网时
		// 那句话永远不会有下文(见 collectorstatus.go)。
		markCollectorNetworkDown()
	case attempts > 0:
		// 这一轮真发出去过请求、且不是全挂 → 网络是通的。
		// attempts==0(整轮都命中缓存,一个请求都没发)时什么都不做:它不构成任何证据。
		clearCollectorNetworkDown()
	}

	// 只保留"解析到东西"的结果;全空(可能网络抽风)不写入,下次再试,别把偶发失败钉死。
	//
	// ⚠️ QQURL 必须排除掉"搜索链接兜底"这一档。qqMusicURL 在 smartbox 查不到时会拼一个
	// 纯本地的搜索页 URL(见 qq.go,它自己也不缓存这个兜底值)——**它不需要网络就能得到**,
	// 拿它当"解析到东西"的证据是假的。2026-08-15 实测:断网时这条守卫因此永不成立,于是
	// 每首歌都会往永久缓存里写一条只有搜索链接、没有任何内容的条目。
	// SpotifyURL 同样是本地拼的,所以它本来就不在这个判据里 —— 说明当初是想到了这一点的,
	// 只是漏了 QQURL 也有本地兜底这条路。
	hasRealQQURL := e.QQURL != "" && !isQQSearchFallbackURL(e.QQURL)
	if e.CoverURL == "" && e.Lyrics == "" && e.AppleURL == "" && !hasRealQQURL && e.NeteaseURL == "" {
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
	// 而下面几行的 e.TS = time.Now().Unix() 又把节流时间戳推进去,10 分钟内不会再补,
	// 封面就这么消失了。
	// 紧挨着的 CanonicalArtist 本来就有 `== ""` 守卫,这几行属于漏了同一层保护。
	//
	// 封面四件套一起判(主色是从这张封面算出来的,不能出现"新封面配旧主色"的错配;
	// cover_album 记的是这张封面属于哪张专辑,换封面就得跟着换)。
	// "这一轮拿到了新封面"之外还要过 coverSwapAllowed —— 见那个函数的注释。
	if coverSwapAllowed(e, fresh, album) {
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor =
			fresh.CoverURL, fresh.CoverSource, fresh.CoverAlbum, fresh.AccentColor
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
	if e.DurationSecs <= 0 {
		e.DurationSecs = fresh.DurationSecs
	}
	// 只推自己那个节流时间戳。**不要**去动 e.TS —— 那是这条记录的解析时刻,歌词重搜拿它
	// 当起算点,推它等于每补一次外围字段就把歌词重搜往后拖 10 分钟(见 TS 字段的注释)。
	e.PeripheralTS = time.Now().Unix()
	// 不管补没补上都记一次 —— 上限就是靠它生效的(见 peripheralBackfillMaxAttempts)。
	e.PeripheralRetryCount++
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
	// 歌词:网易云/QQ音乐/酷狗/Musixmatch/LRCLIB 五个源全部并发查一遍,不是查到第一个
	// 能用的就停——一首歌只在缓存未命中时解析一次,后续都直接读缓存,五个源都查一遍
	// 换来更可信的结果性价比很高。取分/并发/超时兜底细节见 scoredLyricCandidates
	// (同一份逻辑也供 desktop-lyrics 的"重新搜索候选歌词"手动纠正功能复用,搜索用的
	// CLI 子命令见 searchcli.go)——那条手动路径故意不受下面 pickLyricCandidate 的
	// "启用哪些源"过滤,理由见它的注释。
	//
	// 2026-08-10 删掉了「歌词在线匹配」总开关(见 features.go 的说明),原来关掉时走的
	// 那条 neteaseLookup 单查分支也一并删了 —— 它存在的唯一理由就是"歌词关着、但封面
	// 和跳转链接还得要"。
	ne, scored = scoredLyricCandidates(artist, title, album, durationSecs)
	// 封面/主色/平台跳转链接是基础展示信息,不做成可关闭的开关,以下逻辑无条件执行。
	e.CoverURL = ne.Cover
	if e.CoverURL != "" {
		e.CoverSource = "netease"
		e.CoverAlbum = ne.Album
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
		e.CoverAlbum = appleMatch.album
	}
	// 网易云排在 Apple 前面是为了「国内加载得出来」,**不是**为了「对得上正在播的这张
	// 专辑」。这两件事会打架:专辑本身没上网易云、只有先行单曲的时候,pick() 那条"唯一
	// 精确同名候选,专辑名对不上也认"的规则(见 netease.go,刻意保留)会命中单曲版,拿回
	// 单曲封面 —— 于是同一张专辑在"最近记录"里混着两种封面。
	//
	// 2026-08-20 实测坐实(蔡徐坤《KUN》11 首):网易云整张专辑都没有,只有 Deadman /
	// Jasmine / What a Day 三首先行单曲在库里,这三首拿到各自的单曲封面;另外 8 首网易云
	// 一条候选都没有、退到 Apple 拿到 KUN 专辑封面。Apple 那边这三首**同时**有单曲版和
	// KUN 专辑版,searchAppleMusicMatch 按 albumScore 择优本来就会选 KUN 那版(这三条的
	// apple_music_url 当时就已经指向 KUN 专辑),只是封面从没问过它。
	//
	// 所以:网易云那张明确属于另一次发行(albumScore=0)、而 Apple 那张对得上时,用 Apple
	// 的。只换封面,网易云的歌词/译文/罗马音照旧 —— 那些跟"哪张发行"无关。
	if e.CoverSource == "netease" &&
		preferAppleCoverOverNetease(e.CoverAlbum, appleMatch.album, appleMatch.cover, album) {
		e.CoverURL, e.CoverSource, e.CoverAlbum = appleMatch.cover, "apple", appleMatch.album
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
			// CoverAlbum 留空:qqCoverFallback 不回传专辑名,而它内部已经按 albumScore
			// 避开了精选集/合辑,不需要再被 coverNeedsAlbumCheck 复查一次。
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
	e.DurationSecs = durationSecs
	// 不管选没选中,都记下这一轮到底有哪些源真的给出了可用候选 —— needsLyricsRetry
	// 靠"有启用的源这轮没露面"来判断这次结果是不是在信息不全的情况下做的决定。
	e.LyricsSourcesSeen = lyricSourcesWithCandidates(scored)
	e.LyricsSourcesResponded = lyricSourcesResponded(scored)
	picked := pickLyricCandidate(scored)
	// 决策固化(见 decision.go):首次解析是最要紧的一份 —— 缓存永久保留,这一刻的运气
	// 就是这首歌以后一直显示的东西,不记下来事后无从复盘。
	e.LyricsDecision = buildLyricsDecision(
		lyricsDecisionPathFirstResolve, artist, title, album, durationSecs, scored, picked, picked != nil)
	// 首次解析这里拿不到 key(它由上层 trackEnrichment 用**未转简体**的原始标签拼),
	// 用查询词拼一个等价形状 —— trace 是流水账,要的是"能对上是哪首歌",不参与任何查找。
	traceLyricsDecision(artist+"|"+title+"|"+album, e.LyricsDecision)
	if picked != nil {
		// 首次解析选中了 → 这一轮就是当前歌词的出处(分槽语义见 LyricsDecisionApplied)。
		e.LyricsDecisionApplied = e.LyricsDecision
		e.Lyrics = picked.Lyrics
		e.LyricsSource = picked.Source
		e.LyricsScore = picked.Score
		e.LyricsScoringVersion = lyricsScoringVersion
		e.ResolvedDurationSecs = durationSecs
		e.LyricsTr, e.LyricsRoma, e.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
		// 译文换人了,描述译文的两个字段必须跟着换:语言(否则拿旧语言判新译文),
		// 来源(否则上一轮机翻留下的 "machine" 会让新来的社区译文被标成机翻)。
		e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, ""
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
	return e
}

// pickLyricCandidate 从 scoredLyricCandidates 返回的全量候选里,按用户在"歌词"设置
// 分类里配置的"启用哪些源"+"挑选算法"选出最终采用的一条——只用于自动解析路径
// (resolveTrackEnrichment,上面)。手动的 `collector search-lyrics` CLI 子命令("歌词
// 管理"窗口的"重新搜索候选歌词"功能)不复用这个函数(它需要保留完整排序列表给用户挑,
// 不是只要一个赢家),但对"启用哪些源"这条设置口径一致——两条路径都只看你在设置里开着
// 的那几个源,只是手动搜索用的是 searchcli.go 里单独的 filterEnabledLyricSources,
// 不是直接调这个函数。
// pickLyricCandidatePreferring 是 pickLyricCandidate 的"用户选定过源"版本。
//
// sourceChoice 为空时逐字等价于 pickLyricCandidate。非空时**只在那个源的候选里选**:
// 用户明确说过"这首歌我要这个源的词",自愈路径就不该把它换掉,但仍然可以在同一个源
// 内升级(那个源这一轮给出了逐字/更完整的正文时照样能换上来)。
//
// 那个源这一轮一条候选都没有时返回 nil = **不换**,而不是退回全局最优 —— 退回去就等于
// 悄悄推翻用户的选择,而"这一轮没应答"最常见的原因只是超时或限流。
//
// 用户后来在设置里禁用了那个源时,过滤出来的候选会被 pickLyricCandidate 自己的
// features.LyricsSources 闸挡掉,同样落到"不换"。保守是对的:那是两个独立的意图,
// 不该由这里替用户合并。
func pickLyricCandidatePreferring(scored []scoredLyricCandidateResult, sourceChoice string) *scoredLyricCandidateResult {
	if sourceChoice == "" {
		return pickLyricCandidate(scored)
	}
	filtered := make([]scoredLyricCandidateResult, 0, len(scored))
	for _, c := range scored {
		if c.Source == sourceChoice {
			filtered = append(filtered, c)
		}
	}
	return pickLyricCandidate(filtered)
}

func pickLyricCandidate(scored []scoredLyricCandidateResult) *scoredLyricCandidateResult {
	if features.LyricsSourceMode == lyricsModePriority {
		for _, source := range features.LyricsSourceOrder {
			if !lyricSourceEnabled(source) {
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
		if !lyricSourceEnabled(scored[i].Source) {
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
	LyricsTrLang  string `json:"lyrics_tr_lang,omitempty"`
	LyricsRoma    string `json:"lyrics_roma,omitempty"`
	LyricsYRC     string `json:"lyrics_yrc,omitempty"`
	HasWordTiming bool   `json:"has_word_timing"`
	Score         int    `json:"score"`
	// ScoreTerms 是这个分数的构成明细(或者被判 -1 时的唯一那条原因),给"搜索候选歌词"
	// 弹窗把分数摊开显示用。只在那条手动搜索路径上有意义,自动解析路径不读它。
	ScoreTerms []scoreTerm `json:"score_terms,omitempty"`
	// SourceReportedDurationSecs:源自己声明的曲长(秒),0=该源没给。2026-08-12 起透传,
	// 不参与打分——给下一轮维度评测攒"源报版本同一性"数据(见 lyricCandidate 同名字段)。
	SourceReportedDurationSecs float64 `json:"source_reported_duration_secs,omitempty"`
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
// 超时的空间,同时把最坏情况砍掉大半——到点还没回来的源,这一轮就不参与候选。
//
// ⚠️ 这里原来写的是"不影响它自己继续跑完、下次同一首歌缓存命中时照常能用上,只是这一次
// 不等它" —— **那是错的**。缓存没有 TTL、歌词解析一次就永久保留(只有外围字段会被
// needsPeripheralBackfill 补),缓存命中直接返回存好的那条,迟到的结果永远不会被用上。
// 2026-08-07 实测坐实这条错误注释掩盖的真问题:「悟空 2003 Demo」连查两次,一次 3 秒返回、
// 候选里根本没有网易云,lrclib 以 83 分胜出;另一次跑满 20 秒,网易云回来了、525 分带逐字。
// 第一种情况一旦发生在首次解析上,这首歌就永久用着 83 分那份。现在靠 needsLyricsRetry 兜:
// 记下当初"哪些源露过面",有启用的源缺席就在之后择机重搜一次,分数更高才替换。这个常量同时
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
	return scoredLyricCandidatesStreaming(artist, title, album, durationSecs, func(neteaseInfo, []scoredLyricCandidateResult, int, int) {})
}

// scoredLyricCandidatesStreaming 是 scoredLyricCandidates 的流式版本(见
// fetchScoredLyricCandidatesStreaming 顶部注释)——onUpdate 一路透传给主查询和(如果
// 触发了)别名重试查询,所以手动搜索(searchcli.go)在别名重试这条冷门路径上也能看到
// 陆续到达的候选,不会因为切换成了 alias 重试就突然掉回"等全部查完才展示"。
func scoredLyricCandidatesStreaming(artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	ne, results := fetchScoredLyricCandidatesStreaming(artist, title, album, durationSecs, onUpdate)
	// 判据是"有没有**能用**的候选",不是"有没有候选"。
	//
	// 原来写的是 len(results) > 0 —— 五个源都答了、但每一条都被 scoreLyricCandidate 判
	// 了 -1(不是逐行时间戳、语言对不上、整份只有署名行……)时,results 非空,于是重试根本
	// 不触发,最后拿一堆废候选收场。而这恰恰是最该换个歌手名再试一次的情形。
	if !hasUsableLyricCandidate(results) {
		// Apple 目录锚点给的权威署名排在手工别名表/MusicBrainz **前面**:它是这首歌
		// 自己的元数据(而不是"这位歌手一般叫什么"),证据强度更高,而且专辑署名恰好覆盖
		// 手工表和 MB 都够不到的那一类——演唱会嘉宾/群星合辑/客串曲目。见
		// appleCatalogSearchIdentities。两边的名字去重,免得同一个名字查两轮。
		for _, alt := range dedupeArtistIdentities(
			appleCatalogSearchIdentities(artist, title, album),
			retryArtistIdentities(artist)) {
			altNe, altResults := fetchScoredLyricCandidatesStreaming(alt, title, album, durationSecs, onUpdate)
			if hasUsableLyricCandidate(altResults) {
				log.Printf("lyrics: artist alias fallback succeeded: original_artist=%q alias=%q title=%q candidates=%d",
					artist, alt, title, len(altResults))
				// 封面/链接一并采用这一轮的结果。原名查空时 ne 里的封面和跳转链接本来就是
				// 空的,而原来这里写的是 `_, aliasResults :=`——把别名这轮查到的 neteaseInfo
				// 整个丢掉,结果是"歌词有了、封面没了"。只在原来那份确实没有时才覆盖,不动
				// 已经拿到的东西。身份类别名是"同一个人换个写法",整份 ne(含 Artist)可以
				// 采用——跟下面 credit 拆分变体轮"只许补封面/链接"不同。
				if ne.Cover == "" && altNe.Cover != "" {
					ne = altNe
				}
				// 不再直接 return(2026-08-20):别名轮救回的可能也只有一个源,落到下面的
				// 首歌手变体轮再看要不要补——单人歌手在那里生成不出变体,行为不变。
				results = altResults
				break
			}
			// 这一轮也没有能用的,但如果原来那批是彻底空的,留下有内容的这批 ——
			// "搜索候选歌词"弹窗至少还能把它们摊开给用户看,附带被判废的原因。
			if len(results) == 0 && len(altResults) > 0 {
				results = altResults
				if ne.Cover == "" && altNe.Cover != "" {
					ne = altNe
				}
			}
		}
	}
	// 首歌手变体轮(2026-08-20,「wherever u r」案):本地标签是多人合credit
	// ("UMI & 金泰亨")时,LRCLIB 的结构化 artist_name 参数在服务端就查不到(404),
	// 网易云对不同歌手串还会选中不同版本的条目——这类**召回层**的失败,闸门放宽
	// (lyricSourceArtistMatches)救不了,只能换检索词再查一轮。触发条件是"可用候选的
	// 来源数 < 2"而不是"全空":上面别名重试就是被网易云一条 462 分候选短路,酷狗/QQ 的
	// 逐字候选永远没机会被看见的。变体轮的结果**合并**进原串轮(按源去重、原串轮优先、
	// 统一按原串重打分),不是整体替换——见 mergeLyricCandidateRounds。
	// 触发阈值按**启用源数**封顶:只启用 1 个歌词源时,可用源数的上限就是 1,写死 <2 会
	// 让"那一个源已经成功"的多人合credit歌曲每次都白跑最多 3 轮全源抓取(merged 计数
	// 永远追不上 2,采纳门槛每次都把结果丢掉,网络却已经打出去了)。
	targetSources := 2
	if n := enabledLyricSourceCount(); n < targetSources {
		targetSources = n
	}
	if primary := lyricPrimaryQueryArtist(artist); primary != "" && usableLyricSourceCount(results) < targetSources {
		tryVariant := func(alt string) {
			// onUpdate 包一层:变体轮期间把每次流式更新先与已有结果合并再上报。裸透传的话
			// "搜索候选歌词"弹窗(整行替换列表,见 searchcli.go 顶注)会先缩水成变体轮自己
			// 的部分结果、直到最终 emit 才恢复——中间态闪变,且闪出来的分数还是按变体串
			// 打的。自动解析路径 onUpdate 是空函数,不受影响。
			//
			// ⚠️ 已知的语义边界(刻意接受):base 这批候选如果来自上面身份别名轮,它们当初
			// 是按别名串打的分,这里合并重打分统一换回原串——两套裁判对语言闸
			// (isProbablyWrongLanguageLyrics 只看 localArtist/localTitle 含不含汉字)可能
			// 给出不同判决。可达性极低(别名表登记的都是单人名,多人合credit整串登不进去),
			// 且采纳门槛要求可用源数净增,重打分变差只会导致"不采纳",不会污染已有结果。
			mergedUpdate := func(vne neteaseInfo, vres []scoredLyricCandidateResult, done, total int) {
				onUpdate(vne, mergeLyricCandidateRounds(artist, title, album, durationSecs, results, vres), done, total)
			}
			altNe, altResults := fetchScoredLyricCandidatesStreaming(alt, title, album, durationSecs, mergedUpdate)
			merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, altResults)
			if usableLyricSourceCount(merged) <= usableLyricSourceCount(results) {
				return
			}
			log.Printf("lyrics: primary-artist variant added candidates: original_artist=%q variant=%q title=%q usable_sources=%d->%d",
				artist, alt, title, usableLyricSourceCount(results), usableLyricSourceCount(merged))
			results = merged
			// ⚠️ 只许补封面/跳转链接,**绝不**整份采用 altNe:变体串是把合credit截成
			// 首歌手查出来的,altNe.Artist 是按"单人查询"放行的单人名,顺手带回去会经
			// resolveTrackEnrichment 的 e.CanonicalArtist = ne.Artist 把 "A & B" 缩窄成
			// "A"(2026-07-10 的多credit缩窄回归正是这个形态,netease.go:374 那道守卫
			// 收的是**本轮查询串**,对变体轮的单人串不设防)。
			// 采纳封面时 Album/AlbumID 必须跟着封面一起走:e.CoverAlbum 记的是**这张封面**
			// 属于哪张专辑(preferAppleCoverOverNetease 用它判断封面是不是另一次发行),
			// 只拷 Cover 会留下 CoverSource=netease 而 CoverAlbum="" 的半份状态——
			// albumScore("", album)==0 会被当成"明确属于另一发行",Apple 对得上时立刻把
			// 网易云封面掀成国内加载不出的 mzstatic,违背封面选源的本意。
			if ne.Cover == "" && altNe.Cover != "" {
				ne.Cover, ne.Album, ne.AlbumID = altNe.Cover, altNe.Album, altNe.AlbumID
			}
			if ne.SongURL == "" && altNe.SongURL != "" {
				ne.SongURL = altNe.SongURL
			}
		}
		tryVariant(primary)
		if usableLyricSourceCount(results) < targetSources {
			// 首歌手本身没救回来时,再试首歌手的已知别名/MusicBrainz 中文名(比如本地
			// 标签 "Leah Dou & 别人" 截出 "Leah Dou" 还是查不到,换 "窦靖童" 再试)。
			// retryArtistIdentities 自带去重,最多两个变体,每轮 20s 兜底,上限可控。
			for _, alt := range retryArtistIdentities(primary) {
				tryVariant(alt)
				if usableLyricSourceCount(results) >= targetSources {
					break
				}
			}
		}
	}
	return ne, results
}

// hasUsableLyricCandidate:这批候选里有没有至少一条没被判废的。
// Score < 0 是 scoreLyricCandidateDetailed 的"一票否决"标记(见 match.go 里的
// scoreReject* 常量),不是"分低"。
func hasUsableLyricCandidate(scored []scoredLyricCandidateResult) bool {
	for _, c := range scored {
		if c.Score >= 0 {
			return true
		}
	}
	return false
}

// usableLyricSourceCount 数这批候选里"给出了可用候选"的**来源**有几个——是首歌手变体轮
// 的触发判据(<2 才值得多花一轮网络):hasUsableLyricCandidate 只答"有没有",这里要的是
// "有几个源在场"——「wherever u r」那次网易云一条 462 分候选就让整个别名重试短路,酷狗/
// QQ 的逐字候选永远没机会被看见,教训是"有一条可用"不等于"信息够了"。
// 两类候选不算数:Instrumental 标记(不是候选,是 lrclib 的"纯音乐"信号搭车,见
// scoredLyricCandidateResult.Instrumental);用户在"歌词来源"里**关掉的源**——抓取
// goroutine 不看开关、raw 结果里禁用源照样在场,但 pickLyricCandidate 和手动搜索弹窗
// 都只认启用的源,把禁用源算进"信息够了"会让变体轮在它真正该补位的配置下永远不触发
// (features.LyricsSources 为空 = 全开,与 filterEnabledLyricSources 同一条约定)。
func usableLyricSourceCount(scored []scoredLyricCandidateResult) int {
	seen := map[string]bool{}
	for _, c := range scored {
		if c.Score >= 0 && !c.Instrumental &&
			lyricSourceEnabled(c.Source) {
			seen[c.Source] = true
		}
	}
	return len(seen)
}

// lyricCandidateFromScored 把一条打好分的候选还原成打分入参形态,给
// mergeLyricCandidateRounds 合并后统一重打分用。字段都是当初构造时原样存进
// scoredLyricCandidateResult 的;hasUsableTranslation/hasUsableRomanization 当初没存,
// 按 fetchScoredLyricCandidatesStreaming 里同一套 usableValueAdd 逻辑重算(入参全部
// 来自这条候选自己带的字段,结果与首轮一致)。
func lyricCandidateFromScored(r scoredLyricCandidateResult) lyricCandidate {
	tr, roma := usableValueAdd(r.Lyrics, r.LyricsTr, r.LyricsTrLang, r.LyricsRoma, features.LyricsTranslationLanguage)
	return lyricCandidate{
		source:                     r.Source,
		lyrics:                     r.Lyrics,
		wordTimingYRC:              r.LyricsYRC,
		hasWordTiming:              r.HasWordTiming,
		hasUsableTranslation:       tr,
		hasUsableRomanization:      roma,
		sourceReportedDurationSecs: r.SourceReportedDurationSecs,
		title:                      r.Title,
		artist:                     r.Artist,
		album:                      r.Album,
		cover:                      r.CoverURL,
	}
}

// mergeLyricCandidateRounds 把首歌手变体轮查到的候选并进原串那轮里,再对合并后的成员集
// 统一重打分。规则:
//
//   - 按源去重,**原串轮优先**:原串轮已经有可用候选的源,变体轮同源那条不顶替(原串是
//     身份的 ground truth,变体只是检索词放宽;这也天然避开了"变体轮网易云选中
//     Instrumental 版"这类更差的重复条目)。原串轮那条被判废(-1)而变体轮可用时才顶替。
//     按源去重是硬约束:corroborated/consensus 的 peers 按 source 键,Swift 弹窗的
//     选中态/当前使用徽标也按 source 键,同源两条会互相顶掉。
//   - 重打分的 localArtist/localTitle 用**原串**(调用方传进来的 artist 就是它):变体串
//     无汉字时会打开 isProbablyWrongLanguageLyrics 的语言闸,"拉丁首歌手+真中文歌"会被
//     误杀——变体串只作检索词和源内采纳闸,绝不进打分。
//   - corroboratedEndings/contentConsensusPeers 按合并后的全体成员重算:变体轮捞回的源
//     就该给原串轮的候选作证(反之亦然),分数不是拼接两轮旧值能得到的。
//   - lrclib 的 Instrumental 标记:任一轮带了、且合并后没有真实的 lrclib 候选,才保留
//     一条(语义同 scoreAndSort 里"lrclibLyr 为空才附"的约定)。
func mergeLyricCandidateRounds(artist, title, album string, durationSecs float64, base, extra []scoredLyricCandidateResult) []scoredLyricCandidateResult {
	chosen := map[string]scoredLyricCandidateResult{}
	var order []string
	var instrumental *scoredLyricCandidateResult
	for _, r := range base {
		if r.Instrumental {
			if instrumental == nil {
				rr := r
				instrumental = &rr
			}
			continue
		}
		if _, ok := chosen[r.Source]; !ok {
			chosen[r.Source] = r
			order = append(order, r.Source)
		}
	}
	for _, r := range extra {
		if r.Instrumental {
			if instrumental == nil {
				rr := r
				instrumental = &rr
			}
			continue
		}
		cur, ok := chosen[r.Source]
		if !ok {
			chosen[r.Source] = r
			order = append(order, r.Source)
			continue
		}
		if cur.Score < 0 && r.Score >= 0 {
			chosen[r.Source] = r
		}
	}
	// 重建顺序按 lyricSourceNames 的固定源序,不是两轮的到达/分数序——scoreAndSort 的
	// 稳定排序约定"同分按候选构造顺序决胜,确定且可复现",合并路径要跟主路径同一套口径,
	// 否则同一首歌走没走变体轮,同分平手时可能选出不同的源。
	ordered := make([]string, 0, len(order))
	inNames := map[string]bool{}
	for _, s := range lyricSourceNames {
		if _, ok := chosen[s]; ok {
			ordered = append(ordered, s)
			inNames[s] = true
		}
	}
	for _, s := range order { // 防御:不认识的源名(理论上不存在)按到达序垫底,不丢
		if !inNames[s] {
			ordered = append(ordered, s)
		}
	}
	cands := make([]lyricCandidate, 0, len(ordered))
	for _, s := range ordered {
		cands = append(cands, lyricCandidateFromScored(chosen[s]))
	}
	corroborated := corroboratedEndings(cands, durationSecs)
	consensusPeers := contentConsensusPeers(artist, title, cands, durationSecs)
	out := make([]scoredLyricCandidateResult, 0, len(ordered)+1)
	// "合并后有没有**标记那个源自己**的真候选"。2026-08-20 从写死的 lrclib 改成按标记
	// 的 Source 判:纯音乐标记现在也可能来自网易云(见 scoreAndSort 里的 instrumentalMarker),
	// 写死 lrclib 会让"网易云既给了真歌词、又带着纯音乐标记"这种自相矛盾的组合被保留。
	hasRealFromMarkerSource := false
	for i, s := range ordered {
		r := chosen[s]
		r.Score, r.ScoreTerms = scoreLyricCandidateDetailed(
			artist, title, album, durationSecs, cands[i], corroborated[s], consensusPeers[s])
		if instrumental != nil && s == instrumental.Source {
			hasRealFromMarkerSource = true
		}
		out = append(out, r)
	}
	if instrumental != nil && !hasRealFromMarkerSource {
		out = append(out, *instrumental)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Score > out[j].Score })
	return out
}

// fetchScoredLyricCandidates 是真正"拿这一个具体的歌手名字符串,去查网易云/QQ/酷狗/
// Musixmatch/LRCLIB 五个源、给查到的候选打分"的实现——从 scoredLyricCandidates 里
// 拆出来,是为了在第一次用原始歌手名查询彻底查无候选时,能原封不动地对已知别名再
// 调用一遍(见 scoredLyricCandidates 上面的注释),而不必把并发抓取/打分这套逻辑抄
// 第二遍。只关心最终这一批结果的调用方(resolveTrackEnrichment/别名重试)走这个
// 薄封装;真正的实现在下面 fetchScoredLyricCandidatesStreaming,onUpdate 传空函数。
func fetchScoredLyricCandidates(artist, title, album string, durationSecs float64) (neteaseInfo, []scoredLyricCandidateResult) {
	return fetchScoredLyricCandidatesStreaming(artist, title, album, durationSecs, func(neteaseInfo, []scoredLyricCandidateResult, int, int) {})
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
// lyricSearchUpdateFunc 是流式搜索的进度回调。done/total 是**歌词源**的完成进度
// (给"搜索候选歌词"弹窗显示 (X/Y)):
//
//   - total 只数用户在"歌词来源"里**开着**的源。关掉的源即便查了也不会出现在候选里
//     (见 filterEnabledLyricSources),把它算进分母会让进度永远停在 4/5 这种数上。
//   - 六个并发 goroutine 里有一个是 applecover(只查封面兜底),它不是歌词源,不计入。
//   - 别名重试那条路径会带着同一个回调再跑一轮完整搜索,于是 done 会从头再数一遍 ——
//     如实反映"确实又查了五个源",不假装单调递增。
type lyricSearchUpdateFunc func(ne neteaseInfo, results []scoredLyricCandidateResult, done, total int)

// lyricSourceNames 是五个歌词源的名字,顺序无关紧要,只用来数进度分母。
// applecover 不在里面 —— 它查的是封面。
var lyricSourceNames = []string{"netease", "qq", "kugou", "lrclib", "musixmatch", "amll"}

// enabledLyricSourceCount 数"用户开着的歌词源"有几个。features.LyricsSources 为空
// 表示还没配置过 = 全开(跟 filterEnabledLyricSources 同一条约定)。
func enabledLyricSourceCount() int {
	n := 0
	for _, s := range lyricSourceNames {
		if lyricSourceEnabled(s) {
			n++
		}
	}
	return n
}

func fetchScoredLyricCandidatesStreaming(artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	type sourceResult struct {
		source                  string
		ne                      neteaseInfo
		lyr, yrc, tr            string
		matchTitle, matchArtist string
		matchAlbum, matchCover  string
		srcDur                  float64 // 源自己声明的曲长(秒),0=没给。见 lyricCandidate.sourceReportedDurationSecs
		// instrumental:"这首歌是纯音乐"这个**明确结论**。三个源会给:lrclib 的结构化字段、
		// 网易云的 pureMusic/占位正文、QQ 的占位正文(2026-08-22 加,见 qqLyricResult)。
		instrumental bool
		// amll:amll-ttml-db 那一档的三件套(见 amllttml.go)。它跟别的源不同,一次就带回
		// 整行+逐字+译文,所以单独放一个结构而不是复用上面的 lyr/yrc/tr。
		amll amllResult
	}
	resultsCh := make(chan sourceResult, 7)

	// amll-ttml-db 按**平台音乐 ID**取歌词,所以它得等网易云/QQ 先把 ID 搜出来。
	// 用两个带缓冲的 channel 把 ID 递过去,而不是把查询塞进那两个 goroutine 里 ——
	// 那样会把 amll 的网络耗时串到它们头上,拖慢主力源的到达时间。
	neteaseIDCh := make(chan string, 1)
	qqIDCh := make(chan string, 1)

	go func() {
		info := neteaseLookup(artist, title, album)
		if info.SongID > 0 {
			neteaseIDCh <- strconv.FormatInt(info.SongID, 10)
		} else {
			neteaseIDCh <- ""
		}
		resultsCh <- sourceResult{source: "netease", ne: info}
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
		var qqDur float64
		var qqInstrumental bool
		if qqMid != "" {
			qqLyr := qqLyric(qqMid)
			lyr, qqInstrumental = qqLyr.lrc, qqLyr.instrumental
			// 逐字(QRC)是完全独立的一套接口/密钥,自己失败不影响上面整行歌词——
			// 见 qq.go 顶部注释。
			yrc = qqQRCLyric(qqMid, artist, title, album, durationSecs)
			// 只读缓存:QRC 那步走通时(它内部查过同一首的单曲详情)这里是热的,没走通
			// (会话拿不到 sid / 详情接口失败,那边不写负缓存)就留 0。srcDur 是纯透传的
			// 评测数据,不值得为它在歌词主路径上多挂一次最多 6s 的请求(2026-08-12 审阅)。
			qqDur = qqSongMetaCachedOnly(qqMid).interval
		}
		qqIDCh <- qqMid
		resultsCh <- sourceResult{source: "qq", lyr: lyr, yrc: yrc, matchTitle: match.title, matchArtist: match.artist, matchAlbum: match.album, srcDur: qqDur, instrumental: qqInstrumental}
	}()
	go func() {
		// 等两个 ID 都到齐再查。两个 goroutine 都是无条件启动的(启用与否在后面
		// filterEnabledLyricSources 那步过滤),所以这两个 channel 一定会收到值,
		// 不会在这里挂死。
		neteaseID, qqID := <-neteaseIDCh, <-qqIDCh
		resultsCh <- sourceResult{source: "amll", amll: amllLyric(neteaseID, qqID)}
	}()
	go func() {
		r := kugouLyric(artist, title, album, durationSecs)
		resultsCh <- sourceResult{source: "kugou", lyr: r.lrc, yrc: r.yrc, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, srcDur: r.durationSecs}
	}()
	go func() {
		r := lrclibLyric(artist, title, album, durationSecs)
		resultsCh <- sourceResult{source: "lrclib", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, srcDur: r.durationSecs, instrumental: r.instrumental}
	}()
	go func() {
		r := musixmatchLyric(artist, title, durationSecs, features.LyricsTranslationLanguage)
		resultsCh <- sourceResult{source: "musixmatch", lyr: r.lrc, yrc: r.yrc, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs}
	}()
	go func() {
		// 跟 resolveTrackEnrichment 里 e.AppleURL = appleMatch.url 共用同一份
		// appleURLCache——谁先查到谁写缓存,这里不重复消耗一次网络请求。
		resultsCh <- sourceResult{source: "applecover", matchCover: appleMusicMatchCached(artist, title, album).cover}
	}()

	var ne neteaseInfo
	var qqLyr, qqYRC, qqTitle, qqArtist, qqAlbum string
	var qqDur, kugouDur, lrclibDur float64
	var kugouLyr, kugouYRC, kugouTitle, kugouArtist, kugouAlbum string
	var lrclibLyr, lrclibTitle, lrclibArtist, lrclibAlbum string
	var lrclibInstrumental bool
	var qqInstrumental bool
	var mxLyr, mxYRC, mxTr, mxTitle, mxArtist, mxAlbum, mxCover string
	var mxDur float64
	var amll amllResult
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
			// 网易云的社区翻译固定中文(见下面附着处的注释),usable 判定按目标语言过闸;
			// 这两个标志必须在**打分前**算好挂到候选上(v3 的增值内容决胜分要读它),
			// 不能等选完冠军再附着。
			neTr, neRoma := usableValueAdd(ne.Lyrics, ne.Trans, "zh", ne.Roma, features.LyricsTranslationLanguage)
			candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.Lyrics, wordTimingYRC: usableYRC(ne.Lyrics, ne.YRC), hasWordTiming: usableWordTiming(ne.Lyrics, ne.YRC), hasUsableTranslation: neTr, hasUsableRomanization: neRoma, sourceReportedDurationSecs: ne.DurationSecs, title: ne.Title, artist: ne.Artist, album: ne.Album, cover: coverOrFallback(ne.Cover)})
		}
		if qqLyr != "" {
			candidates = append(candidates, lyricCandidate{source: "qq", lyrics: qqLyr, wordTimingYRC: usableYRC(qqLyr, qqYRC), hasWordTiming: usableWordTiming(qqLyr, qqYRC), sourceReportedDurationSecs: qqDur, title: qqTitle, artist: qqArtist, album: qqAlbum, cover: coverOrFallback("")})
		}
		if kugouLyr != "" {
			candidates = append(candidates, lyricCandidate{source: "kugou", lyrics: kugouLyr, wordTimingYRC: usableYRC(kugouLyr, kugouYRC), hasWordTiming: usableWordTiming(kugouLyr, kugouYRC), sourceReportedDurationSecs: kugouDur, title: kugouTitle, artist: kugouArtist, album: kugouAlbum, cover: coverOrFallback("")})
		}
		if mxLyr != "" {
			mxUsableTr, _ := usableValueAdd(mxLyr, mxTr, features.LyricsTranslationLanguage, "", features.LyricsTranslationLanguage)
			candidates = append(candidates, lyricCandidate{source: "musixmatch", lyrics: mxLyr, wordTimingYRC: usableYRC(mxLyr, mxYRC), hasWordTiming: usableWordTiming(mxLyr, mxYRC), hasUsableTranslation: mxUsableTr, sourceReportedDurationSecs: mxDur, title: mxTitle, artist: mxArtist, album: mxAlbum, cover: coverOrFallback(mxCover)})
		}
		if lrclibLyr != "" {
			candidates = append(candidates, lyricCandidate{source: "lrclib", lyrics: lrclibLyr, sourceReportedDurationSecs: lrclibDur, title: lrclibTitle, artist: lrclibArtist, album: lrclibAlbum, cover: coverOrFallback("")})
		}
		if !amll.empty() {
			// 身份是确定的 —— 这份 TTML 是按网易云/QQ 的音乐 ID 直接取回来的,不是搜出来的,
			// 所以 title/artist/album 直接沿用本地曲目信息,不会在标题/歌手/专辑那几项上
			// 被扣分。它没有自报时长,sourceReportedDurationSecs 留 0(= 该项不参与打分)。
			amllTr, _ := usableValueAdd(amll.lrc, amll.tr, features.LyricsTranslationLanguage, "", features.LyricsTranslationLanguage)
			candidates = append(candidates, lyricCandidate{
				source: "amll", lyrics: amll.lrc,
				wordTimingYRC: usableYRC(amll.lrc, amll.yrc), hasWordTiming: usableWordTiming(amll.lrc, amll.yrc),
				hasUsableTranslation: amllTr,
				title:                title, artist: artist, album: album, cover: coverOrFallback(""),
			})
		}
		corroborated := corroboratedEndings(candidates, durationSecs)
		// v3:跨源正文共识,整批统一算(理由同 corroboratedEndings——peers 随后到的源变化,
		// 每轮全量重算)。artist/title 已是 toSimplified 后的搜索关键词,与打分入参一致。
		consensusPeers := contentConsensusPeers(artist, title, candidates, durationSecs)
		// lrclib 明确说这首歌是纯音乐、且没有真的歌词候选(lrclibLyr=="")时,搭车塞一条
		// Score:-1 的标记进 results——见 Instrumental 字段定义处的注释,不参与打分/排序,
		// 不会被 pickLyricCandidate 选中,只是把这个信号原样带出这个函数。
		var instrumentalMarker *scoredLyricCandidateResult
		if lrclibLyr == "" && lrclibInstrumental {
			instrumentalMarker = &scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true}
		} else if qqLyr == "" && qqInstrumental {
			// QQ 那一路(2026-08-22 加)。实测案例:蛋堡《收敛水》第 1 轨「关键字: Intro」
			// (114s 的专辑 intro)——网易云只有一行署名(没有 pureMusic 字段)、酷狗
			// KRC 候选 0 条、LRCLIB 404,**只有 QQ 明确回了**「此歌曲为没有填词的纯音乐」。
			// 在此之前那句话在 resolveQQLyric 末尾的 isTimedLRC(要求 ≥3 行带戳)那里就被
			// 当成"不是歌词"扔掉了,于是这类曲目落在「无歌词」而不是「纯音乐」:界面上看起来
			// 像失败,还要每 24 小时(退避后翻倍)白搜一轮五个源。
			// 排在网易云之前只是因为 QQ 这句话是**明文断言**、语义比"正文只有占位"更硬。
			instrumentalMarker = &scoredLyricCandidateResult{Source: "qq", Score: -1, Instrumental: true}
		} else if ne.Lyrics == "" && ne.PureMusic {
			// 网易云那一路同款(2026-08-20 加)。用户报「一堆条目显示无歌词、其实都是
			// 纯音乐」(LoL 原声带 The Music of League of Legends Vol.1 十几首):
			// 那些曲目 lrclib 压根没有(五源全空、responded 是空的),而网易云**匹配上了
			// 歌**(封面/单曲链接都给了)、歌词接口也明确回了 pureMusic=true —— 结论一直
			// 在手上,只是没人接。lrclib 优先只是因为它的标记是结构化字段、语义最干净。
			instrumentalMarker = &scoredLyricCandidateResult{Source: "netease", Score: -1, Instrumental: true}
		}

		results := make([]scoredLyricCandidateResult, 0, len(candidates))
		for _, c := range candidates {
			r := scoredLyricCandidateResult{
				Source:                     c.source,
				Lyrics:                     c.lyrics,
				LyricsYRC:                  c.wordTimingYRC,
				HasWordTiming:              c.hasWordTiming,
				SourceReportedDurationSecs: c.sourceReportedDurationSecs,
				Title:                      c.title,
				Artist:                     c.artist,
				Album:                      c.album,
				CoverURL:                   c.cover,
			}
			r.Score, r.ScoreTerms = scoreLyricCandidateDetailed(
				artist, title, album, durationSecs, c, corroborated[c.source], consensusPeers[c.source])
			switch c.source {
			case "netease":
				// 翻译/罗马音网易云固定给中文;QQ/酷狗这次只接了逐字,不接翻译/罗马音,
				// 见计划"刻意不做的"。"固定中文"这件事必须记下来:目标语言不是中文时,
				// 这份译文用不上,得让机翻接手(见 needsTranslationBackfill)。
				r.LyricsTr, r.LyricsRoma = ne.Trans, ne.Roma
				if r.LyricsTr != "" {
					r.LyricsTrLang = "zh"
				}
			case "musixmatch":
				// Musixmatch 的译文语言是用户在"歌词"设置里配的
				// LyricsTranslationLanguage(ISO 639-1 代码),不像网易云固定中文——
				// 见 musixmatchTranslationLRC 注释。没配置/没查到社区翻译时 mxTr 是
				// 空串,r.LyricsTr 保持空,不影响这条候选本身的原文歌词。
				r.LyricsTr = mxTr
				if r.LyricsTr != "" {
					// 抓取时用的就是当时设置里的语言。之后用户改了设置,这里记下的旧语言
					// 就会跟新目标对不上 —— 那正是要的:对不上就重翻。
					r.LyricsTrLang = features.LyricsTranslationLanguage
				}
			}
			results = append(results, r)
		}
		if instrumentalMarker != nil {
			results = append(results, *instrumentalMarker)
		}
		// 稳定排序:来源加分拿掉之后同分会变多(见 scoreLyricCandidateDetailed 里那段注释),
		// 不稳定的排序会让同分候选的先后随运行变化,同一首歌两次解析可能选出不同的源。
		// 稳定之后就是按 candidates 的构造顺序决胜,确定且可复现。
		sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
		return results
	}

	deadline := time.After(lyricSearchDeadline)
	// 哪些歌词源已经回来了。按名字记而不是只数个数:六个 goroutine 里有一个是
	// applecover(封面兜底,不是歌词源),数个数会把它算进进度、让 (X/Y) 虚高一格。
	doneSources := map[string]bool{}
	totalSources := enabledLyricSourceCount()
	enabledDone := func() int {
		n := 0
		for _, s := range lyricSourceNames {
			if doneSources[s] && lyricSourceEnabled(s) {
				n++
			}
		}
		return n
	}
collect:
	for i := 0; i < 7; i++ {
		select {
		case r := <-resultsCh:
			doneSources[r.source] = true
			switch r.source {
			case "amll":
				amll = r.amll
			case "netease":
				ne = r.ne
			case "qq":
				qqLyr, qqYRC, qqTitle, qqArtist, qqAlbum, qqDur = r.lyr, r.yrc, r.matchTitle, r.matchArtist, r.matchAlbum, r.srcDur
				qqInstrumental = r.instrumental
			case "kugou":
				kugouLyr, kugouYRC, kugouTitle, kugouArtist, kugouAlbum, kugouDur = r.lyr, r.yrc, r.matchTitle, r.matchArtist, r.matchAlbum, r.srcDur
			case "lrclib":
				lrclibLyr, lrclibTitle, lrclibArtist, lrclibAlbum, lrclibDur = r.lyr, r.matchTitle, r.matchArtist, r.matchAlbum, r.srcDur
				lrclibInstrumental = r.instrumental
			case "musixmatch":
				mxLyr, mxYRC, mxTr, mxTitle, mxArtist, mxAlbum, mxCover, mxDur = r.lyr, r.yrc, r.tr, r.matchTitle, r.matchArtist, r.matchAlbum, r.matchCover, r.srcDur
			case "applecover":
				appleCover = r.matchCover
			}
			onUpdate(ne, scoreAndSort(), enabledDone(), totalSources)
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
		// 文件不存在是首次启动的正常情况;别的读错误必须喊出来 —— 静默当成空库,
		// 接下来第一次保存就会把用户攒的整个缓存盖成几条新数据(2026-08-16 实锤:
		// 204 条被磨到 10 条,用户手工修过的歌词也在里面)。
		if !os.IsNotExist(err) {
			log.Printf("load enrich cache: %v — starting empty, existing file left untouched", err)
		}
		return
	}
	var m map[string]enrichEntry
	if err := json.Unmarshal(data, &m); err != nil || m == nil {
		// 解析不动就把原文件挪到一边保住,绝不留在原位等着被后续保存覆盖。
		side := path + ".corrupt"
		if renameErr := os.Rename(path, side); renameErr == nil {
			log.Printf("enrich cache unreadable (%v) — moved aside to %s, starting empty", err, side)
		} else {
			log.Printf("enrich cache unreadable (%v) and could not move aside (%v)", err, renameErr)
		}
		return
	}
	enrichMu.Lock()
	enrichCache = m
	enrichMu.Unlock()
	log.Printf("loaded %d cached track enrichments from %s", len(m), path)
}

// saveEnrichCache atomically writes the cache when dirty (temp file + rename).
//
// ⚠️ enrichSaveMu 罩住 marshal→write→rename 全程,两个并发保存**串行**执行。
// 2026-08-16 实锤过不串行的两种翻车:①两个保存都用 pid 命名的同一个 tmp 文件,
// 先 rename 的把对方的文件偷走,后 rename 的报 no such file(日志里连着两条);
// ②更毒的是慢的那个拿着**过期快照**最后落盘,把新数据盖回老状态。tmp 文件也改用
// os.CreateTemp 的随机名,同名互踩从根上不可能。
var enrichSaveMu sync.Mutex

func saveEnrichCache() {
	enrichSaveMu.Lock()
	defer enrichSaveMu.Unlock()
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
	tmp, err := os.CreateTemp(filepath.Dir(enrichPath), filepath.Base(enrichPath)+".tmp.*")
	if err != nil {
		log.Printf("save enrich cache: %v", err)
		return
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		log.Printf("save enrich cache: %v", err)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		log.Printf("save enrich cache: %v", err)
		return
	}
	if err := os.Rename(tmp.Name(), enrichPath); err != nil {
		os.Remove(tmp.Name())
		log.Printf("save enrich cache: %v", err)
	}
}
