package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
)

// 新增歌词源时的完整性守卫。
//
// 加 amll 那次的教训:源常量加好了、抓取也接上了,但**四处清单漏了**——
// resolveLyricsSources 的全集兜底(导致全新安装时它被禁用)、healthcheckcli 的探测清单、
// Swift 侧 LyricsSource 枚举(导致"顺序优先"排序列表里根本没有它、徽章显示成灰色原名)。
// 一处都不报错、全都是静默失效,只能靠人肉发现。跟 scoretermlabel_test.go 同一个路子:
// 把清单钉死在测试里,忘了补就直接红。
func allLyricSourceConstants() []string {
	return []string{
		lyricSourceNetease, lyricSourceQQ, lyricSourceKugou,
		lyricSourceMusixmatch, lyricSourceLRCLIB, lyricSourceAMLL, lyricSourceLyricFind,
		lyricSourceKuwo, lyricSourceMigu, lyricSourceDeezer, lyricSourceAppleMusic,
		lyricSourceSoda,
	}
}

func TestEveryLyricSourceIsRegistered(t *testing.T) {
	all := allLyricSourceConstants()

	// ① 进度分母 / 并发收集的源名清单
	inNames := map[string]bool{}
	for _, s := range lyricSourceNames {
		inNames[s] = true
	}
	for _, s := range all {
		if !inNames[s] {
			t.Errorf("源 %q 不在 lyricSourceNames 里(进度分母会少算、收集循环也读它)", s)
		}
	}
	if len(lyricSourceNames) != len(all) {
		t.Errorf("lyricSourceNames 有 %d 个,源常量有 %d 个,对不上", len(lyricSourceNames), len(all))
	}

	// ② "顺序优先"模式的默认顺序
	inOrder := map[string]bool{}
	for _, s := range lyricsSourceDefaultOrder {
		inOrder[s] = true
	}
	for _, s := range all {
		if !inOrder[s] {
			t.Errorf("源 %q 不在 lyricsSourceDefaultOrder 里", s)
		}
	}

	// ③ 全集兜底(lyrics_sources 缺失/为空 = 全开)。漏一个 = 那个源在全新安装上被禁用。
	full := resolveLyricsSources(nil, nil, nil, nil, nil, nil, nil, nil)
	for _, s := range all {
		if !full[s] {
			t.Errorf("源 %q 不在 resolveLyricsSources 的全集兜底里(全新安装会禁用它)", s)
		}
	}

	// ④ 老配置的一次性迁移:amll/lyricfind/kuwo 各自的迁移标记缺失时补进去,已表态时
	// 尊重用户选择。 迁移标记参数跟真实源数脱节时,lyrics_sources 里只有旧的六个源、
	// 没有对应迁移字段的机器上,search-lyrics 的 sourcesTotal 会停在 6、候选列表里一条
	// 新源都没有——这里钉死的正是这个场景(见 resolveLyricsSources 里对应的注释)。
	old := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, nil, nil, nil, nil)
	if !old[lyricSourceAMLL] {
		t.Error("老配置(amll_lyrics 缺失)应当把 amll 补进启用集合")
	}
	if !old[lyricSourceLyricFind] {
		t.Error("老配置(lyricfind_lyrics 缺失)应当把 lyricfind 补进启用集合——这正是 2026-08-25 实测复现过的那个 bug")
	}
	if !old[lyricSourceKuwo] {
		t.Error("老配置(kuwo_lyrics 缺失)应当把 kuwo 补进启用集合")
	}
	if !old[lyricSourceMigu] {
		t.Error("老配置(migu_lyrics 缺失)应当把 migu 补进启用集合")
	}
	if !old[lyricSourceDeezer] {
		t.Error("老配置(deezer_lyrics 缺失)应当把 deezer 补进启用集合")
	}
	if !old[lyricSourceSoda] {
		t.Error("老配置(soda_lyrics 缺失)应当把 soda 补进启用集合")
	}
	no := false
	statedAMLL := resolveLyricsSources([]string{"netease", "qq"}, &no, nil, nil, nil, nil, nil, nil)
	if statedAMLL[lyricSourceAMLL] {
		t.Error("用户已表态(amll_lyrics=false)时不该再把 amll 补回来")
	}
	if !statedAMLL[lyricSourceLyricFind] {
		t.Error("amll 已表态不影响 lyricfind 的迁移——lyricfind_lyrics 仍缺失时应该照常补它")
	}
	if !statedAMLL[lyricSourceKuwo] {
		t.Error("amll 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	statedLF := resolveLyricsSources([]string{"netease", "qq"}, nil, &no, nil, nil, nil, nil, nil)
	if statedLF[lyricSourceLyricFind] {
		t.Error("用户已表态(lyricfind_lyrics=false)时不该再把 lyricfind 补回来")
	}
	if !statedLF[lyricSourceAMLL] {
		t.Error("lyricfind 已表态不影响 amll 的迁移——amll_lyrics 仍缺失时应该照常补它")
	}
	if !statedLF[lyricSourceKuwo] {
		t.Error("lyricfind 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	statedKuwo := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, &no, nil, nil, nil, nil)
	if statedKuwo[lyricSourceKuwo] {
		t.Error("用户已表态(kuwo_lyrics=false)时不该再把 kuwo 补回来")
	}
	if !statedKuwo[lyricSourceAMLL] {
		t.Error("kuwo 已表态不影响 amll 的迁移——amll_lyrics 仍缺失时应该照常补它")
	}
	if !statedKuwo[lyricSourceLyricFind] {
		t.Error("kuwo 已表态不影响 lyricfind 的迁移——lyricfind_lyrics 仍缺失时应该照常补它")
	}
	if !statedKuwo[lyricSourceMigu] {
		t.Error("kuwo 已表态不影响 migu 的迁移——migu_lyrics 仍缺失时应该照常补它")
	}
	statedMigu := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, &no, nil, nil, nil)
	if statedMigu[lyricSourceMigu] {
		t.Error("用户已表态(migu_lyrics=false)时不该再把 migu 补回来")
	}
	if !statedMigu[lyricSourceKuwo] {
		t.Error("migu 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	if !statedMigu[lyricSourceDeezer] {
		t.Error("migu 已表态不影响 deezer 的迁移——deezer_lyrics 仍缺失时应该照常补它")
	}
	statedDeezer := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, nil, &no, nil, nil)
	if statedDeezer[lyricSourceDeezer] {
		t.Error("用户已表态(deezer_lyrics=false)时不该再把 deezer 补回来")
	}
	if !statedDeezer[lyricSourceMigu] {
		t.Error("deezer 已表态不影响 migu 的迁移——migu_lyrics 仍缺失时应该照常补它")
	}

	statedAM := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, nil, nil, &no, nil)
	if statedAM[lyricSourceAppleMusic] {
		t.Error("用户已表态(applemusic_lyrics=false)时不该再把 applemusic 补回来")
	}
	if !statedAM[lyricSourceDeezer] {
		t.Error("applemusic 已表态不影响 deezer 的迁移——deezer_lyrics 仍缺失时应该照常补它")
	}
	if !statedAM[lyricSourceSoda] {
		t.Error("applemusic 已表态不影响 soda 的迁移——soda_lyrics 仍缺失时应该照常补它")
	}

	statedSoda := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, nil, nil, nil, &no)
	if statedSoda[lyricSourceSoda] {
		t.Error("用户已表态(soda_lyrics=false)时不该再把 soda 补回来")
	}
	if !statedSoda[lyricSourceAppleMusic] {
		t.Error("soda 已表态不影响 applemusic 的迁移——applemusic_lyrics 仍缺失时应该照常补它")
	}
}

