package main

import (
	"strings"
	"testing"
)

// AMLL 的 x-roman 是整行附属内容:不能被当成一个词拼进正文,要单独产出罗马音轨。
func TestParseAMLLTTMLRomanRole(t *testing.T) {
	doc := `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">` +
		`<head><metadata xmlns=""><ttm:agent type="person" xml:id="v1"/></metadata></head>` +
		`<body><div xmlns="">` +
		`<p begin="1.372" end="2.705" ttm:agent="v1"><span begin="1.372" end="1.749">夢</span><span begin="1.749" end="2.524">ならば</span>` +
		`<span ttm:role="x-translation" xml:lang="zh-CN">如果只是一场梦</span><span ttm:role="x-roman">yu me na ra ba</span></p>` +
		`<p begin="3.000" end="4.000" ttm:agent="v1">どれほど<span ttm:role="x-roman">do re ho do</span><span ttm:role="x-translation">该有多好</span></p>` +
		`</div></body></tt>`
	r, ok := parseAMLLTTML(doc)
	if !ok {
		t.Fatal("解析失败")
	}
	if strings.Contains(r.lrc, "yu me") || strings.Contains(r.lrc, "do re") || strings.Contains(r.lrc, "该有多好") {
		t.Fatalf("罗马音 / 译文混进了正文: %q", r.lrc)
	}
	if !strings.Contains(r.lrc, "[00:01.37]夢ならば") || !strings.Contains(r.lrc, "[00:03.00]どれほど") {
		t.Fatalf("正文不对: %q", r.lrc)
	}
	if r.roma != "[00:01.37]yu me na ra ba\n[00:03.00]do re ho do\n" {
		t.Fatalf("罗马音 = %q", r.roma)
	}
	if !strings.Contains(r.tr, "[00:01.37]如果只是一场梦") {
		t.Fatalf("译文 = %q", r.tr)
	}
}

// Apple 的官方音译挂在 <transliterations> 里,按 itunes:key 对回正文行首。
func TestApplemusicTransliteration(t *testing.T) {
	doc := `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="ja">` +
		`<head><metadata><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations/>` +
		`<transliterations><transliteration xml:lang="ja-Latn">` +
		`<text for="L1"><span begin="14.402" end="15.345">maru</span><span begin="15.345" end="16.162">de</span> <span begin="16.279" end="17.116">kono</span></text>` +
		`<text for="L9"><span begin="1" end="2">nai</span></text>` +
		`</transliteration></transliterations></iTunesMetadata></metadata></head>` +
		`<body><div><p begin="14.402" end="17.116" itunes:key="L1"><span begin="14.402" end="15.345">まる</span><span begin="15.345" end="16.162">で</span><span begin="16.279" end="17.116">この</span></p></div></body></tt>`
	p, ok := applemusicParseTTML(doc)
	lrc, roma := p.lrc, p.roma
	if !ok || lrc == "" {
		t.Fatal("解析失败")
	}
	if roma != "[00:14.40]marude kono\n" {
		t.Fatalf("音译 = %q(对不上正文的 L9 应当丢掉)", roma)
	}
}

func TestMusixmatchRomaLanguage(t *testing.T) {
	cases := map[string]string{
		"[00:01.00]夢ならばどれほどよかったでしょう":  "rj",
		"[00:01.00]아침은 너무 멀어":         "rk",
		"[00:01.00]故事的小黄花":            "rz",
		"[00:01.00]Look at the stars": "",
	}
	for lrc, want := range cases {
		if got := musixmatchRomaLanguage(lrc); got != want {
			t.Errorf("%s: got %q, want %q", lrc, got, want)
		}
	}
}

