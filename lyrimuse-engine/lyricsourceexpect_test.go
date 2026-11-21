package main

import (
	"context"
	"net"
	"slices"
	"strings"
)

// 登记表(lyricprovider.go)的期望值。生产代码里名单、顺序、轮次、哪几路是播放器本机、近况统计的同类组、专用探测曲、
// 来源链接、按 ISRC 补取、出站的归源、速率与额度(主机归源、主机速率、在途上限、小时额度、每日额度留量、代理回退)、候选装配、
// 括号背景人声、假名标注、共识家族、词曲作者名单取谁的、纯文本回退的档位、播放器自己的无人声信号、
// 顺序优先里本机类来源排在哪、别名轮里等编号的源留不留这几类只读登记表里的描述符,两种失败原因问源的可选接口;这里是同一份事实冻结在测试里的写法,lyricproviderregistry_test.go
// 逐项比「登记表推出来的 == 这里」。加减来源、改描述符里这几类字段,要同步改这里。
// 别的测试拿这几张表当「全部联网源」「决胜序」的输入;App 的 selftest 从这个文件抠 lyricSourceNames 的字面量跟
// LyricsSource.allCases 比:那张表保持整张写在一行里,这个文件里别处(含注释)不要再出现它的声明写法。

// lyricSourceNames:联网歌词源,按源名单里的先后(ProviderDescriptor.Order)。
var lyricSourceNames = []string{"netease", "qq", "kugou", "lrclib", "amll", "lyricfind", "kuwo", "migu", "deezer", "applemusic", "soda", "vibe", "genie", "petitlyrics", "zing", "megalobiz"}

// lyricCandidateTieOrder:全部来源的同分决胜序(ProviderDescriptor.TieRank)。
var lyricCandidateTieOrder = []string{
	"netease", "qq", "kugou", "lrclib", "lyricfind", "kuwo", "migu", "deezer", "applemusic", "soda", "vibe", "genie", "petitlyrics", "zing", "megalobiz",
	kkboxLocalLyricsSource, amazonLocalLyricsSource, lxMusicLocalLyricsSource, localFileLyricsSource, importLyricsSource,
	spotifyLocalLyricsSource,
	"amll",
}

// lyricsSourceDefaultOrder:联网源在顺序优先模式里的默认顺序(ProviderDescriptor.DefaultPriorityRank)。
var lyricsSourceDefaultOrder = []string{
	lyricSourceKugou, lyricSourceNetease, lyricSourceQQ, lyricSourceLRCLIB,
	lyricSourceAMLL, lyricSourceLyricFind, lyricSourceKuwo, lyricSourceMigu, lyricSourceDeezer,
	lyricSourceAppleMusic, lyricSourceSoda, lyricSourceVibe, lyricSourceGenie, lyricSourcePetitLyrics, lyricSourceZing,
	lyricSourceMegalobiz,
}

// lyricSourceOnDemandOnly:只在用户实际在听、在找的时候问的源(ProviderDescriptor.Rounds 是 roundsOnDemand)。
var lyricSourceOnDemandOnly = map[string]bool{lyricSourceMegalobiz: true}

// isPlayerLocalLyricSource:读播放器本机数据的那几路(ProviderDescriptor.Kind 是 providerKindPlayerLocal),导入库不算。
func isPlayerLocalLyricSource(source string) bool {
	return source == kkboxLocalLyricsSource || source == spotifyLocalLyricsSource || source == amazonLocalLyricsSource ||
		source == lxMusicLocalLyricsSource ||
		source == localFileLyricsSource
}

// lyricSourcePeerGroups:近况统计的同类组(ProviderDescriptor.PeerGroup),组内按源名单的先后。
var lyricSourcePeerGroups = [][]string{
	{"netease", "qq", "kugou", "kuwo", "migu", "soda"},
	{"lrclib", "lyricfind", "deezer", "applemusic"},
}

// lyricSourceOwnProbeTracks:配了专用探测曲的源和各自那一首(ProviderDescriptor.Probe)。
var lyricSourceOwnProbeTracks = map[string]ProbeTrack{
	lyricSourceZing: {Artist: "Sơn Tùng M-TP", Title: "Lạc Trôi"},
	lyricSourceSoda: {Artist: "陈奕迅", Title: "十年"},
}