// 并发收集那个循环的次数、以及结果 channel 的缓冲,都必须**跟着源数走**,不许写字面量。
//
// 硬编码过字面量(如 `for i := 0; i < 9`)会跟 goroutine 数(源数 + 1,多出来的是
// applecover)脱节——每加一个源就多丢一份结果:循环先数满就退出,**最后到达的那个源的
// 应答被直接扔掉**,且丢的往往是最慢的源、不容易被察觉,表现是该源明明取回了内容却从
// 没进过候选列表,而丢掉的不只是那一个源自己的候选——跨源正文共识也会跟着少算一份。
//
// 用源码扫描而不是跑一遍收集循环:那需要真网或一整套假源,而这里要守的东西很简单——
// 「这两处有没有跟 lyricSourceNames 绑在一起」,读源码就能答。
func TestLyricSourceCollectLoopTracksSourceCount(t *testing.T) {
	raw, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatalf("读不到 enrich.go: %v", err)
	}
	body := string(raw)
	for _, want := range []string{
		// 收集循环:源数 + applecover
		"for i := 0; i < len(lyricSourceNames)+1; i++ {",
		// 结果 channel 的缓冲同理
		"make(chan lyricSourceResult, len(lyricSourceNames)+1)",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("enrich.go 里没找到 %q —— 这两处必须跟源数联动,写死字面量会在下次加源时静默丢结果", want)
		}
	}
	// 再正面堵一次写死的形状:`for i := 0; i < <数字>; i++` 在这个文件里不该再出现。
	if m := regexp.MustCompile(`for i := 0; i < \d+; i\+\+`).FindString(body); m != "" {
		t.Errorf("enrich.go 里出现了写死次数的循环 %q —— 见本测试头注那个丢结果的坑", m)
	}
}

