package main

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

// 歌词源登记表(lyricprovider.go)的守卫。两种参照:生产代码只读登记表的那几类(名单、顺序),参照是冻结在
// lyricsourceexpect_test.go 里的期望表,登记表推出来的、生产代码读到的都要跟它逐项相等;还在用的按源名写的表,
// 都要能从描述符原样推出来。哪一条红了,先看是描述符填错了还是表改了没同步;推不出来的是描述符缺字段,补字段,
// 别改守卫去迁就。

func registryDescriptors() []*ProviderDescriptor { return lyricProviders().descriptors }

// registryNames:满足 keep 的描述符的源名,按 rank 给的名次从小到大。
func registryNames(keep func(*ProviderDescriptor) bool, rank func(*ProviderDescriptor) int) []string {
	var ds []*ProviderDescriptor
	for _, d := range registryDescriptors() {
		if keep(d) {
			ds = append(ds, d)
		}
	}
	sort.SliceStable(ds, func(i, j int) bool { return rank(ds[i]) < rank(ds[j]) })
	out := make([]string, 0, len(ds))
	for _, d := range ds {
		out = append(out, d.Name)
	}
	return out
}

func registryNetworkNames() []string {
	return registryNames(func(d *ProviderDescriptor) bool { return d.Kind == providerKindNetwork },
		func(d *ProviderDescriptor) int { return d.Order })
}

func registryNameSet(keep func(*ProviderDescriptor) bool) map[string]bool {
	out := map[string]bool{}
	for _, d := range registryDescriptors() {
		if keep(d) {
			out[d.Name] = true
		}
	}
	return out
}

func trueKeys(m map[string]bool) map[string]bool {
	out := map[string]bool{}
	for k, v := range m {
		if v {
			out[k] = true
		}
	}
	return out
}

// goFuncSource:file 里顶层函数 name 的源码(从 `func name(` 到下一个顶层声明之前)。
func goFuncSource(t *testing.T, file, name string) string {
	t.Helper()
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatalf("读不到 %s: %v", file, err)
	}
	s := string(raw)
	start := strings.Index(s, "\nfunc "+name+"(")
	if start < 0 {
		t.Fatalf("%s 里找不到 func %s", file, name)
	}
	end := strings.Index(s[start+1:], "\n}\n")
	if end < 0 {
		t.Fatalf("%s 里 func %s 没有收尾", file, name)
	}
	return s[start : start+1+end+3]
}

// lyricSourceConstNames:源常量的标识符 → 源名(features.go 的 lyricSourceXxx 加六路本机来源)。
func lyricSourceConstNames(t *testing.T) map[string]string {
	t.Helper()
	raw, err := os.ReadFile("features.go")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{
		"kkboxLocalLyricsSource":   kkboxLocalLyricsSource,
		"amazonLocalLyricsSource":  amazonLocalLyricsSource,
		"lxMusicLocalLyricsSource": lxMusicLocalLyricsSource,
		"localFileLyricsSource":    localFileLyricsSource,
		"spotifyLocalLyricsSource": spotifyLocalLyricsSource,
		"importLyricsSource":       importLyricsSource,
	}
	for _, m := range regexp.MustCompile(`(?m)^\s*(lyricSource[A-Z]\w*)\s*=\s*"(\w+)"`).FindAllStringSubmatch(string(raw), -1) {
		out[m[1]] = m[2]
	}
	return out
}

// funcName:包级函数 f 的名字,不带包路径。
func funcName(f any) string {
	full := runtime.FuncForPC(reflect.ValueOf(f).Pointer()).Name()
	return full[strings.LastIndex(full, ".")+1:]
}

func TestProviderRegistryIsWellFormed(t *testing.T) {
	ds := registryDescriptors()
	if len(lyricProviders().byName) != len(ds) {
		t.Fatalf("登记表里有重名的源:%d 份描述符、%d 个名字", len(ds), len(lyricProviders().byName))
	}
	var ties, orders, priorities []int
	for _, d := range ds {
		if lyricProviders().descriptor(d.Name) != d {
			t.Errorf("%s:按名字查回来的不是它自己", d.Name)
		}
		ties = append(ties, d.TieRank)
		if d.Kind == providerKindNetwork {
			orders, priorities = append(orders, d.Order), append(priorities, d.DefaultPriorityRank)
			if d.Rounds == roundsPrimaryOnly {
				t.Errorf("%s 是联网源,别名轮、反查轮照样要问它,不该只在首轮问", d.Name)
			}
			continue
		}
		if d.Order != 0 || d.DefaultPriorityRank != 0 || len(d.Hosts) != 0 || d.Rounds != roundsPrimaryOnly {
			t.Errorf("%s 是本机来源,不该有联网源才有的名次、主机,轮次只能是「只在首轮问」", d.Name)
		}
		// 本机类源由调度同步问:不能等别的源递编号(会把收集循环挂住),也没有熔断冷却那条腿。
		if d.Privileges.has(privTrackIDPublish|privTrackIDConsume|privOfflineLeg) || len(d.DependsOnIDsFrom) != 0 {
			t.Errorf("%s 是本机来源,不该递 / 等曲目编号,也没有冷却时的本机那条腿", d.Name)
		}
	}
	for label, got := range map[string][]int{"TieRank": ties, "Order": orders, "DefaultPriorityRank": priorities} {
		sort.Ints(got)
		for i, v := range got {
			if v != i+1 {
				t.Errorf("%s 应是从 1 起连续不重复的名次,得到 %v", label, got)
				break
			}
		}
	}
	if lyricProviders().descriptor("nope") != nil {
		t.Error("没登记的名字应查不到")
	}
}

// 源名单、全集兜底、源常量:都等于登记表里的联网源按 Order 排出来的名单;生产代码读到的那一份也是。
func TestProviderRegistryNamesMatchSourceList(t *testing.T) {
	got := registryNetworkNames()
	if !slices.Equal(got, lyricSourceNames) {
		t.Errorf("登记表 %v\nlyricSourceNames %v", got, lyricSourceNames)
	}
	if read := networkLyricSourceNames(); !slices.Equal(read, lyricSourceNames) {
		t.Errorf("networkLyricSourceNames %v\n期望表 %v", read, lyricSourceNames)
	}
	for _, d := range registryDescriptors() {
		if got, want := isNetworkLyricSource(d.Name), slices.Contains(lyricSourceNames, d.Name); got != want {
			t.Errorf("%s:isNetworkLyricSource=%v,在不在期望表里=%v", d.Name, got, want)
		}
	}
	if isNetworkLyricSource("nope") || isNetworkLyricSource("") {
		t.Error("没登记的名字不是联网源")
	}
	consts := allLyricSourceConstants()
	sort.Strings(consts)
	sortedGot := slices.Clone(got)
	sort.Strings(sortedGot)
	if !slices.Equal(sortedGot, consts) {
		t.Errorf("登记表 %v\n源常量 %v", sortedGot, consts)
	}
	if full := sortedKeys(trueKeys(resolveLyricsSources(nil))); !slices.Equal(full, sortedGot) {
		t.Errorf("登记表 %v\nresolveLyricsSources 的全集兜底 %v", sortedGot, full)
	}
	for _, d := range registryDescriptors() {
		known := len(resolveLyricsSources([]string{d.Name, "nope"})) == 1
		if known != (d.Kind == providerKindNetwork) {
			t.Errorf("%s:resolveLyricsSources 认不认它(%v)跟 Kind 对不上", d.Name, known)
		}
	}
}

func TestProviderRegistryTieRankMatchesTieOrder(t *testing.T) {
	got := registryNames(func(*ProviderDescriptor) bool { return true }, func(d *ProviderDescriptor) int { return d.TieRank })
	if !slices.Equal(got, lyricCandidateTieOrder) {
		t.Errorf("登记表 %v\nlyricCandidateTieOrder %v", got, lyricCandidateTieOrder)
	}
	if read := lyricProviders().tieOrder; !slices.Equal(read, lyricCandidateTieOrder) {
		t.Errorf("生产代码读的决胜序 %v\n期望表 %v", read, lyricCandidateTieOrder)
	}
}

func TestProviderRegistryDefaultPriorityMatchesDefaultOrder(t *testing.T) {
	got := registryNames(func(d *ProviderDescriptor) bool { return d.Kind == providerKindNetwork },
		func(d *ProviderDescriptor) int { return d.DefaultPriorityRank })
	if !slices.Equal(got, lyricsSourceDefaultOrder) {
		t.Errorf("登记表 %v\nlyricsSourceDefaultOrder %v", got, lyricsSourceDefaultOrder)
	}
	if read := lyricProviders().defaultPriorityOrder; !slices.Equal(read, lyricsSourceDefaultOrder) {
		t.Errorf("生产代码读的默认顺序 %v\n期望表 %v", read, lyricsSourceDefaultOrder)
	}
	if got, want := resolveLyricsSourceOrder(nil), append(slices.Clone(lyricsSourceDefaultOrder), lyricsPriorityPlayerLocal); !slices.Equal(got, want) {
		t.Errorf("没排过顺序时 %v\n期望 %v", got, want)
	}
}

