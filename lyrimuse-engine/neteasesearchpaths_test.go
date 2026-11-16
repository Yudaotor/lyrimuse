package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"testing"
)

// 专辑搜索、按歌手泛搜、按歌词搜在日本出口的原始返回(Globalping 探针,只留用到的字段,歌词只留前三句)。

// neJPAlbumSearchTheBook:日本出口 search/get type=10「YOASOBI THE BOOK」。
const neJPAlbumSearchTheBook = `{"code":200,"result":{"hlWords":["34"],"albums":[{"id":404306757,"name":"34","artist":{"name":"向井太一"},"artists":[{"name":"向井太一"}]},{"id":273953177,"name":"DELTARUNE Chapters 3+4 (Original Game Soundtrack)","artist":{"name":"Toby Fox"},"artists":[{"name":"Toby Fox"}],"alias":["游戏《三角符文：第三四章》原声集"]},{"id":77513,"name":"NARUTO -ナルト- オリジナルサウンドトラック","artist":{"name":"六三四Musashi"},"artists":[{"name":"六三四Musashi"},{"name":"増田俊郎"}]},{"id":77502,"name":"NARUTO-ナルト-オリジナルサウンドトラックIII","artist":{"name":"六三四Musashi"},"artists":[{"name":"六三四Musashi"},{"name":"増田俊郎"}]},{"id":409394626,"name":"三十四音韵之歌","artist":{"name":"王扎"},"artists":[{"name":"王扎"}]}]}}`

// neJPAlbumSearchU87:日本出口 search/get type=10「陈奕迅 U87」。
const neJPAlbumSearchU87 = `{"code":200,"result":{"hlWords":["84"],"albums":[{"id":409999020,"name":"84","artist":{"name":"格格"},"artists":[{"name":"格格"}]},{"id":1655301,"name":"Bach: The Well-Tempered Clavier, Book I, BWV 846-869 (The Glenn Gould Edition)","artist":{"name":"Glenn Gould"},"artists":[{"name":"Glenn Gould"}],"transNames":["巴赫：平均律键盘曲集，第一卷"]},{"id":409668552,"name":"84","artist":{"name":"YY"},"artists":[{"name":"YY"}]},{"id":261611637,"name":"惊艳全场的歌曲84","artist":{"name":"摸鱼的TONY"},"artists":[{"name":"摸鱼的TONY"}]},{"id":3029115,"name":"最新热歌慢摇84","artist":{"name":"Various Artists"},"artists":[{"name":"Various Artists"}]}]}}`

// neAlbumSearchTheBook:美国出口 search/get type=10「YOASOBI THE BOOK」。
const neAlbumSearchTheBook = `{"code":200,"result":{"hlWords":["YOASOBI THE BOOK"],"albums":[{"id":99079344,"name":"THE BOOK","artist":{"name":"YOASOBI"},"artists":[{"name":"YOASOBI"}]},{"id":379547126,"name":"THE BOOK for,","artist":{"name":"YOASOBI"},"artists":[{"name":"YOASOBI"}]},{"id":175201425,"name":"THE BOOK 3","artist":{"name":"YOASOBI"},"artists":[{"name":"YOASOBI"}]},{"id":135888000,"name":"THE BOOK 2","artist":{"name":"YOASOBI"},"artists":[{"name":"YOASOBI"}]},{"id":268116075,"name":"IKKI OGUMA PLAYS YOASOBI THE BOOK","artist":{"name":"IKKI OGUMA"},"artists":[{"name":"IKKI OGUMA"}]}]}}`

// neCloudAlbumSearchTheBook:日本出口 cloudsearch type=10「YOASOBI THE BOOK」(没有 hlWords)。
const neCloudAlbumSearchTheBook = `{"code":200,"result":{"albums":[{"id":99079344,"name":"THE BOOK","artist":{"name":"YOASOBI"},"artists":[{"name":"YOASOBI"}]},{"id":379547126,"name":"THE BOOK for,","artist":{"name":"YOASOBI"},"artists":[{"name":"YOASOBI"}]},{"id":175201425,"name":"THE BOOK 3","artist":{"name":"YOASOBI"},"artists":[{"name":"YOASOBI"}]},{"id":135888000,"name":"THE BOOK 2","artist":{"name":"YOASOBI"},"artists":[{"name":"YOASOBI"}]},{"id":268116075,"name":"IKKI OGUMA PLAYS YOASOBI THE BOOK","artist":{"name":"IKKI OGUMA"},"artists":[{"name":"IKKI OGUMA"}]}]}}`

