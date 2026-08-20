package main

import "testing"

// lyricSourceArtistMatches:歌词源采纳闸的段集交集档。核心案例来自「wherever u r」
// (2026-08-20):本地标签 "UMI & 金泰亨",酷狗署名 "UMI、V"、QQ 署名 "UMI/V",原
// artistMatches 全拒——服务端明明召回成功,正主死在客户端闸门上。
func TestLyricSourceArtistMatches(t *testing.T) {
	cases := []struct {
		candidate, query string
		want             bool
	}{
		// 本案三源的真实署名形态:两侧都是多credit,共享 "umi" 段。
		{"UMI、V", "UMI & 金泰亨", true},
		{"UMI/V", "UMI & 金泰亨", true},
		{"UMI, V", "UMI & 金泰亨", true},
		// 纯英文双人串、分隔符不同——原 artistMatches 同样拒,交集档放行。
		{"UMI、V", "UMI & V", true},
		// 原有语义必须原样保留:单人查询命中候选的一段。
		{"UMI/V", "UMI", true},
		{"UMI", "UMI & 金泰亨", true},
		// 完全相等/大小写。
		{"umi & 金泰亨", "UMI & 金泰亨", true},
		// 防仿冒守卫:尾随分隔符只切出 1 段,进不了交集档(artistCreditParts 的 len<2 约定)。
		{"周杰伦、", "周杰伦 & 王力宏", false},
		{"周杰伦、", "周杰伦", false},
		// 加符号仿冒:段级字节相等,不做 normLoose/子串,老洞不重开。
		{"周杰伦-", "周杰伦 & 王力宏", false},
		// 两侧多credit但没有任何一段相等。
		{"anna & bob", "an & bobby", false},
		// 空串。
		{"", "UMI & 金泰亨", false},
		{"UMI、V", "", false},
	}
	for _, c := range cases {
		if got := lyricSourceArtistMatches(c.candidate, c.query); got != c.want {
			t.Errorf("lyricSourceArtistMatches(%q, %q) = %v, want %v", c.candidate, c.query, got, c.want)
		}
	}
}

// lyricPrimaryQueryArtist:首歌手检索变体的生成(纯函数部分,不含别名/MB 网络查询)。
func TestLyricPrimaryQueryArtist(t *testing.T) {
	cases := []struct {
		artist, want string
	}{
		{"UMI & 金泰亨", "UMI"},
		{"陶喆、卢广仲", "陶喆"},
		{"Prince & The Revolution", "Prince"},
		// 词级 feat 分隔(rune 级分隔符集不认识的形态)。
		{"UMI feat. V", "UMI"},
		{"UMI ft V", "UMI"},
		{"IU (feat. SUGA)", "IU"},
		{"IU（feat. SUGA）", "IU"},
		{"Beyoncé featuring Jay-Z", "Beyoncé"},
		// 单人:没有变体可言。
		{"Taylor Swift", ""},
		{"周杰伦", ""},
		{"", ""},
		// 尾随分隔符的仿冒形态:只切出 1 段,规整后与原串无差别 → 无变体。
		{"周杰伦、", ""},
		// "with"/"x" 刻意不当作分隔词:真实艺名的常见组成部分。
		{"Sleeping With Sirens", ""},
		{"Charli xcx", ""},
		// 艺名自含 "ft" 字样但非独立词:不受影响。
		{"Softest Hard", ""},
		// 整串被 feat 词砍空(F.T. Island 这类):宁可不试也不发错词。
		{"FT Island", ""},
		// 人名自含分隔符(K/DA 案的形态):会产出 "K" 变体——只作检索词,采纳仍要过
		// 标题/时长/歌手闸,且只在可用来源 <2 时才发出去。
		{"K/DA", "K"},
	}
	for _, c := range cases {
		if got := lyricPrimaryQueryArtist(c.artist); got != c.want {
			t.Errorf("lyricPrimaryQueryArtist(%q) = %q, want %q", c.artist, got, c.want)
		}
	}
}