func TestUsableRomaForResult(t *testing.T) {
	ko := "[00:01.00]아침은 너무 멀어\n[00:02.00]보고 싶어\n[00:03.00]오늘도"
	koRoma := "[00:01.00]achimeun neomu meoreo\n[00:02.00]bogo sipeo\n[00:03.00]oneuldo"
	if !usableRomaForResult(ko, koRoma) {
		t.Error("韩文歌的拉丁罗马字应当写进结果")
	}
	// 韩文歌的中文谐音轨不是罗马音。
	if usableRomaForResult(ko, "[00:01.00]啊亲们 挠木 摸咯\n[00:02.00]波高 西泼\n[00:03.00]噢呢到") {
		t.Error("谐音字轨不该当罗马音")
	}
	en := "[00:01.00]Look at the stars\n[00:02.00]Look how they shine\n[00:03.00]For you"
	if usableRomaForResult(en, en) {
		t.Error("英文歌不需要罗马音")
	}
	// 打分那道闸仍只认日文:韩文歌的罗马音不加分。
	if _, roma := usableValueAdd(ko, "", "", koRoma, "zh"); roma {
		t.Error("打分仍只给日文罗马音加分")
	}
}

func TestLooksMandarinPinyin(t *testing.T) {
	if looksMandarinPinyin("[00:17.48]ba soeng hao tong\n[00:25.41]o zi soeng hei hei coeng yao") {
		t.Error("网易云不带声调的粤拼不该判成普通话拼音")
	}
	if looksMandarinPinyin("[00:01.00]ngo5 oi3 nei5\n[00:03.50]ngo5 dei6 gam1 jat6 hou2 hoi1 sam1") {
		t.Error("带声调的粤拼不该判成普通话拼音")
	}
	if !looksMandarinPinyin("[00:01.00]gu shi de xiao huang hua\n[00:03.00]cong chu sheng na tian qi jiu piao zhe") {
		t.Error("普通话拼音没认出来")
	}
	e := enrichEntry{SongLanguage: songLanguageCantonese, LyricsRoma: "[00:01.00]wo ai ni zhong guo shi jie"}
	e.dropMandarinRomaForCantonese()
	if e.LyricsRoma != "" {
		t.Error("粤语歌的普通话拼音应当清掉,交给粤拼")
	}
	e = enrichEntry{SongLanguage: songLanguageCantonese, LyricsRoma: "[00:17.48]ba soeng hao tong"}
	e.dropMandarinRomaForCantonese()
	if e.LyricsRoma == "" {
		t.Error("源给的粤拼要留着")
	}
}

func TestSodaParseSeoTrackTranslation(t *testing.T) {
	r := sodaTestResponse(sodaTestLyricContent)
	r.Lyric.Translations = map[string]string{"cn": "[00:19.65]当我回头\n[00:26.00]看见你\n[00:30.00]在这里"}
	got, _, _ := sodaParseSeoTrack(r)
	if !strings.HasPrefix(got.tr, "[00:19.65]当我回头") {
		t.Fatalf("译文 = %q", got.tr)
	}
	r.Lyric.Translations = map[string]string{"cn": "没有时间戳的一段"}
	if got, _, _ := sodaParseSeoTrack(r); got.tr != "" {
		t.Fatalf("没有时间戳的译文不该收: %q", got.tr)
	}
}

func TestCandidateCoverOriginals(t *testing.T) {
	cases := []struct{ got, want string }{
		{neteaseCoverUpgrade("https://p1.music.126.net/abc==/1099.jpg?param=800y800"), "https://p1.music.126.net/abc==/1099.jpg" + neteaseCoverQuery},
		{neteaseCoverUpgrade("https://p1.music.126.net/abc==/1099.jpg" + neteaseCoverQuery), "https://p1.music.126.net/abc==/1099.jpg" + neteaseCoverQuery},
		{neteaseCoverUpgrade("https://example.com/a.jpg?param=800y800"), "https://example.com/a.jpg?param=800y800"},
		{musixmatchLargestCover(musixmatchTrackRow{AlbumCoverart500x500: "https://s.mxmcdn.net/images-storage/albums2/1/41606678_500_500.jpg"}), "https://s.mxmcdn.net/images-storage/albums2/1/41606678_800_800.jpg"},
		{musixmatchLargestCover(musixmatchTrackRow{AlbumCoverart500x500: "https://s.mxmcdn.net/a_500_500.jpg", AlbumCoverart800x800: "https://s.mxmcdn.net/b_800_800.jpg"}), "https://s.mxmcdn.net/b_800_800.jpg"},
		{ytmusicOriginalThumbnail("https://yt3.googleusercontent.com/C_Wsvrqk0E7n=w120-h120-l90-rj"), "https://yt3.googleusercontent.com/C_Wsvrqk0E7n=s0"},
		{ytmusicOriginalThumbnail("https://i.ytimg.com/vi/x/hqdefault.jpg"), "https://i.ytimg.com/vi/x/hqdefault.jpg"},
		{kkboxOriginalImage("https://i.kfs.io/album/global/276412593,0v1/fit/600x600.jpg"), "https://i.kfs.io/album/global/276412593,0v1/original.jpg"},
		{kuwoCoverURL("120/38/70/3416909732.jpg"), "https://img1.kuwo.cn/star/albumcover/0/38/70/3416909732.jpg"},
		{deezerTrackFromJSON(t, `{"album":{"cover_xl":"https://cdn-images.dzcdn.net/images/cover/3da6/1000x1000-000000-80-0-0.jpg"}}`).cover(), "https://cdn-images.dzcdn.net/images/cover/3da6/1800x1800-000000-80-0-0.jpg"},
	}
	for i, c := range cases {
		if c.got != c.want {
			t.Errorf("#%d: got %q, want %q", i, c.got, c.want)
		}
	}
}