// neAlbumSearchAngham:韩国出口 search/get type=10「Angham تيجي نسيب」:网易云没有这张,结果都不相干,hlWords 是查询词。
const neAlbumSearchAngham = `{"code":200,"result":{"hlWords":["Angham تيجي نسيب"],"albums":[{"id":165176455,"name":"Anemouhagh","artist":{"name":"Tinariwen"},"artists":[{"name":"Tinariwen"}]},{"id":34702617,"name":"Нәзігім","artist":{"name":"Нұрым Қуаныш"},"artists":[{"name":"Нұрым Қуаныш"}]},{"id":2505138,"name":"רבע לשש","artist":{"name":"Idan Raichel"},"artists":[{"name":"Idan Raichel"}]},{"id":141311877,"name":"걘","artist":{"name":"C Jamm"},"artists":[{"name":"C Jamm"}],"transNames":["Ghenn"]}]}}`

// neJPLyricSearchYoru:日本出口 search/get type=1006「沈むように溶けてゆくように」。
const neJPLyricSearchYoru = `{"code":200,"result":{"songs":[{"id":1930107573,"name":"Scopin","artists":[{"name":"Kordhell（Mick Kenny）"}],"album":{"id":142143556,"name":"Scopin"},"duration":101632,"lyrics":{"txt":"i got that gauge 38 and that four five glock\ndeep in the bushes see i'm scooping with that red dart\ni got that, i got that, i got that four five glock"}},{"id":1884668957,"name":"HEADLIGHTS FLASHES","artists":[{"name":"HXVRMXN"}],"album":{"id":134349528,"name":"SWITCHING LANES"},"duration":147940,"lyrics":{"txt":"i ain't barrin' that shit, quick to up my fuckin' gat\nblow a nigga ass off, b***h that's just how i react\ni'm a real nigga all about my fuckin killin'"}},{"id":150562,"name":"宫保鸡丁","artists":[{"name":"陶喆"}],"album":{"id":15190,"name":"黑色柳丁"},"duration":234466,"lyrics":{"txt":"我有一只小毛驴我从来也不骑\n有一天我心血来潮骑着去赶集\n在我记忆中从来没有这么热的夏天"}}]}}`

// neLyricSearchYoru:美国出口 search/get type=1006「沈むように溶けてゆくように」。
const neLyricSearchYoru = `{"code":200,"result":{"songs":[{"id":1409311773,"name":"夜に駆ける","artists":[{"name":"YOASOBI"}],"album":{"id":84072830,"name":"夜に駆ける"},"duration":261013,"transNames":["向夜晚奔去"],"lyrics":{"txt":"沈むように溶けてゆくように\n二人だけの空が广がる夜に\n「さよなら」だけだった"}},{"id":1500151583,"name":"夜に駆ける","artists":[{"name":"YOASOBI"}],"album":{"id":99079344,"name":"THE BOOK"},"duration":258840,"transNames":["向夜晚奔去"],"lyrics":{"txt":"沈むように溶けてゆくように\n二人だけの空が广がる夜に\n「さよなら」だけだった"}},{"id":1935705494,"name":"夜に駆ける (feat. 宵崎奏 & 初音ミク)","artists":[{"name":"Ayase"},{"name":"25時、ナイトコードで。"},{"name":"初音ミク"}],"album":{"id":143084582,"name":"25時、ナイトコードで。 SEKAI ALBUM vol.1"},"duration":260053,"transNames":["向黑夜奔去"],"lyrics":{"txt":"沈むように溶けてゆくように\n二人だけの空が广がる夜に\n「さよなら」だけだった"}}]}}`

