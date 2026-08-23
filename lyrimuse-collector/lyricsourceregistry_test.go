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
		lyricSourceMusixmatch, lyricSourceLRCLIB, lyricSourceAMLL,
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
	full := resolveLyricsSources(nil, nil)
	for _, s := range all {
		if !full[s] {
			t.Errorf("源 %q 不在 resolveLyricsSources 的全集兜底里(全新安装会禁用它)", s)
		}
	}

	// ④ 老配置的一次性迁移:amll 缺失时补进去,已表态时尊重用户选择
	old := resolveLyricsSources([]string{"netease", "qq"}, nil)
	if !old[lyricSourceAMLL] {
		t.Error("老配置(amll_lyrics 缺失)应当把 amll 补进启用集合")
	}
	no := false
	stated := resolveLyricsSources([]string{"netease", "qq"}, &no)
	if stated[lyricSourceAMLL] {
		t.Error("用户已表态(amll_lyrics=false)时不该再把 amll 补回来")
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