// 本机来源:期望表 isPlayerLocalLyricSource 认的是 Kind 为 playerLocal 的那几路,导入库单算一类;两类都没有设置开关。
// 生产代码按 Kind 读(lyricSourceKindIs),跟期望表逐个相等。
func TestProviderRegistryKindMatchesLocalSources(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	// 只开一个不存在的源:联网源全部算关着,本机来源照样算开着。
	featuresRef().LyricsSources = map[string]bool{"nope": true}
	for _, d := range registryDescriptors() {
		if got := isPlayerLocalLyricSource(d.Name); got != (d.Kind == providerKindPlayerLocal) {
			t.Errorf("%s:isPlayerLocalLyricSource=%v,Kind=%v", d.Name, got, d.Kind)
		}
		if got := d.Name == importLyricsSource; got != (d.Kind == providerKindUserLibrary) {
			t.Errorf("%s:是不是导入库(%v)跟 Kind=%v 对不上", d.Name, got, d.Kind)
		}
		if got := lyricSourceEnabled(d.Name); got != (d.Kind != providerKindNetwork) {
			t.Errorf("%s:联网源都关着时 lyricSourceEnabled=%v,Kind=%v", d.Name, got, d.Kind)
		}
		if got, want := lyricSourceKindIs(d.Name, providerKindPlayerLocal), isPlayerLocalLyricSource(d.Name); got != want {
			t.Errorf("%s:生产代码读到是不是播放器本机=%v,期望表=%v", d.Name, got, want)
		}
		if got, want := lyricSourceKindIs(d.Name, providerKindUserLibrary), d.Name == importLyricsSource; got != want {
			t.Errorf("%s:生产代码读到是不是导入库=%v,期望=%v", d.Name, got, want)
		}
		if got, want := lyricSourceEnabled(d.Name), isPlayerLocalLyricSource(d.Name) || d.Name == importLyricsSource; got != want {
			t.Errorf("%s:联网源都关着时 lyricSourceEnabled=%v,期望(播放器本机或导入库)=%v", d.Name, got, want)
		}
	}
	for _, kind := range []ProviderKind{providerKindNetwork, providerKindPlayerLocal, providerKindUserLibrary} {
		if lyricSourceKindIs("nope", kind) || lyricSourceKindIs("", kind) {
			t.Errorf("没登记的名字不属于任何一类(%v)", kind)
		}
	}
	if lyricSourceEnabled("unregistered") {
		t.Error("没登记的名字按联网源的开关算:只开着别的源时它是关的")
	}
}

func TestProviderRegistryRoundsMatchOnDemandOnly(t *testing.T) {
	got := registryNameSet(func(d *ProviderDescriptor) bool { return d.Rounds == roundsOnDemand })
	if want := trueKeys(lyricSourceOnDemandOnly); !reflect.DeepEqual(got, want) {
		t.Errorf("登记表 %v\nlyricSourceOnDemandOnly %v", sortedKeys(got), sortedKeys(want))
	}
	if len(got) == 0 {
		t.Error("没有一个源只在播放那一侧问,这条守卫什么都没比")
	}
	batch, playing := context.Background(), withOnDemandLyricRound(context.Background())
	for _, name := range append(sortedKeys(registryNameSet(func(*ProviderDescriptor) bool { return true })), "nope") {
		want := lyricSourceOnDemandOnly[name]
		if read := onDemandOnlyLyricSource(name); read != want {
			t.Errorf("%s:生产代码读到只在播放那一侧问=%v,期望表=%v", name, read, want)
		}
		if lyricSourceAllowedForRound(batch, name) != !want || !lyricSourceAllowedForRound(playing, name) {
			t.Errorf("%s:批量轮次问不问、播放轮次问不问跟期望表(%v)对不上", name, want)
		}
	}
}

// registrySourceForHost:小写、去空白、去端口之后按描述符的主机规则逐条扫着归源(不经登记表的查表结构);
// 第二个返回值是命中了几个源。
func registrySourceForHost(host string) (string, int) {
	h := strings.ToLower(strings.TrimSpace(host))
	if i := strings.LastIndex(h, ":"); i >= 0 {
		h = h[:i]
	}
	source, n := "", 0
	for _, d := range registryDescriptors() {
		if slices.ContainsFunc(d.Hosts, func(r HostRule) bool { return r.matches(h) }) {
			source, n = d.Name, n+1
		}
	}
	return source, n
}

// hostAttributionSamples:主机归源的样本。期望表那个旧函数体里写到的每个主机字面量、每条主机规则的主机、各源实际
// 请求的主机、不是歌词源的主机和歌词源域名下不该卷进来的那几个,各自再变出子域、父域、粘连前缀、端口、大写带空白、
// 首尾带点几种写法;另加一批写坏的。
func hostAttributionSamples(t *testing.T) (bases map[string]bool, probes []string) {
	t.Helper()
	bases = map[string]bool{
		// 不是歌词源的主机,以及歌词源域名下不该卷进来的那几个。
		"itunes.apple.com": true, "music.apple.com": true, "mvod.itunes.apple.com": true, "is1-ssl.mzstatic.com": true,
		"ws.audioscrobbler.com": true, "musicbrainz.org": true, "douyin.com": true, "music.douyin.com": true,
		"megalobiz.com": true, "www.megalobiz.com": true, "youtube.com": true, "naver.com": true, "github.com": true,
		"petitlyrics.com": true, "genie.co.kr": true, "zmdcdn.me": true, "photo-zmp3.zmdcdn.me": true, "com": true,
		"api.listenbrainz.org": true, "1.1.1.1": true, "notqq.com": true, "evil-163.com": true, "example.com": true,
		"localhost": true, "np.yudaotor.me": true, "image.genie.co.kr": true, "musicmeta-phinf.pstatic.net": true,
		// 各源实际请求的主机(sourcecoverage_test.go、sourcebreaker_test.go、sourcefallback_test.go 里的样本)。
		"c.y.qq.com": true, "u.y.qq.com": true, "shu.y.qq.com": true, "mobilecdn.kugou.com": true, "lyrics.kugou.com": true,
		"krcs.kugou.com": true, "ioscdn.kugou.com": true, "search.kuwo.cn": true, "www.kuwo.cn": true,
		"pd.musicapp.migu.cn": true, "d.musicapp.migu.cn": true, "c.musicapp.migu.cn": true, "api.deezer.com": true,
		"pipe.deezer.com": true, "auth.deezer.com": true, "www.deezer.com": true, "interface3.music.163.com": true,
		"api.qishui.com": true,
	}
	// 期望表这一侧:lyricSourceForHost 函数体里写到的每个主机字面量。
	body := goFuncSource(t, "lyricsourceexpect_test.go", "lyricSourceForHost")
	literals := regexp.MustCompile(`"\.?([a-z0-9][a-z0-9.-]*\.[a-z]{2,})"`).FindAllStringSubmatch(body, -1)
	if len(literals) < 30 {
		t.Fatalf("lyricSourceForHost 里只扫到 %d 个主机字面量,扫描式跟不上源码了", len(literals))
	}
	for _, m := range literals {
		bases[m[1]] = true
	}
	// 描述符这一侧:每条主机规则。
	for _, d := range registryDescriptors() {
		for _, r := range d.Hosts {
			bases[r.Host] = true
		}
	}
	for _, base := range sortedKeys(bases) {
		probes = append(probes, base, "x."+base, "x.y."+base, "x"+base, base+":443", " "+strings.ToUpper(base)+" ", "."+base, base+".")
		if _, parent, ok := strings.Cut(base, "."); ok {
			probes = append(probes, parent)
		}
	}
	return bases, append(probes, "", " ", ":", ".", "lrclib.net:", "lrclib.net:443:1", "[::1]:80", "::1", "a..qq.com", "qq.com:x", "net", "cn")
}