// Swift 侧 LyricsSource 枚举必须覆盖全部源 —— 它是设置界面勾选框、"顺序优先"排序列表、
// 搜索弹窗徽章三处的唯一数据源,漏一个就是那个源在 UI 上整个不存在。
func TestSwiftLyricsSourceEnumCoversAllSources(t *testing.T) {
	const p = "../lyrimuse/Sources/lyrimuse/Settings/FeatureSettingsStore.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}
	// 别按"以 netease 开头"来找这一行。枚举的**声明顺序是有语义的**(它同时是设置页九个
	// 勾选框的展示序和"顺序优先"模式的默认顺序,见 Swift 侧那段注释),排序本来就会变:
	// 按实测采用率把 kugou 提到首位时,原先写死的 `case\s+(netease[^\n]*)` 当场
	// 匹配不到、整条守卫直接 Fatal —— 而它要守的是"九个源一个不漏",跟谁排第一无关。
	// 改成先定位枚举声明本身、再取其后第一个 case 行:以后怎么重排都不会误伤这条守卫。
	re := regexp.MustCompile(`(?s)public enum LyricsSource: String.*?\n\s*case\s+([^\n]+)`)
	m := re.FindStringSubmatch(string(raw))
	if m == nil {
		t.Fatalf("没在 %s 里找到 LyricsSource 的 case 行(枚举被改写了?同步更新这个测试)", p)
	}
	cases := map[string]bool{}
	for _, c := range strings.Split(m[1], ",") {
		cases[strings.TrimSpace(c)] = true
	}
	for _, s := range allLyricSourceConstants() {
		if !cases[s] {
			t.Errorf("Swift 侧 LyricsSource 枚举缺 %q —— 设置里的勾选框/顺序列表/搜索徽章都会漏掉它", s)
		}
	}
}

