package main

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

// PS5:编目匹配的新名字来源(Apple 区服对照 / Apple 目录反查 / YouTube Music 英文署名 / 歌词署名)、
// MV 标题拆身份、MV 时长当未知。用例全部是 09-17 ~ 09-26 真实没接住的那几首的形状。

// 本地化名字:「防弹少年团」在 MusicBrainz 查不到(BTS 的别名里只有日文汉字),Apple 目录按曲名 + 时长反查出 BTS。
func TestCatalogAppleTitleAliasMatches(t *testing.T) {
	const artist, track = "防弹少年团", "Dynamite"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 128, 0)},
		infoKey("BTS", track):  {body: namedTrackJSON("BTS", "Dynamite", "m-dynamite", 1500000, 199000)},
	})
	stubCatalogNameSources(t, catalogNameSources{appleTitle: map[string][]string{artist + "\n" + track: {"BTS"}}})
	if a, _, matched := col.resolve(context.Background(), artist, track, 199.1, scopeAll); a != "BTS" || !matched {
		t.Fatalf("resolve = %q matched=%v, want BTS", a, matched)
	}
}

// YouTube Music 英文署名同样当强身份;这一路查不成时其余照查,结论只记短期。
func TestCatalogYTMusicAliasMatchesAndFailureIsProvisional(t *testing.T) {
	const artist, track = "防弹少年团", "NORMAL"
	responses := map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 40, 0)},
		infoKey("BTS", track):  {body: namedTrackJSON("BTS", "NORMAL", "m-normal", 90000, 187000)},
	}
	col, _ := newCatalogServer(t, responses)
	stubCatalogNameSources(t, catalogNameSources{ytmusic: map[string][]string{artist + "\n" + track: {"BTS"}}})
	if a, _, _ := col.resolve(context.Background(), artist, track, 187, scopeAll); a != "BTS" {
		t.Fatalf("YouTube Music 英文署名应接住,got %q", a)
	}

	col2, _ := newCatalogServer(t, map[string]probeResp{infoKey(artist, track): {body: trackJSON("", 40, 0)}})
	stubCatalogNameSources(t, catalogNameSources{ytmusicErr: errors.New("youtube music 503")})
	if a, _, _ := col2.resolve(context.Background(), artist, track, 187, scopeAll); a != artist {
		t.Fatalf("查不成且别的名字都没有时维持原样,got %q", a)
	}
	if d := decisionOf(col2, artist, track); d.Verdict != verdictDefer || !d.Provisional {
		t.Errorf("YouTube Music 那一路没查成时只记短期 defer,got %+v", d)
	}
}

// 歌词署名是弱身份:编目条目要有 mbid 或听众够多、两边时长都有且对得上才认。
func TestCatalogLyricsWinnerIsWeakIdentity(t *testing.T) {
	const artist, track = "防弹少年团", "Dynamite"
	responses := map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 128, 0)},
		infoKey("BTS", track):  {body: namedTrackJSON("BTS", "Dynamite", "m-dynamite", 1500000, 199000)},
	}
	lyrics := map[string][]string{artist + "\n" + track: {"BTS(防弹少年团)"}}

	col, _ := newCatalogServer(t, responses)
	stubCatalogNameSources(t, catalogNameSources{lyrics: lyrics})
	if a, _, _ := col.resolve(context.Background(), artist, track, 199, scopeAll); a != "BTS" {
		t.Fatalf("歌词署名拆出来的 BTS 时长对得上应接住,got %q", a)
	}

	col2, _ := newCatalogServer(t, responses)
	stubCatalogNameSources(t, catalogNameSources{lyrics: lyrics})
	if a, _, _ := col2.resolve(context.Background(), artist, track, 0, scopeAll); a != artist {
		t.Errorf("时长未知时弱身份不该认,got %q", a)
	}
}

