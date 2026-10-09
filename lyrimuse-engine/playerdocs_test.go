package main

import (
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// 对外文档里列着支持哪些播放器、一共几个(docs/features/16 第 7 节):三份 README、llms.txt、对比页。接新播放器时
// 这几处最容易漏,KKBOX 接入时对比页就整个没改。播放器和它们在各语言里的名字从 shared/players.json 和
// Localizable.xcstrings 取,跟 App 里显示的是同一份。
//
// 跟歌词源那条(TestDocsSourceCountMatchesSourceCount)一样,数量不找固定句子:扫出每一处「数字 + 播放器」,要求
// 都是现在的数量;「其它 N 个」是不用「自动化」权限的那几家(这几份 README 里「其它 / other + 数字」只这么用)。
// 完整名单只核引导向导那一句:三份 README 都在那里把全部播放器列了一遍。
func TestDocsListEveryPlayer(t *testing.T) {
	type player struct {
		ID          string            `json:"id"`
		DisplayName map[string]string `json:"displayName"`
		Automation  *bool             `json:"needsAutomationPermission"`
	}
	var spec struct {
		Players []player `json:"players"`
	}
	readJSON(t, "../shared/players.json", &spec)
	var catalog struct {
		Strings map[string]struct {
			Localizations map[string]struct {
				StringUnit struct {
					Value string `json:"value"`
				} `json:"stringUnit"`
			} `json:"localizations"`
		} `json:"strings"`
	}
	readJSON(t, "../lyrimuse/Localization/Localizable.xcstrings", &catalog)

	// 各语言的名字:literal 原样;l10n 的键就是简体,英文、繁体取 xcstrings 里的译文。
	var en, zhHans, zhHant []string
	automation := 0
	for _, p := range spec.Players {
		if p.ID == playerAuto {
			continue
		}
		if p.Automation != nil && *p.Automation {
			automation++
		}
		if name := p.DisplayName["literal"]; name != "" {
			en, zhHans, zhHant = append(en, name), append(zhHans, name), append(zhHant, name)
			continue
		}
		key := p.DisplayName["l10n"]
		tr := catalog.Strings[key].Localizations
		if tr["en"].StringUnit.Value == "" || tr["zh-Hant"].StringUnit.Value == "" {
			t.Fatalf("%s 的名字 %q 在 Localizable.xcstrings 里缺英文或繁体译文", p.ID, key)
		}
		en, zhHans, zhHant = append(en, tr["en"].StringUnit.Value), append(zhHans, key), append(zhHant, tr["zh-Hant"].StringUnit.Value)
	}
	n := len(en)
	if n == 0 {
		t.Fatal("shared/players.json 里一个播放器都没读出来")
	}
	enWords := []string{"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
		"eleven", "twelve", "thirteen", "fourteen", "fifteen"}
	zhDigits := []string{"零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
		"十一", "十二", "十三", "十四", "十五"}
	if n >= len(enWords) {
		t.Fatalf("播放器数量是 %d,没有对应的中英数字——请在两张表里补上再跑这个测试", n)
	}
	enNum := `(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|\d+)`
	zhNum := `([一二三四五六七八九十]+|\d+)`

	readmes := []struct {
		path           string
		count, others  *regexp.Regexp
		wizard, orAuto string
		sep            string
		names          []string
		word           func(int) string
	}{
		{"../README.md", regexp.MustCompile(`(?i)\b` + enNum + ` players\b`), regexp.MustCompile(`(?i)\bother ` + enNum + `\b`),
			"picking a player (", ", or ", ", ", en, func(i int) string { return enWords[i] }},
		{"../README.zh-CN.md", regexp.MustCompile(zhNum + `[款个]播放器`), regexp.MustCompile(`其[它他]` + zhNum + `个`),
			"选一个播放器（", "，或者", "、", zhHans, func(i int) string { return zhDigits[i] }},
		{"../README.zh-Hant.md", regexp.MustCompile(zhNum + `[款個]播放器`), regexp.MustCompile(`其[它他]` + zhNum + `個`),
			"選播放器（", "，或者", "、", zhHant, func(i int) string { return zhDigits[i] }},
	}
	for _, r := range readmes {
		text := readText(t, r.path)
		// 数量。中文单独一个「一」是「选一个播放器」这类,不是在报数量(字符集里得留着「一」,不然「十一」认不出来)。
		for _, check := range []struct {
			re   *regexp.Regexp
			want int
			what string
			min  int
		}{
			{r.count, n, "播放器数量", 2},
			{r.others, n - automation, "不用「自动化」权限的播放器数量", 1},
		} {
			found := 0
			for _, m := range check.re.FindAllStringSubmatch(text, -1) {
				if m[1] == "一" {
					continue
				}
				found++
				if got := strings.ToLower(m[1]); got != r.word(check.want) && got != strconv.Itoa(check.want) {
					t.Errorf("%s 里的 %q 写的是 %s,%s是 %d——这处的数字要跟着改", r.path, m[0], m[1], check.what, check.want)
				}
			}
			if found < check.min {
				t.Errorf("%s 里只认出 %d 处写着%s的地方(至少该有 %d 处)——措辞改得认不出来了,调这里的正则", r.path, found, check.what, check.min)
			}
		}
		// 引导向导那一句的完整名单:「(甲、乙、…,或者自动识别)」。
		start := strings.Index(text, r.wizard)
		if start < 0 {
			t.Errorf("%s 里没找到引导向导那一句(%q)——措辞改了就跟着改这里", r.path, r.wizard)
			continue
		}
		list, _, ok := strings.Cut(text[start+len(r.wizard):], r.orAuto)
		if !ok || strings.Contains(list, "\n") {
			t.Errorf("%s 引导向导那一句的名单没以 %q 收尾", r.path, r.orAuto)
			continue
		}
		if listed := strings.Split(list, r.sep); !sameNames(listed, r.names) {
			t.Errorf("%s 引导向导那一句列的是 %v,播放器是 %v", r.path, listed, r.names)
		}
	}

	// 功能清单:三种语言写在 shared/feature-list.json 一份里(docs/feature-list*.md 由它生成),每种写法各核一遍数量。
	featureList := readText(t, "../shared/feature-list.json")
	for _, r := range readmes {
		found := 0
		for _, m := range r.count.FindAllStringSubmatch(featureList, -1) {
			if m[1] == "一" {
				continue
			}
			found++
			if got := strings.ToLower(m[1]); got != r.word(n) && got != strconv.Itoa(n) {
				t.Errorf("shared/feature-list.json 里的 %q 写的是 %s,播放器数量是 %d——改完再跑 scripts/gen-feature-list.py", m[0], m[1], n)
			}
		}
		if found == 0 {
			t.Errorf("shared/feature-list.json 里认不出写着播放器数量的地方(按 %s 那种写法)——措辞改了就调这里的正则", r.path)
		}
	}

	// llms.txt 的简介行、对比页「支持的播放器」那一行。这两处把「酷狗音乐」写成「酷狗」,名字尾巴上的
	// 「音乐 / Music」可以省。
	mentions := func(text, name string) bool {
		short := strings.TrimSpace(strings.TrimSuffix(strings.TrimSuffix(name, " Music"), "音乐"))
		return strings.Contains(text, name) || strings.Contains(text, short)
	}
	lines := []struct {
		path, prefix string
		names        []string
	}{
		{"../llms.txt", "> ", en},
		{"../docs/lyrics-apps-comparison.md", "| Players |", en},
		{"../docs/lyrics-apps-comparison.zh-CN.md", "| 支持的播放器 |", zhHans},
	}
	for _, l := range lines {
		var line string
		for _, s := range strings.Split(readText(t, l.path), "\n") {
			if strings.HasPrefix(s, l.prefix) {
				line = s
				break
			}
		}
		if line == "" {
			t.Errorf("%s 里没找到以 %q 开头的那一行——措辞改了就跟着改这里", l.path, l.prefix)
			continue
		}
		if cells := strings.Split(line, "|"); strings.HasPrefix(l.prefix, "|") && len(cells) > 2 {
			line = cells[2] // 表格只看 Lyrimuse 那一格,别的 App 那几格也会写到 Spotify、Apple Music
		}
		for _, name := range l.names {
			if !mentions(line, name) {
				t.Errorf("%s 列支持的播放器那一行没有 %s", l.path, name)
			}
		}
	}
}

func readText(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读不到 %s: %v", path, err)
	}
	return string(raw)
}

// sameNames:两份名单是同一批名字(顺序不论)。
func sameNames(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	seen := map[string]int{}
	for _, s := range a {
		seen[strings.TrimSpace(s)]++
	}
	for _, s := range b {
		if seen[s]--; seen[s] < 0 {
			return false
		}
	}
	return true
}
