package main

import (
	"context"
	"testing"
	"time"
)

// 用例来自真实曲目榜里被拆成两条的写法,以及形状相近、不该剥的正式曲名。
func TestStripReleaseTail(t *testing.T) {
	cases := []struct {
		in, want string
		stripped bool
	}{
		{"First Love (Remastered 2014)", "First Love", true},
		{"When Doves Cry (2015 Paisley Park Remaster)", "When Doves Cry", true},
		{"Money Don't Matter 2 Night (2023 remaster)", "Money Don't Matter 2 Night", true},
		{"Linger - Remastered 2026", "Linger", true},
		{"Bad - 2012 Remaster", "Bad", true},
		{"天黑黑 - Remastered", "天黑黑", true},
		{"被遗忘的时光 (Remastered)", "被遗忘的时光", true},
		{"烦 (Explicit)", "烦", true},
		{"Song (Remastered 2014) [Explicit]", "Song", true},
		{"Something - 2011 Remastered Version", "Something", true},
		// 只剥尾巴,前面那段破折号是歌名本身
		{"Amai Wana - Paint It, Black (Remastered 2014)", "Amai Wana - Paint It, Black", true},
		// 带版本词:另一份录音 / 另一版混音
		{"Hey Jude (Live 2014 Remaster)", "Hey Jude (Live 2014 Remaster)", false},
		{"Help! (2009 Mono Remaster)", "Help! (2009 Mono Remaster)", false},
		{"Song - Remastered Single Version", "Song - Remastered Single Version", false},
		// 不是尾巴
		{"Song (Remix)", "Song (Remix)", false},
		{"Remastered Love", "Remastered Love", false},
		{"Master of Puppets", "Master of Puppets", false},
		{"飛機場的10:30 - Live", "飛機場的10:30 - Live", false},
		{"(Remastered)", "(Remastered)", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, stripped := stripReleaseTail(c.in)
		if got != c.want || stripped != c.stripped {
			t.Errorf("stripReleaseTail(%q) = %q, %v; want %q, %v", c.in, got, stripped, c.want, c.stripped)
		}
	}
}

// 带尾巴的那条本身有 mbid(再版专辑的正规条目)也改发去掉尾巴的那条:收听历史攒在那边。
func TestCatalogReleaseTailPrefersCleanEntryOverOwnMBID(t *testing.T) {
	const artist, tailed, clean = "Prince", "Diamonds and Pearls (2023 Remaster)", "Diamonds and Pearls"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, tailed): {body: trackJSON("mb-tail", 5000, 270000)},
		infoKey(artist, clean):  {body: trackJSON("mb-clean", 300000, 268000)},
	})
	a, tr, matched := col.resolve(context.Background(), artist, tailed, 270, scopeAll)
	if a != artist || tr != clean || !matched {
		t.Fatalf("resolve = %q / %q matched=%v, want %s / %s", a, tr, matched, artist, clean)
	}
	d := col.cache[infoKey(artist, tailed)]
	if d.Via != "tail" || d.Tail != lastfmCatalogTailVersion {
		t.Errorf("缓存 = %+v, want Via=tail Tail=%d", d, lastfmCatalogTailVersion)
	}
}

// 破折号式,带尾巴那条听众很多但没有 mbid:基础判定里它会赢(去尾巴的那条不在候选里),所以要先判去尾巴的写法。
func TestCatalogReleaseTailDashForm(t *testing.T) {
	const artist, tailed, clean = "The Cranberries", "Linger - Remastered 2026", "Linger"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, tailed): {body: trackJSON("", 423086, 274000)},
		infoKey(artist, clean):  {body: trackJSON("mb-linger", 1200000, 274000)},
	})
	if _, tr, _ := col.resolve(context.Background(), artist, tailed, 274, scopeAll); tr != clean {
		t.Fatalf("track = %q, want %q", tr, clean)
	}
}