// 开播那一刻歌词还没解析完:结论只记短期,到打卡时(几分钟后)重判一次。
func TestCatalogLyricsPendingIsProvisional(t *testing.T) {
	const artist, track = "防弹少年团", "SWIM"
	col, _ := newCatalogServer(t, map[string]probeResp{infoKey(artist, track): {body: trackJSON("", 12, 0)}})
	stubCatalogNameSources(t, catalogNameSources{lyricPending: true})
	col.resolve(context.Background(), artist, track, 180, scopeAll)
	if d := decisionOf(col, artist, track); d.Verdict != verdictDefer || !d.Provisional {
		t.Fatalf("歌词未解析完时只记短期 defer,got %+v", d)
	}
}

// MV 标题:拆出「BTS / Merry Go Round」,那条是编目条目 → 改写成它。MV 259 s、录音室版 201 s,
// 拆出来的写法按未知时长判才过得了时长闸(条目没有 mbid,要走时长那一步)。
func TestCatalogMusicVideoTitleMatchesCleanIdentity(t *testing.T) {
	const artist, track = "防弹少年团", "BTS (방탄소년단) ‘Merry Go Round’ Official MV"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):           {body: notFoundJSON},
		infoKey("BTS", "Merry Go Round"): {body: namedTrackJSON("BTS", "Merry Go Round", "", 348000, 201000)},
	})
	a, tr, matched := col.resolve(context.Background(), artist, track, 259, scopeAll)
	if a != "BTS" || tr != "Merry Go Round" || !matched {
		t.Fatalf("resolve = %q / %q matched=%v, want BTS / Merry Go Round", a, tr, matched)
	}
	if d := decisionOf(col, artist, track); d.Via == "" || d.Via[:5] != "video" {
		t.Errorf("结论应标明来自视频标题,got Via=%q", d.Via)
	}
}

// 「只改曲名」档:歌手不许动,MV 拆出来的歌名仍按原歌手判。
func TestCatalogMusicVideoTitleRespectsTrackOnlyScope(t *testing.T) {
	const artist, track = "The Kid LAROI", "Stay (Official Video)"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):  {body: trackJSON("", 189, 0)},
		infoKey(artist, "Stay"): {body: namedTrackJSON(artist, "Stay", "m-stay", 50000, 0)},
	})
	a, tr, _ := col.resolve(context.Background(), artist, track, 240, matchScope{track: true})
	if a != artist || tr != "Stay" {
		t.Fatalf("resolve = %q / %q, want %s / Stay", a, tr, artist)
	}
	if cs.count(infoKey(artist, "Stay")) == 0 {
		t.Error("应按拆出来的歌名查")
	}
}

// 「只改曲名」档:MV 拆出来的演唱者跟播放器报的不同时也不许换歌手,只按原歌手 + 拆出来的歌名判。
func TestCatalogMusicVideoTitleTrackOnlyKeepsReportedArtist(t *testing.T) {
	const artist, track = "音樂頑童", "Musiq Soulchild - Buddy (Official Video)"
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track):              {body: trackJSON("", 1, 0)},
		infoKey(artist, "Buddy"):            {body: notFoundJSON},
		infoKey("Musiq Soulchild", "Buddy"): {body: namedTrackJSON("Musiq", "Buddy", "m-buddy", 16000, 223000)},
	})
	a, _, _ := col.resolve(context.Background(), artist, track, 231, matchScope{track: true})
	if a != artist {
		t.Fatalf("只改曲名时歌手不许变,got %q", a)
	}
}

// 拆出来的写法编目里也没有:原样发,不拿视频标题本身再跑一遍扩展搜索。
func TestCatalogMusicVideoTitleNoMatchKeepsRaw(t *testing.T) {
	const artist, track = "Michael Jackson", "Michael Jackson x Mark Ronson: Diamonds are Invincible (Audio)"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 4, 0)},
		infoKey("Michael Jackson x Mark Ronson", "Diamonds are Invincible"): {body: notFoundJSON},
		infoKey("Michael Jackson", "Diamonds are Invincible"):               {body: trackJSON("", 17, 0)},
		infoKey("Mark Ronson", "Diamonds are Invincible"):                   {body: notFoundJSON},
	})
	if a, tr, _ := col.resolve(context.Background(), artist, track, 230, scopeAll); a != artist || tr != track {
		t.Fatalf("拆不出编目条目应原样发,got %q / %q", a, tr)
	}
	if cs.count(searchKey(track)) != 0 {
		t.Error("不该拿视频标题本身去全站搜")
	}
}