func TestProviderRegistryHostsMatchSourceForHost(t *testing.T) {
	for _, d := range registryDescriptors() {
		if d.Kind == providerKindNetwork && len(d.Hosts) == 0 {
			t.Errorf("%s 没有登记主机", d.Name)
		}
	}
	bases, probes := hostAttributionSamples(t)
	owned := map[string]bool{}
	for _, probe := range probes {
		want := lyricSourceForHost(probe)
		got, n := registrySourceForHost(probe)
		if n > 1 {
			t.Errorf("%q 被 %d 个源的主机规则同时命中", probe, n)
		}
		// 写坏的那几个(多个冒号)这个辅助函数的去端口跟生产代码不是一个写法,只比生产代码那一侧。
		if strings.Count(probe, ":") <= 1 && got != want {
			t.Errorf("%q:描述符的规则归到 %q,期望表归到 %q", probe, got, want)
		}
		if read := lyricSourceOwningHost(probe); read != want {
			t.Errorf("%q:生产代码归到 %q,期望表归到 %q", probe, read, want)
		}
		if want != "" {
			owned[want] = true
		}
	}
	for name := range registryNameSet(func(d *ProviderDescriptor) bool { return d.Kind == providerKindNetwork }) {
		if !owned[name] {
			t.Errorf("样本里没有一个主机归到联网源 %s", name)
		}
	}
	t.Logf("主机归源:%d 个主机、%d 个样本,描述符的规则、生产代码读到的、期望表三方相等;归到 %d 个源", len(bases), len(probes), len(owned))
}

// 查表结构跟逐条规则扫的结果相等:只认这一个主机、连子域、只认子域三种范围各一条,加一个什么都不认的。
func TestHostOwnerIndexMatchesRuleScan(t *testing.T) {
	r := &lyricProviderRegistry{byName: map[string]*ProviderDescriptor{}, byProvider: map[string]LyricProvider{}}
	r.registerBuiltin(&ProviderDescriptor{Name: "exact", Hosts: []HostRule{{"api.one.example", hostExact}, {"one.example", hostExact}}}, 0)
	r.registerBuiltin(&ProviderDescriptor{Name: "with-sub", Hosts: []HostRule{{"two.example", hostWithSubdomains}}}, 0)
	r.registerBuiltin(&ProviderDescriptor{Name: "sub-only", Hosts: []HostRule{{"three.example", hostSubdomainsOnly}, {"cdn.four.example", hostSubdomainsOnly}}}, 0)
	r.registerBuiltin(&ProviderDescriptor{Name: "no-hosts"}, 0)
	r.index()
	scan := func(host string) string {
		for _, d := range r.descriptors {
			if slices.ContainsFunc(d.Hosts, func(rule HostRule) bool { return rule.matches(host) }) {
				return d.Name
			}
		}
		return ""
	}
	want := map[string]string{
		"api.one.example": "exact", "one.example": "exact", "x.one.example": "", "x.api.one.example": "",
		"two.example": "with-sub", "a.two.example": "with-sub", "a.b.two.example": "with-sub", "xtwo.example": "",
		"three.example": "", "a.three.example": "sub-only", "a.b.three.example": "sub-only", "xthree.example": "",
		"cdn.four.example": "", "a.cdn.four.example": "sub-only", "four.example": "", "b.four.example": "",
		"example": "", "": "", ".": "", ".two.example": "with-sub", "two.example.": "", "a..three.example": "sub-only",
	}
	for host, source := range want {
		if got := r.sourceOwningHost(host); got != source {
			t.Errorf("%q:查表归到 %q,期望 %q", host, got, source)
		}
		if got := scan(host); got != source {
			t.Errorf("%q:逐条规则扫归到 %q,期望 %q", host, got, source)
		}
	}
}

func TestProviderRegistryHostRatesMatchHostRateFor(t *testing.T) {
	listed := map[string]bool{}
	probes := map[string]bool{"example.com": true, "": true}
	for _, d := range registryDescriptors() {
		for host, rate := range d.HostRates {
			listed[host] = true
			if want := expectedHostRateFor(host); want != rate {
				t.Errorf("%s 的 %s:登记表 %+v,期望表 %+v", d.Name, host, rate, want)
			}
			if got, _ := registrySourceForHost(host); got != d.Name {
				t.Errorf("%s 给 %s 定了速率,但这个主机归 %q", d.Name, host, got)
			}
		}
		for _, r := range d.Hosts {
			probes[r.Host] = true
			if _, ok := d.HostRates[r.Host]; !ok && expectedHostRateFor(r.Host) != hostRateDefault {
				t.Errorf("%s 的 %s 在期望表里单独定了速率,描述符没写", d.Name, r.Host)
			}
		}
	}
	// 反过来:期望表里单列的主机,是歌词源的都得在描述符里。
	caseRE := regexp.MustCompile(`case "([^"]+)":`)
	cases := caseRE.FindAllStringSubmatch(goFuncSource(t, "lyricsourceexpect_test.go", "expectedHostRateFor"), -1)
	if len(cases) < 4 {
		t.Fatalf("期望表里只扫到 %d 个 case,扫描式跟不上源码了", len(cases))
	}
	for _, m := range cases {
		probes[m[1]] = true
		if lyricSourceForHost(m[1]) != "" && !listed[m[1]] {
			t.Errorf("期望表给歌词源主机 %s 单独定了速率,描述符没写", m[1])
		}
	}
	// 生产代码读到的 == 期望表:每条主机规则的主机、期望表里单列的主机,各自再探子域和父域(速率只对列出的那一个主机生效)。
	for base := range probes {
		for _, host := range []string{base, "x." + base, strings.TrimPrefix(base, "api.")} {
			if got, want := hostRateFor(host), expectedHostRateFor(host); got != want {
				t.Errorf("%q:生产代码读到 %+v,期望表 %+v", host, got, want)
			}
		}
	}
	// hostRateFor 自己只写不是歌词源的主机,歌词源的速率只有描述符一个来源。
	own := caseRE.FindAllStringSubmatch(goFuncSource(t, "hostguard.go", "hostRateFor"), -1)
	if len(own) < 2 {
		t.Fatalf("hostRateFor 里只扫到 %d 个 case,扫描式跟不上源码了", len(own))
	}
	for _, m := range own {
		if source := lyricSourceForHost(m[1]); source != "" {
			t.Errorf("hostRateFor 里写着歌词源 %s 的主机 %s,它的速率该写在描述符的 HostRates", source, m[1])
		}
	}
	if !containsCode(string(mustRead(t, "hostguard.go")), "var newHostGuardRateFor = hostRateFor") {
		t.Error("出站闸默认的速率表不是 hostRateFor")
	}
}

func TestProviderRegistryInflightCapsMatch(t *testing.T) {
	got := map[string]int{}
	for _, d := range registryDescriptors() {
		if d.MaxInflight != 0 {
			got[d.Name] = d.MaxInflight
		}
	}
	if !reflect.DeepEqual(got, lyricSourceInflightCaps) {
		t.Errorf("登记表 %v\nlyricSourceInflightCaps %v", got, lyricSourceInflightCaps)
	}
	for _, name := range append(sortedKeys(registryNameSet(func(*ProviderDescriptor) bool { return true })), "nope", "") {
		want := lyricSourceInflightCaps[name]
		if want == 0 {
			want = lyricSourceInflightDefault
		}
		if read := lyricSourceMaxInflight(name); read != want {
			t.Errorf("%q:生产代码读到在途上限 %d,期望表 %d", name, read, want)
		}
	}
}

func TestProviderRegistryBudgetsMatch(t *testing.T) {
	limited := 0
	for _, d := range registryDescriptors() {
		if got := lyricSourceHourlyBudget(d.Name); got != d.HourlyBudget {
			t.Errorf("%s 的小时额度:登记表 %d,lyricSourceHourlyBudget %d", d.Name, d.HourlyBudget, got)
		}
		if got := lyricSourceDayQuotaReserve(d.Name); got != d.DayQuotaReserve {
			t.Errorf("%s 的每日额度留量:登记表 %d,lyricSourceDayQuotaReserve %d", d.Name, d.DayQuotaReserve, got)
		}
		if d.HourlyBudget != 0 || d.DayQuotaReserve != 0 {
			limited++
		}
	}
	if limited == 0 {
		t.Error("没有一个源带额度,这条守卫什么都没比")
	}
	for _, name := range append(sortedKeys(registryNameSet(func(*ProviderDescriptor) bool { return true })), "nope", "") {
		if read, want := lyricSourceBudgetPerHour(name), lyricSourceHourlyBudget(name); read != want {
			t.Errorf("%q:生产代码读到小时额度 %d,期望表 %d", name, read, want)
		}
		if read, want := lyricSourceDayReserve(name), lyricSourceDayQuotaReserve(name); read != want {
			t.Errorf("%q:生产代码读到每日额度留量 %d,期望表 %d", name, read, want)
		}
	}
	if megalobizHourlyBudget != megalobizExpectedHourlyBudget || megalobizDayQuotaReserve != megalobizExpectedDayQuotaReserve {
		t.Errorf("Megalobiz 的小时额度 %d、每日额度留量 %d,期望 %d、%d", megalobizHourlyBudget, megalobizDayQuotaReserve,
			megalobizExpectedHourlyBudget, megalobizExpectedDayQuotaReserve)
	}
	if !containsCode(string(mustRead(t, "sourcebudget.go")), "var newHostGuardSourceBudget = lyricSourceBudgetPerHour") {
		t.Error("出站闸默认的小时额度不是读描述符的 lyricSourceBudgetPerHour")
	}
}