// neCloudLyricSearchYoru:日本出口 cloudsearch type=1006「沈むように溶けてゆくように」。
const neCloudLyricSearchYoru = `{"code":200,"result":{"songs":[{"id":1409311773,"name":"夜に駆ける","ar":[{"name":"YOASOBI"}],"al":{"id":84072830,"name":"夜に駆ける"},"dt":261013,"tns":["向夜晚奔去"],"lyrics":["<b>沈むように溶けてゆくように</b>","二人だけの空が广がる夜に","「さよなら」だけだった"]},{"id":1500151583,"name":"夜に駆ける","ar":[{"name":"YOASOBI"}],"al":{"id":99079344,"name":"THE BOOK"},"dt":258840,"tns":["向夜晚奔去"],"lyrics":["<b>沈むように溶けてゆくように</b>","二人だけの空が广がる夜に","「さよなら」だけだった"]},{"id":1935705494,"name":"夜に駆ける (feat. 宵崎奏 & 初音ミク)","ar":[{"name":"Ayase"},{"name":"25時、ナイトコードで。"},{"name":"初音ミク"}],"al":{"id":143084582,"name":"25時、ナイトコードで。 SEKAI ALBUM vol.1"},"dt":260053,"tns":["向黑夜奔去"],"lyrics":["<b>沈むように溶けてゆくように</b>","二人だけの空が广がる夜に","「さよなら」だけだった"]}]}}`

const neQueryYoru = "沈むように溶けてゆくように"

func TestNeteaseAlbumSearchVerdict(t *testing.T) {
	cases := []struct {
		name, body, q string
		usable        bool
	}{
		{"日本出口:拉丁查询词", neJPAlbumSearchTheBook, "YOASOBI THE BOOK", false},
		{"日本出口:中文查询词", neJPAlbumSearchU87, "陈奕迅 U87", false},
		{"加密串", neJPSearchWebEncrypted, "YOASOBI THE BOOK", false},
		{"albums 解不开", `{"code":200,"result":{"albums":"x"}}`, "YOASOBI THE BOOK", false},
		{"正常返回", neAlbumSearchTheBook, "YOASOBI THE BOOK", true},
		{"cloudsearch", neCloudAlbumSearchTheBook, "YOASOBI THE BOOK", true},
		{"网易云没有:结果不相干、hlWords 是查询词", neAlbumSearchAngham, "Angham تيجي نسيب", true},
		{"结果不相干、hlWords 也不相干", `{"code":200,"result":{"hlWords":["-53"],"albums":[{"id":1,"name":"Anemouhagh","artist":{"name":"Tinariwen"}}]}}`, "Angham تيجي نسيب", false},
		{"没有 result", `{"code":200}`, "YOASOBI THE BOOK", true},
		{"一张都没有", `{"code":200,"result":{"albumCount":0}}`, "YOASOBI THE BOOK", true},
		{"只有歌手沾边", `{"code":200,"result":{"albums":[{"id":1,"name":"七","artist":{"name":"陈奕迅"}}]}}`, "陈奕迅 不存在的专辑", true},
		{"只有合作歌手沾边", `{"code":200,"result":{"albums":[{"id":1,"name":"X","artist":{"name":"A"},"artists":[{"name":"A"},{"name":"陈奕迅"}]}]}}`, "陈奕迅 不存在的专辑", true},
		{"只有别名沾边", `{"code":200,"result":{"albums":[{"id":1,"name":"X","artist":{"name":"A"},"alias":["Wonderland"]}]}}`, "Wonderland", true},
		{"只有译名沾边", `{"code":200,"result":{"albums":[{"id":1,"name":"X","artist":{"name":"A"},"transNames":["Wonderland"]}]}}`, "Wonderland", true},
	}
	for _, c := range cases {
		a := neteaseAlbumSearchVerdict(neResultOf(t, c.body), c.q)
		if (a.why == "") != c.usable {
			t.Errorf("%s: 能用 = %v(%q),应当是 %v", c.name, a.why == "", a.why, c.usable)
		}
	}
}