// 翻唱不拆:拆出来的是原唱,不能拿去当这首歌的身份。
func TestCatalogCoverTitleNotRewrittenToOriginal(t *testing.T) {
	const artist, track = "MAMAMOO", "[Special] Watermelon Sugar (Cover by 화사)"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: trackJSON("", 212, 0)},
	})
	if a, tr, _ := col.resolve(context.Background(), artist, track, 132, scopeAll); a != artist || tr != track {
		t.Fatalf("翻唱应原样发,got %q / %q", a, tr)
	}
	if cs.count(infoKey("Harry Styles", "Watermelon Sugar")) != 0 || cs.count(infoKey(artist, "Watermelon Sugar")) != 0 {
		t.Error("翻唱不该按原唱 / 去掉署名的歌名去查")
	}
}

// MV 的时长是视频长度:带上标记时编目匹配按未知判,JISOO《FLOWER》174 s 的条目不再被 MV 时长挡掉。
func TestResolveScrobbleTagsMusicVideoDurationUnknown(t *testing.T) {
	const artist, track = "JISOO和BLACKPINK", "Flower"
	responses := map[string]probeResp{
		infoKey(artist, track):      {body: trackJSON("", 1, 0)},
		infoKey("JISOO", track):     {body: namedTrackJSON("JISOO", "FLOWER", "m-flower", 418000, 174000)},
		infoKey("BLACKPINK", track): {body: notFoundJSON},
	}
	setMatch(t, lastfmMatchSmart, true, true, false)

	col, _ := newCatalogServer(t, responses)
	if a, _ := resolveScrobbleTags(context.Background(), col, artist, track, 205); a == "JISOO" {
		t.Fatal("没有 MV 标记时 205 s 跟 174 s 对不上,不该改写(对照组)")
	}
	col2, _ := newCatalogServer(t, responses)
	if a, _ := resolveScrobbleTags(withCatalogDurationUnknown(context.Background(), true), col2, artist, track, 205); a != "JISOO" {
		t.Fatalf("MV 按未知时长判应改写成 JISOO,got %q", a)
	}
	if withCatalogDurationUnknown(context.Background(), false).Value(catalogDurationUnknownKey{}) != nil {
		t.Error("不是 MV 时不该打标记")
	}
}

