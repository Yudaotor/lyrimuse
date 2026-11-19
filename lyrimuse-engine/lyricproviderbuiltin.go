package main

// 近况统计的同类组(ProviderDescriptor.PeerGroup)。
const (
	peerGroupChinese = "chinese"
	peerGroupGlobal  = "global"
)

// newBuiltinLyricProviderRegistry 登记十六个联网歌词源和六路本机来源。登记顺序不带语义,先后看各自的 Order / TieRank /
// DefaultPriorityRank。
func newBuiltinLyricProviderRegistry() *lyricProviderRegistry {
	r := &lyricProviderRegistry{byName: map[string]*ProviderDescriptor{}}

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceNetease, Order: 1, TieRank: 1, DefaultPriorityRank: 2,
		Hosts: []HostRule{{"163.com", hostSubdomainsOnly}},
		Baked: bakedAdopt, ParenBackground: true, InstrumentalRank: 3, PlainText: plainTextLast,
		PeerGroup: peerGroupChinese,
	}, privLocalClientIdentity|privTrackIDPublish|privPeripheral|privPlayerNoVocals)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceQQ, Order: 2, TieRank: 2, DefaultPriorityRank: 3,
		Hosts: []HostRule{{"qq.com", hostWithSubdomains}}, MaxInflight: 4,
		Baked: bakedAdopt, ParenBackground: true, CarriesKana: true, InstrumentalRank: 2, PlainText: plainTextLast,
		PeerGroup: peerGroupChinese,
	}, privLocalClientIdentity|privTrackIDPublish|privPlayerNoVocals)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceKugou, Order: 3, TieRank: 3, DefaultPriorityRank: 1,
		Hosts: []HostRule{{"kugou.com", hostWithSubdomains}},
		Baked: bakedAdopt, ParenBackground: true, CarriesKana: true, InstrumentalRank: 5,
		PeerGroup: peerGroupChinese,
	}, privLocalClientIdentity|privOfflineLeg)

	r.implement(lrclibProvider{desc: r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceLRCLIB, Order: 4, TieRank: 4, DefaultPriorityRank: 4,
		Hosts:       []HostRule{{"lrclib.net", hostWithSubdomains}},
		HostRates:   map[string]hostRate{"lrclib.net": {perSec: 1, burst: 6, reserve: 3}},
		MaxInflight: 3, ProxyFallback: true,
		Baked: bakedStripOnly, ParenBackground: true, CarriesKana: true, InstrumentalRank: 1,
		PeerGroup: peerGroupGlobal,
	}, 0)})

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceAMLL, Order: 5, TieRank: 22, DefaultPriorityRank: 5,
		Hosts: []HostRule{
			{"raw.githubusercontent.com", hostExact}, {"cdn.jsdelivr.net", hostExact}, {"fastly.jsdelivr.net", hostExact},
			{"api.amll.dev", hostExact},
		},
		ProxyFallback: true,
		Baked:         bakedStripOnly, SongwritersRank: 2, ISRCLookup: isrcLookupIndexed, PageURL: amllPageURL,
		DependsOnIDsFrom: []string{lyricSourceNetease, lyricSourceQQ},
	}, privPlaybackTrackIDs|privTrackIDConsume|privBorrowFromPeers|privRefetchByID)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceLyricFind, Order: 6, TieRank: 5, DefaultPriorityRank: 6,
		Hosts: []HostRule{
			{"music.youtube.com", hostExact}, {"youtubei.googleapis.com", hostExact}, {"www.youtube.com", hostExact},
		},
		ProxyFallback: true,
		Baked:         bakedStripOnly, ParenBackground: true, ConsensusFamily: lyricSourceLyricFind,
		PeerGroup:               peerGroupGlobal,
		QueryIndependentFailure: ytmusicLastFailureReasonNow,
	}, privLocalClientIdentity|privPlaybackTrackIDs)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceKuwo, Order: 7, TieRank: 6, DefaultPriorityRank: 7,
		Hosts: []HostRule{{"kuwo.cn", hostWithSubdomains}},
		Baked: bakedCustom, BakedSplit: adoptKuwoBakedTranslation, ParenBackground: true,
		PeerGroup: peerGroupChinese,
	}, privLocalClientIdentity|privOfflineLeg)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceMigu, Order: 8, TieRank: 7, DefaultPriorityRank: 8,
		Hosts:           []HostRule{{"migu.cn", hostWithSubdomains}},
		ParenBackground: true, InstrumentalRank: 4,
		PeerGroup: peerGroupChinese,
	}, 0)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceDeezer, Order: 9, TieRank: 8, DefaultPriorityRank: 9,
		Hosts:           []HostRule{{"deezer.com", hostWithSubdomains}},
		ProxyFallback:   true,
		ParenBackground: true, SongwritersRank: 3, SongwritersSkipCJK: true, ConsensusFamily: lyricSourceLyricFind,
		ISRCLookup: isrcLookupDirect, ISRCAuthority: true,
		PeerGroup:               peerGroupGlobal,
		QueryIndependentFailure: deezerLastFailureReasonNow,
	}, 0)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceAppleMusic, Order: 10, TieRank: 9, DefaultPriorityRank: 10,
		Hosts: []HostRule{
			{"amp-api.music.apple.com", hostExact}, {"amp-api-edge.music.apple.com", hostExact},
			{"api.music.apple.com", hostExact},
		},
		ProxyFallback:   true,
		SongwritersRank: 1, ISRCAuthority: true,
		PeerGroup:               peerGroupGlobal,
		QueryIndependentFailure: applemusicLastFailureReasonNow,
	}, privLocalClientIdentity|privPlaybackTrackIDs|privPlayerNoVocals|privRefetchByID)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceSoda, Order: 11, TieRank: 10, DefaultPriorityRank: 11,
		Hosts:           []HostRule{{sodaSeoTrackHost, hostExact}, {sodaSearchHost, hostExact}},
		ParenBackground: true,
		PeerGroup:       peerGroupChinese,
		Probe:           &ProbeTrack{Artist: "陈奕迅", Title: "十年"},
	}, privLocalClientIdentity|privPlaybackTrackIDs|privPlayerNoVocals)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceVibe, Order: 12, TieRank: 11, DefaultPriorityRank: 12,
		Hosts:         []HostRule{{"apis.naver.com", hostExact}},
		ProxyFallback: true, ParenBackground: true,
	}, 0)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceGenie, Order: 13, TieRank: 12, DefaultPriorityRank: 13,
		Hosts:         []HostRule{{"app.genie.co.kr", hostExact}, {"dn.genie.co.kr", hostExact}},
		ProxyFallback: true, ParenBackground: true,
	}, 0)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourcePetitLyrics, Order: 14, TieRank: 13, DefaultPriorityRank: 14,
		Hosts: []HostRule{
			{"p1.petitlyrics.com", hostExact}, {"p0.petitlyrics.com", hostExact}, {"on.petitlyrics.com", hostExact},
		},
		ProxyFallback: true, ParenBackground: true,
	}, 0)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceZing, Order: 15, TieRank: 14, DefaultPriorityRank: 15,
		Hosts:         []HostRule{{"zingmp3.vn", hostExact}, {"static-zmp3.zmdcdn.me", hostExact}},
		ProxyFallback: true, ParenBackground: true,
		Probe:                   &ProbeTrack{Artist: "Sơn Tùng M-TP", Title: "Lạc Trôi"},
		QueryIndependentFailure: zingLastFailureReasonNow,
	}, privBreakerControl)

	r.registerBuiltin(&ProviderDescriptor{
		Name: lyricSourceMegalobiz, Order: 16, TieRank: 15, DefaultPriorityRank: 16,
		Rounds:       roundsOnDemand,
		Hosts:        []HostRule{{"api.megalobiz.com", hostExact}},
		HostRates:    map[string]hostRate{"api.megalobiz.com": {perSec: 0.4, burst: 6, reserve: 2}},
		HourlyBudget: megalobizHourlyBudget, DayQuotaReserve: megalobizDayQuotaReserve, ProxyFallback: true,
		ParenBackground: true, PageURL: megalobizPageURL,
	}, 0)

	r.registerBuiltin(&ProviderDescriptor{Name: kkboxLocalLyricsSource, Kind: providerKindPlayerLocal, TieRank: 16},
		privLocalClientIdentity)
	r.registerBuiltin(&ProviderDescriptor{Name: amazonLocalLyricsSource, Kind: providerKindPlayerLocal, TieRank: 17},
		privLocalClientIdentity)
	r.registerBuiltin(&ProviderDescriptor{
		Name: lxMusicLocalLyricsSource, Kind: providerKindPlayerLocal, TieRank: 18, ParenBackground: true,
	}, privLocalClientIdentity)
	r.registerBuiltin(&ProviderDescriptor{
		Name: localFileLyricsSource, Kind: providerKindPlayerLocal, TieRank: 19,
		Baked: bakedAdopt, PlainText: plainTextFirst,
	}, privLocalClientIdentity)
	r.registerBuiltin(&ProviderDescriptor{Name: importLyricsSource, Kind: providerKindUserLibrary, TieRank: 20},
		privLocalClientIdentity)
	r.registerBuiltin(&ProviderDescriptor{Name: spotifyLocalLyricsSource, Kind: providerKindPlayerLocal, TieRank: 21},
		privLocalClientIdentity|privPlayerNoVocals)

	return r
}