func TestNeteaseSongSearchVerdict(t *testing.T) {
	cases := []struct {
		name, body, q string
		usable        bool
	}{
		{"日本出口:按歌词搜", neJPLyricSearchYoru, neQueryYoru, false},
		{"日本出口:按歌手泛搜", neJPSearchKokoronashi, "majiko 心做し", false},
		{"加密串", neJPSearchWebEncrypted, neQueryYoru, false},
		{"正常返回:只有带回的歌词沾边", neLyricSearchYoru, neQueryYoru, true},
		{"cloudsearch:歌词是一组字符串", neCloudLyricSearchYoru, neQueryYoru, true},
		{"cloudsearch:字段名 ar / al / alia / tns", neCloudSearchKokoronashi, "Kokoronashi", true},
		{"正常泛搜", neSearchKokoronashi, "majiko 心做し", true},
		{"一首都没有", `{"code":200,"result":{"songCount":0}}`, neQueryYoru, true},
		{"歌词是认不出的写法", `{"code":200,"result":{"songs":[{"name":"A","artists":[{"name":"B"}],"lyrics":5}]}}`, neQueryYoru, false},
		{"cloudsearch 专辑名沾边", `{"code":200,"result":{"songs":[{"name":"A","ar":[{"name":"B"}],"al":{"name":"Contrast"}}]}}`, "Contrast", true},
		{"cloudsearch 歌手沾边", `{"code":200,"result":{"songs":[{"name":"A","ar":[{"name":"majiko"}],"al":{"name":"C"}}]}}`, "majiko", true},
		{"别名沾边", `{"code":200,"result":{"songs":[{"name":"A","artists":[{"name":"B"}],"alias":["Kokoronashi"]}]}}`, "Kokoronashi", true},
		{"译名沾边", `{"code":200,"result":{"songs":[{"name":"A","artists":[{"name":"B"}],"transNames":["Kokoronashi"]}]}}`, "Kokoronashi", true},
		{"cloudsearch 别名沾边", `{"code":200,"result":{"songs":[{"name":"A","ar":[{"name":"B"}],"alia":["Kokoronashi"]}]}}`, "Kokoronashi", true},
		{"cloudsearch 译名沾边", `{"code":200,"result":{"songs":[{"name":"A","ar":[{"name":"B"}],"tns":["Kokoronashi"]}]}}`, "Kokoronashi", true},
	}
	for _, c := range cases {
		a := neteaseSongSearchVerdict(neResultOf(t, c.body), c.q, normLooseUncached)
		if (a.why == "") != c.usable {
			t.Errorf("%s: 能用 = %v(%q),应当是 %v", c.name, a.why == "", a.why, c.usable)
		}
	}
	a := neteaseSongSearchVerdict(neResultOf(t, neCloudLyricSearchYoru), neQueryYoru, normLooseUncached)
	if len(a.val) != 3 || a.val[0].Name != "夜に駆ける" || a.val[0].Duration != 261013 || len(a.val[0].Artists) != 1 || a.val[0].Artists[0].Name != "YOASOBI" {
		t.Fatalf("cloudsearch 的 ar / dt 该归一回来: %+v", a.val)
	}
	a = neteaseSongSearchVerdict(neResultOf(t, neLyricSearchYoru), neQueryYoru, normLooseUncached)
	if len(a.val) != 3 || a.val[0].Duration != 261013 || a.val[0].Artists[0].Name != "YOASOBI" {
		t.Fatalf("search/get 的字段原样: %+v", a.val)
	}
}

func neResultOf(t *testing.T, body string) json.RawMessage {
	t.Helper()
	var r struct {
		Result json.RawMessage `json:"result"`
	}
	if err := json.Unmarshal([]byte(body), &r); err != nil {
		t.Fatal(err)
	}
	return r.Result
}

// 日本出口:search/get 和 eapi 答无关的结果,/web 答加密串,cloudsearch 答对的。
func neJapanEgressFor(junk, cloud string) func(string) (int, string) {
	return func(target string) (int, string) {
		switch target {
		case neSearchGet, neSearchEapi:
			return http.StatusOK, junk
		case neSearchWeb:
			return http.StatusOK, neJPSearchWebEncrypted
		case neSearchCloud:
			return http.StatusOK, cloud
		}
		return http.StatusNotFound, ""
	}
}

func neAskedEachOnce(t *testing.T, f *neFake) {
	t.Helper()
	for _, target := range []string{neSearchGet, neSearchWeb, neSearchEapi, neSearchCloud} {
		if f.count(target) != 1 {
			t.Errorf("%s 该问一次,问了 %d 次", target, f.count(target))
		}
	}
}

func TestNeteaseAlbumIDByNameFallsThroughJapanEgressGarbage(t *testing.T) {
	f := withNeteaseFake(t, neJapanEgressFor(neJPAlbumSearchTheBook, neCloudAlbumSearchTheBook))
	if id, ok := neteaseAlbumIDByName(qqRoundCtx(), "YOASOBI", "THE BOOK"); !ok || id != 99079344 {
		t.Fatalf("该从 cloudsearch 拿到 THE BOOK: %d %v", id, ok)
	}
	neAskedEachOnce(t, f)
}

