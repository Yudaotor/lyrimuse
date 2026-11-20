package main

// 登记表(lyricprovider.go)的期望值。生产代码里名单、顺序、轮次、哪几路是播放器本机、近况统计的同类组、专用探测曲、
// 来源链接、按 ISRC 补取这几类只读登记表里的描述符;这里是同一份事实冻结在测试里的写法,lyricproviderregistry_test.go
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