// lyricSourcePageURL:source 这个源的歌词页地址核过之后的样子(ProviderDescriptor.PageURL);不是要链回的源、地址不对时为空。
func lyricSourcePageURL(source, raw string) string {
	switch source {
	case lyricSourceMegalobiz:
		return megalobizPageURL(raw)
	case "amll":
		return amllPageURL(raw)
	}
	return ""
}

// isrcRetryableSources:能按 ISRC 直取的歌词源(ProviderDescriptor.ISRCLookup 是 isrcLookupDirect)。
var isrcRetryableSources = []string{"deezer"}

// isrcIndexedSources:本地索引里有这个 ISRC 才问的歌词源(ISRCLookup 是 isrcLookupIndexed)。
var isrcIndexedSources = []string{"amll"}

// lyricSourceOwnProbeCalls:各源的专用探测在源码里问的那一句(OwnProbeProvider.ProbeOwnTrack 的函数体里)。汽水走搜索那条路,
// 不看本地队列缓存。
var lyricSourceOwnProbeCalls = map[string]string{
	lyricSourceZing: `return zingLyric(ctx, t.Artist, t.Title, "", 0).lyrics != ""`,
	lyricSourceSoda: `r, _ := sodaLyricBySearch(ctx, t.Artist, t.Title, "", 0)`,
}

// lyricSourceQueryIndependentFailers:带着「跟检索词无关的失败原因」时补查轮不问的源(实现 QueryIndependentFailer 的)。
var lyricSourceQueryIndependentFailers = []string{"lyricfind", "deezer", "applemusic", "zing"}

// lyricSourceFailureDiagnosers:手动搜索的可用情况和设置页「测试」显示专属失败原因的源(实现 FailureDiagnoser 的)。
// 跟上面那一组不是同一组。
var lyricSourceFailureDiagnosers = []string{"netease", "lyricfind", "deezer", "soda", "zing"}

// expectedHostRateFor:各主机的令牌桶参数(歌词源主机的出自 ProviderDescriptor.HostRates,另两个不是歌词源的主机写在
// hostRateFor 里)。
func expectedHostRateFor(host string) hostRate {
	switch host {
	case "itunes.apple.com":
		// Search API 文档写的是每分钟约 20 次,不要调到它之上。见 09 章决策 385。
		return hostRate{perSec: 20.0 / 60, burst: 10, reserve: 3}
	case "ws.audioscrobbler.com":
		return hostRate{perSec: 1, burst: 5, reserve: 2}
	case "lrclib.net":
		// lrclib 拿 503 限流,调用越密比例越高(每分钟 5 次以下 2.7%、31 次以上 6.5%),快速切歌时
		// 一分钟能打到两百次。攒 6 个够首轮加一轮别名不排队。见 09 章决策 108。
		return hostRate{perSec: 1, burst: 6, reserve: 3}
	case "api.megalobiz.com":
		// 不带 key 时每个 IP 每分钟 30 次:攒满 6 个再按每秒 0.4 个补,任意一分钟里最多 6 + 24 = 30 个(megalobiz.go 头注)。
		return hostRate{perSec: 0.4, burst: 6, reserve: 2}
	}
	return hostRateDefault
}

// lyricSourceInflightCaps:单独定了在途上限的源(ProviderDescriptor.MaxInflight),没列的是 lyricSourceInflightDefault。
var lyricSourceInflightCaps = map[string]int{"qq": 4, "lrclib": 3}

// lyricSourceHourlyBudget:各源一小时的请求额度(ProviderDescriptor.HourlyBudget),0 = 不限。
func lyricSourceHourlyBudget(source string) int {
	if source == lyricSourceMegalobiz {
		return megalobizHourlyBudget
	}
	return 0
}

// lyricSourceDayQuotaReserve:各源每日额度剩多少次时只给前台用(ProviderDescriptor.DayQuotaReserve),0 = 不报每日额度。
func lyricSourceDayQuotaReserve(source string) int {
	if source == lyricSourceMegalobiz {
		return megalobizDayQuotaReserve
	}
	return 0
}

// megalobizExpectedHourlyBudget / megalobizExpectedDayQuotaReserve:上面两张表引用的两个数值本身。
const (
	megalobizExpectedHourlyBudget    = 40
	megalobizExpectedDayQuotaReserve = 100
)