func TestUsableLyricSourceCount(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "netease", Score: 462},
		{Source: "netease", Score: 52}, // 同源第二条不重复计数
		{Source: "qq", Score: -1},      // 判废不算
		{Source: "kugou", Score: 0},    // 0 分也算可用(Score>=0)
		{Source: "lrclib", Score: -1, Instrumental: true}, // 纯音乐标记不算
	}
	if got := usableLyricSourceCount(scored); got != 2 {
		t.Errorf("usableLyricSourceCount = %d, want 2", got)
	}
	if got := usableLyricSourceCount(nil); got != 0 {
		t.Errorf("usableLyricSourceCount(nil) = %d, want 0", got)
	}
}

// mergeLyricCandidateRounds:按源去重(原串轮优先/判废才顶替)+ 合并后统一重打分。
func TestMergeLyricCandidateRounds(t *testing.T) {
	timed := "[00:01.00] line one\n[00:05.00] line two\n[00:09.00] line three"
	timedAlt := "[00:01.20] line one\n[00:05.10] line two\n[00:09.30] line three"
	base := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: timed, Score: 400, Title: "base-netease"},
		{Source: "qq", Lyrics: "no timestamps here", Score: -1, Title: "base-qq-rejected"},
		{Source: "lrclib", Score: -1, Instrumental: true},
	}
	extra := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: timedAlt, Score: 999, Title: "extra-netease"},
		{Source: "qq", Lyrics: timedAlt, Score: 300, Title: "extra-qq"},
		{Source: "kugou", Lyrics: timed, Score: 500, Title: "extra-kugou"},
	}
	merged := mergeLyricCandidateRounds("someone & 别人", "song", "album", 0, base, extra)

	bySource := map[string]scoredLyricCandidateResult{}
	instrumentalKept := false
	for _, r := range merged {
		if r.Instrumental {
			instrumentalKept = true
			continue
		}
		if _, dup := bySource[r.Source]; dup {
			t.Errorf("merge produced duplicate source %q", r.Source)
		}
		bySource[r.Source] = r
	}
	// 原串轮可用的源不被变体轮顶替(哪怕变体轮同源分更高)。
	if got := bySource["netease"].Title; got != "base-netease" {
		t.Errorf("netease candidate = %q, want base round's (base-netease)", got)
	}
	// 原串轮判废、变体轮可用 → 顶替。
	if got := bySource["qq"].Title; got != "extra-qq" {
		t.Errorf("qq candidate = %q, want extra round's (extra-qq)", got)
	}
	// 变体轮新增的源并入。
	if _, ok := bySource["kugou"]; !ok {
		t.Errorf("kugou candidate from variant round missing")
	}
	// 合并后统一重打分:可用候选的分数是重算的(带时间戳的候选 >=0),不是原轮旧值。
	for _, s := range []string{"netease", "qq", "kugou"} {
		if bySource[s].Score < 0 {
			t.Errorf("%s rescored to %d, want >= 0", s, bySource[s].Score)
		}
		if len(bySource[s].ScoreTerms) == 0 {
			t.Errorf("%s missing rescored ScoreTerms", s)
		}
	}
	// 合并后没有真实 lrclib 候选 → Instrumental 标记保留。
	if !instrumentalKept {
		t.Errorf("lrclib instrumental marker dropped, want kept")
	}
	// 排序:分数降序。
	for i := 1; i < len(merged); i++ {
		if merged[i-1].Score < merged[i].Score {
			t.Errorf("merged not sorted: %d before %d", merged[i-1].Score, merged[i].Score)
		}
	}

	// 真实 lrclib 候选在场时,Instrumental 标记不再保留。
	extraWithLrclib := append(extra, scoredLyricCandidateResult{Source: "lrclib", Lyrics: timed, Score: 200, Title: "extra-lrclib"})
	merged2 := mergeLyricCandidateRounds("someone & 别人", "song", "album", 0, base, extraWithLrclib)
	for _, r := range merged2 {
		if r.Instrumental {
			t.Errorf("instrumental marker kept although a real lrclib candidate exists")
		}
	}
}
