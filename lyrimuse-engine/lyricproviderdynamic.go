package main

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"sync"
	"unicode"
)

// 运行时登记的歌词来源(动态来源)。编在核心里的来源之外,引擎能在运行时把别的来源接进登记表:setDynamicLyricProviders
// 收一组实现,逐个过 admitDynamicLyricSource 的校验,都过了就连同内置来源另构造一份登记表,换成当前生效的。进行中的搜索
// 轮次用的是开搜时取的那一份,下一轮起用新的。现在没有生产调用方。见 09 章决策 401。
//
// 校验守的是四件事,规则代码见 dynamicSourceRule*:
//   - 动态来源拿不到特权:特权位、等别的源的编号、能看到别家结果的钩子、本机身份、ISRC 的记录权一律不许带;
//   - 不改内置来源:名字不能撞,名次一律由登记表重排到内置之后,纯文本回退不能排到最前,不能并进内置的信源家族、
//     同类组,主机归源表不收它的规则;
//   - 描述符是纯数据:函数字段一律不许带,登记表存的是校验过的副本,登记之后外面改不到;
//   - 通用代码对它成立:只能是联网源,轮次只有「都问」和「只在播放那一侧问」,要有 Assembly。
//
// 动态来源没有设置里的开关:登记着就是开着(lyricProviderRegistry.sourceEnabled),停用 = 从这一组里拿掉。

// ProviderOrigin:这个来源是编在核心里的,还是运行时登记的。
type ProviderOrigin int

const (
	originBuiltin ProviderOrigin = iota
	// originDynamic:运行时登记的。只由 admitDynamicLyricSource 写。
	originDynamic
)

// 动态来源没过校验的规则代码(dynamicSourceError.Rule)。
const (
	dynamicSourceRuleProvider          = "provider"           // 实现是 nil,或者交不出描述符
	dynamicSourceRuleName              = "name"               // 名字为空,或者带空白、控制字符
	dynamicSourceRuleNameBuiltin       = "name_builtin"       // 跟编在核心里的来源重名
	dynamicSourceRuleNameReserved      = "name_reserved"      // 下架的源名,或者顺序表里「播放器自带歌词」那一项
	dynamicSourceRuleNameDuplicate     = "name_duplicate"     // 这一组里重名
	dynamicSourceRuleKind              = "kind"               // 不是联网源
	dynamicSourceRulePrivileges        = "privileges"         // 带了特权位
	dynamicSourceRuleDependsOnIDs      = "depends_on_ids"     // 等别的源递曲目编号
	dynamicSourceRuleRounds            = "rounds"             // 轮次不是「都问」「只在播放那一侧问」
	dynamicSourceRulePriorityPlacement = "priority_placement" // 顺序优先里不是普通联网源的排法
	dynamicSourceRuleAssembly          = "assembly"           // 没有 Assembly
	dynamicSourceRuleBorrowFromPeers   = "borrow_from_peers"  // 带了能看到别家结果的钩子
	dynamicSourceRuleUnpack            = "unpack"             // 带了摊平专用子结构的钩子
	dynamicSourceRuleAcceptTranslation = "accept_translation" // 带了另一条收译文的判据
	dynamicSourceRuleLocalIdentity     = "local_identity"     // 候选要读「身份由播放器本机数据给定」
	dynamicSourceRuleTranslation       = "translation"        // 译文语言标法自相矛盾
	dynamicSourceRuleBaked             = "baked"              // 烘入译文要用自带的摘法
	dynamicSourceRulePageURL           = "page_url"           // 带了核对来源链接的函数
	dynamicSourceRulePlainText         = "plain_text"         // 纯文本回退要排在最前
	dynamicSourceRuleConsensusFamily   = "consensus_family"   // 要并进某个信源家族
	dynamicSourceRuleISRC              = "isrc"               // 要参加按 ISRC 补取,或者要它报的 ISRC 被记下来
	dynamicSourceRulePeerGroup         = "peer_group"         // 要进近况统计的同类组
	dynamicSourceRuleProbe             = "probe"              // 探测曲不完整,或者实现不会探
	dynamicSourceRuleHosts             = "hosts"              // 带了主机归源规则、主机令牌桶参数
	dynamicSourceRuleLimits            = "limits"             // 在途上限、额度是负数
)

// dynamicSourceError:一个运行时登记的来源没过校验。
type dynamicSourceError struct {
	// Source:这个来源自报的名字(可能是空的)。
	Source string
	// Rule:没过的那一条,dynamicSourceRule* 之一。
	Rule string
	// Detail:给人看的说明。
	Detail string
}

func (e *dynamicSourceError) Error() string {
	return fmt.Sprintf("lyric source %q rejected (%s): %s", e.Source, e.Rule, e.Detail)
}

