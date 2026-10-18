package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

// 按专辑名定位到了别的歌手的同名专辑、曲目表里没有这一首:不借它的封面。
func TestAppleMatchViaAlbumSkipsAnotherArtistsAlbumCover(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) {
			return 200, `{"results":[{"collectionName":"7","collectionId":1,"artistName":"Lil Nas X","trackName":"Old Town Road",` +
				`"artworkUrl100":"https://l/100x100bb.jpg"}]}`
		},
		func(string) (int, string) {
			return 200, `{"results":[{"wrapperType":"track","trackName":"Old Town Road","collectionName":"7","artistName":"Lil Nas X",` +
				`"trackViewUrl":"https://music.apple.com/us/album/7/1?i=2","trackTimeMillis":157000}]}`
		})
	got, _ := resolveAppleMusicMatchViaAlbum(context.Background(), "S Club 7", "Cross My Heart", "7", 211)
	if got.cover != "" || got.url != "" {
		t.Errorf("别的歌手的同名专辑,封面不借: %+v", got)
	}
}

// 署名换了文字写法、曲名也换了写法:照样借这张专辑的封面,不给链接。
func TestAppleMatchViaAlbumCoverUnderAnotherScript(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) {
			return 200, `{"results":[{"collectionName":"橙月","collectionId":1,"artistName":"方大同","trackName":"別的歌",` +
				`"artworkUrl100":"https://o/100x100bb.jpg"}]}`
		},
		func(string) (int, string) {
			return 200, `{"results":[{"wrapperType":"track","trackName":"三人遊","collectionName":"橙月","artistName":"方大同",` +
				`"trackViewUrl":"https://music.apple.com/us/album/x/1?i=2","trackTimeMillis":245600}]}`
		})
	got, _ := resolveAppleMusicMatchViaAlbum(context.Background(), "Khalil Fong", "Three Tour", "橙月", 245)
	if got.cover != "https://o/1200x1200bb.jpg" || got.url != "" {
		t.Errorf("署名换了文字写法,借专辑封面、不给链接: %+v", got)
	}
	if got, _ := resolveAppleMusicMatchViaAlbum(context.Background(), "Khalil Fong", "Three Tour", "橙月", 0); got.cover == "" {
		t.Errorf("时长不知道也照样借: %+v", got)
	}
}

