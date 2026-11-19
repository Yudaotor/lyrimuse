package main

import (
	"context"
	"sync"
)

// LyricProvider 是引擎问一个歌词源的统一接口:一轮对一首歌问一次,源自己做完检索、过闸、回退、取词,交一份结果。
// 没问成不返回 error:这一轮没有就交一份只带源名的空结果。见 09 章决策 389。
type LyricProvider interface {
	Descriptor() *ProviderDescriptor
	Resolve(ctx context.Context, q ProviderQuery, env RoundEnv) SourceResult
}

// OfflineResolver 由带 privOfflineLeg 的源实现:这个源在熔断冷却的那一轮,调度不调 Resolve,改调 ResolveOffline,
// 只读客户端下在本机的那一份,不发请求。ok=false 是本机没有这首,这一轮照冷却跳过记。
type OfflineResolver interface {
	ResolveOffline(q ProviderQuery) (r SourceResult, ok bool)
}

// ProviderQuery 是这一轮交给源的查询。源内部读的 ctx 值(原样写法、子请求完成度、出站档位……)照旧挂在 ctx 上,不在这里。
type ProviderQuery struct {
	// Artist / Title / Album:这一轮的检索词。
	Artist, Title, Album string
	// SourceTitle:交给源去搜、去挑候选的歌名,播放器报的歌名带编号时是带着编号的那一份(lyricSourceTitleFor)。
	SourceTitle  string
	DurationSecs float64
}

// RoundEnv 是这一轮交给源的环境。
type RoundEnv struct {
	// ForPlayingTrack:这一轮解析的是正在放的那首或它的待播队列(playerSignalApplies)。
	ForPlayingTrack bool
}

// SourceResult 是一个源这一轮交回的结果。
type SourceResult = lyricSourceResult

// ProviderKind:这一路是联网的歌词源、读播放器自己缓存的本机来源,还是用户导入的库。
type ProviderKind int

const (
	providerKindNetwork ProviderKind = iota
	providerKindPlayerLocal
	providerKindUserLibrary
)

// RoundPolicy:哪些轮次问这个源。
type RoundPolicy int

const (
	// roundsAll:所有轮次都问。
	roundsAll RoundPolicy = iota
	// roundsOnDemand:只在用户此刻在听、在找的轮次里问(isOnDemandLyricRound)。
	roundsOnDemand
)

// HostScope:一条主机规则认多大范围。
type HostScope int

const (
	// hostExact:只认这一个主机。
	hostExact HostScope = iota
	// hostWithSubdomains:这个主机和它的各级子域。
	hostWithSubdomains
	// hostSubdomainsOnly:只认各级子域,不认它自己。
	hostSubdomainsOnly
)

// HostRule 把请求主机归到一个源。
type HostRule struct {
	Host  string
	Scope HostScope
}

// matches:host 是小写、不带端口的主机名。
func (r HostRule) matches(host string) bool {
	suffix := len(host) > len(r.Host) && host[len(host)-len(r.Host)-1] == '.' && host[len(host)-len(r.Host):] == r.Host
	switch r.Scope {
	case hostWithSubdomains:
		return host == r.Host || suffix
	case hostSubdomainsOnly:
		return suffix
	}
	return host == r.Host
}

// BakedPolicy:烘在正文里的逐行中文译文怎么处理(bakedtranslation.go)。
type BakedPolicy int

const (
	// bakedNone:不摘。
	bakedNone BakedPolicy = iota
	// bakedAdopt:摘出来,接到译文轨。
	bakedAdopt
	// bakedStripOnly:只摘不接。
	bakedStripOnly
	// bakedCustom:用这个源自己的摘法(ProviderDescriptor.BakedSplit),摘出来的接到译文轨。
	bakedCustom
)

// PlainTextOrder:没有带时间轴的候选、退到纯文本时这个源排在哪一档(plainTextFallbackFromScored)。
type PlainTextOrder int

