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
		lyricSourceKuwo,
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
	full := resolveLyricsSources(nil, nil, nil, nil)
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
	old := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil)
	if !old[lyricSourceAMLL] {
		t.Error("老配置(amll_lyrics 缺失)应当把 amll 补进启用集合")
	}
	if !old[lyricSourceLyricFind] {
		t.Error("老配置(lyricfind_lyrics 缺失)应当把 lyricfind 补进启用集合——这正是 2026-08-25 实测复现过的那个 bug")
	}
	if !old[lyricSourceKuwo] {
		t.Error("老配置(kuwo_lyrics 缺失)应当把 kuwo 补进启用集合")
	}
	no := false
	statedAMLL := resolveLyricsSources([]string{"netease", "qq"}, &no, nil, nil)
	if statedAMLL[lyricSourceAMLL] {
		t.Error("用户已表态(amll_lyrics=false)时不该再把 amll 补回来")
	}
	if !statedAMLL[lyricSourceLyricFind] {
		t.Error("amll 已表态不影响 lyricfind 的迁移——lyricfind_lyrics 仍缺失时应该照常补它")
	}
	if !statedAMLL[lyricSourceKuwo] {
		t.Error("amll 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	statedLF := resolveLyricsSources([]string{"netease", "qq"}, nil, &no, nil)
	if statedLF[lyricSourceLyricFind] {
		t.Error("用户已表态(lyricfind_lyrics=false)时不该再把 lyricfind 补回来")
	}
	if !statedLF[lyricSourceAMLL] {
		t.Error("lyricfind 已表态不影响 amll 的迁移——amll_lyrics 仍缺失时应该照常补它")
	}
	if !statedLF[lyricSourceKuwo] {
		t.Error("lyricfind 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	statedKuwo := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, &no)
	if statedKuwo[lyricSourceKuwo] {
		t.Error("用户已表态(kuwo_lyrics=false)时不该再把 kuwo 补回来")
	}
	if !statedKuwo[lyricSourceAMLL] {
		t.Error("kuwo 已表态不影响 amll 的迁移——amll_lyrics 仍缺失时应该照常补它")
	}
	if !statedKuwo[lyricSourceLyricFind] {
		t.Error("kuwo 已表态不影响 lyricfind 的迁移——lyricfind_lyrics 仍缺失时应该照常补它")
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
	re := regexp.MustCompile(`(?m)^\s*case\s+(netease[^\n]*)$`)
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
	chineseDigits := map[int]string{5: "五", 6: "六", 7: "七", 8: "八", 9: "九"}
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