func TestNeteaseSongSearchFallsThroughJapanEgressGarbage(t *testing.T) {
	f := withNeteaseFake(t, neJapanEgressFor(neJPSearchKokoronashi, neCloudSearchKokoronashi))
	if found, _, ok := retryTitleFromArtistSearchDetailed(qqRoundCtx(), "majiko", "心做し", 273.583); !ok || found != "心做し" {
		t.Fatalf("按歌手泛搜该从 cloudsearch 拿到心做し: %q %v", found, ok)
	}
	neAskedEachOnce(t, f)

	f = withNeteaseFake(t, neJapanEgressFor(neJPLyricSearchYoru, neCloudLyricSearchYoru))
	samples := []string{"[00:01.00]" + neQueryYoru + "\n[00:05.00]x"}
	title, artist, _, ok := retryTitleFromLyricSearchDetailed(qqRoundCtx(), []string{"YOASOBI"}, samples, 261.0)
	if !ok || title != "夜に駆ける" || artist != "YOASOBI" {
		t.Fatalf("按歌词搜该从 cloudsearch 拿到夜に駆ける: %q %q %v", title, artist, ok)
	}
	neAskedEachOnce(t, f)
}

// 正常地区:首选答得能用就收工,一个请求都不多打。
func TestNeteaseAlbumAndSongSearchNormalEgressAsksOnlyPrimary(t *testing.T) {
	cases := []struct {
		name, body string
		run        func() bool
	}{
		{"专辑", neAlbumSearchTheBook, func() bool {
			id, ok := neteaseAlbumIDByName(qqRoundCtx(), "YOASOBI", "THE BOOK")
			return ok && id == 99079344
		}},
		{"泛搜", neSearchKokoronashi, func() bool {
			found, _, ok := retryTitleFromArtistSearchDetailed(qqRoundCtx(), "majiko", "心做し", 273.583)
			return ok && found == "心做し"
		}},
		{"按歌词搜", neLyricSearchYoru, func() bool {
			songs, ok := neteaseSongSearch(qqRoundCtx(), neteaseSearchTypeLyric, 10, neQueryYoru)
			return ok && len(songs) == 3 && songs[0].Name == "夜に駆ける"
		}},
	}
	for _, c := range cases {
		f := withNeteaseFake(t, func(target string) (int, string) {
			if target == neSearchGet {
				return http.StatusOK, c.body
			}
			return http.StatusOK, neAlbumSearchTheBook
		})
		if !c.run() {
			t.Errorf("%s: 该原样拿到首选那条的结果", c.name)
		}
		if n := f.count(neSearchWeb) + f.count(neSearchEapi) + f.count(neSearchCloud); n != 0 || f.count(neSearchGet) != 1 {
			t.Errorf("%s: 首选答得能用,只该问它一次(get=%d,别的 %d)", c.name, f.count(neSearchGet), n)
		}
	}
}

// 网易云真没有:空结果、或模糊结果跟歌手沾边,都只问首选一次。
func TestNeteaseAlbumAndSongSearchMissingAsksOnlyPrimary(t *testing.T) {
	for _, c := range []struct{ body, artist string }{
		{`{"code":200,"result":{"albumCount":0}}`, "陈奕迅"},
		{`{"code":200,"result":{"albums":[{"id":6530,"name":"七","artist":{"name":"陈奕迅"}}]}}`, "陈奕迅"},
		{neAlbumSearchAngham, "Angham"},
	} {
		body := c.body
		f := withNeteaseFake(t, func(target string) (int, string) {
			if target == neSearchGet {
				return http.StatusOK, body
			}
			return http.StatusOK, neAlbumSearchTheBook
		})
		q := "不存在的专辑"
		if c.artist == "Angham" {
			q = "تيجي نسيب"
		}
		if id, ok := neteaseAlbumIDByName(qqRoundCtx(), c.artist, q); ok {
			t.Errorf("没有这张专辑: %d", id)
		}
		if f.count(neSearchGet) != 1 || f.count(neSearchWeb)+f.count(neSearchEapi)+f.count(neSearchCloud) != 0 {
			t.Errorf("%s: 只该问首选一次", body)
		}
	}
	for _, body := range []string{
		`{"code":200,"result":{"songCount":0}}`,
		`{"code":200,"result":{"songs":[{"name":"十年","duration":205000,"artists":[{"name":"陈奕迅"}]}]}}`,
	} {
		f := withNeteaseFake(t, func(target string) (int, string) {
			if target == neSearchGet {
				return http.StatusOK, body
			}
			return http.StatusOK, neCloudSearchKokoronashi
		})
		if found, _, ok := retryTitleFromArtistSearchDetailed(qqRoundCtx(), "陈奕迅", "不存在的歌", 300); ok {
			t.Errorf("没有这首: %q", found)
		}
		if f.count(neSearchGet) != 1 || f.count(neSearchWeb)+f.count(neSearchEapi)+f.count(neSearchCloud) != 0 {
			t.Errorf("%s: 只该问首选一次", body)
		}
	}
}