// 去掉尾巴的写法编目里没有:按原样照常判(这里原样有 mbid → keep),而且去尾巴那一遍不跑扩展搜索。
func TestCatalogReleaseTailFallsBackWhenCleanMissing(t *testing.T) {
	const artist, tailed, clean = "蔡琴", "被遗忘的时光 (Remastered)", "被遗忘的时光"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, tailed): {body: trackJSON("mb-tail", 900, 0)},
		infoKey(artist, clean):  {body: notFoundJSON},
	})
	if _, tr, _ := col.resolve(context.Background(), artist, tailed, 250, scopeAll); tr != tailed {
		t.Fatalf("track = %q, want 原样 %q", tr, tailed)
	}
	if n := cs.count(searchKey(clean)); n != 0 {
		t.Errorf("去尾巴那一遍不该跑扩展搜索(track.search),却查了 %d 次", n)
	}
}

// 去掉尾巴的写法编目里有、但时长对不上(没有 mbid 撑腰):不认,按原样判。
func TestCatalogReleaseTailKeepsDurationGate(t *testing.T) {
	const artist, tailed, clean = "A", "Song (Remastered 2014)", "Song"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, tailed): {body: trackJSON("mb-tail", 900, 200000)},
		infoKey(artist, clean):  {body: trackJSON("", 90000, 320000)},
	})
	if _, tr, _ := col.resolve(context.Background(), artist, tailed, 200, scopeAll); tr != tailed {
		t.Fatalf("track = %q, want 原样 %q(时长差 120 s)", tr, tailed)
	}
}

// 不许改曲名(自定义档只改歌手)时不剥。
func TestCatalogReleaseTailRespectsScope(t *testing.T) {
	const artist, tailed, clean = "A", "Song (Remastered 2014)", "Song"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, tailed): {body: trackJSON("mb-tail", 900, 200000)},
	})
	if _, tr, _ := col.resolve(context.Background(), artist, tailed, 200, matchScope{artist: true}); tr != tailed {
		t.Fatalf("track = %q, want 原样", tr)
	}
	if n := cs.count(infoKey(artist, clean)); n != 0 {
		t.Errorf("只许改歌手时不该查去尾巴的写法,却查了 %d 次", n)
	}
}

// 带版本词的尾巴(Live)不剥,不去查去尾巴的写法。
func TestCatalogReleaseTailIgnoresLiveRemaster(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("The Beatles", "Hey Jude (Live 2014 Remaster)"): {body: trackJSON("mb-live", 9000, 0)},
	})
	col.resolve(context.Background(), "The Beatles", "Hey Jude (Live 2014 Remaster)", 0, scopeAll)
	if n := cs.count(infoKey("The Beatles", "Hey Jude")); n != 0 {
		t.Errorf("Live 版不该去查录音室版,却查了 %d 次", n)
	}
}

// 尾巴口径之前的缓存:带尾巴的曲名重判,不带尾巴的永久结论照旧(一个请求都不发)。
func TestCatalogReleaseTailRejudgesOnlyTailedCacheEntries(t *testing.T) {
	const artist, tailed, clean = "孙燕姿", "天黑黑 - Remastered", "天黑黑"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, tailed): {body: trackJSON("", 1534, 0)},
		infoKey(artist, clean):  {body: trackJSON("mb-ttt", 60000, 0)},
	})
	old := func(track string) lastfmCatalogDecision {
		return lastfmCatalogDecision{Verdict: verdictKeep, Artist: artist, Track: track, TS: time.Now().Unix(),
			V: lastfmCatalogDecisionVersion, Ext: lastfmCatalogExtVersion, Scope: scopeAll.id()}
	}
	col.cache[infoKey(artist, tailed)] = old(tailed)
	col.cache[infoKey(artist, "遇见")] = old("遇见")
	if _, tr, _ := col.resolve(context.Background(), artist, tailed, 0, scopeAll); tr != clean {
		t.Errorf("带尾巴的旧结论应重判成 %q,got %q", clean, tr)
	}
	before := cs.total()
	if _, tr, _ := col.resolve(context.Background(), artist, "遇见", 0, scopeAll); tr != "遇见" {
		t.Errorf("不带尾巴的旧结论应照旧,got %q", tr)
	}
	if n := cs.total() - before; n != 0 {
		t.Errorf("不带尾巴的旧结论不该重查,却发了 %d 个请求", n)
	}
}