// 每个「迁移标记」(`xxx_lyrics`)在 Go 与 Swift 两侧必须**一一对应**,而且 Swift 侧的三处
// (CodingKeys / 保存时写回 / 读取时补默认)一处都不能少。
//
// 这条关系是硬性的,少了任何一处的后果都是**静默的**:collector 那边 xxxSeen 恒为 nil、
// 每次加载都把这个源补回启用集合,于是**用户在设置里取消勾选这个源对后台完全无效**——
// 而界面自己按 lyrics_sources 显示成已取消,两边说法不一致,从界面上根本看不出来。
// (接 soda 时就漏了 Swift 那三处,靠人问"新源默认是启用还是停用"才翻出来。)
//
// 判据从 Go 侧的 json tag 出发,不靠命名规则推 Swift 的驼峰名(AMLLLyrics / LyricFindLyrics
// 这些反推不出来),而是先从 Swift 的 CodingKeys 行里把该源的 case 名读出来,再拿它去核
// 另外两处。
func TestLyricsMigrationFlagsMatchOnBothSides(t *testing.T) {
	goSrc, err := os.ReadFile("features.go")
	if err != nil {
		t.Fatalf("读不到 features.go: %v", err)
	}
	const swiftPath = "../lyrimuse/Sources/lyrimuse/Settings/FeatureSettingsStore.swift"
	swiftRaw, err := os.ReadFile(swiftPath)
	if err != nil {
		t.Skipf("读不到 %s: %v", swiftPath, err)
	}
	swift := string(swiftRaw)

	tags := regexp.MustCompile(`json:"([a-z_]+_lyrics),omitempty"`).FindAllStringSubmatch(string(goSrc), -1)
	if len(tags) == 0 {
		t.Fatal("features.go 里一个 xxx_lyrics 迁移标记都没找到(字段被改写了?同步更新这个测试)")
	}
	for _, m := range tags {
		tag := m[1]
		caseRe := regexp.MustCompile(`case (\w+) = "` + regexp.QuoteMeta(tag) + `"`)
		cm := caseRe.FindStringSubmatch(swift)
		if cm == nil {
			t.Errorf("Swift 侧 CodingKeys 缺 %q —— collector 会一直把这个源补回来,用户取消勾选无效", tag)
			continue
		}
		name := cm[1]
		if !strings.Contains(swift, name+": lyricsSources.contains(.") {
			t.Errorf("Swift 侧保存时没写回 %s(%s)—— 标记永远为 nil,迁移会每次都跑", name, tag)
		}
		if !strings.Contains(swift, "f."+name+" == nil") {
			t.Errorf("Swift 侧读取时没有 f.%s == nil 那一支(%s)—— 界面与后台会得到两种启用集合", name, tag)
		}
	}
}

// 源特有的失败原因代码必须在**两处**消费面都接上:搜索弹窗的
// `lyricSourceFailureReasons`(searchcli.go)和设置页测试按钮的那个 switch
// (testlyricsourcescli.go)。
//
// 接 deezer 那次只补了前者,后者照样退回通用的 no_response —— 设置页那颗「测试」按钮
// 于是把"换票这一步失败"说成了"这个源没反应"。当时的注释里写着"守卫没钉住它",这条就是
// 补上的那道守卫:按源名扫两个文件的源码,少哪一处就报哪一处。
//
// 用源码扫描而不是跑一遍诊断:后者要造出每一种失败态(限流/地区限制/换票失败/端点变形),
// 而这里要守的只是「这个源名在这两处都出现过」,读源码就能答。
func TestLyricSourceFailureReasonWiredInBothConsumers(t *testing.T) {
	// 有专属失败原因的源 → 它在两处 switch/check 里的源名。没有专属原因的源不在此列
	// (它们只走传输层通用代码),新接的源如果加了 xxxLastFailureReasonNow,这里也要补一行。
	sources := []string{"netease", "musixmatch", "lyricfind", "deezer", "soda"}
	files := map[string]string{
		"searchcli.go":           `check("%s"`,
		"testlyricsourcescli.go": `case "%s":`,
	}
	for name, pattern := range files {
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("读不到 %s: %v", name, err)
		}
		body := string(raw)
		for _, s := range sources {
			if !strings.Contains(body, fmt.Sprintf(pattern, s)) {
				t.Errorf("%s 里没接 %q 的失败原因 —— 两处消费面必须同时接,漏一处的表现见本测试头注", name, s)
			}
		}
	}
}

