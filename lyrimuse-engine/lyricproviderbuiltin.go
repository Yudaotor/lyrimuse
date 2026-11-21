package main

// 近况统计的同类组(ProviderDescriptor.PeerGroup)。
const (
	peerGroupChinese = "chinese"
	peerGroupGlobal  = "global"
)

// newBuiltinLyricProviderRegistry 登记十六个联网歌词源和六路本机来源,各一份描述符、一份实现。联网源的登记顺序不带语义,
// 先后看各自的 Order / TieRank / DefaultPriorityRank;本机类源调度按登记的先后同步问(runLocalLyricProviders):KKBOX、
// Spotify、Amazon Music、文件旁的歌词、洛雪、导入库。
func newBuiltinLyricProviderRegistry() *lyricProviderRegistry {
	r := &lyricProviderRegistry{byName: map[string]*ProviderDescriptor{}, byProvider: map[string]LyricProvider{}}

	r.implement(neteaseProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceNetease, Order: 1, TieRank: 1, DefaultPriorityRank: 2,
		// 只认 163.com 的各级子域(music.163.com、interface3.music.163.com …),不认 163.com 自己。
		Hosts: []HostRule{{"163.com", hostSubdomainsOnly}},
		Baked: bakedAdopt, ParenBackground: true, InstrumentalRank: 3, PlainText: plainTextLast,
		PeerGroup: peerGroupChinese,
	}, privLocalClientIdentity|privTrackIDPublish|privPeripheral|privPlayerNoVocals)})

	r.implement(qqProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceQQ, Order: 2, TieRank: 2, DefaultPriorityRank: 3,
		Hosts: []HostRule{{"qq.com", hostWithSubdomains}}, MaxInflight: 4,
		Baked: bakedAdopt, ParenBackground: true, CarriesKana: true, InstrumentalRank: 2, PlainText: plainTextLast,
		Assembly: &CandidateAssembly{
			Reads: fieldWordTiming | fieldRomanization | fieldSourceDuration | fieldAlbum | fieldCover | fieldLanguage |
				fieldLocalIdentity | fieldPlainText,
			Translation: translationFixed, TranslationLang: "zh",
			Instrumental: instrumentalDeclared | instrumentalCreditsNoVocals,
		},
		PeerGroup: peerGroupChinese,
	}, privLocalClientIdentity|privTrackIDPublish|privPlayerNoVocals)})

	r.implement(kugouProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceKugou, Order: 3, TieRank: 3, DefaultPriorityRank: 1,
		Hosts: []HostRule{{"kugou.com", hostWithSubdomains}},
		Baked: bakedAdopt, ParenBackground: true, CarriesKana: true, InstrumentalRank: 5,
		Assembly: &CandidateAssembly{
			Reads: fieldWordTiming | fieldRomanization | fieldSourceDuration | fieldAlbum | fieldCover | fieldLanguage |
				fieldLocalIdentity,
			Translation: translationFixed, TranslationLang: "zh", Instrumental: instrumentalCreditsNoVocals,
		},
		PeerGroup: peerGroupChinese,
	}, privLocalClientIdentity|privOfflineLeg)})

	r.implement(lrclibProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceLRCLIB, Order: 4, TieRank: 4, DefaultPriorityRank: 4,
		Hosts: []HostRule{{"lrclib.net", hostWithSubdomains}},
		// lrclib 拿 503 限流,调用越密比例越高(每分钟 5 次以下 2.7%、31 次以上 6.5%),快速切歌时
		// 一分钟能打到两百次。攒 6 个够首轮加一轮别名不排队。见 09 章决策 108。
		HostRates:   map[string]hostRate{"lrclib.net": {perSec: 1, burst: 6, reserve: 3}},
		MaxInflight: 3, ProxyFallback: true,
		Baked: bakedStripOnly, ParenBackground: true, CarriesKana: true, InstrumentalRank: 1,
		Assembly: &CandidateAssembly{
			Reads:        fieldWordTiming | fieldRomanization | fieldSourceDuration | fieldAlbum | fieldPlainText,
			Instrumental: instrumentalDeclared,
		},
		PeerGroup: peerGroupGlobal,
	}, 0)})

	r.implement(amllProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceAMLL, Order: 5, TieRank: 22, DefaultPriorityRank: 5,
		// raw.githubusercontent.com 和 jsDelivr 两个是 amll-ttml-db 的镜像(sourcefallback.go 的 amllBases),api.amll.dev 是 AMLL
		// 官方接口(amllttml.go 的 amllAPIBase),全仓只有 amll 请求它们。
		Hosts: []HostRule{
			{"raw.githubusercontent.com", hostExact}, {"cdn.jsdelivr.net", hostExact}, {"fastly.jsdelivr.net", hostExact},
			{"api.amll.dev", hostExact},
		},
		ProxyFallback: true,
		Baked:         bakedStripOnly, SongwritersRank: 2, ISRCLookup: isrcLookupIndexed, PageURL: amllPageURL,
		DependsOnIDsFrom: []string{lyricSourceNetease, lyricSourceQQ},
	}, privPlaybackTrackIDs|privTrackIDConsume|privBorrowFromPeers|privRefetchByID)})

	r.implement(lyricFindProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceLyricFind, Order: 6, TieRank: 5, DefaultPriorityRank: 6,
		// 后两个是同一套 InnerTube 的备用主机(sourcefallback.go 的 ytmusicAPIBases)。
		Hosts: []HostRule{
			{"music.youtube.com", hostExact}, {"youtubei.googleapis.com", hostExact}, {"www.youtube.com", hostExact},
		},
		ProxyFallback: true,
		Baked:         bakedStripOnly, ParenBackground: true, ConsensusFamily: lyricSourceLyricFind,
		Assembly:  &CandidateAssembly{Reads: fieldSourceDuration | fieldAlbum | fieldCover | fieldLocalIdentity | fieldPlainText},
		PeerGroup: peerGroupGlobal,
	}, privLocalClientIdentity|privPlaybackTrackIDs)})

	r.implement(kuwoProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceKuwo, Order: 7, TieRank: 6, DefaultPriorityRank: 7,
		Hosts: []HostRule{{"kuwo.cn", hostWithSubdomains}},
		Baked: bakedCustom, BakedSplit: adoptKuwoBakedTranslation, ParenBackground: true,
		// 译文只有从正文里摘出来的那份(BakedSplit),固定中文;中文歌里那段外文被它译全了的,打分那道「可用」不认也照收。
		Assembly: &CandidateAssembly{
			Reads:       fieldWordTiming | fieldSourceDuration | fieldAlbum | fieldCover | fieldLocalIdentity,
			Translation: translationFixed, TranslationLang: "zh", AcceptTranslation: kuwoBakedTranslationCovers,
		},
		PeerGroup: peerGroupChinese,
	}, privLocalClientIdentity|privOfflineLeg)})

	r.implement(miguProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceMigu, Order: 8, TieRank: 7, DefaultPriorityRank: 8,
		// 搜索 pd.musicapp.migu.cn、歌词文件 d.musicapp.migu.cn 都归这一源。
		Hosts:           []HostRule{{"migu.cn", hostWithSubdomains}},
		ParenBackground: true, InstrumentalRank: 4,
		Assembly: &CandidateAssembly{
			Reads:       fieldWordTiming | fieldSourceDuration | fieldAlbum | fieldCover | fieldPlainText,
			Translation: translationFixed, TranslationLang: "zh", Instrumental: instrumentalPlaceholder,
		},
		PeerGroup: peerGroupChinese,
	}, 0)})

	r.implement(deezerProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceDeezer, Order: 9, TieRank: 8, DefaultPriorityRank: 9,
		// 搜索 api.deezer.com、取词 www.deezer.com 都归这一源。
		Hosts:           []HostRule{{"deezer.com", hostWithSubdomains}},
		ProxyFallback:   true,
		ParenBackground: true, SongwritersRank: 3, SongwritersSkipCJK: true, ConsensusFamily: lyricSourceLyricFind,
		ISRCLookup: isrcLookupDirect, ISRCAuthority: true,
		Assembly: &CandidateAssembly{
			Reads:       fieldWordTiming | fieldSourceDuration | fieldAlbum | fieldCover | fieldPlainText | fieldISRC,
			Translation: translationTarget,
		},
		PeerGroup: peerGroupGlobal,
	}, 0)})

	r.implement(appleMusicProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceAppleMusic, Order: 10, TieRank: 9, DefaultPriorityRank: 10,
		// catalog API 的三个主机(主用加搜索、取词各一个备用,见 sourcefallback.go)。只认这三个,别扩成 `*.apple.com`:
		// itunes.apple.com 是公开的目录检索(专辑提示、封面、标题反查、目录 id),有自己的端点级退避(apple.go 的
		// itunesSearchCoolingDown);music.apple.com 是抓 developer token 的 web origin,它失败是没凭据,不是源坏了。
		Hosts: []HostRule{
			{"amp-api.music.apple.com", hostExact}, {"amp-api-edge.music.apple.com", hostExact},
			{"api.music.apple.com", hostExact},
		},
		ProxyFallback:   true,
		SongwritersRank: 1, ISRCAuthority: true,
		// 官方译文按译文块的 xml:lang 标,没标的是按请求的译文语言取的;背景人声轨是 TTML 自带的。
		Assembly: &CandidateAssembly{
			Reads: fieldWordTiming | fieldRomanization | fieldSourceDuration | fieldAlbum | fieldCover | fieldLocalIdentity |
				fieldPlainText | fieldISRC | fieldBackground,
			Translation: translationDeclared,
		},
		PeerGroup: peerGroupGlobal,
	}, privLocalClientIdentity|privPlaybackTrackIDs|privPlayerNoVocals|privRefetchByID)})

	r.implement(sodaProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceSoda, Order: 11, TieRank: 10, DefaultPriorityRank: 11,
		// 取词(seo_track)和搜索两个端点都在这两个主机上,互为备用(sourcefallback.go)。别扩成 `*.douyin.com`:那个域名下还有
		// 抖音自己的一大堆服务;分享页的 music.douyin.com 同样不进来(soda.go 的 sodaSharePageURL)。
		Hosts:           []HostRule{{sodaSeoTrackHost, hostExact}, {sodaSearchHost, hostExact}},
		ParenBackground: true,
		Assembly: &CandidateAssembly{
			Reads:       fieldWordTiming | fieldSourceDuration | fieldAlbum | fieldCover | fieldLocalIdentity,
			Translation: translationFixed, TranslationLang: "zh",
		},
		PeerGroup: peerGroupChinese,
		Probe:     &ProbeTrack{Artist: "陈奕迅", Title: "十年"},
	}, privLocalClientIdentity|privPlaybackTrackIDs|privPlayerNoVocals)})

	r.implement(vibeProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceVibe, Order: 12, TieRank: 11, DefaultPriorityRank: 12,
		// 搜索和取词都在这个主机的 /vibeWeb/ 下(vibe.go);封面图在 musicmeta-phinf.pstatic.net,不进来。
		Hosts:         []HostRule{{"apis.naver.com", hostExact}},
		ProxyFallback: true, ParenBackground: true,
		Assembly: &CandidateAssembly{
			Reads:       fieldSourceDuration | fieldAlbum | fieldCover | fieldPlainText,
			Translation: translationFixed, TranslationLang: vibeTranslationLang,
		},
	}, 0)})

	r.implement(genieProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceGenie, Order: 13, TieRank: 12, DefaultPriorityRank: 13,
		// 搜索在 app.genie.co.kr、取词在 dn.genie.co.kr(genie.go);封面图在 image.genie.co.kr,不进来。
		Hosts:         []HostRule{{"app.genie.co.kr", hostExact}, {"dn.genie.co.kr", hostExact}},
		ProxyFallback: true, ParenBackground: true,
		Assembly: &CandidateAssembly{Reads: fieldSourceDuration | fieldAlbum | fieldCover | fieldPlainText},
	}, 0)})

	r.implement(petitProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourcePetitLyrics, Order: 14, TieRank: 13, DefaultPriorityRank: 14,
		// 轮换着用的三个主机(petitlyrics.go 的 petitClients)。
		Hosts: []HostRule{
			{"p1.petitlyrics.com", hostExact}, {"p0.petitlyrics.com", hostExact}, {"on.petitlyrics.com", hostExact},
		},
		ProxyFallback: true, ParenBackground: true,
		Assembly: &CandidateAssembly{Reads: fieldWordTiming | fieldSourceDuration | fieldAlbum | fieldCover | fieldPlainText | fieldISRC},
	}, 0)})

	r.implement(zingProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceZing, Order: 15, TieRank: 14, DefaultPriorityRank: 15,
		// 接口在 zingmp3.vn、LRC 文件在 static-zmp3.zmdcdn.me(zing.go);封面图在 photo-zmp3.zmdcdn.me /
		// photo-resize-zmp3.zmdcdn.me,不进来。
		Hosts:         []HostRule{{"zingmp3.vn", hostExact}, {"static-zmp3.zmdcdn.me", hostExact}},
		ProxyFallback: true, ParenBackground: true,
		Assembly: &CandidateAssembly{Reads: fieldWordTiming | fieldSourceDuration | fieldAlbum | fieldCover},
		Probe:    &ProbeTrack{Artist: "Sơn Tùng M-TP", Title: "Lạc Trôi"},
	}, privBreakerControl)})

	r.implement(megalobizProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceMegalobiz, Order: 16, TieRank: 15, DefaultPriorityRank: 16,
		Rounds: roundsOnDemand,
		// 搜索和取词都在这一个主机上;歌词页 megalobiz.com 只给 App 做来源链接、引擎不请求,不进来。
		Hosts: []HostRule{{"api.megalobiz.com", hostExact}},
		// 不带 key 时每个 IP 每分钟 30 次:攒满 6 个再按每秒 0.4 个补,任意一分钟里最多 6 + 24 = 30 个(megalobiz.go 头注)。
		HostRates:    map[string]hostRate{"api.megalobiz.com": {perSec: 0.4, burst: 6, reserve: 2}},
		HourlyBudget: megalobizHourlyBudget, DayQuotaReserve: megalobizDayQuotaReserve, ProxyFallback: true,
		ParenBackground: true, PageURL: megalobizPageURL,
		Assembly: &CandidateAssembly{Reads: fieldSourceDuration | fieldSourceURL},
	}, 0)})

	r.implement(kkboxLocalProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: kkboxLocalLyricsSource, Kind: providerKindPlayerLocal, TieRank: 16, Rounds: roundsPrimaryOnly,
	}, privLocalClientIdentity)})
	r.implement(spotifyLocalProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: spotifyLocalLyricsSource, Kind: providerKindPlayerLocal, TieRank: 21, Rounds: roundsPrimaryOnly,
	}, privLocalClientIdentity|privPlayerNoVocals)})
	r.implement(amazonLocalProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: amazonLocalLyricsSource, Kind: providerKindPlayerLocal, TieRank: 17, Rounds: roundsPrimaryOnly,
	}, privLocalClientIdentity)})
	r.implement(localFileProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: localFileLyricsSource, Kind: providerKindPlayerLocal, TieRank: 19, Rounds: roundsPrimaryOnly,
		Baked: bakedAdopt, PlainText: plainTextFirst,
	}, privLocalClientIdentity)})
	r.implement(lxMusicLocalProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lxMusicLocalLyricsSource, Kind: providerKindPlayerLocal, TieRank: 18, Rounds: roundsPrimaryOnly,
		ParenBackground: true,
	}, privLocalClientIdentity)})
	r.implement(importLibraryProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: importLyricsSource, Kind: providerKindUserLibrary, TieRank: 20, Rounds: roundsPrimaryOnly,
	}, privLocalClientIdentity)})

	r.index()
	return r
}
