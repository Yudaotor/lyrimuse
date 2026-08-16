package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoosenEnrichKey(t *testing.T) {
	cases := []struct {
		name string
		a, b string
		same bool
	}{
		// 用户 2026-08-16 实际报的那两组
		{"半角空格", "陶喆|Susan 说|太平盛世", "陶喆|Susan说|太平盛世", true},
		{"中英之间空格", "陶喆|Sula 与 Lampa 的寓言|太平盛世", "陶喆|Sula 与 Lampa的寓言|太平盛世", true},
		// 繁简(12 组里的代表),歌名和歌手名两处都要能折
		{"歌名繁简", "方大同|千纸鹤|回到未來", "方大同|千紙鶴|回到未來", true},
		{"歌手名繁简", "孙燕姿|我懷念的|逆光", "孫燕姿|我懷念的|逆光", true},
		{"大小写", "PRINCE|Kiss|Parade", "Prince|Kiss|Parade", true},

		// ⚠️ 下面这些**必须**判为不同。宽松键是纯减法(删空格/统一大小写字形),
		// 删不掉任何区分版本的字符,所以结构上不可能把"一首歌"和"它+额外内容"并到一起。
		{"版本括号", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说(Music鉴赏版)|太平盛世", false},
		{"不同专辑", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说|黑色柳丁", false},
		{"不同歌手", "陶喆|Susan 说|太平盛世", "王力宏|Susan 说|太平盛世", false},
		{"Live 版", "周杰伦|晴天|叶惠美", "周杰伦|晴天 (Live)|叶惠美", false},
		{"数字不同", "群星|1 2 3|合辑", "群星|1 2 4|合辑", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := loosenEnrichKey(c.a) == loosenEnrichKey(c.b)
			if got != c.same {
				t.Errorf("loosenEnrichKey(%q)==loosenEnrichKey(%q) = %v, want %v\n  a→%q\n  b→%q",
					c.a, c.b, got, c.same, loosenEnrichKey(c.a), loosenEnrichKey(c.b))
			}
		})
	}
}

// 「1 2 3」和「123」这类只差空格的**不同**歌名会被判为同一首 —— 这是这套宽松归并已知且
// 接受的代价,钉下来免得以后有人当成回归 bug 去"修"。
//
// 为什么接受:三段 key 必须**同时**只差空白/字形才会被并,而歌手名和专辑名同时也吻合的
// 前提下,「1 2 3」和「123」几乎不可能是同一张专辑里的两首不同歌。真出现了,代价是两条
// 歌词并成一条(可以手动重搜),而收紧规则的代价是用户天天看着重复条目。
func TestLoosenEnrichKeyKnownFalsePositive(t *testing.T) {
	a, b := "群星|1 2 3|合辑", "群星|123|合辑"
	if loosenEnrichKey(a) != loosenEnrichKey(b) {
		t.Fatalf("这条断言是用来记录已知代价的;若实现改成不再折叠它,请一并更新这段注释")
	}
}

func TestPlanDedupeKeepsWinnerOriginalKey(t *testing.T) {
	cache := map[string]enrichEntry{
		// 分数高的那条该胜出,而胜出后落盘的 key 必须还是它**原来的**写法,
		// 不能变成分组用的宽松键 `陶喆|susan说|太平盛世`。
		"陶喆|Susan 说|太平盛世": {Lyrics: "a", LyricsScore: 1271},
		"陶喆|Susan说|太平盛世":  {Lyrics: "b", LyricsScore: 1274},
		// 版本不同,绝不能进同一组
		"陶喆|Susan 说(Music鉴赏版)|太平盛世": {Lyrics: "c", LyricsScore: 1269},
		// 单独一条,不该出现在计划里
		"孙燕姿|逆光|逆光": {Lyrics: "d", LyricsScore: 900},
	}
	plan := planDedupe(cache)
	if len(plan.groups) != 1 {
		t.Fatalf("groups = %d, want 1: %+v", len(plan.groups), plan.groups)
	}
	g := plan.groups[0]
	// 内容取分数更高的那条…
	if g.source != "陶喆|Susan说|太平盛世" {
		t.Errorf("source = %q, want 陶喆|Susan说|太平盛世(分数更高的那条)", g.source)
	}
	// …但显示取带空格的写法(等价 key 之间更长的那个就是有空格的那个)。
	if g.winner != "陶喆|Susan 说|太平盛世" {
		t.Errorf("winner = %q, want 陶喆|Susan 说|太平盛世(排版更好的写法)", g.winner)
	}
	if len(g.losers) != 1 || g.losers[0] != "陶喆|Susan说|太平盛世" {
		t.Errorf("losers = %v, want [陶喆|Susan说|太平盛世]", g.losers)
	}
	// 胜者 key 必须是缓存里真实存在的原始写法
	if _, ok := cache[g.winner]; !ok {
		t.Errorf("winner %q 不是缓存里的原始 key —— 落盘会写出一个谁都不这么写的串", g.winner)
	}
}

func TestPlanDedupeIsDeterministic(t *testing.T) {
	// 三条同组(孙燕姿那组的真实形状),且分数完全相同 —— 逼出"并列时选谁"这条路径。
	// map 遍历顺序随机,跑很多次都必须得到同一个胜者。
	cache := map[string]enrichEntry{
		"孙燕姿|我怀念的|逆光": {Lyrics: "a", LyricsScore: 1000},
		"孙燕姿|我懷念的|逆光": {Lyrics: "b", LyricsScore: 1000},
		"孫燕姿|我懷念的|逆光": {Lyrics: "c", LyricsScore: 1000},
	}
	first := planDedupe(cache)
	if len(first.groups) != 1 || len(first.groups[0].losers) != 2 {
		t.Fatalf("期望 1 组 2 个落败者,得到 %+v", first.groups)
	}
	for i := 0; i < 200; i++ {
		got := planDedupe(cache)
		if got.groups[0].winner != first.groups[0].winner {
			t.Fatalf("第 %d 次胜者变成 %q(首次是 %q)—— 并列时的选择必须是确定的",
				i, got.groups[0].winner, first.groups[0].winner)
		}
	}
}

func TestResolveStaleFilesNeverTouchesWinner(t *testing.T) {
	dir := t.TempDir()
	old := lyricsDir
	lyricsDir = dir
	t.Cleanup(func() { lyricsDir = old })

	winner := "陶喆|Susan说|太平盛世"
	loser := "陶喆|Susan 说|太平盛世"
	// 两边的导出文件都造出来
	for _, k := range []string{winner, loser} {
		for _, name := range enrichExportedFileNames(k) {
			p := filepath.Join(dir, name)
			if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	plan := dedupePlan{groups: []dedupeGroup{{winner: winner, source: winner, losers: []string{loser}}}}
	stale := resolveStaleFiles(plan)
	if len(stale) == 0 {
		t.Fatal("落败条目的导出文件一个都没列出来 —— 不删的话下次启动会把它导回来")
	}
	winnerNames := map[string]bool{}
	for _, n := range enrichExportedFileNames(winner) {
		winnerNames[n] = true
	}
	for _, f := range stale {
		if winnerNames[filepath.Base(f)] {
			t.Errorf("胜者的导出文件 %q 出现在待删清单里", filepath.Base(f))
		}
	}
}

// 空目录下不该凭空列出文件(只列**确实存在**的,不按名字硬猜)。
func TestResolveStaleFilesOnlyExisting(t *testing.T) {
	dir := t.TempDir()
	old := lyricsDir
	lyricsDir = dir
	t.Cleanup(func() { lyricsDir = old })

	plan := dedupePlan{groups: []dedupeGroup{{
		winner: "陶喆|Susan说|太平盛世",
		source: "陶喆|Susan说|太平盛世",
		losers: []string{"陶喆|Susan 说|太平盛世"},
	}}}
	if got := resolveStaleFiles(plan); len(got) != 0 {
		t.Errorf("空目录下列出了 %v", got)
	}
}

func TestPickDisplayKeyPrefersSimplifiedThenSpaced(t *testing.T) {
	cases := []struct {
		name string
		keys []string
		want string
	}{
		{
			"简体优先于繁体",
			[]string{"方大同|千紙鶴|回到未來", "方大同|千纸鹤|回到未來"},
			"方大同|千纸鹤|回到未來",
		},
		{
			"歌手名也算",
			[]string{"孫燕姿|我懷念的|逆光", "孙燕姿|我懷念的|逆光", "孙燕姿|我怀念的|逆光"},
			"孙燕姿|我怀念的|逆光",
		},
		{
			"同为简体时取有空格的",
			[]string{"陶喆|Susan说|太平盛世", "陶喆|Susan 说|太平盛世"},
			"陶喆|Susan 说|太平盛世",
		},
		{
			"专辑名本来就是繁体也不影响(两条都非简体时仍按空格挑)",
			[]string{"丁世光|小师妹|神經志 The Journal", "丁世光|小師妹|神經志 The Journal"},
			"丁世光|小师妹|神經志 The Journal",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := pickDisplayKey(c.keys); got != c.want {
				t.Errorf("pickDisplayKey(%v) = %q, want %q", c.keys, got, c.want)
			}
		})
	}
}

// 显示 key 跟内容来源不是同一条时,winner 自己的旧导出文件必须一并删掉 —— 否则
// importLyricsFromFiles 会把它那份较差的正文当权威源读回来。
func TestResolveStaleFilesIncludesWinnerWhenContentMovedIn(t *testing.T) {
	dir := t.TempDir()
	old := lyricsDir
	lyricsDir = dir
	t.Cleanup(func() { lyricsDir = old })

	winner := "陶喆|Susan 说|太平盛世" // 显示用这条
	source := "陶喆|Susan说|太平盛世"  // 内容来自这条
	for _, k := range []string{winner, source} {
		for _, name := range enrichExportedFileNames(k) {
			if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	plan := dedupePlan{groups: []dedupeGroup{{
		winner: winner, source: source, losers: []string{source},
	}}}
	stale := resolveStaleFiles(plan)
	names := map[string]bool{}
	for _, f := range stale {
		names[filepath.Base(f)] = true
	}
	for _, n := range enrichExportedFileNames(winner) {
		if _, err := os.Stat(filepath.Join(dir, n)); err == nil && !names[n] {
			t.Errorf("winner 的旧文件 %q 没进待删清单 —— 它装的还是落败正文", n)
		}
	}
}