// 「歌词管理」窗口的**来源筛选下拉**必须从 LyricsSource.allCases 派生,不许手写字面量清单。
//
// 漏网之鱼:那份清单原来是手写的
// `[.all, .named("amll"), .named("netease"), …, .named("lyricfind"), .none]`,是一份跟
// LyricsSource.allCases 平行维护的字面量副本 —— 后续接入的酷我 / 咪咕 / Deezer / Apple Music
// 四个源**在下拉里根本不存在** —— 列表里明明有这些源的歌词,按来源却永远筛不出来。
//
// 上面那几个 Test 全都没能拦住它:它们守的是"源常量有没有挂进某个清单",而这里是
// 另一种形态——一份**平行维护的字面量副本**,每加一个源都要人肉同步一次。所以这条守卫
// 换个守法:不检查"有没有 applemusic",而是检查"它到底是不是从枚举派生的"。只要还是
// 派生的,以后加多少源都不可能漏;哪天有人改回手写清单,这条立刻红。
func TestSwiftSourceFilterDerivesFromEnum(t *testing.T) {
	const p = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsManagerView.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}
	body := string(raw)
	if !strings.Contains(body, "LyricsSource.allCases.map { .named($0.rawValue) }") {
		t.Errorf("%s 的来源筛选清单不是从 LyricsSource.allCases 派生的——手写清单每加一个源都要人肉同步,已经漏过一次(见本测试头注)", p)
	}
	// 反面:文件里不该再出现 `.named("<字面量>")`。`.named(` 本身在模式匹配里还会用到
	// (case .named(let s)),所以只拦带引号的那种——那只可能是手写的源名。
	if m := regexp.MustCompile(`\.named\("[a-z]+"\)`).FindString(body); m != "" {
		t.Errorf("%s 里出现了手写的源名 %q —— 来源清单要从 LyricsSource.allCases 派生", p, m)
	}
}

// 来源展示名和配色也得有,否则界面上直接印英文原名 / 一律灰色。
func TestSwiftSourceDisplayNameCoversAllSources(t *testing.T) {
	const p = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsManagerView.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}
	body := string(raw)
	for _, s := range allLyricSourceConstants() {
		if !strings.Contains(body, `case "`+s+`": return`) {
			t.Errorf("Swift 侧 sourceDisplayName/sourceColor 缺 %q 的分支", s)
		}
	}
}

// 「搜索候选歌词」弹窗两句空状态文案里硬编码的中文数字("六个源都没找到可用的候选"/
// "六个源的请求全部失败…")必须跟源的实际数量一致——加 amll 之后这两句
// 曾经停在"五个源"没跟上,纯靠人肉截图发现,而上面几个 Test 都不会替它报警(它们守的是
// "某个源漏挂在某个清单里",不是"某句文案里的数字过期了")。同一份文件里,零个/一个
// 数字不用写死中文数字表——已知会用到的范围窄,给 5~9 手写映射即可,超出直接报错提醒
// 去扩表,而不是默默算错。
func TestSwiftSearchEmptyStateCountMatchesSourceCount(t *testing.T) {
	chineseDigits := map[int]string{5: "五", 6: "六", 7: "七", 8: "八", 9: "九", 10: "十", 11: "十一", 12: "十二"}
	n := len(allLyricSourceConstants())
	digit, ok := chineseDigits[n]
	if !ok {
		t.Fatalf("源数量是 %d,没有对应的中文数字——请在 chineseDigits 里补上再跑这个测试", n)
	}

	const p = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsSearchSheet.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}
	body := string(raw)
	needles := []string{
		digit + `个源都没找到可用的候选`,
		digit + `个源的请求全部失败`,
	}
	for _, needle := range needles {
		if !strings.Contains(body, needle) {
			t.Errorf("在 %s 里没找到 %q——源数量是 %d(%s个),这两句空状态文案的数字要跟着改",
				p, needle, n, digit)
		}
	}
}

