package main

import "testing"

func TestKKBOXAliasVariant(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"田馥甄", "田馥甄 (Hebe)", true},
		{"Taylor Swift (泰勒絲)", "Taylor Swift", true},
		{"Taylor Swift, Ed Sheeran", "Taylor Swift (泰勒絲), Ed Sheeran", true},
		{"Taylor Swift, Ed Sheeran", "Taylor Swift (泰勒絲), Future", false}, // 后面的歌手不一样
		{"五月天", "五月天 (Mayday), 孫燕姿", false},
		{"田馥甄", "田馥甄", false},
		{"田馥甄", "田馥甄Hebe", false},   // 不是括号别名
		{"田馥甄", "田馥甄 (Hebe", false}, // 括号没收尾
		{"", " (x)", false},
		{"李承隆 Tzo", "Various Artists", false},
	}
	for _, c := range cases {
		if got := kkboxAliasVariant(c.a, c.b); got != c.want {
			t.Errorf("%q vs %q: got %v want %v", c.a, c.b, got, c.want)
		}
	}
}

// 预取按列表里的写法解析过了,KKBOX 报的是带括号别名的那种:整份搬过来、不再解析,出处记成复用。
func TestTrackEnrichmentReusesKKBOXAliasSibling(t *testing.T) {
	sib := enrichKey("田馥甄", "小幸運", "我的少女時代")
	setUpEnrichEditTest(t, map[string]enrichEntry{sib: {
		Lyrics: "[00:01.00]line", LyricsSource: "kugou", LyricsScore: 900, CoverURL: "https://example.invalid/c.jpg",
		LyricsDecisionApplied: &lyricsDecision{Path: lyricsDecisionPathFirstResolve, Winner: "kugou"},
	}})
	fields := trackEnrichment("田馥甄 (Hebe)", "小幸運", "我的少女時代", kkboxBundleID, 265, true, false)
	if fields == nil {
		t.Fatal("有另一种写法的那条:当场返回,不等首次解析")
	}
	key := enrichKey("田馥甄 (Hebe)", "小幸運", "我的少女時代")
	e, ok := cacheEntry(t, key)
	if !ok || e.Lyrics != "[00:01.00]line" || e.CoverURL != "https://example.invalid/c.jpg" {
		t.Fatalf("整份搬到播放的 key 下: ok=%v %+v", ok, e)
	}
	d := e.LyricsDecisionApplied
	if d == nil || d.Path != lyricsDecisionPathArtistAliasReuse || d.ReusedFrom != sib || d.Winner != "kugou" {
		t.Fatalf("出处记成复用: %+v", d)
	}
	enrichMu.Lock()
	_, inflight := enrichInflight[key]
	enrichMu.Unlock()
	if inflight {
		t.Error("搬过来了就不该再起首次解析")
	}
	if src, _ := cacheEntry(t, sib); src.LyricsDecisionApplied.Path != lyricsDecisionPathFirstResolve {
		t.Error("来源那条不动")
	}
}

func TestKKBOXAliasSiblingGates(t *testing.T) {
	withLyrics := enrichKey("田馥甄", "小幸運", "我的少女時代")
	noLyrics := enrichKey("Taylor Swift", "Lover", "Lover")
	setUpEnrichEditTest(t, map[string]enrichEntry{
		withLyrics: {Lyrics: "[00:01.00]line"},
		noLyrics:   {},
	})
	enrichMu.Lock()
	defer enrichMu.Unlock()
	key := enrichKey("田馥甄 (Hebe)", "小幸運", "我的少女時代")
	if got, ok := kkboxAliasSiblingLocked(key, kkboxBundleID); !ok || got != withLyrics {
		t.Errorf("KKBOX、只差括号别名、有歌词:找得到,得到 %q %v", got, ok)
	}
	if _, ok := kkboxAliasSiblingLocked(key, "com.apple.Music"); ok {
		t.Error("别的播放器不找")
	}
	if _, ok := kkboxAliasSiblingLocked(enrichKey("田馥甄 (Hebe)", "小幸運", "另一張專輯"), kkboxBundleID); ok {
		t.Error("专辑不一样不算")
	}
	if _, ok := kkboxAliasSiblingLocked(enrichKey("田馥甄 (Hebe)", "寂寞寂寞就好", "我的少女時代"), kkboxBundleID); ok {
		t.Error("歌名不一样不算")
	}
	if _, ok := kkboxAliasSiblingLocked(enrichKey("Taylor Swift (泰勒絲)", "Lover", "Lover"), kkboxBundleID); ok {
		t.Error("那条没有歌词:照常首次解析(按这种写法可能搜得到)")
	}
}
