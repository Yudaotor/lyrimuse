package main

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// 下面几份是 music.163.com 在不同出口实测的返回(Globalping 探针,limit=3,只留用到的字段)。

// neJPSearchKokoronashi:日本出口 search/get「心做し majiko」。
const neJPSearchKokoronashi = `{"code":200,"result":{"songs":[{"id":3425122938,"name":"-89","artists":[{"id":123620370,"name":"Waliii7"}],"album":{"id":394268460,"name":"-89"},"duration":132290},{"id":109198,"name":"恋曲1990","alias":["电影《阿郎的故事》普通话版主题曲"],"artists":[{"id":3686,"name":"罗大佑"}],"album":{"id":10825,"name":"昨日情歌74-89"},"duration":315906},{"id":109195,"name":"你的样子","alias":["电影《阿郎的故事》片尾曲"],"artists":[{"id":3686,"name":"罗大佑"}],"album":{"id":10825,"name":"昨日情歌74-89"},"duration":210026}]}}`

// neSearchKokoronashi:美国出口 search/get「心做し majiko」。
const neSearchKokoronashi = `{"code":200,"result":{"songs":[{"id":31421443,"name":"心做し","alias":["Kokoronashi"],"transNames":["心理作用"],"artists":[{"id":191316,"name":"majiko"}],"album":{"id":3119399,"name":"Contrast"},"duration":273583},{"id":1911198831,"name":"心做し (Live At 渋谷WWW X / 2017)","transNames":["心理作用"],"artists":[{"id":191316,"name":"majiko"}],"album":{"id":138734703,"name":"Live 2017"},"duration":305542},{"id":31134451,"name":"心做し","alias":["Kokoronashi"],"transNames":["心理作用"],"artists":[{"id":191316,"name":"majiko"}],"album":{"id":3112341,"name":"心做し"},"duration":273583}]}}`

// neCloudSearchKokoronashi:日本出口 cloudsearch/pc「心做し majiko」。
const neCloudSearchKokoronashi = `{"code":200,"result":{"songs":[{"id":31421443,"name":"心做し","alia":["Kokoronashi"],"tns":["心理作用"],"ar":[{"id":191316,"name":"majiko"}],"al":{"id":3119399,"name":"Contrast"},"dt":273583},{"id":1911198831,"name":"心做し (Live At 渋谷WWW X / 2017)","tns":["心理作用"],"ar":[{"id":191316,"name":"majiko"}],"al":{"id":138734703,"name":"Live 2017"},"dt":305542},{"id":31134451,"name":"心做し","alia":["Kokoronashi"],"tns":["心理作用"],"ar":[{"id":191316,"name":"majiko"}],"al":{"id":3112341,"name":"心做し"},"dt":273583}]}}`

// neJPSearchYoasobiIdol:日本出口 search/get「YOASOBI Idol」。
const neJPSearchYoasobiIdol = `{"code":200,"result":{"songs":[{"id":2081780144,"name":"CCTV-14","transNames":["少儿频道"],"artists":[{"id":56054279,"name":"Yxng Amiri"},{"id":51450084,"name":"用户745236988"}],"album":{"id":174675142,"name":"Love Songs 4 My Street"},"duration":155062},{"id":29450266,"name":"Apple","artists":[{"id":15566,"name":"TOWA TEI"}],"album":{"id":3029040,"name":"94-14"},"duration":236518},{"id":22728975,"name":"14歳","artists":[{"id":18480,"name":"amazarashi"}],"album":{"id":2086702,"name":"千年幸福論\u3000"},"duration":392092}]}}`

// neJPSearchSunnyDay:日本出口 search/get「晴天 周杰伦」。
const neJPSearchSunnyDay = `{"code":200,"result":{"songs":[{"id":1371714108,"name":"85%","artists":[{"id":12408152,"name":"Loote"},{"id":1137226,"name":"gnash"}],"album":{"id":79787129,"name":"lost"},"duration":174093},{"id":1371711963,"name":"85%","artists":[{"id":12408152,"name":"Loote"},{"id":1137226,"name":"gnash"}],"album":{"id":79787116,"name":"lost"},"duration":174099},{"id":434974549,"name":"85","artists":[{"id":711232,"name":"illion"}],"album":{"id":34899462,"name":"P.Y.L"},"duration":277502}]}}`

