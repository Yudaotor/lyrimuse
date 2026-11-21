package main

import (
	"context"
	"net"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

// LyricProvider 是引擎问一个歌词源的统一接口:一轮对一首歌问一次,源自己做完检索、过闸、回退、取词,交一份结果。
// 没问成不返回 error:这一轮没有就交一份只带源名的空结果。见 09 章决策 389。
type LyricProvider interface {
	Descriptor() *ProviderDescriptor
	Resolve(ctx context.Context, q ProviderQuery, env RoundEnv) SourceResult
}

// QueryIndependentFailer 由会遇到「跟检索词无关的失败」的源实现:鉴权、换票、地区受限、签名被拒这一类,换个歌手歌名的
// 写法照样问不成。QueryIndependentFailure 交最近一次这类失败的原因代码,没有时为空;非空时补查轮(别名轮、按 ISRC 补取)
// 不问这个源(lyricSourcesWorthRetry)。
//
// 它跟 FailureDiagnoser 是两回事、覆盖的源也不同,别并成一个方法:这里答的是「再问一遍有没有用」,那边答的是「界面上
// 该显示什么原因」。有的源有显示得出的原因、补查轮却照问(网易云的限流过一会儿就好),有的源补查轮不问、界面上另有
// 专门的提示(Apple Music 没连账号)。
type QueryIndependentFailer interface {
	QueryIndependentFailure() string
}

// FailureDiagnoser 由接了失败诊断的源实现。DiagnosedFailure 交这个进程里最近一次认出来的专属失败原因(稳定代码,不是文案,
// 见 lyricsourcefailure.go),没有时为空。手动搜索的「歌词源可用情况」(lyricSourceFailureReasonsWith)和设置页的「测试」
// (runTestLyricSourcesCLI)对没给出候选的源显示它;没实现的源只有传输层的通用原因。
//
// 只交这个源自己的请求认出来的失败。一个源因为它等的源没给编号而没法查(AMLL),那是按依赖推出来的结论,由消费方
// 自己推,不算在这里。
type FailureDiagnoser interface {
	DiagnosedFailure() string
}

// OwnProbeProvider 由描述符带 Probe 的源实现:曲库盖不到共用探测曲的源,拿自己那首探测曲直接问一次这个源自己的取词,
// 不经整轮搜索、不打扰别的源;问出了歌词返回 true。test-lyric-sources 和 healthcheck 共用(ownLyricSourceProbe)。
type OwnProbeProvider interface {
	ProbeOwnTrack(ctx context.Context) bool
}

// ISRCIndexProvider 由 ISRCLookup 是 isrcLookupIndexed 的源实现:按 ISRC 补取那一轮只在它的本地索引里有这个 ISRC 时问它。
type ISRCIndexProvider interface {
	HasISRC(isrc string) bool
}

// PreSearchNoVocalsHinter 由带 privPlayerNoVocals、而且播放器的本机数据在开搜之前就能说「这一条没有人声」的源实现
// (playerNoVocalsHintBeforeSearch)。HintsNoVocals 只读本机数据、不发请求;正在放的不是它那个播放器时返回 false。
type PreSearchNoVocalsHinter interface {
	HintsNoVocals(q ProviderQuery) bool
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

// RoundEnv 是这一轮交给源的环境。带特权的那几样(播放器原样标签、在放的是哪个播放器、播放侧记下的平台曲目编号、
// 播放器自己的无人声信号、源之间递的曲目编号)只经下面的方法读写,方法按 granted 放行:收集循环建的那份 granted 是 0,调度交给源之前按它的描述符填
// (grantedTo),没有对应特权位的源读到的是零值、等不到别人的编号、递的编号没有效果。见 09 章决策 392、393、395。
//
// 这个结构要能用 == 比:别往里加切片、map、函数字段。
type RoundEnv struct {
	// ForPlayingTrack:这一轮解析的是正在放的那首或它的待播队列(playerSignalApplies)。
	ForPlayingTrack bool
	// identityArtist / identityTitle / identityAlbum:播放器原样标签(lyricIdentityFields),播放侧按它记平台曲目编号,
	// 本机类源按它认这一首。
	identityArtist, identityTitle, identityAlbum string
	// granted:拿到这份环境的源的特权位。
	granted builtinPrivileges
	// trackIDs:这一轮源之间递曲目编号的地方,调度起这一轮的源时建(startLyricProviders);nil 时不递。
	trackIDs *roundTrackIDs
	// ownTrackID:拿到这份环境的源自己往外递编号的那一格,这一轮没有它的格时是 nil。
	ownTrackID *roundTrackID
}

// grantedTo:交给描述符是 d 的那个源的一份,特权位照 d 的填,往外递编号的那一格是 d 自己的。
func (e RoundEnv) grantedTo(d *ProviderDescriptor) RoundEnv {
	e.granted = d.Privileges
	e.ownTrackID = e.trackIDs.slot(d.Name)
	return e
}

// PublishTrackID:把这一轮搜到的曲目编号递给等它的源,没搜到递空串。编号一到手就该递,不必等取完词:等的一方只要编号。
// 一轮只有第一次递的算数。要 privTrackIDPublish,没有这一位的源调了没有效果。
func (e RoundEnv) PublishTrackID(id string) {
	if !e.granted.has(privTrackIDPublish) {
		return
	}
	e.ownTrackID.publish(id)
}

// TrackIDFrom:source 这个源这一轮递出来的曲目编号。它还没递时等;它被跳过、没搜到,或这一轮没起它时是空串。
// 要 privTrackIDConsume,没有这一位的源不等、拿到空串。
func (e RoundEnv) TrackIDFrom(source string) string {
	if !e.granted.has(privTrackIDConsume) {
		return ""
	}
	return e.trackIDs.slot(source).await()
}

// roundTrackIDs 是一轮里源之间递曲目编号的地方:这一轮起的源里带 privTrackIDPublish 的各有一格。等编号的源自己一个
// goroutine 等,不把它的查询塞进递编号的源里:那样它的网络耗时会串到主力源头上,拖慢它们到达。见 09 章决策 393。
type roundTrackIDs struct {
	slots map[string]*roundTrackID
}

// roundTrackID 是一个源这一轮递出来的曲目编号。等的一方在它递出来之前一直等、不看 ctx,所以每一格都必须有人递:
// 源自己没递的由调度在它返回时代递空串(runLyricProviderInRound),漏了这一步等的一方会挂到这一轮截止。
// 递编号的源不能自己又等别人的编号(DependsOnIDsFrom 为空):成环就两边都等不到。
type roundTrackID struct {
	once sync.Once
	done chan struct{}
	id   string
}

func newRoundTrackIDs(providers []LyricProvider) *roundTrackIDs {
	b := &roundTrackIDs{slots: map[string]*roundTrackID{}}
	for _, p := range providers {
		if d := p.Descriptor(); d.Privileges.has(privTrackIDPublish) {
			b.slots[d.Name] = &roundTrackID{done: make(chan struct{})}
		}
	}
	return b
}

// slot:source 这一轮的那一格。这一轮没起它、它不往外递编号,或者 b 是 nil 时返回 nil。
func (b *roundTrackIDs) slot(source string) *roundTrackID {
	if b == nil {
		return nil
	}
	return b.slots[source]
}

// publish:只有第一次算数。s 是 nil 时什么都不做。
func (s *roundTrackID) publish(id string) {
	if s == nil {
		return
	}
	s.once.Do(func() {
		s.id = id
		close(s.done)
	})
}

// await:等这一格递出来。s 是 nil(这一轮没有这个源递编号)时立刻返回空串。
func (s *roundTrackID) await() string {
	if s == nil {
		return ""
	}
	<-s.done
	return s.id
}

// IdentityFields:播放器原样标签(歌手、歌名、专辑),本机类源按它在播放器自己的数据里认这一首,不用检索词。
// 要 privLocalClientIdentity,没有这一位的源拿到三个空串。
func (e RoundEnv) IdentityFields() (artist, title, album string) {
	if !e.granted.has(privLocalClientIdentity) {
		return "", "", ""
	}
	return e.identityArtist, e.identityTitle, e.identityAlbum
}

// PlayingPlayer:现在在放的播放器(playingPlayer)。要 privLocalClientIdentity,没有这一位的源拿到空串。各源的 Resolve
// 一律经它读,不直接调 playingPlayer。
func (e RoundEnv) PlayingPlayer() string {
	if !e.granted.has(privLocalClientIdentity) {
		return ""
	}
	return playingPlayer()
}

// PlaybackTrackIDs:播放侧为这一首记下的平台曲目编号(playbackTrackIDsForRound),别的歌那一轮不给。
// 要 privPlaybackTrackIDs,没有这一位的源拿到两个空串。
func (e RoundEnv) PlaybackTrackIDs(ctx context.Context) (appleCatalogID, spotifyTrackID string) {
	if !e.granted.has(privPlaybackTrackIDs) {
		return "", ""
	}
	return playbackTrackIDsForRound(ctx, e.identityArtist, e.identityTitle, e.identityAlbum)
}

// AwaitPlayingAppleCatalogID:在放的这首的 Apple 目录 id,播放侧还没核对完时等它就绪(waitPlayingAppleCatalogID)。
// 要 privPlaybackTrackIDs,没有这一位的源不等、拿到空串。
func (e RoundEnv) AwaitPlayingAppleCatalogID(ctx context.Context) string {
	if !e.granted.has(privPlaybackTrackIDs) {
		return ""
	}
	return waitPlayingAppleCatalogID(ctx, e.identityArtist, e.identityTitle, e.identityAlbum)
}

// PlayerNoVocalsSignalApplies:这一轮能不能用正在放的播放器自己的无人声信号(ForPlayingTrack)。
// 要 privPlayerNoVocals,没有这一位的源一律拿到 false。
func (e RoundEnv) PlayerNoVocalsSignalApplies() bool {
	return e.granted.has(privPlayerNoVocals) && e.ForPlayingTrack
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

// RoundPolicy:哪些轮次问这个源。本机类源一律是 roundsPrimaryOnly。
type RoundPolicy int

const (
	// roundsAll:所有轮次都问。
	roundsAll RoundPolicy = iota
	// roundsOnDemand:只在用户此刻在听、在找的轮次里问(isOnDemandLyricRound)。
	roundsOnDemand
	// roundsPrimaryOnly:只在首轮问(lyricQueryReasonPrimary)。本机类源认这一首不看检索词的写法,别名轮、反查轮里再交
	// 一份会被当成「这个别名救回了候选」;首轮那份靠 mergeLyricCandidateRounds 的只增不减留到最后。
	roundsPrimaryOnly
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

// PriorityPlacement:「顺序优先」模式里这个来源排在哪(priorityTiers / priorityPick)。
type PriorityPlacement int

const (
	// priorityByUserOrder:在用户排的顺序表里自己占一个名次(联网源;默认先后看 DefaultPriorityRank)。
	priorityByUserOrder PriorityPlacement = iota
	// priorityWithPlayerLocal:并在「播放器自带歌词」那一个名次里,同一个名次里按分数挑。
	priorityWithPlayerLocal
	// priorityFileLyrics:歌曲文件自带的歌词。开着「优先用歌曲文件自带的歌词」时自成最前面的一个名次,关着时并进
	// 「播放器自带歌词」那一个名次。
	priorityFileLyrics
	// priorityAboveAll:排在所有名次之前,自己不占名次。用户导入的歌词是这一种:它不像各源那样「回话」,做成一个名次的话
	// 早定和重试会一直等它。
	priorityAboveAll
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
	// privPlayerNoVocals:交「播放器自己说这一条没有人声」的信号(playerInstrumentalSource 只认带这一位的源)。
	privPlayerNoVocals
	// privBorrowFromPeers:排序时借同一条录音别家的封面、时长(CandidateAssembly.BorrowFromPeers)。
	privBorrowFromPeers
	// privRefetchByID:存量回填时按条目上记的编号重取(bgbackfill.go)。
	privRefetchByID
	// privBreakerControl:自己要求熔断器把整源停掉(noteBlocked)。
	privBreakerControl
)

func (p builtinPrivileges) has(bit builtinPrivileges) bool { return p&bit != 0 }

// ProviderDescriptor 是一个源的登记信息。每个字段要么是生产代码唯一读的那一份(期望值冻结在 lyricsourceexpect_test.go),
// 要么跟还在用的按源名写的表逐项相等;两种都由 lyricproviderregistry_test.go 守着,改这里的值要同步改对应的期望表或旧表。
type ProviderDescriptor struct {
	// Name:缓存、留痕、统计里的源名。
	Name string
	Kind ProviderKind
	// Origin:编在核心里的(零值),还是运行时登记的。只由 admitDynamicLyricSource 写。
	Origin ProviderOrigin

	// Order:联网源在源名单里的位置(networkLyricSourceNames),从 1 起;本机来源为 0。只决定「有歌没词」标记、日志和
	// 设置项里的源序,同分候选谁赢看 TieRank。
	Order int
	// TieRank:同分候选的决胜序(lyricProviderRegistry.tieOrder),从 1 起,小的赢;本机来源排在别的联网源之后、AMLL 之前。
	// rankLyricSourceResultsWith 按它定候选的先后(candidateSlots.inTieOrder),合并几轮结果的 mergeLyricCandidateRounds 按它
	// 重建顺序:两处读同一种名单,同一首歌走没走补查轮,同分时选出的源才相同(lyrictieorder_test.go 守着)。
	TieRank int
	// DefaultPriorityRank:顺序优先模式的默认顺序(resolveLyricsSourceOrder),从 1 起;本机来源为 0。必须跟 App 侧
	// LyricsSource.allCases 的声明顺序一致:那边顺序表的默认值就是 allCases,对不上的话顺序优先模式在首次写盘前后表现不同。
	DefaultPriorityRank int
	// PriorityPlacement:顺序优先模式里排在哪。联网源是 priorityByUserOrder,本机类源是另外三种之一。
	PriorityPlacement PriorityPlacement

	Rounds RoundPolicy

	// Hosts:哪些请求主机归这个源(lyricSourceOwningHost)。联网源至少登记一个:主机没登记的请求不归任何源,它的失败一次都
	// 不记进熔断。一个主机只能归一个源(各源的规则不能重叠);只登记这个源取词、搜索真正请求的主机,别把同一个域名下用途
	// 不同的主机卷进来(它们的故障会连带停掉这个源)。
	Hosts []HostRule
	// HostRates:单独定了令牌桶参数的主机(hostRateFor 经 lyricProviderRegistry.hostRates 读),没列的用 hostRateDefault。
	// 键是小写、不带端口的主机名,只对这一个主机生效。
	HostRates map[string]hostRate
	// MaxInflight:同时在途的请求上限(lyricSourceMaxInflight),0 = lyricSourceInflightDefault。
	MaxInflight int
	// HourlyBudget:后台一小时的请求额度(lyricSourceBudgetPerHour),0 = 不限。
	HourlyBudget int
	// DayQuotaReserve:每日额度剩这么多时只留给前台(lyricSourceDayReserve),0 = 这个源不报每日额度。
	DayQuotaReserve int
	// ProxyFallback:直连失败后改走代理(lyricSourceUsesProxyFallback)。
	ProxyFallback bool

	// Assembly:排序时怎么把这个源交的结果装成候选(assembleSourceCandidate),每个来源都有。
	Assembly *CandidateAssembly
	Baked    BakedPolicy
	// BakedSplit:Baked 为 bakedCustom 时的摘法。
	BakedSplit func(lyrics string, foreignSong bool) (clean, tr string, n int)
	// ParenBackground:正文里的括号段拆成背景人声轨(lyricSourceSplitsParenBackground)。自带结构化背景人声的源不拆:正文里
	// 剩下的括号是它们判成主唱的部分,存量回填(bgbackfill.go)还会整份换掉它们的 lyrics_bg;本机文件、各客户端缓存里的
	// 用户歌词也不拆(洛雪存下的是平台原版,拆)。
	ParenBackground bool
	// CarriesKana:正文里会带 `[kana:]` 假名标注(lyricSourceCarriesKana)。
	CarriesKana bool
	// InstrumentalRank:纯音乐标记搭车的先后(lyricProviderRegistry.instrumentalOrder),从 1 起;0 = 不搭车。几个源同时说这首是
	// 纯音乐时,标记记在名次最靠前的那个头上;凭什么说见 CandidateAssembly.Instrumental。
	InstrumentalRank int
	// SongwritersRank:词曲作者名单的取用先后(songwritersFromScored 经 lyricProviderRegistry.songwritersOrder 读),从 1 起;
	// 0 = 不取用。排序时这个源交的名单抄不抄进结果也看它(assembleSourceCandidate)。
	SongwritersRank int
	// SongwritersSkipCJK:正文是中日韩文字时不用它的作者名单。
	SongwritersSkipCJK bool
	PlainText          PlainTextOrder
	// ConsensusFamily:正文同出一家的源互不印证(lyricProviderRegistry.sourceFamily);空 = 自成一家。
	ConsensusFamily string
	// HandTypedTimeline:时间轴是上传者手打的。它那份跟正文共识的另一家整体错开时扣分(applyHandTypedTimelinePenalty)。
	HandTypedTimeline bool
	ISRCLookup        ISRCLookupMode
	// ISRCAuthority:它报的 ISRC 可以当这条录音的记下来(recordingISRCsFromScored)。
	ISRCAuthority bool
	// PageURL:核对这份歌词在源网站上的页面地址(verifiedLyricSourcePageURL),nil = 不链回。
	PageURL func(raw string) string

	// PeerGroup:近况统计的同类组(lyricSourcePeerGroup),空 = 不进任何一组。同组的是曲库覆盖面可比的源:按平台 ID 直取的、
	// 只在某一种语言的歌上是主力的、只在播放那一侧问而且曲库小的,跟谁都不可比,不进组。本机类源不统计,不填。
	PeerGroup string
	// Probe:自己的探测曲,nil = 用共用的探测曲。有它的源要实现 OwnProbeProvider。
	Probe *ProbeTrack

	// Privileges 只在 builtinLyricSources.registerBuiltin 里写。
	Privileges builtinPrivileges
	// DependsOnIDsFrom:等哪几个源递来的曲目编号,带 privTrackIDConsume 的源才有。别名轮的名单里这几个源一个都不在时,
	// 这个源也不问(dropSourcesMissingIDFeeders)。
	DependsOnIDsFrom []string
}

// lyricProviderRegistry 是全部歌词来源的登记表:联网源和本机来源各一份描述符、一份实现,由调度起(startLyricProviders)。
//
// 一份登记表一次构造完(newLyricProviderRegistry),之后不改:里面的切片、map 和各份名单谁都不许动。来源要增减就拿新的
// 来源名单另构造一份,换掉当前生效的那一份(lyricRegistryCurrent)。所以拿着一份登记表的读者,从头到尾看到的是同一组
// 来源、同一组名单;要跨好几步用同一组来源的(一轮搜索),开头取一次 lyricProviders() 一直用到底,别中途再取。
// 见 09 章决策 401。
type lyricProviderRegistry struct {
	descriptors []*ProviderDescriptor
	byName      map[string]*ProviderDescriptor
	// byProvider:源名 → 它的实现。
	byProvider map[string]LyricProvider
	// providers:各来源的实现,一个来源恰好一份,先后跟 descriptors 一样。联网源每个一个并发 goroutine,收集循环按
	// networkNames 数「都回来了没有」:两份名单出自同一组实现,数目对得上。本机类源按这里的先后同步问。
	providers []LyricProvider

	// 下面几份名单构造时算一次(index),读的一方别改它们。
	// networkNames:联网源按 Order。
	networkNames []string
	// tieOrder:全部来源按 TieRank。
	tieOrder []string
	// defaultPriorityOrder:联网源按 DefaultPriorityRank。
	defaultPriorityOrder []string
	// instrumentalOrder:搭纯音乐标记的来源按 InstrumentalRank。
	instrumentalOrder []string
	// songwritersOrder:取用词曲作者名单的来源按 SongwritersRank。
	songwritersOrder []string
	// priorityPlayerLocalNames / priorityFileNames:顺序优先里并在「播放器自带歌词」那一个名次的来源、歌曲文件自带歌词的
	// 来源(PriorityPlacement),按登记的先后。
	priorityPlayerLocalNames, priorityFileNames []string
	// playerNoVocalsNames:带 privPlayerNoVocals 的来源,按登记的先后。正在放的播放器至多认其中一个是自家的
	// (playerOwnsLyricSource),先后不影响结果。
	playerNoVocalsNames []string
	// dynamicPriorityNames:运行时登记的来源按 DefaultPriorityRank(顺序优先里排在用户顺序表的各名次之后,priorityTiers)。
	dynamicPriorityNames []string
	// peerGroups:同类组的名字 → 组里的联网源按 Order。
	peerGroups map[string][]string
	// hostRates:单独定了令牌桶参数的主机 → 参数,各描述符的 HostRates 并在一起。
	hostRates map[string]hostRate
	// hostOwners / domainOwners:各描述符的 Hosts 摊成的查表结构。hostOwners 是主机 → 源(规则认主机自己的);
	// domainOwners 是域名 → 源(规则认它各级子域的)。
	hostOwners, domainOwners map[string]string
}

// newLyricProviderRegistry 用一组来源的实现构造登记表:每个实现的描述符(Descriptor)登记一份,先后照 providers,各份名单
// 当场算好。providers 里不能有重名的、交不出描述符的:编在核心里的那一组由登记表守卫钉着,运行时登记的在进来之前校验。
func newLyricProviderRegistry(providers []LyricProvider) *lyricProviderRegistry {
	r := &lyricProviderRegistry{
		byName: make(map[string]*ProviderDescriptor, len(providers)), byProvider: make(map[string]LyricProvider, len(providers)),
		providers: slices.Clone(providers),
	}
	for _, p := range r.providers {
		d := p.Descriptor()
		r.descriptors = append(r.descriptors, d)
		r.byName[d.Name] = d
		r.byProvider[d.Name] = p
	}
	r.index()
	return r
}

// index 按描述符算出各份名单,只在构造时调。名单是描述符里的 Kind、名次、特权位算出来的:这些字段登记之后不改。
func (r *lyricProviderRegistry) index() {
	network := func(d *ProviderDescriptor) bool { return d.Kind == providerKindNetwork }
	r.networkNames = r.rankedNames(network, func(d *ProviderDescriptor) int { return d.Order })
	r.tieOrder = r.rankedNames(func(*ProviderDescriptor) bool { return true }, func(d *ProviderDescriptor) int { return d.TieRank })
	r.defaultPriorityOrder = r.rankedNames(network, func(d *ProviderDescriptor) int { return d.DefaultPriorityRank })
	r.instrumentalOrder = r.rankedNames(func(d *ProviderDescriptor) bool { return d.InstrumentalRank > 0 },
		func(d *ProviderDescriptor) int { return d.InstrumentalRank })
	r.songwritersOrder = r.rankedNames(func(d *ProviderDescriptor) bool { return d.SongwritersRank > 0 },
		func(d *ProviderDescriptor) int { return d.SongwritersRank })
	r.dynamicPriorityNames = r.rankedNames(func(d *ProviderDescriptor) bool { return d.Origin == originDynamic },
		func(d *ProviderDescriptor) int { return d.DefaultPriorityRank })
	r.playerNoVocalsNames, r.priorityPlayerLocalNames, r.priorityFileNames = nil, nil, nil
	for _, d := range r.descriptors {
		if d.Privileges.has(privPlayerNoVocals) {
			r.playerNoVocalsNames = append(r.playerNoVocalsNames, d.Name)
		}
		switch d.PriorityPlacement {
		case priorityWithPlayerLocal:
			r.priorityPlayerLocalNames = append(r.priorityPlayerLocalNames, d.Name)
		case priorityFileLyrics:
			r.priorityFileNames = append(r.priorityFileNames, d.Name)
		}
	}
	r.indexPeerGroups()
	r.hostRates = map[string]hostRate{}
	r.hostOwners, r.domainOwners = map[string]string{}, map[string]string{}
	for _, d := range r.descriptors {
		for host, rate := range d.HostRates {
			r.hostRates[host] = rate
		}
		for _, rule := range d.Hosts {
			if rule.Scope != hostSubdomainsOnly {
				r.hostOwners[rule.Host] = d.Name
			}
			if rule.Scope != hostExact {
				r.domainOwners[rule.Host] = d.Name
			}
		}
	}
}

// sourceOwningHost:host(小写、不带端口)按各描述符的 Hosts 归到哪个源,都不认是空串。先看主机自己,再从左到右逐级
// 去掉一段看父域;不遍历描述符、不分配。
func (r *lyricProviderRegistry) sourceOwningHost(host string) string {
	if source, ok := r.hostOwners[host]; ok {
		return source
	}
	for rest := host; ; {
		dot := strings.IndexByte(rest, '.')
		if dot < 0 {
			return ""
		}
		rest = rest[dot+1:]
		if source, ok := r.domainOwners[rest]; ok {
			return source
		}
	}
}

// indexPeerGroups 按描述符的 PeerGroup 重算同类组。
func (r *lyricProviderRegistry) indexPeerGroups() {
	groups := map[string][]string{}
	for _, name := range r.networkNames {
		if g := r.byName[name].PeerGroup; g != "" {
			groups[g] = append(groups[g], name)
		}
	}
	r.peerGroups = groups
}

// rankedNames:keep 选中的描述符的源名,按 rank 从小到大。
func (r *lyricProviderRegistry) rankedNames(keep func(*ProviderDescriptor) bool, rank func(*ProviderDescriptor) int) []string {
	ds := make([]*ProviderDescriptor, 0, len(r.descriptors))
	for _, d := range r.descriptors {
		if keep(d) {
			ds = append(ds, d)
		}
	}
	sort.SliceStable(ds, func(i, j int) bool { return rank(ds[i]) < rank(ds[j]) })
	names := make([]string, len(ds))
	for i, d := range ds {
		names[i] = d.Name
	}
	return names
}

// builtinLyricSources 收编在核心里的来源(builtinLyricProviderList),按登记的先后。
type builtinLyricSources struct {
	providers []LyricProvider
}

// registerBuiltin 给一个编在核心里的源的描述符写上特权位,特权位写在调用处。返回这份描述符。
func (b *builtinLyricSources) registerBuiltin(d *ProviderDescriptor, privileges builtinPrivileges) *ProviderDescriptor {
	d.Privileges = privileges
	return d
}

// implement 收一个源的实现。
func (b *builtinLyricSources) implement(p LyricProvider) {
	b.providers = append(b.providers, p)
}

// provider:name 这个源的实现,没登记的名字返回 nil。问源的可选接口时用:`p, ok := r.provider(name).(接口)`。
func (r *lyricProviderRegistry) provider(name string) LyricProvider {
	return r.byProvider[name]
}

// descriptor:没登记的名字返回 nil。
func (r *lyricProviderRegistry) descriptor(name string) *ProviderDescriptor {
	return r.byName[name]
}

var (
	lyricRegistryInit sync.Once
	// lyricRegistryBuiltin:只有编在核心里的来源的那一份,进程里只建一次。
	lyricRegistryBuiltin *lyricProviderRegistry
	// lyricRegistryCurrent:当前生效的登记表。换新是整份换(Store 一份新构造的),不改已经交出去的那一份。没有运行时登记的
	// 来源时就是 lyricRegistryBuiltin。
	lyricRegistryCurrent atomic.Pointer[lyricProviderRegistry]
)

// lyricProviders 返回当前生效的登记表,第一次用到时用编在核心里的来源建。别改成包级变量的初始化式:描述符引用各源的
// 函数,那些函数以后读登记表时会成初始化环。
//
// 每调一次读到的可能是不同的一份(中间换过新的)。一件事里要前后一致地读名单、描述符的,取一次存在局部变量里用。
func lyricProviders() *lyricProviderRegistry {
	lyricRegistryInit.Do(initLyricRegistry)
	return lyricRegistryCurrent.Load()
}

func initLyricRegistry() {
	lyricRegistryBuiltin = newLyricProviderRegistry(builtinLyricProviderList())
	lyricRegistryCurrent.Store(lyricRegistryBuiltin)
}

// builtinLyricRegistry 返回只有编在核心里的来源的那份登记表,运行时登记了什么都不影响它。设置里的源开关和顺序表只认
// 这一份里的名字(resolveLyricsSources、resolveLyricsSourceOrder);运行时登记的来源的校验、名次以它为底。
func builtinLyricRegistry() *lyricProviderRegistry {
	lyricRegistryInit.Do(initLyricRegistry)
	return lyricRegistryBuiltin
}

// enabledNetworkCount:这份登记表里开着的联网源有几个(进度分母)。
func (r *lyricProviderRegistry) enabledNetworkCount() int {
	n := 0
	for _, s := range r.networkNames {
		if r.sourceEnabled(s) {
			n++
		}
	}
	return n
}

// networkLyricSourceNames:联网歌词源的名字,按 Order。每个联网源一轮一个并发 goroutine;结果通道的缓冲、进度分母、到齐判断、
// 熔断轮次、近况统计、设置里的开关都只数它们,本机类源(读播放器本机数据的、导入库)不在里面。返回的是登记表里那一份,别改它。
func networkLyricSourceNames() []string { return lyricProviders().networkNames }

// isNetworkLyricSource:name 是不是登记过的联网歌词源。
func isNetworkLyricSource(name string) bool { return lyricSourceKindIs(name, providerKindNetwork) }

// lyricSourcePeerGroup:source 所在的同类组(近况统计拿同组的源互相比),联网源按 Order;不在任何一组时是 nil。
// 返回的是登记表里那一份,别改它。
func lyricSourcePeerGroup(source string) []string {
	r := lyricProviders()
	d := r.descriptor(source)
	if d == nil || d.PeerGroup == "" {
		return nil
	}
	return r.peerGroups[d.PeerGroup]
}

// verifiedLyricSourcePageURL:source 这个源的歌词页地址核过之后的样子(描述符的 PageURL);不是要链回的源、地址不对时为空。
func verifiedLyricSourcePageURL(source, raw string) string {
	d := lyricProviders().descriptor(source)
	if d == nil || d.PageURL == nil {
		return ""
	}
	return d.PageURL(raw)
}

// lyricSourceTakesISRC:按 ISRC 补取那一轮问不问 source(描述符的 ISRCLookup):能直取的问;索引里有才问的,看它自己的索引里
// 有没有这个 ISRC(ISRCIndexProvider)。
func lyricSourceTakesISRC(source, isrc string) bool {
	r := lyricProviders()
	d := r.descriptor(source)
	if d == nil {
		return false
	}
	switch d.ISRCLookup {
	case isrcLookupDirect:
		return true
	case isrcLookupIndexed:
		index, ok := r.provider(source).(ISRCIndexProvider)
		return ok && index.HasISRC(isrc)
	}
	return false
}

// lyricSourceOwningHost 把请求主机归到歌词源名(描述符的 Hosts);不是歌词源的主机(Last.fm / ListenBrainz / MusicBrainz /
// iTunes / DoH …)返回空串。host 可以带端口、大写、首尾空白。按主机记的状态(熔断器的失败与成功、端点限流上报、审计汇总的
// 分组)直接读它;「这个请求算在哪个源名下」读 outboundSourceFor。
func lyricSourceOwningHost(host string) string {
	h := strings.ToLower(strings.TrimSpace(host))
	if strings.Contains(h, ":") {
		if hostOnly, _, err := net.SplitHostPort(h); err == nil {
			h = hostOnly
		}
	}
	return lyricProviders().sourceOwningHost(h)
}

// lyricSourceMaxInflight:source 同时在途的请求上限(描述符的 MaxInflight)。没单独定的、没登记的名字都是
// lyricSourceInflightDefault。
func lyricSourceMaxInflight(source string) int {
	if d := lyricProviders().descriptor(source); d != nil && d.MaxInflight > 0 {
		return d.MaxInflight
	}
	return lyricSourceInflightDefault
}

// lyricSourceBudgetPerHour:source 一小时的请求额度(描述符的 HourlyBudget),0 = 不限。没登记的名字不限。
func lyricSourceBudgetPerHour(source string) int {
	if d := lyricProviders().descriptor(source); d != nil {
		return d.HourlyBudget
	}
	return 0
}

// lyricSourceDayReserve:source 的每日额度剩多少次时只给前台用(描述符的 DayQuotaReserve);0 = 这个源不报每日额度,
// 没登记的名字同样是 0。
func lyricSourceDayReserve(source string) int {
	if d := lyricProviders().descriptor(source); d != nil {
		return d.DayQuotaReserve
	}
	return 0
}

// lyricSourceUsesProxyFallback:source 直连失败后改不改走代理(描述符的 ProxyFallback)。空串、没登记的名字不走。
func lyricSourceUsesProxyFallback(source string) bool {
	d := lyricProviders().descriptor(source)
	return d != nil && d.ProxyFallback
}

// lyricSourceSplitsParenBackground:source 正文里的括号段拆不拆成背景人声轨(描述符的 ParenBackground)。没登记的名字
// (手改的、粘贴的、空串)不拆。读当前生效的登记表;一轮搜索里的排序读它那一轮的(sourceSplitsParenBackground)。
func lyricSourceSplitsParenBackground(source string) bool {
	return lyricProviders().sourceSplitsParenBackground(source)
}

// sourceSplitsParenBackground:这份登记表里 source 的 ParenBackground。
func (r *lyricProviderRegistry) sourceSplitsParenBackground(source string) bool {
	d := r.descriptor(source)
	return d != nil && d.ParenBackground
}

// lyricSourceCarriesKana:source 的正文里会不会带 `[kana:]` 假名标注(描述符的 CarriesKana)。没登记的名字不会。
func lyricSourceCarriesKana(source string) bool {
	d := lyricProviders().descriptor(source)
	return d != nil && d.CarriesKana
}

// lyricSourcePlainTextOrder:没有带时间轴的候选、退到纯文本时 source 排在哪一档(描述符的 PlainText)。没登记的名字是
// plainTextNormal。
func lyricSourcePlainTextOrder(source string) PlainTextOrder {
	if d := lyricProviders().descriptor(source); d != nil {
		return d.PlainText
	}
	return plainTextNormal
}

// sourceTimelineHandTyped:source 的时间轴是不是上传者手打的(描述符的 HandTypedTimeline)。没登记的名字不是。
func (r *lyricProviderRegistry) sourceTimelineHandTyped(source string) bool {
	d := r.descriptor(source)
	return d != nil && d.HandTypedTimeline
}

// lyricSourceKindIs:name 这一路登记的是不是 kind 这一类。没登记的名字一律不是。播放器本机(providerKindPlayerLocal)和导入库
// (providerKindUserLibrary)是两类:前者是读播放器自己缓存、文件旁歌词的那几路,开搜时同步读好、只在用对应播放器时有;
// 导入库是用户自己的歌词,不跟着播放器走。读当前生效的登记表;一轮搜索里的排序读它那一轮的(sourceKindIs)。
func lyricSourceKindIs(name string, kind ProviderKind) bool {
	return lyricProviders().sourceKindIs(name, kind)
}

// sourceKindIs:这份登记表里 name 登记的是不是 kind 这一类。
func (r *lyricProviderRegistry) sourceKindIs(name string, kind ProviderKind) bool {
	d := r.descriptor(name)
	return d != nil && d.Kind == kind
}
