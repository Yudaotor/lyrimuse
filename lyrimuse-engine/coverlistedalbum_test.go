package main

import (
	"context"
	"image"
	"testing"
)

// 显示的专辑:写法键里的专辑,键里没有时用 YouTube Music 登记的(去掉首尾空白),都没有为空。
func TestEntryListedAlbum(t *testing.T) {
	for _, c := range []struct {
		key  string
		e    enrichEntry
		want string
	}{
		{"A|t|Album", enrichEntry{YouTubeMusicAlbum: "Other"}, "Album"},
		{"A|t|", enrichEntry{YouTubeMusicAlbum: " Listed "}, "Listed"},
		{"A|t|", enrichEntry{}, ""},
	} {
		if got := entryListedAlbum(c.key, c.e); got != c.want {
			t.Errorf("%s %+v: 得到 %q, 要 %q", c.key, c.e, got, c.want)
		}
	}
}

// 《太陽之子》那种:Kaset 放的几首写法键里没专辑,YouTube Music 登记在这张专辑下(歌词管理也排在这张专辑里),给专辑定封面时
// 跟写法键带专辑的几首算一组(歌手繁简写法不同也算):同一张图的原样记下,QQ 按歌名查回来的单曲封面换成定下的那张;
// 键里没专辑、也没登记专辑的不进组。
func TestSettleAlbumCoversIncludesListedAlbum(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	const kaset = "file:///art/kaset.jpg"
	const single = "https://y.qq.com/music/photo_new/T002R800x800M000single.jpg"
	withSettleFakes(t, map[string]image.Image{
		settleTux1: settlePicture(1, false), kaset: settlePicture(1, false), single: settlePicture(0, false),
	}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"周杰伦|西西里|太阳之子": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "太阳之子", CoverSettled: settleTux1},
		"周杰倫|聖徒|":      {CoverURL: kaset, CoverSource: "device", YouTubeMusicAlbum: "太陽之子"},
		"周杰倫|聖誕星|":     {CoverURL: single, CoverSource: "qq", CoverAlbum: "圣诞星 (feat. 杨瑞代)", YouTubeMusicAlbum: "太陽之子"},
		"周杰倫|單曲|":      {CoverURL: single, CoverSource: "qq", CoverAlbum: "圣诞星 (feat. 杨瑞代)"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 1 || settled != 2 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要 2、1", settled, switched)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["周杰倫|聖誕星|"]; e.CoverURL != settleTux1 || e.CoverSource != "netease" || e.CoverAlbum != "太阳之子" || !coverSettled(e) {
		t.Errorf("单曲封面该换成定下的那张: %+v", e)
	}
	if e := enrichCache["周杰倫|聖徒|"]; e.CoverURL != kaset || !coverSettled(e) {
		t.Errorf("同一张图的原样记下: %+v", e)
	}
	if e := enrichCache["周杰倫|單曲|"]; e.CoverURL != single || e.CoverSettled != "" {
		t.Errorf("没专辑的不进组: %+v", e)
	}
}

// 借同专辑核实过的设备封面:写法键里没专辑、登记了这张专辑的照样借,核实过的照样借出去;键里没专辑、也没登记的不借。
func TestCoverSweepBorrowVerifiedSiblingsUsesListedAlbum(t *testing.T) {
	const device = "file:///Users/x/.config/lyrimuse/artwork/album.jpg"
	withEnrichCache(t, map[string]enrichEntry{
		"A|lender|Album": {CoverURL: device, CoverSource: "device", CoverAlbum: "Album"},
		"A|listed|":      {CoverURL: "https://qq/single.jpg", CoverSource: "qq", CoverAlbum: "Single", YouTubeMusicAlbum: "Album"},
		"A|bare|":        {CoverURL: "https://qq/single.jpg", CoverSource: "qq", CoverAlbum: "Single"},
		"B|kaset|":       {CoverURL: device + "2", CoverSource: "device", CoverAlbum: "Second", YouTubeMusicAlbum: "Second"},
		"B|keyed|Second": {CoverURL: "https://qq/b.jpg", CoverSource: "qq", CoverAlbum: "Single"},
	})
	if n := coverSweepBorrowVerifiedSiblings(); n != 2 {
		t.Fatalf("换了 %d 条, 要 2", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|listed|"]; e.CoverURL != device || e.CoverSource != "device" || e.CoverAlbum != "Album" {
		t.Errorf("登记了这张专辑的该借: %+v", e)
	}
	if e := enrichCache["A|bare|"]; e.CoverURL != "https://qq/single.jpg" {
		t.Errorf("没专辑的不借: %+v", e)
	}
	if e := enrichCache["B|keyed|Second"]; e.CoverURL != device+"2" || e.CoverAlbum != "Second" {
		t.Errorf("登记了专辑的设备封面该借出去: %+v", e)
	}
}

// 按判决补封面:写法键里没专辑、登记了专辑的,封面是另一张专辑的照样换成判决胜出那个源自带、专辑对得上登记专辑的封面,
// 对不上的不换;没登记专辑的判不出是另一张专辑,不动。
func TestCoverSweepFillFromDecisionsUsesListedAlbum(t *testing.T) {
	decision := &lyricsDecision{Winner: "soda", Candidates: []lyricsDecisionCandidate{
		{Source: "soda", Score: 1310, Album: "Album", CoverURL: "https://s/1.jpg"}}}
	withEnrichCache(t, map[string]enrichEntry{
		"A|listed|": {CoverURL: "https://q/1.jpg", CoverSource: "qq", CoverAlbum: "Single", YouTubeMusicAlbum: "Album",
			LyricsDecision: decision},
		"A|bare|": {CoverURL: "https://q/1.jpg", CoverSource: "qq", CoverAlbum: "Single", LyricsDecision: decision},
		"A|else|": {CoverURL: "https://q/1.jpg", CoverSource: "qq", CoverAlbum: "Single", YouTubeMusicAlbum: "Else",
			LyricsDecision: decision},
	})
	if n := coverSweepFillFromDecisions(); n != 1 {
		t.Fatalf("换上 %d 条, 要 1", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|listed|"]; e.CoverURL != "https://s/1.jpg" || e.CoverSource != "soda" || e.CoverAlbum != "Album" {
		t.Errorf("登记专辑对不上的封面该换掉: %+v", e)
	}
	if e := enrichCache["A|bare|"]; e.CoverURL != "https://q/1.jpg" {
		t.Errorf("没专辑的不动: %+v", e)
	}
	if e := enrichCache["A|else|"]; e.CoverURL != "https://q/1.jpg" {
		t.Errorf("胜出那个源的专辑对不上登记专辑,不换: %+v", e)
	}
}

// 解析时照定下的封面取:写法键里没专辑、登记了这张专辑的那条定下的也算这张专辑的。
func TestSettledAlbumCoverUsesListedAlbum(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"周杰倫|聖徒|": {CoverURL: settleTux1, CoverSource: "netease", CoverSettled: settleTux1, YouTubeMusicAlbum: "太陽之子"},
	})
	if e, ok := settledAlbumCover("周杰伦", "太阳之子"); !ok || e.CoverURL != settleTux1 {
		t.Fatalf("登记专辑那条定下的该取到: %+v %v", e, ok)
	}
}
