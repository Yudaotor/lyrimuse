package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// 新增歌词源时的完整性守卫。
//
// 2026-08-23 加 amll 那次的教训:源常量加好了、抓取也接上了,但**四处清单漏了**——
// resolveLyricsSources 的全集兜底(导致全新安装时它被禁用)、healthcheckcli 的探测清单、
// Swift 侧 LyricsSource 枚举(导致"顺序优先"排序列表里根本没有它、徽章显示成灰色原名)。
// 一处都不报错、全都是静默失效,只能靠人肉发现。跟 scoretermlabel_test.go 同一个路子:
// 把清单钉死在测试里,忘了补就直接红。
func allLyricSourceConstants() []string {
	return []string{
		lyricSourceNetease, lyricSourceQQ, lyricSourceKugou,
		lyricSourceMusixmatch, lyricSourceLRCLIB, lyricSourceAMLL, lyricSourceLyricFind,
		lyricSourceKuwo, lyricSourceMigu, lyricSourceDeezer,
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
	full := resolveLyricsSources(nil, nil, nil, nil, nil, nil)
	for _, s := range all {
		if !full[s] {
			t.Errorf("源 %q 不在 resolveLyricsSources 的全集兜底里(全新安装会禁用它)", s)
		}
	}

	// ④ 老配置的一次性迁移:amll/lyricfind/kuwo 各自的迁移标记缺失时补进去,已表态时
	// 尊重用户选择。这条不是补测——2026-08-25 实测坐实过:漏了迁移标记参数那版代码在真实
	// 机器上跑,这台机器 lyrics_sources 里只有旧的六个源、没有对应迁移字段,
	// search-lyrics 的 sourcesTotal 停在 6、候选列表里一条新源都没有。这里钉死
	// 的正是当时复现过的那个场景(见 resolveLyricsSources 里对应的注释)。
	old := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, nil, nil)
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
	no := false
	statedAMLL := resolveLyricsSources([]string{"netease", "qq"}, &no, nil, nil, nil, nil)
	if statedAMLL[lyricSourceAMLL] {
		t.Error("用户已表态(amll_lyrics=false)时不该再把 amll 补回来")
	}
	if !statedAMLL[lyricSourceLyricFind] {
		t.Error("amll 已表态不影响 lyricfind 的迁移——lyricfind_lyrics 仍缺失时应该照常补它")
	}
	if !statedAMLL[lyricSourceKuwo] {
		t.Error("amll 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	statedLF := resolveLyricsSources([]string{"netease", "qq"}, nil, &no, nil, nil, nil)
	if statedLF[lyricSourceLyricFind] {
		t.Error("用户已表态(lyricfind_lyrics=false)时不该再把 lyricfind 补回来")
	}
	if !statedLF[lyricSourceAMLL] {
		t.Error("lyricfind 已表态不影响 amll 的迁移——amll_lyrics 仍缺失时应该照常补它")
	}
	if !statedLF[lyricSourceKuwo] {
		t.Error("lyricfind 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	statedKuwo := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, &no, nil, nil)
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
	statedMigu := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, &no, nil)
	if statedMigu[lyricSourceMigu] {
		t.Error("用户已表态(migu_lyrics=false)时不该再把 migu 补回来")
	}
	if !statedMigu[lyricSourceKuwo] {
		t.Error("migu 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	if !statedMigu[lyricSourceDeezer] {
		t.Error("migu 已表态不影响 deezer 的迁移——deezer_lyrics 仍缺失时应该照常补它")
	}
	statedDeezer := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, nil, &no)
	if statedDeezer[lyricSourceDeezer] {
		t.Error("用户已表态(deezer_lyrics=false)时不该再把 deezer 补回来")
	}
	if !statedDeezer[lyricSourceMigu] {
		t.Error("deezer 已表态不影响 migu 的迁移——migu_lyrics 仍缺失时应该照常补它")
	}
}

// 并发收集那个循环的次数、以及结果 channel 的缓冲,都必须**跟着源数走**,不许写字面量。
//
// 2026-09-13 接第十个源时实测坐实的坑:那行曾经是硬编码的 `for i := 0; i < 9`,而 goroutine
// 数是"源数 + 1"(多出来的是 applecover)。两个数从来没绑在一起,于是每加一个源就多丢一份
// 结果——循环先数满就退出,**最后到达的那个源的应答被直接扔掉**。当时的现象是:新接的
// deezer 明明取回了 2810 字节逐行歌词,却从没进过候选列表;`git log -S` 查下来这个字面量
// 自引入起一次都没改过,也就是说 08-31 接酷我、09-04 接咪咕时就已经在丢一份了,只是丢的
// 那份通常是 applecover 或最慢的源、没人察觉。修完同一首歌 deezer 立刻以 660 分 64 行进榜,
// 而且 lrclib 从 620 涨到 770(跨源正文共识 +150)——丢掉的从来不只是那一个源自己的候选。
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
	// ⚠️ 别按"以 netease 开头"来找这一行。枚举的**声明顺序是有语义的**(它同时是设置页九个
	// 勾选框的展示序和"顺序优先"模式的默认顺序,见 Swift 侧那段注释),排序本来就会变:
	// 2026-09-07 按实测采用率把 kugou 提到首位时,原先写死的 `case\s+(netease[^\n]*)` 当场
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
// "六个源的请求全部失败…")必须跟源的实际数量一致——2026-08-24 加 amll 之后这两句
// 曾经停在"五个源"没跟上,纯靠人肉截图发现,而上面几个 Test 都不会替它报警(它们守的是
// "某个源漏挂在某个清单里",不是"某句文案里的数字过期了")。同一份文件里,零个/一个
// 数字不用写死中文数字表——已知会用到的范围窄,给 5~9 手写映射即可,超出直接报错提醒
// 去扩表,而不是默默算错。
func TestSwiftSearchEmptyStateCountMatchesSourceCount(t *testing.T) {
	chineseDigits := map[int]string{5: "五", 6: "六", 7: "七", 8: "八", 9: "九", 10: "十"}
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

// 面向用户 / 面向维护者的几处"一共几个源"必须跟常量表对齐——2026-09-04 加咪咕时只改了上面
// selftest 钉住的两句文案和 README 三处,漏了 01 章、09 章标题、14 章、collector 一条日志里写死的
// "%d/8"(用户当天发现「歌词源数量还是 8」)。这里把**带具体数字的现状描述**钉死;其它地方从此
// 一律写"全部源 / 各源",不带数字(带日期的历史记录除外),新加源时就不会再有第二批漏网。
func TestDocsSourceCountMatchesSourceCount(t *testing.T) {
	chineseDigits := map[int]string{5: "五", 6: "六", 7: "七", 8: "八", 9: "九", 10: "十"}
	englishWords := map[int]string{5: "Five", 6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten"}
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
	for _, c := range checks {
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