// lyricSourceProxyFallbackSources:直连失败后改走代理的源(ProviderDescriptor.ProxyFallback)。
var lyricSourceProxyFallbackSources = map[string]bool{
	lyricSourceLRCLIB: true, lyricSourceAMLL: true, lyricSourceLyricFind: true, lyricSourceDeezer: true,
	lyricSourceAppleMusic: true, lyricSourceVibe: true, lyricSourceGenie: true, lyricSourcePetitLyrics: true,
	lyricSourceZing: true, lyricSourceMegalobiz: true,
}

// lyricSourceForHost:请求主机归到哪个歌词源(ProviderDescriptor.Hosts),不是歌词源的主机返回空串。
func lyricSourceForHost(host string) string {
	h := strings.ToLower(strings.TrimSpace(host))
	if strings.Contains(h, ":") {
		if hostOnly, _, err := net.SplitHostPort(h); err == nil {
			h = hostOnly
		}
	}
	switch {
	case h == "music.163.com" || strings.HasSuffix(h, ".163.com"):
		return "netease"
	case h == "qq.com" || strings.HasSuffix(h, ".qq.com"):
		return "qq"
	case h == "kugou.com" || strings.HasSuffix(h, ".kugou.com"):
		return "kugou"
	case h == "lrclib.net" || strings.HasSuffix(h, ".lrclib.net"):
		return "lrclib"
	case h == "raw.githubusercontent.com" || h == "cdn.jsdelivr.net" || h == "fastly.jsdelivr.net" || h == "api.amll.dev":
		// jsDelivr 两个是 amll-ttml-db 的镜像(sourcefallback.go 的 amllBases),api.amll.dev 是 AMLL 官方接口(amllttml.go 的
		// amllAPIBase),全仓只有 amll 在用。
		return "amll"
	case h == "music.youtube.com" || h == "youtubei.googleapis.com" || h == "www.youtube.com":
		// 后两个是同一套 InnerTube 的备用主机(sourcefallback.go 的 ytmusicAPIBases)。
		return "lyricfind"
	case h == "kuwo.cn" || strings.HasSuffix(h, ".kuwo.cn"):
		return "kuwo"
	case h == "migu.cn" || strings.HasSuffix(h, ".migu.cn"):
		return "migu" // 搜索 pd.musicapp.migu.cn、歌词文件 d.musicapp.migu.cn 都归这一源
	case h == "deezer.com" || strings.HasSuffix(h, ".deezer.com"):
		return "deezer" // 搜索 api.deezer.com、取词 www.deezer.com 都归这一源
	case h == "amp-api.music.apple.com" || h == "amp-api-edge.music.apple.com" || h == "api.music.apple.com":
		// Apple Music 的 catalog API —— applemusic 这个歌词源真正发请求的地方。
		//
		// 只认这三个主机(主用加搜索、取词各一个备用,见 sourcefallback.go),别扩成 `*.apple.com`,那会把另外两个用途完全不同的主机
		// 卷进来、让它们的故障去停掉一个能出歌词的源:
		//   - itunes.apple.com:公开的目录检索(专辑提示/封面/标题反查/目录 id),跟歌词
		//     正文无关,而且被限流得最狠(实测 49.8% 失败)。它有自己的端点级退避,
		//     见 apple.go 的 itunesSearchCoolingDown。
		//   - music.apple.com:抓 developer token 的 web origin。它失败意味着"没凭据"
		//     (applemusic_not_connected),不是"源坏了" —— 那种情况 resolveApplemusicLyric
		//     在发请求之前就安静返回空了,本来也轮不到熔断。
		//
		// 不在这张表里的源,observe 拿到空源名直接返回,失败一次都不记:新加歌词源别漏登记它的主机。
		return "applemusic"
	case h == sodaSeoTrackHost || h == sodaSearchHost:
		// 汽水的两个主机,取词(seo_track)和搜索两个端点都在上面,互为备用(sourcefallback.go)。
		// beta-luna 只认这一个主机,别扩成 `*.douyin.com`:那个域名下还有抖音自己的一大
		// 堆服务,跟歌词无关的故障会连带停掉这个源。分享页的 music.douyin.com 同理不进来(见 soda.go
		// sodaSharePageURL)。
		return "soda"
	case h == "apis.naver.com":
		// VIBE 的搜索和取词都在这个主机的 /vibeWeb/ 下(vibe.go)。全仓只有这一源请求它;封面图在 musicmeta-phinf.pstatic.net,
		// 跟歌词无关,不进来。
		return "vibe"
	case h == "app.genie.co.kr" || h == "dn.genie.co.kr":
		// Genie 的搜索在 app.genie.co.kr、取词在 dn.genie.co.kr(genie.go)。全仓只有这一源请求它们;封面图在
		// image.genie.co.kr,跟歌词无关,不进来。
		return "genie"
	case h == "p1.petitlyrics.com" || h == "p0.petitlyrics.com" || h == "on.petitlyrics.com":
		// PetitLyrics 轮换着用的三个主机(petitlyrics.go 的 petitClients),全仓只有这一源请求它们。
		return "petitlyrics"
	case h == "zingmp3.vn" || h == "static-zmp3.zmdcdn.me":
		// Zing MP3 的接口在 zingmp3.vn、LRC 文件在 static-zmp3.zmdcdn.me(zing.go),全仓只有这一源请求它们;封面图在
		// photo-zmp3.zmdcdn.me / photo-resize-zmp3.zmdcdn.me,跟歌词无关,不进来。
		return "zing"
	case h == "api.megalobiz.com":
		// Megalobiz 的公开接口(megalobiz.go),搜索和取词都在这一个主机上,全仓只有这一源请求它。歌词页 megalobiz.com 只给 App
		// 做来源链接、引擎不请求,不进来。
		return "megalobiz"
	}
	return ""
}