const (
	plainTextNormal PlainTextOrder = iota
	// plainTextFirst:有它的就用它的。
	plainTextFirst
	// plainTextLast:别家都没有纯文本时才用。
	plainTextLast
)

// ISRCLookupMode:按 ISRC 补取那一轮问不问这个源(isrcRetryPlan)。
type ISRCLookupMode int

const (
	isrcLookupNone ISRCLookupMode = iota
	// isrcLookupDirect:能按 ISRC 直取。
	isrcLookupDirect
	// isrcLookupIndexed:本地索引里有这个 ISRC 才问。
	isrcLookupIndexed
)

// ProbeTrack:曲库盖不到共用探测曲的源自己的那一首。
type ProbeTrack struct {
	Artist, Title string
}

// builtinPrivileges:只给编在核心里的源的能力,一位一种。
type builtinPrivileges uint16

const (
	// privLocalClientIdentity:结果的身份可以由播放器本机数据给定(同源加权的准入),能读播放器原样标签。
	privLocalClientIdentity builtinPrivileges = 1 << iota
	// privPlaybackTrackIDs:读播放侧记下的平台曲目编号(Apple 目录 id、Spotify 曲目 id、videoId、客户端播放队列里的 id)。
	privPlaybackTrackIDs
	// privTrackIDPublish:把这一轮搜到的曲目编号递给别的源。
	privTrackIDPublish
	// privTrackIDConsume:等别的源递来的曲目编号(ProviderDescriptor.DependsOnIDsFrom)。
	privTrackIDConsume
	// privOfflineLeg:熔断冷却时不发请求,仍读客户端下在本机的那一份。
	privOfflineLeg
	// privPeripheral:这次查询顺带交封面、平台链接、规范歌手名。
	privPeripheral
	// privPlayerNoVocals:交「播放器自己说这一条没有人声」的信号(playerInstrumentalSource)。
	privPlayerNoVocals
	// privBorrowFromPeers:排序时借同一条录音别家的封面、时长。
	privBorrowFromPeers
	// privRefetchByID:存量回填时按条目上记的编号重取(bgbackfill.go)。
	privRefetchByID
	// privBreakerControl:自己要求熔断器把整源停掉(noteBlocked)。
	privBreakerControl
)

func (p builtinPrivileges) has(bit builtinPrivileges) bool { return p&bit != 0 }