// 各条都不能用时跟只问首选一样:有解得开的交首选那份(专辑挑不出、泛搜拿到那份);一份都没有算没问成。
func TestNeteaseAlbumAndSongSearchAllPathsUnusable(t *testing.T) {
	junkThenDown := func(junk string) func(string) (int, string) {
		return func(target string) (int, string) {
			switch target {
			case neSearchGet, neSearchEapi:
				return http.StatusOK, junk
			case neSearchWeb:
				return http.StatusOK, neJPSearchWebEncrypted
			}
			return http.StatusInternalServerError, ""
		}
	}
	withNeteaseFake(t, junkThenDown(neJPAlbumSearchTheBook))
	if id, ok := neteaseAlbumIDByName(qqRoundCtx(), "YOASOBI", "THE BOOK"); ok {
		t.Fatalf("各条都不能用,挑不出专辑: %d", id)
	}
	withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case neSearchGet:
			return http.StatusOK, neJPSearchKokoronashi
		case neSearchEapi:
			return http.StatusOK, neJPSearchSunnyDay
		case neSearchWeb:
			return http.StatusOK, neJPSearchWebEncrypted
		}
		return http.StatusInternalServerError, ""
	})
	songs, ok := neteaseSongSearch(qqRoundCtx(), neteaseSearchTypeSong, 30, "majiko 心做し")
	if !ok || len(songs) != 3 || songs[0].Name != "-89" {
		t.Fatalf("cloudsearch 没问成时交回首选那份: %+v %v", songs, ok)
	}

	f := withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchCloud {
			return http.StatusOK, `{"code":200,"result":{"songCount":0}}`
		}
		return junkThenDown(neJPSearchKokoronashi)(target)
	})
	songs, ok = neteaseSongSearch(qqRoundCtx(), neteaseSearchTypeSong, 30, "majiko 心做し")
	if !ok || len(songs) != 3 || songs[0].Name != "-89" || f.count(neSearchCloud) != 1 {
		t.Fatalf("cloudsearch 答空时交回首选那份: %+v %v", songs, ok)
	}
	neteaseSearchJunkMu.Lock()
	n := len(neteaseSearchJunk)
	neteaseSearchJunkMu.Unlock()
	if n != 0 {
		t.Error("cloudsearch 答空算不上前面答垃圾的实证")
	}

	withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchWeb {
			return http.StatusOK, neJPSearchWebEncrypted
		}
		return http.StatusInternalServerError, ""
	})
	if songs, ok := neteaseSongSearch(qqRoundCtx(), neteaseSearchTypeSong, 30, "majiko 心做し"); ok {
		t.Fatalf("只有加密串、别的都没问成,算没问成: %+v", songs)
	}
	withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchCloud {
			return http.StatusOK, neJPSearchWebEncrypted
		}
		return http.StatusInternalServerError, ""
	})
	if songs, ok := neteaseSongSearch(qqRoundCtx(), neteaseSearchTypeSong, 30, "majiko 心做し"); ok {
		t.Fatalf("cloudsearch 也答加密串,算没问成: %+v", songs)
	}
}

// cloudsearch 也被拒(code 405)时退避它那个桶,跟别的路径一样。
func TestNeteaseSongSearchCloudRejectionBacksOff(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchCloud {
			return http.StatusOK, `{"code":405}`
		}
		return http.StatusInternalServerError, ""
	})
	if _, ok := neteaseSongSearch(qqRoundCtx(), neteaseSearchTypeSong, 30, "majiko 心做し"); ok {
		t.Fatal("都没问成")
	}
	neteaseRateMu.Lock()
	_, cooling := neteaseCooldownUntil[neteaseEndpointBucket(neteaseCloudSearchEndpoint)]
	neteaseRateMu.Unlock()
	if !cooling {
		t.Fatal("cloudsearch 被拒该退避它的桶")
	}
}