func TestProviderRegistryProxyFallbackMatches(t *testing.T) {
	got := registryNameSet(func(d *ProviderDescriptor) bool { return d.ProxyFallback })
	if want := trueKeys(lyricSourceProxyFallbackSources); !reflect.DeepEqual(got, want) {
		t.Errorf("登记表 %v\nlyricSourceProxyFallbackSources %v", sortedKeys(got), sortedKeys(want))
	}
	for _, name := range append(sortedKeys(registryNameSet(func(*ProviderDescriptor) bool { return true })), "nope", "") {
		if read, want := lyricSourceUsesProxyFallback(name), lyricSourceProxyFallbackSources[name]; read != want {
			t.Errorf("%q:生产代码读到走不走代理回退=%v,期望表=%v", name, read, want)
		}
	}
}

func TestProviderRegistryPeerGroupsMatch(t *testing.T) {
	var got [][]string
	index := map[string]int{}
	for _, name := range registryNetworkNames() {
		d := lyricProviders().descriptor(name)
		if d.PeerGroup == "" {
			continue
		}
		i, ok := index[d.PeerGroup]
		if !ok {
			i = len(got)
			index[d.PeerGroup] = i
			got = append(got, nil)
		}
		got[i] = append(got[i], name)
	}
	if !reflect.DeepEqual(got, lyricSourcePeerGroups) {
		t.Errorf("登记表 %v\nlyricSourcePeerGroups %v", got, lyricSourcePeerGroups)
	}
	for _, d := range registryDescriptors() {
		if d.Kind != providerKindNetwork && d.PeerGroup != "" {
			t.Errorf("%s 是本机来源,不进同类组", d.Name)
		}
		var want []string
		for _, g := range lyricSourcePeerGroups {
			if slices.Contains(g, d.Name) {
				want = g
			}
		}
		if read := lyricSourcePeerGroup(d.Name); !slices.Equal(read, want) || (read == nil) != (want == nil) {
			t.Errorf("%s:生产代码读到的同类组 %v,期望表 %v", d.Name, read, want)
		}
	}
	if lyricSourcePeerGroup("nope") != nil {
		t.Error("没登记的名字不在任何一组")
	}
}

// 专用探测曲:哪几个源有、各是哪一首,跟期望表逐项相等;有探测曲的源恰好是实现了 OwnProbeProvider 的那几个,
// 它们的 ProbeOwnTrack 拿描述符里那一首去问。
func TestProviderRegistryProbesMatchOwnProbes(t *testing.T) {
	got := map[string]ProbeTrack{}
	for _, d := range registryDescriptors() {
		if d.Probe != nil {
			got[d.Name] = *d.Probe
		}
	}
	if !reflect.DeepEqual(got, lyricSourceOwnProbeTracks) || len(got) == 0 {
		t.Fatalf("登记表 %v\n期望表 %v", got, lyricSourceOwnProbeTracks)
	}
	for _, d := range registryDescriptors() {
		_, implemented := lyricProviders().provider(d.Name).(OwnProbeProvider)
		if implemented != (d.Probe != nil) {
			t.Errorf("%s:实现了 OwnProbeProvider(%v)跟描述符有没有 Probe 对不上", d.Name, implemented)
		}
		if (ownLyricSourceProbe(d.Name) != nil) != (d.Probe != nil) {
			t.Errorf("%s:ownLyricSourceProbe 给不给探测跟描述符有没有 Probe 对不上", d.Name)
		}
		if d.Probe == nil {
			continue
		}
		raw, err := os.ReadFile(d.Name + ".go")
		if err != nil {
			t.Fatal(err)
		}
		body := string(raw)
		start := strings.Index(body, "Provider) ProbeOwnTrack(ctx context.Context) bool {")
		if start < 0 {
			t.Fatalf("%s.go 里找不到 ProbeOwnTrack", d.Name)
		}
		body = body[start:]
		body = body[:strings.Index(body, "\n}\n")]
		if !containsCode(body, "t := p.desc.Probe") || !containsCode(body, lyricSourceOwnProbeCalls[d.Name]) {
			t.Errorf("%s 的 ProbeOwnTrack 应拿描述符里的探测曲、照期望表里那一句去问(%s):\n%s", d.Name, lyricSourceOwnProbeCalls[d.Name], body)
		}
	}
	if ownLyricSourceProbe("nope") != nil {
		t.Error("没登记的名字没有专用探测")
	}
	// 两处消费面(healthcheck、设置页的「测试」)都经 ownLyricSourceProbe 找探测。
	for _, f := range []string{"healthcheckcli.go", "testlyricsourcescli.go"} {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if !containsCode(string(raw), "probe := ownLyricSourceProbe(src)\n\t\tif probe == nil {\n\t\t\tcontinue\n\t\t}") {
			t.Errorf("%s 里没有按源找专用探测的那一段", f)
		}
	}
}

// lyricSourceFailureProbes:各源失败原因的进程级旁路怎么读、怎么写(测试里拿它造出「这个源带着失败原因」)。
var lyricSourceFailureProbes = map[string]struct {
	get func() string
	set func(string)
}{
	lyricSourceNetease:    {neteaseLastFailureReasonNow, neteaseSetLastFailureReason},
	lyricSourceLyricFind:  {ytmusicLastFailureReasonNow, ytmusicSetLastFailureReason},
	lyricSourceDeezer:     {deezerLastFailureReasonNow, deezerSetLastFailureReason},
	lyricSourceAppleMusic: {applemusicLastFailureReasonNow, applemusicSetLastFailureReason},
	lyricSourceSoda:       {sodaLastFailureReasonNow, sodaSetLastFailureReason},
	lyricSourceZing:       {zingLastFailureReasonNow, zingSetLastFailureReason},
}

// clearLyricSourceFailuresForTest 把各源的失败原因和网易云的「成功过」标记清掉,测试结束时还原。
func clearLyricSourceFailuresForTest(t *testing.T) {
	t.Helper()
	savedSuccess := neteaseAnySuccess
	neteaseAnySuccess = false
	t.Cleanup(func() { neteaseAnySuccess = savedSuccess })
	for _, probe := range lyricSourceFailureProbes {
		saved := probe.get()
		probe.set("")
		t.Cleanup(func() { probe.set(saved) })
	}
}

// 补查轮(别名轮、ISRC 补取)里「有跟检索词无关的失败原因就不问」的那几个源:恰好是实现了 QueryIndependentFailer 的,
// 跟期望表逐个相等;各自答的是自己那条旁路上的原因,带着原因时补查轮名单里没有它、别的源不受影响。
func TestProviderRegistryQueryIndependentFailureMatchesRetryPlan(t *testing.T) {
	savedFeatures, savedBreaker := features(), sharedLyricSourceBreaker()
	t.Cleanup(func() { setFeatures(savedFeatures); setSharedLyricSourceBreaker(savedBreaker) })
	featuresRef().LyricsSources = nil
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	clearLyricSourceFailuresForTest(t)

	got := map[string]bool{}
	for _, d := range registryDescriptors() {
		if _, ok := lyricProviders().provider(d.Name).(QueryIndependentFailer); ok {
			got[d.Name] = true
		}
	}
	want := map[string]bool{}
	for _, s := range lyricSourceQueryIndependentFailers {
		want[s] = true
	}
	if !reflect.DeepEqual(got, want) || len(got) == 0 {
		t.Fatalf("实现了 QueryIndependentFailer 的源 %v\n期望表 %v", sortedKeys(got), sortedKeys(want))
	}
	if all := lyricSourcesWorthRetry(context.Background(), nil); !slices.Equal(all, lyricSourceNames) {
		t.Fatalf("用例前提:没有失败原因时补查轮问全部联网源,得到 %v", all)
	}
	// 每个源的失败原因单独置一次:只有期望表里的源从补查轮名单里消失,而且只消失它自己。
	for _, name := range lyricSourceNames {
		probe, has := lyricSourceFailureProbes[name]
		if !has {
			if want[name] {
				t.Fatalf("%s 在期望表里,lyricSourceFailureProbes 里没有它的旁路", name)
			}
			continue
		}
		const reason = "registry_guard_reason"
		probe.set(reason)
		if f, ok := lyricProviders().provider(name).(QueryIndependentFailer); ok && f.QueryIndependentFailure() != reason {
			t.Errorf("%s:QueryIndependentFailure 交的是 %q,不是它自己那条旁路上的原因", name, f.QueryIndependentFailure())
		}
		retry := lyricSourcesWorthRetry(context.Background(), nil)
		expect := slices.Clone(lyricSourceNames)
		if want[name] {
			expect = slices.DeleteFunc(expect, func(s string) bool { return s == name })
		}
		if !slices.Equal(retry, expect) {
			t.Errorf("%s 带着失败原因时补查轮名单 %v\n期望 %v", name, retry, expect)
		}
		probe.set("")
	}
}