func TestAppleAlbumCoverIdentityOK(t *testing.T) {
	tracks := []itunesResult{{ArtistName: "Lil Nas X", TrackTimeMillis: 157000}, {ArtistName: "Lil Nas X & S Club 7", TrackTimeMillis: 180000}}
	for _, c := range []struct {
		name               string
		albumArtist, local string
		tracks             []itunesResult
		secs               float64
		want               bool
	}{
		{"专辑署名对上", "S Club 7", "S Club 7", nil, 0, true},
		{"本地没署名", "Lil Nas X", "", nil, 0, true},
		{"专辑没署名", "", "S Club 7", nil, 0, true},
		{"别的歌手", "Lil Nas X", "S Club 7", tracks[:1], 211, false},
		{"曲目表里有一轨署名对上", "Lil Nas X", "S Club 7", tracks, 0, true},
		{"同一种文字的另一个名字、时长差一秒内", "Lil Nas X", "S Club 7", tracks[:1], 157.8, false},
		{"时长差 0.3 秒内", "Lil Nas X", "S Club 7", tracks[:1], 157.2, true},
		{"换了文字写法", "Terry Lin", "林志炫", nil, 0, true},
		{"同一种文字的另一个中文名", "张三", "林志炫", nil, 0, false},
	} {
		if got := appleAlbumCoverIdentityOK(c.albumArtist, c.local, c.tracks, c.secs); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

func TestAppleCoverIsListedAlbum(t *testing.T) {
	for _, c := range []struct {
		apple, album string
		want         bool
	}{
		{"Twenty Five", "Twenty Five", true},
		{"飞鸟与晚霞 - Single", "飛鳥與晚霞", true},
		{"天赐的声音第五季 第6期 (Live)", "天赐的声音第五季 第6期（Live）", true},
		{"Hits of the 80's", "Greatest Hits Of The '80s", false},
		{"Make It Big", "Twenty Five", false},
	} {
		if got := appleCoverIsListedAlbum(c.apple, c.album); got != c.want {
			t.Errorf("%q / %q: %v, want %v", c.apple, c.album, got, c.want)
		}
	}
}

// 封面明确是另一张专辑的:按歌词管理显示的专辑问 Apple,逐字对上就换成 Apple 那张、主色清空;问到了都记下时刻,没对上的不换;
// 封面对得上的、30 天内问过的、专辑定下的、解析中的、提前提交的不问。见 03 章决策 56。
func TestCoverSweepAppleForOtherAlbumCovers(t *testing.T) {
	_, waits := withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	recent := time.Now().Add(-time.Hour).Unix()
	other := enrichEntry{CoverURL: "https://a/make.jpg", CoverSource: "apple", CoverAlbum: "Make It Big", AccentColor: "#112233"}
	withEnrichCache(t, map[string]enrichEntry{
		"Wham!|Last Christmas|": func() enrichEntry {
			e := other
			e.YouTubeMusicAlbum, e.DurationSecs = "Twenty Five", 262
			return e
		}(),
		"Starship|Sara|Greatest Hits Of The '80s": {CoverURL: "https://n/np.jpg", CoverSource: "netease", CoverAlbum: "No Protection"},
		"A|Fits|Twenty Five":                      {CoverURL: "https://n/1.jpg", CoverSource: "netease", CoverAlbum: "Twenty Five"},
		"A|Recent|Twenty Five":                    {CoverURL: "https://n/2.jpg", CoverSource: "netease", CoverAlbum: "Other", CoverAppleAlbumCheckTS: recent},
		"A|Settled|Twenty Five":                   {CoverURL: "https://n/3.jpg", CoverSource: "netease", CoverAlbum: "Other", CoverSettled: "https://n/3.jpg"},
		"A|Inflight|Twenty Five":                  {CoverURL: "https://n/4.jpg", CoverSource: "netease", CoverAlbum: "Other"},
		"A|Provisional|Twenty Five":               {CoverURL: "https://n/5.jpg", CoverSource: "netease", CoverAlbum: "Other"},
		"A|NoAlbum|":                              {CoverURL: "https://n/6.jpg", CoverSource: "netease", CoverAlbum: "Other"},
	})
	enrichMu.Lock()
	enrichInflight["A|Inflight|Twenty Five"] = true
	savedProvisional := enrichProvisional
	enrichProvisional = map[string]bool{"A|Provisional|Twenty Five": true}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichProvisional = savedProvisional
		enrichMu.Unlock()
	})
	var asked []string
	coverSweepAppleCover = func(ctx context.Context, artist, title, album string, secs float64) (string, string, bool) {
		asked = append(asked, artist+"|"+title+"|"+album)
		if !isBackgroundOutbound(ctx) {
			t.Error("后台请求要标成后台")
		}
		if artist == "Wham!" {
			if secs != 262 {
				t.Errorf("带上时长: %v", secs)
			}
			return "https://a/25.jpg", "Twenty Five", true
		}
		return "https://a/hits80.jpg", "Hits of the 80's", true
	}
	if n := coverSweepAppleForOtherAlbumCovers(context.Background()); n != 1 {
		t.Fatalf("换了 %d 条, 要 1", n)
	}
	if strings.Join(asked, ";") != "Starship|Sara|Greatest Hits Of The '80s;Wham!|Last Christmas|Twenty Five" {
		t.Errorf("按 key 顺序只问另一张专辑的两条,专辑用显示的: %q", asked)
	}
	gaps := 0
	for _, w := range *waits {
		if w == coverSweepAppleGap {
			gaps++
		}
	}
	if gaps != 1 {
		t.Errorf("两次联网之间隔 coverSweepAppleGap: %v", *waits)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["Wham!|Last Christmas|"]; e.CoverURL != "https://a/25.jpg" || e.CoverSource != "apple" ||
		e.CoverAlbum != "Twenty Five" || e.AccentColor != "" || e.CoverAppleAlbumCheckTS == 0 {
		t.Errorf("换成显示的专辑那张、主色清空、记下时刻: %+v", e)
	}
	if e := enrichCache["Starship|Sara|Greatest Hits Of The '80s"]; e.CoverURL != "https://n/np.jpg" || e.CoverAppleAlbumCheckTS == 0 {
		t.Errorf("Apple 给的只是包含得上的另一张合辑:不换,记下时刻: %+v", e)
	}
	if e := enrichCache["A|Recent|Twenty Five"]; e.CoverAppleAlbumCheckTS != recent {
		t.Errorf("30 天内问过的不再问: %+v", e)
	}
}

// 没问到的不记时刻;连着 coverSweepOfflineLimit 条没问到就停,问到一次清零。
func TestCoverSweepAppleForOtherAlbumCoversStopsWhenUnreached(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	m := map[string]enrichEntry{}
	for i := 0; i < coverSweepOfflineLimit+3; i++ {
		m["A|"+string(rune('a'+i))+"|Album"] = enrichEntry{CoverURL: "https://n/x.jpg", CoverSource: "netease", CoverAlbum: "Other"}
	}
	withEnrichCache(t, m)
	calls := 0
	coverSweepAppleCover = func(context.Context, string, string, string, float64) (string, string, bool) {
		calls++
		return "", "", calls == 2
	}
	coverSweepAppleForOtherAlbumCovers(context.Background())
	if calls != coverSweepOfflineLimit+2 {
		t.Errorf("问到一次清零,之后连着 %d 条没问到才停: 问了 %d 条", coverSweepOfflineLimit, calls)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for k, e := range enrichCache {
		if (k == "A|b|Album") != (e.CoverAppleAlbumCheckTS != 0) {
			t.Errorf("只有问到的那条记时刻: %s %+v", k, e)
		}
	}
}

// 问 Apple 期间条目被换了封面、或被占去解析:不动它,也不记时刻。只读本地答得出的不等。
func TestCoverSweepAppleForOtherAlbumCoversSkipsEntriesChangedMeanwhile(t *testing.T) {
	_, waits := withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|Changed|Album": {CoverURL: "https://n/1.jpg", CoverSource: "netease", CoverAlbum: "Other"},
		"A|Taken|Album":   {CoverURL: "https://n/2.jpg", CoverSource: "netease", CoverAlbum: "Other"},
	})
	coverSweepAppleAnswered = func(string, string, string) bool { return true }
	coverSweepAppleCover = func(_ context.Context, _, title, _ string, _ float64) (string, string, bool) {
		enrichMu.Lock()
		if title == "Changed" {
			e := enrichCache["A|Changed|Album"]
			e.CoverURL = "https://n/new.jpg"
			enrichCache["A|Changed|Album"] = e
		} else {
			enrichInflight["A|Taken|Album"] = true
		}
		enrichMu.Unlock()
		return "https://a/album.jpg", "Album", true
	}
	if n := coverSweepAppleForOtherAlbumCovers(context.Background()); n != 0 {
		t.Errorf("换了 %d 条, 要 0", n)
	}
	if len(*waits) != 0 {
		t.Errorf("只读本地的不等: %v", *waits)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|Changed|Album"]; e.CoverURL != "https://n/new.jpg" || e.CoverAppleAlbumCheckTS != 0 {
		t.Errorf("期间换了封面的不动: %+v", e)
	}
	if e := enrichCache["A|Taken|Album"]; e.CoverURL != "https://n/2.jpg" || e.CoverAppleAlbumCheckTS != 0 {
		t.Errorf("期间被占去解析的不动: %+v", e)
	}
}

func TestCoverSweepAsksAppleForOtherAlbumCoversAfterSiblings(t *testing.T) {
	src := string(mustRead(t, "coversweep.go"))
	sib := strings.Index(src, "if n := coverSweepBorrowAlbumSiblings(); n > 0 {")
	apple := strings.Index(src, "if n := coverSweepAppleForOtherAlbumCovers(ctx); n > 0 {")
	settle := strings.Index(src, "if switched, settled := coverSweepSettleAlbumCovers(ctx); settled > 0 {")
	if sib < 0 || apple < 0 || settle < 0 || !(sib < apple && apple < settle) {
		t.Errorf("一遍里不联网的几步之后、给专辑定封面之前问 Apple: %d %d %d", sib, apple, settle)
	}
}