// 实证答垃圾、跳过 30 分钟是按路径记的,搜歌、搜专辑、泛搜共用:哪种搜索实证的,别的搜索也跳过。
func TestNeteaseSearchJunkSkipIsSharedAcrossSearches(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case neSearchGet, neSearchEapi:
			return http.StatusOK, neJPAlbumSearchTheBook
		case neSearchWeb:
			return http.StatusOK, neJPSearchWebEncrypted
		}
		return http.StatusOK, neCloudAlbumSearchTheBook
	})
	for i := 0; i < 2; i++ {
		if id, ok := neteaseAlbumIDByName(qqRoundCtx(), "YOASOBI", "THE BOOK"); !ok || id != 99079344 {
			t.Fatalf("第 %d 次: %d %v", i+1, id, ok)
		}
	}
	if f.count(neSearchGet) != 2 || f.count(neSearchCloud) != 2 {
		t.Fatalf("两次都该一路问到 cloudsearch: get=%d cloud=%d", f.count(neSearchGet), f.count(neSearchCloud))
	}
	if id, ok := neteaseAlbumIDByName(qqRoundCtx(), "YOASOBI", "THE BOOK"); !ok || id != 99079344 || f.count(neSearchGet) != 2 || f.count(neSearchCloud) != 3 {
		t.Fatalf("第 3 次该直接问 cloudsearch: %d %v get=%d", id, ok, f.count(neSearchGet))
	}
	_, _ = neteaseSongSearch(qqRoundCtx(), neteaseSearchTypeSong, 30, "YOASOBI アイドル")
	_, _ = neteaseSearchSongs(neteaseTestGet(), "YOASOBI アイドル")
	if f.count(neSearchGet) != 2 || f.count(neSearchWeb) != 2 || f.count(neSearchEapi) != 2 {
		t.Fatalf("专辑搜索实证过的路径,搜歌也跳过: get=%d web=%d eapi=%d", f.count(neSearchGet), f.count(neSearchWeb), f.count(neSearchEapi))
	}

}

// 按歌词搜判沾边时,歌词和查询词(一句歌词)都不进 normLoose 的备忘表:歌词几乎不重复,进了会把真会重复用到的条目冲掉。
func TestNeteaseLyricSearchKeepsLyricsOutOfNormLooseMemo(t *testing.T) {
	const txt = "沈むように溶けてゆくように\n二人だけの空が广がる夜に\n「さよなら」だけだった"
	withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchGet {
			return http.StatusOK, neLyricSearchYoru
		}
		return http.StatusInternalServerError, ""
	})
	if songs, ok := neteaseSongSearch(qqRoundCtx(), neteaseSearchTypeLyric, 10, neQueryYoru); !ok || len(songs) != 3 {
		t.Fatalf("该拿到首选那份: %+v %v", songs, ok)
	}
	normLooseMemoMu.RLock()
	_, lyric := normLooseMemo[txt]
	_, query := normLooseMemo[neQueryYoru]
	normLooseMemoMu.RUnlock()
	if lyric || query {
		t.Fatalf("歌词 %v、查询词 %v 进了备忘表", lyric, query)
	}
}

// 搜索路径答了(没被拒)记成「网易云这次进程里成功过」,给歌词源可用情况判要不要把限流报成原因。
func TestNeteaseSearchResultNotesSuccess(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		return http.StatusOK, neAlbumSearchTheBook
	})
	neteaseRateMu.Lock()
	saved := neteaseAnySuccess
	neteaseAnySuccess = false
	neteaseRateMu.Unlock()
	t.Cleanup(func() {
		neteaseRateMu.Lock()
		neteaseAnySuccess = saved
		neteaseRateMu.Unlock()
	})
	if _, ok := neteaseAlbumIDByName(qqRoundCtx(), "YOASOBI", "THE BOOK"); !ok {
		t.Fatal("该认出 THE BOOK")
	}
	if !neteaseSawSuccessNow() {
		t.Fatal("答了该记成功过")
	}
}

// 一份解得开的都没有时交前三条的真实错误(这里是被拒),不交 cloudsearch 的。
func TestNeteaseSearchPathsKeepsEarlierError(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchEapi {
			return http.StatusOK, `{"code":405}`
		}
		return http.StatusInternalServerError, ""
	})
	if _, err := neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi); !errors.Is(err, errNeteaseTestRejected) {
		t.Fatalf("该交前三条的错误: %v", err)
	}
}