// 设置页「测试」和手动搜索的「歌词源可用情况」显示专属失败原因的那几个源:恰好是实现了 FailureDiagnoser 的,跟期望表
// 逐个相等;各自答的是自己那条旁路上的原因。这一组跟上面补查轮那一组不是同一组源。
func TestProviderRegistryFailureDiagnosersMatchExpected(t *testing.T) {
	clearLyricSourceFailuresForTest(t)
	got := map[string]bool{}
	for _, d := range registryDescriptors() {
		if _, ok := lyricProviders().provider(d.Name).(FailureDiagnoser); ok {
			got[d.Name] = true
		}
	}
	want := map[string]bool{}
	for _, s := range lyricSourceFailureDiagnosers {
		want[s] = true
	}
	if !reflect.DeepEqual(got, want) || len(got) == 0 {
		t.Fatalf("实现了 FailureDiagnoser 的源 %v\n期望表 %v", sortedKeys(got), sortedKeys(want))
	}
	if slices.Equal(sortedKeys(want), sortedKeys(func() map[string]bool {
		m := map[string]bool{}
		for _, s := range lyricSourceQueryIndependentFailers {
			m[s] = true
		}
		return m
	}())) {
		t.Error("两组源相等了:确认是真的一样,还是两个接口被并成了一个")
	}
	on := func(string) bool { return true }
	if r := lyricSourceFailureReasonsWith(nil, nil, on, false); r != nil {
		t.Fatalf("用例前提:没有失败原因时不报,得到 %v", r)
	}
	for _, name := range lyricSourceNames {
		probe, has := lyricSourceFailureProbes[name]
		if !has {
			if want[name] {
				t.Fatalf("%s 在期望表里,lyricSourceFailureProbes 里没有它的旁路", name)
			}
			continue
		}
		const reason = "registry_guard_reason"
		probe.set(reason)
		reasons := lyricSourceFailureReasonsWith(nil, nil, on, false)
		expect := map[string]string(nil)
		if want[name] {
			expect = map[string]string{name: reason}
		}
		if !reflect.DeepEqual(reasons, expect) {
			t.Errorf("%s 带着失败原因时手动搜索报 %v,期望 %v", name, reasons, expect)
		}
		if d, ok := lyricProviders().provider(name).(FailureDiagnoser); ok && d.DiagnosedFailure() != reason {
			t.Errorf("%s:DiagnosedFailure 交的是 %q", name, d.DiagnosedFailure())
		}
		// 给过候选的源不报。
		if r := lyricSourceFailureReasonsWith([]scoredLyricCandidateResult{{Source: name, Score: -1}}, nil, on, false); r != nil {
			t.Errorf("%s 给过候选还报了原因 %v", name, r)
		}
		probe.set("")
	}
	// 网易云:这个进程里成功答过一次就不报限流。
	lyricSourceFailureProbes[lyricSourceNetease].set("registry_guard_reason")
	neteaseAnySuccess = true
	if r := lyricSourceFailureReasonsWith(nil, nil, on, false); r != nil {
		t.Errorf("网易云成功答过之后还报了原因 %v", r)
	}
	if d := lyricProviders().provider(lyricSourceNetease).(FailureDiagnoser).DiagnosedFailure(); d != "" {
		t.Errorf("网易云成功答过之后 DiagnosedFailure = %q", d)
	}
}

