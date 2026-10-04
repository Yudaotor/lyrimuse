package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
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
	full := resolveLyricsSources(nil)
	for _, s := range all {
		if !full[s] {
			t.Errorf("源 %q 不在 resolveLyricsSources 的全集兜底里(全新安装会禁用它)", s)
		}
	}

	// ④ 引擎只认列表:老配置补新源的迁移标记(xxx_lyrics)只 App 读,补完写进 lyrics_sources。
	listed := resolveLyricsSources([]string{"netease", "qq"})
	if len(listed) != 2 || !listed[lyricSourceNetease] || !listed[lyricSourceQQ] {
		t.Errorf("列了几个就开几个,不按迁移标记补源: %v", listed)
	}
}

// 并发收集那个循环的次数、以及结果 channel 的缓冲,都必须**跟着源数走**,不许写字面量。
//
// 硬编码过字面量(如 `for i := 0; i < 9`)会跟 goroutine 数(每个源一个)脱节——每加一个源就多丢一份结果:循环先数满就退出,**最后到达的那个源的
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
		// 收集循环:按源清单逐个核对到齐
		"for !allLyricSourcesBack() {",
		"allLyricSourcesBack := func() bool {\n\t\tfor _, s := range lyricSourceNames {",
		// 结果 channel 的缓冲:每个源一个 goroutine,都能不阻塞地放下自己那一份
		"make(chan lyricSourceResult, len(lyricSourceNames))",
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

// 后来加的源(最早五个之外的)在老配置的 lyrics_sources 白名单里不可能出现,只靠 App 那份迁移标记(`xxx_lyrics`)
// 补进启用集合;引擎只认 lyrics_sources。所以每个后来加的源在 Swift 侧都要有标记,三处一处都不能少:
// CodingKeys 里有键、保存时按集合写回、读取时有 `f.xxx == nil` 补源那一支。少了写回,每次加载都把这个源补回来、
// 再整份写回文件,用户取消勾选无效;少了补源那一支,老配置升级后这个源一直是关的。
//
// 标记的键名是「源名 + _lyrics」;Swift 的 case 名反推不出来(amllLyrics / lyricFindLyrics),先从 CodingKeys
// 行里按键名读出 case 名,再拿它去核另外两处。
func TestLyricsMigrationFlagsCoverNewerSources(t *testing.T) {
	const swiftPath = "../lyrimuse/Sources/lyrimuse/Settings/FeatureSettingsStore.swift"
	swiftRaw, err := os.ReadFile(swiftPath)
	if err != nil {
		t.Skipf("读不到 %s: %v", swiftPath, err)
	}
	swift := string(swiftRaw)
	original := map[string]bool{lyricSourceNetease: true, lyricSourceQQ: true, lyricSourceKugou: true,
		lyricSourceMusixmatch: true, lyricSourceLRCLIB: true}
	for _, src := range lyricSourceNames {
		if original[src] {
			continue
		}
		tag := src + "_lyrics"
		cm := regexp.MustCompile(`case (\w+) = "` + regexp.QuoteMeta(tag) + `"`).FindStringSubmatch(swift)
		if cm == nil {
			t.Errorf("Swift 侧 CodingKeys 缺 %q —— 老配置升级后 %s 一直是关的", tag, src)
			continue
		}
		name := cm[1]
		if !strings.Contains(swift, name+": lyricsSources.contains(.") {
			t.Errorf("Swift 侧保存时没写回 %s(%s)—— 标记永远为 nil,每次加载都会把这个源补回来", name, tag)
		}
		if !strings.Contains(swift, "f."+name+" == nil") {
			t.Errorf("Swift 侧读取时没有 f.%s == nil 那一支(%s)—— 老配置升级后这个源一直是关的", name, tag)
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

// 「搜索候选歌词」弹窗的空状态文案如果写了中文数字("六个源都没找到可用的候选"/
// "六个源的请求全部失败…"),必须跟源的实际数量一致——加 amll 之后这两句曾经停在"五个源"没跟上,
// 纯靠人肉截图发现,而上面几个 Test 都不会替它报警(它们守的是"某个源漏挂在某个清单里",
// 不是"某句文案里的数字过期了")。现在这两句改成不带数字的「启用的歌词源……」(用户关掉几个源时
// 写全部源数本来就不对),没有数字就没有可过期的;这里守的是以后谁再把数字写回来时它得对。
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
	// 只看界面文案(L10n.t 的键),注释里记着的旧措辞不算。
	re := regexp.MustCompile(`L10n\.t\("([一二三四五六七八九十]+)个源(都没找到可用的候选|的请求全部失败)`)
	for _, m := range re.FindAllStringSubmatch(string(raw), -1) {
		if m[1] != digit {
			t.Errorf("%s 里的 %q 写的是%s个源,实际源数量是 %d(%s个)——改成不带数字,或者跟着改数字",
				p, m[0][len(`L10n.t("`):], m[1], n, digit)
		}
	}
}

// 面向用户 / 面向维护者的几处"一共几个源"必须跟常量表对齐——加咪咕时只改了上面
// selftest 钉住的两句文案和 README 三处,漏了 01 章、09 章标题、14 章、引擎一条日志里写死的
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

	// README 的文案常改,改措辞不该碰到测试,所以这里不找固定句子:扫出每一处「数字 + 歌词源」,要求每一处都是
	// 现在的数量,且每份至少两处(简介、功能列表、隐私说明里各写了一次)。「一个歌词源都没启用」「no lyric
	// sources enabled」这类不是在报数量:英文那句正则不收,中文单独一个「一」跳过(字符集里得留着「一」,
	// 不然「十一个歌词源」整个认不出来)。
	readmes := []struct {
		path string
		re   *regexp.Regexp
		want string
	}{
		{"../README.md", regexp.MustCompile(`(?i)\b(five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|\d+) lyrics? sources?\b`), strings.ToLower(en)},
		{"../README.zh-CN.md", regexp.MustCompile(`([一二三四五六七八九十]+|\d+)个歌词源`), zh},
		{"../README.zh-Hant.md", regexp.MustCompile(`([一二三四五六七八九十]+|\d+)個歌詞來?源`), zh},
	}
	for _, r := range readmes {
		raw, err := os.ReadFile(r.path)
		if err != nil {
			t.Errorf("读不到 %s: %v", r.path, err)
			continue
		}
		var found [][]string
		for _, m := range r.re.FindAllStringSubmatch(string(raw), -1) {
			if m[1] != "一" {
				found = append(found, m)
			}
		}
		if len(found) < 2 {
			t.Errorf("%s 里只认出 %d 处写着歌词源数量的地方(至少该有 2 处)——措辞改得认不出来了,调这里的正则", r.path, len(found))
		}
		for _, m := range found {
			if got := strings.ToLower(m[1]); got != r.want && got != strconv.Itoa(n) {
				t.Errorf("%s 里的 %q 写的是 %s,源数量是 %d——这处的数字要跟着改", r.path, m[0], m[1], n)
			}
		}
	}
}

// 热重读不许保留任何字段的旧值:App 侧改设置不再重启引擎(EngineRestartPolicy 已删),
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