// 韩文歌常夹大段英文,整首多数是拉丁字母,照样要罗马音。
func TestRomaScriptOfMixedKpop(t *testing.T) {
	ditto := "[00:01.00]Woo woo woo woo ooh\n[00:08.00]Stay in the middle\n[00:14.00]Like you a little\n" +
		"[00:17.00]Don't want no riddle\n[00:19.00]말해줘 say it back\n[00:21.00]Oh, say it ditto\n[00:23.00]아침은 너무 멀어"
	if got := romaScriptOf(ditto); got != scriptHangul {
		t.Fatalf("got %v, want hangul", got)
	}
	if got := musixmatchRomaLanguage(ditto); got != "rk" {
		t.Fatalf("got %q, want rk", got)
	}
	if romaScriptOf("[00:01.00]Look at the stars\n[00:02.00]Look how they shine for you") != scriptNone {
		t.Fatal("英文歌不需要罗马音")
	}
}

func TestApplemusicLyricsQuery(t *testing.T) {
	cases := map[string]string{
		"zh":      "?extend=ttmlLocalizations&l%5Blyrics%5D=zh-Hans-CN&l%5Bscript%5D=zh-Hans%2Czh-Latn",
		"zh-Hant": "?extend=ttmlLocalizations&l%5Blyrics%5D=zh-Hant-TW&l%5Bscript%5D=zh-Hant%2Czh-Latn",
		"en":      "?extend=ttmlLocalizations&l%5Blyrics%5D=en-US&l%5Bscript%5D=en-Latn",
		"fr":      "?extend=ttmlLocalizations&l%5Blyrics%5D=fr&l%5Bscript%5D=fr-Latn",
	}
	for lang, want := range cases {
		if got := applemusicLyricsQuery(lang); got != want {
			t.Errorf("%s: got %q, want %q", lang, got, want)
		}
	}
}

func TestMigrateNeteaseCoverURLs(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"a|网易云|": {CoverURL: "https://p1.music.126.net/abc==/1099.jpg?param=800y800", CoverSource: "netease", AccentColor: "#112233"},
		"b|QQ|":  {CoverURL: "https://y.qq.com/music/photo_new/T002R800x800M000abc.jpg"},
		"c|已换过|": {CoverURL: "https://p2.music.126.net/x==/1.jpg" + neteaseCoverQuery},
	})
	migrateNeteaseCoverURLs()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["a|网易云|"]; e.CoverURL != "https://p1.music.126.net/abc==/1099.jpg"+neteaseCoverQuery || e.CoverSource != "netease" || e.AccentColor != "#112233" {
		t.Errorf("网易云条目只换地址: %+v", e)
	}
	if e := enrichCache["b|QQ|"]; e.CoverURL != "https://y.qq.com/music/photo_new/T002R800x800M000abc.jpg" {
		t.Errorf("别的图床不动: %q", e.CoverURL)
	}
	if e := enrichCache["c|已换过|"]; e.CoverURL != "https://p2.music.126.net/x==/1.jpg"+neteaseCoverQuery {
		t.Errorf("已经是新写法的不动: %q", e.CoverURL)
	}
}