// ProviderDescriptor 是一个源的登记信息。各字段跟现有按源名写的表逐项相等,由 lyricproviderregistry_test.go 守着;
// 改这里的值就要同步改对应的表,反之亦然。
type ProviderDescriptor struct {
	// Name:缓存、留痕、统计里的源名。
	Name string
	Kind ProviderKind

	// Order:联网源在源名单里的位置(lyricSourceNames),从 1 起;本机来源为 0。
	Order int
	// TieRank:同分候选的决胜序(lyricCandidateTieOrder),从 1 起,小的赢。
	TieRank int
	// DefaultPriorityRank:顺序优先模式的默认顺序(lyricsSourceDefaultOrder),从 1 起;本机来源为 0。
	DefaultPriorityRank int

	Rounds RoundPolicy

	// Hosts:哪些请求主机归这个源(lyricSourceForHost)。
	Hosts []HostRule
	// HostRates:单独定了令牌桶参数的主机(hostRateFor),没列的用 hostRateDefault。
	HostRates map[string]hostRate
	// MaxInflight:同时在途的请求上限(lyricSourceInflightCaps),0 = lyricSourceInflightDefault。
	MaxInflight int
	// HourlyBudget:后台一小时的请求额度(lyricSourceHourlyBudget),0 = 不限。
	HourlyBudget int
	// DayQuotaReserve:每日额度剩这么多时只留给前台(lyricSourceDayQuotaReserve),0 = 这个源不报每日额度。
	DayQuotaReserve int
	// ProxyFallback:直连失败后改走代理(lyricSourceProxyFallbackSources)。
	ProxyFallback bool

	Baked BakedPolicy
	// BakedSplit:Baked 为 bakedCustom 时的摘法。
	BakedSplit func(lyrics string, foreignSong bool) (clean, tr string, n int)
	// ParenBackground:正文里的括号段拆成背景人声轨(parenBGSources)。
	ParenBackground bool
	// CarriesKana:正文里会带 `[kana:]` 假名标注(kanaDonorSources)。
	CarriesKana bool
	// InstrumentalRank:纯音乐标记搭车的先后(rankLyricSourceResults),从 1 起;0 = 不搭车。
	InstrumentalRank int
	// SongwritersRank:词曲作者名单的取用先后(songwritersFromScored),从 1 起;0 = 不取用。
	SongwritersRank int
	// SongwritersSkipCJK:正文是中日韩文字时不用它的作者名单。
	SongwritersSkipCJK bool
	PlainText          PlainTextOrder
	// ConsensusFamily:正文同出一家的源互不印证(lyricSourceConsensusFamily);空 = 自成一家。
	ConsensusFamily string
	ISRCLookup      ISRCLookupMode
	// ISRCAuthority:它报的 ISRC 可以当这条录音的记下来(recordingISRCsFromScored)。
	ISRCAuthority bool
	// PageURL:核对这份歌词在源网站上的页面地址(lyricSourcePageURL),nil = 不链回。
	PageURL func(raw string) string

	// PeerGroup:近况统计的同类组(lyricSourcePeerGroups),空 = 不进任何一组。
	PeerGroup string
	// Probe:自己的探测曲(lyricSourceOwnProbes),nil = 用共用的探测曲。
	Probe *ProbeTrack
	// QueryIndependentFailure:最近一次跟检索词无关的失败原因(鉴权、换票、地区受限、签名被拒),非空时补查轮不问它
	// (lyricSourcesWorthRetry);nil = 没有这类原因。
	QueryIndependentFailure func() string

	// Privileges 只在 registerBuiltin 里写。
	Privileges builtinPrivileges
	// DependsOnIDsFrom:等哪几个源递来的曲目编号,带 privTrackIDConsume 的源才有。
	DependsOnIDsFrom []string
}

// lyricProviderRegistry 是全部歌词来源的登记表:联网源和本机来源各一份描述符,已经接到 LyricProvider 上的源另有一份实现。
type lyricProviderRegistry struct {
	descriptors []*ProviderDescriptor
	byName      map[string]*ProviderDescriptor
	// providers:已经接到统一接口上的源。收集循环由调度起它们(startLyricProviders),不在这里的源仍是循环里手写的
	// goroutine;一个源只能走其中一条路,两条都走会多交一份结果,都不走这一轮会等到截止。
	providers []LyricProvider
}

// registerBuiltin 登记一个编在核心里的源,特权位写在调用处。返回登记好的描述符。
func (r *lyricProviderRegistry) registerBuiltin(d *ProviderDescriptor, privileges builtinPrivileges) *ProviderDescriptor {
	d.Privileges = privileges
	r.descriptors = append(r.descriptors, d)
	r.byName[d.Name] = d
	return d
}

// implement 登记一个源的实现。
func (r *lyricProviderRegistry) implement(p LyricProvider) {
	r.providers = append(r.providers, p)
}

// descriptor:没登记的名字返回 nil。
func (r *lyricProviderRegistry) descriptor(name string) *ProviderDescriptor {
	return r.byName[name]
}

var (
	lyricProvidersOnce   sync.Once
	lyricProvidersShared *lyricProviderRegistry
)

// lyricProviders 返回登记表,第一次用到时建。别改成包级变量的初始化式:描述符引用各源的函数,那些函数以后读登记表时
// 会成初始化环。
func lyricProviders() *lyricProviderRegistry {
	lyricProvidersOnce.Do(func() { lyricProvidersShared = newBuiltinLyricProviderRegistry() })
	return lyricProvidersShared
}
