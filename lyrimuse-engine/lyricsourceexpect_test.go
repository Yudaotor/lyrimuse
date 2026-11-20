package main

// 登记表(lyricprovider.go)的期望值。生产代码里名单、顺序、轮次、哪几路是播放器本机、近况统计的同类组、专用探测曲、
// 来源链接、按 ISRC 补取、出站的速率与额度(主机速率、在途上限、小时额度、每日额度留量、代理回退)这几类只读登记表里的
// 描述符,两种失败原因问源的可选接口;这里是同一份事实冻结在测试里的写法,lyricproviderregistry_test.go
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