// parenBGSources:正文里的括号段拆成背景人声轨的源(ProviderDescriptor.ParenBackground)。amll / applemusic 自带结构化的
// 背景人声,本机文件、各客户端缓存里的用户歌词不动(洛雪存下的是平台原版,拆)。
var parenBGSources = map[string]bool{
	"netease": true, "qq": true, "kugou": true, "lrclib": true, "lyricfind": true, "kuwo": true,
	"migu": true, "deezer": true, "soda": true, "vibe": true, "genie": true, "petitlyrics": true, "zing": true, "megalobiz": true,
	lxMusicLocalLyricsSource: true,
}

// kanaDonorSources:会在正文里带 `[kana:]` 假名标注的源(ProviderDescriptor.CarriesKana)。
var kanaDonorSources = map[string]bool{"kugou": true, "qq": true, "lrclib": true}

// lyricSourceConsensusFamily:source 的正文出自哪一家(ProviderDescriptor.ConsensusFamily),同一家的互不印证。
func lyricSourceConsensusFamily(source string) string {
	switch source {
	case lyricSourceDeezer, lyricSourceLyricFind:
		return lyricSourceLyricFind
	}
	return source
}

// expectedSongwritersFromScored:词曲作者名单取谁的(ProviderDescriptor.SongwritersRank / SongwritersSkipCJK)。
func expectedSongwritersFromScored(scored []scoredLyricCandidateResult) []string {
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

// expectedPlainTextFallbackFromScored:退到纯文本时取谁的(ProviderDescriptor.PlainText)。
func expectedPlainTextFallbackFromScored(scored []scoredLyricCandidateResult) (lyrics, source string) {
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

// lyricSourcePlayerNoVocalsSources:交「播放器自己说这一条没有人声」信号的来源(特权位 privPlayerNoVocals),照 43fa2dff7 的
// playerInstrumentalSource 里那份名单。
var lyricSourcePlayerNoVocalsSources = []string{lyricSourceNetease, lyricSourceQQ, lyricSourceSoda, lyricSourceAppleMusic, spotifyLocalLyricsSource}

// expectedPlayerLocalNoVocalsHint:开搜之前播放器的本机数据就说这一条没有人声(实现 PreSearchNoVocalsHinter 的源)。
func expectedPlayerLocalNoVocalsHint(artist, title, album string, durationSecs float64) bool {
	switch playingPlayer() {
	case playerNetease:
		t, ok := neteaseLocalEntry(context.Background(), artist, title, album, durationSecs)
		return ok && t.Mark&neteaseMarkNoVocals != 0
	case playerSoda:
		return sodaLocalInstrumental(artist, title, album, durationSecs)
	}
	return false
}

// lyricSourcePreSearchNoVocalsHinters:实现 PreSearchNoVocalsHinter 的源。
var lyricSourcePreSearchNoVocalsHinters = []string{lyricSourceNetease, lyricSourceSoda}

// 顺序优先模式里本机类来源排在哪(ProviderDescriptor.PriorityPlacement),照迁移前按源名写的那一版:priorityPlayerCacheSources
// 是「播放器自带歌词」那一个名次里的播放器本地歌词,priorityPlayerLocalTier 是那一个名次包括哪些来源(文件自带的歌词不优先时
// 也在里面),expectedPriorityTiers 是实际的取用先后,expectedPriorityPick 是按它挑(用户导入的歌词排在各名次之前)。
var priorityPlayerCacheSources = []string{kkboxLocalLyricsSource, spotifyLocalLyricsSource, amazonLocalLyricsSource,
	lxMusicLocalLyricsSource}

func priorityPlayerLocalTier(preferLocalFile bool) []string {
	if preferLocalFile {
		return priorityPlayerCacheSources
	}
	return append(slices.Clone(priorityPlayerCacheSources), localFileLyricsSource)
}

func expectedPriorityTiers() [][]string {
	var tiers [][]string
	prefer := features().PreferLocalFileLyrics
	if prefer {
		tiers = append(tiers, []string{localFileLyricsSource})
	}
	playerLocal := priorityPlayerLocalTier(prefer)
	placed := false
	for _, entry := range features().LyricsSourceOrder {
		switch {
		case entry == lyricsPriorityPlayerLocal:
			tiers, placed = append(tiers, playerLocal), true
		case lyricSourceEnabled(entry):
			tiers = append(tiers, []string{entry})
		}
	}
	if !placed {
		tiers = append(tiers, playerLocal)
	}
	return tiers
}

func expectedPriorityPick(scored []scoredLyricCandidateResult, ok func(scoredLyricCandidateResult) bool) *scoredLyricCandidateResult {
	for i := range scored {
		if scored[i].Source == importLyricsSource && ok(scored[i]) {
			return &scored[i]
		}
	}
	for _, tier := range expectedPriorityTiers() {
		for i := range scored {
			if slices.Contains(tier, scored[i].Source) && ok(scored[i]) {
				return &scored[i]
			}
		}
	}
	return nil
}

// dropAMLLWithoutIDSource:别名轮名单里既没有网易云也没有 QQ 时剔掉 amll(ProviderDescriptor.DependsOnIDsFrom)。
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

// lyricSourceCandidateShape:排序时一个源交的结果里哪几栏进它的候选和结果。
type lyricSourceCandidateShape struct {
	// reads:读的栏,空格隔开,名字同 rankShapeFields。歌名、歌手每个源都读,不列。
	reads string
	// translation:交的译文轨标什么语言。空 = 不读译文轨;"zh" / "ko" = 固定是这种语言;"target" = 按设置里的译文语言;
	// "declared" = 源自己标的,没标按设置里的译文语言。
	translation string
	// baked:烘在正文里的中文译文。空 = 不摘;"adopt" = 摘出来接到译文轨(标中文);"strip" = 只摘不接。
	baked string
	// instrumental:凭什么搭纯音乐标记,空格隔开,名字同 rankShapeInstrumentalSignals。
	instrumental string
	// unnamed:结果没带歌名时候选的歌名、歌手、专辑。空 = 就空着;"query" = 用查询的那一组。
	unnamed string
	// borrows:自己没有封面、曲长,借同一条录音别家的(借的认法是这个源自己的,amllcover_test.go 守)。
	borrows bool
}

// lyricSourceCandidateShapes:照 43fa2dff7 的 rankLyricSourceResults 里各源那段装配和 switch 里它的 case 整理的
// (lyricrankreference_test.go 是那份函数体)。lyricrankshape_test.go 拿每一栏都交了的输入喂参照和生产,看到的跟这里
// 逐项相等。网易云、AMLL 的内容交上来时在专用子结构里(ne、amll),这里写的是摊到公共栏之后的读法。
var lyricSourceCandidateShapes = map[string]lyricSourceCandidateShape{
	lyricSourceAMLL:          {reads: "逐字 读音 专辑 来源链接 背景人声轨 作者", translation: "declared", baked: "strip", unnamed: "query", borrows: true},
	lyricSourceNetease:       {reads: "逐字 读音 自报曲长 专辑 封面 本机身份 另一栏纯文本", translation: "zh", baked: "adopt", instrumental: "明说 没正文加无人声"},
	lyricSourceQQ:            {reads: "逐字 读音 自报曲长 专辑 封面 语种 本机身份 纯文本", translation: "zh", baked: "adopt", instrumental: "明说 署名行加无人声"},
	lyricSourceKugou:         {reads: "逐字 读音 自报曲长 专辑 封面 语种 本机身份", translation: "zh", baked: "adopt", instrumental: "署名行加无人声"},
	lyricSourceLRCLIB:        {reads: "逐字 读音 自报曲长 专辑 纯文本", baked: "strip", instrumental: "明说"},
	lyricSourceLyricFind:     {reads: "自报曲长 专辑 封面 本机身份 纯文本", baked: "strip"},
	lyricSourceKuwo:          {reads: "逐字 自报曲长 专辑 封面 本机身份", baked: "adopt"},
	lyricSourceMigu:          {reads: "逐字 自报曲长 专辑 封面 纯文本", translation: "zh", instrumental: "占位句"},
	lyricSourceDeezer:        {reads: "逐字 自报曲长 专辑 封面 纯文本 ISRC 作者", translation: "target"},
	lyricSourceAppleMusic:    {reads: "逐字 读音 自报曲长 专辑 封面 本机身份 纯文本 ISRC 背景人声轨 作者", translation: "declared"},
	lyricSourceSoda:          {reads: "逐字 自报曲长 专辑 封面 本机身份", translation: "zh"},
	lyricSourceVibe:          {reads: "自报曲长 专辑 封面 纯文本", translation: "ko"},
	lyricSourceGenie:         {reads: "自报曲长 专辑 封面 纯文本"},
	lyricSourcePetitLyrics:   {reads: "逐字 自报曲长 专辑 封面 纯文本 ISRC"},
	lyricSourceZing:          {reads: "逐字 自报曲长 专辑 封面"},
	lyricSourceMegalobiz:     {reads: "自报曲长 来源链接"},
	kkboxLocalLyricsSource:   {reads: "自报曲长 专辑 封面 本机身份"},
	amazonLocalLyricsSource:  {reads: "自报曲长 专辑 封面 本机身份"},
	lxMusicLocalLyricsSource: {reads: "逐字 读音 自报曲长 专辑 本机身份", translation: "zh"},
	localFileLyricsSource:    {reads: "逐字 自报曲长 本机身份 纯文本", translation: "zh", baked: "adopt"},
	importLyricsSource:       {reads: "逐字 读音 专辑 背景人声轨", translation: "declared"},
	spotifyLocalLyricsSource: {reads: "自报曲长 专辑 封面"},
}

// lyricSourceTranslationAccepters:打分那道「译文可用」没过时,另有一条判据把译文写进结果的源和各自的判据
// (CandidateAssembly.AcceptTranslation)。照 43fa2dff7 的 rankLyricSourceResults 里 switch 的 kuwo 那一支整理。
var lyricSourceTranslationAccepters = map[string]string{lyricSourceKuwo: "kuwoBakedTranslationCovers"}

// lyricSourceUnpackers:结果的内容在专用子结构里、排序时要摊到公共栏上的源和各自的摊法(CandidateAssembly.Unpack)。
var lyricSourceUnpackers = map[string]string{lyricSourceNetease: "unpackNeteaseResult", lyricSourceAMLL: "unpackAMLLResult"}

// lyricSourcePeerBorrowers:借同一条录音别家的封面、曲长的源和各自的借法(CandidateAssembly.BorrowFromPeers)。
var lyricSourcePeerBorrowers = map[string]string{lyricSourceAMLL: "amllBorrowFromPeers"}

// lyricSourceHandTypedTimelines:时间轴是上传者手打的源(ProviderDescriptor.HandTypedTimeline)。43fa2dff7 的
// applyMegalobizTimelinePenalty 只认 megalobiz 这一个源名。
var lyricSourceHandTypedTimelines = map[string]bool{lyricSourceMegalobiz: true}