// 烘入译文怎么处理:描述符的 Baked / BakedSplit 等于迁移前 rankLyricSourceResults 里 bakedLines[…] 那八行的写法
// (扫参照 handwrittenRankLyricSourceResults 的函数体);生产的排序跟参照逐字段相等由 lyricrankparity_test.go 守。
func TestProviderRegistryBakedPolicyMatchesRanking(t *testing.T) {
	consts := lyricSourceConstNames(t)
	body := goFuncSource(t, "lyricrankreference_test.go", "handwrittenRankLyricSourceResults")
	type baked struct {
		policy BakedPolicy
		split  string
	}
	want := map[string]baked{}
	calls := regexp.MustCompile(`bakedLines\[("\w+"|\w+)\] = (\w+)\(([^\n]*)\)\n`).FindAllStringSubmatch(body, -1)
	for _, m := range calls {
		name := strings.Trim(m[1], `"`)
		if !strings.HasPrefix(m[1], `"`) {
			if name = consts[m[1]]; name == "" {
				t.Fatalf("bakedLines[%s]:不认识的源常量", m[1])
			}
		}
		switch {
		case m[2] != "adoptBakedTranslation":
			want[name] = baked{bakedCustom, m[2]}
		case strings.HasSuffix(m[3], ", true"):
			want[name] = baked{policy: bakedAdopt}
		case strings.HasSuffix(m[3], ", false"):
			want[name] = baked{policy: bakedStripOnly}
		default:
			t.Fatalf("bakedLines[%s] 的调用认不出接不接译文:%s", m[1], m[3])
		}
	}
	if n := strings.Count(body, "bakedLines["); n != len(calls)+1 || len(want) != len(calls) {
		t.Fatalf("参照里写 bakedLines 的有 %d 处,扫出来 %d 处、%d 个源,扫描式跟不上源码了", n-1, len(calls), len(want))
	}
	got := map[string]baked{}
	for _, d := range registryDescriptors() {
		if (d.BakedSplit != nil) != (d.Baked == bakedCustom) {
			t.Errorf("%s:BakedSplit 只在 bakedCustom 时有", d.Name)
		}
		switch d.Baked {
		case bakedNone:
		case bakedCustom:
			got[d.Name] = baked{bakedCustom, funcName(d.BakedSplit)}
		default:
			got[d.Name] = baked{policy: d.Baked}
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("登记表 %v\n参照 %v", got, want)
	}
}

func TestProviderRegistryParenBackgroundAndKanaMatch(t *testing.T) {
	got := registryNameSet(func(d *ProviderDescriptor) bool { return d.ParenBackground })
	if want := trueKeys(parenBGSources); !reflect.DeepEqual(got, want) {
		t.Errorf("括号背景人声:登记表 %v\nparenBGSources %v", sortedKeys(got), sortedKeys(want))
	}
	got = registryNameSet(func(d *ProviderDescriptor) bool { return d.CarriesKana })
	if want := trueKeys(kanaDonorSources); !reflect.DeepEqual(got, want) {
		t.Errorf("假名标注:登记表 %v\nkanaDonorSources %v", sortedKeys(got), sortedKeys(want))
	}
}

// 纯音乐标记搭车的先后:描述符的 InstrumentalRank 等于迁移前 rankLyricSourceResults 里那串 if / else if 的先后(扫参照的
// 函数体);几个源同时说是纯音乐时生产实际认谁,由 TestInstrumentalMarkerFollowsRank 按行为守。
func TestProviderRegistryInstrumentalRankMatchesRanking(t *testing.T) {
	body := goFuncSource(t, "lyricrankreference_test.go", "handwrittenRankLyricSourceResults")
	var want []string
	for _, m := range regexp.MustCompile(`scoredLyricCandidateResult\{Source: "(\w+)", Score: -1, Instrumental: true\}`).FindAllStringSubmatch(body, -1) {
		want = append(want, m[1])
	}
	if n := strings.Count(body, `scoredLyricCandidateResult{Source: "`); n != len(want) || n == 0 {
		t.Fatalf("参照里造纯音乐标记的有 %d 处,扫出来 %d 处,扫描式跟不上源码了", n, len(want))
	}
	got := registryNames(func(d *ProviderDescriptor) bool { return d.InstrumentalRank > 0 },
		func(d *ProviderDescriptor) int { return d.InstrumentalRank })
	if !slices.Equal(got, want) {
		t.Errorf("登记表 %v\n参照 %v", got, want)
	}
	if read := lyricProviders().instrumentalOrder; !slices.Equal(read, want) {
		t.Errorf("生产代码读的搭车先后 %v\n参照 %v", read, want)
	}
}

// 手打时间轴的源:描述符推出来的、生产代码读到的都等于期望表;没登记的名字不是。
func TestProviderRegistryHandTypedTimelineMatches(t *testing.T) {
	got := registryNameSet(func(d *ProviderDescriptor) bool { return d.HandTypedTimeline })
	if want := trueKeys(lyricSourceHandTypedTimelines); !reflect.DeepEqual(got, want) {
		t.Errorf("登记表 %v\n期望表 %v", sortedKeys(got), sortedKeys(want))
	}
	for _, d := range registryDescriptors() {
		if read := lyricSourceTimelineHandTyped(d.Name); read != lyricSourceHandTypedTimelines[d.Name] {
			t.Errorf("%s:lyricSourceTimelineHandTyped=%v,期望表 %v", d.Name, read, lyricSourceHandTypedTimelines[d.Name])
		}
	}
	if lyricSourceTimelineHandTyped("nope") || lyricSourceTimelineHandTyped("") {
		t.Error("没登记的名字不是手打时间轴的源")
	}
}

// descriptorCandidateShape:描述符的装配字段换成期望表 lyricSourceCandidateShape 的写法。
func descriptorCandidateShape(d *ProviderDescriptor) lyricSourceCandidateShape {
	as := d.Assembly
	bits := map[string]resultFields{
		"逐字": fieldWordTiming, "读音": fieldRomanization, "自报曲长": fieldSourceDuration, "专辑": fieldAlbum, "封面": fieldCover,
		"语种": fieldLanguage, "本机身份": fieldLocalIdentity, "纯文本": fieldPlainText, "ISRC": fieldISRC, "来源链接": fieldSourceURL,
		"背景人声轨": fieldBackground, "另一栏纯文本": fieldUntimedBody,
	}
	var reads []string
	for _, f := range rankShapeFields {
		if as.Reads.has(bits[f]) || (f == "作者" && d.SongwritersRank > 0) {
			reads = append(reads, f)
		}
	}
	shape := lyricSourceCandidateShape{reads: strings.Join(reads, " ")}
	switch as.Translation {
	case translationFixed:
		shape.translation = as.TranslationLang
	case translationTarget:
		shape.translation = "target"
	case translationDeclared:
		shape.translation = "declared"
	}
	switch d.Baked {
	case bakedAdopt:
		shape.baked = "adopt"
	case bakedStripOnly:
		shape.baked = "strip"
	case bakedCustom:
		// 自带摘法的源只用摘出来的译文,结果里交的译文轨不读。
		shape.baked, shape.translation = "adopt", ""
	}
	var signals []string
	for i, bit := range []instrumentalSignals{instrumentalDeclared, instrumentalCreditsNoVocals, instrumentalPlaceholder, instrumentalNoBodyNoVocals} {
		if as.Instrumental.has(bit) {
			signals = append(signals, rankShapeInstrumentalSignals[i])
		}
	}
	shape.instrumental = strings.Join(signals, " ")
	if as.UnnamedIsQueryTrack {
		shape.unnamed = "query"
	}
	shape.borrows = as.BorrowFromPeers != nil
	return shape
}

// 候选装配:带 Assembly 的描述符换成期望表的写法,跟 lyricSourceCandidateShapes 逐项相等(那张表是按行为从迁移前的排序里
// 看出来的,lyricrankshape_test.go 守着它跟参照、跟生产都对得上)。另核字段之间的硬关系。
func TestProviderRegistryAssemblyMatchesShapes(t *testing.T) {
	const known = fieldWordTiming | fieldRomanization | fieldSourceDuration | fieldAlbum | fieldCover | fieldLanguage |
		fieldLocalIdentity | fieldPlainText | fieldISRC | fieldSourceURL | fieldBackground | fieldUntimedBody
	for _, d := range registryDescriptors() {
		as := d.Assembly
		want, listed := lyricSourceCandidateShapes[d.Name]
		if as == nil || !listed {
			t.Errorf("%s:每个来源都要有 Assembly(%v),也都要在期望表 lyricSourceCandidateShapes 里(%v)", d.Name, as != nil, listed)
			continue
		}
		unpack := ""
		if as.Unpack != nil {
			unpack = funcName(as.Unpack)
		}
		if unpack != lyricSourceUnpackers[d.Name] {
			t.Errorf("%s:Unpack 是 %q,期望表 lyricSourceUnpackers 是 %q", d.Name, unpack, lyricSourceUnpackers[d.Name])
		}
		borrow := ""
		if as.BorrowFromPeers != nil {
			borrow = funcName(as.BorrowFromPeers)
		}
		if borrow != lyricSourcePeerBorrowers[d.Name] {
			t.Errorf("%s:BorrowFromPeers 是 %q,期望表 lyricSourcePeerBorrowers 是 %q", d.Name, borrow, lyricSourcePeerBorrowers[d.Name])
		}
		if (as.BorrowFromPeers != nil) != d.Privileges.has(privBorrowFromPeers) {
			t.Errorf("%s:借别家的封面、曲长(%v)和 privBorrowFromPeers(%v)要同时有", d.Name, as.BorrowFromPeers != nil, d.Privileges.has(privBorrowFromPeers))
		}
		if as.BorrowFromPeers != nil && as.Reads.has(fieldCover|fieldSourceDuration) {
			t.Errorf("%s:借别家封面、曲长的源自己不读这两栏", d.Name)
		}
		if as.Instrumental.has(instrumentalCreditsNoVocals) && as.Instrumental.has(instrumentalNoBodyNoVocals) {
			t.Errorf("%s:署名行加无人声已经包含没交正文的情形,别再登记没正文加无人声", d.Name)
		}
		if got := descriptorCandidateShape(d); got != want {
			t.Errorf("%s\n  登记表 %+v\n  期望表 %+v", d.Name, got, want)
		}
		if as.Reads&^known != 0 {
			t.Errorf("%s:Reads 里有不认识的位 %b", d.Name, as.Reads&^known)
		}
		if (as.TranslationLang != "") != (as.Translation == translationFixed) {
			t.Errorf("%s:TranslationLang 只在 translationFixed 时有,而且必须有", d.Name)
		}
		if (d.Baked == bakedAdopt || d.Baked == bakedCustom) && (as.Translation != translationFixed || as.TranslationLang != "zh") {
			t.Errorf("%s:摘出来的烘入译文固定是中文,接到译文轨的源译文轨必须固定标 zh", d.Name)
		}
		if as.Reads.has(fieldLocalIdentity) && !d.Privileges.has(privLocalClientIdentity) {
			t.Errorf("%s:候选读本机身份,却没有 privLocalClientIdentity(调度会把它交的本机身份清掉)", d.Name)
		}
		if as.Reads.has(fieldSourceURL) != (d.PageURL != nil) {
			t.Errorf("%s:候选带来源链接(%v)和登记了链接校验(%v)要同时有", d.Name, as.Reads.has(fieldSourceURL), d.PageURL != nil)
		}
		if as.Reads.has(fieldBackground) && d.ParenBackground {
			t.Errorf("%s:自带背景人声轨的源不拆括号背景人声", d.Name)
		}
		if (as.Instrumental != 0) != (d.InstrumentalRank > 0) {
			t.Errorf("%s:搭纯音乐标记的说法(%b)和搭车的名次(%d)要同时有", d.Name, as.Instrumental, d.InstrumentalRank)
		}
		accept := ""
		if as.AcceptTranslation != nil {
			accept = funcName(as.AcceptTranslation)
		}
		if accept != lyricSourceTranslationAccepters[d.Name] {
			t.Errorf("%s:AcceptTranslation 是 %q,期望表 lyricSourceTranslationAccepters 是 %q", d.Name, accept, lyricSourceTranslationAccepters[d.Name])
		}
	}
}

const registryGuardCJKLyrics = "[00:01.00]春天的花开了\n[00:05.00]秋天的风吹过\n[00:09.00]冬天的雪落下\n"

func TestProviderRegistrySongwritersRankMatches(t *testing.T) {
	const latin = "[00:01.00]first line here\n[00:05.00]second line here\n[00:09.00]third line here\n"
	var pool []scoredLyricCandidateResult
	for _, d := range registryDescriptors() {
		pool = append(pool, scoredLyricCandidateResult{Source: d.Name, Score: 1, Lyrics: latin, Songwriters: []string{d.Name}})
	}
	// 每次取出被选中的那个源、拿掉它再问,问到没有为止,得到的就是取用顺序。
	var want []string
	for len(pool) > 0 {
		sw := songwritersFromScored(pool)
		if len(sw) == 0 {
			break
		}
		want = append(want, sw[0])
		pool = slices.DeleteFunc(pool, func(c scoredLyricCandidateResult) bool { return c.Source == sw[0] })
	}
	got := registryNames(func(d *ProviderDescriptor) bool { return d.SongwritersRank > 0 },
		func(d *ProviderDescriptor) int { return d.SongwritersRank })
	if !slices.Equal(got, want) || len(want) == 0 {
		t.Errorf("登记表 %v\nsongwritersFromScored %v", got, want)
	}
	for _, name := range want {
		d := lyricProviders().descriptor(name)
		skipped := songwritersFromScored([]scoredLyricCandidateResult{
			{Source: name, Score: 1, Lyrics: registryGuardCJKLyrics, Songwriters: []string{name}},
		}) == nil
		if skipped != d.SongwritersSkipCJK {
			t.Errorf("%s:中日韩正文时不用它的作者名单=%v,登记表 SongwritersSkipCJK=%v", name, skipped, d.SongwritersSkipCJK)
		}
	}
	for _, d := range registryDescriptors() {
		if d.SongwritersSkipCJK && d.SongwritersRank == 0 {
			t.Errorf("%s:不取用作者名单的源不该带 SongwritersSkipCJK", d.Name)
		}
	}
}

func TestProviderRegistryPlainTextOrderMatches(t *testing.T) {
	const ref = "registry-guard-ref"
	plain := func(source string) scoredLyricCandidateResult {
		return scoredLyricCandidateResult{Source: source, Score: -1, PlainTextOnly: true, Lyrics: "text of " + source}
	}
	seen := map[PlainTextOrder]bool{}
	for _, d := range registryDescriptors() {
		_, behind := plainTextFallbackFromScored([]scoredLyricCandidateResult{plain(ref), plain(d.Name)})
		_, ahead := plainTextFallbackFromScored([]scoredLyricCandidateResult{plain(d.Name), plain(ref)})
		want := plainTextNormal
		switch {
		case behind == d.Name && ahead == d.Name:
			want = plainTextFirst
		case behind == ref && ahead == ref:
			want = plainTextLast
		case behind != ref || ahead != d.Name:
			t.Fatalf("%s:排在后面时选了 %q、排在前面时选了 %q,不是三档里的任何一档", d.Name, behind, ahead)
		}
		if d.PlainText != want {
			t.Errorf("%s:登记表 PlainText=%v,plainTextFallbackFromScored 表现为 %v", d.Name, d.PlainText, want)
		}
		seen[want] = true
	}
	if len(seen) != 3 {
		t.Errorf("三档应各有源落进去,只见到 %v", seen)
	}
}

func TestProviderRegistryConsensusFamilyMatches(t *testing.T) {
	shared := 0
	for _, d := range registryDescriptors() {
		got := d.ConsensusFamily
		if got == "" {
			got = d.Name
		}
		if want := lyricSourceConsensusFamily(d.Name); got != want {
			t.Errorf("%s:登记表家族 %q,lyricSourceConsensusFamily %q", d.Name, got, want)
		}
		if got != d.Name {
			shared++
		}
	}
	if shared == 0 {
		t.Error("没有一个源并进别家的家族,这条守卫什么都没比")
	}
}

func TestProviderRegistryISRCMatches(t *testing.T) {
	direct := sortedKeys(registryNameSet(func(d *ProviderDescriptor) bool { return d.ISRCLookup == isrcLookupDirect }))
	want := slices.Clone(isrcRetryableSources)
	sort.Strings(want)
	if !slices.Equal(direct, want) {
		t.Errorf("按 ISRC 直取:登记表 %v\nisrcRetryableSources %v", direct, want)
	}
	indexed := sortedKeys(registryNameSet(func(d *ProviderDescriptor) bool { return d.ISRCLookup == isrcLookupIndexed }))
	if !slices.Equal(indexed, isrcIndexedSources) || len(indexed) == 0 {
		t.Errorf("索引里有才问:登记表 %v\nisrcIndexedSources %v", indexed, isrcIndexedSources)
	}
	// 生产代码的读法:直取的一律问;索引里有才问的,问这个源自己的索引(ISRCIndexProvider);别的不问。
	for _, d := range registryDescriptors() {
		index, implemented := lyricProviders().provider(d.Name).(ISRCIndexProvider)
		if implemented != (d.ISRCLookup == isrcLookupIndexed) {
			t.Errorf("%s:实现了 ISRCIndexProvider(%v)跟 ISRCLookup=%v 对不上", d.Name, implemented, d.ISRCLookup)
		}
		const code = "USRC17607839"
		want := slices.Contains(isrcRetryableSources, d.Name) || (implemented && index.HasISRC(code))
		if got := lyricSourceTakesISRC(d.Name, code); got != want {
			t.Errorf("%s:lyricSourceTakesISRC=%v,期望 %v", d.Name, got, want)
		}
	}
	if lyricSourceTakesISRC("nope", "USRC17607839") {
		t.Error("没登记的名字不按 ISRC 问")
	}
	if plan := goFuncSource(t, "isrcretry.go", "isrcRetryPlan"); !containsCode(plan, "if lyricSourceTakesISRC(s, isrc) {") {
		t.Error("isrcRetryPlan 应按 lyricSourceTakesISRC 挑源")
	}

	authority := map[string]bool{}
	for _, d := range registryDescriptors() {
		recorded := recordingISRCsFromScored("", []scoredLyricCandidateResult{
			{Source: d.Name, Score: 1, ISRC: "USRC17607839", SourceReportedDurationSecs: 200, Title: "Song"},
		}, 200, "Song", "")
		if len(recorded) > 0 {
			authority[d.Name] = true
		}
	}
	if got := registryNameSet(func(d *ProviderDescriptor) bool { return d.ISRCAuthority }); !reflect.DeepEqual(got, authority) || len(got) == 0 {
		t.Errorf("ISRC 可记:登记表 %v\nrecordingISRCsFromScored %v", sortedKeys(got), sortedKeys(authority))
	}
}

func TestProviderRegistryPageURLMatches(t *testing.T) {
	samples := []string{
		"https://www.megalobiz.com/lrc/maker/Some+Song.54321",
		"https://github.com/amll-dev/amll-ttml-db/blob/main/ncm-lyrics/123.ttml",
		"http://www.megalobiz.com/lrc/maker/Some+Song.54321",
		"https://example.com/lyrics/1",
		"",
	}
	for _, d := range registryDescriptors() {
		linked := false
		for _, raw := range samples {
			want := lyricSourcePageURL(d.Name, raw)
			got := ""
			if d.PageURL != nil {
				got = d.PageURL(raw)
			}
			if got != want {
				t.Errorf("%s 的 %q:登记表核成 %q,lyricSourcePageURL 核成 %q", d.Name, raw, got, want)
			}
			if read := verifiedLyricSourcePageURL(d.Name, raw); read != want {
				t.Errorf("%s 的 %q:生产代码核成 %q,期望 %q", d.Name, raw, read, want)
			}
			linked = linked || want != ""
		}
		if linked != (d.PageURL != nil) {
			t.Errorf("%s:lyricSourcePageURL 链不链回(%v)跟登记表有没有 PageURL 对不上", d.Name, linked)
		}
	}
	if verifiedLyricSourcePageURL("nope", samples[0]) != "" {
		t.Error("没登记的名字不链回")
	}
}

// 特权位跟这张期望表逐项相等:给一个源加减特权要改这张表。
func TestProviderRegistryPrivilegesMatchExpected(t *testing.T) {
	want := map[string]builtinPrivileges{
		lyricSourceNetease:       privLocalClientIdentity | privTrackIDPublish | privPeripheral | privPlayerNoVocals,
		lyricSourceQQ:            privLocalClientIdentity | privTrackIDPublish | privPlayerNoVocals,
		lyricSourceKugou:         privLocalClientIdentity | privOfflineLeg,
		lyricSourceLRCLIB:        0,
		lyricSourceAMLL:          privPlaybackTrackIDs | privTrackIDConsume | privBorrowFromPeers | privRefetchByID,
		lyricSourceLyricFind:     privLocalClientIdentity | privPlaybackTrackIDs,
		lyricSourceKuwo:          privLocalClientIdentity | privOfflineLeg,
		lyricSourceMigu:          0,
		lyricSourceDeezer:        0,
		lyricSourceAppleMusic:    privLocalClientIdentity | privPlaybackTrackIDs | privPlayerNoVocals | privRefetchByID,
		lyricSourceSoda:          privLocalClientIdentity | privPlaybackTrackIDs | privPlayerNoVocals,
		lyricSourceVibe:          0,
		lyricSourceGenie:         0,
		lyricSourcePetitLyrics:   0,
		lyricSourceZing:          privBreakerControl,
		lyricSourceMegalobiz:     0,
		kkboxLocalLyricsSource:   privLocalClientIdentity,
		amazonLocalLyricsSource:  privLocalClientIdentity,
		lxMusicLocalLyricsSource: privLocalClientIdentity,
		localFileLyricsSource:    privLocalClientIdentity,
		importLyricsSource:       privLocalClientIdentity,
		spotifyLocalLyricsSource: privLocalClientIdentity | privPlayerNoVocals,
	}
	got := map[string]builtinPrivileges{}
	for _, d := range registryDescriptors() {
		got[d.Name] = d.Privileges
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("登记表 %v\n期望表 %v", got, want)
	}
}

// 特权位里能从现有代码推出来的几种,跟代码对一遍。
func TestProviderRegistryPrivilegesMatchCode(t *testing.T) {
	consts := lyricSourceConstNames(t)
	withPriv := func(bit builtinPrivileges) map[string]bool {
		return registryNameSet(func(d *ProviderDescriptor) bool { return d.Privileges.has(bit) })
	}
	enrichRaw, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	enrichSrc := string(enrichRaw)

	// 等别的源递编号:别名轮名单里没有它等的那几个源时被剔掉(dropAMLLWithoutIDSource)。
	network := registryNetworkNames()
	for _, name := range network {
		d := lyricProviders().descriptor(name)
		consumes := d.Privileges.has(privTrackIDConsume)
		if consumes != (len(d.DependsOnIDsFrom) > 0) {
			t.Errorf("%s:DependsOnIDsFrom 只在带 privTrackIDConsume 时有", name)
		}
		if alone := slices.Contains(dropAMLLWithoutIDSource([]string{name}), name); alone == consumes {
			t.Errorf("%s:名单里只有它时留不留(%v)跟 privTrackIDConsume=%v 对不上", name, alone, consumes)
		}
		if !consumes {
			continue
		}
		for _, other := range network {
			if other == name {
				continue
			}
			kept := slices.Contains(dropAMLLWithoutIDSource([]string{name, other}), name)
			if kept != slices.Contains(d.DependsOnIDsFrom, other) {
				t.Errorf("%s:名单里有 %s 时留不留(%v)跟 DependsOnIDsFrom=%v 对不上", name, other, kept, d.DependsOnIDsFrom)
			}
		}
		for _, from := range d.DependsOnIDsFrom {
			if !lyricProviders().descriptor(from).Privileges.has(privTrackIDPublish) {
				t.Errorf("%s 等 %s 的编号,但 %s 没有 privTrackIDPublish", name, from, from)
			}
			if len(lyricProviders().descriptor(from).DependsOnIDsFrom) != 0 {
				t.Errorf("%s 等 %s 的编号,%s 自己又等别人的:成环就两边都等不到", name, from, from)
			}
		}
	}

	// 递编号:登记的实现在 Resolve 里经环境递(env.PublishTrackID),收集循环里不再有按源名写的通道。熔断冷却时的
	// 本机那条腿:登记的实现有没有 ResolveOffline,它里面读的是这个源自己的本机那份;收集循环里不再有按源名写的这一支。
	offlineImpl, publishes := map[string]bool{}, map[string]bool{}
	for _, p := range lyricProviders().providers {
		if _, ok := p.(OfflineResolver); ok {
			offlineImpl[p.Descriptor().Name] = true
		}
		if containsCode(lyricProviderResolveSource(t, p), "env.PublishTrackID(") {
			publishes[p.Descriptor().Name] = true
		}
		// 等编号:Resolve 里经环境读(env.TrackIDFrom),读的恰好是描述符声明要等的那几个源。
		d := p.Descriptor()
		var reads []string
		for _, m := range regexp.MustCompile(`env\.TrackIDFrom\((\w+)\)`).FindAllStringSubmatch(lyricProviderResolveSource(t, p), -1) {
			from := consts[m[1]]
			if from == "" {
				t.Fatalf("%s 的 Resolve 里 env.TrackIDFrom(%s):不认识的源常量", d.Name, m[1])
			}
			reads = append(reads, from)
		}
		if !slices.Equal(reads, d.DependsOnIDsFrom) {
			t.Errorf("%s:Resolve 里等的编号 %v 跟 DependsOnIDsFrom=%v 对不上", d.Name, reads, d.DependsOnIDsFrom)
		}
	}
	if containsCode(enrichSrc, "case lyricSourceSkipCooling: if r, ok := ") {
		t.Error("收集循环里不该再有按源名写的「冷却时读本机那份」:这一支在调度里(offlineLegResult)")
	}
	for _, name := range network {
		d := lyricProviders().descriptor(name)
		if publishes[name] != d.Privileges.has(privTrackIDPublish) {
			t.Errorf("%s:Resolve 里递不递编号(%v)跟 privTrackIDPublish 对不上", name, publishes[name])
		}
		if containsCode(enrichSrc, name+"IDCh") {
			t.Errorf("收集循环里不该再有按源名写的递编号通道 %sIDCh:递编号经调度建的 roundTrackIDs", name)
		}
		if offlineImpl[name] != d.Privileges.has(privOfflineLeg) {
			t.Errorf("%s:实现了 ResolveOffline(%v)跟 privOfflineLeg 对不上", name, offlineImpl[name])
		}
		if !offlineImpl[name] {
			continue
		}
		raw, err := os.ReadFile(name + ".go")
		if err != nil {
			t.Fatal(err)
		}
		body := string(raw)
		start := strings.Index(body, "Provider) ResolveOffline(q ProviderQuery) (SourceResult, bool) {")
		if start < 0 {
			t.Fatalf("%s.go 里找不到 ResolveOffline", name)
		}
		body = body[start:]
		body = body[:strings.Index(body, "\n}\n")]
		if !containsCode(body, "r, ok := "+name+"LocalLyric(q.Artist, q.SourceTitle,") || containsCode(body, name+"Lyric(") {
			t.Errorf("%s 的 ResolveOffline 应只读它自己的本机那份(%sLocalLyric),不调联网的入口:\n%s", name, name, body)
		}
	}
	if len(offlineImpl) == 0 {
		t.Error("没有一个源实现 ResolveOffline:酷狗、酷我应各有一份")
	}

	// 播放器自己的无人声信号:playerInstrumentalSource 认的那几路。
	list := regexp.MustCompile(`range \[\]string\{([^}]*)\}`).FindStringSubmatch(goFuncSource(t, "enrich.go", "playerInstrumentalSource"))
	if list == nil {
		t.Fatal("playerInstrumentalSource 里找不到源名单")
	}
	noVocals := map[string]bool{}
	for _, id := range strings.Split(list[1], ",") {
		name := consts[strings.TrimSpace(id)]
		if name == "" {
			t.Fatalf("playerInstrumentalSource 的名单里有不认识的源常量 %q", id)
		}
		noVocals[name] = true
	}
	if got := withPriv(privPlayerNoVocals); !reflect.DeepEqual(got, noVocals) {
		t.Errorf("privPlayerNoVocals:登记表 %v\nplayerInstrumentalSource %v", sortedKeys(got), sortedKeys(noVocals))
	}

	// 存量回填按编号重取:needsBackgroundVocalsBackfill 认的胜出源。
	refetch := map[string]bool{}
	for _, d := range registryDescriptors() {
		if needsBackgroundVocalsBackfill(enrichEntry{LyricsSource: d.Name, Lyrics: bt(registryGuardCJKLyrics)}) {
			refetch[d.Name] = true
		}
	}
	if got := withPriv(privRefetchByID); !reflect.DeepEqual(got, refetch) || len(got) == 0 {
		t.Errorf("privRefetchByID:登记表 %v\nneedsBackgroundVocalsBackfill %v", sortedKeys(got), sortedKeys(refetch))
	}

	// 自己要求整源暂停:全部非测试源码里调 noteBlocked 的源。
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	blocked := map[string]bool{}
	call := regexp.MustCompile(`\.noteBlocked\((\w+)\)`)
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range call.FindAllStringSubmatch(string(raw), -1) {
			name := consts[m[1]]
			if name == "" {
				t.Fatalf("%s 里 noteBlocked(%s):不认识的源常量", f, m[1])
			}
			blocked[name] = true
		}
	}
	if got := withPriv(privBreakerControl); !reflect.DeepEqual(got, blocked) || len(got) == 0 {
		t.Errorf("privBreakerControl:登记表 %v\n调 noteBlocked 的源 %v", sortedKeys(got), sortedKeys(blocked))
	}
}