// dynamicLyricSource 是登记表里的一个动态来源:描述符是登记时校验过、分好名次的副本,Resolve 转给登记进来的实现。
// 可选接口只转 QueryIndependentFailer、FailureDiagnoser、OwnProbeProvider 这三个;登记进来的实现另外实现了什么
// (OfflineResolver、PreSearchNoVocalsHinter、ISRCIndexProvider……),经这一层都问不到。
type dynamicLyricSource struct {
	desc  *ProviderDescriptor
	inner LyricProvider
}

func (s *dynamicLyricSource) Descriptor() *ProviderDescriptor { return s.desc }

func (s *dynamicLyricSource) Resolve(ctx context.Context, q ProviderQuery, env RoundEnv) SourceResult {
	return s.inner.Resolve(ctx, q, env)
}

// QueryIndependentFailure:登记进来的实现没实现 QueryIndependentFailer 时为空(补查轮照常问它)。
func (s *dynamicLyricSource) QueryIndependentFailure() string {
	if f, ok := s.inner.(QueryIndependentFailer); ok {
		return f.QueryIndependentFailure()
	}
	return ""
}

// DiagnosedFailure:登记进来的实现没实现 FailureDiagnoser 时为空(只有传输层的通用原因)。
func (s *dynamicLyricSource) DiagnosedFailure() string {
	if f, ok := s.inner.(FailureDiagnoser); ok {
		return f.DiagnosedFailure()
	}
	return ""
}

// ProbeOwnTrack:描述符带 Probe 的才会被问到,登记时已经核过实现会探。
func (s *dynamicLyricSource) ProbeOwnTrack(ctx context.Context) bool {
	p, ok := s.inner.(OwnProbeProvider)
	return ok && p.ProbeOwnTrack(ctx)
}

// lyricRegistrySwapMu:换当前生效的登记表的几步(校验、构造、换上)串着做。
var lyricRegistrySwapMu sync.Mutex

// setDynamicLyricProviders 把运行时登记的来源整组换成 providers(空 = 一个都不留),先后照 providers。有一个没过校验就
// 整组不换,返回 *dynamicSourceError,当前生效的登记表原样不动。可以并发调。
func setDynamicLyricProviders(providers []LyricProvider) error {
	lyricRegistrySwapMu.Lock()
	defer lyricRegistrySwapMu.Unlock()
	builtin := builtinLyricRegistry()
	if len(providers) == 0 {
		lyricRegistryCurrent.Store(builtin)
		return nil
	}
	all := slices.Clone(builtin.providers)
	ranks := dynamicRanksAfter(builtin)
	seen := map[string]bool{}
	for _, p := range providers {
		source, err := admitDynamicLyricSource(builtin, p, &ranks)
		if err != nil {
			return err
		}
		if seen[source.desc.Name] {
			return &dynamicSourceError{source.desc.Name, dynamicSourceRuleNameDuplicate, "registered twice in one set"}
		}
		seen[source.desc.Name] = true
		all = append(all, source)
	}
	lyricRegistryCurrent.Store(newLyricProviderRegistry(all))
	return nil
}

// dynamicRanks:下一个动态来源拿到的各类名次。
type dynamicRanks struct {
	order, tie, defaultPriority, instrumental, songwriters int
}

// dynamicRanksAfter:排在 builtin 里各类名次最大的那个之后的第一个名次。
func dynamicRanksAfter(builtin *lyricProviderRegistry) dynamicRanks {
	var r dynamicRanks
	for _, d := range builtin.descriptors {
		r.order = max(r.order, d.Order)
		r.tie = max(r.tie, d.TieRank)
		r.defaultPriority = max(r.defaultPriority, d.DefaultPriorityRank)
		r.instrumental = max(r.instrumental, d.InstrumentalRank)
		r.songwriters = max(r.songwriters, d.SongwritersRank)
	}
	r.order, r.tie, r.defaultPriority, r.instrumental, r.songwriters = r.order+1, r.tie+1, r.defaultPriority+1, r.instrumental+1, r.songwriters+1
	return r
}