// neJPSearchRacingIntoTheNight:日本出口 search/get「夜に駆ける YOASOBI」。
const neJPSearchRacingIntoTheNight = `{"code":200,"result":{"songs":[{"id":2139033235,"name":"15(Prod.TurnItUpKaRon)","artists":[{"id":14117457,"name":"SASIOVERLXRD"}],"album":{"id":190000663,"name":"那小子真帅"},"duration":192096},{"id":2674876888,"name":"15 Minutes","artists":[{"id":77993,"name":"Sabrina Carpenter"}],"album":{"id":262762990,"name":"Short n' Sweet (Deluxe)"},"duration":191519},{"id":1942981991,"name":"15th Floor","artists":[{"id":12031126,"name":"PREP"}],"album":{"id":144244705,"name":"15th Floor"},"duration":270868}]}}`

// neJPSearchWebEncrypted:日本出口 search/get/web「心做し majiko」,result 是加密串(截短)。
const neJPSearchWebEncrypted = `{"result":"35b1748964af8a7c1d883e3a6f3c773b3d42235da074ffe5a095beda502ab3e8b484ecf8bc8bca7a477e0dfd77f17c48","abroad":true,"code":200}`

const (
	neQueryKokoronashi = "心做し majiko"
	neSearchGet        = "music.163.com/api/search/get"
	neSearchWeb        = "music.163.com/api/search/get/web"
	neSearchEapi       = "music.163.com/eapi/search/get"
	neSearchCloud      = "music.163.com/api/cloudsearch/pc"
)

func neSearchVerdictOf(t *testing.T, body, q string) string {
	t.Helper()
	var r struct {
		Result json.RawMessage `json:"result"`
	}
	if err := json.Unmarshal([]byte(body), &r); err != nil {
		t.Fatal(err)
	}
	_, why := neteaseSearchVerdict(r.Result, q)
	return why
}

func TestNeteaseSearchVerdict(t *testing.T) {
	cases := []struct {
		name, body, q string
		usable        bool
	}{
		{"日本出口:心做し", neJPSearchKokoronashi, neQueryKokoronashi, false},
		{"日本出口:纯 ASCII 查询词", neJPSearchYoasobiIdol, "YOASOBI Idol", false},
		{"日本出口:中文查询词", neJPSearchSunnyDay, "晴天 周杰伦", false},
		{"日本出口:假名查询词", neJPSearchRacingIntoTheNight, "夜に駆ける YOASOBI", false},
		{"加密串", neJPSearchWebEncrypted, neQueryKokoronashi, false},
		{"songs 解不开", `{"code":200,"result":{"songs":"x"}}`, neQueryKokoronashi, false},
		{"正常返回", neSearchKokoronashi, neQueryKokoronashi, true},
		{"没有 result", `{"code":200}`, neQueryKokoronashi, true},
		{"result 是 null", `{"code":200,"result":null}`, neQueryKokoronashi, true},
		{"一首都没有", `{"code":200,"result":{"songCount":0}}`, neQueryKokoronashi, true},
		{"模糊结果只有歌手沾边", `{"code":200,"result":{"songs":[{"id":1,"name":"十年","artists":[{"name":"陈奕迅"}],"album":{"name":"黑白灰"}}]}}`, "陈奕迅 不存在的歌", true},
		{"只有专辑名沾边", `{"code":200,"result":{"songs":[{"id":1,"name":"Intro","artists":[{"name":"X"}],"album":{"name":"U87"}}]}}`, "陈奕迅 浮夸 U87", true},
		{"只有别名沾边", `{"code":200,"result":{"songs":[{"id":1,"name":"心做し","alias":["Kokoronashi"],"artists":[{"name":"majiko"}],"album":{"name":"Contrast"}}]}}`, "Kokoronashi", true},
		{"繁简", `{"code":200,"result":{"songs":[{"id":1,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"name":"U87"}}]}}`, "陳奕迅 浮誇", true},
		{"全角与大小写", `{"code":200,"result":{"songs":[{"id":1,"name":"アイドル","artists":[{"name":"YOASOBI"}],"album":{"name":"アイドル"}}]}}`, "ｙｏａｓｏｂｉ Idol", true},
		{"查询词连写、歌名在里面", `{"code":200,"result":{"songs":[{"id":1,"name":"浮夸","artists":[{"name":"Eason"}],"album":{"name":"U87"}}]}}`, "陈奕迅浮夸", true},
		{"查询词切不出词", `{"code":200,"result":{"songs":[{"id":1,"name":"B","artists":[{"name":"C"}],"album":{"name":"D"}}]}}`, "A", true},
	}
	for _, c := range cases {
		why := neSearchVerdictOf(t, c.body, c.q)
		if (why == "") != c.usable {
			t.Errorf("%s: 能用 = %v(%q),应当是 %v", c.name, why == "", why, c.usable)
		}
	}
}

