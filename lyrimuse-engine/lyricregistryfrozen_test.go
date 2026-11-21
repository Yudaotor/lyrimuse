package main

import (
	"fmt"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

// 只有编在核心里的来源时,登记表算出来的每一份名单、调度对每个来源的处置,跟冻结在这里的逐项相同。登记表的构造方式、
// 换新方式怎么改,这一份都不该变;加减内置来源、改名次时照新的输出更新 builtinRegistryFrozen。

// renderRegistryLists:一份登记表算出来的全部名单,一行一份,map 按键排好。
func renderRegistryLists(r *lyricProviderRegistry) string {
	var b strings.Builder
	line := func(label string, names []string) { fmt.Fprintf(&b, "%s: %s\n", label, strings.Join(names, " ")) }
	var descriptors, providers []string
	for _, d := range r.descriptors {
		descriptors = append(descriptors, d.Name)
	}
	for _, p := range r.providers {
		providers = append(providers, p.Descriptor().Name)
	}
	line("descriptors", descriptors)
	line("providers", providers)
	line("network", r.networkNames)
	line("tie", r.tieOrder)
	line("defaultPriority", r.defaultPriorityOrder)
	line("instrumental", r.instrumentalOrder)
	line("songwriters", r.songwritersOrder)
	line("priorityPlayerLocal", r.priorityPlayerLocalNames)
	line("priorityFile", r.priorityFileNames)
	line("playerNoVocals", r.playerNoVocalsNames)
	sortedMapKeys := func(n int, each func(yield func(string))) []string {
		keys := make([]string, 0, n)
		each(func(k string) { keys = append(keys, k) })
		sort.Strings(keys)
		return keys
	}
	for _, g := range sortedMapKeys(len(r.peerGroups), func(yield func(string)) {
		for k := range r.peerGroups {
			yield(k)
		}
	}) {
		line("peerGroup "+g, r.peerGroups[g])
	}
	for _, h := range sortedMapKeys(len(r.hostRates), func(yield func(string)) {
		for k := range r.hostRates {
			yield(k)
		}
	}) {
		fmt.Fprintf(&b, "hostRate %s: %v\n", h, r.hostRates[h])
	}
	for _, h := range sortedMapKeys(len(r.hostOwners), func(yield func(string)) {
		for k := range r.hostOwners {
			yield(k)
		}
	}) {
		fmt.Fprintf(&b, "hostOwner %s: %s\n", h, r.hostOwners[h])
	}
	for _, h := range sortedMapKeys(len(r.domainOwners), func(yield func(string)) {
		for k := range r.domainOwners {
			yield(k)
		}
	}) {
		fmt.Fprintf(&b, "domainOwner %s: %s\n", h, r.domainOwners[h])
	}
	return b.String()
}

// renderRoundDecisions:调度在十六种轮次下对 r 里每个来源的处置(lyricRoundPlan.decide),一行一种轮次,一个来源一位数字
// (0 照常问、1 静默跳过、2 冷却跳过),先后照 r.providers。设置里全开;「只查这些源」取网易云、QQ;冷却取全部联网源。
func renderRoundDecisions(r *lyricProviderRegistry) string {
	cooling := lyricSourceRoundPlan{}
	for _, s := range r.networkNames {
		cooling[s] = time.Minute
	}
	var b strings.Builder
	for _, primary := range []bool{true, false} {
		for _, onDemand := range []bool{true, false} {
			for _, only := range []map[string]bool{nil, {lyricSourceNetease: true, lyricSourceQQ: true}} {
				for _, cool := range []lyricSourceRoundPlan{nil, cooling} {
					plan := lyricRoundPlan{only: only, onDemand: onDemand, primary: primary, cooling: cool,
						enabled: func(string) bool { return true }}
					fmt.Fprintf(&b, "primary=%v onDemand=%v only=%v cooling=%v: ", primary, onDemand, only != nil, cool != nil)
					for _, p := range r.providers {
						fmt.Fprintf(&b, "%d", plan.decide(p.Descriptor()))
					}
					b.WriteByte('\n')
				}
			}
		}
	}
	return b.String()
}

const builtinRegistryFrozen = `descriptors: netease qq kugou lrclib amll lyricfind kuwo migu deezer applemusic soda vibe genie petitlyrics zing megalobiz kkbox spotify amazon localfile lxmusic import
providers: netease qq kugou lrclib amll lyricfind kuwo migu deezer applemusic soda vibe genie petitlyrics zing megalobiz kkbox spotify amazon localfile lxmusic import
network: netease qq kugou lrclib amll lyricfind kuwo migu deezer applemusic soda vibe genie petitlyrics zing megalobiz
tie: netease qq kugou lrclib lyricfind kuwo migu deezer applemusic soda vibe genie petitlyrics zing megalobiz kkbox amazon lxmusic localfile import spotify amll
defaultPriority: kugou netease qq lrclib amll lyricfind kuwo migu deezer applemusic soda vibe genie petitlyrics zing megalobiz
instrumental: lrclib qq netease migu kugou
songwriters: applemusic amll deezer
priorityPlayerLocal: kkbox spotify amazon lxmusic
priorityFile: localfile
playerNoVocals: netease qq applemusic soda spotify
peerGroup chinese: netease qq kugou kuwo migu soda
peerGroup global: lrclib lyricfind deezer applemusic
hostRate api.megalobiz.com: {0.4 6 2}
hostRate lrclib.net: {1 6 3}
hostOwner amp-api-edge.music.apple.com: applemusic
hostOwner amp-api.music.apple.com: applemusic
hostOwner api.amll.dev: amll
hostOwner api.megalobiz.com: megalobiz
hostOwner api.music.apple.com: applemusic
hostOwner api.qishui.com: soda
hostOwner apis.naver.com: vibe
hostOwner app.genie.co.kr: genie
hostOwner beta-luna.douyin.com: soda
hostOwner cdn.jsdelivr.net: amll
hostOwner deezer.com: deezer
hostOwner dn.genie.co.kr: genie
hostOwner fastly.jsdelivr.net: amll
hostOwner kugou.com: kugou
hostOwner kuwo.cn: kuwo
hostOwner lrclib.net: lrclib
hostOwner migu.cn: migu
hostOwner music.youtube.com: lyricfind
hostOwner on.petitlyrics.com: petitlyrics
hostOwner p0.petitlyrics.com: petitlyrics
hostOwner p1.petitlyrics.com: petitlyrics
hostOwner qq.com: qq
hostOwner raw.githubusercontent.com: amll
hostOwner static-zmp3.zmdcdn.me: zing
hostOwner www.youtube.com: lyricfind
hostOwner youtubei.googleapis.com: lyricfind
hostOwner zingmp3.vn: zing
domainOwner 163.com: netease
domainOwner deezer.com: deezer
domainOwner kugou.com: kugou
domainOwner kuwo.cn: kuwo
domainOwner lrclib.net: lrclib
domainOwner migu.cn: migu
domainOwner qq.com: qq
primary=true onDemand=true only=false cooling=false: 0000000000000000000000
primary=true onDemand=true only=false cooling=true: 2222222222222222000000
primary=true onDemand=true only=true cooling=false: 0011111111111111000000
primary=true onDemand=true only=true cooling=true: 2211111111111111000000
primary=true onDemand=false only=false cooling=false: 0000000000000001000000
primary=true onDemand=false only=false cooling=true: 2222222222222221000000
primary=true onDemand=false only=true cooling=false: 0011111111111111000000
primary=true onDemand=false only=true cooling=true: 2211111111111111000000
primary=false onDemand=true only=false cooling=false: 0000000000000000111111
primary=false onDemand=true only=false cooling=true: 2222222222222222111111
primary=false onDemand=true only=true cooling=false: 0011111111111111111111
primary=false onDemand=true only=true cooling=true: 2211111111111111111111
primary=false onDemand=false only=false cooling=false: 0000000000000001111111
primary=false onDemand=false only=false cooling=true: 2222222222222221111111
primary=false onDemand=false only=true cooling=false: 0011111111111111111111
primary=false onDemand=false only=true cooling=true: 2211111111111111111111
enabledLyricSourceCount: 16
enabledNetworkLyricSources: netease qq kugou lrclib amll lyricfind kuwo migu deezer applemusic soda vibe genie petitlyrics zing megalobiz
`

func TestBuiltinRegistryMatchesFrozenLists(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = nil

	r := lyricProviders()
	got := renderRegistryLists(r) + renderRoundDecisions(r) +
		fmt.Sprintf("enabledLyricSourceCount: %d\nenabledNetworkLyricSources: %s\n",
			enabledLyricSourceCount(), strings.Join(enabledNetworkLyricSources(), " "))
	if got != builtinRegistryFrozen {
		t.Errorf("只有内置来源时登记表的名单、调度的处置跟冻结的不一样。\n得到:\n%s\n冻结:\n%s", got, builtinRegistryFrozen)
	}
	if n := len(strings.Fields(strings.SplitN(got, "\n", 2)[0])) - 1; n != len(lyricSourceNames)+len(localLyricSources) {
		t.Errorf("登记表里 %d 个来源,期望联网 %d + 本机类 %d", n, len(lyricSourceNames), len(localLyricSources))
	}
	// 另构造一份(同一条构造的路)逐项相同:名单只由那一组来源定,跟构造了几次、先后没有关系。
	if again := renderRegistryLists(newLyricProviderRegistry(builtinLyricProviderList())); again != renderRegistryLists(r) {
		t.Errorf("同一组内置来源再构造一份,名单不同:\n%s\n原来:\n%s", again, renderRegistryLists(r))
	}
	if !slices.Equal(r.networkNames, lyricSourceNames) {
		t.Errorf("联网源名单 %v\n期望表 %v", r.networkNames, lyricSourceNames)
	}
}

// useLyricRegistry:当前生效的登记表换成 r,测完换回去。
func useLyricRegistry(t *testing.T, r *lyricProviderRegistry) {
	t.Helper()
	prev := lyricProviders()
	lyricRegistryCurrent.Store(r)
	t.Cleanup(func() { lyricRegistryCurrent.Store(prev) })
}

// 登记表构造完不跟着传进来的那份名单变;当前生效的换成另一份时,先前取到的那一份(和读者手里拿着的切片)原样不动。
func TestRegistryIsImmutableOnceBuilt(t *testing.T) {
	providers := builtinLyricProviderList()
	r := newLyricProviderRegistry(providers)
	before := renderRegistryLists(r)
	providers[0], providers[1] = providers[1], providers[0]
	_ = append(providers[:2], providers[5:]...)
	if got := renderRegistryLists(r); got != before {
		t.Errorf("构造之后改传进来的那份名单,登记表跟着变了:\n%s\n原来:\n%s", got, before)
	}

	old := lyricProviders()
	oldLists := renderRegistryLists(old)
	held := map[string][]string{
		"networkNames": old.networkNames, "tieOrder": old.tieOrder, "defaultPriorityOrder": old.defaultPriorityOrder,
		"instrumentalOrder": old.instrumentalOrder, "songwritersOrder": old.songwritersOrder,
		"priorityPlayerLocalNames": old.priorityPlayerLocalNames, "priorityFileNames": old.priorityFileNames,
		"playerNoVocalsNames": old.playerNoVocalsNames,
	}
	copies := map[string][]string{}
	for label, names := range held {
		copies[label] = slices.Clone(names)
	}
	extra := &stubLyricProvider{desc: &ProviderDescriptor{
		Name: "stub-extra", Order: 17, TieRank: 23, DefaultPriorityRank: 17, InstrumentalRank: 6, SongwritersRank: 4,
		PeerGroup: peerGroupGlobal, Hosts: []HostRule{{"stub-extra.example", hostWithSubdomains}},
		HostRates: map[string]hostRate{"stub-extra.example": {perSec: 1, burst: 1}},
	}}
	next := newLyricProviderRegistry(append(builtinLyricProviderList(), extra))
	useLyricRegistry(t, next)
	if lyricProviders() != next {
		t.Fatal("换新之后 lyricProviders() 读到的不是新的那份")
	}
	for label, names := range map[string][]string{
		"networkNames": next.networkNames, "tieOrder": next.tieOrder, "defaultPriorityOrder": next.defaultPriorityOrder,
		"instrumentalOrder": next.instrumentalOrder, "songwritersOrder": next.songwritersOrder,
	} {
		if len(names) != len(held[label])+1 || names[len(names)-1] != "stub-extra" || !slices.Equal(names[:len(names)-1], copies[label]) {
			t.Errorf("新的那份 %s = %v,应是原来的 %v 后面多一个 stub-extra", label, names, copies[label])
		}
		if &names[0] == &held[label][0] {
			t.Errorf("新的那份 %s 跟原来那份共用底层数组", label)
		}
	}
	if next.sourceOwningHost("a.stub-extra.example") != "stub-extra" || old.sourceOwningHost("a.stub-extra.example") != "" {
		t.Error("主机归源:新的那份认 stub-extra 的主机,原来那份不认")
	}
	if _, ok := old.hostRates["stub-extra.example"]; ok || len(old.peerGroups[peerGroupGlobal])+1 != len(next.peerGroups[peerGroupGlobal]) {
		t.Error("原来那份的 hostRates / peerGroups 被新的那份改了")
	}
	if got := renderRegistryLists(old); got != oldLists {
		t.Errorf("换新之后,先前取到的那份登记表变了:\n%s\n原来:\n%s", got, oldLists)
	}
	for label, names := range held {
		if !slices.Equal(names, copies[label]) {
			t.Errorf("读者手里的 %s 被改了:%v,原来 %v", label, names, copies[label])
		}
	}
	if old.descriptor("stub-extra") != nil || old.provider("stub-extra") != nil || next.descriptor("stub-extra") != extra.desc || next.provider("stub-extra") != extra {
		t.Error("按名字查:新的那份查得到 stub-extra,原来那份查不到")
	}
}

// registryListFields:登记表里构造时算好、之后谁都不许动的字段。
var registryListFields = []string{
	"descriptors", "byName", "byProvider", "networkNames", "tieOrder", "defaultPriorityOrder", "instrumentalOrder", "songwritersOrder",
	"priorityPlayerLocalNames", "priorityFileNames", "playerNoVocalsNames", "peerGroups", "hostOwners", "domainOwners",
}

// 登记表只在构造时写:生产代码里给登记表的字段赋值、对它的名单 append / 排序的,只有 lyricprovider.go 里构造的那三个函数;
// 登记表只在 newLyricProviderRegistry 里造;当前生效的那份只在 registryStoreSites 列的地方换。
func TestRegistryIsWrittenOnlyWhileBuilding(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fields := strings.Join(registryListFields, "|")
	assign := regexp.MustCompile(`\b\w+\.(` + fields + `|hostRates)\b(\[[^\]\n]*\])?\s*(=[^=]|\+=|,[^=\n]*[^=!<>:]=[^=])`)
	inPlace := regexp.MustCompile(`\b(append|sort\.\w+|slices\.(Sort\w*|Reverse|Insert|Delete\w*))\(\w+(\(\))?\.(` + fields + `)\b`)
	builders := []string{"newLyricProviderRegistry", "index", "indexPeerGroups"}
	stores := map[string]int{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src := stripGoLineComments(string(mustRead(t, f)))
		if n := strings.Count(src, "lyricRegistryCurrent.Store("); n > 0 {
			stores[f] = n
		}
		if n := strings.Count(src, "&lyricProviderRegistry{"); n > 0 && f != "lyricprovider.go" {
			t.Errorf("%s 里自己造了登记表:只许经 newLyricProviderRegistry 造", f)
		}
		check := src
		if f == "lyricprovider.go" {
			if strings.Count(src, "&lyricProviderRegistry{") != 1 {
				t.Errorf("lyricprovider.go 里应恰好一处造登记表(newLyricProviderRegistry)")
			}
			for _, name := range builders {
				body := registryMethodSource(t, src, name)
				check = strings.Replace(check, body, "", 1)
			}
		}
		for _, m := range assign.FindAllString(check, -1) {
			t.Errorf("%s 里在构造之外给登记表的字段赋值:%q", f, m)
		}
		for _, m := range inPlace.FindAllString(check, -1) {
			t.Errorf("%s 里对登记表的名单就地 append / 排序:%q —— 要改先 slices.Clone", f, m)
		}
	}
	if !reflect.DeepEqual(stores, registryStoreSites) {
		t.Errorf("换当前生效的登记表的地方 %v,期望 %v", stores, registryStoreSites)
	}
}

// registryStoreSites:生产代码里换当前生效的登记表(lyricRegistryCurrent.Store)的地方,文件 → 几处。
var registryStoreSites = map[string]int{"lyricprovider.go": 1}

// stripGoLineComments:去掉整行和行尾的 `//` 注释(字符串里的 `//` 不管:这里扫的几种写法不会出现在字符串里)。
func stripGoLineComments(src string) string {
	lines := strings.Split(src, "\n")
	for i, l := range lines {
		if j := strings.Index(l, "//"); j >= 0 {
			lines[i] = l[:j]
		}
	}
	return strings.Join(lines, "\n")
}

// registryMethodSource:src 里登记表的方法或包级函数 name 的源码(到下一个顶层的 `}` 为止)。
func registryMethodSource(t *testing.T, src, name string) string {
	t.Helper()
	start := strings.Index(src, "\nfunc (r *lyricProviderRegistry) "+name+"(")
	if start < 0 {
		start = strings.Index(src, "\nfunc "+name+"(")
	}
	if start < 0 {
		t.Fatalf("lyricprovider.go 里找不到 %s", name)
	}
	end := strings.Index(src[start+1:], "\n}\n")
	if end < 0 {
		t.Fatalf("%s 没有收尾", name)
	}
	return src[start : start+1+end+3]
}