// admitDynamicLyricSource 校验一个运行时登记的来源,过了就交登记表里存的那一份:描述符是副本(外面那份之后怎么改都
// 影响不到),Origin 标成 originDynamic,名次从 next 里取、取完往后挪一个:源名单里的位置、同分决胜序、顺序优先的默认序
// 一律重排;纯音乐标记、词曲作者名单这两类登记的名次不是 0 才参加,同样重排。排出来都在内置来源之后。
func admitDynamicLyricSource(builtin *lyricProviderRegistry, p LyricProvider, next *dynamicRanks) (*dynamicLyricSource, error) {
	var given *ProviderDescriptor
	if p != nil {
		given = p.Descriptor()
	}
	if given == nil {
		return nil, &dynamicSourceError{"", dynamicSourceRuleProvider, "nil provider or nil descriptor"}
	}
	d := *given
	reject := func(rule, detail string) (*dynamicLyricSource, error) {
		return nil, &dynamicSourceError{d.Name, rule, detail}
	}
	switch {
	case d.Name == "" || strings.ContainsFunc(d.Name, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }):
		return reject(dynamicSourceRuleName, "name must be non-empty without whitespace or control characters")
	case builtin.descriptor(d.Name) != nil:
		return reject(dynamicSourceRuleNameBuiltin, "name belongs to a built-in source")
	case isRetiredLyricSource(d.Name) || d.Name == lyricsPriorityPlayerLocal:
		return reject(dynamicSourceRuleNameReserved, "name is reserved")
	case d.Kind != providerKindNetwork:
		return reject(dynamicSourceRuleKind, "only network sources can be registered at run time")
	case d.Privileges != 0:
		return reject(dynamicSourceRulePrivileges, "privileges are for built-in sources only")
	case len(d.DependsOnIDsFrom) != 0:
		return reject(dynamicSourceRuleDependsOnIDs, "waiting for other sources' track ids needs a privilege")
	case d.Rounds != roundsAll && d.Rounds != roundsOnDemand:
		return reject(dynamicSourceRuleRounds, "rounds must be all or on-demand")
	case d.PriorityPlacement != priorityByUserOrder:
		return reject(dynamicSourceRulePriorityPlacement, "priority placement must be the ordinary one")
	case d.Assembly == nil:
		return reject(dynamicSourceRuleAssembly, "assembly is required")
	case d.Assembly.BorrowFromPeers != nil:
		return reject(dynamicSourceRuleBorrowFromPeers, "a hook that sees other sources' results is not allowed")
	case d.Assembly.Unpack != nil:
		return reject(dynamicSourceRuleUnpack, "results must be in the common fields")
	case d.Assembly.AcceptTranslation != nil:
		return reject(dynamicSourceRuleAcceptTranslation, "function hooks are not allowed")
	case d.Assembly.Reads.has(fieldLocalIdentity):
		return reject(dynamicSourceRuleLocalIdentity, "local client identity needs a privilege")
	case (d.Assembly.Translation == translationFixed) != (d.Assembly.TranslationLang != ""):
		return reject(dynamicSourceRuleTranslation, "a translation language goes with the fixed policy and only with it")
	case d.Baked == bakedCustom || d.BakedSplit != nil:
		return reject(dynamicSourceRuleBaked, "custom baked-translation splitting is not allowed")
	case d.PageURL != nil:
		return reject(dynamicSourceRulePageURL, "function hooks are not allowed")
	case d.PlainText == plainTextFirst:
		return reject(dynamicSourceRulePlainText, "cannot be the first choice for plain text")
	case d.ConsensusFamily != "":
		return reject(dynamicSourceRuleConsensusFamily, "cannot join a consensus family")
	case d.ISRCLookup != isrcLookupNone || d.ISRCAuthority:
		return reject(dynamicSourceRuleISRC, "ISRC lookup and ISRC authority are for built-in sources only")
	case d.PeerGroup != "":
		return reject(dynamicSourceRulePeerGroup, "cannot join a peer group")
	case len(d.Hosts) != 0 || len(d.HostRates) != 0:
		return reject(dynamicSourceRuleHosts, "host rules are for built-in sources only")
	case d.MaxInflight < 0 || d.HourlyBudget < 0 || d.DayQuotaReserve < 0:
		return reject(dynamicSourceRuleLimits, "limits cannot be negative")
	}
	if d.Probe != nil {
		if _, ok := p.(OwnProbeProvider); !ok || d.Probe.Artist == "" || d.Probe.Title == "" {
			return reject(dynamicSourceRuleProbe, "a probe track needs artist, title and a provider that can probe")
		}
		probe := *d.Probe
		d.Probe = &probe
	}
	assembly := *d.Assembly
	d.Assembly = &assembly
	d.Origin = originDynamic
	d.Order, d.TieRank, d.DefaultPriorityRank = next.order, next.tie, next.defaultPriority
	next.order, next.tie, next.defaultPriority = next.order+1, next.tie+1, next.defaultPriority+1
	if d.InstrumentalRank != 0 {
		d.InstrumentalRank = next.instrumental
		next.instrumental++
	}
	if d.SongwritersRank != 0 {
		d.SongwritersRank = next.songwriters
		next.songwriters++
	}
	return &dynamicLyricSource{desc: &d, inner: p}, nil
}