// 日本出口:search/get 答无关的歌,/web 答加密串,eapi 同 search/get,一路退到 cloudsearch。
func neJapanEgress(target string) (int, string) {
	switch target {
	case neSearchGet, neSearchEapi:
		return http.StatusOK, neJPSearchKokoronashi
	case neSearchWeb:
		return http.StatusOK, neJPSearchWebEncrypted
	case neSearchCloud:
		return http.StatusOK, neCloudSearchKokoronashi
	}
	return http.StatusNotFound, ""
}

func TestNeteaseSearchSongsFallsThroughJapanEgressGarbage(t *testing.T) {
	f := withNeteaseFake(t, neJapanEgress)
	songs, err := neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi)
	if err != nil || len(songs) != 3 || songs[0].ID != 31421443 || songs[0].Name != "心做し" || songs[0].Artists[0].Name != "majiko" {
		t.Fatalf("该从 cloudsearch 拿到心做し: %+v %v", songs, err)
	}
	for _, target := range []string{neSearchGet, neSearchWeb, neSearchEapi, neSearchCloud} {
		if f.count(target) != 1 {
			t.Errorf("%s 该问一次,问了 %d 次", target, f.count(target))
		}
	}
	if f.count("interface.music.163.com/api/search/get") != 0 {
		t.Error("答了不能用的不换主机:换主机还是同一个接口")
	}
}

// 正常地区:首选那条答的能用就收工,一个请求都不多打。
func TestNeteaseSearchSongsNormalEgressAsksOnlyPrimary(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchGet {
			return http.StatusOK, neSearchKokoronashi
		}
		return http.StatusOK, neCloudSearchKokoronashi
	})
	songs, err := neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi)
	if err != nil || len(songs) != 3 || songs[0].ID != 31421443 {
		t.Fatalf("该原样拿到首选那条的结果: %+v %v", songs, err)
	}
	for _, target := range []string{neSearchWeb, neSearchEapi, neSearchCloud} {
		if f.count(target) != 0 {
			t.Errorf("首选答得能用,不该再问 %s", target)
		}
	}
}

// 网易云真没这首、只回模糊结果:沾边的照收,一个请求都不多打;一首都不沾边时四条都问过,交回首选那条的结果、不记垃圾。
func TestNeteaseSearchSongsFuzzyResultsForAMissingSong(t *testing.T) {
	const fuzzy = `{"code":200,"result":{"songs":[{"id":1,"name":"十年","artists":[{"name":"陈奕迅"}],"album":{"id":2,"name":"黑白灰"},"duration":205000}]}}`
	f := withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchGet {
			return http.StatusOK, fuzzy
		}
		return http.StatusOK, neCloudSearchKokoronashi
	})
	songs, err := neteaseSearchSongs(neteaseTestGet(), "陈奕迅 不存在的歌")
	if err != nil || len(songs) != 1 || songs[0].ID != 1 {
		t.Fatalf("模糊结果该照收: %+v %v", songs, err)
	}
	if f.count(neSearchWeb)+f.count(neSearchEapi)+f.count(neSearchCloud) != 0 {
		t.Error("有沾边的就不该再问别的路径")
	}

	const unrelated = `{"code":200,"result":{"songs":[{"id":7,"name":"Apple","artists":[{"name":"TOWA TEI"}],"album":{"id":8,"name":"94-14"},"duration":236518}]}}`
	const unrelatedCloud = `{"code":200,"result":{"songs":[{"id":9,"name":"Banana","ar":[{"name":"Y"}],"al":{"id":10,"name":"Z"},"dt":1000}]}}`
	f = withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchCloud {
			return http.StatusOK, unrelatedCloud
		}
		return http.StatusOK, unrelated
	})
	songs, err = neteaseSearchSongs(neteaseTestGet(), "Nobody Nothing")
	if err != nil || len(songs) != 1 || songs[0].ID != 7 {
		t.Fatalf("各条都不沾边时交回首选那条: %+v %v", songs, err)
	}
	if f.count(neSearchCloud) != 1 {
		t.Error("首选不沾边该一路问到 cloudsearch")
	}
	neteaseSearchJunkMu.Lock()
	n := len(neteaseSearchJunk)
	neteaseSearchJunkMu.Unlock()
	if n != 0 {
		t.Error("后面没有一条答得能用,算不上前面答垃圾的实证")
	}
}

