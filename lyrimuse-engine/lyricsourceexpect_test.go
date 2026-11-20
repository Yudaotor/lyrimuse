package main

// 登记表(lyricprovider.go)的期望值。生产代码里名单、顺序、轮次、哪几路是播放器本机这几类只读登记表里的描述符;这里是
// 同一份事实冻结在测试里的写法,lyricproviderregistry_test.go 逐项比「登记表推出来的 == 这里」。加减来源、改描述符里的
// 名次、Kind、Rounds,要同步改这里。
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