// 面向用户 / 面向维护者的几处"一共几个源"必须跟常量表对齐——加咪咕时只改了上面
// selftest 钉住的两句文案和 README 三处,漏了 01 章、09 章标题、14 章、collector 一条日志里写死的
// 「%d/8」(表现是界面上「歌词源数量还是 8」)。这里把**带具体数字的现状描述**钉死;其它地方从此
// 一律写"全部源 / 各源",不带数字(带日期的历史记录除外),新加源时就不会再有第二批漏网。
func TestDocsSourceCountMatchesSourceCount(t *testing.T) {
	chineseDigits := map[int]string{5: "五", 6: "六", 7: "七", 8: "八", 9: "九", 10: "十", 11: "十一", 12: "十二"}
	englishWords := map[int]string{5: "Five", 6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten", 11: "Eleven", 12: "Twelve"}
	n := len(allLyricSourceConstants())
	zh, okZh := chineseDigits[n]
	en, okEn := englishWords[n]
	if !okZh || !okEn {
		t.Fatalf("源数量是 %d,没有对应的中英数字——请在两张表里补上再跑这个测试", n)
	}
	checks := []struct{ path, needle string }{
		{"../README.md", en + " lyrics sources checked automatically"},
		{"../README.md", "to the " + strings.ToLower(en) + " lyric sources above"},
		{"../README.zh-CN.md", "自动查" + zh + "个歌词源"},
		{"../README.zh-CN.md", "发给上面" + zh + "个歌词源"},
		{"../docs/features/01-overview.md", zh + "个歌词源:`music.163.com`"},
		{"../docs/features/01-overview.md", zh + "个歌词源(网易云/QQ/酷狗/"},
		{"../docs/features/09-lyrics-resolution.md", "### 3. " + zh + "源并发收集"},
		{"../docs/features/09-lyrics-resolution.md", "去" + zh + "个歌词源（"},
		{"../docs/features/14-settings-config.md", "歌词来源" + zh + "源勾选"},
		{"../docs/features/README.md", zh + "源检索、守卫"},
		{"../lyrimuse/Sources/lyrimuse/Settings/FeatureSettingsStore.swift", "// " + zh + "个歌词源——rawValue"},
	}
	// docs/features 只留本地、不进版本控制,所以 CI 检出的树里根本没有这一整个目录。
	// 判据是**目录在不在**,不是逐个文件容错:目录在却少一份 = 真的被挪走/改名了,那仍然要报。
	docsCheckedOut := true
	if _, err := os.Stat("../docs/features"); err != nil {
		docsCheckedOut = false
	}
	for _, c := range checks {
		if !docsCheckedOut && strings.HasPrefix(c.path, "../docs/features/") {
			continue
		}
		raw, err := os.ReadFile(c.path)
		if err != nil {
			t.Errorf("读不到 %s: %v", c.path, err)
			continue
		}
		if !strings.Contains(string(raw), c.needle) {
			t.Errorf("%s 里没找到 %q——源数量是 %d,这处的数字要跟着改", c.path, c.needle, n)
		}
	}
}

// 热重读不许保留任何字段的旧值:App 侧改设置不再重启 collector(CollectorRestartPolicy 已删),
// 被留下旧值的字段改了就永远不生效,而且不报错。有字段真要特殊处理,照 lyrics_dir 的做法在换快照
// 之后另起一步(见 lyricsdirswitch.go),别在快照里留旧值。
func TestFeaturesHotReloadKeepsNoStaleField(t *testing.T) {
	goSrc, err := os.ReadFile("featuresreload.go")
	if err != nil {
		t.Fatalf("读不到 featuresreload.go: %v", err)
	}
	for _, m := range regexp.MustCompile(`next\.(\w+) = cur\.\w+`).FindAllStringSubmatch(string(goSrc), -1) {
		t.Errorf("featuresreload.go 热重读时保留了 %s 的旧值,改它将永远不生效", m[1])
	}
}