// 重试只对「一两秒就恢复」的失败:本地排队排满、单个请求超时。Last.fm 明确回限流 / 429 窗口不重试。
func TestCatalogRetryable(t *testing.T) {
	cases := []struct {
		err  error
		want bool
	}{
		{errHostRateLimited, true},
		{context.DeadlineExceeded, true},
		{errHostGuarded, false},
		{&lastfmAPIError{Code: lastfmErrRateLimited}, false},
		{errors.New("decode: bad json"), false},
	}
	for _, c := range cases {
		if got := catalogRetryable(c.err); got != c.want {
			t.Errorf("catalogRetryable(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

// 扩展搜索的名字按强在前排,截断先截弱身份。
func TestCatalogExtNamesStrongFirst(t *testing.T) {
	col, _ := newCatalogServer(t, nil)
	stubAliases(t, map[string][]string{"防弹少年团": {"Bangtan Boys"}})
	stubCatalogNameSources(t, catalogNameSources{
		storefront: map[string][]string{"防弹少年团": {"BTS"}},
		lyrics:     map[string][]string{"防弹少年团\nDynamite": {"Bangtan(防弹)"}},
	})
	names, partial := col.extNames(context.Background(), "防弹少年团", "Dynamite", 199)
	if partial {
		t.Error("所有来源都查成了,不该标 partial")
	}
	seenWeak := false
	for _, n := range names {
		if n.strength == identityWeak {
			seenWeak = true
		} else if seenWeak {
			t.Fatalf("强身份排在弱身份后面: %+v", names)
		}
	}
	if len(names) == 0 || names[0].name != "Bangtan Boys" {
		t.Errorf("MusicBrainz 别名应排在最前: %+v", names)
	}
}

// 按 id 对应,不按名字猜:Taio Cruz《Dynamite》曲名相同、时长只差 4 s、署名也跨文字系统,但它的视频 id / 曲目 id
// 跟本地写法「防弹少年团」那几条对不上,不能被当成防弹少年团的原名。
func TestPickYTMusicLinkedNames(t *testing.T) {
	local := []ytmusicParsedSearchItem{
		{videoID: "v-bts", title: "Dynamite", artist: "防弹少年团", durationSecs: 199},
		{videoID: "v-bts-inst", title: "Dynamite (Instrumental)", artist: "防弹少年团", durationSecs: 199},
		{videoID: "v-taio", title: "Dynamite", artist: "Taio Cruz", durationSecs: 203},
	}
	en := []ytmusicParsedSearchItem{
		{videoID: "v-taio", title: "Dynamite", artist: "Taio Cruz", durationSecs: 203},
		{videoID: "v-bts", title: "Dynamite", artist: "BTS", durationSecs: 199},
		{videoID: "v-bts-inst", title: "Dynamite (Instrumental)", artist: "BTS", durationSecs: 199},
	}
	if got := pickYTMusicLinkedNames(local, en, "防弹少年团"); len(got) != 1 || got[0] != "BTS" {
		t.Fatalf("应只收同一视频 id 的 BTS,got %v", got)
	}
	if got := pickYTMusicLinkedNames(local[2:], en, "防弹少年团"); len(got) != 0 {
		t.Errorf("本地界面里没有署名是防弹少年团的结果时一个都不收,got %v", got)
	}
	if ytmusicLocalHL("防弹少年团") != "zh-CN" || ytmusicLocalHL("周杰倫") != "zh-TW" || ytmusicLocalHL("あいみょん") != "ja" ||
		ytmusicLocalHL("방탄소년단") != "ko" || ytmusicLocalHL("Khalil Fong") != "" {
		t.Error("界面语言应按本地署名的文字选,拉丁字母不查")
	}
}

func TestPickAppleLinkedNames(t *testing.T) {
	results := []itunesResult{
		{TrackID: 1, TrackName: "Dynamite", ArtistName: "防弹少年团"},
		{TrackID: 9, TrackName: "Dynamite", ArtistName: "Taio Cruz"},
		{TrackID: 1, TrackName: "Dynamite", ArtistName: "BTS"},
		{TrackID: 2, TrackName: "Butter", ArtistName: "防弹少年团"},
		{TrackID: 2, TrackName: "Butter", ArtistName: "BTS"},
		{TrackID: 0, TrackName: "Dynamite", ArtistName: "Someone"},
	}
	if got := pickAppleLinkedNames(results, "防弹少年团"); len(got) != 1 || got[0] != "BTS" {
		t.Fatalf("应只收同一曲目 id 的 BTS(Taio Cruz 那条 id 对不上),got %v", got)
	}
}

func TestParenthesizedAlias(t *testing.T) {
	cases := []struct{ in, outer, inner string }{
		{"BTS(防弹少年团)", "BTS", "防弹少年团"},
		{"IU（아이유）", "IU", "아이유"},
		{"(G)I-DLE", "", ""},
		{"Prince", "", ""},
		{"()", "", ""},
	}
	for _, c := range cases {
		o, i, ok := parenthesizedAlias(c.in)
		if o != c.outer || i != c.inner || ok != (c.outer != "") {
			t.Errorf("parenthesizedAlias(%q) = %q %q %v", c.in, o, i, ok)
		}
	}
}

func TestStorefrontArtistAliasesCached(t *testing.T) {
	appleStorefrontArtistMu.Lock()
	saved := appleStorefrontArtistCache
	appleStorefrontArtistCache = map[string][]string{
		normLoose("防弹少年团") + "|" + normLoose("ARIRANG"):  {"BTS"},
		normLoose("防弹少年团") + "|" + normLoose("BE"):       {"BTS", "防弹少年团"},
		normLoose("防弹少年团团") + "|" + normLoose("ARIRANG"): {"别人"},
	}
	appleStorefrontArtistMu.Unlock()
	t.Cleanup(func() {
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache = saved
		appleStorefrontArtistMu.Unlock()
	})
	got := storefrontArtistAliasesCached("防弹少年团")
	if len(got) != 1 || got[0] != "BTS" {
		t.Errorf("应跨专辑合并、去掉自己、不串到前缀相同的别的歌手,got %v", got)
	}
}

func TestEnrichLyricsWinnerArtists(t *testing.T) {
	savedCache, savedPath := enrichCache, enrichPath
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichCache, enrichPath = savedCache, savedPath
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	enrichPath = filepath.Join(t.TempDir(), "enrich.json")
	enrichCache = map[string]enrichEntry{
		enrichKey("防弹少年团", "Dynamite", ""):    {LyricsDecision: &lyricsDecision{WinnerArtist: "BTS(防弹少年团)", DecidedAt: time.Now().Unix()}},
		enrichKey("防弹少年团", "SWIM", "ARIRANG"): {},
	}
	enrichMu.Unlock()
	if names, pending := enrichLyricsWinnerArtists("防弹少年团", "Dynamite"); pending || len(names) != 1 || names[0] != "BTS(防弹少年团)" {
		t.Errorf("已解析的歌应给出胜出署名,got %v pending=%v", names, pending)
	}
	if _, pending := enrichLyricsWinnerArtists("防弹少年团", "SWIM"); !pending {
		t.Error("条目在、歌词还没解析完应算 pending(不管专辑)")
	}
	if _, pending := enrichLyricsWinnerArtists("防弹少年团", "NORMAL"); !pending {
		t.Error("缓存里还没有这首歌应算 pending")
	}
	enrichMu.Lock()
	enrichPath = ""
	enrichMu.Unlock()
	if names, pending := enrichLyricsWinnerArtists("防弹少年团", "NORMAL"); pending || names != nil {
		t.Error("没加载歌词缓存的进程(回填子命令)不算 pending")
	}
}

// 名字缓存有上限:常驻进程跑几天也不会无限长。
func TestCatalogLinkedCacheIsCapped(t *testing.T) {
	catalogLinkedNameMu.Lock()
	saved := catalogLinkedNameCache
	catalogLinkedNameCache = map[string][]string{}
	catalogLinkedNameMu.Unlock()
	t.Cleanup(func() {
		catalogLinkedNameMu.Lock()
		catalogLinkedNameCache = saved
		catalogLinkedNameMu.Unlock()
	})
	for i := 0; i < catalogLinkedNameMax+50; i++ {
		key := fmt.Sprintf("apple|artist|song %d", i)
		if _, err := catalogLinkedCached(key, func() ([]string, error) { return []string{"x"}, nil }); err != nil {
			t.Fatal(err)
		}
	}
	catalogLinkedNameMu.Lock()
	n := len(catalogLinkedNameCache)
	_, newest := catalogLinkedNameCache[fmt.Sprintf("apple|artist|song %d", catalogLinkedNameMax+49)]
	catalogLinkedNameMu.Unlock()
	if n > catalogLinkedNameMax || !newest {
		t.Fatalf("缓存该封顶在 %d 条且保留最新那条: len=%d newest=%v", catalogLinkedNameMax, n, newest)
	}
}