// 都不能用时:有解得开的交第一份;一份都没有交真实错误,不吞。
func TestNeteaseSearchSongsAllPathsUnusable(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case neSearchGet:
			return http.StatusOK, neJPSearchKokoronashi
		case neSearchWeb:
			return http.StatusOK, neJPSearchWebEncrypted
		}
		return http.StatusInternalServerError, ""
	})
	songs, err := neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi)
	if err != nil || len(songs) != 3 || songs[0].ID != 3425122938 {
		t.Fatalf("cloudsearch 没问成时交回首选那份: %+v %v", songs, err)
	}

	withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchWeb {
			return http.StatusOK, neJPSearchWebEncrypted
		}
		return http.StatusInternalServerError, ""
	})
	if songs, err := neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi); err == nil || songs != nil {
		t.Fatalf("只有加密串、别的都没问成,该报错: %+v %v", songs, err)
	}
}

// 连着两次实证答垃圾的路径先跳过 30 分钟;到期照常问,答一次能用的就清零。
func TestNeteaseSearchSongsSkipsPathsProvenJunk(t *testing.T) {
	f := withNeteaseFake(t, neJapanEgress)
	now := time.Now()
	neteaseSearchJunkNow = func() time.Time { return now }
	for i := 0; i < 2; i++ {
		if songs, err := neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi); err != nil || len(songs) == 0 || songs[0].ID != 31421443 {
			t.Fatalf("第 %d 次: %+v %v", i+1, songs, err)
		}
	}
	if songs, err := neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi); err != nil || len(songs) == 0 || songs[0].ID != 31421443 {
		t.Fatalf("第 3 次: %+v %v", songs, err)
	}
	if f.count(neSearchGet) != 2 || f.count(neSearchWeb) != 2 || f.count(neSearchEapi) != 2 || f.count(neSearchCloud) != 3 {
		t.Fatalf("第 3 次该直接问 cloudsearch: get=%d web=%d eapi=%d cloud=%d",
			f.count(neSearchGet), f.count(neSearchWeb), f.count(neSearchEapi), f.count(neSearchCloud))
	}

	now = now.Add(neteaseSearchJunkSkipFor - time.Second)
	_, _ = neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi)
	if f.count(neSearchGet) != 2 {
		t.Fatal("没到期不该问")
	}
	now = now.Add(2 * time.Second)
	_, _ = neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi)
	if f.count(neSearchGet) != 3 {
		t.Fatal("到期该照常问一次")
	}
	_, _ = neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi)
	if f.count(neSearchGet) != 3 {
		t.Fatal("到期后还是垃圾,该立刻再跳过")
	}

	now = now.Add(neteaseSearchJunkSkipFor + time.Second)
	f2 := withNeteaseFake(t, func(target string) (int, string) {
		if target == neSearchGet {
			return http.StatusOK, neSearchKokoronashi
		}
		return http.StatusOK, neCloudSearchKokoronashi
	})
	neteaseSearchJunk[neteaseSearchEndpointPrimary] = neteaseSearchJunkState{strikes: 5}
	if songs, err := neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi); err != nil || len(songs) == 0 || f2.count(neSearchGet) != 1 {
		t.Fatalf("没在跳过期内就照常问: %+v %v", songs, err)
	}
	neteaseSearchJunkMu.Lock()
	_, kept := neteaseSearchJunk[neteaseSearchEndpointPrimary]
	neteaseSearchJunkMu.Unlock()
	if kept {
		t.Error("答一次能用的该清零")
	}
}

// 只实证过一次的不跳过:正常地区偶尔一次排序不同,不该把首选桶让给限流更狠的 /web。
func TestNeteaseSearchSongsOneStrikeDoesNotSkip(t *testing.T) {
	f := withNeteaseFake(t, neJapanEgress)
	_, _ = neteaseSearchSongs(neteaseTestGet(), neQueryKokoronashi)
	_, _ = neteaseSearchSongs(neteaseTestGet(), "陈奕迅 浮夸")
	if f.count(neSearchGet) != 2 {
		t.Fatalf("只实证过一次,第二次照常先问首选: %d", f.count(neSearchGet))
	}
}
