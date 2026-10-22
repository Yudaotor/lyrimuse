package main

import (
	"context"
	"encoding/json"
	"errors"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"log/slog"
	"math"
	neturl "net/url"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// enrichEntry is a track's resolved metadata, persisted permanently once
// resolved (歌手|歌名|专辑 key) — there is no cache/TTL concept for the
// identity fields (Lyrics/CoverURL/CanonicalArtist/等): once a song is
// listened to and resolved, its data lives on local disk until the user
// explicitly deletes it via desktop-lyrics 的"歌词管理"窗口 (which clears the
// whole entry, letting the next play resolve fresh). TS is only used to
// throttle the one thing that still self-heals automatically — see
// needsPeripheralBackfill.
// songLanguageFromScored 在**全部**候选(不只是最终胜出、拿到歌词正文的那个)里找
// 第一个非空的 Language。目前只有 qq/kugou 会给这个信号,netease 从来不给——如果只看
// picked.Language,遇到"胜出的歌词正文来自网易云,但 QQ/酷狗也搜到了这首歌"这种常见
// 情况,SongLanguage 会白白留空,即使别的候选已经给出了权威的语种真值。取哪个候选的
// 歌词正文(picked)和这首歌到底是什么语种(SongLanguage)是两件独立的事,不能混着判。
func songLanguageFromScored(scored []scoredLyricCandidateResult) string {
	for _, c := range scored {
		if c.Language != "" {
			return c.Language
		}
	}
	return ""
}

// songwritersFromScored:这一轮里各源给的词曲作者名单。过了身份关(分数 >= 0)的 applemusic 候选优先,
// 其次 amll(它的 TTML 多半就是 Apple 那份),再次 deezer;都没有时为 nil。deezer 那份正文是中日韩文字时不用它的
// 名单(writtenInCJKScript):这类歌它给的是拼音或罗马字、名在前姓在后。跟 songLanguageFromScored 一样从全部候选里取:
// 名单描述的是这首歌,跟最后用了谁的歌词正文无关。见 09 章决策 155。
func songwritersFromScored(scored []scoredLyricCandidateResult) []string {
	for _, src := range []string{"applemusic", "amll", "deezer"} {
		for _, c := range scored {
			if c.Source != src || c.Score < 0 || len(c.Songwriters) == 0 {
				continue
			}
			if src == "deezer" && writtenInCJKScript(c.Lyrics) {
				continue
			}
			return c.Songwriters
		}
	}
	return nil
}

// writtenInCJKScript:正文(lyricConsensusBody)的主要文字是汉字、假名或谚文。
func writtenInCJKScript(lyrics string) bool {
	switch dominantScript(lyricConsensusBody(lyrics)) {
	case scriptHan, scriptKana, scriptHangul:
		return true
	}
	return false
}

// needsRomanizationRetry 判断"要不要为了拿罗马音/语种信号,多试几个艺人名变体"。
//
// 存在的理由:本地标签往往是罗马化艺名(側田 → "Justin Lo"),用它搜时 musixmatch+lrclib
// 这类源就已经凑够 targetSources 的门槛,"首歌手变体轮"根本不会触发 —— 而这类歌真正需要的
// 是让 QQ/酷狗(全仓库唯一会上报 Language 字段、间接触发粤语粤拼自动生成
// maybeGenerateJyutpingRoma 的两个源)用本名再搜一次。
//
// 判据不是"这首歌是中文":日语(假名为主,偶尔汉假混排)、韩语(谚文)理论上同样需要
// 罗马音,只是目前全仓库唯一的罗马音来源是网易云自己的 Roma 字段(没有语种信号挂钩,见
// netease.go),而这条触发条件对它同样有效。复用 translate.go 给翻译路由用的 dominantScript,
// 三大文字系统(scriptHan/scriptKana/scriptHangul)覆盖粤语/官话/日语/韩语,纯拉丁文的
// 英文歌不会命中任何一个候选文字系统判据,不会多打这一轮网络请求。
//
// 已经有任意一个源给出罗马音或语种信号时直接放行(不需要再试)——这条要放在文字系统
// 判断前面:找到信号就该停,不管其它候选文字系统判成什么。
//
// 只看能用的候选(Score >= 0):被判废的多半是别的歌(对不上歌手、语种不对),它是什么文字、带没带信号都说明不了这一首,
// 不该为它多跑一轮全源重查,也不该因为它带着信号就不跑。
func needsRomanizationRetry(results []scoredLyricCandidateResult) bool {
	needsScript := false
	for _, r := range results {
		if r.Score < 0 {
			continue
		}
		if r.LyricsRoma != "" || r.Language != "" {
			return false
		}
		if r.Lyrics == "" {
			continue
		}
		switch dominantScript(r.Lyrics) {
		case scriptHan, scriptKana, scriptHangul:
			needsScript = true
		}
	}
	return needsScript
}

// maybeGenerateJyutpingRoma:歌曲语种是粤语、且这一轮没有任何源给出罗马音字段时,
// 引擎自己拼一份粤拼填进去(见 jyutping.go)。只在 LyricsRoma 原本为空时补——
// 绝不覆盖任何源自己给出的罗马音(哪怕语种判断这次翻车,也不会把已经可用的内容换掉)。
func (e *enrichEntry) maybeGenerateJyutpingRoma() {
	if e.SongLanguage == songLanguageCantonese && !e.Lyrics.IsZero() && e.LyricsRoma.IsZero() {
		e.LyricsRoma = bt(jyutpingLRC(e.Lyrics.String()))
	}
}

// dropUnusableCantoneseRoma:粤语歌的罗马音只要带声调的粤拼。源自带的罗马音是普通话拼音(looksMandarinPinyin),
// 或者音节几乎都没标声调(lacksJyutpingTones)时清掉,交给粤拼补上。用户手改过的不动(lyricsHandEdited)。必须排在
// maybeGenerateJyutpingRoma / applyPregeneratedRoma 之前 —— 那两处只在罗马音为空时才填。见 10 章决策 36。
func (e *enrichEntry) dropUnusableCantoneseRoma() {
	if e.SongLanguage == songLanguageCantonese && !e.lyricsHandEdited() && !e.LyricsRoma.IsZero() &&
		(looksMandarinPinyin(e.LyricsRoma.String()) || lacksJyutpingTones(e.LyricsRoma.String())) {
		e.LyricsRoma = bodyText{}
	}
}

type enrichEntry struct {
	CoverURL string `json:"cover_url,omitempty"`
	// MotionCoverURL:这张专辑的 Apple Music 动态封面(motion artwork)master m3u8,由
	// motioncover.go 按**已校验的目录专辑 ID**查出来。空 = 没有 / 查不到,桌面端照旧铺静态图。
	// MotionPreviewURL 是同一份资源的静态首帧模板(带 {w}x{h}bb.{f} 占位)。
	//
	// 跟 QQAlbumMid 同一条:**刻意不进** fields() —— 那张 map 是发给 relay/LB 的载荷、有
	// 字节预算,而这两个值只有桌面端(直接读这份缓存文件)会用。
	MotionCoverURL   string `json:"motion_cover_url,omitempty"`
	MotionPreviewURL string `json:"motion_preview_url,omitempty"`
	// MotionCoverChecked:这条记录的动态封面**已经核对过了**(不论结论)。
	//
	// 为什么需要它:`fillMotionCover` 最后一道是**图像校验**(首帧要跟这条记录采用的封面
	// 是同一张,见 motionCoverMatchesCover)。真的比对过且两张图确实不是同一张时
	// MotionCoverURL 留空,而 `motionCoverWorthBackfill` 光看"空不空"会一直判它缺 ——
	// 于是每轮 backfill 都重下一次首帧再算一次指纹,白跑 5 轮。有了这一位,每条记录最多
	// 核对一次。 仅在**真的比对成功**(motionCoverMatchesCover 的 verified==true)时才
	// 置位——单纯取图失败(网络/CDN 限流)不算"核对过",见 fillMotionCover 尾部注释。
	//
	// 它跟 motion 缓存里那个 `checked` 是**两件事**:那个按**专辑**记"这张专辑有没有动态
	// 封面",这个按**记录**记"这一条的封面跟那段动画是不是同一张" —— 后者只能逐条判,因为
	// cover_url 是逐条决定的(同一张专辑的不同曲目可能落到单曲封面)。
	MotionCoverChecked bool `json:"motion_cover_checked,omitempty"`
	// MotionCoverFor:动态封面这一组结论(MotionCoverURL / MotionPreviewURL / MotionCoverChecked / MotionCoverIdentityVerified)是对着
	// 哪张封面(CoverURL)核出来的。跟 CoverURL 不一样就是封面后来换过,结论作废(motionVerdictCurrent):App 不用它,引擎按现在
	// 这张重核。见 03 章决策 53。
	MotionCoverFor string `json:"motion_cover_for,omitempty"`
	// MotionCoverIdentityVerified:这条的动态封面是靠**专辑身份核验**放行的 —— 首帧跟封面
	// 对不上,但这条的封面就是 Apple 那张专辑的官方封面(专辑 ID 确定无误),见
	// decideMotionCover。App 侧据此**跳过**中段帧终审:那道终审跟首帧比对是同一个代理判据,
	// 会把刚确认的身份再否掉。
	//
	// 它跟 MotionCoverURL 是一组:所有逐字段挑着拷 motion 字段的地方(backfillPeripheralFields、
	// recheckMotionCoverAgainstCurrentCover、recheck-motion-cover 的写回)都得带上它,漏一处
	// 就是"地址落下了、这一位没落",App 侧照常终审、把 Midnights 那一类又否掉。
	MotionCoverIdentityVerified bool   `json:"motion_cover_identity_verified,omitempty"`
	AccentColor                 string `json:"accent_color,omitempty"`
	NeteaseURL                  string `json:"netease_url,omitempty"`
	AppleURL                    string `json:"apple_music_url,omitempty"`
	QQURL                       string `json:"qq_music_url,omitempty"`
	// NeteaseRejected:重核判错、清掉的那个网易云歌曲 id(neteaselinkcheck.go)。外围补全再配到这一首时链接、封面都不收。
	NeteaseRejected string `json:"netease_rejected,omitempty"`
	// QQ 音乐的 专辑 mid / 首位歌手 mid(歌词窗口「前往专辑/前往艺人」在播放器是 QQ 音乐
	// 时那一档;页面路由见 qqSongCatalogMids)。
	// 刻意**不进** fields() —— 那张 map 是发给 relay/LB 的载荷、有字节预算,而桌面端
	// 直接读这份缓存文件,不需要经它绕一圈。
	QQAlbumMid  string   `json:"qq_album_mid,omitempty"`
	QQSingerMid string   `json:"qq_singer_mid,omitempty"`
	SpotifyURL  string   `json:"spotify_url,omitempty"`
	Lyrics      bodyText `json:"lyrics,omitzero"`
	LyricsTr    bodyText `json:"lyrics_tr,omitzero"` // 中文翻译(逐行 LRC)
	// 罗马音(逐行 LRC)。三条来路,优先级见 maybeGenerateRoma:
	//   ① 源自带(网易云 romalrc / QQ roma / 酷狗 KRC);
	//   ② 粤语粤拼,引擎纯查表自算(maybeGenerateJyutpingRoma);
	//   ③ 日/韩/中,起 lyrics-romanize 子进程算(maybeGenerateHelperRoma)。
	// ②③ 都只在本字段为空时才补,绝不覆盖①。
	LyricsRoma bodyText `json:"lyrics_roma,omitzero"`
	// PlainLyrics 跟 Lyrics **不是同一件事**:这里装的是没有时间戳的纯文本。存在的理由是
	// 给"歌词窗口"一条静态兜底展示:Lyrics 为空、这个字段有内容时,说明"没有能同步显示的
	// 版本,但至少有纯文字可读"。两个字段刻意分开,不能把纯文本塞进 Lyrics 冒充一份(那样
	// LyricsSyncEngine 解析不出任何一行,会让桌面悬浮歌词/灵动岛这些真正依赖时间戳的展示面
	// 误判成"这首歌真的没有歌词")。
	//
	// 写入方有两条,都遵守"只在这个字段当前为空时才写、绝不覆盖已有内容"这条规矩(不区分是
	// 哪条路径写的,统一按"有内容就不动"处理):
	//   1. 用户在"搜索候选歌词"弹窗里明确点选一条 PlainTextOnly 候选("采纳为静态文本"),
	//      由 Swift 侧写入。
	//   2. rescoreLyrics/resolveEnrichAsync 里的自动兜底 —— picked==nil(没有任何分数>=0 的
	//      候选,pickLyricCandidate 对分数<0 一票否决,PlainTextOnly 候选恒为 -1)且 results
	//      里确实有一条 PlainTextOnly 候选时,由引擎自己写入。
	// 引擎侧声明这个字段(以及下面 PlainLyricsSource)纯粹是为了让它在(Go 自己的其它
	// 字段更新触发的)重新落盘时不被悄悄丢掉 —— json.Marshal 只认结构体里声明过的字段,
	// 不声明就等于每次 Go 重新序列化都会把 Swift 刚写进去的这份纯文本冲掉。
	PlainLyrics bodyText `json:"plain_lyrics,omitzero"`
	// PlainLyricsSource:PlainLyrics 来自哪个源(lrclib 与 musixmatch 会给,见
	// lrclibResult.plainOnly 头注)。写入方是 Swift 侧的 EnrichCacheStore.savePlainTextEdit,
	// 这里声明只为直通保留,理由同上。
	PlainLyricsSource string `json:"plain_lyrics_source,omitempty"`
	// BodyCRC:只出现在给 App 的精简索引里(五个正文字段的校验值,见 enrichindex.go);主缓存里恒为 0、
	// 因 omitempty 不落盘。
	BodyCRC uint32 `json:"body_crc,omitempty"`
	// BodyFields:同上,只在索引里 —— 去掉的四块正文各有没有(见 enrichBodyFields)。「歌词管理」拿索引当
	// 精简快照,列表上「逐字 / 译文 / 罗马音 / 纯文本」四个标记靠它,不必去读几千个正文小文件。
	BodyFields uint8    `json:"body_fields,omitempty"`
	LyricsYRC  bodyText `json:"lyrics_yrc,omitzero"` // 逐字(词级，网易云 yrc 格式)
	// LyricsBG:背景人声轨(YRC 语法,每行行头是所属主句的起止,见 amllResult.bg),只有 amll / applemusic
	// 胜出时才有。它跟 Lyrics / LyricsYRC 是一组:从新的解析结果成套写歌词字段的地方都要带上它,
	// 正文或逐字被替换、它又没有跟着换的地方要清掉,漏一处就是把上一份歌词的和声挂在新歌词下面。
	LyricsBG bodyText `json:"lyrics_bg,omitzero"`
	// LyricsBGChecked:这条的歌词已经按哪一版 TTML 附属内容解析器取过(lyricsBGParserVersion)。0 = 还没有,
	// 胜出源是 amll / applemusic 时播放到会补一次(bgbackfill.go)。
	LyricsBGChecked int `json:"lyrics_bg_checked,omitempty"`
	// LyricsSongwriters:这首歌的词曲作者名单(Apple 的 TTML <songwriters>,没有时用 Deezer 的,见 songwritersFromScored),App 在
	// 完整歌词窗口末尾显示成「创作者：…」。它描述的是这首歌、不是哪一份歌词:取自这一轮全部候选、不跟着胜出源走,
	// 换源、手改正文都不清它;一轮里没有哪个源给出名单时保留原值。
	LyricsSongwriters []string `json:"lyrics_songwriters,omitempty"`
	// LyricsSpeakers:当前正文每一行是谁唱的(Musixmatch 的演唱者标注换算过来,见 lyricspeakers.go),绑着正文指纹,
	// App 核对过才补成对唱标记。正文自带演唱者标记的条目没有它。不在正文小文件里。
	LyricsSpeakers *lyricSpeakers `json:"lyrics_speakers,omitempty"`
	// LyricsSpeakersChecked:这条按哪一版演唱者标注(lyricsSpeakersVersion)问过 Musixmatch。0 = 还没有,符合条件的
	// 条目播放到时补问一次(speakersbackfill.go)。
	LyricsSpeakersChecked int `json:"lyrics_speakers_checked,omitempty"`
	// LyricsKana:正文自己不带 `[kana:]` 时,从别的候选借来的假名标注(一份只含借到的那些行的小 LRC,见 kanadonor.go)。
	// App 和 lyrics-romanize 在正文自己没有标注时用它定汉字读音。不绑正文指纹,只对文字一样的行生效。
	LyricsKana string `json:"lyrics_kana,omitempty"`
	// LyricsKanaChecked:这条按哪一版借假名标注(lyricsKanaVersion)问过带标注的源。0 = 还没有,日文歌播放到时补问一次
	// (kanabackfill.go)。
	LyricsKanaChecked int `json:"lyrics_kana_checked,omitempty"`
	// LyricsKanaRomaFor:kanabackfill.go 按借来的标注核过罗马音时,那一刻标注、正文、罗马音的指纹(kanaRomaFingerprint)。
	// 三样都没变就不再起 helper 核一遍。
	LyricsKanaRomaFor string `json:"lyrics_kana_roma_for,omitempty"`
	// SongLanguage 是这首歌的语种真值(songLanguageMandarin/songLanguageCantonese 之一,
	// 见 lyricCandidate.language),取自**全部**候选里第一个给出这个信号的那个(见
	// songLanguageFromScored),不是只看最终拿到歌词正文的那个候选——目前只有 QQ/酷狗
	// 会给,没有可用信号时留空。目前唯一的消费方是"粤语歌粤拼罗马音生成"
	// (SongLanguage==songLanguageCantonese 且 LyricsRoma 原本为空时,由引擎自算
	// 一份粤拼写回 LyricsRoma)——不是通用语种字段,别拿它当"这首歌是什么语言"的权威来源
	// 用在别处(通用语种判断是 Romanizer.LyricScript 已经在管的事)。
	SongLanguage string `json:"song_language,omitempty"`
	// CanonicalArtist 是网易云/QQ 音乐曲库核实过的官方歌手名(仅单一歌手时才有值)，
	// 用来把同一歌手在历史记录里时而中文时而英文、时而全大写的写法统一成一个版本
	// (如 PRINCE/Prince 统一成 Prince、David Tao/陶喆 统一成 陶喆——中文平台曲库通常
	// 就是这么标的，天然贴合"能识别就用中文名"的诉求，不需要额外维护中英文对照表)。
	// 识别不出时留空，lbMeta 原样使用本地(Apple Music)标签，不瞎猜。
	CanonicalArtist string `json:"canonical_artist,omitempty"`
	// InferredArtist / InferredAlbum:播放器没报歌手时按「歌名 + 时长」认出来的歌手和专辑(inferredidentity.go)。
	// 给 App 显示、找封面、拼链接用;不进 fields(),打卡照旧按播放器报的。
	InferredArtist string `json:"inferred_artist,omitempty"`
	InferredAlbum  string `json:"inferred_album,omitempty"`
	// CoverSource/LyricsSource 记录封面/歌词实际来自哪个平台("netease"/"qq"/"lrclib"/"amll"…),
	// 供网页页脚如实展示(而不是写死"来自网易云"——封面/歌词各自可能来自不同平台,或者
	// 干脆哪个平台都没有)。
	CoverSource  string `json:"cover_source,omitempty"`
	LyricsSource string `json:"lyrics_source,omitempty"`
	// CoverAlbum 是这张封面在**来源平台上所属的专辑名**。存它是为了事后能判断
	// "这张封面对不上正在播的这张专辑" —— 见 preferAppleCoverOverNetease 与
	// coverNeedsAlbumCheck。老条目没有这个字段(读成空 = 不详)。
	//
	// 这是 enrichEntry 里唯一一个"记录另一个实体的名字"的字段,别拿它当展示用:
	// 网页页脚要显示的是 CoverSource(封面来自哪个平台),不是这个。
	CoverAlbum string `json:"cover_album,omitempty"`
	// LyricsScore/LyricsSourcesSeen 记录"这条歌词是在什么情况下选出来的",给
	// needsLyricsRetry 判断值不值得再搜一次用。
	//
	// 为什么需要:全源搜索有 20 秒总上限(lyricSearchDeadline),到点没回来的源这一轮直接
	// 不参与候选;而网易云恰恰是最慢、也最可能带逐字歌词的那个。同一首歌连查两次可能一次
	// 3 秒返回、候选里**根本没有网易云**(lrclib 以 83 分胜出),另一次跑满 20 秒、网易云
	// 回来了 525 分带逐字 —— 选中哪个源有相当大的运气成分,而缓存又是"解析一次永久保留",
	// 那一瞬间的运气会被永久固化。
	LyricsScore       int      `json:"lyrics_score,omitempty"`
	LyricsSourcesSeen []string `json:"lyrics_sources_seen,omitempty"`
	// 这一轮应答过的源(哪怕候选被判负分)。跟上面 SourcesSeen 的区别、以及为什么两个都要存,见 lyricSourcesResponded
	// 的注释和 decision.go:"回了烂候选"和"超时没露面"是两种不同的坏。
	LyricsSourcesResponded []string `json:"lyrics_sources_responded,omitempty"`
	// 这一轮因源级熔断被跳过的源(sourcebreaker.go)。非空且歌词为空时 needsLyricsFirstFill
	// 把补空间隔缩到 10 分钟——那不是"查过了没有",是"没问它"。每次写缓存都整体覆盖(含清空)。
	LyricsSourcesSkipped []string `json:"lyrics_sources_skipped,omitempty"`
	// 这一轮开搜时开着的联网歌词源(lyricSourceRound.enabled)。歌词为空时 needsLyricsFirstFill 拿它跟现在开着的比。
	LyricsSourcesEnabled []string `json:"lyrics_sources_enabled,omitempty"`
	// 最近一轮歌词评估拿去当专辑搜索、打分的 YouTube Music 登记专辑(播放器没报专辑时才有,见 lyricsSearchAlbum)。
	// 跟 YouTubeMusicAlbum 对不上就带着登记专辑重搜一次,见 listedAlbumLyricsWorthRecheck。
	LyricsListedAlbum string `json:"lyrics_listed_album,omitempty"`
	// 交给各歌词源去搜、去挑候选的歌名(lyricSearchTitle),只在跟 key 里的歌名不同时记:播放器报的歌名带编号这类括号,
	// key 剥掉了。后台补搜、重打分、手动重新匹配、手动搜索手上只有 key,读它把编号带回去(见 lyricSearchTitleOrStored)。
	LyricsSearchTitle string `json:"lyrics_search_title,omitempty"`
	// 最近一轮歌词评估按哪个 videoId 问了 Kaset 自家那个源(lyricfind 按 videoId 取那一版,MV 换成配对的音轨版本,见
	// kasetNativeLyricsVideoID)。跟这首现在该问的对不上就带着 videoId 重搜一次,见 kasetLyricsWorthRecheck。
	LyricsNativeVideoID string `json:"lyrics_native_video_id,omitempty"`
	// 最近一次完整评估的决策记录(候选表+得分明细,只存元数据),见 decision.go。
	// 只写不读:解析逻辑不许拿它当输入。
	LyricsDecision *lyricsDecision `json:"lyrics_decision,omitempty"`
	// **当前生效歌词的出处**:最近一次"胜者内容成为(或确认仍是)当前歌词"的那轮评估。
	// 跟上面 LyricsDecision(最近一次评估,可能维持原状、甚至输入本身是脏的)**必须分槽存**,
	// 详情页才能永远解释"现在这份词是谁、凭什么选的" —— 合槽的话,一轮被换曲窗口串扰时长
	// (见 observeWrongDuration)的 upgrade 评估会把 first-resolve 的存档盖掉,「解析决策」
	// 里看到的记录跟生效歌词完全对不上号。
	// 同样只写不读。
	LyricsDecisionApplied *lyricsDecision `json:"lyrics_decision_applied,omitempty"`
	// LyricsDecisionAppliedSame 只在盘上出现:两槽相同时 applied 那一槽不写、写这个标记,解码时还原成跟
	// LyricsDecision 共用一个对象,内存里恒为 false(见 enrichjson.go)。
	LyricsDecisionAppliedSame bool `json:"lyrics_decision_applied_same,omitempty"`
	// 升级重试的节流与上限,见 needsLyricsRetry。
	LyricsRetryTS    int64 `json:"lyrics_retry_ts,omitempty"`
	LyricsRetryCount int   `json:"lyrics_retry_count,omitempty"`
	// "当初一条歌词都没搜到"那条重试路径的节流与计数,见 needsLyricsFirstFill。
	// 跟上面那两个字段刻意分开:那一对记的是"有歌词、想升级到更好的源",这一对记的是
	// "压根没有歌词、还在等第一次填上"。混用一个计数器会让一首歌先耗完补空的次数、
	// 以后真需要升级时无从判断。
	LyricsFillTS    int64 `json:"lyrics_fill_ts,omitempty"`
	LyricsFillCount int   `json:"lyrics_fill_count,omitempty"`
	// 这份歌词是按多少秒的曲目时长校验选出来的(0 = 旧条目/当时不知道时长)。专辑预取(albumprefetch.go)拿的是
	// 网易云版本的时长,跟实际播放的可能不是同一版:按短版时长校验会选到给短版对轴的歌词,唱到一半就放完了。
	// 真播放时长跟这个值对不上 → 按真实时长重选一次。
	ResolvedDurationSecs float64 `json:"resolved_duration_secs,omitempty"`
	// LyricsScoringVersion 记录这条歌词是按哪一版打分规则选出来的(见 lyricsScoringVersion),
	// LyricsRescoreCount/LyricsRescoreTS 是按新规则重选的已尝试次数与上次尝试时间
	// (见 needsLyricsRescore)。没有这些字段的老条目会读成 0,一律落后于当前版本 ——
	// 正是想要的:它们确实是按更老的规则选的。
	LyricsScoringVersion int `json:"lyrics_scoring_version,omitempty"`
	// LyricsScoringRevision 是同一主版本下的开发修订号(见 lyricsScoringRevision),跟 LyricsScoringVersion
	// 一起读写,走 lyricsScoring / stampLyricsScoring。
	LyricsScoringRevision int   `json:"lyrics_scoring_revision,omitempty"`
	LyricsRescoreCount    int   `json:"lyrics_rescore_count,omitempty"`
	LyricsRescoreTS       int64 `json:"lyrics_rescore_ts,omitempty"`
	// LyricsRescoreVersion 记录上面那几次尝试是**针对哪一版**打分规则做的。
	// needsLyricsRescore 的次数上限和 1 小时节流只认"针对当前版本"的尝试;版本一升,旧版本下
	// 用掉的次数就不再算。 别退回"LyricsRescoreCount 从不归零"的终身上限:打分版本连升几次
	// 时每次都消耗一次,播得最多的歌最先被永久冻结,而设置里「跟进算法升级」承诺的是"算法
	// 更新后会重新评估"。老条目没有这个字段读成 0 ≠ 当前版本 = 计数视同清零 —— 正是想要的:
	// 冻结的那批自动解冻,不需要迁移。
	LyricsRescoreVersion int `json:"lyrics_rescore_version,omitempty"`
	// LyricsRescoreRevision:同上,对应的开发修订号,走 lyricsRescoreScoring / stampLyricsRescore。
	LyricsRescoreRevision int `json:"lyrics_rescore_revision,omitempty"`
	// 外围字段补全的已尝试次数,见 needsPeripheralBackfill 的上限说明。
	PeripheralRetryCount int `json:"peripheral_retry_count,omitempty"`
	// 解析这条时用的曲目真实时长(秒)。给"歌词管理"的手动搜索用:打分里时长匹配那一档权重很重,手动搜索浏览的是
	// 任意历史缓存条目、拿不到时长,传 0 的话弹窗里的排名跟当初真正做决定用的那组分数对不上。
	DurationSecs float64 `json:"duration_secs,omitempty"`
	// LyricsTrSource 记录 lyrics_tr 是哪来的:空 = 歌词源自带的社区翻译(网易云/Musixmatch),
	// "machine" = translate.go 机翻补的,"borrowed:<源>" = 从那个源的候选借来的社区翻译(borrowtranslation.go)。UI 据此如实标注,不让机翻冒充社区翻译 —— 跟页脚
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
	// LyricsSourceChoice:用户在「联网搜索候选歌词」里选定的源。只约束选哪个源,不是手改内容(手改内容是 ManualLyrics,
	// 一票否决所有自动路径)。非空时自愈路径照常跑,但重选被约束在这个源内(pickLyricCandidatePreferring):同一个源
	// 给出了更好的内容仍然能升上来,换成另一个源不会发生;那个源这一轮没给出候选时就不换。
	//
	// 当前没有任何写入方:App 侧两个「采纳候选」入口恒传空串,migrateManualPickMarks(manualpickmigrate.go)每次启动
	// 都会把它清空(转成 manual_pick_sha 留痕)。所以 pickLyricCandidatePreferring 的非空分支、App 侧那两枚「来源已选定」
	// 徽章都不会生效。要删就整套一起删:字段、preferring 函数和它的单测、两枚徽章、migrateManualPickMarks 里读它的那几行。
	LyricsSourceChoice string `json:"lyrics_source_choice,omitempty"`
	// ManualPickSHA 由 App 侧写、引擎只读:跨专辑复用不覆盖有它的条目,lyricsHandEdited 拿它分辨
	// 「原样采纳的候选」与「手改过的正文」。成员必须声明在这里,它才能在缓存往返里活下来。
	//
	// 这不是可选的。loadEnrichCache 把整个文件解进 map[string]enrichEntry,
	// saveEnrichCache 再整个 marshal 回去,而 encoding/json 会**直接丢弃未声明字段** ——
	// App 侧写进缓存的任何字段,只要这里没有对应成员,就会在引擎下一次存盘时被
	// 静默抹掉(而引擎每解析一首歌都可能存盘,窗口就是几分钟)。表现是"开关打开时
	// 什么都没锁上",而缓存文件里那个字段就是不见了、像从没写过;
	// TestEnrichEntryPreservesAppOwnedFields 钉着这条。**App 侧以后新增任何写进这份缓存的
	// 字段,都要在这里补一个成员**,哪怕引擎永远不读。
	//
	// 内容:App 侧「采纳候选」时写下的正文指纹,用来回答"这首歌是用户手动选的、而且当前
	// 这份内容还就是他选的那一份吗"。语义见 Swift 侧 LyrimuseCore/ManualPickLock.swift。
	ManualPickSHA string `json:"manual_pick_sha,omitempty"`
	// Instrumental 标记"查过了,至少一个来源(lrclib 的 instrumental、网易云的
	// pureMusic / 纯音乐占位正文,或汽水客户端本地队列缓存里的 vocal==2 兜底 ——
	// 见 instrumentalFromScored)明确说这首歌是纯音乐"——
	// 跟"Lyrics 为空"要分开看:后者也可能是"所有源都没查到、真的没搜到"这种更含糊的
	// 情况(用户可能想手动重新搜索候选歌词试试),前者是有明确依据的结论,UI 上应该
	// 显示成"纯音乐"而不是笼统的"无歌词"。信号来源见 lrclibResult 定义处的注释。
	// 用户也能手标(歌词管理详情页、搜索候选歌词面板,set_instrumental)。标了就按纯音乐处理:fields() 不交歌词,
	// 自动搜歌词、补附属内容的路径都跳过;条目里留着的歌词不删,撤标就回来。撤标只有两处:用户存进歌词
	// (applySaveEdit / save_plain_text),手动重新匹配换了词(rematchClearsInstrumental)。
	Instrumental bool `json:"instrumental,omitempty"`
	// InstrumentalCleared:用户撤过纯音乐标记(set_instrumental 传 false),等于说了「这首不是纯音乐」。自动加标的
	// 两条路径(没词条目的补搜、重新打分时那份词是别的版本)看到它就不再标(autoMarksInstrumental);用户重新标上时清掉。
	// 不记的话撤完标,下一次补搜或打分版本升级后的重评会照着同一个依据再标回去。
	InstrumentalCleared bool `json:"instrumental_cleared,omitempty"`
	// TS 是**这条记录当初被解析出来的时刻**,不是任何一种节流时间戳。它只被 needsLyricsRetry
	// 当作"歌词重搜"6 小时间隔的起算点。
	//
	// 外围补全的节流必须另用 PeripheralTS,不能共用这一个字段:共用的话,外围补全每跑一次
	// 就把它推到当下(最多 5 次、每次隔 10 分钟),而歌词重搜的起算点正是它 —— 于是补个封面
	// 主色就能把"去别的源再搜一遍歌词"这件事整体往后推近一小时。两者本来毫无关系。
	TS int64 `json:"ts"`
	// PeripheralTS 是外围字段补全**上一次尝试**的时刻,只给 needsPeripheralBackfill 节流用。
	// 老条目没有这个字段(读成 0),此时回退到 TS —— 那正是拆分之前的语义,不会让存量条目
	// 在升级后一股脑全部立刻重试一遍。
	PeripheralTS int64 `json:"peripheral_ts,omitempty"`
	// PeripheralPending:歌词已经落盘、这一轮的外围字段(封面、链接、canonical_artist)还没补完——提前提交上屏的那份,
	// 或者拿到歌词后这一轮被取消。外围补全不等节流(peripheralBackfillThrottleElapsed),补过一次就清掉。见 09 章决策 249。
	PeripheralPending bool `json:"peripheral_pending,omitempty"`
	// CoverUpgradeCheckTS:后台补封面上一次核对这张小设备封面能不能换成同一张图的清晰版的时刻(coversweep.go),
	// 隔 coverUpgradeRecheckInterval 再核。
	CoverUpgradeCheckTS int64 `json:"cover_upgrade_check_ts,omitempty"`
	// CoverUpgradeCheckRules:上一次核对时按的是哪一版找法(coverUpgradeCheckRules)。找法多了来源,按旧版本核过的
	// 不等 30 天,下一遍就重核。
	CoverUpgradeCheckRules int `json:"cover_upgrade_check_rules,omitempty"`
	// CoverMissingRetryRules:后台补封面上一次按哪一版补法补过这条缺封面的(coverMissingRetryRules)。补法多了一道,
	// 按旧版补过的不管补过几次都再补一次。
	CoverMissingRetryRules int `json:"cover_missing_retry_rules,omitempty"`
	// CoverAppleAlbumCheckTS:后台补封面上一次为这条另一张专辑的封面按显示的专辑问到 Apple 目录的时刻(coversweep.go),
	// 隔 coverAppleAlbumRecheckInterval 再问。
	CoverAppleAlbumCheckTS int64 `json:"cover_apple_album_check_ts,omitempty"`
	// CoverSettleCheckTS / CoverSettleCheckFor:后台补封面给这条所在的专辑定封面、比完定不了(各首不是同一张图,Apple 也没给出
	// 其中一张)的时刻,和当时这条的封面地址(coversweep.go coverSettleCheckedRecently)。组里各条的封面都没变、隔
	// coverSettleRecheckInterval 之内不再比。
	CoverSettleCheckTS  int64  `json:"cover_settle_check_ts,omitempty"`
	CoverSettleCheckFor string `json:"cover_settle_check_for,omitempty"`
	// VideoFrameURL:播放这首时 App 交来的视频帧(视频缩略图、竖屏截图这类不像封面的图),落成本机文件。不当封面用:
	// 引擎照旧按缺封面去找,「歌词管理」只在 cover_url 为空时拿它当缩略图。见 03 章决策 39。
	VideoFrameURL string `json:"video_frame_url,omitempty"`

	// SpotifyTrackID:Spotify 原生客户端播这首歌时 AppleScript `spotify url` 给的 22 位曲目 ID
	// (见 spotifytrack.go)。有它就能拼出真链接 open.spotify.com/track/<id>:fields() 里的
	// spotify_url 经 spotifyLink() 优先用它,SpotifyURL 那个本地拼的搜索页链接只在没有 ID 时兜底。
	// 录音级身份,同一条目被别的播放器再放时照样可用做链接;但 LB 的 spotify_id / music_service
	// 只在本次播放确实来自 Spotify 时上送(lb.go)。
	// 单独成段放在这里(不挤进上面链接那一组)是为了不动那一组的 gofmt 对齐列。
	SpotifyTrackID string `json:"spotify_track_id,omitempty"`

	// ISRCs:这条录音的 ISRC(一份录音可能被不同发行商各登记一个),App 合并收听写法时按它认同一首,来路和时长闸见
	// recordingisrc.go。ISRCLevels:号 → 来路级别(player / verified / searched,recordISRCs 写),没记的号不知道来路。
	// ISRCLookup:补 ISRC 时补过哪几支,一支一个记号(isrcLookupParts),id 没变就不再补。都不进 fields()。
	ISRCs      []string          `json:"isrcs,omitempty"`
	ISRCLevels map[string]string `json:"isrc_levels,omitempty"`
	ISRCLookup string            `json:"isrc_lookup,omitempty"`

	// KKBOXURL:用 KKBOX 放这首歌时,它缓存里的单曲详情给的歌曲页(`https://www.kkbox.com/<地区>/<语言>/song/<id>`,
	// 见 kkboxlyrics.go kkboxPlayingInfoFor)。App 从里面取曲目 id 拼 `kkbox://song/<id>#view` 在 KKBOX 里打开,网页用原样链接。
	KKBOXURL string `json:"kkbox_url,omitempty"`

	// AmazonURL:用 Amazon Music 放这首歌时,它日志里这首的 ASIN 拼成的公开曲目页
	// (`https://music.amazon.com/tracks/<ASIN>`,见 amazonmusic.go amazonTrackURLFor)。App 和网页都原样用。
	AmazonURL string `json:"amazon_url,omitempty"`

	// YouTubeMusicURL:用 Kaset 放这首歌时,它报的 videoId 拼成的 YouTube Music 歌曲页
	// (`https://music.youtube.com/watch?v=<id>`,见 kasetlink.go youtubeMusicTrackURLFor)。App 和网页都原样用。
	YouTubeMusicURL string `json:"youtube_music_url,omitempty"`

	// PlayerCovers:各播放器自己给这首记下的封面地址(公网 https),键是播放器 bundle id,只从播放器本机的数据里读
	// (见 playercover.go)。跟 CoverURL 分开存:那个常是设备直送、存在本机的文件,离开这台机器打不开,设备封面覆盖它时
	// 不动这里。只有 App 读(给 Discord 这类 App 外面的地方挑封面),不进 fields()。
	PlayerCovers map[string]string `json:"player_covers,omitempty"`

	// PublicCoverURL / PublicCoverFor:设备封面在网上的同一张图。设备封面(CoverSource == "device")存在本机,离开这台机器
	// 打不开;换上它时顶掉的远程候选(网易云 / QQ / Apple 的 https 地址)跟它核对过是同一张图,就把那个地址记在
	// PublicCoverURL,PublicCoverFor 记当时那张设备封面的地址(见 devicePublicCover)。只有 App 读(没配网页中继时给 Discord
	// 状态挑封面),不进 fields()。App 只在 PublicCoverFor 等于现在的 CoverURL 时认:封面换过,旧记录自动作废,改封面的
	// 那十来处不用逐个清它。
	PublicCoverURL string `json:"public_cover_url,omitempty"`
	PublicCoverFor string `json:"public_cover_for,omitempty"`

	// CoverSettled:后台补封面给这张专辑定下的封面(coverSweepSettleAlbumCovers),记的是定下时这条的 CoverURL。只在它等于现在的
	// CoverURL 时算数(coverSettled):设备封面、外围补全、借同专辑封面都不再换掉它;封面被别处换过,旧记录自动作废,下一遍后台
	// 补封面再定。不进 fields()。见 03 章决策 48。
	CoverSettled string `json:"cover_settled,omitempty"`

	// YouTubeMusicAlbum:用 Kaset 放这首歌时,按 YouTube Music 的登记判出来的专辑(见 kasetalbum.go)。给 App 界面、上送,
	// 以及播放器没报专辑时搜歌词用(见 lyricsSearchAlbum;Kaset 报的专辑那一栏放歌单时是歌单名,不用),不进缓存 key。
	YouTubeMusicAlbum string `json:"youtube_music_album,omitempty"`
	// YouTubeMusicMV:用 Kaset 放的这一版是 MV 版本(没有专辑,界面写「MV」),见 kasetalbum.go。
	YouTubeMusicMV bool `json:"youtube_music_mv,omitempty"`
	// YouTubeMusicAlbumLang:上面两个是按哪种界面语言判的(YouTube Music 的 hl)。界面语言换了要重判,补判扫描按它挑
	// (startKasetAlbumSweep)。
	YouTubeMusicAlbumLang string `json:"youtube_music_album_lang,omitempty"`
	// YouTubeMusicAlbumRev:上面三个是按哪一版判法判的(kasetAlbumVerdictRev)。
	YouTubeMusicAlbumRev int `json:"youtube_music_album_rev,omitempty"`
	// YouTubeMusicAlbumID / YouTubeMusicArtistID:跟专辑一起判出来的专辑页 browseId(`MPREb_…`)和歌手频道 id(`UC…`),
	// App 拼成 YouTube Music 的专辑页、歌手页(见 kasetalbum.go applyKasetAlbumVerdict)。不进 fields()。
	YouTubeMusicAlbumID  string `json:"youtube_music_album_id,omitempty"`
	YouTubeMusicArtistID string `json:"youtube_music_artist_id,omitempty"`

	// SodaURL:用汽水音乐放这首歌时,它本机数据里这首的曲目 id 拼成的网页分享页
	// (`https://music.douyin.com/qishui/share/track?track_id=<id>`,见 playercatalog.go)。App 和网页都原样用。
	SodaURL string `json:"soda_url,omitempty"`

	// 各播放器自己给这首记下的专辑 id 和第一位歌手的 id(Amazon Music 的是 ASIN),用它放这首时从它本机的数据里读
	// (见 playercatalog.go)。App 拼成那家的专辑页、歌手页;跟 QQAlbumMid 一样不进 fields()。
	SodaAlbumID      string `json:"soda_album_id,omitempty"`
	SodaArtistID     string `json:"soda_artist_id,omitempty"`
	KKBOXAlbumID     string `json:"kkbox_album_id,omitempty"`
	KKBOXArtistID    string `json:"kkbox_artist_id,omitempty"`
	AmazonAlbumASIN  string `json:"amazon_album_asin,omitempty"`
	AmazonArtistASIN string `json:"amazon_artist_asin,omitempty"`
	SpotifyAlbumID   string `json:"spotify_album_id,omitempty"`
	SpotifyArtistID  string `json:"spotify_artist_id,omitempty"`

	// Song:这条写法所在的歌曲实体的 id。只由实体表全量重建写(writeBackSongEntityIDs),重建分 id 时当种子、比上一份
	// 实体表优先(见 18 章决策 8)。
	Song string `json:"song,omitempty"`
	// SongShare:这条写法在实体里所在共享组的编号(实体表 `share` 的编号,跨重建延续、不一定连续),0 号不写。跟 Song 一起由建表写,
	// App 只在同一个共享组里借检索配的链接(18 章决策 12)。
	SongShare int `json:"song_share,omitempty"`
	// LyricsEntityOrigin:这条的歌词是从同一首歌哪条写法的手改原件同步过来的副本(songentityshare.go);原件、自动选的都是
	// 空串。副本的手改标记跟原件一样,各处的闸照旧拦得住;用户直接改这一条(歌词管理保存、歌词文件夹里改了正文)就成了原件。
	LyricsEntityOrigin string `json:"lyrics_entity_origin,omitempty"`
	// Reported:各播放器最近一次原样报的歌名、歌手、专辑,跟这条的写法键(归一化之后)不一样时才记,键是 bundle id,最多
	// maxNotedPlayers 个(noteReportedNameLocked)。只给歌词管理显示「原始写法」,不参与建表、不随歌词同步复制(18 章决策 50)。
	Reported map[string]reportedName `json:"reported,omitempty"`
	// Players:放过这条写法的播放器(bundle id),按第一次放的先后排,最多 maxNotedPlayers 个(notePlayerLocked)。条目里
	// playerIDFields 那几样 id、PlayerCovers 的键对应的播放器也记在这里(notePlayersFromRecords)。歌词管理「同一首歌的其他写法」
	// 拿它显示每条写法是哪个播放器收录的(18 章决策 38、39、42)。
	Players []string `json:"players,omitempty"`
	// PlayerSongIDs:在 Apple Music、QQ 音乐、网易云、酷狗里放这首时,播放器自己报的这一首的歌曲 id,键是 bundle id(Apple Music 是
	// 目录曲目 id,QQ 是 songmid,网易云是歌曲 id,酷狗是曲库里的 mixId;notePlayerSongLocked 记,换成最近一次的)。歌曲实体当播放器给的 id 用
	// (18 章决策 65)。按歌名检索配的单曲链接(AppleURL、QQURL、NeteaseURL)说明不了是哪一首,别往这里写。
	PlayerSongIDs map[string]string `json:"player_song_ids,omitempty"`
	// PlayerAlbumIDs:PlayerSongIDs 里那一首所在的专辑 id,键同样是 bundle id,跟歌曲 id 成对记(notePlayerSongLocked;QQ 是
	// albumMid,网易云是专辑 id)。歌曲实体拿它认「同一张专辑里的另一首」(18 章决策 67)。检索配的专辑(QQAlbumMid)别往这里写。
	PlayerAlbumIDs map[string]string `json:"player_album_ids,omitempty"`

	// Unknown 装这条记录里当前二进制不认识的键(原样的 JSON 片段),MarshalJSON 时原样写回(enrichjson.go)。
	// 没有它的话,结构体里还没有某几个新字段的老二进制把整份缓存读进来再写回,会在上千条记录上静默抹掉那些字段;
	// 有了它,任何版本的二进制重新落盘都不丢别人写的字段。
	// 只读不写:引擎自己永远不往这里放东西,也不读它做决策。
	Unknown map[string]json.RawMessage `json:"-"`
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
	put("spotify_url", e.spotifyLink())
	put("spotify_track_id", e.SpotifyTrackID)
	put("kkbox_url", e.KKBOXURL)
	put("amazon_url", e.AmazonURL)
	put("youtube_music_url", e.YouTubeMusicURL)
	put("soda_url", e.SodaURL)
	put("youtube_music_album", e.YouTubeMusicAlbum)
	put("isrc", e.confidentISRC())
	// 标了纯音乐就不交歌词,网页和 ListenBrainz 都不显示;歌词还在条目里,撤掉标记就回来。App 读缓存同一口径
	// (EnrichCacheReader.makeLyrics)。
	// 改交一个 instrumental 记号:字段表非空才算解析过(poller 里换曲那条 playing_now 的挂起判据),只存着歌词的条目
	// 标上之后别的字段一个都没有,不交的话换曲那条白等 pnPendingMax。上送和中继只按键名取字段,不会带上它。
	if e.Instrumental {
		m["instrumental"] = "1"
	} else {
		put("lyrics", e.Lyrics.String())
		put("lyrics_tr", e.LyricsTr.String())
		put("lyrics_roma", e.LyricsRoma.String())
		put("lyrics_yrc", e.LyricsYRC.String())
		put("lyrics_source", e.LyricsSource)
	}
	put("canonical_artist", e.CanonicalArtist)
	put("cover_source", e.CoverSource)
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
	// 首次解析(resolveEnrichAsync)专用的取消登记表——见 enrichcancel.go。只有这一条
	// 路径的占位行在 App 侧有"停止搜索"按钮,backfillPeripheralFields/rescoreLyrics 等
	// 另外四条后台自愈路径操作的都是**已存在**的缓存条目,没有对应的占位 UI,不需要
	// 能被手动取消。
	enrichCancelFuncs = map[string]context.CancelFunc{}
	enrichNotify      chan struct{} // 后台解析完成→通知 poll 立刻重推;run() 里初始化
	// 首次解析已提前提交了歌词、外围信息还在补的 key(见 resolveEnrichAsync 的 early)。
	// 这期间缓存里的条目会被最终提交整条覆盖,别的路径不能往它上面写。
	enrichProvisional = map[string]bool{}
)

// enrichLooseMatchLogged:已经记过"loose match 复用"日志的 key(受 enrichMu 保护)。见 lookupEnrich 里那行日志的注释。
var enrichLooseMatchLogged = map[string]bool{}

// canonicalEnrichKey 在已有缓存里找一个宽松等价的 key(大小写 + 空格 + 繁简三档)。调用方必须已经持有 enrichMu。
//
// 同一首歌会被不同来源报成不同写法:本机 Apple Music 给的是专辑元数据的原始写法(PRINCE / "Get on the Boat"),
// Last.fm 桥接给的是 Last.fm 规范化过的写法(Prince / "Get On The Boat");中文侧还会差一个半角空格或繁简:
//
//	陶喆|Susan 说|太平盛世        vs  陶喆|Susan说|太平盛世          (差一个半角空格)
//	方大同|千纸鹤|回到未來        vs  方大同|千紙鶴|回到未來          (繁简)
//	孙燕姿|我怀念的|逆光 / 孙燕姿|我懷念的|逆光 / 孫燕姿|我懷念的|逆光  (歌手名也繁简不一)
//
// key 大小写敏感,不归一就会把同一首歌存成两条:歌词管理里多一行、第二条白跑一轮全源搜索、lyrics/ 里多一份导出文件。
// cleanMediaTag 只统一不可见空白、折叠连续空白,ToLower 不动空白和字形,空格和繁简这两档正好漏在中间。
//
// 线性扫而不是维护一份小写索引:写入点分散在几条补全路径里,索引得每处都记得同步。扫一遍的成本在每条现算一次
// loosenEnrichKey(繁转简)上,那一步按输入记忆化了(见 loosekey.go)。
//
// 再加一层旧规则(legacyOfEnrichKey,见 enrichKey 头注):key 的歌名带说明括号时,旧规则那条没被另一种写法占着
// (enrichLegacyClaimedByOther)就直接用它;宽松比对也按旧规则的样子比 —— 不带括号的 key 认任何去括号后相同的条目,
// 带括号的 key 只认旧规则形态、没被占着的那几条,不认括号里写的不一样的另一条。
func canonicalEnrichKey(key string) (string, bool) {
	legacy := legacyOfEnrichKey(key)
	bracketed := legacy != key
	_, title, _ := splitEnrichKey(key)
	if bracketed {
		if e, ok := enrichCache[legacy]; ok && !enrichLegacyClaimedByOther(e, title) {
			return legacy, true
		}
	}
	loose := loosenEnrichKey(key)
	looseLegacy := loosenEnrichKey(legacy)
	cacheID, size, now := reflect.ValueOf(enrichCache).Pointer(), len(enrichCache), time.Now()
	if alt, ok := canonicalMemoLookup(key, cacheID, size, now); ok {
		if alt == "" {
			return "", false
		}
		if _, still := enrichCache[alt]; still && canonicalEnrichKeyMatches(alt, loose, looseLegacy, bracketed, title) {
			return alt, true
		}
	}
	// 必须挑出**确定的**那一条,不能"遍历时撞见谁就用谁"—— Go 的 map 遍历顺序是随机的,
	// 而缓存里真的存在一个宽松键对应多条的情况(上面孙燕姿那组是三条)。随机命中的后果是
	// 同一首歌这次读到 A 的歌词、下次读到 B 的,时间轴还可能不一样,排查起来像见了鬼。
	// 用 betterEnrichEntry 挑最好的那条 —— 跟迁移合并时的胜者规则同一套,两处结论一致。
	// 只遍历 key:条目约 1.4 KB,按值遍历会把每条都拷一遍,而绝大多数按 key 就筛掉了。
	best := ""
	for existing := range enrichCache {
		if existing == key || !canonicalEnrichKeyMatches(existing, loose, looseLegacy, bracketed, title) {
			continue
		}
		if best == "" || betterEnrichEntry(enrichCache[existing], enrichCache[best], existing, best) {
			best = existing
		}
	}
	canonicalMemoStore(key, best, cacheID, size, now)
	if best == "" {
		return "", false
	}
	return best, true
}

// canonicalEnrichKeyMatches:existing 这条能不能给宽松 key 是 loose、旧规则宽松 key 是 looseLegacy 的那首歌用(见 canonicalEnrichKey)。
// 调用方持有 enrichMu(要读 existing 那条的内容时现取)。
func canonicalEnrichKeyMatches(existing, loose, looseLegacy string, bracketed bool, title string) bool {
	if loosenEnrichKey(existing) == loose {
		return true
	}
	el := legacyOfEnrichKey(existing)
	if loosenEnrichKey(el) != looseLegacy {
		return false
	}
	if !bracketed {
		return true
	}
	return el == existing && !enrichLegacyClaimedByOther(enrichCache[existing], title)
}

// canonicalEnrichKey 整表扫描的结果按 key 记住:精确 key 查不到的那首歌,poller 每拍构建中继 / ListenBrainz 负载
// 都会再问一遍。记下的结果在这几种情况下作废、重扫:缓存整张换过(加载、恢复、单测)、条目数变了(增删条目)、
// 超过 canonicalMemoTTL、记下的那条已经不在或不再匹配。条目内容变了(旧规则那条被另一种写法占了、胜者规则比较的
// 字段变了)不让它作废,最多晚 canonicalMemoTTL 才按新内容重挑。整张替换 enrichCache 的地方都要调 canonicalMemoReset:
// 旧 map 回收后地址可能被新 map 复用,只靠 map 身份认不出来。见 15 章决策 50。
const canonicalMemoMax = 1024

// canonicalMemoTTL 是变量只为单测:TestMain 设成 0(各用例直接换 enrichCache,不经 canonicalMemoReset)。
var canonicalMemoTTL = 30 * time.Second

type canonicalMemoEntry struct {
	alt     string
	cacheID uintptr
	size    int
	at      time.Time
}

var (
	canonicalMemoMu sync.Mutex
	canonicalMemo   = map[string]canonicalMemoEntry{}
)

func canonicalMemoLookup(key string, cacheID uintptr, size int, now time.Time) (string, bool) {
	canonicalMemoMu.Lock()
	m, ok := canonicalMemo[key]
	canonicalMemoMu.Unlock()
	if !ok || m.cacheID != cacheID || m.size != size || now.Sub(m.at) >= canonicalMemoTTL {
		return "", false
	}
	return m.alt, true
}

func canonicalMemoReset() {
	canonicalMemoMu.Lock()
	canonicalMemo = map[string]canonicalMemoEntry{}
	canonicalMemoMu.Unlock()
}

func canonicalMemoStore(key, alt string, cacheID uintptr, size int, now time.Time) {
	canonicalMemoMu.Lock()
	if len(canonicalMemo) >= canonicalMemoMax {
		canonicalMemo = map[string]canonicalMemoEntry{}
	}
	canonicalMemo[key] = canonicalMemoEntry{alt: alt, cacheID: cacheID, size: size, at: now}
	canonicalMemoMu.Unlock()
}

// looseInflightKey 在**正在后台解析**的队列里找宽松等价的 key。
//
// 光有 canonicalEnrichKey 挡不住重复。机制是竞态:canonicalEnrichKey 查的是
// enrichCache,而第一条这时还**只在 enrichInflight 里**、解析没回来、一个字都还没写进
// enrichCache。第二条(另一个写入路径报了另一种拼法)来查,缓存里当然找不到等价条目,
// 于是各自起一路解析、各自写入 —— 两条路径先后差十几秒,正好落在这个窗口里
// (`方大同|春風吹之吹吹風mix|愛愛愛` / `方大同|春风吹之吹吹风mix|愛愛愛` 就是这么来的)。
//
// 所以"要不要发起解析"的判断必须**同时**宽松地查缓存和在途队列,少一个就还会漏。
//
// 调用方必须已经持有 enrichMu。
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
// 结果**只用于比对**,绝不写进 enrichCache 当 key、绝不用于显示、绝不用于文件名。
// 这条边界是整个修法的关键:
//   - 归一化写进 **key**,就要求 Swift 侧 EnrichCacheKeys 逐字节复刻同一套规则,否则两边
//     算出的 key 对不上,表现是「悬浮窗整首歌没词」(EnrichCacheReader 是纯精确命中,
//     那边注释自己写过这个后果)。而繁简这一档 Go 走内嵌 OpenCC 词典、Swift 走
//     CFStringTransform(ICU),两者对部分字本来就不一致,根本复刻不了。
//   - 归一化只用于**查询兜底**,两侧不一致的后果就温和得多:某个字兜不到,退化成改动前的
//     行为(多一条重复),而不是查不到歌词。
//
// 所以:key 一个字节不改,宽松只活在比对这一层。
//
// 调用方走 loosenEnrichKey(loosekey.go,记忆化的那一层),不直接调这里。
func loosenEnrichKeyUncached(key string) string {
	// 合 credit 的分隔符也折平:同一次播放里两条路径对多歌手串的写法系统性不同 —— 播放器(media-control)报
	// `VALORANT/Grabbitz/bbno$`,专辑预取从 Apple Music 曲目表(AppleScript `artist of t`)拿到的是
	// `VALORANT & Grabbitz & bbno$`。预取的 canonicalEnrichKey + looseInflightKey 两道宽松查重都建立在这个函数上,
	// 折不平分隔符就一起失效,存成两条只差分隔符的重复条目。
	//
	// 分隔符集合直接复用 isArtistCreditSep(match.go),别在这里再抄一份 —— 那边加了新分隔符,这边要跟着生效。
	// 全部映射成 '&'(挑哪个字符不重要,只要唯一)。
	folded := strings.Map(func(r rune) rune {
		if isArtistCreditSep(r) {
			return '&'
		}
		return r
	}, toSimplified(key))
	return strings.ToLower(strings.ReplaceAll(folded, " ", ""))
}

// trackEnrichment 返回一首歌已解析的字段,第一次见到时解析并永久存下。并发安全(poll 与桥接都会调)。
// durationSecs(曲目真实时长,秒)主要作为解析时的校验输入:同一首歌每次报的时长有几百毫秒抖动也命中同一份记录
// (durationMismatch 的 12% 阈值远大于这点抖动)。命中的既有条目时长跟当前差出这个阈值,说明 key 撞车其实是两首
// 不同录音(enrichKeyVersionWords 清单漏了某个版本词),由 resolveEnrichKeyForDuration 换到一个消歧变体 key,
// 不当同一条复用/覆盖。已经解析过的条目直接返回,不会自动整条重新解析;只有 needsPeripheralBackfill 命中时,会在
// 后台补一次缺失的外围字段(不碰歌词/封面来源等身份字段)。
//
// isNewTrack:poller.go 的 handle() 只在"确认这是一次全新的曲目开始播放"(换曲/单曲循环
// 重新起播)那两处传 true,其余调用方(pnPending 重试、lb.go/relay.go 的缓存读取)传
// false。true 时才去取设备直送封面(fetchNowPlayingArtwork:读 App 写的当前封面文件,见
// deviceartwork.go 头注)——这一步放在**触发它的那次轮询之后紧接着的一个新 goroutine 里**,
// 不是先在 handle() 里同步拿到封面再传进来:读文件、校验、解码、落盘都不该让轮询主循环等着,
// 跟"不阻塞 poll 循环"这条贯穿全仓库的约束一致。异步调用的代价:曲目可能在这几百毫秒内又换了——
// fetchNowPlayingArtwork 自己会核对 bundleID/artist/title 还对不对得上,对不上就当没读到,
// 不会把封面错配到别的曲目上。
func trackEnrichment(artist, title, album, bundleID string, durationSecs float64, isNewTrack, radio bool) map[string]string {
	if title == "" {
		return nil
	}
	// 电台台卡不能拿去搜歌词:开台那几十秒系统把**台名当一首歌**推过来(title=台名、
	// artist 空,如 `|petal radio|`、`|NCT 127|`、`|YEONJUN|`),这类条目无一例外搜不到歌词。
	// 理由跟上面那道广告闸逐字相同:它不是歌,搜不到还会被永久写进磁盘缓存、污染「歌词管理」
	// 列表,而且白跑一轮网络搜索。
	//
	// 判据与两侧对齐的理由都在 radioStationCard 那边(纯函数,单测钉住)。
	if radioStationCard(radio, artist, title) {
		return nil
	}
	// artistlessNotMusic 的播放器(KKBOX、Amazon Music)歌手空的只可能是非歌曲内容(播客单集,见 App 侧 TrustedPlayers.artistlessContent):
	// 同上一个理由,不拿去搜歌词、不写进缓存。
	if artist == "" && playerArtistlessNotMusic[bundleID] {
		return nil
	}
	// Kaset 放的是播客单集(YouTube Music 登记的类型)也不是歌,同上。App 那边认出来就不报它(KasetVideoKind),
	// 这里挡的是它还没认出来、照常报过来的那几拍。
	if bundleID == kasetBundleID && kasetPodcastEpisodeCached(kasetVideoIDFor(bundleID, artist, title)) {
		return nil
	}
	// 广告不能拿去搜歌词:qqMusicURL()/e.SpotifyURL 这两路兜底链接只要 title!="" 就会给出
	// 非空值,导致 resolveEnrichAsync 的"全空不写入"判断永远不成立,广告标题会被当成一首
	// "歌"永久写进磁盘缓存、污染"歌词管理"列表,还白跑一轮网络搜索。判据见 isAdBreak。
	if isAdBreak(bundleID, artist, title, album) {
		return nil
	}
	// 同源加权(250「与当前播放器同源」)的判据 —— 按**这一刻真正在放的那个播放器**设,
	// 不是按设置里勾了哪些(全勾会让三个源同时 +250)。放 Apple Music / Spotify / 认不出来
	// 时是空集,谁都不加。完整理由见 match.go 里 nativeLyricSources 的注释。
	//
	// 放在这里而不是更靠里:专辑预取会为同一张专辑并发跑几十首,它们共享同一个播放器,
	// 值相同、重复设是幂等的;而更靠里的话每条兜底轮都要各自关心一次这件事。
	setNativeLyricSourcesForPlayer(bundleID)
	// 播放器原样报的那一份(下面歌名会归一化),跟写法键不一样时记进条目(noteReportedNameLocked)。
	reported := reportedName{Title: title, Artist: artist, Album: album}
	key := enrichKey(artist, title, album)
	// 按歌名记的提示表(Spotify 曲目 ID、电台曲长、MV 时长)按旧规则的 key 存(见 legacyEnrichKey),下面 key 可能被
	// canonical / 时长变体重定向,提示的查找键单独算。
	hintKey := legacyEnrichKey(artist, title, album)
	// Apple Music 页:有已校验的目录锚点就用它的(见 appleCatalogLinkFor)。锚点按播放器报的原标题核对,先按原标题查,
	// 下面标题归一之后再补查一次。另一把锁(appleCatalogMu),在取 enrichMu 之前取。
	anchorLink := appleCatalogLinkFor(artist, title, album, durationSecs)
	// 归一化后的标题不只用来算 key,后面所有搜索调用(peripheral backfill/首次解析/升级
	// 重试/重打分)也要用它:各源曲库多半不带结尾那种非版本标记的括号,带着它原样去搜常常
	// 整轮落空;「歌词管理」手动搜索弹窗初始填的标题来自拆开缓存 key(已经剥过),两条路径
	// 必须用同一份查询词。例外是明说第几个的编号(searchTitle,见 lyricSearchTitle):经 ctx
	// 交给各歌词源去搜、去挑候选,见 09 章决策 196。
	searchTitle := lyricSearchTitle(title)
	title = normEnrichTitle(title)
	if anchorLink == "" {
		anchorLink = appleCatalogLinkFor(artist, title, album, durationSecs)
	}
	// 封面复查用的专辑名(albumhint.go 的 coverAlbumForTrack):播放器报了就是 album,没报就是 Apple 目录回填的那个。
	// 必须在取 enrichMu 之前算:它内部经 lyricResolvedArtists 取同一把锁,sync.Mutex 不可重入,持锁再加锁会把 poll 循环冻死。
	kasetVideoID := kasetVideoIDFor(bundleID, artist, title)
	coverAlbum := coverAlbumForTrack(withYouTubeMusicVideoID(context.Background(), kasetVideoID), artist, title, album, durationSecs)
	// KKBOX 的缓存里现在有没有这首的词:要扫它的缓存目录,放在锁外(记忆 30 秒,见 kkboxLyricsAvailable)。
	var kkboxInfo kkboxPlayingInfo
	if bundleID == kkboxBundleID {
		kkboxInfo = kkboxPlayingInfoFor(artist, title, durationSecs)
	}
	// Spotify 缓存里现在有没有这首的词:同理放在锁外(记忆 30 秒,见 spotifyLocalLyricsAvailable)。
	spotifyLyricsAvail := bundleID == spotifyBundleID && spotifyLocalLyricsAvailable(artist, title)
	// 播放器自己给这首记下的专辑、歌手 id(汽水还有歌曲页):读它本机的数据,放在锁外(见 playercatalog.go)。
	catalogIDs := playerCatalogIDsFor(bundleID, artist, title, album, durationSecs)
	// Amazon Music 曲目页:它的时钟那一拍记下的 ASIN,另一把锁,同样放在锁外取。
	amazonURL := amazonTrackURLFor(bundleID, artist, title)
	amazonLyricsAvail := amazonLocalLyricsAvailable(bundleID, artist, title, album)
	lxMusicLyricsAvail := lxMusicLyricsAvailable(bundleID, artist, title, durationSecs)
	localFileLyricsAvail := localFileLyricsAvailable(bundleID, artist, title)
	youtubeMusicURL := youtubeMusicWatchURL(kasetVideoID)
	// 播放器自己给这首记下的封面地址:读它本机的数据,同样放在锁外(见 playercover.go)。
	playerCover := playerCoverURLFor(bundleID, artist, title, album, durationSecs, kkboxInfo)
	ytmVerdict, ytmSettled := kasetAlbumVerdictFor(kasetVideoID, durationSecs, artist, title)
	playingSongID := playingSongIDFor(bundleID, anchorLink, catalogIDs)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		// 精确没命中时,再看看已有条目里有没有"只差大小写/空格/繁简"的同一首歌 —— 有就
		// 复用那个 key,别另存一份。理由见 canonicalEnrichKey。
		if alt, found := canonicalEnrichKey(key); found {
			// 只在第一次撞上这个 key 时记一行:这条路径每次轮询同一首歌都会走到,不去重的话
			// 一首歌放完能把同一句打上千遍。enrichMu 此刻已持有,普通 map 即可。
			if !enrichLooseMatchLogged[key] {
				enrichLooseMatchLogged[key] = true
				log.Printf("enrich: reusing existing entry %q for %q (loose match)", alt, key)
			}
			key, e, ok = alt, enrichCache[alt], true
		}
	}
	// 正在播的这首记在哪条上(poller 换歌时按 playingEnrichKey 记的就是它):兜底找到的那条;下面换到时长变体时跟着挪过去。
	playKey := key
	// 这一拍把「正在播」从基条目挪到了时长变体上:变体已有条目就在锁外补写它的单条快照。
	movedPlaying := false
	correctDuration := false
	// 播放器自己说是同一段录音(sameRecordingAsPlaying),时长对不上不算换了版本:不另开「~durN」,也不按时长重搜歌词。
	sameRecordingStay := false
	if ok && durationSecs > 0 {
		// 命中的条目时长跟这次播放差太多——key 撞车,其实是两首不同录音,见
		// resolveEnrichKeyForDuration 的注释。换成消歧变体 key,不覆盖已有数据。
		if rk, re, rok := resolveEnrichKeyForDuration(enrichCache, key, durationSecs); rk != key {
			// 播放器这一拍报的曲目 id 跟这条记下的一样:同一段录音,对不上的是这一拍的时长(见 sameRecordingAsPlaying)。
			sameRecording := sameRecordingAsPlaying(e, bundleID, playingSongID)
			// 要另开的那一位还空着:时长连续稳定之前先不建,这一拍返回空(见 durationVariantSteadyLocked)。同一段录音不挂起,
			// 先留在这条上。
			steady := rok || durationVariantSteadyLocked(key, durationSecs, time.Now())
			if !steady && !sameRecording {
				enrichMu.Unlock()
				return nil
			}
			switch {
			case !steady:
				sameRecordingStay = true
			case !rok && enrichCreatedThisPlayLocked(key) && enrichInflight[key]:
				// 这次播放刚建的、首次解析还在跑:它后面的提交会把建条目时那个时长写回去,等它跑完下一拍再改。
			case !rok && enrichCreatedThisPlayLocked(key):
				// 这次播放刚建的:是开播那一拍的时长不对,不是另一段录音(见 enrichCreatedThisPlay)。
				log.Printf("enrich: %q duration corrected in place (recorded %.1fs, %.1fs in the same play)",
					key, e.DurationSecs, durationSecs)
				correctDuration = true
			case sameRecording:
				// 时长稳定成另一个值,是这条记下的时长不对:原地改,不另开、也不用已有的「~durN」(那一条是同一段录音按错的
				// 时长分出去的,启动迁移会把它并回来)。时长必须跟着改:App 按时长挑变体(EnrichCacheKeys.durationVariant),
				// 不改的话它去找一个不会建的「~durN」,整首没词。歌词不重搜(sameRecordingStay),报来的是试听段长度时也不换掉。
				correctDuration, sameRecordingStay = true, true
				if !durationSameRecordingLogged[key] {
					if len(durationSameRecordingLogged) >= durationVariantSeenCap {
						durationSameRecordingLogged = map[string]bool{}
					}
					durationSameRecordingLogged[key] = true
					log.Printf("enrich: %q duration corrected in place (recorded %.1fs, %.1fs; %s reports the same song id)",
						key, e.DurationSecs, durationSecs, bundleID)
				}
			default:
				log.Printf("enrich: %q duration mismatch (cached %.1fs vs actual %.1fs), using variant %q",
					key, e.DurationSecs, durationSecs, rk)
				// 放的是变体那份录音:「正在播」改记在变体上。单条快照、早上屏、机翻、封面补扫都按它认正在播的那首,
				// App 读快照时也认定它已按时长挑过变体;留在基条目上,变体的提交一概不写快照,App 拿基条目那份
				// 录音的歌词一直顶到整份落盘(见 09 章决策 288)。
				if isEnrichPlayingKey(playKey) {
					enrichPlayingKey.Store(&rk)
					movedPlaying = rok
				}
				if isEnrichPlayingKey(rk) {
					playKey = rk
				}
				key, e, ok = rk, re, rok
			}
		} else {
			delete(durationVariantSeen, key)
		}
	}
	if ok {
		// Spotify 曲目 ID 提示:换曲那一拍 poller 从 App 播放状态记下的真 ID,写进条目就落盘。
		// 只在变化时写 —— 同一首歌每几秒进来一次,不能每次都 save;落盘放在锁外(见函数末尾)。
		spotifyHintDirty := applySpotifyTrackIDHintLocked(hintKey, &e)
		// 电台真曲长提示(同一套模式):目录锚点是异步的,条目写下那一拍通常还没有,几秒后
		// 到位了要补进来 —— App 拿它当电台进度条的分母。见 radioduration.go。
		if applyRadioDurationHintLocked(hintKey, &e) {
			spotifyHintDirty = true
		}
		// KKBOX 歌曲页:用 KKBOX 放时从它缓存的单曲详情里取(锁外已经取好),同一套「变了才落盘」。
		if kkboxInfo.url != "" && e.KKBOXURL != kkboxInfo.url {
			e.KKBOXURL = kkboxInfo.url
			spotifyHintDirty = true
		}
		if amazonURL != "" && e.AmazonURL != amazonURL {
			e.AmazonURL = amazonURL
			spotifyHintDirty = true
		}
		if youtubeMusicURL != "" && e.YouTubeMusicURL != youtubeMusicURL {
			e.YouTubeMusicURL = youtubeMusicURL
			spotifyHintDirty = true
		}
		if applyPlayerCoverLocked(&e, bundleID, playerCover) {
			spotifyHintDirty = true
		}
		if notePlayersFromRecords(&e) {
			spotifyHintDirty = true
		}
		if notePlayerLocked(&e, bundleID) {
			spotifyHintDirty = true
		}
		if noteReportedNameLocked(&e, key, bundleID, reported) {
			spotifyHintDirty = true
		}
		// 条目先建好、后来才真正放到(专辑预取,第一次解析时播放器还没报时长):补上播放器报的时长。已经有的不动,
		// 对不上的走上面的消歧变体。
		if e.DurationSecs <= 0 && durationSecs > 0 {
			e.DurationSecs = durationSecs
			spotifyHintDirty = true
		}
		// 解析时用的时长(ResolvedDurationSecs)不动:跟这一拍对不上,下面 wrongDuration 按改好的时长重搜歌词(播放器报同一个曲目 id 时
		// 不重搜,见 sameRecordingStay)。按原来那个时长核过的号对不上改好的时长,降级(demoteISRCsAcrossDuration;播放器报的不降,
		// 两种原地改都还是同一首),重搜按新时长核过的号再升回来。见 18 章决策 77。
		if correctDuration {
			demoteISRCsAcrossDuration(&e, e.DurationSecs, durationSecs)
			e.DurationSecs = durationSecs
			spotifyHintDirty = true
		}
		// 歌词是在不知道曲长时选的、行级时间轴当时没能按逐字轴重挂:这一拍有了曲长,补做(见 rehangOnReportedDurationLocked)。
		timelineRehung := rehangOnReportedDurationLocked(key, &e, durationSecs)
		if timelineRehung {
			spotifyHintDirty = true
		}
		if ytmSettled && applyKasetAlbumVerdict(&e, ytmVerdict, ytmusicDisplayLanguage()) {
			spotifyHintDirty = true
		}
		// 目录锚点跟电台真曲长一样是异步到位的,条目常常先带着按歌名搜出来的链接写下,锚点到了换成它的页面。
		if applyAppleCatalogLinkLocked(&e, anchorLink) {
			spotifyHintDirty = true
		}
		// Apple Music 在放时,锚点就是它这一拍报的目录曲目 id(播放路径的索引先查),记成它报的这一首(18 章决策 65)。
		if bundleID == appleMusicBundleID && anchorLink != "" &&
			notePlayerSongIDLocked(&e, appleMusicBundleID, appleCatalogIDFromURL(anchorLink)) {
			spotifyHintDirty = true
		}
		if applyPlayerCatalogIDsLocked(&e, bundleID, catalogIDs) {
			spotifyHintDirty = true
		}
		if st := lyricSearchTitleWorthStoring(searchTitle, title); st != "" && e.LyricsSearchTitle != st {
			e.LyricsSearchTitle = st
			spotifyHintDirty = true
		}
		if spotifyHintDirty {
			enrichCache[key] = e
			enrichDirty = true
		}
		// 播放器给的 ISRC 当场补:本机缓存那两支、Apple Music 播放时报的目录锚点(见 playbackISRCJobLocked)。
		// 这条还有后台解析在跑(首次解析先上屏、最终那次提交还没回来)时先不起:那次提交整条覆盖,期间补上的号会被盖掉,
		// 而起过一次的这组 id 要隔 isrcPlaybackRetry 才再试。等解析回来,下一拍再起。
		if !enrichInflight[key] {
			if job, ok := playbackISRCJobLocked(key, e, bundleID, anchorLink, time.Now()); ok {
				go runPlaybackISRCJob(job)
			}
		}
		// 用户校准过这首歌的歌词时间轴吗(自己钉着,或者在读穿同一首歌的一份校准,见 lyricsCalibratedLocked)—— 两条
		// "自动重选歌词源"的路径共用这一次判定(见 lyricspins.go)。放在这里而不是各自函数里面:那两个判定要保持纯函数,
		// 好让单测不碰文件系统就能覆盖"被 pin 住就不重选"。
		pinned := lyricsCalibratedLocked(key)
		// 「时长对不上」的原始观察值先过稳定性去抖再交给重试判定 —— 换曲/预载窗口里的
		// 混合快照(当前标题 + 下一首的时长)是一次性的脏值,直接当真会白烧重试预算、
		// 还把决策记录盖掉,见 observeWrongDuration。每次进来都要喂一口(包括时长又对上
		// 的观察,它负责清零),所以放在分支链外面。
		wrongDuration := observeWrongDuration(key,
			(durationMismatch(e.ResolvedDurationSecs, durationSecs) || lyricsOutrunPlayback(e.Lyrics.String(), e.ResolvedDurationSecs, durationSecs)) &&
				!sameRecordingStay, durationSecs, time.Now().Unix())
		// 正在播的是 MV、而这份歌词当初是按视频时长选的:跟 wrongDuration 同一个理由重来一次(见 musicvideolyrics.go)。
		// 这一拍放的不是 MV(MV 交给歌词解析的时长是 0):之前记下的视频时长提示不再适用,清掉 —— 留着的话放音频版时
		// 仍会越过 observeWrongDuration 的去抖直接判时长不符,MV 跟歌曲只差一两秒时本来选对的词也要白重来一次。
		if durationSecs > 0 {
			delete(musicVideoDurationHints, hintKey)
		} else if musicVideoLyricsStaleLocked(hintKey, e) {
			wrongDuration = true
		}
		// 已经有词、值得再全源搜一轮的几个理由,下面分支链里一个分支起一轮、全部带上(见 lyricsRecheck)。
		recheck := lyricsRecheckForLocked(key, e, lyricsRecheckScene{
			album: album, bundleID: bundleID, kasetVideoID: kasetVideoID, pinned: pinned, wrongDuration: wrongDuration,
			kkboxLyrics: kkboxInfo.lyrics, amazonLyrics: amazonLyricsAvail, spotifyLyrics: spotifyLyricsAvail,
			localFileLyrics: localFileLyricsAvail, lxMusicLyrics: lxMusicLyricsAvail,
		})
		// 一次只跑一路后台任务(都会重新取锁改同一条记录),下次播放时轮到下一个。
		// 设备直送封面排最前面:只在"新曲目开始播放" + 现有封面还不是设备直送 / 播放器自带这两档时才
		// 起——后一条门槛避免同一首歌每次重播都重新取一遍设备封面(coverSource 一旦
		// 变成 "device" 或 "player" 就此定案,不再需要每次播放都重新验证,见 applyDeviceCoverUpgrade
		// 头注)。后台补封面给专辑定下的封面(coverSettled)设备封面不再顶掉,也不起。
		if isNewTrack && e.CoverSource != "device" && e.CoverSource != "player" && !coverSettled(e) && !enrichInflight[key] {
			enrichInflight[key] = true
			go applyDeviceCoverUpgrade(withPlayerCover(context.Background(), playerCover), key, artist, title, album, bundleID)
		} else if isNewTrack && e.CoverSource == "device" && !deviceCoverUpgradeTried[key] && !enrichInflight[key] &&
			deviceCoverSmall(e.CoverURL) {
			// 存量的小设备封面换成同一张图的清晰版(见 upgradeSmallDeviceCover)。每个条目每次启动只试一次:
			// 换不成的条目每次都会走到这一档,不限次数的话后面的外围补全(按远程结果再比一次)永远轮不到。
			deviceCoverUpgradeTried[key] = true
			enrichInflight[key] = true
			go upgradeSmallDeviceCover(withPlayerCover(context.Background(), playerCover), key, e.CoverURL,
				artist, title, album, durationSecs)
		} else if motionVerdictStale(e) && !motionRecheckTried[key] && !enrichInflight[key] {
			// 动态封面结论是对着别的封面核的(封面后来换过):按现在这张重核。每个条目每次启动只试一次,没查成的留给后台补封面那一遍。
			motionRecheckTried[key] = true
			enrichInflight[key] = true
			go recheckPlayingMotionCover(key, title, album)
		} else if (needsPeripheralBackfill(e, artist, album) ||
			(coverNeedsHintCheck(e, album, coverAlbum) && peripheralBackfillWindowOpen(e)) ||
			(inferredIdentityWorthBackfill(e, artist, title, durationSecs) && peripheralBackfillWindowOpen(e)) ||
			(motionCoverWorthBackfill(e, artist, title, album) && peripheralBackfillWindowOpen(e))) && !enrichInflight[key] {
			// 第二个条件:播放器没报专辑、回填出的专辑名跟现有封面完全不沾边 —— 首次解析时没有
			// 专辑名可用、Apple 第一条合集就此冻结,这条给它一次按回填专辑重选的机会(见
			// coverNeedsHintCheck)。
			//
			// 第三个条件:播放器没报歌手、还没认出是谁的(inferredIdentityWorthBackfill),同样挂在这里、共用上限与节流。
			//
			// 第四个条件:动态封面是后加的字段,存量条目一个都没有 —— 跟第二条同构地挂在这里、
			// 共用同一套上限与节流,而**不是**塞进 needsPeripheralBackfill:那个函数被四个测试文件
			// 按三参数签名调着,为一条判据改签名不值得。三态判据见 motionCoverWorthBackfill。
			enrichInflight[key] = true
			go backfillPeripheralFields(withPlayerCover(withLyricSearchTitle(context.Background(), searchTitle), playerCover), key, artist, title, album, durationSecs)
		} else if needsLyricsFirstFill(e) && !enrichInflight[key] {
			// "条目已存在但一条歌词都没有" —— 少了这条,一首歌搜砸一次就永久卡住,见
			// needsLyricsFirstFill 的注释。排在下面两条前面无所谓先后:那两条对空歌词条目都
			// 直接 return false。
			enrichInflight[key] = true
			go retryLyricsUpgrade(withLyricSearchTitle(context.Background(), searchTitle), key, artist, title, album, durationSecs, true)
		} else if needsLyricsRescore(e, pinned, features().LyricsAutoUpgrade) && !enrichInflight[key] {
			enrichInflight[key] = true
			go rescoreLyrics(withLyricSearchTitle(context.Background(), searchTitle), key, artist, title, album, durationSecs)
		} else if recheck.due() && !enrichInflight[key] {
			// 已经有词、值得再全源搜一轮:这一刻成立的理由这一轮全部带上(见 lyricsRecheck)。
			recheck.consumeLocked(key)
			enrichInflight[key] = true
			go retryLyricsUpgradeWith(withLyricSearchTitle(context.Background(), searchTitle), key, artist, title, album, durationSecs, false,
				lyricsRescoreOpts{reasons: recheck.String()})
		} else if needsBackgroundVocalsBackfill(e) && !enrichInflight[key] && bgBackfillOnce(key) {
			// 存量 amll / applemusic 条目补背景人声,只重取那一个源、不动正文(见 bgbackfill.go)。
			enrichInflight[key] = true
			go backfillBackgroundVocals(key, artist, title, album, durationSecs)
		} else if needsLyricSpeakersBackfill(e, artist, title) && !enrichInflight[key] && speakersBackfillOnce(key) {
			// 存量条目补演唱者标注,只问一次 Musixmatch、不动正文(见 speakersbackfill.go)。
			enrichInflight[key] = true
			go backfillLyricSpeakers(key, artist, title, album, durationSecs)
		} else if needsLyricsKanaBackfill(e) && !enrichInflight[key] && kanaBackfillOnce(key) {
			// 日文歌补借假名标注、让生成的罗马音用上它,不动正文(见 kanabackfill.go)。
			enrichInflight[key] = true
			go backfillLyricsKana(key, artist, title, album, durationSecs)
		}
		// 机翻不排上面这条链,跟哪一路都能同时跑,理由见 translatestart.go。
		startTranslationBackfillLocked(key, e)
		enrichMu.Unlock()
		if movedPlaying {
			writePlayingEntry(key)
		}
		if spotifyHintDirty {
			requestEnrichSaveFor(key)
		}
		if timelineRehung {
			log.Printf("lyric timeline: rehung %q on the reported duration %.1fs", key, durationSecs)
			exportLyricsFilesFor(key)
		}
		return e.fields()
	}
	// KKBOX 报的是另一种歌手写法、预取按列表里那种解析过了:整份搬过来,不再解析一遍(见 kkboxalias.go)。
	if sib, found := kkboxAliasSiblingLocked(key, bundleID); found {
		e := kkboxAliasCopyLocked(key, sib)
		enrichMu.Unlock()
		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
		commitEnrichSave(key)
		exportLyricsFilesFor(key)
		return e.fields()
	}
	// 洛雪这一拍还没报时长:首次解析等下一拍(见 lxMusicAwaitsDuration)。
	if lxMusicAwaitsDuration(bundleID, durationSecs) {
		enrichMu.Unlock()
		return nil
	}
	// 从没见过这首歌:首次解析,不阻塞 poll 循环。
	// 去重要连**在途**的一起查(不只是 enrichInflight[key] 这一个精确键)——理由见
	// looseInflightKey,少这一道就会在十几秒的窗口里长出繁简/空格重复。
	if _, busy := looseInflightKey(key); !busy {
		enrichInflight[key] = true
		// 每次首次解析单独开一个可取消的 context,登记进 enrichCancelFuncs——见
		// enrichcancel.go 和 resolveEnrichAsync 的注释。用 context.Background() 起,
		// 不挂在 run() 的进程级 ctx 下面:进程整体退出时这些 goroutine 反正会跟着
		// 主进程一起消失,不需要额外传导那层取消;这里只需要"能单独取消某一个 key"
		// 这一件事。
		// 解析的是正在播的这首时,首轮里歌词可以先上屏(见 earlylyrics.go);判据按 playKey,poller 记在播那首用的就是它。
		cancelCtx, cancel := context.WithCancel(withEarlyLyricsTarget(withYouTubeMusicVideoID(context.Background(), kasetVideoID), playKey))
		cancelCtx = withLyricSearchTitle(cancelCtx, searchTitle)
		cancelCtx = withPlayerCover(cancelCtx, playerCover)
		enrichCancelFuncs[key] = cancel
		go resolveEnrichAsync(cancelCtx, key, artist, title, album, bundleID, durationSecs, isNewTrack)
	}
	enrichMu.Unlock()
	return nil
}

// needsPeripheralBackfill 判断是否要补一次外围字段(主色/Apple/QQ/网易云链接)——这几路
// 各自独立请求,可能因限流/超时单独失败,漏了哪个就该重试哪个,不代表歌词/封面本身有问题。
// 用 TS 节流,避免同一首歌每次 poll(几秒一次)都重新发一遍网络请求。
// peripheralBackfillMaxAttempts 给外围字段补全设的硬上限。
//
// 只有节流、没有次数上限的话:某个字段如果是真的补不上(这首歌在网易云压根没有、
// Apple Music 没收录……),这条记录会每 10 分钟重发一轮网络请求,只要它还在被播放就
// 永远停不下来。5 次 ≈ 给足偶发网络抖动恢复的机会,之后认账。
const peripheralBackfillMaxAttempts = 5

// needsPeripheralBackfill 判断是否要补一次外围字段。artist 用来判断"canonical 为空"到底
// 算不算缺 —— 引擎只在**单一歌手**时才给 canonical_artist,合唱曲目为空是正常的,
// 不该为它反复重试。
//
// **必须在持有 enrichMu 的前提下调用**:它下面那条
// coverCanUpgradeToVerifiedSiblingLocked 要扫 enrichCache 找同专辑邻居,而那个扫描**不自己
// 加锁** —— 唯一的生产调用点 trackEnrichment 本来就整段持着这把锁。在那里面再 Lock 一次
// 会直接死锁(Go 的 sync.Mutex 不可重入),表现是引擎进程还在、日志还在打别的
// goroutine 的行,但轮询、feed 刷新、歌曲解析全部无声停摆。
func needsPeripheralBackfill(e enrichEntry, artist, album string) bool {
	// 节流和次数上限先判:窗口关着时结论必然是 false,下面那几项里有整表扫描(coverCanUpgradeToVerifiedSiblingLocked)
	// 和读本机文件(deviceCoverSmall),而同一首歌每拍都会问到这里。见 15 章决策 50。
	if !peripheralBackfillWindowOpen(e) {
		return false
	}
	// canonical_artist 也要进这个条件:它在 backfillPeripheralFields 里本就有 `== ""` 的
	// 补全分支,但触发条件不看它的话,只要那四个字段都齐了,一条缺 canonical 的记录就再也
	// 没机会补上(同一张专辑里一半曲目报 "Leah Dou"、一半报"窦靖童",后者靠 canonical
	// 归一,缺了就归不成)。
	missingCanonical := e.CanonicalArtist == "" && expectsCanonicalArtist(artist)
	// QQ 的专辑/歌手 mid 是后加的字段,存量条目一个都没有 —— 靠这一条把它们纳进自愈。
	// 只在**已经拿到真·歌曲页链接**时才算缺:搜索兜底链接里没有 songmid、压根查不出 mid,
	// 把它算成缺只会让那批条目白重试 5 次。
	missingQQMids := qqMidFromURL(e.QQURL) != "" && (e.QQAlbumMid == "" || e.QQSingerMid == "")
	// 搜索兜底链接本身也该继续争取升级成真·歌曲页。只判 `QQURL == ""` 的话,兜底 URL 非空
	// 的那批条目**永远不会**再被补一次,「前往专辑/前往艺人」对它们也就永远做不了。
	// 网易云链接只有网易云那一路查询能给(e.NeteaseURL = ne.SongURL),而网易云作为歌词源被
	// 关掉时那一路不发请求(见 fetchScoredLyricCandidatesStreaming 的 skipSource)——把它算缺
	// 只会让每条记录白补 5 轮、每轮把开着的源全部重查一遍。
	// 同理,仿冒号名单上的艺人(isNeteaseImpersonatorRidden)这个链接是
	// withholdImpersonatorRiddenIdentity **故意扣掉**的,补多少轮都不会有。
	missingNeteaseURL := e.NeteaseURL == "" && lyricSourceEnabled("netease") && !isNeteaseImpersonatorRidden(artist)
	// 封面归属可以升级成"借同专辑一张实证图"时也算缺(见 coverCanUpgradeToVerifiedSibling):
	// coverNeedsAlbumCheck 只查网易云那一档,而这里要救的正是它刻意不查的 qq 档。
	// 主色只在配了状态中继时才算缺:它是纯网页字段,没配中继时压根不会去算(见
	// resolveTrackEnrichment 那处),不收窄的话恒判"缺"、每条记录白补满 5 轮、每轮把开着的
	// 歌词源全部重查一遍 —— 跟上面 QQURL 兜底链接、NeteaseURL 仿冒号名单是同一个坑。
	// 用户后来才配中继时,这条判据会自动把存量条目重新算成缺、走既有回填路径补上(自愈);
	// 只有 PeripheralRetryCount 已经打满的条目补不回来,那批网页上无配色。
	missingAccent := e.AccentColor == "" && webRelayConfigured()
	// 设备封面太小(deviceCoverSmall,排在最后:要读本机文件)也算缺:这一轮查到的远程封面跟它是同一张图、更清晰就换上
	// (backfillPeripheralFields 里 deviceCoverUpgradable 那段)。存这张小图的时候手上常常还没有远程封面可比,之后没有
	// 别的时机再比一次。
	return missingAccent || e.AppleURL == "" || e.QQURL == "" || missingNeteaseURL ||
		isQQSearchFallbackURL(e.QQURL) || missingQQMids ||
		missingCanonical || coverNeedsAlbumCheck(e, album) ||
		coverCanUpgradeToVerifiedSiblingLocked(e, artist, album) ||
		(e.CoverSource == "device" && deviceCoverSmall(e.CoverURL))
}

// peripheralBackfillWindowOpen:外围补全的上限(peripheralBackfillMaxAttempts)+ 节流
// (enrichPeripheralRetryInterval),needsPeripheralBackfill 与 coverNeedsHintCheck
// (albumhint.go)两条触发条件共用。
func peripheralBackfillWindowOpen(e enrichEntry) bool {
	return e.PeripheralRetryCount < peripheralBackfillMaxAttempts && peripheralBackfillThrottleElapsed(e)
}

// peripheralBackfillThrottleElapsed:离上一次外围补全过了 enrichPeripheralRetryInterval,不看次数上限。
func peripheralBackfillThrottleElapsed(e enrichEntry) bool {
	if e.PeripheralPending {
		return true
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

// qqFallbackCoverTaken 判断 QQ 兜底拿到的那张封面换不换上:没拿到不换;原来没封面时换;原来有一张时,QQ 那张贴合本地专辑的
// 程度(albumScore,按它在 QQ 上所属的专辑算)不比原来那张差才换 —— 两张都对不上版、或者没有本地专辑可比(两边都是 0 分)时
// 照样换,只是不拿更不对版的顶掉更贴的那张。纯函数。见 03 章决策 47。
func qqFallbackCoverTaken(e enrichEntry, qqCover, qqAlbum, coverAlbum string) bool {
	return qqCover != "" && (e.CoverURL == "" || albumScore(qqAlbum, coverAlbum) >= albumScore(e.CoverAlbum, coverAlbum))
}

// coverNeedsAlbumCheck 判断这条记录的封面值不值得重新解析一次 —— 只针对网易云那档:
//
//   - cover_album 有值、但对不上正在播的这张专辑(< 200,不是严格相等)→ 该重解析;
//   - cover_album 为空(老条目没有这个字段)→ 判不出来,补一次重解析顺便把这个字段写上。
//
// 门槛是 `< 200`,不能放宽回 `== 0`:albumScore 的 100 分档是"宽松包含"(见它自己的
// 注释——"几乎任何同名重发/纪念版都会被判定为'包含'、拿到 100 分"),对"同一个基础专辑名、
// 不同版本封面确实不一样"这类情况不够格 —— 本地专辑《JTW 西游记 (Gold) [Explicit]》vs
// 网易云那张《JTW西游记》,后者是前者的子串、算 100 分"对得上",但两版封面完全不同,QQ 上
// 正确的"Gold"版封面永远没机会被问到。只有 200(逐字相等/仅大小写繁简差异)才真的说明
// 这是同一次发行。
// 代价:繁简/带副标题这类"其实没事、就是打分打了 100"的老条目现在也会被多查最多 5 次
// (仍受 peripheralBackfillMaxAttempts 封顶),但 resolveTrackEnrichment 那边只有 QQ 真给
// 出结果才会换封面,查了没用不会把已经对的封面换错,成本是可接受的。
//
// Apple/QQ 两档不查:Apple 那档的封面本来就是按 albumScore 择优选出来的,QQ 那档
// qqCoverFallback 内部也按 albumScore 避开了精选集。
//
// 一条最多查 5 次(peripheralBackfillMaxAttempts)、每次隔 10 分钟,跟其它几个缺字段
// 共用同一套节流与上限,所以存量条目不会在升级后一股脑全部重跑。
//
// 后台补封面给专辑定下的封面(coverSettled)不查:定的时候已经跟同专辑各首、Apple 目录按图比过。
func coverNeedsAlbumCheck(e enrichEntry, album string) bool {
	if album == "" || e.CoverSource != "netease" || coverSettled(e) {
		return false
	}
	if e.CoverAlbum == "" {
		return true
	}
	return albumScore(e.CoverAlbum, album) < 200
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
	return coverSwapAllowedWith(old, fresh, album, deviceCoverUpgradable)
}

// coverSwapAllowedWith 同 coverSwapAllowed,设备封面那一档的判据由调用方给:deviceCoverUpgradable 要读本地图、
// 取远程候选(最长几秒),持着 enrichMu 的调用方得在锁外先算好,锁里只认算好的结果(见 backfillPeripheralFields)。
func coverSwapAllowedWith(old, fresh enrichEntry, album string, deviceUpgradable func(deviceURL, candidateURL string) bool) bool {
	if fresh.CoverURL == "" {
		return false
	}
	// 后台补封面给这张专辑定下的封面(coverSettled):旧的是就不换;新的是就换,那是照定下的那张取的(见 finishTrackEnrichment)。
	if coverSettled(old) {
		return false
	}
	if coverSettled(fresh) {
		return true
	}
	// device 一旦定案就不再按文字匹配的结果换掉:身份由"设备当时确实在播这首歌"保证(同 applyDeviceCoverUpgrade 头注)。
	// 不能走下面"fresh.CoverSource=='qq' 就无条件接受"那一档:canonical_artist 永远解不出来的歌手(不需要中文别名的那类),
	// needsPeripheralBackfill 会每 10 分钟重新判"缺"、反复触发外围自愈,每次都会把定案的设备封面换成这次又猜错的某个
	// 结果,封面在几次重试之间来回变。
	//
	// fresh 也可能是 device 来源:同专辑邻居那一档可以借走一张 device 封面(见 siblingAlbumCover),下面单独有一档处理。
	//
	// 唯一的例外是低分辨率的设备封面(浏览器 MediaSession 常给 120×120)让位给同一张图的高清远程版:判据是"两张图是不是
	// 同一张",不是"谁更大",完整判据表见 coverquality.go 头注。存量低分辨率设备封面也靠这条在下次被播到时自愈升级。
	if old.CoverSource == "device" {
		return deviceUpgradable(old.CoverURL, fresh.CoverURL)
	}
	// 播放器自带的封面(player)身份由播放器自己的本机数据保证,补全时按文字匹配出来的结果不换掉它;它自己只补空着的、
	// 换掉明确是另一张专辑的(coverSweepFillFromPlayerCovers)、升级小设备封面(上面那档),别的按文字匹配出来的封面不换。
	if old.CoverSource == "player" {
		return false
	}
	if old.CoverURL == "" || old.CoverSource == fresh.CoverSource {
		return true
	}
	if fresh.CoverSource == "player" {
		return false
	}
	// 借来的 device 封面。在这条外围自愈路径上 fresh 只可能**靠借**拿到
	// device 来源(deviceCoverURL 恒传空串,见上面那段),而那一档要求邻居自己的
	// cover_album 已经逐字对上这张专辑 —— 归属是实测证据、不是文字匹配,按全系统的可信度
	// 排序它高于 netease/apple/qq 任何一档,不必再走下面"网易云真的应答过"那条代理证据
	// (那条闸防的是"网易云限流 → 只剩 Apple 那张 → 把对版的网易云图换成 mzstatic",
	// 跟这一档要解决的事无关;old 本身是 device 的情形上面已经先拦掉了)。
	if fresh.CoverSource == "device" {
		return true
	}
	if fresh.CoverSource == "qq" {
		// QQ 那档不走下面"网易云真的应答过 + albumScore > 0"这条正面证据——
		// qqCoverFallback 自己已经在 resolveTrackEnrichment 里按 albumScore 避开了
		// 精选集/合辑才会被选中(见那里的注释),不需要再靠 fresh.NeteaseURL 佐证。
		// 这一档也可能是"网易云/Apple 都给了封面但都对不上本地专辑版本"时的纠正结果
		// (见 resolveTrackEnrichment 里那个 guard):这时网易云多半没给出对版的那张,QQ 那张的 cover_album
		// 又是它在 QQ 上的写法,走下面那条会被拦住,好不容易查到的对版封面永远存不进缓存,每次自愈都白查一次。
		return true
	}
	return fresh.NeteaseURL != "" && album != "" && albumScore(fresh.CoverAlbum, album) > 0
}

// siblingAlbumCover 在同一张专辑(同歌手、逐字同专辑名)已经解析出的曲目里找一张现成的、来源可信的封面,给
// resolveTrackEnrichment 当网易云/Apple/QQ 三源各自的单曲检索都没能给出精确对版封面时的最后一道兜底:实体专辑的
// 曲目共用同一张封面,比再挑一个自己打分也不够精确的候选更可信(QQ 对某首歌唯一收录的那条记录,专辑名文本上对得上,
// 挂的封面却可能是另一款合集版,文字打分核不出图本身对不对)。只在这首歌自己的检索都不够精确时才会被调用(见调用点
// 的 guard);缓存里一首邻居都没有时返回空。见 03 章决策 13。
//
// 能借的邻居分两档,第三个返回值说这张图的归属够不够格声明(调用方据此决定盖不盖 cover_album):
//   - device:那张图是这张专辑的某一首在本机播放时系统给的,归属由"设备当时确实在播这首歌"保证,可以连归属一起借走。
//     要求邻居自己那条记录的 cover_album 已经逐字对上这张专辑,不在这里替它推断。
//   - qq:qqCoverFallback 按 albumScore 把关过才会被选中,图有用但不认领归属,不盖 cover_album(邻居的 cover_album 记的是
//     那张图在 QQ 上属于哪张专辑,明确是另一张专辑的不借)。盖了就把"未认领归属"升级成"逐字对上专辑":App 侧
//     localAlbumVerifiedCovers 会拿它越过 Last.fm 自带图,引擎侧 coverNeedsAlbumCheck 撞上 200 分也从此不再复查,
//     QQ 给的合集图就这样顶掉了对图。
//
// netease / apple 两档不借:它们的 cover_album 是源自己报的专辑名,同名不同版(重发/纪念版换了封面)照样能逐字对上,
// 借过去等于把靠文字对上的答案当成实测证据传染给另一首歌。
func siblingAlbumCover(artist, title, album string) (url, source string, albumVerified bool) {
	if album == "" {
		return "", "", false
	}
	self := enrichKey(artist, title, album)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if u, src := siblingCoverLocked(self, artist, album, true); u != "" {
		return u, src, true
	}
	if u, src := siblingCoverLocked(self, artist, album, false); u != "" {
		return u, src, false
	}
	return "", "", false
}

// siblingCoverLocked 在同一张专辑(同歌手、逐字同专辑名)的邻居里挑一张封面。
// verifiedOnly = true 只认"归属可外借"的那一档(见 coverSourceLendsAlbumIdentity,且要求
// 邻居自己的 cover_album 已经逐字对上),false 只认 qq 档(cover_album 明确是另一张专辑的不认)。**调用方必须持有 enrichMu。**
//
// 按 key **定序**扫,不吃 map 的随机迭代顺序:同一张专辑有两条可借邻居时,不排序的话
// 每次启动可能借到不同的图,表现是"这首歌的封面偶尔自己变了"、且复现不出来。
func siblingCoverLocked(self, artist, album string, verifiedOnly bool) (url, source string) {
	// 专辑名按繁简折叠后比:首次解析传进来的是转成简体的检索用专辑名,缓存 key 里是播放器的原写法。
	// 逐字比的话繁体专辑整张借不到,补全那一路又按原写法判「有邻居可借」,白补满次数。
	simpAlbum := toSimplified(album)
	// 取够格的里 key 最小的那条,结果跟按 key 排序后取第一条一样,不用每次把几千个 key 分配出来再排一遍
	// (缓存命中路径上每次 trackEnrichment 都可能问到这里,而且持着 enrichMu)。
	bestKey := ""
	for key, e := range enrichCache {
		if key == self || (bestKey != "" && key >= bestKey) {
			continue
		}
		if e.CoverURL == "" {
			continue
		}
		if verifiedOnly {
			if !siblingLendsAlbumIdentity(e, album) {
				continue
			}
		} else if e.CoverSource != "qq" || (e.CoverAlbum != "" && !candidateCoverAlbumFits(e.CoverAlbum, album)) {
			continue
		}
		a, _, al := splitEnrichKey(key)
		if (al != album && toSimplified(al) != simpAlbum) || !artistMatches(a, artist) {
			continue
		}
		bestKey, url, source = key, e.CoverURL, e.CoverSource
	}
	return url, source
}

// coverSourceLendsAlbumIdentity 回答"这个来源的封面,归属能不能被同专辑其它曲目借走"。
// 只有 device 一档,理由见 siblingAlbumCover 头注第一档那段。单列一个函数是为了让"哪些
// 来源算实测证据"只有一处定义 —— 以后真有第二个来源够格(比如按专辑 mid 而不是专辑名
// 核实过的),改这里一行,借用和自愈两条路径同时跟上。
func coverSourceLendsAlbumIdentity(source string) bool {
	return source == "device"
}

// siblingLendsAlbumIdentity:这条邻居的封面能不能连归属一起借给专辑 album 的其它曲目 —— 来源够格
// (coverSourceLendsAlbumIdentity)、自己的 cover_album 逐字对上这张专辑。siblingCoverLocked 和后台补封面那一步
// (coverSweepBorrowVerifiedSiblings)共用。
func siblingLendsAlbumIdentity(e enrichEntry, album string) bool {
	return e.CoverURL != "" && coverSourceLendsAlbumIdentity(e.CoverSource) && albumScore(e.CoverAlbum, album) == 200
}

// hasAlbumVerifiedSiblingCoverLocked:这张专辑里有没有一条"归属可外借"的邻居封面。
// 给 coverCanUpgradeToVerifiedSiblingLocked 当自愈触发判据用,纯内存扫描、不发任何请求。
//
// **调用方必须已经持有 enrichMu**(名字里的 Locked 就是这个意思)。唯一的生产调用链是
// `trackEnrichment` → `needsPeripheralBackfill` → 这里,而 trackEnrichment 从进函数就一直
// 持着这把锁(见它里面那句"enrichMu 此刻已持有,普通 map 即可")—— 这里**不能**自己
// `enrichMu.Lock()`,那会当场把引擎的轮询整个焊死(Go 的 sync.Mutex 不可重入):进程还
// 活着、日志还在打别的 goroutine 的行,但 feed 不再刷新、歌曲解析全停。
//
// 不排除"自己"那一条:调用方只在自己的封面**归属没核实**时才问(见那个函数的三道 guard),
// 而这里要的正是"归属已核实的 device 档",两者互斥,自己不可能被误当成邻居。
func hasAlbumVerifiedSiblingCoverLocked(artist, album string) bool {
	if album == "" {
		return false
	}
	u, _ := siblingCoverLocked("", artist, album, true)
	return u != ""
}

// coverCanUpgradeToVerifiedSiblingLocked:这条记录的封面归属没核实过,而同专辑已经有一条
// 归属已核实的邻居可以借 —— 值得重解析一次。
//
// **调用方必须已经持有 enrichMu**,理由见 hasAlbumVerifiedSiblingCoverLocked。
//
// 为什么不直接放进 coverNeedsAlbumCheck:那个函数**只查网易云那一档**是一条有实测理由的
// 收窄(见它的头注),而这里要覆盖的是 qq / apple 这些它刻意不查的档。把两件事分开,
// 网易云那条判据一个字节都不用动(它的整张测试表也就原样成立)。
//
// 判据刻意收得很窄 —— "有邻居可借"才算缺。放宽成"qq 档 + cover_album 为空就重查"的话,
// QQ 正常给对图的那一大类(早先存下的 cover_album 是空的)会每条白重试满 5 次
// (peripheralBackfillMaxAttempts)、永远补不上一个补不了的字段,正是 coverNeedsAlbumCheck
// 当初收窄要避开的成本。device / player 两档自己不用升(身份最硬),直接排除。
func coverCanUpgradeToVerifiedSiblingLocked(e enrichEntry, artist, album string) bool {
	return coverAwaitsVerifiedSibling(e, album) && hasAlbumVerifiedSiblingCoverLocked(artist, album)
}

// coverAwaitsVerifiedSibling:这条的封面归属还没核实 —— 有封面、不是 device / player(身份最硬,自己不用升)、cover_album
// 没逐字对上本地专辑、不是后台补封面给专辑定下的(coverSettled)。同专辑有归属核实过的邻居时值得换成那张;
// coverCanUpgradeToVerifiedSiblingLocked 和后台补封面那一步(coverSweepBorrowVerifiedSiblings)共用。
func coverAwaitsVerifiedSibling(e enrichEntry, album string) bool {
	return e.CoverURL != "" && e.CoverSource != "device" && e.CoverSource != "player" && albumScore(e.CoverAlbum, album) != 200 &&
		!coverSettled(e)
}

// coverSettled:这条的封面是后台补封面给专辑定下的那张,之后没被别处换过(见 enrichEntry.CoverSettled)。
func coverSettled(e enrichEntry) bool {
	return e.CoverURL != "" && e.CoverURL == e.CoverSettled
}

// entryListedAlbum:这条写法所在的专辑,跟 App 歌词管理显示的同一个(LocalPlaybackSource.albumOrListed,两处一起改):写法键里的
// 专辑,键里没有时用 Kaset 按 YouTube Music 登记判出来的(YouTubeMusicAlbum)。按专辑统一封面的几步(按判决补封面、借同专辑
// 核实过的设备封面、给专辑定封面、解析时照定下的取)都按它认专辑,不然 Kaset 放的那几首在歌词管理里跟同专辑排在一起,
// 封面却从没跟它们比过。见 03 章决策 49。只有一处跟 App 不同:占位专辑名(albumIsPlaceholder)这里算没有专辑,占位名下的
// 几首不是一张专辑;歌词管理照旧显示它。
func entryListedAlbum(key string, e enrichEntry) string {
	if _, _, album := splitEnrichKey(key); album != "" {
		return coverAlbumOrNone(album)
	}
	return strings.TrimSpace(e.YouTubeMusicAlbum)
}

// settledAlbumCover:这张专辑(同歌手、专辑名繁简折叠后相同,专辑按 entryListedAlbum 认)后台补封面定下的封面,几条都定过时取
// key 最小的那条;没定过返回 false。首次解析、重新解析照它取(见 finishTrackEnrichment)。
func settledAlbumCover(artist, album string) (enrichEntry, bool) {
	if album == "" {
		return enrichEntry{}, false
	}
	simpAlbum := toSimplified(album)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	bestKey, best := "", enrichEntry{}
	for key, e := range enrichCache {
		if !coverSettled(e) || (bestKey != "" && key >= bestKey) {
			continue
		}
		a, _, _ := splitEnrichKey(key)
		al := entryListedAlbum(key, e)
		if (al != album && toSimplified(al) != simpAlbum) || !artistMatches(a, artist) {
			continue
		}
		bestKey, best = key, e
	}
	return best, bestKey != ""
}

// lyricSourcesWithCandidates 挑出这一轮真的给出了可用候选的源(负分是"纯音乐"/"曲库里有
// 但没歌词"这类搭车标记,不算候选,见 scoredLyricCandidateResult.Instrumental 与
// TrackFoundNoLyrics)。
func lyricSourcesWithCandidates(scored []scoredLyricCandidateResult) []string {
	return distinctLyricSources(scored, true)
}

// lyricSourcesResponded 跟上面的区别是**不看分数**:只要这个源在这一轮里给出过候选就算,
// 哪怕那个候选被判成无效(Score<0)。用来回答"这一轮全部源是不是都回来了",而不是"哪些源
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
	for _, source := range lyricSourceNames {
		if !lyricSourceEnabled(source) {
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
// 判据**不是**"所有启用的源都回来了":全源搜索有 20 秒总上限,**有源超时是常态**,那样这条
// 路对绝大多数条目会静默失效(日志里连着都是 `rescore deferred (source missing)`)。
//
// 真正要防的不是"信息不完整",而是"把手上这份好的换成更差的"。只要**当前这份歌词的来源**
// 这一轮也回来了,它自己就参与了新规则下的重新比较 —— 输了就是真输了,这是有依据的替换,
// 缺不缺别的源不影响这个结论(当初那次解析同样可能是在缺源的情况下做的)。反过来,如果
// 恰恰是它没回来,那就什么都别动。
//
// 兜底:老条目可能压根没记 lyrics_source,或者那个源后来被用户关掉了 —— 这种情况下无从
// 判断"手上这份"参没参与,退回那条更严的"所有启用的源都回来了"。
//
// noCurrentLyrics:调用方明确知道"手上压根没有歌词"时传 true,这道闸直接放行 —— 手上什么都没有时这道闸保护的是
// 虚空,而退回"所有启用的源都回来了"会让一首只要有一个源永远不收录的歌永远判不了。同一个道理见
// lyricsUpgradeBaseline 对空歌词条目那一支:「没有旧分要保护,任何真候选都是改进」。
//
// 做成参数而不是就地推断 `currentSource == ""`:同一个空串在不同调用方那里意思不同。rescoreLyrics 只对有词的
// 条目跑,那里的空串是"有词但没记来源"(歌词管理里手改保存会清掉来源),必须保持严格;devtools 的
// resync-lyrics 按条目里有没有词传。
func rescoreDecidable(scored []scoredLyricCandidateResult, currentSource string, noCurrentLyrics bool) bool {
	if noCurrentLyrics {
		return true
	}
	if currentSource != "" && lyricSourceEnabled(currentSource) {
		return containsString(lyricSourcesResponded(scored), currentSource)
	}
	return allEnabledLyricSourcesResponded(scored)
}

// rescorePlayerLocalUnreachable:当前这份是播放器本地歌词(isPlayerLocalLyricSource),而这首此刻正用别的播放器在放 ——
// 那份本地歌词只在用它自己的播放器放时才读得到,等它应答就一直判不了。这时照常判,当前这份留不留交给 rescoreKeepsLyrics。
// 没在放这首(预取、全量扫库)时不算:还在用那个播放器的人,换了版本的扫库不该把它的本地歌词换掉。见 09 章决策 307。
func rescorePlayerLocalUnreachable(currentSource, key string) bool {
	return isPlayerLocalLyricSource(currentSource) && !isNativeLyricSource(currentSource) && playingPlayer() != "" &&
		isEnrichPlayingKey(key)
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
// 一首歌总共会多跑几轮全源搜索"。缺席的源可能是真的没有这首歌(那样永远补不上),所以必须
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
// 存量失败就又变成永久失败了(修好某个前缀解析 bug 之后,已经在缓存里的那首歌永远不会
// 自己好起来)。
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
// 之外,**一首歌解析失败过一次就永久卡住**:哪怕后来修好了解析 bug、五个源都能搜到,
// 也压根没有任何代码会去重试它。
//
// 三道闸:
//   - 有歌词了就不是这条路径的事(交给 needsLyricsRetry 去谈升级);
//   - 用户手改过的绝不自动重搜(跟其余几条路径同一个理由,见 ManualLyrics 注释);
//   - **明确判定为纯音乐的不重搜** —— 那是有依据的结论(lrclib 的 instrumental 标记),
//     不是"没搜到"这种含糊状态,重搜一万次也不会有歌词。
func needsLyricsFirstFill(e enrichEntry) bool {
	if !e.Lyrics.IsZero() || e.ManualLyrics || e.Instrumental {
		return false
	}
	// 落成"没歌词"的那一轮是按别的时长搜的(开播那一拍播放器报错了时长、同一次播放里才改正):那一轮的结论不作数,
	// 不等退避、这一拍就按现在的时长补一次。只认还没补过空的;补完决策记录记的是现在的时长,不会反复触发。见 09 章决策 236。
	if e.LyricsFillCount == 0 && e.LyricsDecision != nil && durationMismatch(e.LyricsDecision.DurationSecs, e.DurationSecs) {
		return true
	}
	// 设置里新开了歌词源、上一轮搜的时候它还没开:不等退避,按现在开着的源补一次。补完名单跟着更新,不会反复触发;
	// 一个源都没连上的那一轮不更新名单,隔 lyricsFillSkippedReadyRetryInterval 再来,别在断网时每拍重搜。见 09 章决策 311。
	if lyricSourceEnabledSince(e.LyricsSourcesEnabled) &&
		time.Now().Unix()-e.LyricsFillTS >= int64(lyricsFillSkippedReadyRetryInterval/time.Second) {
		return true
	}
	// 从"上次补空尝试"和"当初解析"里取更晚的那个当起算点,理由跟 needsLyricsRetry 同款:
	// 免得刚写进缓存的新条目立刻又被重搜一遍。
	base := e.LyricsFillTS
	if e.TS > base {
		base = e.TS
	}
	interval := lyricsFillBackoff(e.LyricsFillCount)
	// 落成"没歌词"的那一轮有源因熔断被跳过(见 sourcebreaker.go 文件头第二条护栏):这不是
	// 完整结论,该早点重来一次——只对第一次补空生效,之后回到正常退避。
	//
	// 两档:被跳过的那些源**现在还在冷却**就等 10 分钟(熔断最长 5 分钟,10 分钟足够它过期,
	// 这是原有的兜底);都不冷却了就只等 30 秒。后面这一档存在的理由:一次几十秒的 DNS 抽风
	// 就能把 7 个源全部熔断,而 10 分钟的等待比整首歌还长,于是**整首歌**都挂着"暂无歌词",
	// 几分钟后手动搜索却候选满屏。30 秒这一档让重搜落在同一次播放里:trackEnrichment 每次
	// poll 都会重新过一遍这个判定(见它里面那串后台任务分派),所以不需要额外的定时器。
	//
	// 为什么不干脆判"不冷却就立刻重来":那会在冷却刚过、故障其实还没好的窗口里把唯一一次
	// 快速补空烧掉(补完 LyricsFillCount 就是 1,直接掉回 24 小时起步的退避)。30 秒是给
	// "抖动型故障"留的观察期——熔断第一档就是 15 秒,等满 30 秒意味着至少有一档冷却完整
	// 过完、且没有新的失败把它重新点着。
	if len(e.LyricsSourcesSkipped) > 0 && e.LyricsFillCount == 0 {
		interval = lyricsFillSkippedRetryInterval
		if !anyLyricSourceCooling(e.LyricsSourcesSkipped) {
			interval = lyricsFillSkippedReadyRetryInterval
		}
	}
	return time.Now().Unix()-base >= int64(interval/time.Second)
}

// lyricsFillSkippedRetryInterval / lyricsFillSkippedReadyRetryInterval 见
// needsLyricsFirstFill 里的注释。
const (
	lyricsFillSkippedRetryInterval      = 10 * time.Minute
	lyricsFillSkippedReadyRetryInterval = 30 * time.Second
)

// lyricsUpgradeBaseline 给"歌词升级重试"算出该跟谁比大小,以及这一轮到底能不能比。
//
// 跨打分版本**不能**直接比大小:新版本给同一份候选普遍多算几百分(专辑/标题/共识/增值),
// 拿新分去比存量的旧分,"严格更高才替换"这道闸就形同虚设 —— 一份更差的候选只因为按新
// 规则算就轻松超过旧分,把好歌词换掉。版本落后的条目本该由 rescoreLyrics 收编(它是版本
// 感知的、压根不比大小),但 rescore 有 1 小时节流 + 3 次上限,节流窗口里 retry 照样会跑
// 到这儿。
//
// 解法是把基准换成**同尺度**的量:现存这份歌词若还在这一轮候选里,就用它这一轮的分数
// 当基准(like-for-like);它没出现(源这轮没答、或内容变了)就这轮不换,等 rescore 收编。
func lyricsUpgradeBaseline(e enrichEntry, scored []scoredLyricCandidateResult) (baseline int, comparable bool) {
	// 空歌词条目("第一次填上"那条路径,见 needsLyricsFirstFill):没有旧分要保护,任何
	// 真候选都是改进。上面那段"跨打分版本不能比大小"的顾虑在这里不成立 —— 压根没有旧分。
	//
	// 必须有这一支,不能指望下面两条。LyricsScoringVersion 对这类条目通常是 0
	// (从来没写过),于是第一条不成立;而第二条要在候选里找 Source/Lyrics 都等于现存值的
	// 那一份,空歌词条目这两个字段都是空串、永远找不到 —— 结果 comparable=false、
	// upgraded 恒为 false,搜出来的歌词一个字都不会被写回去(白跑一轮网络)。
	if e.Lyrics.IsZero() {
		return 0, true
	}
	if e.lyricsScoring() == currentLyricsScoring {
		return e.LyricsScore, true
	}
	if score, _, ok := currentLyricsRoundScore(e, scored, true); ok {
		return score, true
	}
	return 0, false
}

// lyricsUpgradeMinGain:条目已有歌词时,升级重试的胜者要比基准高出这么多分才换。时长项、行数项每轮会差几分,
// 门槛要高过这类零头、低于最小的一项实质加分(带译文 +50)。见 09 章决策 212。
const lyricsUpgradeMinGain = 30

// lyricsUpgradeApplies 升级重试这一轮的胜者够不够格换掉现存那份(没歌词时分数严格更高就填;有歌词时要高出
// lyricsUpgradeMinGain;换上去屏上看不出差别的不换,见 keepsShownLyricsOver)。锁内正式判一次、锁外按快照预判一次
// (prepareSwapTranslation),两处必须调这一个函数。
func lyricsUpgradeApplies(e enrichEntry, scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult, durationSecs float64) bool {
	baseline, comparable := lyricsUpgradeBaseline(e, scored)
	// 这一轮按「时长未知」打分(MV),现存那份的分数却带着时长那一项:换成它在这一轮里的分再比。
	if durationSecs <= 0 && e.ResolvedDurationSecs > 0 && !e.Lyrics.IsZero() {
		baseline, comparable = lyricsBaselineForUnknownDuration(e, scored)
	}
	// 现存那份的末句比这一轮的曲长还晚(lyricsOutrunPlayback):它不是给这段音频的,存着的分是按另一个时长算的,不当基准。
	if lyricsOutrunPlayback(e.Lyrics.String(), e.ResolvedDurationSecs, durationSecs) {
		baseline, comparable = 0, true
	}
	// 反方向:条目记下的时长已经认了这一轮的曲长,现存那份却是给短得多的另一个版本选的,存着的分带着那个时长的加分,
	// 换成它在这一轮里的分再比(同 MV 那条)。只认「放的比词长」:试听段只会比整首短,不走这条(见 09 章决策 289)。
	if lyricsChosenForShorterCut(e, durationSecs) {
		baseline, comparable = lyricsBaselineForUnknownDuration(e, scored)
	}
	if picked != nil && !e.Lyrics.IsZero() && features().LyricsSourceMode == lyricsModePriority {
		if applies, decided := priorityUpgradeVerdict(e, scored, picked, durationSecs); decided {
			return applies
		}
	}
	if picked == nil || !comparable {
		return false
	}
	if e.Lyrics.IsZero() {
		return picked.Score > baseline
	}
	return picked.Score >= baseline+lyricsUpgradeMinGain && !keepsShownLyricsOver(e, picked)
}

// priorityUpgradeVerdict:「顺序优先」下升级重试换不换按名次定,不比分数(decided 为 false 时照分数门槛判):
//   - 这一轮的冠军排在现存那份的来源前面:换(排前面的源上次没回话、这次回来了);
//   - 排在后面:现存那份的来源这一轮回了话、却没给出能挑的(它给的都带扣分项或不能用),或者现存那份是给另一版选的
//     (lyricsFitAnotherCut),才换;它这一轮没回话就不动 —— 不然排第一的源一次超时,词就被排后面的换走;
//   - 同一个来源、来源关掉了或认不出:不归这里管。
//
// 换上去屏上看不出差别的照样不换(keepsShownLyricsOver)。见 09 章决策 296。
func priorityUpgradeVerdict(e enrichEntry, scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult, durationSecs float64) (applies, decided bool) {
	cur, next := priorityRank(e.LyricsSource), priorityRank(picked.Source)
	if cur < 0 || next < 0 || cur == next {
		return false, false
	}
	if next > cur && !containsString(lyricSourcesResponded(scored), e.LyricsSource) && !lyricsFitAnotherCut(e, durationSecs) {
		return false, true
	}
	return !keepsShownLyricsOver(e, picked), true
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

// lyricsOutrunPlayback:这份歌词按 resolved 秒选的,末句(lastLRCTimestampSecs)比现在真播的 actual 秒还晚
// lyricOvershootToleranceSecs 以上 —— 打分里 durationOvershoot 那条物理矛盾,词是给更长的另一个版本的(开头多一段对白的
// 专辑版配了没有对白的版本)。时长差在 durationMismatch 的 12% 以内时只有这条认得出来。resolved 不比 actual 长出这个余量的
// 不解析歌词就返回 false(每一拍都会问);任一时长未知、没有时间戳时返回 false。纯函数。见 09 章决策 277。
func lyricsOutrunPlayback(lyrics string, resolved, actual float64) bool {
	if lyrics == "" || actual <= 0 || resolved <= actual+lyricOvershootToleranceSecs {
		return false
	}
	last, ok := lastLRCTimestampSecs(lyrics)
	return ok && last > actual+lyricOvershootToleranceSecs
}

// lyricsChosenForShorterCut:现存那份歌词按 ResolvedDurationSecs 选的,这一轮真播的 actual 秒比它长出 durationMismatch 那 12%,
// 而条目记下的 DurationSecs 已经跟 actual 对得上(播放器说是同一段录音、原地改过时长,或者稳定观察过)。没有歌词、
// 任一时长未知都是 false。纯函数。
func lyricsChosenForShorterCut(e enrichEntry, actual float64) bool {
	if e.Lyrics.IsZero() || actual <= e.ResolvedDurationSecs || e.DurationSecs <= 0 {
		return false
	}
	return durationMismatch(e.ResolvedDurationSecs, actual) && !durationMismatch(e.DurationSecs, actual)
}

// lyricsFitAnotherCut:现存那份是给另一个版本选的 —— 末句比这一轮的曲长还晚(lyricsOutrunPlayback),或者是给短得多的
// 那一版选的(lyricsChosenForShorterCut)。重评留下它时不把选词时长改记成这一轮的,两个方向必须一起认,见 09 章决策 295。
func lyricsFitAnotherCut(e enrichEntry, actual float64) bool {
	return lyricsOutrunPlayback(e.Lyrics.String(), e.ResolvedDurationSecs, actual) || lyricsChosenForShorterCut(e, actual)
}

// observeWrongDuration:「时长对不上」这个观察值必须同值稳定满一个窗口才可信。
//
// 换曲/预载窗口里 media-control 会把下一首的时长和当前曲目的标题拼进同一份快照。这样一次性的脏观察值直接喂给
// durationMismatch 就会白烧一轮升级重试(3 次预算之一),重跑时所有候选按错误时长全吃 durationOvershoot -700,
// 还把决策记录盖掉。
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

// 观察断流的陈旧上限。堵的是"跨播放残留":脏快照落在曲目**切出**侧(标题还是当前曲、
// 时长已被预载成下一首)时,切歌后该 key 再收不到清零观察,记录会一直挂着;几天后重放
// 同曲若第一口又是同值脏观察,拿着陈旧 firstSeen 一步就凑满 30 秒窗口。上限必须盖过稳定
// 播放期的正常喂食间隔 —— trackEnrichment 在同曲存活期的调用来自 relay 心跳(≤4 分钟)
// 和 LB 的 playing_now/listen 提交(≤4 分钟),不是每拍 poll 都调,取 60 秒会把合法确认
// 饿死,5 分钟刚好双覆盖。残余风险(有意接受):切出侧恰好被心跳采到脏值(尾窗几秒,
// 概率很低)且几分钟内快速重放同曲、第一口又是同值脏观察 —— 代价有界(白烧一轮重试,
// Applied 槽已保住决策记录)。
const wrongDurationObsMaxGapSecs = 300

type wrongDurationObs struct {
	durationSecs float64
	firstSeen    int64
	lastSeen     int64
}

// wrongDurationSeen 只在 enrichMu 临界区内读写(trackEnrichment 是唯一调用方)。
var wrongDurationSeen = map[string]wrongDurationObs{}

// needsLyricsRetry 判断这条缓存的歌词值不值得再搜一次、试着升级到更好的源。
//
// 只在"这次决定是在信息不全的情况下做出来的"时才重试:有已启用的源在当初那一轮里压根没露面(超时/失败,见
// lyricSearchDeadline 的注释)。所有源都回来了、lrclib 是货真价实赢的,就不折腾。
//
// 三道闸门缺一不可:
//   - 已经有逐字歌词(LyricsYRC)就不再重试:逐字是这套打分里最值钱的东西(scoreLyricCandidate 给它加 400 分),
//     已经拿到就没什么可升级的了,没必要为了几分之差再跑一轮网络搜索。
//   - 重试次数上限:缺席的源可能真的没有这首歌,那样永远补不上,必须有硬上限。
//   - 时间节流:同一首歌被反复播放时不能每次都重搜。
//
// 没有 LyricsSourcesSeen 的老条目会被判成"所有启用的源都缺席",从而获得一次升级机会。
func needsLyricsRetry(e enrichEntry, wrongDuration, pinned, autoUpgrade bool) bool {
	// 标了纯音乐的不自动重搜:用户手标时歌词留着,不挡的话这份留着的词会被换掉(见 enrichEntry.Instrumental)。
	if e.Lyrics.IsZero() || e.Instrumental {
		return false
	}
	// 同 needsLyricsRescore:关掉「自动跟进算法升级」之后,已经有歌词的曲目不再自动重搜升级。
	// 排在 `pinned` 旁边、所有"越过下面那道闸"的判据(nativeMissedOut / wrongDuration)
	// **之前** —— 那两条是刻意越闸的,放它们后面等于这个开关对它们无效。
	if !autoUpgrade {
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
	// 这一条必须排在下面"已经有逐字就不重试"**之前**。否则"缓存里是酷狗那份、而酷狗那份
	// 正好带逐字"这种常见情形会被那道闸原地挡死,同源加权对**所有存量歌词**等于没上线,只有
	// 以后新解析的歌才享受得到。
	//
	// 判据只用缓存里已有的两个字段(LyricsSource + LyricsSourcesSeen),所以**不需要**把
	// 播放器加进缓存 key。加进 key 的话,换一次播放器全部歌词集体失效、每首都要重打四个源;
	// 而真正该重来的只是"当初见过同源候选却没选它"的那一小撮。
	//
	// 下面的手改保护/重试上限/时间节流照常生效 —— 同源候选要是每次都赢不了(比如它质量
	// 实在差,250 分也翻不过来),重试次数上限会兜住,不会没完没了地重搜。
	//
	// kkbox 不走这条:它的词只在用 KKBOX 放过之后才进缓存,出现在候选里时几乎总是已经带着同源加权打过分了,「没选它」
	// 就是结论(它只有逐行,输给逐字源是常态),走这条会让每首用 KKBOX 放的歌都白白全源重搜到次数上限。它什么时候值得
	// 重来一次由 kkboxLyricsWorthRecheck 管。lyricfind 在条目记下按 videoId 问过它(LyricsNativeVideoID)之后同理:那一轮
	// 已经带着同源加权比过,再搜结论不变;什么时候值得再按 videoId 问一次由 kasetLyricsWorthRecheck 管。
	nativeMissedOut := hasNativeLyricSource() && !isNativeLyricSource(e.LyricsSource) &&
		slices.ContainsFunc(e.LyricsSourcesSeen, func(s string) bool {
			return isNativeLyricSource(s) && s != kkboxLocalLyricsSource && s != amazonLocalLyricsSource &&
				s != localFileLyricsSource && s != lxMusicLocalLyricsSource &&
				(s != lyricSourceLyricFind || e.LyricsNativeVideoID == "")
		})
	// 版本时长对不上(预取用了另一个版本的时长做校验)跟"同源落选"一样,本身就是重来
	// 一次的理由,同样要越过下面"已经有逐字就不重试"那道闸。wrongDuration 由调用方
	// (trackEnrichment)算好传进来:durationMismatch 的原始观察值必须先过
	// observeWrongDuration 的稳定性确认 —— 换曲/预载窗口里 media-control 会把下一首的
	// 时长和当前曲目的标题拼进同一份快照,一次性的脏观察值不能直接当真(这个函数保持
	// 纯函数,时间态的去抖状态留在调用方那层,单测才不用碰包级状态)。
	// 「顺序优先」下排在当前来源前面的源上一轮没回话:同样越过这道闸,它回来了就该轮到它(见 lyricsAheadSourceAbsent)。
	if !e.LyricsYRC.IsZero() && !nativeMissedOut && !wrongDuration && !lyricsAheadSourceAbsent(e) {
		return false
	}
	// 用户手改过的绝不自动重搜,理由见 ManualLyrics 字段的注释。这道闸不能省:saveEdit 只写
	// manual_lyrics、不动 lyrics_score,于是一条人工修正过的记录仍挂着当初自动选出来那份的
	// 分数,后台重搜一旦拿到更高分就会把用户手改的内容直接覆盖掉 —— 而这是整个缓存里唯一
	// 不可恢复的东西。
	if e.ManualLyrics {
		return false
	}
	if e.LyricsRetryCount >= lyricsRetryMaxAttempts {
		return false
	}
	// 同源候选当初落选:这本身就是重来一次的理由,不必再要求"有源缺席"。下面那段找的是
	// "有源当初没答上话",跟这里说的"答了但没选它"是两回事 —— 混在一起会让这条路径永远
	// 返回 false。
	//
	// 越过的只是「有源缺席」,节流照样要过:离上一轮重试(不管因为什么起的)不到 lyricsRetryInterval 就不来。
	// 别写成直接返回 true —— 那一轮已经带着同源加权、按这一刻的时长评过,输的照样输、时长照样对不上,条件
	// 原样成立,下一拍又起一轮,一直跑到次数上限。基准只看 LyricsRetryTS、不看 TS:换了播放器、换了版本是
	// 解析之后才有的新情况,条目刚解析过也要马上给这一次。见 09 章决策 182。
	if nativeMissedOut || wrongDuration {
		return time.Now().Unix()-e.LyricsRetryTS >= int64(lyricsRetryInterval/time.Second)
	}
	// 「缺席」= 这个源这一轮压根没露面(超时 / 失败),看应答名单(给出过候选就算,哪怕是负分候选)。
	// 拿「给出了能用候选」的名单判,开着十几个源时几乎每条都算有源缺席。老条目没记应答名单时退回它。
	answered := e.LyricsSourcesResponded
	if len(answered) == 0 {
		answered = e.LyricsSourcesSeen
	}
	missing := false
	for _, source := range lyricSourceNames {
		if !lyricSourceEnabled(source) {
			continue
		}
		found := false
		for _, s := range answered {
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

// lyricsAheadSourceAbsent:「顺序优先」模式下,顺序里排在当前来源前面、开着的源上一轮没回话(应答名单同 needsLyricsRetry)。
// 现存那份带逐字时 needsLyricsRetry 本来不重试,排第一的源一次超时、排后面的填上之后,它就再也轮不到。见 09 章决策 296。
func lyricsAheadSourceAbsent(e enrichEntry) bool {
	if features().LyricsSourceMode != lyricsModePriority || e.LyricsSource == "" {
		return false
	}
	answered := e.LyricsSourcesResponded
	if len(answered) == 0 {
		answered = e.LyricsSourcesSeen
	}
	for _, tier := range priorityTiers() {
		if slices.Contains(tier, e.LyricsSource) {
			return false
		}
		// 播放器本地歌词开搜前就读好了,不算缺席。
		for _, s := range tier {
			if !isPlayerLocalLyricSource(s) && !slices.Contains(answered, s) {
				return true
			}
		}
	}
	return false
}

// retryLyricsUpgrade 后台重跑一轮全源搜索,只有分数**严格更高**才替换歌词。
//
// 跟 backfillPeripheralFields 同一个范式(inflight 去重 + 重新取锁 + 条目可能已被删)。
// 不管有没有升级成功都要记一次重试(次数+时间戳),否则缺席的源如果是真的没有这首歌,
// 这条会每 6 小时被重搜一次、永远停不下来。
//
// firstFill=true 时走的是"这条压根没有歌词、还在等第一次填上"那条路径
// (needsLyricsFirstFill)。刻意复用这同一个函数而不是另写一个:两者要做的事完全一样
// (重跑一轮全源搜索 → 取赢家 → 写回 + 落盘 + 导出 + 通知),只有三处不同 ——
// 记到哪一对节流字段、决策记录里标成什么路径、以及"够不够好才替换"那个基准
// (见 lyricsUpgradeBaseline 里空歌词那一支)。另写一份必然跟这边漂,这个函数尾部那一长串"解锁→落盘→导出→通知"
// 的顺序也有讲究。
//
// ctx 带出站优先级(批量路径传 withBackgroundOutbound),也能取消:补空扫描传的是这一轮的 ctx,
// 用户按「停止」或进程退出时搜到一半就收工,这一轮什么都不写(半截结果不是结论)。
// 播放侧传 context.Background(),不会被取消。
func retryLyricsUpgrade(ctx context.Context, key, artist, title, album string, durationSecs float64, firstFill bool) {
	retryLyricsUpgradeWith(ctx, key, artist, title, album, durationSecs, firstFill, lyricsRescoreOpts{})
}

// retryLyricsUpgradeWith 是带上手动重新匹配那几处差别的 retryLyricsUpgrade,见 lyricsRescoreOpts。
func retryLyricsUpgradeWith(ctx context.Context, key, artist, title, album string, durationSecs float64, firstFill bool, opts lyricsRescoreOpts) {
	// 已经有词在屏上、不急:主用主机答了却没有能用的结果时也问备用主机,见 lyricSearchAsksBackupHosts。
	ctx = withLyricSearchBackupHosts(ctx)
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	sourceChoice := opts.sourceChoice(enrichCache[key].LyricsSourceChoice)
	startLyrics := enrichCache[key].Lyrics
	startSource := enrichCache[key].LyricsSource
	startKana := enrichCache[key].LyricsKana
	listed := enrichCache[key].YouTubeMusicAlbum
	storedSearchTitle := enrichCache[key].LyricsSearchTitle
	stamp := enrichEditStampLocked()
	ctx = withCachedYouTubeMusicVideoIDLocked(ctx, key)
	enrichMu.Unlock()
	ctx = withLearnedAliasSelf(ctx, key)
	// 播放器没报专辑时拿 YouTube Music 登记的专辑去搜、去打分,见 lyricsSearchAlbum。
	searchAlbum, listedAlbum := lyricsSearchAlbum(ctx, album, listed, durationSecs, artist, title)

	// 播放侧的后台重试没有"停止"入口(见 backfillPeripheralFields 同款注释);补空扫描 / 全量扫库
	// 传进来的 ctx 可以取消。
	roundCtx, round := withLyricSourceRound(ctx)
	roundCtx, queries := withLyricQueryLog(roundCtx)
	// 交给各歌词源的歌名带上编号:ctx 上挂着的,或条目里记下的(见 lyricSearchTitleOrStored)。
	roundCtx = withLyricSourceTitle(roundCtx, lyricSearchTitleOrStored(ctx, storedSearchTitle, title), artist, title, searchAlbum)
	// 查询词跟首次解析一样先归一化(见 searchQueryFields);缓存 key、决策记录仍用原样标签。
	qa, qt, qal := searchQueryFields(artist, title, searchAlbum)
	_, scored := scoredLyricCandidatesStreaming(withSearchQueryOriginal(roundCtx, artist, title, searchAlbum), qa, qt, qal, durationSecs, opts.onUpdate())
	if ctx.Err() != nil {
		return
	}
	reached := round.reachedAny()
	// 存着的是这一轮某个候选补词之前的原文:下面的比较都按补好的那份算,见 gainUnmaskedWords。
	startLyrics = unmaskedCounterpart(startSource, startLyrics, scored)
	// 用户选定过源就只在那个源内重选,见 LyricsSourceChoice 字段注释。
	picked := pickLyricCandidatePreferring(scored, sourceChoice)
	seen := lyricSourcesWithCandidates(scored)
	// 罗马音兜底可能要起子进程,在上锁之前算好(见 maybeGenerateRoma);只在这一轮会换正文时才算。
	var preparedRoma string
	if picked != nil && picked.LyricsRoma == "" && !startLyrics.EqualString(picked.Lyrics) {
		preparedRoma = generatedRomaFor(picked.Lyrics, "", entrySongLanguage(picked.Lyrics, scored),
			nextLyricsKana(startKana, picked.Lyrics, picked.LyricsYRC, scored))
	}
	// 换上去会让正在播的这首丢掉能用的译文时,先把新正文翻好,跟正文同一次换上。
	preparedTr := prepareSwapTranslation(ctx, key, artist, title, picked, func(e enrichEntry) bool {
		return (opts.manual || !e.ManualLyrics) && lyricsUpgradeApplies(e, scored, picked, durationSecs)
	})
	// 播放器给的 ISRC 在上锁之前取:取它要拿 enrichMu(经 amazonCachedASIN),别挪进锁里。
	sourceISRC := lyricSourceISRC(ctx, artist, title, album)

	enrichMu.Lock()
	// 解锁之后再落盘 —— App 侧读的是**磁盘上**这份缓存文件(EnrichCacheReader 每次直读
	// 文件),只把 enrichDirty 标成 true 是不够的:补出来的东西只活在引擎内存里,
	// 界面永远看不到(表现是日志里译文一首首翻出来了,而缓存文件停在两小时前)。
	// **四条补全路径都要做这一步**,不只 resolveEnrichAsync / backfillPeripheralFields。
	//
	// 顺序不能反:saveEnrichCache 和 exportLyricsFiles 自己都要拿同一把 enrichMu,
	// 在持锁期间调用会死锁。
	//
	// 导出只在歌词族字段真的变了的时候做,而且只导这一条(exportLyricsFilesFor):这几条
	// 路径就算什么都没补上也会推进重试计数/时间戳(那些只要落盘、不涉及 lyrics/ 文件)。
	lyricsChanged := false
	// leadsGroup:换词之前这条的歌词不是从同组别的写法同步来的(songShareFollower),换了才让共享组跟上。
	leadsGroup := false
	// 条目里有词、这一轮改按纯音乐处理:要马上落盘、通知重推(屏上还显示着那份词),但歌词没换,不导出。
	markedInstrumental := false
	defer func() {
		if lyricsChanged {
			translateAfterLyricsSwapLocked(key)
		}
		enrichMu.Unlock()
		if !lyricsChanged && !markedInstrumental {
			requestEnrichBookkeepingSave(key)
			return
		}
		commitEnrichSave(key)
		if lyricsChanged {
			exportLyricsFilesFor(key)
		}
		// 歌词同步开着时共享组跟上这一份(手动重新匹配那条路自己跟,见 runLyricsRematchOne)。
		if lyricsChanged && leadsGroup && !opts.manual {
			shareFollowAfterSwap(key)
		}
		// 非阻塞通知 poll 立刻重推。跟 saveEnrichCache 一样,**四条补全路径都要做** —— 漏了
		// 的话,同一首歌播到中途才补出来的译文要等下一次换歌才会被推出去(译文其实早就翻好、
		// 也落盘了,只是没人通知)。
		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
	}()
	e, ok := enrichCache[key]
	leadsGroup = ok && !songShareFollower(e)
	if !ok {
		// 重搜这段时间里这条被用户在"歌词管理"里删掉了 —— 不要把它复活回去。
		opts.report(lyricsRematchMissing)
		return
	}
	if (e.ManualLyrics && !opts.manual) || enrichEditedSinceLocked(key, stamp) {
		// 重搜这几秒里用户刚好在"歌词管理"里改了这条(手改、采纳候选、标纯音乐……)—— 进来时的
		// 快照已经过期,以拿锁这一刻的实际状态为准(跟 rescoreLyrics 里同一道判断)。
		opts.report(lyricsRematchEdited)
		return
	}
	before := e
	if gainUnmaskedWords(&e, scored) {
		log.Printf("lyrics: %s  %s masked words filled in from this round", key, e.LyricsSource)
		lyricsChanged = true
	}
	// 一个歌词源都没连上(断网、DNS 抽风、全被熔断)的这一轮不算一次尝试:计数只记时间戳。
	// 算上的话,补空的指数退避、「有源被跳过就快点重来」那一次机会(只认计数 0)、没歌手没专辑
	// 满 3 次就放弃(lyricsNoAnchorGaveUp)都会被一次断网白白用掉。时间戳照记,免得断网期间每拍重搜。
	if firstFill {
		if reached {
			e.LyricsFillCount++
		}
		e.LyricsFillTS = time.Now().Unix()
	} else {
		if reached {
			e.LyricsRetryCount++
		}
		e.LyricsRetryTS = time.Now().Unix()
	}
	if len(seen) > 0 {
		e.LyricsSourcesSeen = seen
	}
	if responded := lyricSourcesResponded(scored); len(responded) > 0 {
		e.LyricsSourcesResponded = responded
	}
	roundSkipped := round.skippedSources()
	e.LyricsSourcesSkipped = lyricSourcesSkippedForRetry(roundSkipped)
	if reached {
		e.LyricsListedAlbum = listedAlbum
		e.LyricsNativeVideoID = kasetNativeLyricsVideoID(ctx, round, scored)
		e.LyricsSourcesEnabled = round.enabledSources()
	}
	if sw := songwritersFromScored(scored); len(sw) > 0 {
		e.LyricsSongwriters = sw
	}
	recordISRCs(&e, recordingISRCsFromScored(sourceISRC, scored, durationSecs, title, album))
	upgraded := lyricsUpgradeApplies(e, scored, picked, durationSecs)
	path := lyricsDecisionPathUpgrade
	if firstFill {
		path = lyricsDecisionPathRefill
	}
	path = opts.decisionPath(path)
	// 无论换没换,这一轮完整评估都值得留证(Applied 区分两种含义,见 decision.go)。
	e.LyricsDecision = buildLyricsDecision(
		path, artist, title, searchAlbum, durationSecs, scored, picked, upgraded, opts.logAttrs()...)
	e.LyricsDecision.SourcesSkipped = roundSkipped
	e.LyricsDecision.statsSkips = round.statsSkips()
	e.LyricsDecision.QueriesTried = queries.queries()
	traceLyricsDecision(key, e.LyricsDecision)
	// 换上了新的、或胜者就是现存这份(分数没严格更高所以没"升级",但等于再次确认了当前
	// 选择):两种都算"当前歌词的出处"(分槽语义见 LyricsDecisionApplied)。注意此刻
	// e.Lyrics/e.LyricsSource 还是旧值,判的是"胜者=现存"。刻意源+正文双比(跟
	// lyricsUpgradeBaseline 同一口径):LRCLIB 镜像别家正文逐字节相同很常见,只比正文
	// 会让出处槽的 Winner 记成另一个源、跟缓存 lyrics_source 对不上号 —— 那正是分槽
	// 要消除的那类困惑。
	if upgraded || (picked != nil && picked.Source == e.LyricsSource && e.Lyrics.EqualString(picked.Lyrics)) {
		e.LyricsDecisionApplied = e.LyricsDecision
	}
	if upgraded {
		log.Printf("lyrics upgrade: %s  %s(%d) -> %s(%d)", key, e.LyricsSource, e.LyricsScore, picked.Source, picked.Score)
		// 换上的正文跟现在这份一字不差、新候选又没带读音:现有那份读音描述的就是这份正文,留着(锁外没为它预算)。
		var keptRoma bodyText
		if picked.LyricsRoma == "" && e.Lyrics.EqualString(picked.Lyrics) {
			keptRoma = e.LyricsRoma
		}
		e.Lyrics = bt(picked.Lyrics)
		e.LyricsSource = picked.Source
		e.LyricsScore = picked.Score
		e.stampLyricsScoring()
		e.ResolvedDurationSecs = durationSecs
		e.LyricsTr, e.LyricsRoma, e.LyricsYRC = bt(picked.LyricsTr), bt(picked.LyricsRoma), bt(picked.LyricsYRC)
		if !keptRoma.IsZero() {
			e.LyricsRoma = keptRoma
		}
		e.LyricsBG, e.LyricsBGChecked = bt(picked.LyricsBG), lyricsBGParserVersion
		e.SongLanguage = entrySongLanguage(picked.Lyrics, scored)
		e.dropHokkienRoma()
		e.dropUnusableCantoneseRoma()
		e.applyPregeneratedRoma(preparedRoma)
		lyricsChanged = true
		// 译文换人了,描述译文的两个字段必须跟着换:语言(否则拿旧语言判新译文),
		// 来源(否则上一轮机翻留下的 "machine" 会让新来的社区译文被标成机翻)。
		e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, lyricsTrSourceFor(picked)
		e.resetTranslationAttempts()
		preparedTr.applyLocked(&e)
		if opts.manual {
			e.ManualLyrics, e.LyricsSourceChoice = false, ""
		}
	} else if durationSecs > 0 && keepsShownLyricsOver(e, picked) {
		// 冠军跟现存这份上屏看不出差别时不换词(见 keepsShownLyricsOver),时长照记成这一轮的。
		log.Printf("lyrics upgrade: %s  keeping %s(%d), %s(%d) shows the same lyrics",
			key, e.LyricsSource, e.LyricsScore, picked.Source, picked.Score)
		e.ResolvedDurationSecs = durationSecs
	}
	// 纯音乐结论也要在这条路径上落地(首次解析那边见 resolveEnrichAsync 里读 c.Instrumental 的分支):否则首轮没有
	// 任何源给出这个信号、重搜时才给出的条目拿不到「纯音乐」标记,一直显示「无歌词」,needsLyricsFirstFill 还要按退避
	// 白搜;标记一旦落地它就直接 return。
	//
	// 只在**没选出歌词**时看:选出了歌词还标纯音乐是自相矛盾(合并轮的
	// hasRealFromMarkerSource 已经挡住同源那种,这里再挡跨源那种)。
	// 条目本来就有歌词(升级重试)时也不看:时长对不上的重试里候选全被判掉、只剩一条纯音乐标记,
	// 会给一首明明有逐行歌词的歌打上「纯音乐」,之后扫库、补空、外围补收都跳过它。
	// 例外是播放器自己给的标记(playerSaysInstrumental):它说的就是正在放的这一条,词留在条目里,撤标就回来。用户选定了来源、
	// 手动重新匹配的不按它改,同重评那条(rescoreTurnsInstrumental 的调用处)。
	turnedInstrumental := false
	if picked == nil && e.autoMarksInstrumental() && (e.Lyrics.IsZero() || (playerSaysInstrumental(scored) && sourceChoice == "" && !opts.manual)) {
		if ok, src := instrumentalFromScored(scored, artist, title, album, durationSecs); ok {
			e.Instrumental = true
			turnedInstrumental = true
			markedInstrumental = !e.Lyrics.IsZero()
			log.Printf("lyrics: %s marked instrumental by %s (no lyrics from any source)", key, src)
		}
	}
	// 纯文本(无时间戳)兜底自动采纳:自动解析流程试遍所有源、真的找不到任何带时间戳版本
	// 时,才把纯文本兜底自动采纳进去(不用等用户去"搜索候选歌词"弹窗里手动点"采纳为静态
	// 文本")。picked==nil 这个条件本身已经是"试遍了这一轮能试的所有源和身份变体(标题反查/
	// 艺人别名等重试轮都在 scoredLyricCandidatesStreaming 内部跑完了)、没有一条分数>=0"——
	// 不需要额外判断"是不是最后一次尝试",因为 needsLyricsFirstFill 本来就会隔一段时间
	// (退避后翻倍)反复调这条路径,每次都是各自完整的一轮,不存在"半途"状态。
	//
	// 只在 e.PlainLyrics 当前为空时才写,绝不覆盖——不区分这份内容当初是这里自动写的
	// 还是用户在弹窗里手动"采纳为静态文本"选的,统一"有内容就不动",避免自动兜底事后
	// 用另一个源的纯文本悄悄顶掉用户已经看过、确认过的那份。跟纯音乐标记那段一样只在
	// **没选出真歌词**时看;两者互斥(instrumentalMarker 和 plainTextOnly 候选不会
	// 同时出现在同一份 scored 里,见 scoreAndSort 里那段互斥的候选构造逻辑),即便日后
	// 某个源两者都给,这里的顺序(先纯音乐、后纯文本)也天然让纯音乐结论优先,不会两条
	// 都命中打架。
	if picked == nil && !e.Instrumental && e.PlainLyrics.IsZero() && e.Lyrics.IsZero() {
		if lyrics, source := plainTextFallbackFromScored(scored); lyrics != "" {
			e.PlainLyrics, e.PlainLyricsSource = bt(lyrics), source
			log.Printf("lyrics: %s auto-adopted plain-text fallback from %s (no timed version from any source)", key, source)
		}
	}
	// 跟首次解析同一条「同一段录音、评分高的兄弟赢」(判据见 crossalbum.go),不挂的话
	// cross-album-reuse 对齐过的组会在这两条路径上各自重选、又长出分歧。刚按纯音乐处理的不换词,同重评那条。
	if !turnedInstrumental && adoptCrossAlbumSiblingLyrics(key, &e) {
		lyricsChanged = true
	}
	// 正文没变、自己没有可用译文:这一轮同一份正文借到了译文就补上(见 applyBorrowedTranslations)。
	if !turnedInstrumental && gainBorrowedTranslation(&e, scored) {
		log.Printf("lyrics: %s  %s gained a translation from %s", key, e.LyricsSource, strings.TrimPrefix(e.LyricsTrSource, lyricsTrSourceBorrowedPrefix))
		lyricsChanged = true
	}
	refreshSpeakers(&e, scored)
	refreshKana(&e, scored)
	if rematchClearsInstrumental(opts.manual, before, e) {
		e.Instrumental = false
	}
	opts.finish(lyricsRematchFacts{before: before, after: e, picked: picked, reached: reached, decidable: true})
	enrichCache[key] = e
	enrichDirty = true
}

// plainTextFallbackFromScored 从打分结果里挑一条可以自动兜底采纳的纯文本(无时间戳)
// 候选——纯函数,拆出来给 rescoreLyrics/resolveEnrichAsync 两个写入点共用+单测。调用方
// 已经确认了 picked==nil(没有分数>=0 的候选)、!e.Instrumental、e.PlainLyrics==""
// 这三个前提,这里只负责"scored 里有没有能用的 PlainTextOnly 候选、选哪一条"——按
// scored 原有顺序(打分环节已按固定源序排过)取第一条。正在放的文件标签里自带的(localfile)排在最前:它就是这个文件的歌词。
// 网易云 / QQ 的纯文本排在别家后面,只在别家都没有纯文本时才用(QQ 的正文常带「歌名 - 歌手」那一行标题),
// 有别家的时候取到的跟它们不交纯文本时一样。
func plainTextFallbackFromScored(scored []scoredLyricCandidateResult) (lyrics, source string) {
	for _, c := range scored {
		if c.PlainTextOnly && c.Lyrics != "" && c.Source == localFileLyricsSource {
			return c.Lyrics, c.Source
		}
	}
	var last scoredLyricCandidateResult
	for _, c := range scored {
		if !c.PlainTextOnly || c.Lyrics == "" {
			continue
		}
		if c.Source == "netease" || c.Source == "qq" {
			if last.Lyrics == "" {
				last = c
			}
			continue
		}
		return c.Lyrics, c.Source
	}
	return last.Lyrics, last.Source
}

// instrumentalFromScored 回答"这一轮有没有依据说这首歌是纯音乐",给 retryLyricsUpgrade
// 和 resolveTrackEnrichment 两个写入点共用(同 plainTextFallbackFromScored 那条的模式:
// 共享挑选逻辑,各自决定何时调用)。调用方已经确认了"没选出歌词"这个前提 —— 选出了
// 歌词还标纯音乐是自相矛盾。
//
// 两级,顺序不能反:
//  1. scored 里搭车带来的联网信号(lrclib / 网易云 / QQ / Musixmatch),这是主力。
//  2. 都没有时,才问汽水客户端的本地队列缓存(sodalocal.go)。
//
// 第 2 级在最后是因为它只覆盖汽水队列缓存里的歌,比四个联网源窄得多。反过来,它命中时
// 那四个源已经全都沉默了 —— 此时标「纯音乐」比继续显示笼统的「无歌词」更接近事实,
// 而且能让 needsLyricsFirstFill 别再每隔 24 小时白搜一轮。
//
// 第二个返回值是来源标签,只用于日志。
func instrumentalFromScored(scored []scoredLyricCandidateResult, artist, title, album string, durationSecs float64) (bool, string) {
	for _, c := range scored {
		if c.Instrumental {
			return true, c.Source
		}
	}
	if sodaLocalInstrumental(artist, title, album, durationSecs) {
		return true, "soda local"
	}
	if localIsInstrumentalVersion(title, album) {
		return true, "instrumental version"
	}
	return false, ""
}

// rescoreTurnsInstrumental 回答「重新打分时这份歌词该不该改成按纯音乐处理」:这一轮有纯音乐标记,而现有这份歌词的
// 来源这一轮给的候选被判了版本不符 —— 这份词是给别的版本做的(见 09 章决策 194)。调用方已经确认这一轮没有能用的
// 候选、用户也没选定过源。用户撤过标记的不标(autoMarksInstrumental)。
func rescoreTurnsInstrumental(e enrichEntry, scored []scoredLyricCandidateResult) bool {
	if e.Lyrics.IsZero() || !e.autoMarksInstrumental() || !scoredHasInstrumentalMarker(scored) {
		return false
	}
	if playerSaysInstrumental(scored) {
		return true
	}
	for _, c := range scored {
		if !c.Instrumental && c.Source == e.LyricsSource && c.hasScoreTerm(scoreTermVersionTags) {
			return true
		}
	}
	return false
}

// autoMarksInstrumental:自动路径还能给这一条标纯音乐 —— 眼下没标着,用户也没撤过(InstrumentalCleared)。
func (e enrichEntry) autoMarksInstrumental() bool {
	return !e.Instrumental && !e.InstrumentalCleared
}

// lyricsRescoreMaxAttempts / lyricsRescoreDeferInterval 给"按新打分规则重选"设的上限和节流。
//
// 正常情况下一次就够:重选成功就盖上当前版本号,这条在下一次版本升级之前不会再进这条路径。
// 会用到后面几次的只有"当前这份歌词的来源这一轮没回来、不敢动"(见 rescoreDecidable)那种情况。
//
// 上限是**每个打分版本** 3 次,不是终身 3 次(见 LyricsRescoreVersion):版本升了计数
// 从零算,不然连升几版之后存量条目会一个个被永久冻结、开关形同虚设。
//
// 节流也不能省:只有次数上限、没有时间间隔的话,同一首歌能在**一秒之内**连着重选两次
// (第一次跑完清掉 inflight 标记,下一次 poll 立刻又符合条件),两次尝试烧在同一个网络
// 时机上,而重试的全部意义正是"换个时机再试一次"。
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
func needsLyricsRescore(e enrichEntry, pinned, autoUpgrade bool) bool {
	if e.Lyrics.IsZero() || e.ManualLyrics || e.Instrumental || pinned {
		return false
	}
	// 用户关掉了「自动跟进算法升级」:已经选定的歌词不再因为打分规则升级被换掉
	// (见 features.go 的 LyricsAutoUpgrade)。 做成**入参**而不是在函数里读包级
	// `features`,是为了让这条闸跟 `pinned` 一样能被单测直接钉住 —— 这两个函数刻意
	// 保持纯函数,时间态/配置态都由调用方喂进来。
	if !autoUpgrade {
		return false
	}
	if !e.lyricsScoring().before(currentLyricsScoring) {
		return false
	}
	// 次数与节流只认针对**当前**版本的那几次尝试(见 LyricsRescoreVersion 字段注释)。旧版本
	// 下的计数不算 —— 那几次得出的结论已被新规则作废,不该拿来限制新规则下的重选;本版一次
	// 都没试过时也不套节流。rescoreLyrics 一跑就会把版本号对齐并从零计数,所以第二次进来
	// 照常受下面两道闸管,不会一秒内连烧两次。
	if e.lyricsRescoreScoring() != currentLyricsScoring {
		return true
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
//
// 返回 true = 这一轮没能给出这一版规则下的最终结论:当前歌词的来源没应答(什么都没改),或有源被跳过
// (照常重选,但不追平打分版本)。全量扫库靠它把这首留到整份候选跑完后再试一次(见
// lyricsFullScanState.Deferred)。条目被删 / 被手改、ctx 被取消都返回 false。
//
// ctx 同 retryLyricsUpgrade。
func rescoreLyrics(ctx context.Context, key, artist, title, album string, durationSecs float64) (deferred bool) {
	return rescoreLyricsWith(ctx, key, artist, title, album, durationSecs, lyricsRescoreOpts{})
}

// rescoreLyricsWith 是带上手动重新匹配那几处差别的 rescoreLyrics,见 lyricsRescoreOpts。
func rescoreLyricsWith(ctx context.Context, key, artist, title, album string, durationSecs float64, opts lyricsRescoreOpts) (deferred bool) {
	// 已经有词在屏上、不急:主用主机答了却没有能用的结果时也问备用主机,见 lyricSearchAsksBackupHosts。
	ctx = withLyricSearchBackupHosts(ctx)
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	currentSource := enrichCache[key].LyricsSource
	sourceChoice := opts.sourceChoice(enrichCache[key].LyricsSourceChoice)
	startLyrics := enrichCache[key].Lyrics
	startKana := enrichCache[key].LyricsKana
	listed := enrichCache[key].YouTubeMusicAlbum
	storedSearchTitle := enrichCache[key].LyricsSearchTitle
	stamp := enrichEditStampLocked()
	ctx = withCachedYouTubeMusicVideoIDLocked(ctx, key)
	enrichMu.Unlock()
	ctx = withLearnedAliasSelf(ctx, key)
	// 搜索用的专辑同 retryLyricsUpgrade。
	searchAlbum, listedAlbum := lyricsSearchAlbum(ctx, album, listed, durationSecs, artist, title)

	// 播放侧的后台重试没有"停止"入口(见 backfillPeripheralFields 同款注释);补空扫描 / 全量扫库
	// 传进来的 ctx 可以取消。
	roundCtx, round := withLyricSourceRound(ctx)
	roundCtx, queries := withLyricQueryLog(roundCtx)
	// 交给各歌词源的歌名同 retryLyricsUpgrade。
	roundCtx = withLyricSourceTitle(roundCtx, lyricSearchTitleOrStored(ctx, storedSearchTitle, title), artist, title, searchAlbum)
	// 查询词同 retryLyricsUpgrade。
	qa, qt, qal := searchQueryFields(artist, title, searchAlbum)
	_, scored := scoredLyricCandidatesStreaming(withSearchQueryOriginal(roundCtx, artist, title, searchAlbum), qa, qt, qal, durationSecs, opts.onUpdate())
	if ctx.Err() != nil {
		return false
	}
	reached := round.reachedAny()
	// 同 retryLyricsUpgradeWith:快照按补好的那份算。
	startLyrics = unmaskedCounterpart(currentSource, startLyrics, scored)
	// 用户选定过源就只在那个源内重选,见 LyricsSourceChoice 字段注释。
	picked := pickLyricCandidatePreferring(scored, sourceChoice)
	// 传 false:这条路只对有词的条目跑(needsLyricsRescore 第一行就要求 e.Lyrics != "",全量扫库和手动重新匹配
	// 都先把没词的分给补空那条路),手上总有一份要保护的词。
	decidable := rescoreDecidable(scored, currentSource, false) ||
		rescorePlayerLocalUnreachable(currentSource, key)
	// 当前这份跟这一轮哪一份都对不上:是另一首歌的词,当前来源没应答也可判,换不换也不再看它留不留得住
	// (见 rescoreCurrentContradicted)。
	contradicted := rescoreCurrentContradicted(startLyrics.String(), scored, picked)
	decidable = decidable || contradicted
	seen := lyricSourcesWithCandidates(scored)
	// 罗马音兜底在上锁之前算好,同 retryLyricsUpgrade。
	var preparedRoma string
	if decidable && picked != nil && picked.LyricsRoma == "" && !startLyrics.EqualString(picked.Lyrics) {
		preparedRoma = generatedRomaFor(picked.Lyrics, "", entrySongLanguage(picked.Lyrics, scored),
			nextLyricsKana(startKana, picked.Lyrics, picked.LyricsYRC, scored))
	}
	// 同 retryLyricsUpgrade:换正文会让正在播的这首丢掉能用的译文时先翻好。判据对着下面 default 分支换正文那一支。
	preparedTr := prepareSwapTranslation(ctx, key, artist, title, picked, func(e enrichEntry) bool {
		return (opts.manual || !e.ManualLyrics) && decidable && picked != nil &&
			!rescoreKeepsLyrics(rescoreComparedEntry(e, durationSecs), scored, picked, opts.manual, contradicted) &&
			!e.Lyrics.EqualString(picked.Lyrics)
	})
	// 只打了纯音乐标记(rescoreTurnsInstrumental):要马上落盘、通知重推,但歌词没换,不导出、不补翻。
	markedInstrumental := false
	// 同 retryLyricsUpgradeWith:播放器给的 ISRC 在上锁之前取。
	sourceISRC := lyricSourceISRC(ctx, artist, title, album)

	enrichMu.Lock()
	// 解锁之后再落盘 —— App 侧读的是**磁盘上**这份缓存文件(EnrichCacheReader 每次直读
	// 文件),只把 enrichDirty 标成 true 是不够的:补出来的东西只活在引擎内存里,
	// 界面永远看不到(表现是日志里译文一首首翻出来了,而缓存文件停在两小时前)。
	// **四条补全路径都要做这一步**,不只 resolveEnrichAsync / backfillPeripheralFields。
	//
	// 顺序不能反:saveEnrichCache 和 exportLyricsFiles 自己都要拿同一把 enrichMu,
	// 在持锁期间调用会死锁。
	//
	// 导出只在歌词族字段真的变了的时候做,而且只导这一条(exportLyricsFilesFor):这几条
	// 路径就算什么都没补上也会推进重试计数/时间戳(那些只要落盘、不涉及 lyrics/ 文件)。
	lyricsChanged := false
	// leadsGroup:换词之前这条的歌词不是从同组别的写法同步来的(songShareFollower),换了才让共享组跟上。
	leadsGroup := false
	defer func() {
		if lyricsChanged {
			translateAfterLyricsSwapLocked(key)
		}
		enrichMu.Unlock()
		if !lyricsChanged && !markedInstrumental {
			requestEnrichBookkeepingSave(key)
			return
		}
		commitEnrichSave(key)
		if lyricsChanged {
			exportLyricsFilesFor(key)
		}
		// 歌词同步开着时共享组跟上这一份(手动重新匹配那条路自己跟,见 runLyricsRematchOne)。
		if lyricsChanged && leadsGroup && !opts.manual {
			shareFollowAfterSwap(key)
		}
		// 非阻塞通知 poll 立刻重推。跟 saveEnrichCache 一样,**四条补全路径都要做** —— 漏了
		// 的话,同一首歌播到中途才补出来的译文要等下一次换歌才会被推出去(译文其实早就翻好、
		// 也落盘了,只是没人通知)。
		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
	}()
	e, ok := enrichCache[key]
	leadsGroup = ok && !songShareFollower(e)
	if !ok {
		// 重搜这段时间里这条被用户在"歌词管理"里删掉了 —— 不要把它复活回去。
		opts.report(lyricsRematchMissing)
		return false
	}
	// 期间用户可能刚好手改或采纳了这条(重搜是异步的,进来时的快照已经过期)。跟删除同理:
	// 以拿锁这一刻的实际状态为准,不能用几秒前的判断结果去覆盖用户刚做的改动。采纳候选在开关
	// 关着时不置 ManualLyrics,所以还要看改动序号。手动重新匹配照跑人工修正过的条目(见 lyricsRescoreOpts)。
	if (e.ManualLyrics && !opts.manual) || enrichEditedSinceLocked(key, stamp) {
		opts.report(lyricsRematchEdited)
		return false
	}
	before := e
	if gainUnmaskedWords(&e, scored) {
		log.Printf("lyrics: %s  %s masked words filled in from this round", key, e.LyricsSource)
		lyricsChanged = true
	}
	// 当前这份只有署名:它不是要护着的歌词,见下面 keep 与纯音乐那一支。
	currentCreditOnly := lyricsAreCreditsOnly(e.Lyrics.String())
	// 换了打分版本后的第一次尝试:旧版本下的计数作废、从零开始(见 LyricsRescoreVersion 注释)。
	if e.lyricsRescoreScoring() != currentLyricsScoring {
		e.LyricsRescoreCount = 0
		e.stampLyricsRescore()
	}
	// 一个歌词源都没连上的这一轮不占上限次数,理由同 retryLyricsUpgrade。
	if reached {
		e.LyricsRescoreCount++
	}
	e.LyricsRescoreTS = time.Now().Unix()
	// 不可判(当前源这轮没应答)时这一轮没有做出任何决定:不写决策记录,出现过 / 应答 / 跳过三份
	// 名单和搜索用的登记专辑也不盖 —— 它们跟决策记录一起描述当前这份歌词是哪一轮选出来的,只盖名单会让两者对不上、
	// 应答源数被一轮残缺的搜索压低。可判的两个分支都写(见 decision.go 的 Applied 语义)。
	skipped := round.skippedSources()
	if decidable {
		e.LyricsListedAlbum = listedAlbum
		e.LyricsNativeVideoID = kasetNativeLyricsVideoID(ctx, round, scored)
		if len(seen) > 0 {
			e.LyricsSourcesSeen = seen
		}
		if responded := lyricSourcesResponded(scored); len(responded) > 0 {
			e.LyricsSourcesResponded = responded
		}
		e.LyricsSourcesSkipped = lyricSourcesSkippedForRetry(skipped)
		if sw := songwritersFromScored(scored); len(sw) > 0 {
			e.LyricsSongwriters = sw
		}
		recordISRCs(&e, recordingISRCsFromScored(sourceISRC, scored, durationSecs, title, album))
	}
	// 有源被跳过(熔断冷却 / 后台暂停)的一轮只算这一版规则下的阶段性结论:照常重选,但不把打分
	// 版本标成已追平,needsLyricsRescore 与全量扫库之后还会再选中它。
	complete := len(skipped) == 0
	deferred = !decidable || !complete
	// 冠军换词之前先看当前这份该不该留着,见 rescoreKeepsLyrics。
	compared := rescoreComparedEntry(e, durationSecs)
	keep := decidable && picked != nil && rescoreKeepsLyrics(compared, scored, picked, opts.manual, contradicted)
	if decidable {
		e.LyricsDecision = buildLyricsDecision(
			opts.decisionPath(lyricsDecisionPathRescore), artist, title, searchAlbum, durationSecs, scored, picked,
			picked != nil && !keep && (!e.Lyrics.EqualString(picked.Lyrics) || gainsWordTiming(e, picked)))
		e.LyricsDecision.SourcesSkipped = skipped
		e.LyricsDecision.statsSkips = round.statsSkips()
		e.LyricsDecision.QueriesTried = queries.queries()
		traceLyricsDecision(key, e.LyricsDecision)
		// rescore 可判且有胜者:无论内容换没换,这一轮之后当前歌词就是 picked 那份
		// (见下面 default 分支),它就是新的出处(分槽语义见 LyricsDecisionApplied)。
		if picked != nil && !keep {
			e.LyricsDecisionApplied = e.LyricsDecision
		}
	}
	if contradicted {
		log.Printf("lyrics rescore: %s  current lyrics (%s) match none of this round's candidates; %s(%d) is title-matched and corroborated",
			key, currentSource, picked.Source, picked.Score)
	}
	switch {
	case !decidable:
		log.Printf("lyrics rescore deferred: %s  current source %q did not answer this round (responded: %v)",
			key, currentSource, lyricSourcesResponded(scored))
	case picked == nil && sourceChoice == "" && !opts.manual && rescoreTurnsInstrumental(e, scored):
		// 这一轮有纯音乐标记、没有能用的候选,而现有这份歌词就是被判版本不符的那条:按纯音乐处理。同用户手标,
		// 歌词留在条目里,撤标就回来。
		if complete {
			e.stampLyricsScoring()
		}
		e.ResolvedDurationSecs = durationSecs
		e.Instrumental = true
		markedInstrumental = true
		log.Printf("lyrics rescore: %s  %s is another version and a source says instrumental, marking instrumental under v%s",
			key, e.LyricsSource, currentLyricsScoring)
	case picked == nil && sourceChoice == "" && e.autoMarksInstrumental() &&
		(localIsInstrumentalVersion(title, album) || (currentCreditOnly && scoredHasInstrumentalMarker(scored))):
		// 伴奏版,或当前这份只有署名、这一轮有源说是纯音乐:按纯音乐处理,歌词留在条目里、撤标就回来。手动重新匹配同样走这里。
		// 见 09 章决策 209。
		if complete {
			e.stampLyricsScoring()
		}
		e.ResolvedDurationSecs = durationSecs
		e.Instrumental = true
		markedInstrumental = true
		log.Printf("lyrics rescore: %s  no usable candidate for an instrumental version or credits-only lyrics, marking instrumental under v%s",
			key, currentLyricsScoring)
	case picked == nil:
		// 够格判断、但新规则下一个能用的候选都没有(比如全被"超出曲目时长"判掉)。
		// 保留现有歌词不动 —— 有一份存疑的歌词也好过没有 —— 但版本号照盖:结论已经
		// 在完整信息下得出过了,再重搜一次也是同样的结果。
		if complete {
			e.stampLyricsScoring()
		}
		if !lyricsFitAnotherCut(e, durationSecs) {
			e.ResolvedDurationSecs = durationSecs
		}
		log.Printf("lyrics rescore: %s  no valid candidate under v%s, keeping %s", key, currentLyricsScoring, e.LyricsSource)
	case keep:
		// 当前这份留着(见 rescoreKeeps),只记这一轮做过。给另一版选的那份(lyricsFitAnotherCut)留下来时不改记成这一轮的
		// 时长:它没在这个时长下赢过,改了之后升级重选和重新匹配都认不出它配不上这段录音。
		if complete {
			e.stampLyricsScoring()
		}
		if !lyricsFitAnotherCut(e, durationSecs) {
			e.ResolvedDurationSecs = durationSecs
		}
		switch {
		case rescoreWouldLoseWordTiming(e, scored, picked):
			log.Printf("lyrics rescore: %s  keeping %s(%d) with word timing, %s(%d) has none this round",
				key, e.LyricsSource, e.LyricsScore, picked.Source, picked.Score)
		case rescoreKeepsCurrent(compared, scored, picked):
			if cur, gained, _ := currentLyricsRoundScore(compared, scored, false); gained {
				log.Printf("lyrics rescore: %s  keeping %s, the same lyrics this round lack its word timing or translation (%d with them), %s(%d) is no better",
					key, e.LyricsSource, cur, picked.Source, picked.Score)
				break
			}
			log.Printf("lyrics rescore: %s  keeping %s(%d), current lyrics not among candidates and %s(%d) is no better",
				key, e.LyricsSource, e.LyricsScore, picked.Source, picked.Score)
		default:
			log.Printf("lyrics rescore: %s  keeping %s(%d), %s(%d) shows the same lyrics",
				key, e.LyricsSource, e.LyricsScore, picked.Source, picked.Score)
		}
	default:
		if !e.Lyrics.EqualString(picked.Lyrics) {
			if !e.LyricsYRC.IsZero() && picked.LyricsYRC == "" && rescoreCurrentTimelineOff(e, scored) {
				log.Printf("lyrics rescore: %s  current %s lyrics run off this round's timeline, not keeping them for their word timing",
					key, e.LyricsSource)
			}
			log.Printf("lyrics rescore: %s  %s(v%s) -> %s(%d)", key, e.LyricsSource, e.lyricsScoring(), picked.Source, picked.Score)
			e.Lyrics = bt(picked.Lyrics)
			e.LyricsTr, e.LyricsRoma, e.LyricsYRC = bt(picked.LyricsTr), bt(picked.LyricsRoma), bt(picked.LyricsYRC)
			e.LyricsBG, e.LyricsBGChecked = bt(picked.LyricsBG), lyricsBGParserVersion
			e.SongLanguage = entrySongLanguage(picked.Lyrics, scored)
			e.dropHokkienRoma()
			e.dropUnusableCantoneseRoma()
			e.applyPregeneratedRoma(preparedRoma)
			lyricsChanged = true
			// 译文换人了,描述译文的两个字段必须跟着换:语言(否则拿旧语言判新译文),
			// 来源(否则上一轮机翻留下的 "machine" 会让新来的社区译文被标成机翻)。
			e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, lyricsTrSourceFor(picked)
			e.resetTranslationAttempts()
			preparedTr.applyLocked(&e)
		}
		if e.Lyrics.EqualString(picked.Lyrics) && gainsWordTiming(e, picked) {
			log.Printf("lyrics rescore: %s  %s gained word timing", key, picked.Source)
			e.LyricsYRC = bt(picked.LyricsYRC)
			lyricsChanged = true
		}
		// 正文没变、这条还没按背景人声解析器取过:这一轮取到的背景人声(可能为空)就是它该有的。
		// 背景人声不导出成歌词文件,不用置 lyricsChanged。
		if e.Lyrics.EqualString(picked.Lyrics) && e.LyricsBGChecked < lyricsBGParserVersion {
			e.LyricsBG, e.LyricsBGChecked = bt(picked.LyricsBG), lyricsBGParserVersion
		}
		if picked.Source != e.LyricsSource {
			// 正文一样但冠军换了源:导出的 .lrc 里 [source:] 头也得跟着重写。lyrics/ 文件夹是
			// 6 字段权威源,importLyricsFromFiles 下次启动会拿文件头把缓存里的 LyricsSource
			// 静默改回旧值,rescore 的结论就被回滚了。
			lyricsChanged = true
		}
		if opts.manual {
			// [manual:1] 写在导出的歌词文件头里,清掉人工修正标记要重新导出。
			if e.ManualLyrics {
				lyricsChanged = true
			}
			e.ManualLyrics, e.LyricsSourceChoice = false, ""
		}
		e.LyricsSource = picked.Source
		e.LyricsScore = picked.Score
		if complete {
			e.stampLyricsScoring()
		}
		e.ResolvedDurationSecs = durationSecs
	}
	// 跟首次解析同一条「同一段录音、评分高的兄弟赢」(判据见 crossalbum.go),不挂的话
	// cross-album-reuse 对齐过的组会在这两条路径上各自重选、又长出分歧。刚按纯音乐处理的不换词。
	if !markedInstrumental && adoptCrossAlbumSiblingLyrics(key, &e) {
		lyricsChanged = true
	}
	// 正文没变、自己没有可用译文:这一轮同一份正文借到了译文就补上(见 applyBorrowedTranslations)。
	if !markedInstrumental && gainBorrowedTranslation(&e, scored) {
		log.Printf("lyrics: %s  %s gained a translation from %s", key, e.LyricsSource, strings.TrimPrefix(e.LyricsTrSource, lyricsTrSourceBorrowedPrefix))
		lyricsChanged = true
	}
	refreshSpeakers(&e, scored)
	refreshKana(&e, scored)
	if rematchClearsInstrumental(opts.manual, before, e) {
		e.Instrumental = false
	}
	opts.finish(lyricsRematchFacts{before: before, after: e, picked: picked, reached: reached, decidable: decidable,
		keptWordTiming: keep && rescoreWouldLoseWordTiming(before, scored, picked)})
	enrichCache[key] = e
	enrichDirty = true
	return deferred
}

// peripheralQQURL 外围补全后生效的 QQ 链接:只在这一轮**真的升级了**(拿到真·歌曲页)时才覆盖 ——
// 兜底搜索链接不该把已经存下来的真链接冲掉(fresh 可能因为一次网络抖动退化成兜底)。
func peripheralQQURL(existing, fresh string) string {
	if fresh != "" && (!isQQSearchFallbackURL(fresh) || isQQSearchFallbackURL(existing)) {
		return fresh
	}
	return existing
}

// peripheralQQMids 是 lookupPeripheralQQMids 在锁外查好的结果;songMid 是按哪一首查的。
type peripheralQQMids struct {
	songMid, albumMid, singerMid string
}

// lookupPeripheralQQMids 在拿 enrichMu 之前,按外围补全落盘时会生效的那个 QQURL 查专辑 / 歌手 mid。
// 条目不在、两个 mid 都已经有、链接里没有 songmid 时不查。
func lookupPeripheralQQMids(ctx context.Context, key string, fresh enrichEntry) peripheralQQMids {
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok || (e.QQAlbumMid != "" && e.QQSingerMid != "") {
		return peripheralQQMids{}
	}
	songMid := qqMidFromURL(peripheralQQURL(e.QQURL, fresh.QQURL))
	if songMid == "" {
		return peripheralQQMids{}
	}
	albumMid, singerMid := qqSongCatalogMids(ctx, songMid)
	return peripheralQQMids{songMid: songMid, albumMid: albumMid, singerMid: singerMid}
}

// rescoreKeepsCurrent:重评可判(当前歌词的来源这一轮回了话),但回来的不是当前这一份 —— 当前这份没参与这一轮
// 的比较。它已经是这一版规则下打的分时,两个分数可以比:冠军不比它高就不换(不然一次换了个版本回来的应答就能
// 让 820 分的词换成 500 分的)。打分版本落后的,旧分数没法比,照原规则让这一轮说了算。跟这一轮某份被判整首错开的
// 候选同轴(rescoreCurrentTimelineOff)的也不比:那一份就是当前这份、只是正文写法变了,它已经参与比较并输了,
// 存的分数是没扣这一项时打的。
//
// 当前这份参与了比较(这一轮有同一份正文的候选)时输了就换;只有它带着那份候选没带的逐字 / 译文时,按补上之后的分比
// (currentLyricsRoundScore),这个分是这一轮的、跟打分版本无关。
func rescoreKeepsCurrent(e enrichEntry, scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult) bool {
	if e.Lyrics.EqualString(picked.Lyrics) {
		return false
	}
	if cur, gained, ok := currentLyricsRoundScore(e, scored, false); ok {
		return gained && picked.Score <= cur
	}
	if e.lyricsScoring() != currentLyricsScoring {
		return false
	}
	return !rescoreCurrentTimelineOff(e, scored) && picked.Score <= e.LyricsScore
}

// currentLyricsRoundScore:当前这份歌词在这一轮的分 —— 跟它同一份正文的候选的分(sameSource 时还要同一个源;同文的有
// 几份取最高),加上当前这份带着、那份候选没带的东西按打分同一口径该得的分(currentLyricsExtraPoints)。gained:补上了。
// ok:这一轮有同文的候选。同一段词常挂在同一首歌的几个条目下,有的带逐字、有的没有(换专辑、同曲共享、同一个源的
// 不同曲目 ID),只拿候选的分会把当前这份的逐字算丢,输给分数更低的另一份。被判不可用(负分)的候选不补。见 09 章决策 304。
func currentLyricsRoundScore(e enrichEntry, scored []scoredLyricCandidateResult, sameSource bool) (score int, gained, ok bool) {
	for i := range scored {
		c := &scored[i]
		if (sameSource && c.Source != e.LyricsSource) || !e.Lyrics.EqualString(c.Lyrics) {
			continue
		}
		s, extra := c.Score, 0
		if s > 0 {
			extra = currentLyricsExtraPoints(e, c, scored)
		}
		if !ok || s+extra > score {
			score, gained, ok = s+extra, extra > 0, true
		}
	}
	return score, gained, ok
}

// currentLyricsExtraPoints:当前这份带着、同文候选 c 没带的增值内容在这一轮该得的分:逐字(当前这份这一轮没被判整首
// 错开时,同 rescoreWouldLoseWordTiming)、歌词源自带的可用译文(机翻不算)。判据跟构造候选时同一套
// (usableWordTiming、usableValueAdd)。
func currentLyricsExtraPoints(e enrichEntry, c *scoredLyricCandidateResult, scored []scoredLyricCandidateResult) int {
	extra := 0
	if scoreTermPoints(c.ScoreTerms, scoreTermWordTiming) == 0 && usableWordTiming(e.Lyrics.String(), e.LyricsYRC.String()) &&
		!rescoreCurrentTimelineOff(e, scored) {
		extra += wordTimingPoints
	}
	if scoreTermPoints(c.ScoreTerms, scoreTermTranslation) == 0 && e.LyricsTrSource == "" {
		if tr, _ := usableValueAdd(e.Lyrics.String(), e.LyricsTr.String(), e.LyricsTrLang, "", features().LyricsTranslationLanguage); tr {
			extra += translationPoints
		}
	}
	return extra
}

// rescoreComparedEntry:重评判当前这份留不留时拿来比的那一份。它是给另一版选的(lyricsFitAnotherCut)时,存着的分带着
// 那个时长的加分,记成 0;它这一轮也在候选里时 rescoreKeepsCurrent 照旧按这一轮的分比。同升级重选那条,见 09 章决策 289。
func rescoreComparedEntry(e enrichEntry, durationSecs float64) enrichEntry {
	if lyricsFitAnotherCut(e, durationSecs) {
		e.LyricsScore = 0
	}
	return e
}

// rescoreKeeps:重评可判、有冠军时,当前这份要不要留着 —— 它没参与比较而冠军不比它高(rescoreKeepsCurrent),
// 或者换过去会丢掉逐字(rescoreWouldLoseWordTiming)。
func rescoreKeeps(e enrichEntry, scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult) bool {
	return rescoreKeepsCurrent(e, scored, picked) || rescoreWouldLoseWordTiming(e, scored, picked)
}

// rescoreKeepsLyrics:重评可判、有冠军时当前这份留不留 —— rescoreKeeps,外加冠军换上去屏上看不出差别(keepsShownLyricsOver,
// 手动重新匹配不算)。只有署名的当前这份一律不留(09 章决策 209),跟这一轮哪份都对不上的(contradicted,见
// rescoreCurrentContradicted)也不留。锁内正式判一次、锁外按快照预判一次(prepareSwapTranslation),两处必须调这一个函数。
func rescoreKeepsLyrics(e enrichEntry, scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult, manual, contradicted bool) bool {
	if picked == nil || contradicted || lyricsAreCreditsOnly(e.Lyrics.String()) {
		return false
	}
	return rescoreKeeps(e, scored, picked) || (!manual && keepsShownLyricsOver(e, picked))
}

// rescoreContradictedMaxSim:当前这份跟这一轮的候选正文 3-gram 相似度都低于它,才算对不上。另一首歌的词在 0.05 以下;
// 同一段词换了写法(粤语口语字对书面中文)也能低到 0.16,不能算。见 09 章决策 214。
const rescoreContradictedMaxSim = 0.1

// rescoreCurrentContradicted:当前这份歌词是不是另一首歌的词 —— 这一轮的冠军歌名对得上(titleMatch,含从正文互证
// 伙伴继承的)、有别家正文印证(consensus)、末句跟曲长对得上且自报曲长没有对不上(duration 有分、没有
// sourceDurationOff),而当前这份正文跟这一轮每一份可比的候选(正文不短于 lyricConsensusMinBodyRunes,被判负分的
// 也算)相似度都低于 rescoreContradictedMaxSim,可比的至少两份。成立时当前来源没应答也可判(当初那份多半是搜歪了
// 才拿到的,换了搜法就再也搜不到它),rescoreKeepsLyrics 也不留它:另一首歌的词没有可保护的,它有逐字、分数没被
// 比过都不算留的理由。见 09 章决策 214。
func rescoreCurrentContradicted(current string, scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult) bool {
	if picked == nil || scoreTermPoints(picked.ScoreTerms, scoreTermTitleMatch) <= 0 ||
		scoreTermPoints(picked.ScoreTerms, scoreTermConsensus) <= 0 ||
		scoreTermPoints(picked.ScoreTerms, scoreTermDuration) <= 0 ||
		scoreTermPoints(picked.ScoreTerms, scoreTermSourceDurationOff) != 0 {
		return false
	}
	body := lyricConsensusBody(current)
	if utf8.RuneCountInString(body) < lyricConsensusMinBodyRunes {
		return false
	}
	grams := lyricGram3Set(body)
	comparable := 0
	for _, c := range scored {
		if c.Lyrics == "" || c.Instrumental || c.TrackFoundNoLyrics {
			continue
		}
		b := lyricConsensusBody(c.Lyrics)
		if utf8.RuneCountInString(b) < lyricConsensusMinBodyRunes {
			continue
		}
		if gramJaccard(grams, lyricGram3Set(b)) >= rescoreContradictedMaxSim {
			return false
		}
		comparable++
	}
	return comparable >= 2
}

// rescoreWouldLoseWordTiming:冠军是另一份正文、没有逐字,而当前这份有逐字。逐字取决于那个源这一轮有没有把逐字
// 接口给全,同一首歌这一轮有、下一轮一个都没有很常见;换过去会把卡拉 OK 填色丢掉,而且不可逆。正文相同时不算
// (那种情形只会补逐字,见 gainsWordTiming);这一轮判了当前这份整首错开时也不算(rescoreCurrentTimelineOff)。
func rescoreWouldLoseWordTiming(e enrichEntry, scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult) bool {
	return !e.Lyrics.EqualString(picked.Lyrics) && !e.LyricsYRC.IsZero() && picked.LyricsYRC == "" && !rescoreCurrentTimelineOff(e, scored)
}

// rescoreCurrentTimelineOff:当前这份的时间轴跟这一轮某份扣了 timelineOffset 的候选是同一份(timelinesIdentical),
// 即这一轮判了它整首错开,它的逐字填色也跟着错开。跟哪一份被扣分的候选都对不上时不算。见 09 章决策 217。
func rescoreCurrentTimelineOff(e enrichEntry, scored []scoredLyricCandidateResult) bool {
	current := displayedTimeline(e.Lyrics.String(), e.LyricsYRC.String())
	for i := range scored {
		c := &scored[i]
		if scoreTermPoints(c.ScoreTerms, scoreTermTimelineOffset) < 0 && timelinesIdentical(current, displayedTimeline(c.Lyrics, c.LyricsYRC)) {
			return true
		}
	}
	return false
}

// gainsWordTiming:正文不变时唯一要补写的情况 —— 缓存里没有逐字、这一轮的胜者带了逐字。
// 只补 LyricsYRC,译文/罗马音保持原样(正文没变,它们没有理由跟着换)。rescoreLyrics 和
// resync-lyrics 两处共用这一条判定。
func gainsWordTiming(e enrichEntry, picked *scoredLyricCandidateResult) bool {
	return e.LyricsYRC.IsZero() && picked.LyricsYRC != ""
}

// resolveEnrichAsync 首次解析一首歌的完整信息(封面/主色/链接/歌词),写入并永久保留,
// 直到用户在"歌词管理"里显式删除这条。由 trackEnrichment 在从没见过这个 key 时启动;
// 同一 key 同时只有一个在跑(enrichInflight 去重)。各外部请求自带 4~10s 超时,故本
// goroutine 有界、进程退出即止。
//
// 支持取消(见 enrichcancel.go):调用方(见下面的 go resolveEnrichAsync(...) 调用点)
// 为每一次首次解析单独开一个 context.WithCancel,登记进 enrichCancelFuncs;用户在
// "歌词管理"占位行点"停止搜索"时,enrichcancel.go 的后台 watcher 会找到这份登记、调用
// 对应的 cancel —— 真正让下面 resolveTrackEnrichment 内部还在飞的网络请求中断,不是
// "隔着进程装个样子"。
//
// isNewTrack:透传自 trackEnrichment,true 时才去取设备直送封面——
// 见 trackEnrichment 参数注释。albumprefetch.go 直接调这个函数解析同专辑里没在播的
// 曲目,恒传 false(那些曲目此刻并不是设备正在播的这首,见该调用点注释)。
func resolveEnrichAsync(ctx context.Context, key, artist, title, album, bundleID string, durationSecs float64, isNewTrack bool) {
	// 开跑时的改动序号:这一轮跑着的时候「歌词管理」改了这首,落盘时整轮作废(见 enrichedit.go 的改动序号)。
	enrichMu.Lock()
	stamp := enrichEditStampLocked()
	noteEnrichCreatedLocked(key)
	enrichMu.Unlock()
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		delete(enrichProvisional, key)
		// 无论正常完成还是被取消,都要把登记表里这一条清掉——留着就是内存泄漏(map
		// 只会越长越大),而且会让下一次同一首歌的首次解析误查到一个早已失效的旧
		// CancelFunc。对已经被调用过的 cancel 再调一次是安全的空操作,这里统一调一遍
		// 兜底(正常完成的路径从没调用过它)。
		if cancel, ok := enrichCancelFuncs[key]; ok {
			cancel()
			delete(enrichCancelFuncs, key)
		}
		if translateAfterResolve(ctx) {
			translateUpcomingLocked(key)
		}
		enrichMu.Unlock()
	}()
	// 观察这一轮的网络成败 —— 全空时要能区分"查过了,这首歌没有"和"根本没查成"。
	// 必须用 per-round 的计数,不能用 networkLooksDown():那个读的是进程启动以来的累计
	// 值,在常驻采集器里一旦早期有过成功就永远报"正常"(见 networkobs.go)。只数这一首自己发的(withNetworkRound):
	// 专辑预取并发解析的别的歌、中继推送、收听上送的成功混进来,一个请求都没问成的这首也会被判成「查过了没有」。
	ctx, roundStat := withNetworkRound(ctx)
	deviceCoverURL := deviceCoverURLIfFresh(ctx, isNewTrack, bundleID, artist, title)
	if deviceCoverURL != "" {
		// 这一刻设备推的可能还是它自己的占位图(见 deviceCoverSettleDelays)。首次解析走不到
		// applyDeviceCoverUpgrade —— 那条路的闸门是「条目已存在且封面还不是 device」,而这里
		// 的条目正是这一趟新建的、封面恰恰就是 device,于是占位图会永久钉在这条新记录上。
		// 第一档延迟之前条目多半还没落盘,那几趟自己会判成「条目还不在」直接跳过。
		// 不跟首次解析的 ctx 走:解析一结束 defer 就取消它,而那几档恰恰要在条目落盘**之后**才有事做,
		// 跟着它走一档都跑不成。三档一共 16 秒、每档都重读条目,自己就是有界的。
		go settleDeviceCover(context.WithoutCancel(ctx), key, artist, title, album, bundleID)
	} else if isNewTrack {
		// 没有设备封面时 App 可能交来的是视频帧:条目落盘之后记下(见 settleVideoFrame)。
		go settleVideoFrame(context.WithoutCancel(ctx), key, bundleID, artist, title)
		// 封面可能只是还没到:收尾挑封面时再取一次(见 withLateDeviceCover)。
		ctx = withLateDeviceCover(ctx, bundleID, artist, title)
	}
	// 歌词先上屏:resolveTrackEnrichment 选定歌词后、补外围信息之前回调一次,先提交一份只带
	// 歌词与网易云封面的条目;下面拿到完整结果后再提交一次,整条覆盖它。
	var earlyLog earlyCommitLog
	early := func(p enrichEntry) {
		if ctx.Err() != nil {
			return
		}
		p.LyricsSearchTitle = lyricSearchTitleToStore(ctx, title)
		enrichMu.Lock()
		applySpotifyTrackIDHintLocked(key, &p)
		enrichProvisional[key] = true
		enrichMu.Unlock()
		p.TS = time.Now().Unix()
		p.PeripheralPending = true
		commitEnrichEntrySince(key, p, stamp)
		earlyLog.note(key, p.LyricsSource)
	}
	// Amazon Music 开播前就把这首的歌词拉进了本机缓存(按 ASIN 认,见 amazonlibrary.go):先把这份上屏,不等各歌词源 ——
	// 待播曲目常常认不出歌名、预取不到(见 amazonUpcoming),不垫这一份,开头要空到网络那份回来。选定的那份照常经
	// early / 最终提交整条覆盖它。只管正在放的这首(isNewTrack),预取的那些不是在放的歌。伴奏版不垫,它直接标纯音乐
	// (instrumentalVersionEnrichment)。
	if p, ok := amazonProvisionalLyrics(isNewTrack, bundleID, artist, title, album); ok && ctx.Err() == nil && !localIsInstrumentalVersion(title, album) {
		enrichMu.Lock()
		enrichProvisional[key] = true
		enrichMu.Unlock()
		p.TS = time.Now().Unix()
		p.PeripheralPending = true
		commitEnrichEntrySince(key, p, stamp)
		log.Printf("lyrics: showing Amazon Music's cached lyrics for %q while the sources resolve", key)
	}
	e := resolveTrackEnrichment(ctx, artist, title, album, durationSecs, deviceCoverURL, early, lyricsDecisionPathFirstResolve)
	if deviceCoverURL == "" && isNewTrack && e.CoverSource == "device" {
		// 收尾那次才取到的设备封面同样可能是占位图,照开头取到时一样再核几档。
		go settleDeviceCover(context.WithoutCancel(ctx), key, artist, title, album, bundleID)
	}
	e.LyricsSearchTitle = lyricSearchTitleToStore(ctx, title)
	// 首次解析:换曲那一拍 poller 留下的 Spotify 曲目 ID 一并写进条目(见 spotifytrack.go)。首次解析的 key
	// 就是原始 key(canonical 命中的话走的是上面缓存命中那条路),直接按它查。
	enrichMu.Lock()
	applySpotifyTrackIDHintLocked(key, &e)
	enrichMu.Unlock()
	e.TS = time.Now().Unix()

	if ctx.Err() != nil {
		// 被用户手动取消(见 enrichcancel.go)。跟"自然查无"走同一条写入路径,不因为
		// e 大概率残缺就被下面"全空不写入"那道守卫拦住:用户主动点了「停止搜索」,
		// 就该立刻落定成"暂无歌词"这个确认状态——EnrichCacheReader.lookup 靠 ts>0
		// 判定"这一轮解析真的跑完了"(见该文件顶部注释),写这条记录之后灵动岛/桌面
		// 悬浮歌词/歌词管理会统一从"搜索歌词中…"切到"暂无歌词",不需要改 Swift 侧
		// 一行代码。以后这首歌重新播放时会经 needsLyricsFirstFill 正常走自愈重试
		// 节奏(24h 起始指数退避),不是永久钉死在"没有"上——取消只是让用户不用
		// 干等这一次,不是给这首歌下了永久结论。
		//
		// 不走下面的网络健康度分类:那一段统计的是"这一轮请求失败得多不多",用户
		// 主动取消会让全部还在飞的请求同时失败,拿这个去判"网络是不是不通"是一次
		// 必然的误报,而不是巧合。
		//
		// 拿到了歌词的才记外围待补:没词的照旧按 needsLyricsFirstFill 的退避重搜,别让取消变成立刻重来。
		e.PeripheralPending = !e.Lyrics.IsZero() || !e.PlainLyrics.IsZero()
		commitEnrichEntrySince(key, e, stamp)
		return
	}

	// 网络结论**独立于**下面写不写缓存来下 —— 别把它挂在守卫分支里。
	// 挂进去的话,只要有任何一个字段碰巧非空(下面那个搜索链接兜底就是),这条判断就再也
	// 不会执行,而那恰恰是断网时必然发生的情况。
	attempts, failures := roundStat()
	noteLyricsRoundNetwork(attempts, failures)

	// 只保留"解析到东西"的结果;全空(可能网络抽风)不写入,下次再试,别把偶发失败钉死。判据见 enrichRoundFoundNothing。
	if enrichRoundFoundNothing(e) {
		// 全空分两种,结论完全不同,不能压成同一个"不写":
		//
		//  · 根本没查成(断网/整轮一个请求都没发出去)—— 不写,下次再试,别把一次网络抽风钉死成"这首歌没歌词"。
		//  · 查过了,确实没有(网络通、请求真发出去过、各源就是一条候选都没给)—— 照常写入:App 侧判定"这一轮解析
		//    跑完了"的唯一依据就是条目里的 TS(见 EnrichCacheReader.EnrichCacheLyrics.resolved),不写的话悬浮歌词、
		//    灵动岛、歌词窗口会一直停在"搜索歌词中…"。
		//
		// 确证查无这一支走的是跟用户点「停止搜索」同一条既有路径(上面 ctx.Err() 那一支):落一条只有 TS 的空条目,
		// UI 统一切到"暂无歌词"。这不是永久结论:needsLyricsFirstFill 会按 24h 起始的指数退避继续重试,这一轮有源因
		// 熔断被跳过的(LyricsSourcesSkipped 非空)10 分钟就重来一次。
		//
		// 判据用 attempts/failures 这一对而不是"全部源都应答":20 秒截止时差一两个源没回来是常态,要求全应答等于把最常见的
		// 情况留在无限转圈里。边界(整轮零请求、只发了一两个请求且全挂)由 lyricsRoundConfirmsNoResult 挡掉,见它的头注。
		if lyricsRoundConfirmsNoResult(attempts, failures) {
			commitEnrichEntrySince(key, e, stamp)
		}
		return
	}
	commitEnrichEntrySince(key, e, stamp)
}

// enrichRoundFoundNothing:一轮解析什么都没拿到(resolveEnrichAsync 的「全空不写入」)。纯文本歌词算拿到了:
// 正在放的文件标签里只有不带时间的歌词、网上又一样都没搜到时,这一轮的结果就只有它。
//
// QQURL 必须排除掉"搜索链接兜底"这一档。qqMusicURL 在 smartbox 查不到时会拼一个
// 纯本地的搜索页 URL(见 qq.go,它自己也不缓存这个兜底值)——**它不需要网络就能得到**,
// 拿它当"解析到东西"的证据是假的:断网时这条守卫会因此永不成立,于是每首歌都会往永久
// 缓存里写一条只有搜索链接、没有任何内容的条目。
// SpotifyURL 同样是本地拼的,所以它本来就不在这个判据里。
func enrichRoundFoundNothing(e enrichEntry) bool {
	hasRealQQURL := e.QQURL != "" && !isQQSearchFallbackURL(e.QQURL)
	return e.CoverURL == "" && e.Lyrics.IsZero() && e.PlainLyrics.IsZero() && e.AppleURL == "" && !hasRealQQURL && e.NeteaseURL == ""
}

// commitEnrichEntry 是 resolveEnrichAsync 两条落盘路径(正常查完/被用户取消)共用的
// 收尾:写缓存、落盘、导出歌词文件、非阻塞通知 poll 重推。抽出来是因为两条路径要做的
// 事逐字节相同,不是"相似的三行"——分开写只会让以后改一处漏改另一处。
func commitEnrichEntry(key string, e enrichEntry) {
	commitEnrichEntrySince(key, e, enrichEditNoStamp)
}

// commitEnrichEntrySince 同 commitEnrichEntry,另外核对改动序号:stamp 之后「歌词管理」改过这首
// (保存、采纳、删除、清空……),这一轮的结果作废、不落盘。取消这一轮的正是那次改动
// (cancelInFlightEnrichLocked),而取消分支本身也会落盘,不核对就会把删掉的条目写回、把刚存的歌词换掉。
func commitEnrichEntrySince(key string, e enrichEntry, stamp uint64) {
	timer := newStepTimer()
	defer timer.logIfSlow("commit for "+key, slowCommitThreshold)
	enrichMu.Lock()
	timer.mark("lock")
	// 被撤回的身份(播放中途被纠正顶掉)不再落盘,见 enrichretract.go。
	if enrichKeyRetractedLocked(key) {
		enrichMu.Unlock()
		return
	}
	if enrichEditedSinceLocked(key, stamp) {
		enrichMu.Unlock()
		log.Printf("enrich: dropped a resolve round for %q, the entry was edited while it ran", key)
		return
	}
	// 落盘前对齐到评分更高的跨专辑兄弟(同一段录音收在多张专辑下时,让它们用同一份歌词)。
	// 判据、保护位、以及「为什么只做单向」见 crossalbum.go。首次解析的几次提交和取消收尾都收口到这个函数;
	// 升级重试、重评在各自的写回处调同一个函数(见 retryLyricsUpgrade / rescoreLyrics 末尾)。
	// 写歌词的路径少挂一处就会又长出一条分歧。
	adoptCrossAlbumSiblingLyrics(key, &e)
	if _, existed := enrichCache[key]; !existed {
		enrichPendingHasNew = true
	}
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	timer.mark("cross_album")
	// 非阻塞通知 poll 立刻重推(带上刚解析好的封面/歌词);没人在听就跳过。排在落盘之前:
	// poll 读的是内存里的 enrichCache,不必等写盘。App 读的是磁盘文件,由下面的落盘负责。
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
	commitEnrichSaveTimed(key, timer)
	exportLyricsFilesFor(key) // 歌词为空的条目导出时自己会跳过,取消场景常见的空歌词记录不会被误导出成文件
	timer.mark("export")
}

// applyDeviceCoverUpgrade 把设备直送的封面(已经落盘,见
// fetchNowPlayingArtwork/deviceartwork.go)写进一条**已存在**的条目,顶掉它原来的封面
// (不管原来是网易云/Apple/QQ 哪个源)。
//
// 这是"封面来源是身份字段、解析出结果就不该被自愈路径悄悄改掉"这条一般原则(见
// backfillPeripheralFields 头注)的一次刻意例外:设备直送的封面不是"又猜了一次、猜得
// 可能更准",它的身份由"这一刻确实是设备自己在播这首歌"直接保证,不存在"猜错"的可能性
// (内容对不对得上这首歌不需要验证,内容是不是一张像样的封面图由 App 把关,见 deviceartwork.go
// 头注)——所以可以顶替,不需要跟旧封面比较谁更可信。
//
// 顶替**不是无条件的**:低分辨率的设备封面(浏览器 MediaSession 常给 120×120)不该
// 盖掉"同一张图的高清版"。判据见 coverquality.go 头注。
//
// 这处的清晰度判据跟 `resolveTrackEnrichment` 那处**必须同时存在**:那处只管**首次
// 解析**,而这条路管的是**已存在条目在换歌时的升级** —— 只守前者的话,已经升级成高清的
// 条目会在这首歌下次被播到时又被这里改回 120px。
//
// 不改 Lyrics/LyricsSource 等歌词族字段,也不改 AppleURL/QQURL 等跳转链接——这条只管
// 封面这一件事,其余外围字段仍由 needsPeripheralBackfill 那条既有路径负责。
//
// 调用方(trackEnrichment 的缓存命中分支)已经把 isNewTrack 判过了,这里恒传 true 给
// deviceCoverURLIfFresh——真正去取设备封面(读 App 写的当前封面文件)的动作就发生在这个 goroutine
// 里,不是同步拿到值才起这个 goroutine(那会阻塞 poll 循环,见 trackEnrichment 参数注释)。
func applyDeviceCoverUpgrade(ctx context.Context, key, artist, title, album, bundleID string) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	deviceCoverUpgradePass(ctx, key, artist, title, album, bundleID)
	// 头一趟拿到的可能是播放器自己的占位图,真封面晚几秒才推——见 deviceCoverSettleDelays。
	// 另起 goroutine 而不是在这儿等:登记表 enrichInflight 是给「一次只跑一路后台任务」用的,
	// 捏着它横跨十几秒会把同一首歌的其它自愈路径一起挡掉。
	go settleDeviceCover(ctx, key, artist, title, album, bundleID)
}

// deviceCoverSettleDelays:头一张设备封面拿到之后,再隔这些间隔各取一次(累计 3 / 8 / 16 秒),
// 拿到不一样的图就换上。App 换歌后自己也会复核封面,播放器换上真图时它会重写当前封面文件,这里才取得到新图。
//
// 播放器会**先推自己的占位图、真封面晚几秒才推**:酷狗 3.3.2 实测换歌后头 8 秒推的是它
// 内置的那张蓝底黑胶唱片(同一张图被本机十几首歌共用),之后才换成真封面;网易云「先给
// 占位图、匹配到曲库后换真图」是同一类行为。
//
// 只问一次不够,而且后果是**永久的**:占位图一旦落成 cover_source == "device",
// coverSwapAllowed 一律不再换源(见 artworkrelay.go 头注),这条记录的封面就此钉死,
// 网页中继和歌词管理里都会一直是那张唱片。「设备封面的身份由这一刻确实在播这首歌直接
// 保证」这条前提仍然成立 —— 不成立的是「它已经是这首歌的最终封面」。
//
// 登记在案的占位图 App 认得出、不会交过来(KnownPlaceholderArtwork.swift),但那张表按字节
// 指纹认图、播放器换一版内置图就静默失效,所以不能替代这里:按时间多问几次是通用的 —— 没有这个
// 行为的播放器只是多几次 sha256 比对,同一张图 saveDeviceArtwork 连盘都不会重写。
var deviceCoverSettleDelays = []time.Duration{3 * time.Second, 5 * time.Second, 8 * time.Second}

// settleDeviceCover 把上面那张间隔表跑完,换上一次就收工——占位图换成真封面是一次性事件。
//
// 换歌之后这个 goroutine 不会往上一首的记录里写东西:每一档都完整走一遍
// deviceCoverUpgradePass,那里面的 fetchNowPlayingArtwork(核对此刻在播的就是这首歌)和
// 写入前重读条目两道守卫各自都拦得住。
//
// 整张表跑完条目还不是设备封面(播放器一直没报图、报的是占位图、或报的是别的歌)时记一行,
// 说明这首为什么停在网络封面上。
func settleDeviceCover(ctx context.Context, key, artist, title, album, bundleID string) {
	var waited time.Duration
	for _, d := range deviceCoverSettleDelays {
		select {
		case <-ctx.Done():
			return
		case <-time.After(d):
		}
		waited += d
		// 首次解析还没提交(条目还不在、或还是先上屏的那份):等它落定再问,不白用一档。解析要二十来秒的歌,不等的话三档
		// 全落在提交之前,开头那张过渡图就此钉住。
		if !waitForCommittedEntry(ctx, key) {
			return
		}
		if deviceCoverUpgradePass(ctx, key, artist, title, album, bundleID) {
			return
		}
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if ok && e.CoverSource != "device" && e.CoverSource != "player" {
		log.Printf("device artwork: no usable artwork from %s for %q within %s, keeping the %q cover",
			bundleID, key, waited, e.CoverSource)
	}
}

// deviceCoverCommitWait / deviceCoverCommitPoll:设备封面沉降那几档等首次解析提交最多等多久、多久看一次。单测调小。
var (
	deviceCoverCommitWait = 60 * time.Second
	deviceCoverCommitPoll = time.Second
)

// waitForCommittedEntry:等到 key 这一条已经落盘、不是先上屏的那份(enrichProvisional)。等到了返回 true;到期还没有
// (解析失败、条目被删)或 ctx 结束返回 false。
func waitForCommittedEntry(ctx context.Context, key string) bool {
	deadline := time.Now().Add(deviceCoverCommitWait)
	for {
		enrichMu.Lock()
		_, ok := enrichCache[key]
		committed := ok && !enrichProvisional[key]
		enrichMu.Unlock()
		if committed {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(deviceCoverCommitPoll):
		}
	}
}

// deviceCoverUpgradePass 是上面两条路共用的一趟:问一次设备封面,够格就写进条目。
// 返回值 = 这一趟真的换了封面。没换(没问到、条目还不在、跟现有的是同一张、清晰度
// 顶不掉现有的)一律 false,调用方据此决定还要不要再等下一档。
func deviceCoverUpgradePass(ctx context.Context, key, artist, title, album, bundleID string) bool {
	deviceCoverURL := deviceCoverURLIfFresh(ctx, true, bundleID, artist, title)
	if deviceCoverURL == "" {
		// 交来的可能是视频帧:不当封面,只记下来(见 03 章决策 39)。
		noteVideoFrame(key, bundleID, artist, title)
		return false
	}
	// 先在锁外把"现有封面"读出来 —— 下面的清晰度判据要发 HTTP 取一次远程候选来比指纹,
	// 那是几百毫秒的事,绝不能捏着 enrichMu 做(整份缓存的读写都在这把锁上)。
	enrichMu.Lock()
	existing, exists := enrichCache[key]
	// 提前提交的歌词条目会被首次解析的最终提交整条覆盖,在它上面换封面会被冲掉、而这一档
	// 又已经算成功收工——当作条目还没落盘,留给下一档。
	provisional := enrichProvisional[key]
	enrichMu.Unlock()
	if !exists || provisional || existing.CoverURL == deviceCoverURL || coverSettled(existing) {
		return false
	}
	cover, source, public := deviceCoverURL, "device", ""
	if own := playerCoverFor(ctx); smallDeviceCoverYieldsTo(deviceCoverURL, own) {
		// 小设备封面碰上播放器自带的那张:用自带的,同 applyDeviceOrPlayerCover。
		if existing.CoverURL == own {
			return false
		}
		cover, source = own, "player"
	} else {
		// 低分辨率的设备封面不该盖掉"同一张图的高清版"。判据表见 coverquality.go 头注;这处跟首次解析那处必须同时存在,
		// 见 applyDeviceCoverUpgrade 头注。
		if !deviceCoverOverridesCandidate(ctx, deviceCoverURL, existing.CoverURL) {
			return false
		}
		// 设备封面要顶掉现有封面时先看播放器自带的那张:跟设备封面是同一张图、更清晰就用它(见 playerCoverOverDevice)。
		if pc := playerCoverOverDevice(ctx, deviceCoverURL, existing.CoverURL); pc != "" {
			cover, source = pc, "player"
		} else {
			// 顶掉的候选跟设备封面是同一张图时留下它的地址,给 App 外面用(见 devicePublicCover)。要取远程图,在锁外做。
			public = devicePublicCover(ctx, deviceCoverURL, existing.CoverURL)
		}
	}
	// 取色只为网页,没配中继就不算,理由同 resolveTrackEnrichment 里那处。
	accent := ""
	if webRelayConfigured() {
		accent = dominantColor(ctx, cover)
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok || enrichProvisional[key] || e.CoverURL == cover || e.CoverURL != existing.CoverURL || coverSettled(e) {
		// 这段等待期间条目被"歌词管理"删掉了,(竞态)另一路已经写过同一张封面或换了别的封面(上面是拿旧封面比的),
		// 或者后台补封面刚给专辑定下了封面——都不该再写,换了的留给下一档按新封面再比。
		enrichMu.Unlock()
		return false
	}
	e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = cover, source, album, accent
	if public != "" {
		e.PublicCoverURL, e.PublicCoverFor = public, deviceCoverURL
	}
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	requestEnrichSaveFor(key)
	// 封面刚换了,动态封面原来的结论是对着旧封面核的:按这张重核。
	recheckMotionCoverAgainstCurrentCover(ctx, key, title, album)
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
	return true
}

// recheckMotionCoverAgainstCurrentCover:拿这条记录此刻在用的那张封面重核一次动态封面,返回写没写。结论已经是对着这张核的
// (motionVerdictCurrent)不动;这一轮没查成(在飞 / 请求失败)不写;核的这段时间封面又换了、条目被删了也不写,新封面另走这条路。
// 调用方:换上设备封面的那一刻(applyDeviceCoverUpgrade);外围补全这一轮的结论落不到留用的那张封面上时(给 resolveTrackEnrichment
// 传的 deviceCoverURL 恒为空串,设备封面的条目 fresh 永远对不上);播到这首时结论已作废(recheckPlayingMotionCover);后台补封面
// 那一遍(coverSweepRecheckStaleMotion)。网络 I/O 全在锁外。
func recheckMotionCoverAgainstCurrentCover(ctx context.Context, key, title, album string) bool {
	artist, _, _ := splitEnrichKey(key)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok || motionVerdictCurrent(e) {
		return false
	}
	had := e.MotionCoverURL != ""
	if !e.fillMotionCover(ctx, artist, title, album) {
		return false
	}
	enrichMu.Lock()
	cur, still := enrichCache[key]
	if !still || cur.CoverURL != e.CoverURL {
		enrichMu.Unlock()
		return false
	}
	cur.MotionCoverChecked = e.MotionCoverChecked
	cur.MotionCoverURL = e.MotionCoverURL
	cur.MotionPreviewURL = e.MotionPreviewURL
	cur.MotionCoverIdentityVerified = e.MotionCoverIdentityVerified
	cur.MotionCoverFor = e.MotionCoverFor
	enrichCache[key] = cur
	enrichDirty = true
	enrichMu.Unlock()
	requestEnrichSaveFor(key)
	// 「这首为什么没有 / 为什么不动了」靠这几行查,只记挂上和摘掉,重新核过还是同一段的不记。
	switch {
	case had && e.MotionCoverURL == "":
		log.Printf("motion-cover: %s no longer matches its cover, motion artwork dropped", key)
	case had:
	case e.MotionCoverIdentityVerified:
		log.Printf("motion-cover: %s attached via album identity (preview frame differs from the cover)", key)
	case e.MotionCoverURL != "":
		log.Printf("motion-cover: %s matched its own cover, motion artwork attached", key)
	}
	return true
}

// backfillPeripheralFields 只补外围链接(Apple/QQ/网易云/主色),绝不动歌词/封面来源/
// 人工修正标记等身份字段——这些一旦解析出结果就永久生效,不该被这条自愈路径悄悄改掉。
func backfillPeripheralFields(ctx context.Context, key, artist, title, album string, durationSecs float64) {
	// 开跑时的改动序号:这一轮顺带收下歌词之前要核对这期间没人改过这条(见 adoptBackfilledLyrics)。
	enrichMu.Lock()
	stamp := enrichEditStampLocked()
	skipLyrics := peripheralBackfillSkipsLyrics(enrichCache[key])
	enrichMu.Unlock()
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	// ctx:播放时那一处没有"停止"入口(补的是**已存在**条目的外围字段,不是首次搜索的占位行),
	// 传 context.Background();后台补封面(coversweep.go)传进来的那个进程退出时取消。
	// 这一轮自己发的请求有没有一个成功,决定记不记一次补全次数(见下面 PeripheralRetryCount 那一行)。只数经这个 ctx
	// 发出去的(withNetworkRound):放歌时中继、收听上送这些请求一直在成功,混进来的话断网也会被记成补过一次。
	ctx, networkRound := withNetworkRound(ctx)
	if skipLyrics {
		ctx = withPeripheralOnly(ctx)
	}
	// Kaset 放过的这首:挑封面要用 YouTube Music 给它登记的专辑(coverAlbumForTrack),videoId 从缓存里存过的歌曲页取。
	enrichMu.Lock()
	ctx = withCachedYouTubeMusicVideoIDLocked(ctx, key)
	enrichMu.Unlock()
	ctx = withLearnedAliasSelf(ctx, key)
	// deviceCoverURL 传空串,理由见 resolveTrackEnrichment 参数注释:补的是已存在条目的
	// 外围字段,补的这一刻播的多半已经是别的歌,不能假装这是"正在播的这首"。设备封面的
	// 升级另有专门路径(applyDeviceCoverUpgrade),不走这里。
	fresh := resolveTrackEnrichment(ctx, artist, title, album, durationSecs, "", nil, lyricsDecisionPathPeripheral)
	// 换封面判定用的专辑名:播放器没报时是 Apple 目录回填的那个(刚才 resolveTrackEnrichment 里已经同步查过,
	// 这里只读缓存)。必须在取 enrichMu 之前算,理由见 trackEnrichment 里同一行的注释。
	coverAlbum := coverAlbumForTrack(ctx, artist, title, album, durationSecs)
	// QQ 专辑 / 歌手 mid 的现查是网络请求(单曲详情:几个网页主机各 6 秒,再退客户端网关,没取到不缓存),
	// 同样必须在拿 enrichMu 之前做完,锁里只认这里查好的结果。
	qqMids := lookupPeripheralQQMids(ctx, key, fresh)
	// 设备封面能不能让位给这一轮的候选,要读本地图、取远程候选比对(color.go,最长 4 秒):在拿 enrichMu 之前算好。
	// 锁里只在封面还是算的时候那一张时才用这个结果,变了就不换(下一轮外围补全再判)。
	enrichMu.Lock()
	pre := enrichCache[key]
	enrichMu.Unlock()
	// 这一轮还是没封面:拿存着的歌词判决里胜出的那个源自带的封面兜底(见 winnerCandidateCover)。要读旁路文件,在拿
	// enrichMu 之前做。
	winnerCover, winnerSource, winnerAlbum := "", "", ""
	if pre.CoverURL == "" && fresh.CoverURL == "" {
		winnerCover, winnerSource, winnerAlbum = winnerCandidateCover(withDecisionDetails(key, pre.LyricsDecision), album)
	}
	preDeviceURL, preUpgradable := "", false
	if pre.CoverSource == "device" && fresh.CoverURL != "" {
		preDeviceURL, preUpgradable = pre.CoverURL, deviceCoverUpgradable(pre.CoverURL, fresh.CoverURL)
	}
	// 留下来的设备封面还没记网上的同一张图时,拿这一轮的远程候选核对一次(见 devicePublicCover):换上设备封面那一刻没记的
	// 存量条目靠这里补。只在本来就要补外围的时候顺带做,不为它新开补全。
	prePublic := ""
	if preDeviceURL != "" && !preUpgradable && pre.PublicCoverFor != preDeviceURL {
		prePublic = devicePublicCover(ctx, preDeviceURL, fresh.CoverURL)
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		// 补的这段时间里,这条被用户在"歌词管理"里删掉了——不要把它复活回去。
		enrichMu.Unlock()
		return
	}
	// 只在这次真的拿到值时才覆盖。无条件赋值的话,一次网络抖动/某个源临时挂掉,fresh 里
	// 这些字段就是空的,于是把之前已经解析好的封面、主色和各平台链接**抹成空**,而下面几行
	// 的 e.TS = time.Now().Unix() 又把节流时间戳推进去,10 分钟内不会再补,封面就这么消失了。
	// 紧挨着的 CanonicalArtist 本来就有 `== ""` 守卫,这几行属于同一层保护。
	//
	// 封面四件套一起判(主色是从这张封面算出来的,不能出现"新封面配旧主色"的错配;
	// cover_album 记的是这张封面属于哪张专辑,换封面就得跟着换)。
	// "这一轮拿到了新封面"之外还要过 coverSwapAllowed —— 见那个函数的注释。
	rejectedNeteaseCover := fresh.CoverSource == "netease" && neteaseResultRejected(e, fresh)
	if !rejectedNeteaseCover && coverSwapAllowedWith(e, fresh, coverAlbum, func(deviceURL, candidateURL string) bool {
		return preDeviceURL != "" && deviceURL == preDeviceURL && candidateURL == fresh.CoverURL && preUpgradable
	}) {
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor, e.CoverSettled =
			fresh.CoverURL, fresh.CoverSource, fresh.CoverAlbum, fresh.AccentColor, fresh.CoverSettled
	}
	// 没封面,或留下的那张明确是另一张专辑的(coverOfAnotherAlbum):换成歌词胜出那个源自带、专辑对得上的;换掉旧封面时主色清空。
	if winnerCover != "" && winnerCover != e.CoverURL && (e.CoverURL == "" || coverOfAnotherAlbum(e, album)) {
		if e.CoverURL != "" {
			e.AccentColor = ""
		}
		e.CoverURL, e.CoverSource, e.CoverAlbum = winnerCover, winnerSource, winnerAlbum
	}
	// 只在封面还是核对的那张设备封面时记(这期间换了封面,这份核对就不算数)。
	if prePublic != "" && e.CoverURL == preDeviceURL {
		e.PublicCoverURL, e.PublicCoverFor = prePublic, preDeviceURL
	}
	// 动态封面校验的结论只对 fresh.CoverURL 有效,见 motionCoverFreshResultAppliesTo。
	motionCheckMatchesRetainedCover := motionCoverFreshResultAppliesTo(e.CoverURL, fresh)
	// 存量 QQ 封面提档:早期拼的 QQ 封面 URL 写死 300x300,而同一个 mid 换个路径段就能拿到
	// 800(见 qqCoverAtEdge)。这是**同一张图的另一档**、不是换封面 —— 所以刻意放在
	// coverSwapAllowed 之外,也不动 CoverSource/CoverAlbum/AccentColor(主色从缩略图算,
	// 跟档位无关)。纯字符串换算,不发任何请求。专辑定下的(coverSettled)不提档:地址一换定下的记录就作废,下一遍后台补封面
	// 又把它换回同组定下的那一份,来回翻。
	if !coverSettled(e) {
		e.CoverURL = qqCoverAtEdge(e.CoverURL, qqCoverMaxEdge)
	}
	if fresh.AppleURL != "" {
		e.AppleURL = fresh.AppleURL
	}
	e.QQURL = peripheralQQURL(e.QQURL, fresh.QQURL)
	// 专辑/歌手 mid:按**最终生效**的那个 QQURL 里的 songmid(锁外已经查好,见 lookupPeripheralQQMids)。
	// 锁外读到的条目跟这一刻的不是同一首 songmid 时不认,留给下一轮。
	if e.QQAlbumMid == "" || e.QQSingerMid == "" {
		if songMid := qqMidFromURL(e.QQURL); songMid != "" && songMid == qqMids.songMid {
			if e.QQAlbumMid == "" {
				e.QQAlbumMid = qqMids.albumMid
			}
			if e.QQSingerMid == "" {
				e.QQSingerMid = qqMids.singerMid
			}
		}
	}
	if fresh.SpotifyURL != "" {
		e.SpotifyURL = fresh.SpotifyURL
	}
	// 动态封面:fresh 对着 e 留用的这张封面核出了结论(MotionCoverChecked,没查成不置这一位)就整组换上;fresh 说没有、e 却挂着
	// 一段时不换,留给下面的重核(fillMotionCover 会再拿那段跟这张封面比)。fresh 核的不是这张封面(motionCheckMatchesRetainedCover
	// 为假)时一位都不写。这个函数对已有条目逐字段挑着覆盖,动态封面那几位不在这里列出来就在函数返回时丢了。
	takeFreshMotion := motionCheckMatchesRetainedCover && fresh.MotionCoverChecked &&
		(fresh.MotionCoverURL != "" || e.MotionCoverURL == "")
	if takeFreshMotion {
		e.MotionCoverURL, e.MotionPreviewURL = fresh.MotionCoverURL, fresh.MotionPreviewURL
		e.MotionCoverChecked, e.MotionCoverIdentityVerified = true, fresh.MotionCoverIdentityVerified
		e.MotionCoverFor = fresh.MotionCoverFor
	}
	// 这一轮的结论一位都没落下时,得拿这条记录自己那张封面补算一次,判据与理由见
	// motionCoverNeedsRecheckAgainstOwnCover。真正的重算放在锁外(见函数末尾),这里只
	// 记一个待办位 —— 网络 I/O 不进 enrichMu。
	needsMotionRecheck := motionCoverNeedsRecheckAgainstOwnCover(
		takeFreshMotion || (motionCheckMatchesRetainedCover && !fresh.MotionCoverChecked), e)
	if fresh.NeteaseURL != "" && !neteaseResultRejected(e, fresh) {
		e.NeteaseURL = fresh.NeteaseURL
	}
	if e.CanonicalArtist == "" {
		e.CanonicalArtist = fresh.CanonicalArtist
	}
	mergeEntryISRCs(&e, fresh)
	// 这一轮认出了播放器没报的歌手就换上(专辑跟着这一轮的);认不出不清旧的。
	if fresh.InferredArtist != "" {
		e.InferredArtist, e.InferredAlbum = fresh.InferredArtist, fresh.InferredAlbum
	}
	if e.DurationSecs <= 0 {
		e.DurationSecs = fresh.DurationSecs
	}
	// 条目原本没歌词、这一轮顺带搜到了:收下,规则见 adoptBackfilledLyrics。这期间被改过就不收。
	lyricsAdopted := !enrichEditedSinceLocked(key, stamp) && adoptBackfilledLyrics(&e, fresh)
	if lyricsAdopted {
		log.Printf("lyrics: peripheral backfill filled empty lyrics for %q (source=%s score=%d)", key, e.LyricsSource, e.LyricsScore)
	}
	// 只推自己那个节流时间戳。**不要**去动 e.TS —— 那是这条记录的解析时刻,歌词重搜拿它
	// 当起算点,推它等于每补一次外围字段就把歌词重搜往后拖 10 分钟(见 TS 字段的注释)。
	e.PeripheralTS = time.Now().Unix()
	e.PeripheralPending = false
	// 补没补上都记一次,上限靠它生效(见 peripheralBackfillMaxAttempts);这一轮自己的请求一个都没成功
	// (断网、全被熔断跳过或被本地出站闸挡下)不记。见 09 章决策 195。
	if attempts, failures := networkRound(); lyricsRoundConfirmsNoResult(attempts, failures) {
		e.PeripheralRetryCount++
	}
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	if lyricsAdopted {
		// 收下了歌词:正在播的这首当场落盘(同首次解析),并导出歌词文件。
		commitEnrichSave(key)
		exportLyricsFilesFor(key)
	} else if cur := enrichPlayingKey.Load(); !coverSweepSaveDeferred(ctx) || (cur != nil && *cur == key) {
		// 后台补封面那一遍攒着存(见 coversweep.go);正在播的这首照常当场存,别的歌攒着(见 enrichsave.go)。
		requestEnrichSaveFor(key)
	}
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
	// 拿这条记录真正在用的那张封面重新核对一次动态封面。必须在锁外、在 saveEnrichCache 之后:它自己会重新取锁、自己落盘,
	// 并且会发两次 HTTP(取首帧 + 取封面)。专辑没动画或还没查过时 fillMotionCover 读本地缓存就返回了。
	if needsMotionRecheck {
		recheckMotionCoverAgainstCurrentCover(ctx, key, title, album)
	}
}

// deviceCoverURL 非空时,是 poller.go 在"确认新曲目开始播放"那一刻现场用
// fetchNowPlayingArtwork 拿到、已经落盘的本地封面(file:// URL,
// CoverSource 写 "device")——这份数据的身份由"读取时刻本身"保证,不需要再跟网易云/
// Apple/QQ 三个源的猜测结果比较,直接用,不进下面那整套按专辑名文字匹配择优的级联。
// 只有 resolveEnrichAsync(首次解析,唯一能保证这一刻确实对应"正在播放的这首歌"的
// 调用点)会传非空值;backfillPeripheralFields(补的是已有条目,补的时候播的多半已经
// 是别的歌)、covercli.go(手动 CLI,没有实时播放上下文)都传空串,走原有级联。
//
// decisionPath 是这一轮决策存档与 trace 标的来路(lyricsDecisionPath*),由调用方按自己是哪条路径给。
func resolveTrackEnrichment(ctx context.Context, artist, title, album string, durationSecs float64, deviceCoverURL string, onLyrics func(enrichEntry), decisionPath string) enrichEntry {
	// 播放器没报专辑时歌词拿 YouTube Music 登记的专辑去搜、去打分(见 lyricsSearchAlbum)。只进歌词这一段:封面那段照旧
	// 按真实入参 album,登记专辑由 finishTrackEnrichment 自己取来挑封面,不写成 cover_album。
	searchAlbum, listedAlbum := lyricsSearchAlbum(ctx, album, "", durationSecs, artist, title)
	// 统一转成简体再往下传给 NetEase/QQ/酷狗/LRCLIB 的搜索接口——这几个平台的曲库/搜索
	// 索引都是简体中文,本地 Apple Music 标签如果是繁体,拿繁体原文直接发起搜索请求会
	// 完全查不到候选(不是匹配质量差,是搜索接口本身没命中)。match.go 的 normLoose 里
	// 已经有一处 toSimplified,但那处解决的是"拿到候选之后比较标题/专辑字符串"这一步,
	// 跟这里"搜索关键词本身要先转换才发得出去"是两个不同阶段,不能互相替代。这里只转换
	// 本函数内部用来发起搜索请求的局部变量,不改 enrichCache 的 key(那个在更上层的
	// trackEnrichment 里用原始、未转换的 artist/title/album 构造,必须跟 Apple Music
	// 原始标签保持逐字节一致,否则同一首歌反复播放会对不上同一条缓存记录)。
	ctx = withSearchQueryOriginal(ctx, artist, title, searchAlbum)
	// 交给各歌词源的歌名带上编号(见 withLyricSourceTitle);封面、链接、打分照旧用 title。
	ctx = withLyricSourceTitle(ctx, lyricSearchTitleFor(ctx, title), artist, title, searchAlbum)
	artist, title, searchAlbum = searchQueryFields(artist, title, searchAlbum)
	// 报了专辑时 searchAlbum 就是归一化过的它。
	if album != "" {
		album = searchAlbum
	}
	var e enrichEntry
	// 网易云:封面(国内可加载,苹果 mzstatic 国内已无 CDN)+ 单曲链接 + 带轴歌词,一次搜索出。
	// 只要网易云在「歌词来源」里开着就查一次——封面/跳转链接搭它的车。
	// 用户在设置里关掉网易云歌词源时这一路**不查**(「没启用肯定就不查」压过下面那句
	// "基础展示信息无条件"):封面落到第②级 Apple Music,网易云链接留空,
	// needsPeripheralBackfill 对此不算缺项。下面几段注释里的"无条件"都以此为前提。
	// 开着歌词功能时,这次网易云查询在 scoredLyricCandidates 内部,跟 qq/酷狗/Musixmatch/
	// LRCLIB 四个源一起并发发出去 —— 别改回"本函数先同步查一遍、查完那四个才开始跑",那等于
	// 把网易云自己最坏能到小三十秒的串行耗时原样叠加在整体等待时间最前面。只有歌词功能关掉、
	// 根本不需要凑齐各个歌词源时,才单独查这一次。
	var ne neteaseInfo
	var scored []scoredLyricCandidateResult
	// 歌词:lyricSourceNames 里开着的源全部并发查一遍,
	// 不是查到第一个能用的就停——一首歌只在缓存未命中时解析一次,后续都直接读缓存,全部源都查一遍
	// 换来更可信的结果性价比很高。取分/并发/超时兜底细节见 scoredLyricCandidates
	// (同一份逻辑也供 desktop-lyrics 的"重新搜索候选歌词"手动纠正功能复用,搜索用的
	// CLI 子命令见 searchcli.go)——那条手动路径故意不受下面 pickLyricCandidate 的
	// "启用哪些源"过滤,理由见它的注释。
	//
	// 没有「歌词在线匹配」总开关(见 features.go 的说明),也没有"关掉时走 neteaseLookup 单查"
	// 那条分支 —— 它存在的唯一理由是"歌词关着、但封面和跳转链接还得要"。
	roundCtx, round := withLyricSourceRound(ctx)
	roundCtx, queries := withLyricQueryLog(roundCtx)
	// 首轮先上屏(见 provisionallyrics.go):首轮挑得出歌词、还要接着跑补查轮时,先把首轮的结果提交一份;正在播的这首
	// 还可能在首轮中途就先上屏(见 earlylyrics.go),回调最多来两次。
	// shownFirst:最早上屏的那一份用的是哪个源,给最终定案那行决策日志用;onScreen:最近一次上屏的那一份,
	// 最终定案跟它看不出差别时留着它(见 lyricsEntryFromScored)。
	var shownMu sync.Mutex
	var shownFirst string
	var onScreen *scoredLyricCandidateResult
	if onLyrics != nil {
		roundCtx = withProvisionalLyrics(roundCtx, func(ne neteaseInfo, scored []scoredLyricCandidateResult) {
			timer := newStepTimer()
			if p, picked := lyricsEntryFromScored(decisionPath, artist, title, searchAlbum, durationSecs, ne, scored,
				round.skippedSources(), queries.queries(), true, "", nil); picked != nil {
				p.LyricsListedAlbum = listedAlbum
				p.LyricsNativeVideoID = kasetNativeLyricsVideoID(ctx, round, scored)
				timer.mark("build")
				shownMu.Lock()
				if shownFirst == "" {
					shownFirst = picked.Source
				}
				shown := *picked
				onScreen = &shown
				shownMu.Unlock()
				onLyrics(p)
				timer.mark("commit")
				timer.logIfSlow("provisional lyrics for "+artist+" - "+title, slowCommitThreshold)
			}
		})
	}
	if peripheralOnly(ctx) {
		// 周边补全、条目已有歌词:只单查网易云拿封面和链接,见 peripheralonly.go。
		if lyricSourceEnabled("netease") {
			ne = neteaseLookup(ctx, artist, title, searchAlbum, durationSecs)
		}
		e = neteasePeripheralFields(ne, durationSecs)
		return finishTrackEnrichment(ctx, e, nil, artist, title, album, durationSecs, deviceCoverURL)
	}
	if localIsInstrumentalVersion(title, album) {
		return instrumentalVersionEnrichment(ctx, artist, title, album, searchAlbum, durationSecs, deviceCoverURL, onLyrics)
	}
	ne, scored = scoredLyricCandidates(roundCtx, artist, title, searchAlbum, durationSecs)
	// 封面/主色/平台跳转链接是基础展示信息,不做成可关闭的开关,以下逻辑无条件执行——
	// 唯一的例外是上面说的:网易云作为歌词源被关掉时 ne 是空的,这里自然拿不到它的封面和链接。
	// 决策固化(见 decision.go):首次解析是最要紧的一份 —— 缓存永久保留,这一刻的运气
	// 就是这首歌以后一直显示的东西,不记下来事后无从复盘。
	shownMu.Lock()
	provisionalSource, lastShown := shownFirst, onScreen
	shownMu.Unlock()
	e, picked := lyricsEntryFromScored(decisionPath, artist, title, searchAlbum, durationSecs, ne, scored,
		round.skippedSources(), queries.queries(), false, provisionalSource, lastShown)
	e.LyricsListedAlbum = listedAlbum
	e.LyricsSourcesEnabled = round.enabledSources()
	recordISRCs(&e, recordingISRCsFromScored(lyricSourceISRC(ctx, artist, title, searchAlbum), scored, durationSecs, title, album))
	e.LyricsNativeVideoID = kasetNativeLyricsVideoID(ctx, round, scored)
	// 首次解析这里拿不到 key(它由上层 trackEnrichment 用**未转简体**的原始标签拼),
	// 用查询词拼一个等价形状 —— trace 是流水账,要的是"能对上是哪首歌",不参与任何查找。
	traceLyricsDecision(artist+"|"+title+"|"+album, e.LyricsDecision)
	if picked == nil {
		// 没有任何源给出可用歌词——查一下有没有依据说这是纯音乐(scored 里搭车带着的
		// 联网标记,或汽水客户端的本地队列缓存;见 instrumentalFromScored 与
		// Instrumental 字段定义处的注释),命中就记下来,UI 侧才能把这种情况跟
		// "真的谁都没搜到"区分开显示。
		if ok, _ := instrumentalFromScored(scored, artist, title, album, durationSecs); ok {
			e.Instrumental = true
		}
		// 纯文本(无时间戳)兜底自动采纳——跟 rescoreLyrics 里那段同一个理由/同一条
		// "只在为空时写、绝不覆盖"规矩(见 PlainLyrics 字段定义处的完整说明和
		// plainTextFallbackFromScored 头注)。first-resolve 和 rescore 是两个独立
		// 写入点,共享挑选逻辑但各自决定何时调用。
		if !e.Instrumental && e.PlainLyrics.IsZero() {
			if lyrics, source := plainTextFallbackFromScored(scored); lyrics != "" {
				e.PlainLyrics, e.PlainLyricsSource = bt(lyrics), source
			}
		}
	}
	// 歌词一选定就先交给 onLyrics 提前提交上屏:下面封面 / 规范歌手名 / 主色 / 各平台链接 / 动态封面
	// 这一串是串行的联网请求,都不影响歌词本身(挑选只看 scored)。没拿到歌词时不提前提交,
	// 交给调用方原有的「全空不写入」守卫判断。
	if onLyrics != nil && !e.Lyrics.IsZero() {
		timer := newStepTimer()
		onLyrics(e)
		timer.mark("commit")
		timer.logIfSlow("early lyrics for "+artist+" - "+title, slowCommitThreshold)
	}
	// 读音在出词之后才补:日 / 韩 / 中要起 lyrics-romanize 子进程(中文一首实测 0.7~1.1 秒),App 播放时
	// 本来就用同一个函数现算兜底,出词那一刻不需要预生成的这份。lyricsEntryFromScored 只做了粤拼。
	e.maybeGenerateRoma()
	return finishTrackEnrichment(ctx, e, scored, artist, title, album, durationSecs, deviceCoverURL)
}

// instrumentalVersionEnrichment:本地歌名或专辑带伴奏 / 纯音乐 / Instrumental 限定词(localIsInstrumentalVersion)时
// resolveTrackEnrichment 走这里。各源的整份歌词打分时一律判废(scoreRejectInstrumentalTrack),检索只会落到纯音乐,
// 所以不检索歌词:先交一份标了纯音乐的条目上屏,封面和链接只单查网易云,再走外围字段那一段。手动搜索、重新匹配
// 不经这里,照常检索。见 09 章决策 216。
func instrumentalVersionEnrichment(ctx context.Context, artist, title, album, searchAlbum string, durationSecs float64,
	deviceCoverURL string, onLyrics func(enrichEntry)) enrichEntry {
	log.Printf("lyrics: %q - %q is an instrumental version, marked instrumental without searching", artist, title)
	if onLyrics != nil {
		onLyrics(enrichEntry{Instrumental: true, DurationSecs: durationSecs})
	}
	var ne neteaseInfo
	if lyricSourceEnabled("netease") {
		ne = neteaseLookup(ctx, artist, title, searchAlbum, durationSecs)
	}
	e := neteasePeripheralFields(ne, durationSecs)
	e.Instrumental = true
	return finishTrackEnrichment(ctx, e, nil, artist, title, album, durationSecs, deviceCoverURL)
}

// finishTrackEnrichment 是 resolveTrackEnrichment 选完歌词之后的外围字段那一段(规范歌手名、封面级联、
// 主色、各平台链接、动态封面)。scored 只用来给封面专辑回填提供旁证,周边补全只查网易云时传 nil。
func finishTrackEnrichment(ctx context.Context, e enrichEntry, scored []scoredLyricCandidateResult,
	artist, title, album string, durationSecs float64, deviceCoverURL string) enrichEntry {
	// canonical_artist 解析链路,依次尝试、命中就用。两级都按「歌手本身」查,不按「这一首曲目」匹配:
	// ①MusicBrainz(按歌手整体查、按歌手整体缓存,见 musicbrainz.go 顶部注释);
	// ②resolveGenericArtistCanonicalName(见下面那处调用)。
	//
	// 别把「网易云本次搜索这首歌带回的歌手名」(ne.Artist)和「QQ 音乐同款」(qqArtist)加回来当中间两级:它们是按
	// 曲目匹配的,搜歌搜错了就把错那首歌的歌手名当成这首歌的 canonical 写进缓存,而且没有任何置信度门槛(①有
	// musicbrainzMinScore=90 把关)。代价是一部分歌手没有 canonical_artist(展示时退回播放器原始标签),这是想要的
	// 方向:宁可不归一,也不要把错的名字写进缓存(它还会经 EnrichCacheStore 显示在「歌词管理」窗口里)。
	e.CanonicalArtist = canonicalArtistViaMusicBrainz(ctx, artist)
	// 播放器没报歌手:找封面、拼链接改用按「歌名 + 时长」认出来的那位(inferredidentity.go)。
	lookupArtist := artist
	if artist == "" {
		if id, ok := inferIdentityByTitle(ctx, title, durationSecs); ok {
			e.InferredArtist, e.InferredAlbum = id.artist, id.album
			lookupArtist = id.artist
		}
	}
	// Apple Music/iTunes Search 的匹配结果下面 e.AppleURL 也要用,这里提前算出来复用同一份
	// (appleMusicMatchCached 本身按 key 缓存,提前调不会多打一次请求)。
	//
	// 封面级联里 Apple 排在 QQ 前面:网易云曲库缺失某艺人(整个目录都查不到,版权原因)时,
	// QQ 对这首歌唯一收录的版本常常是精选集(qqCoverFallback 会用 albumScore 判定它不对版,
	// 但判完也没有更好的 QQ 候选可选,只能将就)。resolveAppleMusicMatch 的专辑感知匹配
	// (先按"歌手+专辑名"整体搜索定位到专辑,查不到再退化成拉专辑完整曲目表本地比对标题,
	// 见 apple.go 注释)明显更强,而且这份数据本来就要为跳转链接查一次。所以级联是:网易云
	// 没有 → 先试 Apple Music 的封面,Apple 也没有 → 才退到 QQ(维持"至少给个官方封面"的兜底)。
	//
	// 封面解析用的专辑名(albumhint.go,03 章决策 16):播放器没报专辑时用 Apple 目录按
	// 「署名 + 曲名 + 时长」回填的那个 —— 同步等它(appleAlbumHintSync),这一步过了就不会再来。
	// 旁证 = 缓存里已有的 + 这一轮 MusicBrainz 统一名 + 这一轮歌词胜出候选报的署名
	// (pickLyricCandidate 是纯函数,下面正式挑那次再调一遍不冲突)。
	// coverAlbum 只进下面的**挑选过程**;写 e.CoverAlbum 的几处仍各写来源自己报的专辑名 /
	// 真实入参 album,回填名绝不落盘成 cover_album(理由见 coverAlbumForTrack 头注)。
	//
	// MV 标题(parseVideoTitle):曲库按视频标题搜不到,封面按拆出来的「演唱者 / 歌名」查、时长当未知(MV 比
	// 录音室版长)。翻唱 / 特辑不拆:查不到就没有封面,不拿原唱的封面顶(03 章)。
	coverArtist, coverTitle, coverDuration := lookupArtist, title, durationSecs
	if v := parseVideoTitle(artist, title); v.Kind == videoTitleMusicVideo {
		coverArtist, coverTitle = v.Artist, v.Song
		if v.DurationUnknown {
			coverDuration = 0
		}
	}
	// 占位专辑名(「单曲发行」)按没报专辑,见 albumIsPlaceholder。
	coverAlbum := coverAlbumOrNone(album)
	if coverAlbum == "" {
		coverAlbum = kasetListedAlbumFor(youTubeMusicVideoIDFrom(ctx), durationSecs, artist, title)
	}
	// 给专辑定下的封面按显示的专辑找(entryListedAlbum 那一套):播放器报的,没报时 YouTube Music 登记的;Apple 回填的是猜的,不算。
	listedAlbum := coverAlbum
	if listedAlbum == "" {
		listedAlbum = strings.TrimSpace(e.YouTubeMusicAlbum)
	}
	if coverAlbum == "" {
		coverAlbum = appleAlbumHintSync(ctx, coverArtist, coverTitle, coverDuration,
			coverAlbumCorroboration(coverArtist, coverTitle, album, e.CanonicalArtist, pickLyricCandidate(scored)))
	}
	appleMatch := appleMusicMatchCached(ctx, coverArtist, coverTitle, coverAlbum, coverDuration)
	if e.CoverURL == "" && appleMatch.cover != "" {
		e.CoverURL = appleMatch.cover
		e.CoverSource = "apple"
		e.CoverAlbum = appleMatch.album
	}
	// 网易云排在 Apple 前面是为了「国内加载得出来」,不是为了「对得上正在播的这张专辑」。这两件事会打架:专辑本身
	// 没上网易云、只有先行单曲的时候,pick() 那条"唯一精确同名候选,专辑名对不上也认"的规则(见 netease.go,刻意保留)
	// 会命中单曲版、拿回单曲封面,于是同一张专辑在"最近记录"里混着两种封面。见 09 章决策 11。
	//
	// 所以:网易云那张明确属于另一次发行(albumScore=0)、而 Apple 那张对得上时,用 Apple 的。只换封面,网易云的
	// 歌词/译文/罗马音照旧 —— 那些跟"哪张发行"无关。
	if e.CoverSource == "netease" &&
		preferAppleCoverOverNetease(e.CoverAlbum, appleMatch.album, appleMatch.cover, coverAlbum) {
		e.CoverURL, e.CoverSource, e.CoverAlbum = appleMatch.cover, "apple", appleMatch.album
	}
	// 网易云、Apple 都拿到了封面,但没有一个**精确**对得上本地专辑时,也要问一次 QQ——
	// 常见场景是本地专辑名是某次单独发行的"豪华版/Explicit"重制,网易云、Apple 曲库里
	// 这首歌还挂在更早的原版专辑下,只有 QQ 音乐(往往正是用户实际在用的播放器)收录了新版。
	//
	// 门槛是 `albumScore(...) < 200`,不能写成 `== 0`,更不能写成 `e.CoverURL == ""`:
	// 网易云那张《JTW西游记》是本地《JTW 西游记 (Gold) [Explicit]》的子串,albumScore 判它
	// "宽松包含"给 100 分,`== 0` 这道闸压根不会打开;而 `CoverURL == ""` 更宽松,网易云/
	// Apple 只要给出**任意**结果(哪怕对不上版)这个条件就再也不成立。"< 200" 跟
	// coverNeedsAlbumCheck 的门槛一致(理由见那边的注释)—— 只有逐字相等/仅大小写繁简差异的
	// 200 分才算真的对上版,100 分的"宽松包含"跟完全不沾边的 0 分一样都值得再问一次 QQ。
	// qqCoverFallback 内部本来就按 albumScore 避开精选集/合辑,多问一次成本低、收益高。
	if e.CoverURL == "" || (coverAlbum != "" && albumScore(e.CoverAlbum, coverAlbum) < 200) {
		// 网易云、Apple Music 都没有(或都没能给出对版封面)时的最后一道兜底——QQ
		// 音乐同一首歌的官方版封面,双重校验歌手名(搜索结果+详情接口各查一次)避免
		// QQ 侧的仿冒号蒙混过关;传入 album 让 qqCoverFallback 内部按 albumScore
		// 避开精选集/合辑顶替原始专辑封面。
		// 第二个返回值(QQ 侧的歌手名)刻意丢弃:它不该进 canonical_artist(理由见上面
		// 解析链路那段)。第三个是这张封面在 QQ 上所属的专辑,记进 cover_album:对不上本地专辑时
		// 下面 coverOfAnotherAlbum 才判得出来(见 03 章决策 47)。
		qqCover, _, qqAlbum := qqCoverFallback(ctx, coverArtist, coverTitle, coverAlbum)
		// 拿到了、而且不比已有那张更不对版才换(qqFallbackCoverTaken)——QQ 也没有时保留网易云/Apple 那张
		// "对不上版但好歹有图"的兜底,好过把已有封面抹成空。
		if qqFallbackCoverTaken(e, qqCover, qqAlbum, coverAlbum) {
			e.CoverURL, e.CoverSource, e.CoverAlbum = qqCover, "qq", qqAlbum
		}
	}
	// 网易云/Apple/QQ 各自的单曲检索都试过了,仍然没能给出精确对版的封面时,最后问一次
	// 缓存里的"同专辑邻居"——实体专辑的曲目理论上共用同一张封面,比"再挑一个自己打分也
	// 不够精确的候选"更可信。见 siblingAlbumCover 的注释(典型场景:QQ 搜索对某首歌唯一
	// 收录的那条记录,专辑名文本上对得上,挂的封面却是另一款合集版,跟同专辑其它曲目
	// 实际的单张封面是两张图)。
	if coverAlbum != "" && albumScore(e.CoverAlbum, coverAlbum) < 200 {
		if url, source, albumVerified := siblingAlbumCover(lookupArtist, title, coverAlbum); url != "" {
			e.CoverURL, e.CoverSource = url, source
			// cover_album 只在**借来的那张图自己就核实过归属**时才盖(见 siblingAlbumCover
			// 头注):借一张不认领归属的 qq 图、却盖上本地专辑名,等于凭空造出一条"归属已核实"
			// 的证据 —— App 侧就靠这个字段决定要不要越过 Last.fm 自带图,而引擎侧撞上
			// 200 分就再也不复查。不够格时**清空**(不是留着旧值):这张图确实不是原来那条
			// cover_album 说的那张专辑的。
			if albumVerified {
				// 写真实入参 album(播放器没报就是空),**不**写 coverAlbum:回填名是猜的,
				// 不认领归属(见 coverAlbumForTrack 头注)。
				e.CoverAlbum = album
			} else {
				e.CoverAlbum = ""
			}
		}
	}
	// 三源和同专辑邻居都没给出封面:按双语曲名拆出的那段、歌词判决里认下的歌手写法、ISRC 在 Deezer 上的那条补查(coverretry.go)。
	fillMissingCover(ctx, &e, scored, artist, title, album, durationSecs, coverArtist, coverTitle, coverAlbum, coverDuration)
	// 后台补封面已经给这张专辑定下了封面:照定下的那张。下面的设备封面、播放器自带的、歌词候选自带的都不再顶掉它(coverSettled)。
	if s, ok := settledAlbumCover(lookupArtist, listedAlbum); ok {
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.CoverSettled = s.CoverURL, s.CoverSource, s.CoverAlbum, s.CoverURL
	}
	if deviceCoverURL == "" {
		deviceCoverURL = lateDeviceCover(ctx, artist, title)
	}
	applyDeviceOrPlayerCover(ctx, &e, deviceCoverURL, album)
	// 上面都没给出封面,或给出的那张明确是另一张专辑的:歌词胜出的那个源自带的、专辑对得上的那张(见 winnerCandidateCover、
	// coverOfAnotherAlbum)。
	if e.CoverURL == "" || coverOfAnotherAlbum(e, album) {
		if cover, source, coverAlbum := winnerCandidateCover(e.LyricsDecision, album); cover != "" {
			e.CoverURL, e.CoverSource, e.CoverAlbum = cover, source, coverAlbum
		}
	}
	if e.CanonicalArtist == "" {
		// MusicBrainz 那一级没能给出统一歌手名(常见于 title/album 本身就跨语言对不上
		// 文本的 feat. 曲目)时,改用 resolveGenericArtistCanonicalName(不按曲目、按歌手
		// 本身查:先查 artistAliasTable 那几条真实残留的手工登记,再试 MusicBrainz 的中文
		// 别名,最后试 QQ 音乐自己的歌手搜索建议),见其头注。
		e.CanonicalArtist = resolveGenericArtistCanonicalName(ctx, artist)
	}
	if e.CoverURL != "" && webRelayConfigured() {
		// 封面主色调,供网页按专辑动态配色(浏览器读跨域封面像素会被 CORS 挡,故服务端算)。
		//
		// 没配状态中继就整个不算:这个字段**只有网页读**(relay.go 的 "accent" 键 →
		// web/index.html),App 侧一处都不读 —— 悬浮歌词/灵动岛那套主色是 App 自己从
		// 本地封面像素算的,跟这个字段无关。算一次要发一趟 HTTP 取 64x64 缩图 + 解码 +
		// 逐像素扫描,每首新歌一次(accentCache 只在进程内按 cover URL 去重),没有消费者
		// 时全是白烧。
		//
		// 配套改动在 needsPeripheralBackfill 的 missing 判定——那里必须同步收窄,
		// 否则没配中继时 AccentColor 恒空 → 恒判"缺" → 每条记录白补满 5 轮、每轮把开着的
		// 歌词源全部重查一遍。理由与前两次同类事故见那里的注释。
		e.AccentColor = dominantColor(ctx, e.CoverURL)
	}
	// 认出来的歌手对应的专辑:QQ 那条没报的话用挑封面时那个专辑名(播放器没报专辑时是按署名 + 曲名 + 时长回填的)。
	if e.InferredArtist != "" && e.InferredAlbum == "" {
		e.InferredAlbum = coverAlbum
	}
	// 各平台单曲跳转链接。Apple Music:有已校验的目录锚点就用它的页面(appleCatalogLinkFor),没有才用上面封面兜底那步
	// 按歌名搜出来的 appleMatch(同一个 key 缓存,不是重新发请求),歌曲页按合作署名挑(songURL);QQ 经 smartbox;Spotify 搜索链接。
	e.AppleURL = appleMatch.songURL()
	if u := appleCatalogLinkFor(artist, title, album, durationSecs); u != "" {
		e.AppleURL = u
	}
	e.QQURL = qqMusicURL(ctx, lookupArtist, title, album, durationSecs)
	// 顺手把专辑/歌手 mid 一起拿到,不用等下一轮外围回填(首次解析本来就在打一堆请求,
	// 多这一个不影响体感;拿不到就留空,菜单那两行自己会隐藏)。
	e.QQAlbumMid, e.QQSingerMid = qqSongCatalogMids(ctx, qqMidFromURL(e.QQURL))
	if title != "" {
		e.SpotifyURL = "https://open.spotify.com/search/" + neturl.QueryEscape(lookupArtist+" "+title)
	}
	e.fillMotionCover(ctx, lookupArtist, title, album)
	return e
}

// fillMotionCover:对着这条记录现在的封面(CoverURL)核出动态封面结论(见 motioncover.go),整组记下(recordMotionVerdict)。
// 返回这一轮有没有定论;没有(专辑页没抓成、取图失败)时原样不动,下一轮再试。结论已经是对着这张封面核的
// (motionVerdictCurrent)直接返回。
//
// 现在认的专辑给不出动画、而这条原来挂着一段时,再拿那段的首帧跟现在这张封面比一次,还是同一张图就留着它:Apple 链接、
// 目录锚点会换成同一张专辑的别的版本(标准版 / 加长版),那个版本不一定有动画。
func (e *enrichEntry) fillMotionCover(ctx context.Context, artist, title, album string) bool {
	if motionVerdictCurrent(*e) {
		return true
	}
	before := *e
	if !e.motionVerdictFromAlbum(ctx, artist, title, album) {
		return false
	}
	if e.MotionCoverURL != "" || before.MotionCoverURL == "" || before.MotionPreviewURL == "" {
		return true
	}
	matched, verified := motionCoverMatchesCover(ctx, before.MotionPreviewURL, e.CoverURL)
	switch {
	case !verified:
		e.MotionCoverURL, e.MotionPreviewURL = before.MotionCoverURL, before.MotionPreviewURL
		e.MotionCoverChecked, e.MotionCoverIdentityVerified = before.MotionCoverChecked, before.MotionCoverIdentityVerified
		e.MotionCoverFor = before.MotionCoverFor
		return false
	case matched:
		e.recordMotionVerdict(before.MotionCoverURL, before.MotionPreviewURL, false)
	}
	return true
}

// motionVerdictFromAlbum:按这条现在认的 Apple 专辑核动态封面,返回有没有定论(同 fillMotionCover)。
//
// 专辑 ID 两条来路,按可信度排:① 已校验的目录锚点(App 状态里的目录曲目 ID → iTunes lookup),只有 Apple Music 播的目录
// 曲目才有;② 这条记下的 apple_music_url 里那个 ID,覆盖所有播放器,但来自文字匹配,可能指向另一个版本的专辑(03 章决策 16)。
// ② 敢用全靠两道图像校验(首帧比对 / 专辑身份核验,并联,见 decideMotionCover):错的专辑给出的首帧和官方封面跟这条的
// 封面都不会是同一张。两条来路都没有专辑 ID 时整组清掉:没有可以核的东西。
func (e *enrichEntry) motionVerdictFromAlbum(ctx context.Context, artist, title, album string) bool {
	albumID, viaAnchor := appleCatalogAlbumIDFor(artist, title, album)
	if !viaAnchor {
		albumID = motionCoverAlbumIDFromAppleURL(e.AppleURL)
	}
	if albumID <= 0 {
		e.clearMotionVerdict()
		return true
	}
	mc, done := motionCoverFor(albumID)
	if !done {
		return false
	}
	if mc.Master == "" {
		e.recordMotionVerdict("", "", false)
		return true
	}
	// 取图失败(网络抖动 / CDN 限流 / 解码失败)跟「真的比过、两张图确实不是同一张」必须分开:前者不落结论,
	// 不然一次纯网络问题会被钉成「这条没有动态封面」。
	frameMatched, verified := motionCoverMatchesCover(ctx, mc.PreviewFrame, e.CoverURL)
	if !verified {
		return false
	}
	// 首帧没过时才问专辑身份:首帧过了就已经放行,多问一次只是多下一张图。
	identity := motionIdentityNotAsked
	if !frameMatched {
		identity = motionCoverIdentityFor(ctx, albumID, e.CoverURL)
	}
	switch decideMotionCover(frameMatched, identity, viaAnchor) {
	case motionDecisionPending:
		return false
	case motionDecisionReject:
		e.recordMotionVerdict("", "", false)
	case motionDecisionAcceptIdentity:
		e.recordMotionVerdict(mc.Master, mc.PreviewFrame, true)
	default:
		e.recordMotionVerdict(mc.Master, mc.PreviewFrame, false)
	}
	return true
}

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
// features().LyricsSources 闸挡掉,同样落到"不换"。保守是对的:那是两个独立的意图,
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

// pickLyricCandidate 从 scoredLyricCandidates 返回的全量候选里,按设置里的"启用哪些源"+"挑选算法"选出最终采用的一条,
// 只用于自动解析路径(resolveTrackEnrichment)。手动搜索(`search-lyrics`)要保留完整排序列表给用户挑,不复用这个函数,
// 但"启用哪些源"口径一致(searchcli.go 的 filterEnabledLyricSources)。
func pickLyricCandidate(scored []scoredLyricCandidateResult) *scoredLyricCandidateResult {
	usable := lyricCandidateUsable(scored)
	if features().LyricsSourceMode == lyricsModePriority {
		// 先找顺序里第一个给出干净候选的源;各源给的都带扣分项时,退回顺序里第一个能用的。见 09 章决策 296。
		if p := priorityPick(scored, func(c scoredLyricCandidateResult) bool { return usable(c) && priorityCandidateClean(c) }); p != nil {
			return p
		}
		return priorityPick(scored, usable)
	}
	var picked *scoredLyricCandidateResult
	bestScore := -1
	for i := range scored {
		if !lyricSourceEnabled(scored[i].Source) {
			continue
		}
		if !usable(scored[i]) || scored[i].Score <= bestScore {
			continue
		}
		bestScore = scored[i].Score
		picked = &scored[i]
	}
	return picked
}

// priorityPick:「顺序优先」按 priorityTiers 的先后,取第一个有 ok 候选的名次里分数最高的那条(scored 已按分数从高到低排)。
func priorityPick(scored []scoredLyricCandidateResult, ok func(scoredLyricCandidateResult) bool) *scoredLyricCandidateResult {
	for _, tier := range priorityTiers() {
		for i := range scored {
			if slices.Contains(tier, scored[i].Source) && ok(scored[i]) {
				return &scored[i]
			}
		}
	}
	return nil
}

// priorityTiers:「顺序优先」实际的取用先后,每一项是占同一个名次的几个来源。reAMP 同名 .lrc 排最前(用户自己放在歌曲旁边的
// 文件);用户顺序里的歌词源各占一个名次,关掉的跳过;「播放器自带歌词」那一项(lyricsPriorityPlayerLocal)展开成
// priorityPlayerCacheSources,顺序表里没有那一项时(没经过 resolveLyricsSourceOrder 的数据)排在最后。见 09 章决策 297。
func priorityTiers() [][]string {
	tiers := [][]string{{localFileLyricsSource}}
	placed := false
	for _, entry := range features().LyricsSourceOrder {
		switch {
		case entry == lyricsPriorityPlayerLocal:
			tiers, placed = append(tiers, priorityPlayerCacheSources), true
		case lyricSourceEnabled(entry):
			tiers = append(tiers, []string{entry})
		}
	}
	if !placed {
		tiers = append(tiers, priorityPlayerCacheSources)
	}
	return tiers
}

// priorityPlayerCacheSources:「播放器自带歌词」那一项包括的播放器本地歌词,同一个名次里按分数挑。
var priorityPlayerCacheSources = []string{kkboxLocalLyricsSource, spotifyLocalLyricsSource, amazonLocalLyricsSource,
	lxMusicLocalLyricsSource}

// priorityCandidateClean:这一条没带说明它可能是别的版本、别的录音或时间轴不对的扣分项(earlyLyricsPenaltyTerms;逐字加分
// 撤销那一项不算,它只是把逐字那份加分退回去)。智能算法里这些扣分让它比分落后;「顺序优先」不比分,得在挑源时直接跳过它。
func priorityCandidateClean(c scoredLyricCandidateResult) bool {
	for _, t := range c.ScoreTerms {
		if t.Kind != scoreTermWordTimingOverride && earlyLyricsPenaltyTerms[t.Kind] {
			return false
		}
	}
	return true
}

// priorityRank:「顺序优先」里这个来源排第几(priorityTiers 的下标,0 起);关掉了的、不认得的返回 -1。
func priorityRank(source string) int {
	return slices.IndexFunc(priorityTiers(), func(tier []string) bool { return slices.Contains(tier, source) })
}

// lyricCandidateUsable 给出「这一条能不能当冠军」的判定:分数不为负;这一轮有纯音乐标记时,吃过版本不符扣分的
// 也不算 —— 标记说这首没有词,这份词是给别的版本做的(见 09 章决策 194)。末句超过曲长的同理,词比这段录音还长
// (见 09 章决策 208)。同版本、没超长的歌词照常以正文为准。
//
// 纯音乐标记是正在放的播放器自己给的(playerSaysInstrumental)时一条都不算:它说的就是这一条录音,别的源的词只能是别的录音的。
func lyricCandidateUsable(scored []scoredLyricCandidateResult) func(scoredLyricCandidateResult) bool {
	instrumental := scoredHasInstrumentalMarker(scored)
	player := playerSaysInstrumental(scored)
	return func(c scoredLyricCandidateResult) bool {
		return c.Score >= 0 && !player && !(instrumental && (c.hasScoreTerm(scoreTermVersionTags) || c.hasScoreTerm(scoreTermDurationOvershoot)))
	}
}

// playerSaysInstrumental:这一轮的纯音乐标记是不是正在放的播放器自己给的(见 playerInstrumentalSource)。
func playerSaysInstrumental(scored []scoredLyricCandidateResult) bool {
	for _, c := range scored {
		if c.Instrumental && c.PlayerInstrumental {
			return true
		}
	}
	return false
}

// playerInstrumentalSource:正在放的播放器自己说这一条没有人声、它自己又没给出能用的歌词时,返回它自家的歌词源名,否则空串。
// 身份必须来自播放器的本地数据(同同源加权的准入,见 lyricCandidate.identityFromLocalClient),搜出来的不算;解析的得是它在放的这首
// 或它的待播队列(forPlayingTrack,见 playerSignalApplies)。播放器自己有这一条的歌词(有词的伴奏版,只有不带时间戳的也算)时照常用歌词。
// 见 09 章决策 210。
func playerInstrumentalSource(raw map[string]lyricSourceResult, results []scoredLyricCandidateResult) string {
	for _, src := range []string{lyricSourceNetease, lyricSourceQQ, lyricSourceSoda, lyricSourceAppleMusic, spotifyLocalLyricsSource} {
		r, ok := raw[src]
		if !ok || !r.forPlayingTrack || !playerOwnsLyricSource(src) {
			continue
		}
		claims, local := r.noVocals || r.instrumental, r.identityFromLocalClient
		if src == lyricSourceNetease {
			claims, local = r.ne.PureMusic || r.ne.NoVocals, r.ne.FromLocalClient
		}
		if !claims || !local {
			continue
		}
		for _, c := range results {
			if c.Source == src && !c.Instrumental && (c.Score >= 0 || c.PlainTextOnly) {
				return ""
			}
		}
		return src
	}
	return ""
}

// playerOwnsLyricSource:这个歌词源是不是正在放的播放器自家的。Spotify 没有歌词源,它的本地歌词缓存算它自家的。
func playerOwnsLyricSource(src string) bool {
	if src == spotifyLocalLyricsSource {
		return playingPlayer() == playerSpotify
	}
	return isNativeLyricSource(src)
}

// scoredHasInstrumentalMarker:这一轮有没有源明确说这首是纯音乐(搭车的 Score:-1 标记,见 Instrumental 字段)。
func scoredHasInstrumentalMarker(scored []scoredLyricCandidateResult) bool {
	for _, c := range scored {
		if c.Instrumental {
			return true
		}
	}
	return false
}

func (c scoredLyricCandidateResult) hasScoreTerm(kind string) bool {
	for _, t := range c.ScoreTerms {
		if t.Kind == kind {
			return true
		}
	}
	return false
}

// scoredLyricCandidateResult is one scored lyric candidate — exported shape (JSON
// tags) so it doubles as the `lyrimuse-engine search-lyrics` CLI subcommand's stdout
// format for desktop-lyrics's manual "重新搜索候选歌词" picker.
type scoredLyricCandidateResult struct {
	Source       string `json:"source"`
	Lyrics       string `json:"lyrics"`
	LyricsTr     string `json:"lyrics_tr,omitempty"`
	LyricsTrLang string `json:"lyrics_tr_lang,omitempty"`
	// LyricsTrFrom:LyricsTr 是从哪个源的候选借来的(applyBorrowedTranslations),自带的是空串。写进条目时经 lyricsTrSourceFor。
	LyricsTrFrom  string `json:"lyrics_tr_from,omitempty"`
	LyricsRoma    string `json:"lyrics_roma,omitempty"`
	LyricsYRC     string `json:"lyrics_yrc,omitempty"`
	LyricsBG      string `json:"lyrics_bg,omitempty"` // 背景人声轨(YRC 语法,形状见 amllResult.bg),只有 amll / applemusic 会给。不参与打分。
	HasWordTiming bool   `json:"has_word_timing"`
	Score         int    `json:"score"`
	// ScoreTerms 是这个分数的构成明细(或者被判 -1 时的唯一那条原因),给"搜索候选歌词"
	// 弹窗把分数摊开显示用。只在那条手动搜索路径上有意义,自动解析路径不读它。
	ScoreTerms []scoreTerm `json:"score_terms,omitempty"`
	// ConsensusPeers:这条候选的正文跟**哪些**其它源高度一致(3-gram Jaccard >=
	// lyricConsensusSimThreshold),由 contentConsensusPeers 整批算好。打分侧只看它的长度
	// (>=2 → +250 / ==1 → +150),名单本身**不参与任何判据** —— 它存在的唯一理由是让
	// 决策留痕能回答"冠亚军这两份到底是不是同一份词"(理由见 contentConsensusPeers 头注)。
	// 因此加它不需要 bump lyricsScoringVersion。
	ConsensusPeers []string `json:"consensus_peers,omitempty"`
	// SourceReportedDurationSecs:源自己声明的曲长(秒),0=该源没给。只透传、不参与打分
	// ——给下一轮维度评测攒"源报版本同一性"数据(见 lyricCandidate 同名字段)。
	SourceReportedDurationSecs float64 `json:"source_reported_duration_secs,omitempty"`
	// BorrowedDurationSecs / BorrowedDurationFrom:amll 自己没有曲长,借能认定是同一条录音的那一家报的曲长和那家的源名
	// (amllCandidateDuration)。只给「搜索候选歌词」显示,不参与打分;别的源、借不到时为空。
	BorrowedDurationSecs float64 `json:"borrowed_duration_secs,omitempty"`
	BorrowedDurationFrom string  `json:"borrowed_duration_from,omitempty"`
	// ISRC:源报的这条录音的 ISRC(applemusic、deezer、petitlyrics 给),不参与打分。按 ISRC 补取未应答的源、取原产地曲名用(只认
	// applemusic、deezer 的),见 isrcretry.go、origintitle.go;借封面认同一条录音也看它(applyBorrowedCovers)。
	ISRC string `json:"isrc,omitempty"`
	// Songwriters:词曲作者名单(amll / applemusic 的 TTML,deezer 的 Lyrics.writers)。不参与打分,
	// 只用来写条目的 lyrics_songwriters(songwritersFromScored)。
	Songwriters []string `json:"songwriters,omitempty"`
	// Performers:演唱者标注(只有 musixmatch 给)。不参与打分,只用来写条目的 lyrics_speakers(speakersFromScored)。
	Performers []musixmatchPerformerSpan `json:"-"`
	// Language:源自己上报的语种(songLanguageMandarin/songLanguageCantonese/空),
	// 透传,不参与打分,见 lyricCandidate.language。
	Language string `json:"language,omitempty"`
	// Title/Artist/Album/CoverURL 是这个源实际匹配到的歌名/歌手/专辑/封面(不参与
	// 打分,见 lyricCandidate 的同名字段注释)——"搜索候选歌词"弹窗和「解析决策」面板
	// 靠这几个字段展示每条候选具体对应哪首歌/哪个版本,不是只看来源名字。
	//
	// 别按"LRCLIB / QQ 这两个源天生没有封面"去设计:实测网易云/酷狗/QQ/LRCLIB **四个源
	// 都可能返回封面**(LRCLIB 那条是 iTunes 的 mzstatic 图),连被判 -1 的候选也有。仍然
	// 当"可能为空"处理(某个源某次没查到是正常的)。
	Title    string `json:"title,omitempty"`
	Artist   string `json:"artist,omitempty"`
	Album    string `json:"album,omitempty"`
	CoverURL string `json:"cover_url,omitempty"`
	// BorrowedCoverURL / BorrowedCoverFrom:自己没有封面时,借同一批里 ISRC 相同的那条候选的封面和它的源名
	// (applyBorrowedCovers)。只给「搜索候选歌词」显示缩略图,不参与打分,不进歌词判决、不当条目封面。
	BorrowedCoverURL  string `json:"borrowed_cover_url,omitempty"`
	BorrowedCoverFrom string `json:"borrowed_cover_from,omitempty"`
	// RetryMethod/RetriedTitle:这条候选是**标题反查改写标题之后**那一轮搜出来的。
	// RetryMethod 是 "title-from-album" / "title-from-artist-search",RetriedTitle 是改写后
	// 实际拿去搜的标题。两者都空 = 这条来自按本地标题的正常那一轮。
	//
	// 存在的理由是**事后可审计**:没有它,决策存档里只有 path/winner/candidates,完全看不出
	// "这条的标题被改写过" —— 而标题层面 Uchiagehanabi→春雷(错)和 Black Hole→黑洞里(对)
	// 是一模一样的形状,想统计"库里还有多少条是这么来的"根本无从下手。
	//
	// 只透传、不参与打分 —— 同 Title/Artist/Album,见 decision.go 头注那条"只写不读"铁律。
	RetryMethod  string `json:"retry_method,omitempty"`
	RetriedTitle string `json:"retried_title,omitempty"`
	// Instrumental 标记这不是一条真正的歌词候选,是"lrclib 明确说这首歌是纯音乐"这个
	// 信号本身,借这个结构体的 Score:-1(pickLyricCandidate/priority 模式都会跳过负分)
	// 混进 scored 列表里"搭车"传出去,不需要为了传这一个 bool 单独改
	// fetchScoredLyricCandidatesStreaming 的返回值签名(它被 searchcli.go 的手动搜索
	// CLI 和 resolveTrackEnrichment 两条路径共用,改签名影响面更大)。手动搜索那边会把
	// 这条标记过滤掉,不会当成一条空歌词的候选显示给用户,见 searchcli.go
	// filterEnabledLyricSources 旁边的过滤。
	Instrumental bool `json:"instrumental,omitempty"`
	// PlayerInstrumental:这条纯音乐标记是正在放的播放器自己给的(见 playerInstrumentalSource)。有它时别的源的词一条都不当冠军
	// (lyricCandidateUsable),合并多轮时也压过搜出来的标记。
	PlayerInstrumental bool `json:"player_instrumental,omitempty"`
	// TrackFoundNoLyrics 跟上面 Instrumental 同一个"搭车"套路(Score:-1 的伪候选,手动搜索
	// 那边过滤掉不显示成候选),传的是另一个结论:**这个源的曲库里有这首歌,但平台上没有
	// 歌词文本**。来龙去脉见 neteaseInfo.TrackFoundNoLyrics 的头注。
	//
	// 与 Instrumental 的两点不同,改这里之前先读完:
	// ① 语义不同(本来就没词 vs 暂时还没有词),所以**不能**合并成一个 bool;
	// ② 这种标记**可以同时存在多条**(网易云和 QQ 都命中没词就是两条),而 instrumentalMarker
	//    全局只留一条 —— 因为界面要如实列出"是哪几个源都找到了这首歌",不是只说一个。
	//
	// 这条标记会带上 Title/Artist/Album/SourceReportedDurationSecs(那个源实际匹配到的
	// 曲目元数据),让弹窗能把"匹配到的就是这首歌"摆出来 —— 要回答的疑问正是"是不是搜错了"。
	TrackFoundNoLyrics bool `json:"track_found_no_lyrics,omitempty"`
	// PlainTextOnly:见 lyricCandidate.plainTextOnly 头注——true 时 Lyrics 装的是没有时间戳
	// 的纯文本。跟 Instrumental 不同,**不**在 filterEnabledLyricSources 里过滤掉:这是一条
	// 真实可用的候选(只是不能同步显示),"搜索候选歌词"弹窗要把它当成一个用户可以手动选中
	// 的选项展示出来,只是要在旁边标出"无时间戳",不能让用户误以为会像其它候选一样逐字/
	// 逐行同步。
	PlainTextOnly bool `json:"plain_text_only,omitempty"`
	// IdentityFromLocalClient:见 lyricCandidate.identityFromLocalClient(同源加权的准入条件)。合并各轮候选重打分时
	// 靠它还原(lyricCandidateFromScored),漏了的话跑过补救轮的歌全部丢掉同源那 250 分。
	IdentityFromLocalClient bool `json:"identity_from_local_client,omitempty"`
	// BakedTranslationLines:候选装配时从正文里摘掉、改挂到译文轨的"烘进正文的逐行中文译文"行数
	// (bakedtranslation.go)。0 = 这条候选没有这种形态。透传进决策留痕,让"这条候选行数
	// 怎么比另一个源少了一半 / 译文哪来的"能事后回答。不参与打分。
	BakedTranslationLines int `json:"baked_translation_lines,omitempty"`
	// unmasked:星号补成原词之前的原文(applyUnmaskedWords),没补过是 nil。
	unmasked *lyricUnmaskOrig
}

// lyricSearchDeadline 给 fetchScoredLyricCandidatesStreaming 整体加一个上限。各源的 HTTP client 都有自己的超时
// (4~10 秒不等),但单个源内部可能串行链好几次请求才死心(网易云最多试 4 个搜索变体 + 详情 + 歌词,最坏能吃掉小
// 三十秒;Musixmatch token 过期后重新申请若被限流会 sleep 10 秒再试),极端情况下一轮能卡到快一分钟。20 秒给足了
// 每个源独立超时的空间,到点还没回来的源这一轮就不参与候选。
//
// 迟到的结果不会被用上:缓存没有 TTL、歌词解析一次就永久保留,缓存命中直接返回存好的那条。所以这道截止线有代价:
// 首次解析时某个源超时缺席,这首歌就可能一直用着较差的那份。靠 needsLyricsRetry 兜:记下当初哪些源露过面,有启用的
// 源缺席就在之后择机重搜一次,分数更高才替换。
//
// 自动解析(resolveTrackEnrichment)和"歌词管理"的手动联网搜索(searchcli.go)共用这个常量。
const lyricSearchDeadline = 20 * time.Second

// scoredLyricCandidates 并发问全部歌词源(见 fetchScoredLyricCandidatesStreaming),逐条打分(scoreLyricCandidate),
// 返回按分数排好的全部候选(不只是冠军)。自动解析(resolveTrackEnrichment)和手动 `search-lyrics`(searchcli.go)都走
// 这里,"怎么给歌词源排名"全项目只有这一份实现。另返回原名那一轮的网易云结果:resolveTrackEnrichment 拿它取封面和
// 链接,不管最后的歌词候选来自哪一轮。歌手别名、首歌手变体、标题反查等补查轮见 scoredLyricCandidatesStreaming。
func scoredLyricCandidates(ctx context.Context, artist, title, album string, durationSecs float64) (neteaseInfo, []scoredLyricCandidateResult) {
	return scoredLyricCandidatesStreaming(ctx, artist, title, album, durationSecs, nil)
}

// scoredLyricCandidatesStreaming 是 scoredLyricCandidates 的流式版本(见
// fetchScoredLyricCandidatesStreaming 顶部注释)——onUpdate 一路透传给主查询和(如果
// 触发了)别名重试查询,所以手动搜索(searchcli.go)在别名重试这条冷门路径上也能看到
// 陆续到达的候选,不会因为切换成了 alias 重试就突然掉回"等全部查完才展示"。
func scoredLyricCandidatesStreaming(ctx context.Context, artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	// 同一次解析里被总截止掐掉过的源,补缺席的轮次不再为它跑(见 deadlinemiss.go)。重入时沿用外层那一份。
	ctx = withLyricDeadlineMisses(ctx)
	ne, results := fetchScoredLyricCandidatesStreaming(ctx, artist, title, album, durationSecs, onUpdate)
	// 播放器自己说这一条是纯音乐时不再换身份重搜:搜回来的词一条都不能用(lyricCandidateUsable)。手动搜索照常搜,那是用户要看候选。
	if playerSaysInstrumental(results) && !manualLyricSearch(ctx) {
		return ne, results
	}
	// 搬运频道形态的身份重入:浏览器里播 YouTube Music 上搬运频道上传的「Musiq Soulchild - Buddy (Official Video)」,
	// media-control 的 artist 位是频道名,真正的歌手写在曲名破折号前面。原身份九个源零候选;下面的别名轮只换歌手名
	// 不换曲名,对一个 YouTube 频道名也查不到别名(MusicBrainz 没有、本机学不到、appleTitleSearchIdentities 要曲名
	// 归一全等)。
	//
	// 做法:全部源一个能用的候选都没有(rescue)、且曲名能按第一个破折号拆成「署名 - 曲名」时
	// (albumHintTitleSplit,跟专辑回填共用同一条拆法,含剥尾括号的规则),把拆出来的身份
	// **整个重入本函数**一次 —— 别名轮 / 首歌手变体轮 / 标题反查轮全套照跑,打分与合并也都按
	// 拆出来的身份算,不会像 mergeLyricCandidateRounds 那样再按频道名重打分把候选判废。重入
	// 救回来就直接用它那份(ne 整份采用:这就是这首歌真正的署名,CanonicalArtist 跟着变成
	// 「Musiq Soulchild」,专辑回填的 1 档旁证也顺带有了);没救回来就当没发生过,原身份那批
	// 结果照旧往下走别名轮。递归有界:拆出来的曲名比原曲名少一段破折号,拆到没有破折号为止。
	// 「Song - Remastered」这类被拆错的歌名会白跑一遍重入(连同它的别名轮、变体轮、反查轮;救不回来时原身份的
	// 补查轮照样再跑一遍),候选过不了打分,不会多出错结果。
	// 翻唱重入那一轮不拆(coverPerformerOnly):拆出来的是曲名里别的名字,不是翻唱者。
	if !hasUsableLyricCandidate(results) && !coverPerformerOnly(ctx) {
		if splitArtist, splitTitle, durationUnknown, ok := titleSplitIdentity(artist, title); ok {
			log.Printf("lyrics: %q - %q has no usable candidate, retrying as title-split identity %q - %q", artist, title, splitArtist, splitTitle)
			splitCtx := withLyricQueryReason(ctx, lyricQueryReasonTitleSplit)
			// MV 的时长跟录音室版对不上,按未知打分(同 YouTube Music MV 的处理,02 章决策 33)。
			splitDuration := durationSecs
			if durationUnknown {
				splitDuration = 0
			}
			// 界面上原身份那批先留着(keepShownRoundUpdate):重入那一轮的源一个个应答,裸透传的话弹窗先缩成它的半截结果,
			// 救不回来时又跳回原来那批。
			splitNe, splitResults := scoredLyricCandidatesStreaming(splitCtx, splitArtist, splitTitle, album, splitDuration, keepShownRoundUpdate(onUpdate, results))
			if hasUsableLyricCandidate(splitResults) {
				log.Printf("lyrics: title-split identity fallback succeeded: original=%q - %q identity=%q - %q candidates=%d sources=%v",
					artist, title, splitArtist, splitTitle, len(splitResults), lyricSourcesWithCandidates(splitResults))
				return splitNe, splitResults
			}
		}
	}
	// 翻唱重入:曲名写着翻唱者(「(Cover by X)」「Covered by X」)、原身份一个能用的候选都没有时,换成翻唱者
	// 整个重入一次,只认翻唱版本身,见 coverRescue。形态同上面的拆分重入:救回来就用,没救回来当没发生过。
	if !hasUsableLyricCandidate(results) {
		if coverNe, coverResults, ok := coverRescue(ctx, artist, title, album, durationSecs, keepShownRoundUpdate(onUpdate, results)); ok {
			return coverNe, coverResults
		}
	}
	// 判据是"有没有能用的候选",不是"有没有候选"。写成 `len(results) > 0` 的话:各源都答了、但每一条都被
	// scoreLyricCandidate 判了 -1(不是逐行时间戳、语言对不上、整份只有署名行……)时 results 非空,重试根本不触发,
	// 最后拿一堆废候选收场 —— 而这恰恰是最该换个歌手名再试一次的情形。
	//
	// 第二个触发理由是 needsRomanizationRetry(见其头注):就算已经有可用歌词,只要还没拿到罗马音/语种信号、而歌词
	// 文字系统看着又需要,也值得换个艺人名再搜一次 —— QQ/酷狗(粤语语种信号)、网易云(日语罗马字)这三个源本来就在
	// altIdentities 的候选范围内。
	//
	// 别名轮的触发口径是:任何一个启用的源没给出可用候选、且手上有别名,就用别名再查一轮,而且那一轮只查缺着的那几个
	// 源(withLyricSourceOnly),已经答了的不重复打。别退回"一个能用的候选都没有才跑"那种救急口径:同一位歌手在不同
	// 曲库里写法不同时,一个源用原名答上了,别的源就再也等不到别名那一轮(见 09 章「检索前处理」的歌手别名重试)。
	// 缺着的源里剔掉"换名字也救不回来"的:传输层连不上的(sourcebreaker 的 transportFailureCodes)、
	// 地区限制 / 直连被堵这类带具体原因的 —— 见 lyricSourcesWorthAliasRetry。
	// 救急(一个能用的都没有)和缺罗马音信号这两种触发条件仍然全源重查;缺罗马音只驱动一轮。
	// 救急时提前跑的标题反查(见 titlereverse.go);没用上的在返回时取消。
	var titleSpec *titleReverseSpec
	defer func() { titleSpec.stop() }()
	rescue := !hasUsableLyricCandidate(results)
	romaRetry := needsRomanizationRetry(results)
	missing := lyricSourcesWorthAliasRetry(ctx, results)
	if rescue || romaRetry || len(missing) > 0 {
		notifyProvisionalLyrics(ctx, ne, results)
		// Apple 目录锚点给的权威署名排在手工别名表/MusicBrainz **前面**:它是这首歌
		// 自己的元数据(而不是"这位歌手一般叫什么"),证据强度更高,而且专辑署名恰好覆盖
		// 手工表和 MB 都够不到的那一类——演唱会嘉宾/群星合辑/客串曲目。见
		// appleCatalogSearchIdentities。appleStorefrontArtistIdentities 排在它后面、
		// MusicBrainz 前面:同样是"这张专辑自己的元数据"而不是通用推断,只是要求本地
		// 标签是 Apple Music 目录里真实存在的这首歌(见其头注),覆盖面比锚点(要求
		// 本地是从 Apple Music 播放、带 uniqueIdentifier)更广——手动搜索(searchcli.go)
		// 这条路径永远拿不到锚点,全靠这条补上。三组名字去重,免得同一个名字查两轮。
		// appleTitleSearchIdentities排在 storefront 之后、MusicBrainz 之前:同样是
		// "这一条录音自己的元数据",但它既不要锚点也不要专辑名,只靠曲名 + 时长对上 —— 浏览器里
		// 播 YouTube Music 的 MV(没有专辑名、艺人名被界面本地化成「王子」)只有它救得了;证据比
		// 前两条弱,所以门最严(曲名归一全等,外加本地专辑名或时长对得上),见其头注。
		// 这一条**只在救急(rescue)时**才问:原名一轮已经有源答出这首歌,说明本地署名本身没问题、
		// 缺的那几个源多半是曲库里没有,再拿曲名去 iTunes 反查署名只会多两到四次请求、还可能把同名
		// 同长的翻唱者带进来白查一轮;它要救的形状是"九个源全空"这种,别扩到"某个源缺"上。
		//
		// 翻唱重入那一轮(coverPerformerOnly)只用 retryArtistIdentities:前三路都是按曲名 / 专辑反推「这首歌是谁唱的」,
		// 对翻唱推出来的是原唱,换过去查到的就是原唱的词,不是这版翻唱。
		//
		// 商店署名、标题反查(iTunes)和 retryArtistIdentities(MusicBrainz 等)三路互不依赖,并发查;
		// 排序只由下面 dedupeArtistIdentities 的参数顺序决定,跟谁先回来无关。
		var catalogIdentities, storefrontIdentities, titleSearchIdentities []string
		var identityWG sync.WaitGroup
		if !coverPerformerOnly(ctx) {
			catalogIdentities = appleCatalogSearchIdentities(artist, title, album)
			samples := lyricSamplesForStorefront(results)
			identityWG.Add(1)
			go func() {
				defer identityWG.Done()
				storefrontIdentities = appleStorefrontArtistIdentities(ctx, artist, title, album, durationSecs, samples)
			}()
			if rescue {
				identityWG.Add(1)
				go func() {
					defer identityWG.Done()
					titleSearchIdentities = appleTitleSearchIdentities(ctx, artist, title, album, durationSecs)
				}()
			}
		}
		retryIdentities := retryArtistIdentitiesWithOrigin(ctx, artist)
		identityWG.Wait()
		altIdentities := dedupeArtistIdentities(
			identitiesFrom(catalogIdentities, lyricQueryOriginAppleCatalog),
			identitiesFrom(storefrontIdentities, lyricQueryOriginAppleStorefront),
			identitiesFrom(titleSearchIdentities, lyricQueryOriginAppleTitle),
			retryIdentities)
		if rescue {
			isrc := trustedRecordingISRC(artist, title, album, durationSecs, results)
			titleSpec = startTitleReverseSpec(ctx, artist, title, album, durationSecs, lyricSamplesForStorefront(results),
				isrc, titleReverseSungInChinese(results, isrc))
		}
		if len(altIdentities) > 0 {
			switch {
			case rescue:
				log.Printf("lyrics: %q has no usable candidate yet, trying alt identities: %v", artist, altIdentities)
			case romaRetry:
				log.Printf("lyrics: %q has no romanization signal yet, trying alt identities: %v", artist, altIdentities)
			default:
				log.Printf("lyrics: %q left %v without a usable candidate, trying alt identities for them: %v", artist, missing, altIdentities)
			}
		}
		romaTried := false
		// 救急时接下来几位别名并发开查,采用仍按顺序(见 rescuefanout.go)。支线问的源跟串行救急一样按
		// lyricSourcesWorthAliasRetry 剔掉换名字也救不回来的(连不上的、地区限制的……)。
		fan := newAliasFanout(ctx)
		rescueBase, rescueOnly := results, lyricSourcesWorthAliasRetry(ctx, results)
		rescueBranch := func(bctx context.Context, j int) (neteaseInfo, []scoredLyricCandidateResult) {
			bctx = withLyricQueryOrigin(withLyricQueryReason(withLyricSourceOnly(bctx, rescueOnly), lyricQueryReasonAliasRescue), altIdentities[j].origin)
			bNe, bRes := fetchScoredLyricCandidatesStreaming(bctx, altIdentities[j].name, title, album, durationSecs, nil)
			if hasUsableLyricCandidate(bRes) {
				notifyProvisionalLyrics(ctx, bNe, mergeLyricCandidateRounds(artist, title, album, durationSecs, rescueBase, bRes))
			}
			return bNe, bRes
		}
		// 手动搜索时补缺席源的别名轮也并发(见 rescuefanout.go 的 withManualLyricSearch)。支线按开查那一刻缺着的源问,
		// 取用时再按当时还缺着的源筛(下面 take 那一支)。
		missingParallel := manualLyricSearch(ctx)
		missingBranch := func(only []string) func(bctx context.Context, j int) (neteaseInfo, []scoredLyricCandidateResult) {
			return func(bctx context.Context, j int) (neteaseInfo, []scoredLyricCandidateResult) {
				bctx = withLyricQueryOrigin(withLyricQueryReason(withLyricSourceOnly(bctx, only), lyricQueryReasonAliasMissing), altIdentities[j].origin)
				return fetchScoredLyricCandidatesStreaming(bctx, altIdentities[j].name, title, album, durationSecs, nil)
			}
		}
		for i, alt := range altIdentities {
			// 只为补缺席的源跑的那几轮(首轮已经有可用候选、也不缺罗马音)有上限,见 lyricAliasMissingMaxTries。
			if !rescue && !romaRetry && i >= lyricAliasMissingMaxTries {
				break
			}
			// 这一位别名查哪些源:救急 / 缺罗马音 → 全部;否则只查还缺着的那几个。
			var only []string
			if !rescue && !romaRetry {
				only = missing
			}
			if romaRetry {
				romaTried = true
			}
			// 别名轮的来路按**这一位别名为什么被试**分三种,决策留痕里分得开:
			// 救急(全部源都没有能用的)/ 缺罗马音信号 / 只是某几个源没答。三者的后续处置完全不同 ——
			// 前两种全源重查、第三种只定向问 missing 那几个。
			aliasReason := lyricQueryReasonAliasMissing
			switch {
			case rescue:
				aliasReason = lyricQueryReasonAliasRescue
			case romaRetry:
				aliasReason = lyricQueryReasonAliasRoma
			}
			altCtx := withLyricQueryOrigin(withLyricQueryReason(withLyricSourceOnly(ctx, only), aliasReason), alt.origin)
			// onUpdate 包一层,理由跟下面"首歌手变体轮"的 mergedUpdate 一样(见那边注释):
			// 别名轮裸透传 onUpdate 的话,"搜索候选歌词"弹窗会先缩水成这一轮别名自己的部分结果
			// (从空开始,这一轮的源一个个陆续应答)、直到这一轮彻底跑完才恢复,中间态闪变 ——
			// 表现是原名一轮先展示出 LRCLIB 那条候选,别名轮开始后候选"刷没了",别名轮自己也查到
			// 同一条时又重新出现。原名这轮的候选本来就已经展示给用户看了,不该被"正在试的下一个
			// 身份、还没查完"的空/半状态覆盖掉。
			aliasUpdate := mergedRoundUpdate(onUpdate, artist, title, album, durationSecs, results)
			var altNe neteaseInfo
			var altResults []scoredLyricCandidateResult
			switch {
			case rescue:
				fan.ensure(i, len(altIdentities), rescueBranch)
			case missingParallel && !romaRetry:
				fan.ensure(i, min(len(altIdentities), lyricAliasMissingMaxTries), missingBranch(only))
			}
			// 补罗马音那一轮要全源重查:提前按「补缺席的源」开的那一支只问了缺着的源,不能拿来顶,走下面串行那条。
			if bNe, bRes, ok := fan.take(i); ok && (rescue || !romaRetry) {
				altNe, altResults = bNe, bRes
				if !rescue && !romaRetry {
					altResults = keepLyricSources(altResults, only)
				}
				if aliasUpdate != nil {
					// 先报一帧 0/n 再报整轮:提前跑完的支线一次交齐,不先报 0 的话接连两支都是 n/n,弹窗那边按
					// 「进度回跳 = 新一轮」数轮次(searchcli.go 的 emit)会少数一轮。
					n := enabledLyricSourceCount()
					aliasUpdate(altNe, nil, 0, n)
					aliasUpdate(altNe, altResults, n, n)
				}
			} else {
				altNe, altResults = fetchScoredLyricCandidatesStreaming(altCtx, alt.name, title, album, durationSecs, aliasUpdate)
			}
			// 这里必须用 `mergeLyricCandidateRounds(results, altResults)` 的**只增不减**合并语义,
			// 不能写成 `results = altResults` 整体覆盖(下面"首歌手变体轮"/"标题反查轮"两处同理)。
			// 原名这一轮(比如 lrclib 的纯文本兜底,分数 -1 但确实是候选)已经查到、且已经通过流式
			// onUpdate 展示给用户看了;只要别名轮自己没有重新查到同一个源(别名串对不上 lrclib 索引
			// 的原始歌手名、或这次 lrclib 网络请求恰好瞬时失败),整体覆盖就会让
			// 原来那条凭空消失,跟用户用的是不是同一个别名毫无关系,纯粹是这一轮的网络/索引匹配运气。
			// 合并之后:只有别名轮真的重新证明某个源可用时才顶替原名轮那一条,其余原样保留。
			merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, altResults)
			if hasUsableLyricCandidate(altResults) {
				log.Printf("lyrics: artist alias fallback succeeded: original_artist=%q alias=%q origin=%q title=%q candidates=%d sources=%v",
					artist, alt.name, alt.origin, title, len(altResults), lyricSourcesWithCandidates(altResults))
				// 封面/链接一并采用这一轮的结果。原名查空时 ne 里的封面和跳转链接本来就是空的,
				// 别名轮的 neteaseInfo 不能丢掉(丢掉的结果是"歌词有了、封面没了")。只在原来那份
				// 确实没有时才覆盖,不动已经拿到的东西。身份类别名是"同一个人换个写法",整份 ne
				// (含 Artist)可以采用——跟下面 credit 拆分变体轮"只许补封面/链接"不同。
				if ne.Cover == "" && altNe.Cover != "" {
					ne = altNe
				}
				// 不再直接 return:别名轮救回的可能也只有一个源,落到下面的
				// 首歌手变体轮再看要不要补——单人歌手在那里生成不出变体,行为不变。
				results = merged
			} else if len(results) == 0 && len(altResults) > 0 {
				// 这一轮也没有能用的,但如果原来那批是彻底空的,留下有内容的这批 ——
				// "搜索候选歌词"弹窗至少还能把它们摊开给用户看,附带被判废的原因。
				results = merged
				if ne.Cover == "" && altNe.Cover != "" {
					ne = altNe
				}
			}
			// 下一位别名只管仍然缺着的源;都齐了就停(不是"第一位别名一成功就 break")。
			// 缺罗马音这个理由只驱动一轮,不然信号一直不来会把每位别名都全源重查一遍。
			rescue = !hasUsableLyricCandidate(results)
			romaRetry = !romaTried && needsRomanizationRetry(results)
			missing = lyricSourcesWorthAliasRetry(ctx, results)
			if !rescue && !romaRetry && len(missing) == 0 {
				break
			}
		}
		fan.stop()
	}
	// 首歌手变体轮(「wherever u r」案):本地标签是多人合credit("UMI & 金泰亨")时,
	// LRCLIB 的结构化 artist_name 参数在服务端就查不到(404),网易云对不同歌手串还会选中
	// 不同版本的条目——这类**召回层**的失败,闸门放宽(lyricSourceArtistMatches)救不了,
	// 只能换检索词再查一轮。触发条件是"可用候选的来源数 < targetSources"而不是"全空":网易云一条 462 分
	// 候选就能把上面的别名重试短路,酷狗/QQ 的逐字候选永远没机会被看见。变体轮的结果**合并**
	// 进原串轮(按源去重、原串轮优先、统一按原串重打分),不是整体替换——见
	// mergeLyricCandidateRounds。
	// 阈值 3:只有两个源给出候选时,常见的是一条原标签查到的弱候选加一份播放器自带的,正是标题意译、
	// 艺名罗马化这类要靠后面几轮才救得回来的歌(阈值取值的影响面见 09 章决策)。计数不含播放器本地歌词
	// (见 usableLyricSourceCount)。
	// 触发阈值按**启用源数**封顶:只启用 1 个歌词源时可用源数上限就是 1,写死阈值会让多人
	// 合credit的歌每次都白跑最多 3 轮全源抓取(merged 计数永远追不上阈值,采纳门槛每次都把
	// 结果丢掉,网络却已经打出去了)。
	targetSources := 3
	if n := enabledLyricSourceCount(); n < targetSources {
		targetSources = n
	}
	if primary := lyricPrimaryQueryArtist(artist); primary != "" && usableLyricSourceCount(results) < targetSources {
		notifyProvisionalLyrics(ctx, ne, results)
		tryVariant := func(alt artistIdentity) {
			// onUpdate 包一层:变体轮期间把每次流式更新先与已有结果合并再上报。裸透传的话
			// "搜索候选歌词"弹窗(整行替换列表,见 searchcli.go 顶注)会先缩水成变体轮自己
			// 的部分结果、直到最终 emit 才恢复——中间态闪变,且闪出来的分数还是按变体串
			// 打的。自动解析路径 onUpdate 是 nil,不受影响。
			//
			// 已知的语义边界(刻意接受):base 这批候选如果来自上面身份别名轮,它们当初
			// 是按别名串打的分,这里合并重打分统一换回原串——两套裁判对语言闸
			// (isProbablyWrongLanguageLyrics,除了看 localArtist/localTitle 含不含汉字,也看
			// 候选源自己确认匹配到的 candidateArtist)可能给出不同判决。可达性极低(别名表登记
			// 的都是单人名,多人合credit整串登不进去),且采纳门槛要求可用源数净增,重打分变差
			// 只会导致"不采纳",不会污染已有结果。
			mergedUpdate := mergedRoundUpdate(onUpdate, artist, title, album, durationSecs, results)
			variantCtx := withLyricQueryOrigin(withLyricQueryReason(ctx, lyricQueryReasonPrimaryVar), alt.origin)
			altNe, altResults := fetchScoredLyricCandidatesStreaming(variantCtx, alt.name, title, album, durationSecs, mergedUpdate)
			merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, altResults)
			if usableLyricSourceCount(merged) <= usableLyricSourceCount(results) {
				return
			}
			log.Printf("lyrics: primary-artist variant added candidates: original_artist=%q variant=%q origin=%q title=%q usable_sources=%d->%d",
				artist, alt.name, alt.origin, title, usableLyricSourceCount(results), usableLyricSourceCount(merged))
			results = merged
			// 只许补封面/跳转链接,**绝不**整份采用 altNe:变体串是把合credit截成首歌手
			// 查出来的,altNe.Artist 是按"单人查询"放行的单人名,顺手带回去会经
			// resolveTrackEnrichment 的 e.CanonicalArtist = ne.Artist 把 "A & B" 缩窄成 "A"
			// (resolveNeteaseInfo 那道合唱守卫看的是本轮查询串,变体轮的查询串是单人名,拦不住)。
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
		tryVariant(artistIdentity{name: primary})
		if usableLyricSourceCount(results) < targetSources {
			// 首歌手本身没救回来时,再试首歌手的已知别名/MusicBrainz 中文名(比如本地
			// 标签 "Leah Dou & 别人" 截出 "Leah Dou" 还是查不到,换 "窦靖童" 再试)。
			// retryArtistIdentities 自带去重,最多两个变体,每轮 20s 兜底,上限可控。
			for _, alt := range retryArtistIdentitiesWithOrigin(ctx, primary) {
				tryVariant(alt)
				if usableLyricSourceCount(results) >= targetSources {
					break
				}
			}
		}
	}
	// 标题反查轮:上面几轮全部只换艺人名、标题原封不动,对"标题本身在平台间是意译"的场景无效(换成正确的中文艺人名
	// 再搜英文标题,几个源依然全部落空)。触发条件跟首歌手变体轮同一个"可用源数 < targetSources"(不是"全空":常见的
	// 是某个源靠原标题就查到了,hasUsableLyricCandidate 一直是真),放在最后是因为这是最贵的一道兜底(要多打两次网易云
	// 请求:搜专辑 + 浏览专辑全部曲目,见 retryTitleFromAlbum 的头注)。
	if usableLyricSourceCount(results) < targetSources {
		notifyProvisionalLyrics(ctx, ne, results)
		// 反查专辑本身也吃"英文艺人名+双语专辑名混一起查"这个坑(跟歌曲搜索同一个毛病,见 retryArtistIdentities
		// 头注):"Khalil Fong 梦想家 The Dreamer" 网易云专辑搜索零条,换成 "方大同 梦想家 The Dreamer" 才能搜到 ——
		// 所以搜专辑这一步也要用已知别名,不能直接拿原始艺人名去搜。
		//
		// 但也不能无条件把 titleArtist 换成 retryArtistIdentities 给出的别名:本地标签恰好就是网易云那张专辑记录的
		// artist 字段(neteaseAlbumIDByName 里 artistMatches 校验用的正是这个字段)时,换算出的别名反而是网易云用不上的
		// 写法,专辑 / 歌手反查两条兜底会全部落空。原串和别名哪个是网易云索引用的写法不能预先假定,只能都试、留误差更小的那个。
		// 反查那一步见 titleReverseLookup;救急时它已经跟别名轮同时提前跑过(titleSpec),样本没变就直接用。
		samples := lyricSamplesForStorefront(results)
		isrc := trustedRecordingISRC(artist, title, album, durationSecs, results)
		chinese := titleReverseSungInChinese(results, isrc)
		var correctedTitle, retryMethod, titleArtist string
		spec := titleSpec.take(samples, chinese)
		if spec != nil {
			correctedTitle, retryMethod, titleArtist = spec.corrected, spec.method, spec.artist
		} else {
			correctedTitle, retryMethod, titleArtist = titleReverseLookup(ctx, artist, title, album, durationSecs, samples, isrc, chinese)
		}
		if correctedTitle != "" && normLoose(correctedTitle) != normLoose(title) {
			titleUpdate := mergedRoundUpdate(onUpdate, artist, title, album, durationSecs, results)
			// retryMethod 的两个取值跟 lyricQueryReasonTitleAlbum / lyricQueryReasonTitleSearch
			// 逐字相同(常量就是照它定的),直接当来路用。
			titleCtx := withLyricQueryReason(ctx, retryMethod)
			var altNe neteaseInfo
			var altResults []scoredLyricCandidateResult
			if spec != nil && spec.fetched {
				altNe, altResults = spec.ne, spec.results
				if titleUpdate != nil {
					// 先报 0/n,理由同别名轮那一处。
					n := enabledLyricSourceCount()
					titleUpdate(altNe, nil, 0, n)
					titleUpdate(altNe, altResults, n, n)
				}
			} else {
				altNe, altResults = fetchScoredLyricCandidatesStreaming(titleCtx, titleArtist, correctedTitle, album, durationSecs, titleUpdate)
			}
			// 打上"这一轮是改写标题之后搜的"的标记,好让决策存档事后能认出来(见
			// scoredLyricCandidateResult.RetryMethod)。必须在 merge **之前**盖:merge 是按源
			// 挑基础轮/反查轮里更好的那条,盖晚了就分不清最终留下的是哪一轮的了。
			for i := range altResults {
				altResults[i].RetryMethod = retryMethod
				altResults[i].RetriedTitle = correctedTitle
			}
			merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, altResults)
			// **无条件采纳 merged**,不要加"usable 源数有提升才采纳"这道判据。merged 是
			// mergeLyricCandidateRounds 逐源合并出来的,那个函数自己已经保证"只增不减"(遇到
			// 同一个源,base 那边分数没到 0 分才会被 extra 换掉,见其内部 `cur.Score < 0 &&
			// r.Score >= 0` 那道闸),merged 天然是 results 的超集,不可能比 results 差。加了那道
			// 判据会问错问题:反查轮就算三个源都答了、但分数依旧是 -1(netease/qq/酷狗这次全被
			// 判定拒绝),usable 数确实没变,却白白多出三条"至少查过、能看到拒绝原因"的候选,被
			// 整批扔掉。而这轮 onUpdate 流式推送的正是这份 merged(titleUpdate 闭包里调的就是它)
			// ——用户在弹窗里眼睁睁看着候选一条条搜出来,收尾却把画面拉回反查前那份更窄的列表,
			// 表现就是"搜出来很多,最后又不见了"。"够不够格写日志"那件事留在判据后面 —— 多不多
			// 刷一行日志不影响正确性,丢不丢候选才是真正要紧的。
			if usableLyricSourceCount(merged) > usableLyricSourceCount(results) {
				log.Printf("lyrics: %s fallback added candidates: original_title=%q corrected_title=%q artist=%q usable_sources=%d->%d",
					retryMethod, title, correctedTitle, titleArtist, usableLyricSourceCount(results), usableLyricSourceCount(merged))
			}
			results = merged
			if ne.Cover == "" && altNe.Cover != "" {
				ne.Cover, ne.Album, ne.AlbumID = altNe.Cover, altNe.Album, altNe.AlbumID
			}
			if ne.SongURL == "" && altNe.SongURL != "" {
				ne.SongURL = altNe.SongURL
			}
			if retryMethod == lyricQueryReasonTitleStorefront {
				// 原产地曲名是按录音 ISRC 查出来的、那边的署名跟本地写法不同时,还缺着的源再拿原产地署名问一轮,见 titleReverseOriginArtistRound。
				ne, results = titleReverseOriginArtistRound(ctx, artist, title, album, durationSecs, samples, correctedTitle, ne, results, onUpdate)
			}
		}
	} else {
		// 可用源已经够数、走不到上面的标题反查时,缺着的源可能只是拿罗马字的本地曲名搜不到原文登记的这首歌,见 originTitleRound。
		ne, results = originTitleRound(ctx, artist, title, album, durationSecs, ne, results, onUpdate)
	}
	// 还缺着的源换一种曲名写法再问一次,见 titleVariantRound。
	ne, results = titleVariantRound(ctx, artist, title, album, durationSecs, ne, results, onUpdate)
	// 按 ISRC 补取:还缺着的 deezer / musixmatch 拿已被认可的 Apple Music 候选报的 ISRC 直取,见 isrcretry.go。
	// 放在所有轮次之后:别名轮可能才让 Apple Music 查到这首(曲库里署名跟本地不同)。
	if isrc, sources := isrcRetryPlan(ctx, results, durationSecs); isrc != "" {
		// 补来的候选正文要跟前面几轮已认可的对得上才并进来,中途推给界面的结果同样先筛,见 isrcRetryReference。
		ref := newISRCRetryReference(results)
		isrcUpdate := mergedRoundUpdate(onUpdate, artist, title, album, durationSecs, results)
		if isrcUpdate != nil {
			update := isrcUpdate
			isrcUpdate = func(vne neteaseInfo, vres []scoredLyricCandidateResult, done, total int) {
				kept, _ := ref.filter(vres)
				update(vne, kept, done, total)
			}
		}
		isrcCtx := withLyricQueryReason(withLyricSourceOnly(withRecordingISRC(ctx, isrc), sources), lyricQueryReasonISRC)
		_, isrcResults := fetchScoredLyricCandidatesStreaming(isrcCtx, artist, title, album, durationSecs, isrcUpdate)
		isrcResults, dropped := ref.filter(isrcResults)
		for _, d := range dropped {
			s, _ := ref.similarity(d)
			log.Printf("lyrics: isrc %s from applemusic: dropped %s candidate %q for %q - %q, lyrics match no accepted candidate (best similarity %.2f)",
				isrc, d.Source, d.Title, artist, title, s)
		}
		merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, isrcResults)
		if usableLyricSourceCount(merged) > usableLyricSourceCount(results) {
			log.Printf("lyrics: isrc %s from applemusic added candidates for %q - %q: usable_sources=%d->%d",
				isrc, artist, title, usableLyricSourceCount(results), usableLyricSourceCount(merged))
		}
		results = merged
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

// lyricSourcesWorthAliasRetry:这一轮**值得**拿别名再查一次的源 —— 启用、没给出可用候选、
// 而且失败原因不是"换个名字也没用"的那几类:传输层连不上(DNS / 连接 / 5xx,sourcebreaker 的
// transportFailureCodes,进程内累计)、lyricfind 的地区限制、Musixmatch 的限流 / 直连被堵
// (各自的 xxxLastFailureReasonNow 旁路)。amll 不发搜索请求(按曲目 ID 直取,按名字只在本地索引里找),
// 它在别名轮里会跟着网易云 / QQ 的别名结果拿到新 ID,所以照常算进来
// —— 网易云 / QQ 不在名单里时由 dropAMLLWithoutIDSource 剔掉。
// soda 照常算进来:它有自己的搜索(本地队列缓存拿不到 id 时的兜底,见 soda.go),别名确实
// 会影响命中 —— 本地那条路在别名轮里查空是预期的(署名换了就不再对应同一条录音),搜索
// 那条路则正是别名要救的场景。
// 同一次解析里被总截止掐掉过的源也剔掉(见 deadlinemiss.go):再问一遍多半又是等满一整轮截止。
// 这一轮因熔断冷却 / 后台暂停被跳过的源(ctx 上 lyricSourceRound 的跳过名单)也剔掉:补查轮里它照样
// 被跳过,为它去查别名只是白打别名解析那几次请求;这一轮会因此不追平打分版本,之后整首重来。
// 给 scoredLyricCandidatesStreaming 的别名轮当"只查这些源"的名单;顺序按 lyricSourceNames。
func lyricSourcesWorthAliasRetry(ctx context.Context, scored []scoredLyricCandidateResult) []string {
	return dropAMLLWithoutIDSource(lyricSourcesWorthRetry(ctx, scored))
}

// lyricSourcesWorthRetry:lyricSourcesWorthAliasRetry 剔 amll(dropAMLLWithoutIDSource)之前的名单。按 ISRC 补取那一轮用它
// (isrcRetryPlan):那一轮 amll 按 ISRC 在本地索引里找,不靠网易云 / QQ 的 ID。
func lyricSourcesWorthRetry(ctx context.Context, scored []scoredLyricCandidateResult) []string {
	usable := map[string]bool{}
	for _, c := range scored {
		if c.Score >= 0 && !c.Instrumental {
			usable[c.Source] = true
		}
	}
	transport := sharedLyricSourceBreaker().transportFailureCodes()
	skipped := lyricSourceRoundFrom(ctx).skippedSources()
	var out []string
	for _, s := range lyricSourceNames {
		if !lyricSourceEnabled(s) || usable[s] || transport[s] != "" || slices.Contains(skipped, s) || lyricDeadlineMissed(ctx, s) {
			continue
		}
		switch s {
		case "lyricfind":
			if ytmusicLastFailureReasonNow() != "" {
				continue
			}
		case "musixmatch":
			if musixmatchLastFailureReasonNow() != "" {
				continue
			}
		case "deezer":
			// 换不到匿名 JWT(deezer_auth_failed)时,换个歌手别名同样一个字都取不回来
			// —— 跟 lyricfind 那条一个道理,见 deezer.go 头注。
			if deezerLastFailureReasonNow() != "" {
				continue
			}
		case "applemusic":
			// 没连过账号 / 令牌过期 / 拿不到 developer token —— 三种都跟"歌手名写法"
			// 毫无关系,换个别名重试一次只是白白多打一轮请求。见 applemusic.go 头注。
			// 反过来说,连上了只是没搜到,这一路**值得**重试:它跟网易云/QQ 一样是拿
			// 歌手名 + 歌名去搜的,别名确实会影响命中。
			if applemusicLastFailureReasonNow() != "" {
				continue
			}
		}
		out = append(out, s)
	}
	return out
}

// dropAMLLWithoutIDSource:别名轮名单里既没有网易云也没有 QQ 时剔掉 amll。amll 不发搜索请求,按曲目 ID
// 直取:Apple / Spotify 两个精确 ID 跟署名写法无关、首轮已经拿它们问过(别名轮按改写后的署名也查不到它们),
// 网易云 / QQ 的 ID 只有这一轮也重查那两个源时才可能是新的。都不在的话 amll 这一轮拿不到新 ID,只剩拿别名在
// 本地索引里再找一次;留在名单里会让"只缺 amll"的歌(库里没有的歌占绝大多数)都跑一轮别名(MusicBrainz /
// iTunes 身份查询)。
func dropAMLLWithoutIDSource(sources []string) []string {
	for _, s := range sources {
		if s == "netease" || s == "qq" {
			return sources
		}
	}
	out := sources[:0:0]
	for _, s := range sources {
		if s != "amll" {
			out = append(out, s)
		}
	}
	return out
}

// usableLyricSourceCount:给出可用候选的歌词源有几个(同源多条只算一个),是首歌手变体轮等补查轮的触发判据。
// 这几类不算:纯音乐标记(不是候选,见 scoredLyricCandidateResult.Instrumental);用户在「歌词来源」里关掉的源(抓取不看
// 开关,raw 结果里照样在场,但挑选和手动搜索都只认启用的源);KKBOX / Spotify / Amazon Music 的本地歌词(读的是播放器
// 自己的缓存,不是歌词源,也不随换检索词变多,算进去的话一份本地歌词加一条弱候选就凑够门槛,后面的别名 / 标题反查轮
// 全被跳过)。
func usableLyricSourceCount(scored []scoredLyricCandidateResult) int {
	seen := map[string]bool{}
	for _, c := range scored {
		if c.Score >= 0 && !c.Instrumental && !isPlayerLocalLyricSource(c.Source) &&
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
//
// language / plainTextOnly 也要拷。漏拷的后果是走过别名轮/变体轮合并的候选重打分时
// 被当成"普通没时间戳的候选"——lrclib 纯文本兜底在决策存档里会被记成 rejectNotTimed
// 而不是 rejectPlainTextOnly,「搜索候选歌词」弹窗据此给出的提示也是错的("没有时间戳"
// 而非"仅纯文本")。分数本身两条路都是 -1、采纳不受影响,所以只是标签错。
// language 目前不参与打分(只在 scored 结果里透传给 songLanguageFromScored),一起拷是
// 让"还原"名副其实——以后谁在打分里用到它,不会在合并轮里悄悄拿到空值。timelineRemap
// 不还原:重挂时间轴在候选构造时已经作用到正文上,scored 结果里的正文就是重挂后的。
func lyricCandidateFromScored(r scoredLyricCandidateResult) lyricCandidate {
	// 借来的译文(LyricsTrFrom)不算这条自己的,不加分(10 章决策 42)。
	ownTr := r.LyricsTr
	if r.LyricsTrFrom != "" {
		ownTr = ""
	}
	tr, roma := usableValueAdd(r.Lyrics, ownTr, r.LyricsTrLang, r.LyricsRoma, features().LyricsTranslationLanguage)
	return lyricCandidate{
		source:                     r.Source,
		lyrics:                     r.Lyrics,
		wordTimingYRC:              r.LyricsYRC,
		hasWordTiming:              r.HasWordTiming,
		hasUsableTranslation:       tr,
		hasUsableRomanization:      roma,
		sourceReportedDurationSecs: r.SourceReportedDurationSecs,
		isrc:                       r.ISRC,
		title:                      r.Title,
		artist:                     r.Artist,
		album:                      r.Album,
		cover:                      r.CoverURL,
		language:                   r.Language,
		plainTextOnly:              r.PlainTextOnly,
		identityFromLocalClient:    r.IdentityFromLocalClient,
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
//
// 误杀——变体串只作检索词和源内采纳闸,绝不进打分。 那道语言闸另有一层豁免(候选源
//
//	  自己确认匹配到的 candidateArtist 含汉字就不拦),但豁免救不了"原串本身也是罗马化
//	  写法、候选源报的 artist 恰好也没有汉字"这一档(比较少见,多数源匹配上时会报中文
//	  曲库里的写法),用原串仍是必需的第一道防线,不能指望那道豁免顶替它。
//	- corroboratedEndings/contentConsensusPeers 按合并后的全体成员重算:变体轮捞回的源
//	  就该给原串轮的候选作证(反之亦然),分数不是拼接两轮旧值能得到的。
//	- lrclib 的 Instrumental 标记:任一轮带了、且合并后没有真实的 lrclib 候选,才保留
//	  一条(语义同 scoreAndSort 里"lrclibLyr 为空才附"的约定)。
func mergeLyricCandidateRounds(artist, title, album string, durationSecs float64, base, extra []scoredLyricCandidateResult) []scoredLyricCandidateResult {
	chosen := map[string]scoredLyricCandidateResult{}
	var order []string
	var instrumental *scoredLyricCandidateResult
	// "曲库里有、但没有歌词"的标记按**源**收着(不像 instrumental 那样全局只留一条,理由见
	// noLyricsMarkers 头注的 ①)。跟 instrumental 同样的道理:它们不是候选,绝不能进 chosen
	// —— 否则会占住那个源的位置,把变体轮真正搜到的候选顶掉。
	noLyrics := map[string]scoredLyricCandidateResult{}
	take := func(r scoredLyricCandidateResult) bool {
		if r.Instrumental {
			if instrumental == nil || (r.PlayerInstrumental && !instrumental.PlayerInstrumental) {
				rr := r
				instrumental = &rr
			}
			return true
		}
		if r.TrackFoundNoLyrics {
			if _, ok := noLyrics[r.Source]; !ok {
				noLyrics[r.Source] = r
			}
			return true
		}
		return false
	}
	for _, r := range base {
		if take(r) {
			continue
		}
		if _, ok := chosen[r.Source]; !ok {
			chosen[r.Source] = r
			order = append(order, r.Source)
		}
	}
	for _, r := range extra {
		if take(r) {
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
	// 重建顺序按 lyricCandidateTieOrder(主路径构造候选的源序),不是两轮的到达/分数序——scoreAndSort 的
	// 稳定排序约定"同分按候选构造顺序决胜,确定且可复现",合并路径要跟主路径同一套口径,
	// 否则同一首歌走没走变体轮,同分平手时可能选出不同的源。
	ordered := make([]string, 0, len(order))
	inNames := map[string]bool{}
	for _, s := range lyricCandidateTieOrder {
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
		// 前几轮排完序借过的译文先撤掉,合并后按这一批候选重借(末尾的 applyBorrowedTranslations):供体可能已被顶替或判废。
		if r := chosen[s]; r.LyricsTrFrom != "" {
			r.LyricsTr, r.LyricsTrLang, r.LyricsTrFrom = "", "", ""
			chosen[s] = r
		}
		cands = append(cands, lyricCandidateFromScored(chosen[s]))
	}
	// 重音字母旁多切的空格,同 rankLyricSourceResults(见 accentsplit.go)。修的是 cands,下面打分时写回结果。
	repairCandidateAccentSplits(cands)
	// v15:批级语种判决,跟下面两个批级步骤同一位置(理由见 match.go applyLanguageVersionVerdicts)。
	applyLanguageVersionVerdicts(title, album, durationSecs, cands)
	applyVerifiedTitleVersion(title, album, durationSecs, verifiedRecordingTitle(base, extra), cands)
	corroborated := corroboratedEndings(cands, durationSecs)
	consensusPeers := contentConsensusPeers(artist, title, cands, durationSecs)
	inheritIdentityTerms(title, album, cands, consensusPeers)
	out := make([]scoredLyricCandidateResult, 0, len(ordered)+1)
	// "合并后有没有**标记那个源自己**的真候选"。按标记的 Source 判,别写死 lrclib ——
	// 纯音乐标记也可能来自网易云(见 scoreAndSort 里的 instrumentalMarker),写死会让
	// "网易云既给了真歌词、又带着纯音乐标记"这种自相矛盾的组合被保留。
	hasRealFromMarkerSource := false
	for i, s := range ordered {
		r := chosen[s]
		r.Lyrics, r.LyricsYRC = cands[i].lyrics, cands[i].wordTimingYRC
		r.Score, r.ScoreTerms = scoreLyricCandidateDetailed(
			artist, title, album, durationSecs, cands[i], corroborated[s], len(consensusPeers[s]))
		r.ConsensusPeers = consensusPeers[s]
		if instrumental != nil && s == instrumental.Source && r.Score >= 0 {
			hasRealFromMarkerSource = true
		}
		out = append(out, r)
	}
	if instrumental != nil && !hasRealFromMarkerSource {
		out = append(out, *instrumental)
	}
	// 同一个条件按**每个源**各判一次:某个源在原串轮说"有歌没词"、变体轮却真搜到了词,
	// 那条标记就该消失(它已经不成立了),但别的源的标记不受影响 —— 这正是它不去重的意义。
	// 纯音乐那条留下来时,同源的这条要让位(互斥,理由同 noLyricsMarkers 的 ③)。
	for _, source := range lyricSourceNames {
		m, ok := noLyrics[source]
		if !ok {
			continue
		}
		if _, hasReal := chosen[source]; hasReal {
			continue
		}
		if instrumental != nil && instrumental.Source == source && !hasRealFromMarkerSource {
			continue
		}
		out = append(out, m)
	}
	// v5:同 scoreAndSort 里那一处——必须在排序之前跑,见 applyWordTimingTitleOverride
	// 的注释。变体轮合并出来的这批候选一样要过这道闸,不然同一首歌走没走变体轮,判定标准会不一致。
	// 时间轴平移扣分同理,且排在它前面(见 applyTimelineOffsetPenalty)。
	applySourceDurationNearMissPenalty(out, durationSecs)
	applyTimelineOffsetPenalty(out, durationSecs)
	applyTimelineIntrusionPenalty(out, durationSecs)
	applyWordTimingTitleOverride(out)
	sort.SliceStable(out, func(i, j int) bool { return out[i].Score > out[j].Score })
	applyUnmaskedWords(out)
	applyBorrowedTranslations(out)
	applyBorrowedCovers(out)
	return out
}

// lyricSearchUpdateFunc 是流式搜索的进度回调。done/total 是**歌词源**的完成进度
// (给"搜索候选歌词"弹窗显示 (X/Y)):
//
//   - total 只数用户在"歌词来源"里**开着**的源。关掉的源即便查了也不会出现在候选里
//     (见 filterEnabledLyricSources),把它算进分母会让进度永远停在 6/7 这种数上。
//   - 别名重试那条路径会带着同一个回调再跑一轮完整搜索,于是 done 会从头再数一遍 ——
//     如实反映"确实又把各个源查了一遍",不假装单调递增。
type lyricSearchUpdateFunc func(ne neteaseInfo, results []scoredLyricCandidateResult, done, total int)

// mergedRoundUpdate 包装追加轮(别名轮 / 首歌手变体轮 / 标题反查轮)的流式回调:每次更新先与前几轮已有的
// base 合并再上报。onUpdate 为 nil 时返回 nil。
func mergedRoundUpdate(onUpdate lyricSearchUpdateFunc, artist, title, album string, durationSecs float64, base []scoredLyricCandidateResult) lyricSearchUpdateFunc {
	if onUpdate == nil {
		return nil
	}
	return func(vne neteaseInfo, vres []scoredLyricCandidateResult, done, total int) {
		onUpdate(vne, mergeLyricCandidateRounds(artist, title, album, durationSecs, base, vres), done, total)
	}
}

// keepShownRoundUpdate:换了身份整个重入(拆分署名、翻唱者)那一轮的进度回调。重入那一轮按它自己的身份打分,不能像
// mergedRoundUpdate 那样按原身份重打分(会把它的候选全判废);只把原来那批里重入这一轮还没出现的源接在后面,弹窗上
// 原来那批不会先消失。只管显示:onUpdate 只给弹窗用,最终结果照旧由调用方决定采用哪一批。
func keepShownRoundUpdate(onUpdate lyricSearchUpdateFunc, base []scoredLyricCandidateResult) lyricSearchUpdateFunc {
	if onUpdate == nil || len(base) == 0 {
		return onUpdate
	}
	return func(vne neteaseInfo, vres []scoredLyricCandidateResult, done, total int) {
		have := map[string]bool{}
		for _, r := range vres {
			have[r.Source] = true
		}
		shown := append([]scoredLyricCandidateResult(nil), vres...)
		for _, r := range base {
			if !have[r.Source] {
				shown = append(shown, r)
			}
		}
		sort.SliceStable(shown, func(i, j int) bool { return shown[i].Score > shown[j].Score })
		onUpdate(vne, shown, done, total)
	}
}

// lyricSourceNames 是全部歌词源的名字,每个源一个并发 goroutine。顺序只决定「有歌没词」标记、日志和设置项里的源序;
// 同分候选谁赢看 lyricCandidateTieOrder,不看这里。
var lyricSourceNames = []string{"netease", "qq", "kugou", "lrclib", "musixmatch", "amll", "lyricfind", "kuwo", "migu", "deezer", "applemusic", "soda", "vibe", "genie", "petitlyrics"}

// lyricCandidateTieOrder:同分候选按这个源序决胜,就是 rankLyricSourceResults 构造候选的顺序(本机几家的歌词夹在
// 汽水和 AMLL 之间)。合并几轮结果的 mergeLyricCandidateRounds 按它重建顺序,两边才是同一个口径:不然同一首歌走没走
// 补查轮,同分时会在 musixmatch / lrclib、applemusic / amll 之间换源。rankLyricSourceResults 里加了源、挪了顺序,这里
// 跟着改(lyrictieorder_test.go 用源码扫描钉着两边一致)。
var lyricCandidateTieOrder = []string{
	"netease", "qq", "kugou", "musixmatch", "lrclib", "lyricfind", "kuwo", "migu", "deezer", "applemusic", "soda", "vibe", "genie", "petitlyrics",
	kkboxLocalLyricsSource, amazonLocalLyricsSource, lxMusicLocalLyricsSource, localFileLyricsSource, spotifyLocalLyricsSource,
	"amll",
}

// enabledLyricSourceCount 数"用户开着的歌词源"有几个。features().LyricsSources 为空
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

// lyricSourceResult 是**一个源这一轮的原始应答**——fetchScoredLyricCandidatesStreaming 里九个
// goroutine 各自往 resultsCh 送的就是它。放在包级(而不是那个函数的局部类型)只有一个理由:
// 让 rankLyricSourceResults(打分/排序这一段)能以"一组原始应答"为入参单独存在,回归金标集
// (lyricsgolden_test.go)才能拿真实曲目的原始应答喂**生产同一份代码**,而不是在测试里重抄
// 一份骨架(simeval_test.go 就是重抄的,已经漂了两步:少了 rehangCandidateTimelines 和
// applyWordTimingTitleOverride)。
type lyricSourceResult struct {
	source                  string
	ne                      neteaseInfo
	lyr, yrc, tr, roma      string // roma:源自带罗马音(逐行 LRC),目前只有 qq 走这里(网易云的在 ne.Roma)
	bg                      string // 背景人声轨(YRC 语法,形状见 amllResult.bg)。只有 applemusic 走这里,amll 的在 amll.bg。
	trLang                  string // tr 的语言,源自己标了才有。只有 applemusic 走这里(applemusicResult.trLang),amll 的在 amll.trLang。
	matchTitle, matchArtist string
	matchAlbum, matchCover  string
	srcDur                  float64 // 源自己声明的曲长(秒),0=没给。见 lyricCandidate.sourceReportedDurationSecs
	isrc                    string  // 源报的这条录音的 ISRC,applemusic、deezer、petitlyrics 填,见 isrcretry.go
	// trackIDs:这一路匹配到的曲目在该平台上的 ID。只有 qq 走这里(songmid 与数字 ID,见 qqTrackIDs),amll 借封面时
	// 跟 TTML 登记的 ID 比(amllCandidateCover);网易云的在 ne.SongID。
	trackIDs []string
	// language:源自己上报的语种(songLanguageMandarin/songLanguageCantonese/空),
	// 目前只有 qq/kugou 两路会填,见 lyricCandidate.language。
	language string
	// songwriters:词曲作者名单(applemusicResult.songwriters / deezerResult.songwriters)。applemusic 与 deezer 走这里,
	// amll 的在 amll.songwriters。
	songwriters []string
	// performers:演唱者标注(musixmatchResult.performers),只有 musixmatch 走这里。
	performers []musixmatchPerformerSpan
	// trackFoundNoLyrics:"这个源的曲库里有这首歌,但平台上没有歌词文本"这个**明确结论**
	//。目前 netease/qq 两路会给(经各自的 neteaseInfo.TrackFoundNoLyrics /
	// qqLyricResult.trackFoundNoLyrics,判据和边界见那两处头注)。跟 instrumental 是并列
	// 而非重叠的两个结论,互斥由各源自己的判据保证。
	trackFoundNoLyrics bool
	// instrumental:"这首歌是纯音乐"这个**明确结论**。四个源会给:lrclib 的结构化字段、
	// 网易云的 pureMusic/占位正文、QQ 的占位正文(见 qqLyricResult)、musixmatch 每行都带的
	// instrumental 字段(见 pickMusixmatchTrackRow 第三趟)。
	instrumental bool
	// plainOnly:lrclib / musixmatch / deezer / applemusic / migu / qq / lyricfind 会给(musixmatch 见
	// resolveMusixmatchLyric 里的纯文本回退;网易云的纯文本在 ne.PlainLyrics)——语义见 lrclibResult.plainOnly 头注。
	plainOnly bool
	// amll:amll-ttml-db 那一档的三件套(见 amllttml.go)。它跟别的源不同,一次就带回
	// 整行+逐字+译文,所以单独放一个结构而不是复用上面的 lyr/yrc/tr。
	amll amllResult
	// identityFromLocalClient:这一份的身份由播放器客户端自己的本地数据给定,不是搜出来的。
	// 本地路径会置位(kugou/applemusic 连正文都在本地,qq/netease/soda 只给权威 id);lyricfind 按 Kaset 报的 videoId
	// 取到时也置位(ytmusicVideoLyric)。
	// 语义与唯一用途见 lyricCandidate.identityFromLocalClient —— 同源加权的准入条件。
	// netease 那一路不走这个字段,它的事实在 ne.FromLocalClient 上(neteaseInfo 整个
	// 结构本来就随 lyricSourceResult.ne 传过来,不必再抄一份)。
	identityFromLocalClient bool
	// noVocals:这个源给的曲目信息说这一条没有人声(QQ 语种「纯音乐」、酷狗语种「纯音乐」、汽水 vocal==2、Apple audioLocale zxx、
	// Spotify 演唱语言 zxx)。伴奏版也带它,所以本身不等于「没有歌词」;怎么用见 playerInstrumentalSource 与 instrumentalMarker。
	noVocals bool
	// forPlayingTrack:这次解析的是正在放的那首或它的待播队列(playerSignalApplies),收集循环统一填。只有它为真时,播放器自己的
	// 信号才算数(playerInstrumentalSource)。
	forPlayingTrack bool
}

// lyricSourceResultTap 只给测试用(默认 nil,生产永远不设):fetchScoredLyricCandidatesStreaming
// 每收到一个源的原始应答就回调一次。回归金标集的采集器靠它把一次真实检索的原始应答固化成
// 样本(见 lyricsgolden_capture_test.go);打分逻辑不读它,跟 decision.go 那条"只写不读"同一纪律。
var lyricSourceResultTap func(lyricSourceResult)

// lyricSearchItemsTap 同样只给测试用(默认 nil):各源把**解析好的搜索结果**交给自己的挑选函数之前
// 回调一次——netease 的 neteasePickSong、qq 的 qqCollectCandidates、kugou 的 pickKugouSearchCandidate、
// lrclib 的 pickLRCLIBSearchResultDetailed。检索层金标(lyricsgolden_search_test.go)靠它把"这一批
// 搜索结果里该选谁"固化成样本。items 是各源自己的切片类型([]neSearchSong / []qqSearchItem /
// []kugouSong / []lrclibSearchItem),由采集侧按 source 断言回来。
var lyricSearchItemsTap func(source, artist, title, album string, durationSecs float64, items any)

// rankLyricSourceResults 把一组各源原始应答变成打好分、排好序的候选列表:构建候选、时间轴自洽修复、corroboratedEndings、
// 跨源正文共识、逐条打分、纯音乐标记搭车、逐字加分撤销、稳定排序,全在这里。每次有新源到达都全量重跑(分数不是只增
// 不改的东西,见 fetchScoredLyricCandidatesStreaming 的头注)。
//
// 做成包级纯函数是为了可测:回归金标集(lyricsgolden_test.go)拿真实曲目固化下来的原始应答直接喂这里,断言"冠军是谁、
// 每条候选判决如何、分项是什么",测的是生产同一份代码。除 features(译文语言、来源开关)、当前播放器同源表和歌手别名
// 缓存(isProbablyWrongLanguageLyrics 读)之外不依赖别的包级状态。
//
// raw 里缺某个源(没应答/被熔断跳过)就是零值。
func rankLyricSourceResults(artist, title, album string, durationSecs float64, raw map[string]lyricSourceResult) []scoredLyricCandidateResult {
	// 第一步先把各源正文里的 HTML / XML 字符实体还原(酷狗 `they&apos;re`,见 lyricentities.go)。
	// 返回的是新 map,调用方那份原始应答不动——它每来一个源就全量重跑一次这里。
	raw = decodeLyricSourceEntities(raw)
	raw = dropOtherVersionInstrumentalClaims(title, album, raw)
	ne := raw["netease"].ne
	qq, kugou, lrclib, mx, lf, kuwo := raw["qq"], raw["kugou"], raw["lrclib"], raw["musixmatch"], raw["lyricfind"], raw["kuwo"]
	qqLyr, qqYRC, qqTr, qqRoma, qqTitle, qqArtist, qqAlbum, qqCover, qqDur, qqLang := qq.lyr, qq.yrc, qq.tr, qq.roma, qq.matchTitle, qq.matchArtist, qq.matchAlbum, qq.matchCover, qq.srcDur, qq.language
	qqInstrumental := qq.instrumental
	qqPlainOnly := qq.plainOnly
	kugouLyr, kugouYRC, kugouTr, kugouRoma, kugouTitle, kugouArtist, kugouAlbum, kugouCover, kugouDur, kugouLang := kugou.lyr, kugou.yrc, kugou.tr, kugou.roma, kugou.matchTitle, kugou.matchArtist, kugou.matchAlbum, kugou.matchCover, kugou.srcDur, kugou.language
	lrclibLyr, lrclibTitle, lrclibArtist, lrclibAlbum, lrclibDur := lrclib.lyr, lrclib.matchTitle, lrclib.matchArtist, lrclib.matchAlbum, lrclib.srcDur
	lrclibInstrumental := lrclib.instrumental
	lrclibPlainOnly := lrclib.plainOnly
	lrclibYRC, lrclibRoma := lrclib.yrc, lrclib.roma
	mxLyr, mxYRC, mxTr, mxRoma, mxTitle, mxArtist, mxAlbum, mxCover, mxDur := mx.lyr, mx.yrc, mx.tr, mx.roma, mx.matchTitle, mx.matchArtist, mx.matchAlbum, mx.matchCover, mx.srcDur
	mxPlainOnly := mx.plainOnly
	mxInstrumental := mx.instrumental
	lfLyr, lfTitle, lfArtist, lfAlbum, lfCover, lfDur, lfPlainOnly := lf.lyr, lf.matchTitle, lf.matchArtist, lf.matchAlbum, lf.matchCover, lf.srcDur, lf.plainOnly
	kuwoLyr, kuwoYRC, kuwoTitle, kuwoArtist, kuwoAlbum, kuwoCover, kuwoDur := kuwo.lyr, kuwo.yrc, kuwo.matchTitle, kuwo.matchArtist, kuwo.matchAlbum, kuwo.matchCover, kuwo.srcDur
	migu := raw["migu"]
	miguLyr, miguYRC, miguTr, miguTitle, miguArtist, miguAlbum, miguCover := migu.lyr, migu.yrc, migu.tr, migu.matchTitle, migu.matchArtist, migu.matchAlbum, migu.matchCover
	miguPlainOnly, miguDur := migu.plainOnly, migu.srcDur
	dz := raw["deezer"]
	dzLyr, dzYRC, dzTr, dzTitle, dzArtist, dzAlbum, dzCover, dzDur, dzPlainOnly := dz.lyr, dz.yrc, dz.tr, dz.matchTitle, dz.matchArtist, dz.matchAlbum, dz.matchCover, dz.srcDur, dz.plainOnly
	am := raw["applemusic"]
	amLyr, amYRC, amTr, amRoma, amTitle, amArtist, amAlbum, amCover, amDur, amPlainOnly := am.lyr, am.yrc, am.tr, am.roma, am.matchTitle, am.matchArtist, am.matchAlbum, am.matchCover, am.srcDur, am.plainOnly
	amBG := am.bg
	amTrLang := am.trLang
	if amTrLang == "" {
		amTrLang = features().LyricsTranslationLanguage
	}
	soda := raw["soda"]
	vibe := raw["vibe"]
	genie := raw["genie"]
	petit := raw["petitlyrics"]
	kk := raw[kkboxLocalLyricsSource]
	spl := raw[spotifyLocalLyricsSource]
	amz := raw[amazonLocalLyricsSource]
	localLRC := raw[localFileLyricsSource]
	lxm := raw[lxMusicLocalLyricsSource]
	sodaLyr, sodaYRC, sodaTr, sodaTitle, sodaArtist, sodaAlbum, sodaCover, sodaDur := soda.lyr, soda.yrc, soda.tr, soda.matchTitle, soda.matchArtist, soda.matchAlbum, soda.matchCover, soda.srcDur
	amll := raw["amll"].amll
	// 候选的封面只用它自己那个源给的,没有就空着(「搜索候选歌词」弹窗显示占位图,「解析决策」全空时整列不出现);
	// amll 自己没有封面,借能认定是同一条录音的那几家的(amllCandidateCover)。
	// 别拿按本地歌名搜来的 Apple 封面给它兜底:那是"本地这首"的封面、不是这条候选的出处,候选缩略图本来是帮人
	// 分辨"这条是哪个版本"的,套上一张别人的图反而像是对上了;所有没带封面的候选还会套成同一张,毫无区分度。
	// 烘进正文的逐行中文译文(bakedtranslation.go):候选装配**之前**摘出来——共识、行数、
	// 逐字覆盖率全都读正文,晚了就都是按"一半是中文"的正文算的。译文轨本来就是中文语义的源
	// (netease/qq/kugou)接上摘出来的译文;musixmatch/amll 的译文语言跟设置走,只摘不接。
	foreignSong := !containsHan(artist) && !containsHan(title)
	bakedLines := map[string]int{}
	ne.Lyrics, ne.Trans, ne.YRC, bakedLines["netease"] = adoptBakedTranslation(ne.Lyrics, ne.Trans, ne.YRC, foreignSong, true)
	qqLyr, qqTr, qqYRC, bakedLines["qq"] = adoptBakedTranslation(qqLyr, qqTr, qqYRC, foreignSong, true)
	kugouLyr, kugouTr, kugouYRC, bakedLines["kugou"] = adoptBakedTranslation(kugouLyr, kugouTr, kugouYRC, foreignSong, true)
	mxLyr, _, mxYRC, bakedLines["musixmatch"] = adoptBakedTranslation(mxLyr, "", mxYRC, foreignSong, false)
	lrclibLyr, _, lrclibYRC, bakedLines["lrclib"] = adoptBakedTranslation(lrclibLyr, "", lrclibYRC, foreignSong, false)
	lfLyr, _, _, bakedLines["lyricfind"] = adoptBakedTranslation(lfLyr, "", "", foreignSong, false)
	// 酷我对外文歌**系统性**地把中文译文烘在正文里(金标 ko-fallen-angel / latin-purple-rain 里的酷我候选
	// 128→67 行、71→37 行),摘出来的译文照 qq/kugou 的口径接到译文轨(中文)。
	// 酷我的译文行挂在下一句的时间戳上,整首判断之后再逐行认一遍(adoptKuwoBakedTranslation)。
	// 逐字轨**不**传进去:它在 kuwolrcx.go 转换时已去掉译文行,而酷我的译文行跟下一句原文同一个时间戳,
	// 交给这里按时间删会把原文那行一起删掉。
	var kuwoTr string
	kuwoLyr, kuwoTr, bakedLines["kuwo"] = adoptKuwoBakedTranslation(kuwoLyr, foreignSong)
	amll.lrc, _, amll.yrc, bakedLines["amll"] = adoptBakedTranslation(amll.lrc, "", amll.yrc, foreignSong, false)
	var candidates []lyricCandidate
	if ne.Lyrics != "" {
		// 网易云的社区翻译固定中文(见下面附着处的注释),usable 判定按目标语言过闸;
		// 这两个标志必须在**打分前**算好挂到候选上(v3 的增值内容决胜分要读它),
		// 不能等选完冠军再附着。
		neTr, neRoma := usableValueAdd(ne.Lyrics, ne.Trans, "zh", ne.Roma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.Lyrics, wordTimingYRC: usableYRC(ne.Lyrics, ne.YRC), hasWordTiming: usableWordTiming(ne.Lyrics, ne.YRC), hasUsableTranslation: neTr, hasUsableRomanization: neRoma, sourceReportedDurationSecs: ne.DurationSecs, title: ne.Title, artist: ne.Artist, album: ne.Album, cover: ne.Cover, identityFromLocalClient: ne.FromLocalClient})
	} else if ne.PlainLyrics != "" {
		// 只有不带时间戳的歌词:交成 plainOnly,直通打分层那道恒 -1 的闸,口径同 deezer / lrclib 的纯文本回退。
		candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.PlainLyrics, sourceReportedDurationSecs: ne.DurationSecs, title: ne.Title, artist: ne.Artist, album: ne.Album, cover: ne.Cover, identityFromLocalClient: ne.FromLocalClient, plainTextOnly: true})
	}
	if qqLyr != "" {
		// QQ 的译文固定是中文(跟网易云 tlyric 同款),语言标 "zh";罗马音的可用判定
		// (原文假名占比 > 5%)也沿用同一套 usableValueAdd——韩文歌的罗马音会跟网易云
		// 一样被判不可用,这是既有口径,不是 QQ 这路新加的规则。
		qqUsableTr, qqUsableRoma := usableValueAdd(qqLyr, qqTr, "zh", qqRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "qq", lyrics: qqLyr, wordTimingYRC: usableYRC(qqLyr, qqYRC), hasWordTiming: usableWordTiming(qqLyr, qqYRC), hasUsableTranslation: qqUsableTr, hasUsableRomanization: qqUsableRoma, sourceReportedDurationSecs: qqDur, title: qqTitle, artist: qqArtist, album: qqAlbum, cover: qqCover, language: qqLang, identityFromLocalClient: qq.identityFromLocalClient, plainTextOnly: qqPlainOnly})
	}
	if kugouLyr != "" {
		// 酷狗 KRC `[language:]` 轨的译文固定中文,标 "zh";罗马音的可用判定同样走
		// usableValueAdd 的假名占比闸(韩文歌的谐音轨在 kugou.go 里已先按汉字占比挡掉一次)。
		kugouUsableTr, kugouUsableRoma := usableValueAdd(kugouLyr, kugouTr, "zh", kugouRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "kugou", lyrics: kugouLyr, wordTimingYRC: usableYRC(kugouLyr, kugouYRC), hasWordTiming: usableWordTiming(kugouLyr, kugouYRC), hasUsableTranslation: kugouUsableTr, hasUsableRomanization: kugouUsableRoma, sourceReportedDurationSecs: kugouDur, title: kugouTitle, artist: kugouArtist, album: kugouAlbum, cover: kugouCover, language: kugouLang, identityFromLocalClient: kugou.identityFromLocalClient})
	}
	if mxLyr != "" {
		mxUsableTr, mxUsableRoma := usableValueAdd(mxLyr, mxTr, features().LyricsTranslationLanguage, mxRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "musixmatch", lyrics: mxLyr, wordTimingYRC: usableYRC(mxLyr, mxYRC), hasWordTiming: usableWordTiming(mxLyr, mxYRC), hasUsableTranslation: mxUsableTr, hasUsableRomanization: mxUsableRoma, sourceReportedDurationSecs: mxDur, title: mxTitle, artist: mxArtist, album: mxAlbum, cover: mxCover, plainTextOnly: mxPlainOnly})
	}
	if lrclibLyr != "" {
		// 罗马音来自 lyricsfile 的音译(lyricsfile.go),可用性跟别的源同一道 usableValueAdd;没有译文。
		_, lrclibUsableRoma := usableValueAdd(lrclibLyr, "", "", lrclibRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "lrclib", lyrics: lrclibLyr, wordTimingYRC: usableYRC(lrclibLyr, lrclibYRC), hasWordTiming: usableWordTiming(lrclibLyr, lrclibYRC), hasUsableRomanization: lrclibUsableRoma, sourceReportedDurationSecs: lrclibDur, title: lrclibTitle, artist: lrclibArtist, album: lrclibAlbum, cover: "", plainTextOnly: lrclibPlainOnly})
	}
	if lfLyr != "" {
		// 只有逐行,没有逐字/译文/罗马音——跟 lrclib 同一个形状(见 ytmusic.go 头注)。只有纯文本时 plainOnly 直通打分层那道
		// 恒 -1 的闸,口径同 deezer/lrclib 的纯文本回退。
		candidates = append(candidates, lyricCandidate{source: "lyricfind", lyrics: lfLyr, sourceReportedDurationSecs: lfDur, title: lfTitle, artist: lfArtist, album: lfAlbum, cover: lfCover, plainTextOnly: lfPlainOnly, identityFromLocalClient: lf.identityFromLocalClient})
	}
	if kuwoLyr != "" {
		// 逐行正文 + 可选的逐字轨(kuwolrcx.go),译文只有从正文摘出来的烘入译文,没有罗马音
		// (见 kuwo.go 头注)。逐字的可用性判定同网易云/QQ/酷狗(usableYRC / usableWordTiming)。
		kuwoUsableTr, _ := usableValueAdd(kuwoLyr, kuwoTr, "zh", "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "kuwo", lyrics: kuwoLyr, wordTimingYRC: usableYRC(kuwoLyr, kuwoYRC), hasWordTiming: usableWordTiming(kuwoLyr, kuwoYRC), hasUsableTranslation: kuwoUsableTr, sourceReportedDurationSecs: kuwoDur, title: kuwoTitle, artist: kuwoArtist, album: kuwoAlbum, cover: kuwoCover})
	}
	if miguLyr != "" {
		// 逐行 LRC + 可选的逐字轨(MRC,migumrc.go)+ 可选的中文译文(trcUrl,外语歌才有),没有罗马音;
		// 封面用搜索结果自带的 imgItems(见 migu.go 头注)。译文固定中文、标 "zh",可用性同网易云/QQ/酷狗
		// 走 usableValueAdd,逐字同样走 usableYRC / usableWordTiming。
		// 搜索结果没有时长字段,sourceReportedDurationSecs 用文件大小估的(miguSearchItem.durationSecs),估不出时为 0。
		// plainOnly 直通打分层那道恒 -1 的闸,口径同 deezer/lrclib 的纯文本回退。
		miguUsableTr, _ := usableValueAdd(miguLyr, miguTr, "zh", "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "migu", lyrics: miguLyr, wordTimingYRC: usableYRC(miguLyr, miguYRC), hasWordTiming: usableWordTiming(miguLyr, miguYRC), hasUsableTranslation: miguUsableTr, sourceReportedDurationSecs: miguDur, title: miguTitle, artist: miguArtist, album: miguAlbum, cover: miguCover, plainTextOnly: miguPlainOnly})
	}
	if dzLyr != "" {
		// 逐行正文 + 可选的逐字轨 + 可选的译文(语言跟译文语言设置走),没有罗马音;封面用搜索
		// 结果自带的 album.cover_xl,时长用 Deezer 自报的 duration(见 deezer.go 头注)。逐字走
		// usableYRC / usableWordTiming,译文走 usableValueAdd,口径同别的源。plainOnly 直通打分层
		// 那道恒 -1 的闸(match.go 的 scoreRejectPlainTextOnly),口径与 lrclib/musixmatch 的纯文本回退一致。
		dzUsableTr, _ := usableValueAdd(dzLyr, dzTr, features().LyricsTranslationLanguage, "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "deezer", lyrics: dzLyr, wordTimingYRC: usableYRC(dzLyr, dzYRC), hasWordTiming: usableWordTiming(dzLyr, dzYRC), hasUsableTranslation: dzUsableTr, sourceReportedDurationSecs: dzDur, title: dzTitle, artist: dzArtist, album: dzAlbum, cover: dzCover, plainTextOnly: dzPlainOnly, isrc: dz.isrc})
	}
	if amLyr != "" {
		// 全部源里唯一的**官方逐字**来源:逐行 LRC + 逐字 YRC(itunes:timing="Word")+
		// 可选译文,封面用 artwork 模板替换出的 1000x1000,时长用 Apple 自报的
		// durationInMillis(见 applemusic.go 头注)。逐字的可用性判定走跟 amll 完全一样的
		// usableYRC/usableWordTiming —— 两边都是同一套 TTML 解析出来的,没理由用两套判据。
		// plainOnly 直通打分层那道恒 -1 的闸,口径同 deezer/lrclib 的纯文本回退。
		amUsableTr, amUsableRoma := usableValueAdd(amLyr, amTr, amTrLang, amRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: "applemusic", lyrics: amLyr,
			wordTimingYRC: usableYRC(amLyr, amYRC), hasWordTiming: usableWordTiming(amLyr, amYRC),
			hasUsableTranslation:       amUsableTr,
			hasUsableRomanization:      amUsableRoma,
			sourceReportedDurationSecs: amDur,
			isrc:                       am.isrc,
			title:                      amTitle, artist: amArtist, album: amAlbum,
			cover: amCover, plainTextOnly: amPlainOnly,
			identityFromLocalClient: am.identityFromLocalClient,
		})
	}
	if sodaLyr != "" {
		// 官方逐字(格式与酷狗 KRC 同构,归一化见 soda.go)+ 平台自带的中文译文(外语歌才有),
		// 没有罗马音。译文固定中文、标 "zh",可用性同网易云/QQ/酷狗走 usableValueAdd。没有
		// plainTextOnly —— 拿不到计时行时 krcToLRC 返回空串,这里根本进不来。
		sodaUsableTr, _ := usableValueAdd(sodaLyr, sodaTr, "zh", "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: "soda", lyrics: sodaLyr,
			wordTimingYRC: usableYRC(sodaLyr, sodaYRC), hasWordTiming: usableWordTiming(sodaLyr, sodaYRC),
			hasUsableTranslation:       sodaUsableTr,
			sourceReportedDurationSecs: sodaDur,
			title:                      sodaTitle, artist: sodaArtist, album: sodaAlbum,
			cover:                   sodaCover,
			identityFromLocalClient: soda.identityFromLocalClient,
		})
	}
	if vibe.lyr != "" {
		// 逐行 + 外语歌的韩文译文(标 "ko",译文语言设成韩文时才用得上),没有逐字和罗马音;封面是搜索结果自带的专辑图原图,
		// 时长是搜索结果自报的 playTime(见 vibe.go 头注)。plainOnly 直通打分层那道恒 -1 的闸,口径同 deezer / lrclib。
		vibeUsableTr, _ := usableValueAdd(vibe.lyr, vibe.tr, vibeTranslationLang, "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "vibe", lyrics: vibe.lyr, hasUsableTranslation: vibeUsableTr,
			sourceReportedDurationSecs: vibe.srcDur, title: vibe.matchTitle, artist: vibe.matchArtist, album: vibe.matchAlbum,
			cover: vibe.matchCover, plainTextOnly: vibe.plainOnly})
	}
	if genie.lyr != "" {
		// 逐行,没有逐字、译文、罗马音;封面、时长是搜索结果自带的(见 genie.go 头注)。plainOnly 口径同 vibe。
		candidates = append(candidates, lyricCandidate{source: "genie", lyrics: genie.lyr,
			sourceReportedDurationSecs: genie.srcDur, title: genie.matchTitle, artist: genie.matchArtist, album: genie.matchAlbum,
			cover: genie.matchCover, plainTextOnly: genie.plainOnly})
	}
	if petit.lyr != "" {
		// 逐字(取不到时纯文本),没有译文、罗马音;封面是按 ISRC 在 Deezer 上取的,时长是这份歌词登记的(见 petitlyrics.go 头注)。
		// plainOnly 口径同 vibe。
		candidates = append(candidates, lyricCandidate{source: "petitlyrics", lyrics: petit.lyr,
			wordTimingYRC: usableYRC(petit.lyr, petit.yrc), hasWordTiming: usableWordTiming(petit.lyr, petit.yrc),
			sourceReportedDurationSecs: petit.srcDur, title: petit.matchTitle, artist: petit.matchArtist, album: petit.matchAlbum,
			cover: petit.matchCover, plainTextOnly: petit.plainOnly, isrc: petit.isrc})
	}
	if kk.lyr != "" {
		// KKBOX 本地歌词(用 KKBOX 放歌时读它自己缓存里的那份,逐行,见 kkboxlyrics.go)。只精确到整秒的那类不置
		// identityFromLocalClient,不享受同源加权。
		candidates = append(candidates, lyricCandidate{
			source: kkboxLocalLyricsSource, lyrics: kk.lyr,
			sourceReportedDurationSecs: kk.srcDur,
			title:                      kk.matchTitle, artist: kk.matchArtist, album: kk.matchAlbum,
			cover:                   kk.matchCover,
			identityFromLocalClient: kk.identityFromLocalClient,
		})
	}
	if amz.lyr != "" {
		// Amazon Music 本地歌词(用它放歌时读它自己缓存里的那份,逐行,按 ASIN 认身份,见 amazonlibrary.go)。只精确到整秒的
		// 那类不置 identityFromLocalClient,同 KKBOX。
		candidates = append(candidates, lyricCandidate{
			source: amazonLocalLyricsSource, lyrics: amz.lyr,
			sourceReportedDurationSecs: amz.srcDur,
			title:                      amz.matchTitle, artist: amz.matchArtist, album: amz.matchAlbum,
			cover:                   amz.matchCover,
			identityFromLocalClient: amz.identityFromLocalClient,
		})
	}
	if lxm.lyr != "" {
		// 洛雪本地歌词(用洛雪放歌时读它存下的那份原版,按平台曲目 id 认身份,带逐字和译文,见 lxmusic.go)。
		lxmUsableTr, lxmUsableRoma := usableValueAdd(lxm.lyr, lxm.tr, "zh", lxm.roma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: lxMusicLocalLyricsSource, lyrics: lxm.lyr,
			wordTimingYRC: usableYRC(lxm.lyr, lxm.yrc), hasWordTiming: usableWordTiming(lxm.lyr, lxm.yrc),
			hasUsableTranslation: lxmUsableTr, hasUsableRomanization: lxmUsableRoma,
			sourceReportedDurationSecs: lxm.srcDur,
			title:                      lxm.matchTitle, artist: lxm.matchArtist, album: lxm.matchAlbum,
			identityFromLocalClient: lxm.identityFromLocalClient,
		})
	}
	if localLRC.lyr != "" {
		// reAMP 正在放的文件同名的 .lrc(用户自己配的,按文件认身份,见 localfilelyrics.go)。
		candidates = append(candidates, lyricCandidate{
			source: localFileLyricsSource, lyrics: localLRC.lyr,
			sourceReportedDurationSecs: localLRC.srcDur,
			title:                      localLRC.matchTitle, artist: localLRC.matchArtist,
			identityFromLocalClient: localLRC.identityFromLocalClient, plainTextOnly: localLRC.plainOnly,
		})
	}
	if spl.lyr != "" {
		// Spotify 本地歌词(Spotify 自己拉过的那份,逐行,多是 Musixmatch 供词,见 spotifylyrics.go)。Spotify 没有配同源
		// 歌词,不置 identityFromLocalClient,跟各源公平打分。
		candidates = append(candidates, lyricCandidate{
			source: spotifyLocalLyricsSource, lyrics: spl.lyr,
			sourceReportedDurationSecs: spl.srcDur,
			title:                      spl.matchTitle, artist: spl.matchArtist, album: spl.matchAlbum,
			cover: spl.matchCover,
		})
	}
	if !amll.empty() {
		// 按 ID 取回的那份身份是确定的 —— 这份 TTML 是按曲目 ID 直接取回来的,不是搜出来的,
		// 所以 title/artist/album 直接沿用本地曲目信息,不会在标题/歌手/专辑那几项上
		// 被扣分。按 ISRC / 歌名在索引里找到的(matchTitle 非空)报索引里的歌名 / 歌手 / 专辑,跟搜出来的源一样打分。
		// 它没有自报时长,sourceReportedDurationSecs 留 0(= 该项不参与打分)。
		// 它自己没有封面,只借能认定是同一条录音的那几家的(amllCandidateCover)。
		amllTitle, amllArtist, amllAlbum := title, artist, album
		if amll.matchTitle != "" {
			amllTitle, amllArtist, amllAlbum = amll.matchTitle, amll.matchArtist, amll.matchAlbum
		}
		amllCover := amllCandidateCover(amll, ne, qq, am, dz)
		target := features().LyricsTranslationLanguage
		amllTr, amllRoma := usableValueAdd(amll.lrc, amll.tr, amll.translationLang(target), amll.roma, target)
		candidates = append(candidates, lyricCandidate{
			source: "amll", lyrics: amll.lrc,
			wordTimingYRC: usableYRC(amll.lrc, amll.yrc), hasWordTiming: usableWordTiming(amll.lrc, amll.yrc),
			hasUsableTranslation:  amllTr,
			hasUsableRomanization: amllRoma,
			title:                 amllTitle, artist: amllArtist, album: amllAlbum, cover: amllCover,
		})
	}
	// 重音字母旁多切的空格,拿整批候选与缓存里见过的拼法证实之后删掉(见 accentsplit.go)。只删空格、不动时间轴。
	repairCandidateAccentSplits(candidates)
	// 时间轴自洽修复:候选自带的行级 LRC 与逐字轴打架时,以逐字轴为准重挂行时间戳
	// (见 lyricstimeline.go 的完整来龙去脉)。**必须在这里**而不是选完冠军之后 ——
	// corroboratedEndings / contentConsensusPeers / scoreLyricCandidateDetailed 的
	// 时长判据全都读 LRC 末句,先修完再算,打分看到的才是修正后的时间轴。
	rehangCandidateTimelines(candidates, durationSecs)
	// v15:批级语种判决(见 match.go applyLanguageVersionVerdicts)。放在重挂时间轴之后、
	// 其余批级步骤之前——它只读 title/album/language/自报时长,与时间轴无关,位置只求跟另一条
	// 流水线(mergeLyricCandidateRounds)一致。
	applyLanguageVersionVerdicts(title, album, durationSecs, candidates)
	corroborated := corroboratedEndings(candidates, durationSecs)
	// v3:跨源正文共识,整批统一算(理由同 corroboratedEndings——peers 随后到的源变化,
	// 每轮全量重算)。artist/title 已是 toSimplified 后的搜索关键词,与打分入参一致。
	consensusPeers := contentConsensusPeers(artist, title, candidates, durationSecs)
	inheritIdentityTerms(title, album, candidates, consensusPeers)
	// lrclib 明确说这首歌是纯音乐、且没有真的歌词候选(lrclibLyr=="")时,搭车塞一条
	// Score:-1 的标记进 results——见 Instrumental 字段定义处的注释,不参与打分/排序,
	// 不会被 pickLyricCandidate 选中,只是把这个信号原样带出这个函数。
	var instrumentalMarker *scoredLyricCandidateResult
	if lrclibLyr == "" && lrclibInstrumental {
		instrumentalMarker = &scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true}
	} else if (qqLyr == "" && qqInstrumental) || (isCreditOnlyLRC(qqLyr) && qq.noVocals) {
		// QQ 那一路。有的曲目只有 QQ 明确回了「此歌曲为没有填词的纯音乐」(网易云只有一行署名、没有 pureMusic 字段,
		// 酷狗、LRCLIB 都没有)。这句话不能在 resolveQQLyric 末尾的 isTimedLRC(要求 ≥3 行带戳)那里被当成"不是歌词"扔掉,
		// 否则这类曲目会落在「无歌词」而不是「纯音乐」:界面上看起来像失败,还要按退避白搜全部源。排在网易云之前只是
		// 因为 QQ 这句话是明文断言、语义比"正文只有占位"更硬。
		instrumentalMarker = &scoredLyricCandidateResult{Source: "qq", Score: -1, Instrumental: true}
	} else if ne.Lyrics == "" && (ne.PureMusic || ne.NoVocals) {
		// 网易云那一路同款。典型案例:LoL 原声带 The Music of League of Legends Vol.1
		// 十几首 —— lrclib 压根没有(五源全空、responded 是空的),而网易云**匹配上了歌**
		// (封面/单曲链接都给了)、歌词接口也明确回了 pureMusic=true。lrclib 优先只是因为
		// 它的标记是结构化字段、语义最干净。
		instrumentalMarker = &scoredLyricCandidateResult{Source: "netease", Score: -1, Instrumental: true}
	} else if mxLyr == "" && mxInstrumental {
		// Musixmatch 那一路。它的 instrumental 也是结构化字段(track.search 每一行都带),
		// 干净程度跟 lrclib 一档 —— 排在最后只是因为最新、样本最少,而排序只决定"界面上说是
		// 谁判的",不影响结论本身。
		//
		// 覆盖面上它补的是**西方器乐**这一块:Explosions In The Sky《Your Hand In Mine》
		// (post-rock 器乐)五行候选全是 instrumental=1,而这类曲目 lrclib 往往没收、网易云/QQ
		// 也不一定匹配得上。Musixmatch 本来就是各源里西方曲库覆盖最好的那个(见 doh.go 头注)。
		//
		// 能走到这里有个前提:musixmatch.go 的 pickMusixmatchTrackRow 有第三趟。纯音乐行在
		// Musixmatch 上是 has_subtitles=0 且 has_lyrics=0,前两趟的闸门按定义会把它们全筛掉 ——
		// 没有第三趟,这个分支永远不会被触发。
		instrumentalMarker = &scoredLyricCandidateResult{Source: "musixmatch", Score: -1, Instrumental: true}
	} else if isInstrumentalPlaceholderLyric(miguLyr) {
		// 咪咕对纯音乐回的歌词文件就是一句「此歌曲为纯音乐,请欣赏」,判定同 QQ 的占位。
		instrumentalMarker = &scoredLyricCandidateResult{Source: "migu", Score: -1, Instrumental: true}
	} else if isCreditOnlyLRC(kugouLyr) && kugou.noVocals {
		instrumentalMarker = &scoredLyricCandidateResult{Source: "kugou", Score: -1, Instrumental: true}
	}

	results := make([]scoredLyricCandidateResult, 0, len(candidates))
	for _, c := range candidates {
		r := scoredLyricCandidateResult{
			Source:                     c.source,
			Lyrics:                     c.lyrics,
			LyricsYRC:                  c.wordTimingYRC,
			HasWordTiming:              c.hasWordTiming,
			SourceReportedDurationSecs: c.sourceReportedDurationSecs,
			ISRC:                       c.isrc,
			Title:                      c.title,
			Artist:                     c.artist,
			Album:                      c.album,
			CoverURL:                   c.cover,
			Language:                   c.language,
			PlainTextOnly:              c.plainTextOnly,
			IdentityFromLocalClient:    c.identityFromLocalClient,
			BakedTranslationLines:      bakedLines[c.source],
		}
		if c.source == "amll" {
			r.BorrowedDurationSecs, r.BorrowedDurationFrom = amllCandidateDuration(amll, ne, qq, am, dz)
		}
		r.Score, r.ScoreTerms = scoreLyricCandidateDetailed(
			artist, title, album, durationSecs, c, corroborated[c.source], len(consensusPeers[c.source]))
		r.ConsensusPeers = consensusPeers[c.source]
		// 正文时间轴被重挂过的话,附属歌词也得搬 —— 它们的时间戳是照原文 LRC 抄的
		// (translate.go 的 assembleTranslationLRC / musixmatch.go 的 buildTranslatedLRC)。
		// 下面 switch 里各源赋完 r.LyricsTr/r.LyricsRoma 之后统一搬,见循环末尾。
		switch c.source {
		case "netease":
			// 翻译/罗马音网易云固定给中文(QQ、酷狗同样,见下面各自的 case)。"固定中文"这件事必须记下来:目标语言不是中文时,这份译文
			// 用不上,得让机翻接手(见 needsTranslationBackfill)。
			//
			// 译文赋值前必须过 c.hasUsableTranslation 这道闸(罗马音走更宽的 usableRomaForResult,
			// 见那边注释)。"能不能用"的判定(usableValueAdd,已经算过"原文本来就是目标语言,同语言
			// 不同文字不算翻译"这类情况)如果只用来加 +50 的打分、不管赋值,candidates 里那份不可用的翻译内容
			// 就会原样抄进 r.LyricsTr,分数赢了就带着这份没有意义的"翻译"一起进缓存(繁体原文配
			// 一份只是转成简体的"翻译"就是这么来的)。判定为不可用时干脆不赋值,行为跟"这个源
			// 没有可用译文"一致。
			if c.hasUsableTranslation {
				r.LyricsTr = ne.Trans
				r.LyricsTrLang = "zh"
			}
			if usableRomaForResult(c.lyrics, ne.Roma) {
				r.LyricsRoma = ne.Roma
			}
		case "lrclib":
			if usableRomaForResult(c.lyrics, lrclibRoma) {
				r.LyricsRoma = lrclibRoma
			}
		case "musixmatch":
			// Musixmatch 的译文语言是用户在"歌词"设置里配的
			// LyricsTranslationLanguage(ISO 639-1 代码),不像网易云固定中文——
			// 见 musixmatchTranslationLRC 注释。没配置/没查到社区翻译时 mxTr 是
			// 空串,r.LyricsTr 保持空,不影响这条候选本身的原文歌词。
			// 同上,c.hasUsableTranslation 是同一道闸——不可用(如目标语言跟原文
			// 实际语言"同语言不同文字"这类假翻译)就不赋值。
			if c.hasUsableTranslation {
				r.LyricsTr = mxTr
				// 抓取时用的就是当时设置里的语言。之后用户改了设置,这里记下的旧语言
				// 就会跟新目标对不上 —— 那正是要的:对不上就重翻。
				r.LyricsTrLang = features().LyricsTranslationLanguage
			}
			if usableRomaForResult(c.lyrics, mxRoma) {
				r.LyricsRoma = mxRoma
			}
			r.Performers = mx.performers
		case "amll":
			// amll 这条 case 不能漏。amll.tr 早就在 candidates 构造那一步被读出来过(见上面
			// usableValueAdd 调用,+50 分的打分信号靠它),但只要这个 switch 没有 amll 分支,分数
			// 算对了、内容却从没被抄进 r.LyricsTr:选中 amll 之后 lyrics_tr 永远是空的,机翻又拿
			// 这份本来就有毛病的原文(逐词粘连,见 amllttml.go)反复重试、屡试屡败,表现成"这首歌
			// 一直没有译文"。
			//
			// 语言标注跟 usableValueAdd 那次调用用同一个值(amllResult.translationLang:TTML 给译文标的语言,
			// 没标时按目标语言),"能不能用"和"语言标什么"两处口径一致。c.hasUsableTranslation 一并把关
			// "同语言不同文字不算翻译"这类情况。
			if c.hasUsableTranslation {
				r.LyricsTr = amll.tr
				r.LyricsTrLang = amll.translationLang(features().LyricsTranslationLanguage)
			}
			if usableRomaForResult(c.lyrics, amll.roma) {
				r.LyricsRoma = amll.roma
			}
			r.LyricsBG = amll.bg
			r.Songwriters = amll.songwriters
		case "applemusic":
			// 官方译文(<translations type="subtitle">)与官方音译(<transliterations>)。语言按译文块的 xml:lang,
			// 没标时按目标语言(网络那条按请求的语言给,applemusicLyricsQuery)。
			if c.hasUsableTranslation {
				r.LyricsTr = amTr
				r.LyricsTrLang = amTrLang
			}
			if usableRomaForResult(c.lyrics, amRoma) {
				r.LyricsRoma = amRoma
			}
			r.LyricsBG = amBG
			r.Songwriters = am.songwriters
		case "soda":
			// 汽水 lyric.translations.cn 固定中文,口径同 migu。
			if c.hasUsableTranslation {
				r.LyricsTr = sodaTr
				r.LyricsTrLang = "zh"
			}
		case "qq":
			// QQ GetPlayLyricInfo 的 trans/roma 两轨(见 qq.go qqQRCLyric / qqAuxiliaryLRC):
			// 译文跟网易云一样固定中文,标 "zh";两轨都由候选构造时算好的 usableValueAdd 结果
			// 把关。 这个 switch 的纪律是"接一个源就必须在这里补一个 case"(漏了的后果见上面
			// amll 那条:分数算对了、内容没抄进来)。
			if c.hasUsableTranslation {
				r.LyricsTr = qqTr
				r.LyricsTrLang = "zh"
			}
			if usableRomaForResult(c.lyrics, qqRoma) {
				r.LyricsRoma = qqRoma
			}
		case "kuwo":
			// 酷我自己没有译文轨,这里接的是从正文里摘出来的烘入译文(bakedtranslation.go),
			// 固定中文,可用性同样由候选装配时的 usableValueAdd 把关;中文歌里那段外文被它译全了的也收(kuwoBakedTranslationCovers)。
			if c.hasUsableTranslation || kuwoBakedTranslationCovers(c.lyrics, kuwoTr, features().LyricsTranslationLanguage, artist, title) {
				r.LyricsTr = kuwoTr
				r.LyricsTrLang = "zh"
			}
		case "kugou":
			// 酷狗 KRC `[language:]` 内嵌的中文译文 / 罗马音(见 kugou.go krcLanguageTracks),
			// 口径与 qq 完全一致:译文固定 "zh",两轨都由候选装配时的 usableValueAdd 结果把关。
			if c.hasUsableTranslation {
				r.LyricsTr = kugouTr
				r.LyricsTrLang = "zh"
			}
			if usableRomaForResult(c.lyrics, kugouRoma) {
				r.LyricsRoma = kugouRoma
			}
		case "migu":
			// 咪咕 trcUrl 的译文固定中文,标 "zh",可用性由候选装配时的 usableValueAdd 结果
			// 把关——口径同网易云/QQ/酷狗;这个 switch 的纪律仍是"接一个源就必须在这里补一个
			// case"(见上面 qq 那条)。
			if c.hasUsableTranslation {
				r.LyricsTr = miguTr
				r.LyricsTrLang = "zh"
			}
		case "vibe":
			// VIBE 只有韩文译文,可用性由候选装配时的 usableValueAdd 把关。
			if c.hasUsableTranslation {
				r.LyricsTr = vibe.tr
				r.LyricsTrLang = vibeTranslationLang
			}
		case lxMusicLocalLyricsSource:
			// 洛雪存下的是平台原版的译文 / 音译轨(国内平台的译文固定中文),口径同 qq。
			if c.hasUsableTranslation {
				r.LyricsTr = lxm.tr
				r.LyricsTrLang = "zh"
			}
			if usableRomaForResult(c.lyrics, lxm.roma) {
				r.LyricsRoma = lxm.roma
			}
		case "deezer":
			// Deezer 的译文按请求时的译文语言设置取(deezer.go deezerAcceptLanguage),标同一个语言;
			// 文字系统对不上目标语言的已在 deezerBuildTranslation 丢掉。
			if c.hasUsableTranslation {
				r.LyricsTr = dzTr
				r.LyricsTrLang = features().LyricsTranslationLanguage
			}
			r.Songwriters = dz.songwriters
		}
		// 正文时间轴被重挂过就把附属歌词一起搬过去。放在 switch **之后** —— 各源的
		// r.LyricsTr/r.LyricsRoma 到这里才赋完值,搬早了搬的是空串。
		if len(c.timelineRemap) > 0 {
			if tr, ok := remapLRCTimestamps(r.LyricsTr, c.timelineRemap); ok {
				r.LyricsTr = tr
			}
			if roma, ok := remapLRCTimestamps(r.LyricsRoma, c.timelineRemap); ok {
				r.LyricsRoma = roma
			}
		}
		results = append(results, r)
	}
	if src := playerInstrumentalSource(raw, results); src != "" {
		instrumentalMarker = &scoredLyricCandidateResult{Source: src, Score: -1, Instrumental: true, PlayerInstrumental: true}
	}
	if instrumentalMarker != nil {
		results = append(results, *instrumentalMarker)
	}
	results = append(results, noLyricsMarkers(raw, instrumentalMarker)...)
	// v5:必须在排序**之前**跑——它要看的是"排完序会是谁赢",然后据此
	// 决定要不要撤销冠军的逐字加分,晚了就成了在排好的结果上事后改分,顺序会跟着乱。
	// instrumentalMarker(Score:-1)不受影响,函数内部本来就跳过负分。
	// 时间轴整体平移的扣分排在它前面:那一步要看的是扣完之后谁赢(见 applyTimelineOffsetPenalty)。
	applySourceDurationNearMissPenalty(results, durationSecs)
	applyTimelineOffsetPenalty(results, durationSecs)
	applyTimelineIntrusionPenalty(results, durationSecs)
	applyWordTimingTitleOverride(results)
	// 稳定排序:来源加分拿掉之后同分会变多(见 scoreLyricCandidateDetailed 里那段注释),
	// 不稳定的排序会让同分候选的先后随运行变化,同一首歌两次解析可能选出不同的源。
	// 稳定之后就是按 candidates 的构造顺序决胜,确定且可复现。
	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	applyUnmaskedWords(results)
	applyBorrowedTranslations(results)
	applyBorrowedCovers(results)
	return results
}

// lyricSourceSkip 是"这个源这一轮要不要发请求"的三种答案。
type lyricSourceSkip int

const (
	lyricSourceQuery        lyricSourceSkip = iota // 正常查
	lyricSourceSkipDisabled                        // 用户在设置里关掉了——不发请求、不记账、不打日志
	lyricSourceSkipCooling                         // 熔断冷却中——不发请求,记 lyrics_sources_skipped
)

// noLyricsMarkers 把各源"曲库里有这首歌、但平台上没有歌词文本"这个结论,做成 Score:-1 的搭车标记带出
// rankLyricSourceResults —— 套路与 instrumentalMarker 一致(见 scoredLyricCandidateResult.TrackFoundNoLyrics 的头注),
// 不参与打分/排序、不会被 pickLyricCandidate 选中,手动搜索那边(searchcli.go filterEnabledLyricSources)过滤掉、
// 不显示成一条空候选。
//
// 与 instrumentalMarker 的三点不同:
//   - 不去重,命中几个源就出几条:界面要如实说"网易云音乐、QQ音乐 都找到了这首歌";
//   - 带上那个源实际匹配到的曲目元数据(Title/Artist/Album/自报时长),让弹窗能把"匹配到的就是这首歌"摆出来;
//   - 跟纯音乐互斥:某个源既被判纯音乐又说没词是自相矛盾,以纯音乐为准(各源自己的判据已经保证互斥,这里再挡一道,
//     免得日后哪个源的判据松了就冒出两条打架的结论)。
//
// 源序按 lyricSourceNames 固定,跟别处一样确定且可复现,不跟到达顺序走。
func noLyricsMarkers(raw map[string]lyricSourceResult, instrumental *scoredLyricCandidateResult) []scoredLyricCandidateResult {
	var out []scoredLyricCandidateResult
	for _, source := range lyricSourceNames {
		r, ok := raw[source]
		if !ok {
			continue
		}
		// 网易云这一路的结论挂在 ne 上(它整条信息走 neteaseInfo,不走 lyr 那几个字段),
		// 其余源统一走 lyricSourceResult.trackFoundNoLyrics。
		found := r.trackFoundNoLyrics
		title, artist, album, dur := r.matchTitle, r.matchArtist, r.matchAlbum, r.srcDur
		if source == "netease" {
			found = r.ne.TrackFoundNoLyrics
			title, artist, album, dur = r.ne.Title, r.ne.Artist, r.ne.Album, r.ne.DurationSecs
		}
		if !found {
			continue
		}
		if instrumental != nil && instrumental.Source == source {
			continue // ③ 纯音乐优先
		}
		out = append(out, scoredLyricCandidateResult{
			Source:                     source,
			Score:                      -1,
			TrackFoundNoLyrics:         true,
			Title:                      title,
			Artist:                     artist,
			Album:                      album,
			SourceReportedDurationSecs: dur,
		})
	}
	return out
}

// kugouSourceResult 把 kugouLyric / kugouLocalLyric 的产物摊成这一路的结果。抽出来是因为
// 酷狗有两个产出点(正常轮、熔断冷却时的本地兜底),字段散着写两遍迟早漏一个。
func kugouSourceResult(r kugouResult) lyricSourceResult {
	return lyricSourceResult{
		source: "kugou", lyr: r.lrc, yrc: r.yrc, tr: r.tr, roma: r.roma,
		matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover,
		srcDur: r.durationSecs, language: r.language, noVocals: r.noVocals,
		identityFromLocalClient: r.fromLocalClient,
	}
}

// lyricSourceSkipFor 决定一个源这一轮发不发请求(纯函数,给 fetchScoredLyricCandidatesStreaming 的 skipSource 用,
// 单测钉住"关掉的源不发请求、也不算冷却跳过")。关掉优先于冷却:一个既关掉又在冷却的源按"关掉"处理,不该因为它在
// 冷却就被记进 lyrics_sources_skipped 招来重搜。
func lyricSourceSkipFor(source string, enabled func(string) bool, plan lyricSourceRoundPlan) lyricSourceSkip {
	if !enabled(source) {
		return lyricSourceSkipDisabled
	}
	if _, cooling := plan[source]; cooling {
		return lyricSourceSkipCooling
	}
	return lyricSourceQuery
}

// fetchScoredLyricCandidatesStreaming 是实际实现:全部歌词源(含网易云)一起并发发出去,用带缓冲的 channel 收集结果。
// 网易云必须跟其它源同批起跑,别为了封面/跳转链接单独同步先查一遍:那等于把网易云自己最坏能到小三十秒的串行耗时原样
// 叠加在整体等待时间最前面。用 channel 而不是"WaitGroup + 共享变量":超时后放弃继续等、先用已到手的候选这件事是并发
// 安全的 —— 晚到的源往 channel 送结果不会阻塞(容量 = goroutine 数量),结果被直接丢弃。
//
// onUpdate 在每个源的结果到达后都会被调用一次,携带当前已知全部候选重新算出的完整排序结果,给 search-lyrics CLI 的
// "手动搜索陆续展示"用(searchcli.go)。每次都重算完整列表、不只是追加新来源:corroboratedEndings(见 match.go)是跨候选
// 互相印证的信号,后到的源可能让已经展示出来的候选分数往上修正。只关心最终结果的调用方传 nil:收集循环和追加轮的包装
// 见到 nil 就不重算中间结果。
func fetchScoredLyricCandidatesStreaming(ctx context.Context, artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	// 截止时间一到就返回,还没回来的源请求跟着取消:不然它们各自跑到自己的 HTTP 超时(网易云最坏接近 30 秒),
	// 全量扫库每首只隔几秒,残留请求会跟下一首的叠在一起抢出站配额。取消不计进源的熔断(sourcebreaker.go)。
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// 播放时的平台曲目 ID、本机客户端歌词按播放器原样标签记,用这一组查;查询词照旧用 artist / title / album。
	idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)
	// 交给各歌词源去搜、去挑候选的歌名:播放器报的歌名带编号时是带着编号的那一份(见 withLyricSourceTitle);
	// ISRC、平台曲目 ID、打分照旧用 title。
	srcTitle := lyricSourceTitleFor(ctx, title)
	// 缓冲开到"每个 goroutine 都能不阻塞地放下自己那一份"= 源数(每个源一个 goroutine)。同样不写
	// 字面量:下面那个 collect 循环就是栽在字面量跟源数脱钩上的。
	resultsCh := make(chan lyricSourceResult, len(lyricSourceNames))
	// 播放器自己的纯音乐信号能不能用:只对在放的那首和它的待播队列(见 playerSignalApplies)。
	forPlaying := playerSignalApplies(ctx)

	// 记下"这一组词真的问出去了"(见 querylog.go)。放在这里而不是五个重试轮各写一遍:
	// 这里是所有轮次唯一的实际发起点,漏不掉也不会重复。来路与"只问这几个源"的名单都从
	// ctx 上取(withLyricQueryReason / withLyricSourceOnly),没挂收集器时是空操作。
	lyricQueryLogFrom(ctx).record(artist, title, lyricQueryReasonFrom(ctx), lyricQueryOriginFrom(ctx), sortedLyricSourceOnly(ctx))

	// 源级熔断(sourcebreaker.go):起跑前算一次"谁在冷却中",冷却中的源不发请求、立刻回一个
	// 空结果——省掉的正是那 20 秒截止里白等的部分。被跳过的源记进 ctx 上的 round(没挂就
	// 不记,CLI 路径),由写缓存的那几层落到 lyrics_sources_skipped。
	breakerPlan := sharedLyricSourceBreaker().planRound(lyricSourceNames)
	round := lyricSourceRoundFrom(ctx)
	// 未启用的源这一轮**不发请求**(「没启用肯定就不查」)。无条件全查、只在
	// filterEnabledLyricSources / pickLyricCandidate 那步丢结果的话,关掉的源照样吃一份网络
	// 请求,而用户关掉一个源最常见的理由恰恰是"它在我这儿连不上 / 很慢"。代价要说清:
	//   - 网易云那一次查询顺带供着第①级封面(e.CoverURL = ne.Cover)和「网易云」跳转链接
	//     (e.NeteaseURL)。关掉网易云歌词源 = 这两样也不查:封面落到第②级 Apple Music、链接留空;
	//     needsPeripheralBackfill 相应地不再把"没有网易云链接"算缺项,否则每条都白补 5 轮。
	//   - amll-ttml-db 要网易云 / QQ 搜出来的曲目 ID,两个都关掉时它只剩 Apple / Spotify 的 ID 和在索引里按 ISRC /
	//     歌名找。手动搜索的可用情况面板对这种情形只显示笼统的「未给出候选」:searchcli.go 的 amll 派生
	//     规则只在网易云和 QQ **都带传输层失败代码**时才报 upstream_unreachable,而关掉的源不发
	//     请求、没有传输层记录,派生不了(要不要单加一个"上游已关闭"的代码另议)。
	//   - 语种 / 罗马音这些顺带信号(QQ / 酷狗的粤语标记等)自然也只来自开着的源。
	// 跟熔断跳过是两回事:不记 lyrics_sources_skipped(那是"冷却中"的记录,needsLyricsRetry 会据它
	// 择机重搜;关掉的源不该被重搜——用户以后再开,它在 lyrics_sources_responded 里缺席,照样会
	// 触发一次补搜),也不打日志(是设置,不是事件)。进度分母本来就只数开着的源,不受影响。
	only := lyricSourceOnlyFrom(ctx)
	skipSource := func(source string) bool {
		// 别名轮的"只查缺着的源"(withLyricSourceOnly):名单外的源静默跳过 ——
		// 它们在原名那一轮已经答过了,不重复打、不记账、不打日志。名单为 nil = 不限制。
		if only != nil && !only[source] {
			return true
		}
		switch lyricSourceSkipFor(source, lyricSourceEnabled, breakerPlan) {
		case lyricSourceSkipDisabled:
			return true
		case lyricSourceSkipCooling:
			round.markSkippedBecause(source, sharedLyricSourceBreaker().cooldownReason(source))
			log.Printf("lyrics: source %s skipped this round, cooling down for another %s", source, breakerPlan[source].Round(time.Second))
			return true
		}
		return false
	}

	// amll-ttml-db 按**平台音乐 ID**取歌词,所以它得等网易云/QQ 先把 ID 搜出来。
	// 用两个带缓冲的 channel 把 ID 递过去,而不是把查询塞进那两个 goroutine 里 ——
	// 那样会把 amll 的网络耗时串到它们头上,拖慢主力源的到达时间。
	neteaseIDCh := make(chan string, 1)
	qqIDCh := make(chan string, 1)

	go func() {
		if skipSource("netease") {
			neteaseIDCh <- ""
			resultsCh <- lyricSourceResult{source: "netease"}
			return
		}
		info := neteaseLookup(ctx, artist, srcTitle, album, durationSecs)
		if info.SongID > 0 {
			neteaseIDCh <- strconv.FormatInt(info.SongID, 10)
		} else {
			neteaseIDCh <- ""
		}
		resultsCh <- lyricSourceResult{source: "netease", ne: info}
	}()
	go func() {
		if skipSource("qq") {
			qqIDCh <- ""
			resultsCh <- lyricSourceResult{source: "qq"}
			return
		}
		// qqMusicMatchCached 本身也是一次网络请求(smartbox 搜索,6秒超时,按
		// artist|title|album 缓存)——挪进这个 goroutine 一起并发,不再是这个函数最
		// 前面的一步单独阻塞;resolveTrackEnrichment 那边为封面/跳转链接另外调用
		// qqMusicURL 时会命中这里可能已经写热的缓存,反过来也一样,谁先算出来谁写
		// 缓存,不要求哪边一定在前(两者共用同一份 qqURLCache,见 qq.go)。
		match := qqMusicMatchCached(ctx, artist, srcTitle, album, durationSecs)
		qqMid := qqMidFromURL(match.url)
		// 曲目 ID 一到手就交给 amll,不等下面取词:amll 只要 ID,等取词就是白等。
		qqIDCh <- qqMid
		var lyr, yrc, tr, roma string
		var qqDur float64
		var qqInstrumental, qqNoLyrics, qqPlainOnly bool
		var qqCover string
		if qqMid != "" {
			// 整行歌词与逐字(QRC)两套接口互不依赖,并发取。
			var qqLyr qqLyricResult
			lyricDone := make(chan struct{})
			go func() {
				defer close(lyricDone)
				qqLyr = qqLyric(ctx, qqMid)
			}()
			// 逐字(QRC)是完全独立的一套接口/密钥,自己失败不影响整行歌词——
			// 见 qq.go 顶部注释。同一份响应还带中文译文/罗马音两轨(见 qqQRCLyric 注释),
			// 时间戳与 qqLyric 的整行歌词逐行一致。
			qrc := qqQRCLyric(ctx, qqMid, artist, srcTitle, album, durationSecs)
			// qqCover:qqMid 这时已经是经过身份闸校验过的那首歌,不需要像 qqCoverFallback
			// (resolveTrackEnrichment 那条独立的封面兜底路径)那样另外核对 singer,直接取
			// cover 即可。查不到就留空(候选不拿别的封面兜底,见 rankLyricSourceResults)。
			// 排在 QRC 之后、不跟它并发:两边都读同一份单曲详情(qqSongDetail),QRC 走通时详情已在缓存里,
			// 并发的话两边同时没命中缓存,同一个详情请求会发两次。
			qqCover, _, _ = qqSongCoverAndSinger(ctx, qqMid)
			<-lyricDone
			// 整行接口没给词时用 QRC 压出来的整行,见 qqLineLyric。
			lyr, qqInstrumental, qqNoLyrics = qqLineLyric(qqLyr, qrc), qqLyr.instrumental, qqLyr.trackFoundNoLyrics
			// 只有不带时间戳的歌词时交成 plainOnly,见 qqPlainLyric。
			if lyr == "" {
				if lyr = qqPlainLyric(qqLyr, qrc); lyr != "" {
					qqPlainOnly = true
				}
			}
			yrc, tr, roma = qrc.yrc, qrc.tr, qrc.roma
			// QRC 正文里的 `[kana:…]` 假名标注行拼到整行歌词开头,App 侧 KanaAnnotation 才
			// 读得到(跟酷狗 LRC 自带的那一行同格式,见 qqQRCResult.kana 注释)。
			lyr = attachKanaLine(lyr, qrc.kana)
			// 专辑维度路线(resolveQQMatchViaAlbum)选中时曲目单里就带官方时长,直接用;
			// 否则只读缓存:QRC 那步走通时(它内部查过同一首的单曲详情)这里是热的,没走通
			// (会话拿不到 sid / 详情接口失败,那边不写负缓存)就留 0。srcDur 是纯透传的
			// 评测数据,不值得为它在歌词主路径上多挂一次最多 6s 的请求。
			qqDur = match.interval
			if qqDur <= 0 {
				qqDur = qqSongMetaCachedOnly(qqMid).interval
			}
		}
		// language 跟 qqDur 同一个只读缓存、同一条"QRC 那步走通时这里是热的"理由,见上面
		// qqDur 那行注释——不为它单独发请求。
		qqMeta := qqSongMetaCachedOnly(qqMid)
		qqLang := qqCanonicalLanguage(qqMeta.language)
		qqNoVocals := qqMeta.id != 0 && qqMeta.language == qqLanguagePureMusic
		resultsCh <- lyricSourceResult{source: "qq", lyr: lyr, yrc: yrc, tr: tr, roma: roma, matchTitle: match.title, matchArtist: match.artist, matchAlbum: match.album, matchCover: qqCover, srcDur: qqDur, language: qqLang, instrumental: qqInstrumental, noVocals: qqNoVocals, trackFoundNoLyrics: qqTrackFoundNoLyrics(qqNoLyrics, lyr, yrc), identityFromLocalClient: match.fromLocalLibrary, plainOnly: qqPlainOnly, trackIDs: qqTrackIDs(qqMid)}
	}()
	go func() {
		// 等两个 ID 都到齐再查。两个 goroutine 都是无条件启动的(源关掉 / 冷却中时
		// skipSource 那支也会往 channel 里送一个空串),所以这两个 channel 一定会收到值,
		// 不会在这里挂死。网易云 / QQ 都关掉时这里拿到两个空串,amllLyric 只剩 Apple / Spotify 的 ID
		// 和在索引里按 ISRC / 歌名找。
		neteaseID, qqID := <-neteaseIDCh, <-qqIDCh
		if skipSource("amll") {
			resultsCh <- lyricSourceResult{source: "amll"}
			return
		}
		// Apple / Spotify 的曲目 ID 由播放侧顺带记下(见 platformtrackid.go),这里只读。
		// 别名轮 / 拆分身份轮传的是改写过的署名,那时必然落空、退回只用上面两个 ID。
		appleCatalogID, spotifyTrackID := playbackTrackIDsFor(idArtist, idTitle, idAlbum)
		resultsCh <- lyricSourceResult{source: "amll", amll: amllLyric(ctx, amllQuery{
			neteaseID: neteaseID, qqID: qqID, appleCatalogID: appleCatalogID, spotifyTrackID: spotifyTrackID,
			isrc: lyricSourceISRC(ctx, artist, title, album), artist: artist, title: srcTitle, album: album,
			durationSecs: durationSecs, translationLang: features().LyricsTranslationLanguage,
		})}
	}()
	go func() {
		// 酷狗这一路**不能直接用 skipSource**:它比别的源多一条完全不经网络的路 ——
		// 客户端自己下在本地的 KRC(kugoulocal.go)。熔断冷却挡的是"别再打那台服务器了",
		// 而读本地文件跟服务器挂没挂毫无关系;恰恰是网络不通那阵子,本地那份最该顶上。
		// 所以冷却期间仍然问一次本地,只是不发请求。
		//
		// 三档区别:①别名轮的 only 名单外 —— 静默跳过(它上一轮已经答过);②用户在设置里
		// **关掉**了酷狗源 —— 那是"我不要酷狗的歌词",本地那份同样不要;③熔断冷却 ——
		// 只放弃网络那一半。本地命中时**不记 lyrics_sources_skipped**:这一轮它确实答了,
		// 记成跳过会让 needsLyricsRetry 以为缺了它、白重搜一轮。
		if only != nil && !only["kugou"] {
			resultsCh <- lyricSourceResult{source: "kugou"}
			return
		}
		switch lyricSourceSkipFor("kugou", lyricSourceEnabled, breakerPlan) {
		case lyricSourceSkipDisabled:
			resultsCh <- lyricSourceResult{source: "kugou"}
			return
		case lyricSourceSkipCooling:
			if r, ok := kugouLocalLyric(artist, srcTitle, album, durationSecs); ok {
				resultsCh <- kugouSourceResult(r)
				return
			}
			round.markSkippedBecause("kugou", sharedLyricSourceBreaker().cooldownReason("kugou"))
			log.Printf("lyrics: source kugou skipped this round, cooling down for another %s", breakerPlan["kugou"].Round(time.Second))
			resultsCh <- lyricSourceResult{source: "kugou"}
			return
		}
		resultsCh <- kugouSourceResult(kugouLyric(ctx, artist, srcTitle, album, durationSecs))
	}()
	go func() {
		if skipSource("lrclib") {
			resultsCh <- lyricSourceResult{source: "lrclib"}
			return
		}
		r := lrclibLyric(ctx, artist, srcTitle, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "lrclib", lyr: r.lyrics, yrc: r.yrc, roma: r.roma, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, srcDur: r.durationSecs, instrumental: r.instrumental, plainOnly: r.plainOnly}
	}()
	go func() {
		if skipSource("musixmatch") {
			resultsCh <- lyricSourceResult{source: "musixmatch"}
			return
		}
		// isrc 同 deezer 那路:有值时走 track.get?track_isrc= 直取,绕开这个源最松的那套
		// 名称搜索(见 musixmatch.go)。
		// Apple / Spotify ID 让它按录音级身份一次取齐(musixmatchmacro.go):播放器这一拍给的优先,没有就取缓存里存的。
		// 只在首轮取:补查轮换的是歌手别名,key 本来就对不上,按 ID 那一次首轮也已经试过。
		mxCtx := ctx
		if lyricQueryReasonFrom(ctx) == lyricQueryReasonPrimary {
			appleID, spotifyID := musixmatchTrackIDsFor(idArtist, idTitle, idAlbum)
			mxCtx = withMusixmatchPlaybackIDs(ctx, appleID, spotifyID)
		}
		r := musixmatchLyric(mxCtx, artist, srcTitle, durationSecs, features().LyricsTranslationLanguage, lyricSourceISRC(ctx, artist, title, album))
		resultsCh <- lyricSourceResult{source: "musixmatch", lyr: r.lrc, yrc: r.yrc, tr: r.tr, roma: r.roma, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: musixmatchResultCover(ctx, r), srcDur: r.durationSecs, plainOnly: r.plainOnly, instrumental: r.instrumental, performers: r.performers}
	}()
	go func() {
		if skipSource("lyricfind") {
			resultsCh <- lyricSourceResult{source: "lyricfind"}
			return
		}
		// ytmusicLyric 检索机制上是"查 YouTube Music",但对外只暴露真正是 LyricFind 的
		// 那部分(见 ytmusic.go 头注的过滤理由)——source 因此标 "lyricfind" 不是 "ytmusic"。
		r := ytmusicLyric(ctx, artist, srcTitle, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "lyricfind", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly, identityFromLocalClient: r.fromLocalClient}
	}()
	go func() {
		if skipSource("kuwo") {
			resultsCh <- lyricSourceResult{source: "kuwo"}
			return
		}
		r := kuwoLyric(ctx, artist, srcTitle, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "kuwo", lyr: r.lyrics, yrc: r.yrc, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs}
	}()
	go func() {
		if skipSource("migu") {
			resultsCh <- lyricSourceResult{source: "migu"}
			return
		}
		// 独立检索(不等任何其它源的 ID),同 kuwo;tr 是 trcUrl 拉回来的中文译文,多数曲目为空。
		r := miguLyric(ctx, artist, srcTitle, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "migu", lyr: r.lyrics, yrc: r.yrc, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly}
	}()
	go func() {
		if skipSource("deezer") {
			resultsCh <- lyricSourceResult{source: "deezer"}
			return
		}
		// 独立检索(不等任何其它源的 ID),同 kuwo/migu。搜索结果自带时长,srcDur 有值;
		// 没有同步歌词、只有纯文本时 plainOnly=true(分数恒 -1,见 deezer.go 头注)。
		//
		// isrc 有值时(Spotify 原生客户端在播、且它缓存里记了这条录音,见 spotifyisrc.go)
		// 走 /track/isrc: 直取,跳过搜索与名称打分——那是录音级身份,比名字硬。
		r := deezerLyric(ctx, artist, srcTitle, album, durationSecs, lyricSourceISRC(ctx, artist, title, album))
		resultsCh <- lyricSourceResult{source: "deezer", lyr: r.lyrics, yrc: r.yrc, tr: r.tr, songwriters: r.songwriters, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, isrc: r.isrc, plainOnly: r.plainOnly}
	}()
	go func() {
		if skipSource("applemusic") {
			resultsCh <- lyricSourceResult{source: "applemusic"}
			return
		}
		// 独立检索(不等任何其它源的 ID),同 kuwo/migu/deezer。这一路是全部源里唯一能给出
		// **逐字**时间轴的官方源,yrc 因此常有值;tr 来自 TTML 里的 <translations>,多数曲目为空。
		// 用户没连过 Apple Music 时它安静返回空(applemusic_not_connected),不是故障。
		// Apple 目录 id 由播放侧顺带记下(platformtrackid.go,同 amll 那路);有它就能先问
		// Music.app 自己的歌词缓存,拿到官方逐字 + 官方译文,见 applemusiclocal.go。
		// isrc 有值时(同 deezer 那路)先按 ISRC 直取这条录音,再按名字搜。
		appleID, _ := playbackTrackIDsFor(idArtist, idTitle, idAlbum)
		r := applemusicLyric(ctx, artist, srcTitle, album, durationSecs, appleID, lyricSourceISRC(ctx, artist, title, album))
		// 正在用 Apple Music 放、它自己没给这一条的歌词时,问一次这条录音有没有人声(播放器自己的信号,见 playerInstrumentalSource)。
		appleNoVocals := forPlaying && r.lyrics == "" && appleID != "" && playingPlayer() == playerAppleMusic && applemusicCatalogNoVocals(ctx, appleID)
		resultsCh <- lyricSourceResult{noVocals: appleNoVocals, source: "applemusic", lyr: r.lyrics, yrc: r.yrc, tr: r.tr, trLang: r.trLang, roma: r.roma, bg: r.bg, songwriters: r.songwriters, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, isrc: r.isrc, plainOnly: r.plainOnly, identityFromLocalClient: r.fromLocalClient || r.fromPlayerCatalogID || appleNoVocals}
	}()
	go func() {
		if skipSource("soda") {
			resultsCh <- lyricSourceResult{source: "soda"}
			return
		}
		// 曲目 id 先取汽水客户端的播放队列缓存,拿不到再按歌手 + 歌名搜索(见 soda.go 头注)。取词走无签名的 seo_track。
		r, noLyrics := sodaLyric(ctx, artist, srcTitle, album, durationSecs)
		// 曲目 id 来自汽水客户端的播放队列缓存时,同一份缓存里的 vocal==2 就是这一条没有人声(见 sodalocal.go)。
		noVocals := r.fromLocalClient && sodaLocalInstrumental(artist, srcTitle, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "soda", lyr: r.lyrics, yrc: r.yrc, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, trackFoundNoLyrics: noLyrics, noVocals: noVocals, identityFromLocalClient: r.fromLocalClient}
	}()
	go func() {
		if skipSource("vibe") {
			resultsCh <- lyricSourceResult{source: "vibe"}
			return
		}
		// 独立检索(不等任何其它源的 ID),同 kuwo / migu / deezer。只有纯文本时 plainOnly=true。
		r := vibeLyric(ctx, artist, srcTitle, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "vibe", lyr: r.lyrics, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly}
	}()
	go func() {
		if skipSource("genie") {
			resultsCh <- lyricSourceResult{source: "genie"}
			return
		}
		// 独立检索,同 vibe。只有纯文本时 plainOnly=true。
		r := genieLyric(ctx, artist, srcTitle, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "genie", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly}
	}()
	go func() {
		if skipSource("petitlyrics") {
			resultsCh <- lyricSourceResult{source: "petitlyrics"}
			return
		}
		// 独立检索,同 vibe。只有纯文本时 plainOnly=true。
		r := petitLyric(ctx, artist, srcTitle, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "petitlyrics", lyr: r.lyrics, yrc: r.yrc, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, isrc: r.isrc, plainOnly: r.plainOnly}
	}()

	// raw:目前为止到手的各源原始应答,按源名存。打分/排序全部下放给
	// rankLyricSourceResults(包级纯函数,回归金标集与生产共用),这里只负责收结果、喂进去。
	raw := map[string]lyricSourceResult{}
	// KKBOX 本地歌词不是歌词源,不进上面那组并发(源清单、进度分母、收集循环都只数歌词源):正在用 KKBOX 放歌时,
	// 开搜之前读一次它自己的缓存(本机文件,毫秒级),有就当一份候选放进去(见 kkboxlyrics.go)。
	//
	// 只在首轮读:它按时长就认得出这首,跟查询用的歌手写法无关,别名轮 / 反查轮里再放一份,会被当成「这个别名救回了
	// 候选」。首轮那份靠 mergeLyricCandidateRounds 的只增不减留到最后。
	if lyricQueryReasonFrom(ctx) == lyricQueryReasonPrimary {
		if r, ok := kkboxLocalLyricsFor(idArtist, idTitle, durationSecs); ok {
			raw[kkboxLocalLyricsSource] = r
		}
		// Spotify 本地歌词同理(Musixmatch 的备用管道,见 spotifylyrics.go),不看当前播放器:按曲目 ID 找得到就放。
		if r, ok := spotifyLocalLyricsFor(idArtist, idTitle, idAlbum); ok {
			raw[spotifyLocalLyricsSource] = r
		}
		// 正在用 Spotify 放时,换曲那一拍记下的曲目在它元数据缓存里没有人声:播放器自己的信号(见 playerInstrumentalSource)。
		if forPlaying && playingPlayer() == playerSpotify && spotifyLocalNoVocals(spotifyTrackIDHintFor(idArtist, idTitle)) {
			r := raw[spotifyLocalLyricsSource]
			r.source, r.noVocals, r.identityFromLocalClient, r.forPlayingTrack = spotifyLocalLyricsSource, true, true, true
			raw[spotifyLocalLyricsSource] = r
		}
		// Amazon Music 本地歌词同 KKBOX:正用它放歌时读,按 ASIN 认这首(见 amazonlibrary.go)。
		if r, ok := amazonLocalLyricsFor(idArtist, idTitle, idAlbum); ok {
			raw[amazonLocalLyricsSource] = r
		}
		// reAMP 正在放的文件同目录同名的 .lrc 同 KKBOX:正用它放这首时读(见 localfilelyrics.go)。
		if r, ok := localFileLyricsFor(idArtist, idTitle, durationSecs); ok {
			raw[localFileLyricsSource] = r
		}
		// 洛雪存下的原版歌词同 KKBOX:正用洛雪放这首时读(见 lxmusic.go)。
		if r, ok := lxMusicLocalLyricsFor(ctx, idArtist, idTitle, durationSecs); ok {
			raw[lxMusicLocalLyricsSource] = r
		}
		for s, r := range raw {
			raw[s] = withoutPlayerIdentity(ctx, r)
		}
	}
	// scoreAndSort 用目前为止已经到手的原始结果重新构建候选、算 corroboratedEndings、
	// 打分、排序——每次有新结果到达都会重新跑一遍(而不是缓存增量),因为一份候选的
	// corroborated 状态可能随后到的源变化(见上面 onUpdate 的注释),分数不是只增不改
	// 的东西,不能靠增量更新蒙混过去。
	scoreAndSort := func() []scoredLyricCandidateResult {
		return rankLyricSourceResults(artist, title, album, durationSecs, raw)
	}

	deadline := time.After(lyricSearchDeadline)
	// 哪些歌词源已经回来了。按名字记,进度分母只数开着的源(见 enabledDone)。
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
	// 收够每一个源各自的那一份,按 lyricSourceNames 逐个核对,别钉一个字面量:硬编码的数字跟源数没绑在一起,每加一个源
	// 循环就会先数满退出、把最后到达的那个源的应答扔掉(amll 最容易中招:它要等网易云/QQ 先把音乐 ID 搜出来,结构性地
	// 总是最后回)。源清单是加源时必须改的那一处(lyricSourceNames 有守卫钉着,见 lyricsourceregistry_test.go)。
	// 超时/取消两条分支照旧兜底,不会因为某个 goroutine 没发结果而卡死。
	//
	// 这里只该有歌词源:给候选兜底封面的 iTunes 查询在出站闸排队时后台请求最多等 30 秒,比这里的 20 秒截止还长,放进来
	// 会让截止几乎总是只差它一份(见 09 章决策 93)。
	allLyricSourcesBack := func() bool {
		for _, s := range lyricSourceNames {
			if !doneSources[s] {
				return false
			}
		}
		return true
	}
	// 首轮中途先上屏(见 earlylyrics.go):只有首次解析正在播的这首、第一轮才有,别的情况是 nil,下面几处都是空操作。
	// 它不在等的时候别为它打分:自动解析不要中间结果,每到一个源整份重打分是白算(见 09 章决策 94)。
	earlyWatch := newEarlyLyricsWatch(ctx, artist, title, durationSecs)
	if earlyWatch != nil && forPlaying {
		earlyWatch.holdForNative = playerLocalNoVocalsHint(artist, srcTitle, album, durationSecs)
	}
collect:
	for !allLyricSourcesBack() {
		select {
		case r := <-resultsCh:
			doneSources[r.source] = true
			r = withoutPlayerIdentity(ctx, r)
			r.forPlayingTrack = forPlaying
			raw[r.source] = r
			if lyricSourceResultTap != nil {
				lyricSourceResultTap(r)
			}
			if onUpdate != nil || earlyWatch.active() {
				scored := scoreAndSort()
				if onUpdate != nil {
					onUpdate(raw["netease"].ne, scored, enabledDone(), totalSources)
				}
				earlyWatch.observe(raw["netease"].ne, scored, doneSources)
			}
		case <-earlyWatch.graceC():
			earlyWatch.endGrace()
			earlyWatch.observe(raw["netease"].ne, scoreAndSort(), doneSources)
		case <-deadline:
			log.Printf("lyrics: search deadline (%s) hit for artist=%q title=%q, proceeding with %d/%d sources back", lyricSearchDeadline, artist, title, enabledDone(), totalSources)
			for _, s := range lyricSourceNames {
				if !doneSources[s] {
					noteLyricDeadlineMiss(ctx, s)
				}
			}
			break collect
		case <-ctx.Done():
			// 用户主动取消(见 enrichcancel.go)——不用等剩下的源真的把 in-flight 请求
			// 中断完、逐个把(大概率是空的)结果送进 resultsCh,直接收工。各 goroutine
			// 自己的请求已经因为 ctx 被取消而中断,不会真的卡着不退出,只是不再等它们了。
			break collect
		}
	}
	earlyWatch.finish(enabledDone(), totalSources)

	return raw["netease"].ne, scoreAndSort()
}

// loadEnrichCache reads the persisted enrichment cache (best-effort) and sets the
// path future saves write to. Call once at startup.
func loadEnrichCache(path string) {
	enrichPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		// 文件不存在是首次启动的正常情况;别的读错误(权限、I/O、打开文件数上限……)不等于没有:静默当成空库,接下来
		// 第一次保存就会把整个缓存(连同手工修过的歌词)盖成几条新数据。所以这个进程不写它,见 refuseEnrichSavesThisRun。
		if !os.IsNotExist(err) {
			refuseEnrichSavesThisRun()
			slog.Error("load enrich cache failed — running without saving, existing file left untouched", "err", err)
			return
		}
		// 主缓存还没有(新装后头一次整份落盘之前):上一次退出前写下的待落盘小文件照样叠回来,不然那批改动就丢了。
		applyEnrichPendingAtLoad(path)
		return
	}
	var m map[string]enrichEntry
	if err := json.Unmarshal(data, &m); err != nil || m == nil {
		// 解析不动就把原文件挪到一边保住,绝不留在原位等着被后续保存覆盖。名字带时间:再坏一次时
		// 不盖掉上一份(跟 App 放弃坏配置文件同一个命名)。
		suffix := ".corrupt-" + time.Now().Format("20060102-150405")
		side := path + suffix
		if renameErr := os.Rename(path, side); renameErr == nil {
			moveEnrichSideDirsAside(path, suffix)
			enrichMu.Lock()
			lyricsImportRestoreAll = true
			enrichLoadMovedAside = true
			enrichMu.Unlock()
			log.Printf("enrich cache unreadable (%v) — moved aside to %s, starting empty", err, side)
		} else {
			refuseEnrichSavesThisRun()
			slog.Error("enrich cache unreadable and could not move aside — running without saving", "err", err, "rename_err", renameErr)
		}
		return
	}
	// 正文在小文件里的条目补回正文,见 enrichbodyload.go。
	bodies := hydrateEnrichBodies(m, enrichBodiesDirFor(path))
	// 正文小文件缺了的那几条连主歌词都没有了:启动那次导入要让 lyrics/ 里的文件把它们补回来,见 lyricsImportRestoreKeys。
	lyricsImportRestoreKeys = bodies.missingSet
	moveUnreadableBodiesAside(bodies.unreadable)
	enrichDiskFullFormat = bodies.full > 0
	shared := shareIdenticalDecisions(m) // 内存里两槽相同的判决记录共用一个对象,见 enrichdedupe.go
	enrichMu.Lock()
	enrichCache = m
	canonicalMemoReset()
	enrichMu.Unlock()
	applyEnrichPendingAtLoad(path)
	log.Printf("cache: loaded %d track enrichments from %s (%d identical decision pairs shared)", len(m), path, shared)
	bodies.log()
	warnEnrichUnknownKeys(m) // 见 enrichjson.go:非零 = 这个构建比缓存文件老
}

// enrichLoadFailed:这次启动主缓存读不进来、原文件又还在原位(读出错,或解析不动又挪不走)。
var enrichLoadFailed bool

// enrichLoadMovedAside:这次启动主缓存解析不动、挪成了 `.corrupt-*`,从空库起步。持 enrichMu。
var enrichLoadMovedAside bool

// refuseEnrichSavesThisRun 让这个进程从空库跑、但什么都不落盘:清空 enrichPath 后 saveEnrichCache、
// 精简索引、正文小文件、判决旁路文件的写入和启动清扫全是空操作,原文件原样留给下次启动再读。
// 启动那次导入按「文件全赢」把歌词从 lyrics/ 补回内存,这一场照常出词。
func refuseEnrichSavesThisRun() {
	enrichMu.Lock()
	enrichPath = ""
	enrichLoadFailed = true
	lyricsImportRestoreAll = true
	enrichMu.Unlock()
}

// moveEnrichSideDirsAside 主缓存挪成坏文件之后,把它的正文小文件目录、判决旁路目录一起挪到旁边(同一个后缀)。
// 精简格式的主缓存里只剩元数据和主歌词,译文 / 罗马音 / 逐字 / 纯文本 / 背景人声都只在正文小文件里:
// 留在原位的话,从空库起的这一场会按 lyrics/ 重建的条目重写它们、再把 lyrics/ 里没有的那些当孤儿清掉,
// 手工救回坏文件时要用的另一半就没了。挪不走只记一笔,不影响启动。
func moveEnrichSideDirsAside(cachePath, suffix string) {
	dirs := []string{enrichBodiesDirFor(cachePath), filepath.Join(filepath.Dir(cachePath), clientName+"-decisions")}
	for _, dir := range dirs {
		if _, err := os.Stat(dir); err != nil {
			continue
		}
		if err := os.Rename(dir, dir+suffix); err != nil {
			slog.Error("enrich cache unreadable: could not move side directory aside", "dir", dir, "err", err)
		}
	}
}

// saveEnrichCache atomically writes the cache when dirty (temp file + rename).
//
// enrichSaveMu 罩住 marshal→write→rename 全程,两个并发保存**串行**执行。不串行会
// 翻两种车:①两个保存都用 pid 命名的同一个 tmp 文件,先 rename 的把对方的文件偷走,
// 后 rename 的报 no such file;②更毒的是慢的那个拿着**过期快照**最后落盘,把新数据
// 盖回老状态。tmp 文件也用 os.CreateTemp 的随机名,同名互踩从根上不可能。
//
// enrichMu 只罩住浅拷贝那一步,marshal 在锁外做:整份缓存上千条时 marshal 是秒级的,持锁期间
// poll 循环、网页中继和所有解析路径都在等这把锁。锁外 marshal 成立的前提是 enrichCache 里
// 的条目**只整条替换、不原地改**——条目里的指针 / 切片 / map(LyricsDecision、
// LyricsDecisionApplied、LyricsSources*、Unknown)存进缓存之后不能再被写。
var enrichSaveMu sync.Mutex

func saveEnrichCache() {
	_ = saveEnrichCacheChecked() // 失败已经记过日志,脏标记也还原了,下一次保存 / 退出前那次会再写
}

// errEnrichCacheNotLoaded:这次启动主缓存没读进来,这个进程不写它(见 refuseEnrichSavesThisRun)。
var errEnrichCacheNotLoaded = errors.New("enrich cache could not be loaded this run; not saving over it")

// saveEnrichCacheChecked 同 saveEnrichCache,把失败交回给要告诉别人的调用方(apply-enrich-edit 回给 App)。
func saveEnrichCacheChecked() error {
	enrichSaveMu.Lock()
	defer enrichSaveMu.Unlock()
	start := time.Now()
	enrichMu.Lock()
	if !enrichDirty || enrichPath == "" {
		failed := enrichDirty && enrichLoadFailed
		enrichMu.Unlock()
		if failed {
			return errEnrichCacheNotLoaded
		}
		return nil
	}
	snapshot := make(map[string]enrichEntry, len(enrichCache))
	pendingSeq := enrichPendingSeqLocked()
	// 判决记录的候选明细不进主缓存:还带着明细的条目在这里拆开,明细先写旁路文件、内存里换成去掉
	// 明细的那一份(见 decisionstore.go)。整条替换,不原地改 —— 下面锁外 marshal 的前提不变。
	var sidecars []decisionSidecarJob
	for k, v := range enrichCache {
		if stripped, job, ok := splitDecisionDetails(k, v); ok {
			enrichCache[k] = stripped
			v = stripped
			sidecars = append(sidecars, job)
		}
		snapshot[k] = v
	}
	enrichDirty = false
	enrichMu.Unlock()
	// 先写旁路文件、再写主缓存:主缓存里那一槽一旦落盘,读的一方就会去找它的明细。
	writeDecisionSidecars(sidecars)
	// 正文小文件也在主缓存之前(只写变了的那几首):主缓存里正文已经写好的条目只存精简那一条,正文只在
	// 小文件里(见 enrichbodyload.go)。索引在主缓存之后、最后落盘,是指向主缓存的硬链接(见 enrichindex.go)。
	bodyCRCs := writeEnrichBodies(snapshot)
	disk := snapshot
	if backupFullEnrichCacheOnce() {
		disk = leanEnrichSnapshot(snapshot, bodyCRCs)
	}
	tmp, err := os.CreateTemp(filepath.Dir(enrichPath), filepath.Base(enrichPath)+".tmp.*")
	if err != nil {
		slog.Error("save enrich cache", "err", err)
		return enrichSaveFailed(err)
	}
	// 流式写,不再先 Marshal 出整份再一次写入(一次保存临时分配约 680 MB,见 enrichsave.go 头注)。
	if err := writeEnrichSnapshot(tmp, disk); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		slog.Error("save enrich cache", "err", err)
		return enrichSaveFailed(err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		slog.Error("save enrich cache", "err", err)
		return enrichSaveFailed(err)
	}
	if err := os.Rename(tmp.Name(), enrichPath); err != nil {
		os.Remove(tmp.Name())
		slog.Error("save enrich cache", "err", err)
		return enrichSaveFailed(err)
	}
	linkEnrichIndex(snapshot, bodyCRCs)
	enrichPendingSavedThrough(pendingSeq)
	noteSongEntityCacheSaved()
	logEnrichSave(len(disk), start)
	return nil
}

// enrichSaveFailed 写盘失败时把脏标记还原:快照取完就清了它,不还原的话这批改动只活在内存里,
// 退出前 flushEnrichSave 看到「不脏」直接跳过,就这么丢了。
func enrichSaveFailed(err error) error {
	enrichMu.Lock()
	enrichDirty = true
	enrichMu.Unlock()
	return err
}

// maxNotedPlayers:一条写法最多记几个播放器(同一种写法通常只出自一两个播放器)。
const maxNotedPlayers = 8

// notePlayerLocked:把 bundleID 记进 e.Players(已经有、空串、记满了都不动),返回记没记。调用方持 enrichMu。
func notePlayerLocked(e *enrichEntry, bundleID string) bool {
	if bundleID == "" || len(e.Players) >= maxNotedPlayers || slices.Contains(e.Players, bundleID) {
		return false
	}
	e.Players = append(e.Players, bundleID)
	return true
}

// notePlayerSongIDLocked:把 bundleID 这个播放器自己报的这一首的歌曲 id 记进 e.PlayerSongIDs(换成最近一次的;空串不记),
// 返回改没改。没有专辑 id 可记时用它,同 notePlayerSongLocked(e, bundleID, id, "")。调用方持 enrichMu。
func notePlayerSongIDLocked(e *enrichEntry, bundleID, id string) bool {
	return notePlayerSongLocked(e, bundleID, id, "")
}

// notePlayerSongLocked:bundleID 这个播放器报的这一首,歌曲 id 记进 PlayerSongIDs,同一拍读到的专辑 id 记进 PlayerAlbumIDs。
// 两张表成对:歌曲 id 换了、没给新的专辑 id 时,旧的专辑 id 跟着删;同一首这一拍没读到专辑的,记下的留着。空的歌曲 id 不记。
// 返回改没改。换整张表、不原地改:条目是值拷贝,表跟落盘那份快照共用。调用方持 enrichMu。
func notePlayerSongLocked(e *enrichEntry, bundleID, songID, albumID string) bool {
	if bundleID == "" || songID == "" {
		return false
	}
	changed := false
	if e.PlayerSongIDs[bundleID] != songID {
		e.PlayerSongIDs = withBundleValue(e.PlayerSongIDs, bundleID, songID)
		if albumID == "" && e.PlayerAlbumIDs[bundleID] != "" {
			e.PlayerAlbumIDs = withBundleValue(e.PlayerAlbumIDs, bundleID, "")
		}
		changed = true
	}
	if albumID != "" && e.PlayerAlbumIDs[bundleID] != albumID {
		e.PlayerAlbumIDs = withBundleValue(e.PlayerAlbumIDs, bundleID, albumID)
		changed = true
	}
	return changed
}

// withBundleValue:m 的副本,bundleID 那一项换成 v(空串删掉;删空了返回 nil)。
func withBundleValue(m map[string]string, bundleID, v string) map[string]string {
	out := make(map[string]string, len(m)+1)
	for k, x := range m {
		out[k] = x
	}
	if v == "" {
		delete(out, bundleID)
	} else {
		out[bundleID] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// reportedName:播放器原样报的歌名、歌手、专辑(App 送来的那一份,没经 enrichKey 归一化)。
type reportedName struct {
	Title  string `json:"title,omitempty"`
	Artist string `json:"artist,omitempty"`
	Album  string `json:"album,omitempty"`
}

// noteReportedNameLocked:bundleID 这一拍原样报的 r 跟写法键 key 拆出来的三段(歌名去掉时长变体位标记)不一样时记进
// e.Reported(换掉这个播放器上次记的),一样时删掉这个播放器原来记的;记满 maxNotedPlayers 个不再加新播放器。返回改没改。
// 换整张表、不原地改:条目是值拷贝,表跟落盘那份快照共用。调用方持 enrichMu。
func noteReportedNameLocked(e *enrichEntry, key, bundleID string, r reportedName) bool {
	if bundleID == "" {
		return false
	}
	artist, title, album := splitEnrichKey(key)
	old, had := e.Reported[bundleID]
	same := r == reportedName{Title: songDurVariantRe.ReplaceAllString(title, ""), Artist: artist, Album: album}
	switch {
	case same && !had, !same && had && old == r, !same && !had && len(e.Reported) >= maxNotedPlayers:
		return false
	}
	out := make(map[string]reportedName, len(e.Reported)+1)
	for k, v := range e.Reported {
		out[k] = v
	}
	if same {
		delete(out, bundleID)
	} else {
		out[bundleID] = r
	}
	if len(out) == 0 {
		out = nil
	}
	e.Reported = out
	return true
}

// playerIDFields:只在用某个播放器放这首时才写进条目的那几样 id,和那个播放器。条目有其中一样,就说明那个播放器放过,
// 跟 notePlayerLocked 当场记下的一样算数。别把按歌名搜出来的链接(NeteaseURL、QQURL、AppleURL、SpotifyURL)加进来,
// 那几样不说明谁放过。App 侧 SongVersions.players 没有记录时按同一张表推断,两处同步改。
var playerIDFields = []struct {
	bundleID string
	id       func(e *enrichEntry) string
}{
	{spotifyBundleID, func(e *enrichEntry) string { return e.SpotifyTrackID }},
	{kkboxBundleID, func(e *enrichEntry) string { return e.KKBOXURL }},
	{amazonMusicBundleID, func(e *enrichEntry) string { return e.AmazonURL }},
	{sodaMusicBundleID, func(e *enrichEntry) string { return e.SodaURL }},
	{kasetBundleID, func(e *enrichEntry) string { return e.YouTubeMusicURL }},
}

// notePlayersFromRecords:把条目里 playerIDFields 那几样 id 对应的播放器,和 PlayerCovers、PlayerSongIDs 的键(播放器自己给
// 这首记的封面、报的歌曲 id,只在用它放时写)记进 e.Players(规则同 notePlayerLocked),返回记没记。
func notePlayersFromRecords(e *enrichEntry) bool {
	changed := false
	for _, f := range playerIDFields {
		if f.id(e) != "" && notePlayerLocked(e, f.bundleID) {
			changed = true
		}
	}
	for _, m := range [...]map[string]string{e.PlayerCovers, e.PlayerSongIDs} {
		for _, b := range songSortedKeys(m) {
			if notePlayerLocked(e, b) {
				changed = true
			}
		}
	}
	return changed
}

// migratePlayersFromRecords:存量条目按 notePlayersFromRecords 补记播放器(18 章决策 39、42)。运行期在 trackEnrichment 和
// mergePeripheralInto 里做同一件事;不挂水位,每次启动都扫一遍(近万条只要几毫秒,没改动不落盘),配置搬家进来的
// 条目也能补上。
func migratePlayersFromRecords() {
	enrichMu.Lock()
	n := 0
	for k, e := range enrichCache {
		if notePlayersFromRecords(&e) {
			enrichCache[k] = e
			n++
		}
	}
	if n > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if n > 0 {
		log.Printf("enrich: noted players from player-provided ids and covers on %d entries", n)
		saveEnrichCache()
	}
}

// migratePlayersFromAppleAnchors:Apple 链接就是 Apple Music 播放时报的目录锚点(appleCatalogCache 里有这个曲目 id)、写法键跟
// 锚点的歌手、歌名、专辑按 enrichKey 算出来的完全相同(歌名去掉时长变体位)的存量条目,补记 Apple Music 放过(18 章决策 64),
// 没记过它报的歌曲 id 的把锚点 id 记上(决策 65)。Apple Music 报的就是曲库自己的名字,逐字相同才认:别的播放器的写法借了
// 锚点链接的,名字对不上。不挂水位,每次启动扫一遍,没改动不落盘。锚点在 appleCatalogMu 后面,先抄出来再取 enrichMu。
func migratePlayersFromAppleAnchors() {
	appleCatalogMu.Lock()
	anchorKeys := make(map[string]string, len(appleCatalogCache))
	for id, t := range appleCatalogCache {
		anchorKeys[id] = legacyEnrichKey(t.ArtistName, t.TrackName, t.AlbumName)
	}
	appleCatalogMu.Unlock()
	enrichMu.Lock()
	n := 0
	for k, e := range enrichCache {
		id := appleCatalogIDFromURL(e.AppleURL)
		want, ok := anchorKeys[id]
		if !ok || (slices.Contains(e.Players, appleMusicBundleID) && e.PlayerSongIDs[appleMusicBundleID] != "") {
			continue
		}
		artist, title, album := splitEnrichKey(k)
		if legacyEnrichKey(artist, enrichKeyDurationVariantRe.ReplaceAllString(title, ""), album) != want {
			continue
		}
		changed := notePlayerLocked(&e, appleMusicBundleID)
		if e.PlayerSongIDs[appleMusicBundleID] == "" && notePlayerSongIDLocked(&e, appleMusicBundleID, id) {
			changed = true
		}
		if changed {
			enrichCache[k] = e
			n++
		}
	}
	if n > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if n > 0 {
		log.Printf("enrich: noted Apple Music on %d entries whose link is the catalog anchor it reported", n)
		saveEnrichCache()
	}
}

// migrateListenDurations:没有时长的条目从收听记录里补播放器当时报的时长(18 章决策 42)。只认 key 对得上、记了时长的收听;
// 几次收听的时长互相差过 durationMismatch 的不补(说不准是哪一段录音)。运行期 trackEnrichment 放到时自己补,存量只补一次。
// readListens 给出收听记录:水位到了整道跳过时不调它(收听日志是整份读,可能几 MB)。
func migrateListenDurations(readListens func() []listenLogLine) {
	scope := migrationScopeOf(migrationListenDurations, migrationListenDurationsVersion)
	if scope.skip() {
		return
	}
	durs := map[string][]float64{}
	for _, l := range readListens() {
		if l.T == "l" && l.DUR > 0 && l.TI != "" {
			k := enrichKey(l.AR, l.TI, l.AL)
			durs[k] = append(durs[k], l.DUR)
			// 旧规则建的条目按去括号后的歌名找(收听记录里是原样歌名)。
			if lk := legacyEnrichKey(l.AR, l.TI, l.AL); lk != k {
				durs[lk] = append(durs[lk], l.DUR)
			}
		}
	}
	enrichMu.Lock()
	n := 0
	for k, e := range scope.entries() {
		ds := durs[k]
		if e.DurationSecs > 0 || len(ds) == 0 || slices.ContainsFunc(ds, func(d float64) bool { return durationMismatch(ds[0], d) }) {
			continue
		}
		e.DurationSecs = ds[len(ds)-1]
		enrichCache[k] = e
		n++
	}
	if n > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if n > 0 {
		log.Printf("enrich: filled duration from the listen log on %d entries", n)
		saveEnrichCache()
	}
	markMigrationDone(migrationListenDurations, migrationListenDurationsVersion)
}
