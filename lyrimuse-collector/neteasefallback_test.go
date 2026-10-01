package main

import (
	"context"
	"crypto/aes"
	"crypto/md5"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// neFake 把网易云几个主机(真实主机名经改写的传输层)指到一个本地服务器,按 "主机/路径" 分发并计数。
// methods / bodies / ctypes 记每个目标最近一次请求的方法、请求体和 Content-Type(eapi 是 POST 表单)。
type neFake struct {
	mu      sync.Mutex
	hits    map[string]int
	cookies map[string]string
	methods map[string]string
	bodies  map[string]string
	ctypes  map[string]string
}

func (f *neFake) last(m map[string]string, key string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return m[key]
}

func (f *neFake) count(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[key]
}

func withNeteaseFake(t *testing.T, handle func(target string) (int, string)) *neFake {
	t.Helper()
	savedGuard, savedBreaker, savedTransport := sharedHostGuard(), sharedLyricSourceBreaker(), sharedLyricSourceTransport()
	setSharedHostGuard(newHostGuard(time.Now))
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	neteaseRateMu.Lock()
	savedCall, savedCooldown, savedStreak := neteaseLastCall, neteaseCooldownUntil, neteaseBlockStreak
	neteaseLastCall = time.Time{}
	neteaseCooldownUntil = map[string]time.Time{}
	neteaseBlockStreak = map[string]int{}
	neteaseRateMu.Unlock()
	t.Cleanup(func() {
		setSharedHostGuard(savedGuard)
		setSharedLyricSourceBreaker(savedBreaker)
		setSharedLyricSourceTransport(savedTransport)
		neteaseRateMu.Lock()
		neteaseLastCall, neteaseCooldownUntil, neteaseBlockStreak = savedCall, savedCooldown, savedStreak
		neteaseRateMu.Unlock()
	})
	f := &neFake{hits: map[string]int{}, cookies: map[string]string{}, methods: map[string]string{}, bodies: map[string]string{}, ctypes: map[string]string{}}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		target := host + r.URL.Path
		reqBody, _ := io.ReadAll(r.Body)
		f.mu.Lock()
		f.hits[target]++
		f.cookies[target] = r.Header.Get("Cookie")
		f.methods[target] = r.Method
		f.bodies[target] = string(reqBody)
		f.ctypes[target] = r.Header.Get("Content-Type")
		f.mu.Unlock()
		status, body := handle(target)
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	addr := srv.Listener.Addr().String()
	setSharedLyricSourceTransport(&http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	})
	return f
}

func TestNeteaseHostURLs(t *testing.T) {
	got := neteaseHostURLs("https://music.163.com/api/song/detail?ids=[1]")
	if len(got) != len(neteaseHosts) || !strings.HasPrefix(got[1], "https://interface.music.163.com/api/song/detail?") {
		t.Fatalf("该按主机展开: %v", got)
	}
	if got := neteaseHostURLs("https://p1.music.126.net/x.jpg"); len(got) != 1 {
		t.Fatalf("别的主机原样返回: %v", got)
	}
}

// 首选主机没问成就换下一个主机;响应体里的拒绝码不换主机(按路径分桶限流,换主机也是同一个桶),
// 而是由调用方换另一条路径。
func TestNeteaseFetchBodyHostFallbackAndNoHopOnRejection(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case "music.163.com/api/album/9":
			return http.StatusBadGateway, ""
		case "interface.music.163.com/api/album/9":
			return http.StatusOK, `{"code":200}`
		}
		return http.StatusNotFound, ""
	})
	body, err := neteaseFetchBody(qqRoundCtx(), "https://music.163.com/api/album/9", "os=pc", 4*time.Second)
	if err != nil || string(body) != `{"code":200}` {
		t.Fatalf("该从备用主机拿到: %s %v", body, err)
	}
	if f.cookies["interface.music.163.com/api/album/9"] != "os=pc" {
		t.Error("换了主机也要带上 cookie")
	}
	if f.count("interface3.music.163.com/api/album/9") != 0 {
		t.Error("拿到了就停")
	}

	f = withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case "music.163.com/api/search/get":
			return http.StatusOK, `{"result":{},"code":405}`
		case "music.163.com/api/search/get/web":
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":1,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":9,"name":"U87"},"duration":283000}]}}`
		}
		return http.StatusNotFound, ""
	})
	get := neteaseTestGet()
	songs, err := neteaseSearchSongs(get, "陈奕迅 浮夸")
	if err != nil || len(songs) != 1 {
		t.Fatalf("主路径被拒该换 /web 路径: %v %v", songs, err)
	}
	if f.count("interface.music.163.com/api/search/get") != 0 {
		t.Error("拒绝码不该换主机再撞同一个桶")
	}
}

// neteaseTestGet 复刻 resolveNeteaseInfo 里 get 的判定(200 + body 拒绝码当失败),给单测直接调搜索用。
func neteaseTestGet() func(string, any) error {
	return func(u string, v any) error {
		body, err := neteaseFetchBody(qqRoundCtx(), u, "", 4*time.Second)
		if err != nil {
			return err
		}
		if strings.Contains(string(body), `"code":405`) {
			return errNeteaseTestRejected
		}
		return jsonUnmarshalForTest(body, v)
	}
}

// 搜歌:search/get 两条路径几个主机都没问成,退到 cloudsearch,字段名 ar/al/dt 归一回来。
func TestNeteaseSearchSongsFallsBackToCloudSearch(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/api/search/get") || strings.HasSuffix(target, "/api/search/get/web") {
			return http.StatusInternalServerError, ""
		}
		if target == "music.163.com/api/cloudsearch/pc" {
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","dt":283520,"ar":[{"name":"陈奕迅"}],"al":{"id":6491,"name":"U87"}}]}}`
		}
		return http.StatusNotFound, ""
	})
	songs, err := neteaseSearchSongs(neteaseTestGet(), "陈奕迅 浮夸")
	if err != nil || len(songs) != 1 {
		t.Fatalf("该从 cloudsearch 拿到: %v %v", songs, err)
	}
	s := songs[0]
	if s.ID != 66282 || s.Name != "浮夸" || s.Duration != 283520 || s.Album.ID != 6491 || s.Album.Name != "U87" ||
		len(s.Artists) != 1 || s.Artists[0].Name != "陈奕迅" {
		t.Fatalf("字段没归一对: %+v", s)
	}
}

const neV1Lyric = `{"t":0,"c":[{"tx":"作词: "},{"tx":"黄伟文"}]}
{"t":800,"c":[{"tx":"作曲: "},{"tx":"C. Y. Kong"}]}
[00:28.948]有人问我 我就会讲
[00:36.141]我期待 到无奈
[00:44.000]第三句
[00:52.000]第四句`

func TestNeteaseV1LyricLines(t *testing.T) {
	got := neteaseV1LyricLines(neV1Lyric)
	want := "[00:00.00] 作词 : 黄伟文\n[00:00.80] 作曲 : C. Y. Kong\n[00:28.948]有人问我 我就会讲\n[00:36.141]我期待 到无奈\n[00:44.000]第三句\n[00:52.000]第四句"
	if got != want {
		t.Fatalf("JSON 署名行该换回老接口写法、正文原样:\n got %q\nwant %q", got, want)
	}
	if plain := "[00:01.00]a\n[00:02.00]b"; neteaseV1LyricLines(plain) != plain {
		t.Error("没有 JSON 行时原样返回")
	}
	// 纯文本歌词:署名行没有 t,老接口那边也不带时间戳。
	if got := neteaseV1LyricLines(`{"c":[{"tx":"作曲: "},{"tx":"John Deacon"}]}` + "\n[Intro]\nYeah!"); got != "作曲 : John Deacon\n[Intro]\nYeah!" {
		t.Errorf("没有 t 的署名行不该补时间戳: %q", got)
	}
	// 没词的曲目:署名的 t 是 -1,按 0 算,换完是只有署名的正文。
	if got := neteaseV1LyricLines(`{"t":-1,"c":[{"tx":"作曲: "},{"tx":"John Rzeznik"}]}` + "\n"); got != "[00:00.00] 作曲 : John Rzeznik\n" || !isCreditOnlyLRC(got) {
		t.Errorf("没词那种形状换完应只剩署名: %q", got)
	}
}

const neSearchOne = `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":6491,"name":"U87"},"duration":283520}]}}`

// 一个 v1 请求拿齐整行 / 译文 / 逐字,老歌词接口不再问。
func TestResolveNeteaseInfoFetchesBundleFromV1(t *testing.T) {
	const yrc = "[28948,2000](28948,500,0)有(29448,500,0)人"
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, neSearchOne
		case strings.HasSuffix(target, "/api/song/detail"):
			return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case target == "music.163.com/api/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(neV1Lyric) + `},"tlyric":{"lyric":"[00:28.948]译1\n[00:36.141]译2\n[00:44.000]译3"},"yrc":{"lyric":` + jsonQuoteForTest(yrc) + `}}`
		}
		return http.StatusNotFound, ""
	})
	info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
	if !strings.HasPrefix(info.Lyrics, "[00:00.00] 作词 : 黄伟文") || info.YRC != yrc || info.Trans == "" {
		t.Fatalf("整行 / 逐字 / 译文都该从 v1 一次拿到: lyrics=%q yrc=%q trans=%q", info.Lyrics, info.YRC, info.Trans)
	}
	if f.count("music.163.com/api/song/lyric") != 0 {
		t.Error("v1 答了就不该再问老歌词接口")
	}
	if f.count("music.163.com/api/song/lyric/v1") != 1 {
		t.Errorf("v1 该恰好问一次, got %d", f.count("music.163.com/api/song/lyric/v1"))
	}
}

// 端到端:单曲详情的老接口几个主机都挂了退到 v3;歌词的 v1 几个主机都挂了退到老接口(没有逐字)。
func TestResolveNeteaseInfoFallsBackForDetailAndLyric(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, neSearchOne
		case strings.HasSuffix(target, "/api/song/detail"), strings.HasSuffix(target, "/api/song/lyric/v1"):
			return http.StatusInternalServerError, ""
		case target == "music.163.com/api/v3/song/detail":
			return http.StatusOK, `{"code":200,"songs":[{"al":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case target == "music.163.com/api/song/lyric":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":"[00:00.00] 作词 : 黄伟文\n[00:28.948]有人问我 我就会讲\n[00:36.141]我期待 到无奈\n[00:44.000]第三句"}}`
		}
		return http.StatusNotFound, ""
	})
	info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
	if info.Cover != "http://p1.music.126.net/x.jpg"+neteaseCoverQuery {
		t.Errorf("封面该从 v3 详情拿到: %q", info.Cover)
	}
	if !strings.HasPrefix(info.Lyrics, "[00:00.00] 作词 : 黄伟文") || info.YRC != "" {
		t.Errorf("歌词该从老接口拿到、没有逐字: lyrics=%q yrc=%q", info.Lyrics, info.YRC)
	}
	for _, h := range neteaseHosts {
		if f.count(h+"/api/song/detail") != 1 || f.count(h+"/api/song/lyric/v1") != 1 {
			t.Errorf("老详情接口与 v1 歌词接口在 %s 上该各先试一次", h)
		}
	}
}

// 没词的曲目:v1 只给 JSON 署名行,换回老接口写法之后是只有署名的正文,判「曲库里有、平台没给词」。
func TestResolveNeteaseInfoNoLyricsFromV1Credits(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, neSearchOne
		case strings.HasSuffix(target, "/api/song/detail"):
			return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case target == "music.163.com/api/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(`{"t":-1,"c":[{"tx":"作曲: "},{"tx":"John Rzeznik"}]}`+"\n"+`{"t":-1,"c":[{"tx":"制作人: "},{"tx":"OLORUNNS"}]}`+"\n") + `}}`
		}
		return http.StatusNotFound, ""
	})
	info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
	if !info.TrackFoundNoLyrics || info.Lyrics != "" {
		t.Fatalf("只有署名应判成平台没词: noLyrics=%v lyrics=%q", info.TrackFoundNoLyrics, info.Lyrics)
	}
}

var errNeteaseTestRejected = errorString("netease test: rejected")

type errorString string

func (e errorString) Error() string { return string(e) }

func jsonUnmarshalForTest(b []byte, v any) error { return json.Unmarshal(b, v) }

func jsonQuoteForTest(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func neTestSong(id int64, name, artist, album string, secs float64) neSearchSong {
	var s neSearchSong
	s.ID, s.Name, s.Duration = id, name, secs*1000
	s.Album.Name = album
	s.Artists = append(s.Artists, struct {
		Name string `json:"name"`
	}{Name: artist})
	return s
}

// 身份挑不出时给歌词用的候选:时长最贴近的胜出,差 3% 以上、版本不符、歌手对不上又过不了三角验证的都不收。
func TestNeteaseLyricOnlyPick(t *testing.T) {
	const mj = "Michael Jackson"
	for _, c := range []struct {
		name                 string
		songs                []neSearchSong
		artist, title, album string
		dur                  float64
		want                 int64
	}{
		{"同名多版本、专辑都对不上:取版本对得上、时长最近的", []neSearchSong{
			neTestSong(1, "Rock With You", mj, "Off the Wall", 221),
			neTestSong(2, "Rock with You (Single Version)", mj, "The Ultimate Fan Extras Collection", 203),
			neTestSong(3, "Rock with You (Single Version)", mj, "The Indispensable Collection", 220),
		}, mj, "Rock With You (Single Version)", "世纪典藏", 204, 2},
		{"打平取排在前面的", []neSearchSong{
			neTestSong(4, "Leave Me Alone", mj, "Bad", 280),
			neTestSong(5, "Leave Me Alone", mj, "The Collection", 280),
		}, mj, "Leave Me Alone", "世纪典藏", 281, 4},
		{"时长差 3% 以上不收", []neSearchSong{neTestSong(5, "Human Nature", mj, "Thriller", 246)}, mj, "Human Nature (Single Version)", "世纪典藏", 227, 0},
		{"版本不符不收", []neSearchSong{neTestSong(6, "成全", "林宥嘉", "蒙面唱将猜猜猜", 310)}, "林宥嘉", "成全 (Live)", "THE GREAT YOGA 演唱会", 310, 0},
		{"歌手写法不同、三角验证成立", []neSearchSong{neTestSong(7, "随便", "关浩德Walter", "Just Be A Rock", 191)}, "关浩德", "随便", "Just Be a Rock", 191, 7},
		{"单曲、歌手毫无交集不收", []neSearchSong{neTestSong(8, "街角的晚风", "某翻唱", "街角的晚风", 155)}, "原唱", "街角的晚风", "街角的晚风", 155, 0},
		{"本地时长未知不给", []neSearchSong{neTestSong(9, "Leave Me Alone", mj, "Bad", 280)}, mj, "Leave Me Alone", "世纪典藏", 0, 0},
		{"本地歌名带破折号宣传语", []neSearchSong{neTestSong(10, "什么歌", "五月天", "什么歌", 237)}, "五月天", "什么歌 - 电影<捉妖记2>主题曲", "什么歌", 237, 10},
		{"破折号尾段是版本限定词照样拦", []neSearchSong{neTestSong(11, "落笔成书", "刘惜君", "落笔成书", 272)}, "刘惜君", "落笔成书 - Live", "音乐缘计划 第9期 - Live", 272, 0},
		{"破折号尾段带 feat 括号", []neSearchSong{neTestSong(12, "Please Do Not Lean", "Daniel Caesar", "NEVER ENOUGH (Bonus Version)", 241)}, "Daniel Caesar", "Please Do Not Lean (feat. BADBADNOTGOOD) - Bonus", "NEVER ENOUGH (Bonus Version)", 241, 12},
	} {
		got := neteaseLyricOnlyPick(c.songs, c.artist, c.title, c.album, c.dur)
		var id int64
		if got != nil {
			id = got.ID
		}
		if id != c.want {
			t.Errorf("%s: got id %d, want %d", c.name, id, c.want)
		}
	}
}

// 端到端:身份挑不出(同名两条、专辑都对不上)时照样给歌词,但不给封面、链接,也不为封面去问详情接口。
func TestResolveNeteaseInfoLyricOnlyWhenIdentityAmbiguous(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, `{"code":200,"result":{"songs":[` +
				`{"id":11,"name":"Leave Me Alone","artists":[{"name":"Michael Jackson"}],"album":{"id":1,"name":"Bad"},"duration":280000},` +
				`{"id":12,"name":"Leave Me Alone","artists":[{"name":"Michael Jackson"}],"album":{"id":2,"name":"The Collection"},"duration":276000}]}}`
		case target == "music.163.com/api/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(neV1Lyric) + `}}`
		}
		return http.StatusNotFound, ""
	})
	info := resolveNeteaseInfo(qqRoundCtx(), "Michael Jackson", "Leave Me Alone", "世纪典藏", 281)
	if info.Lyrics == "" || info.SongID != 11 {
		t.Fatalf("应当按时长最近的那条给歌词: songID=%d lyrics=%q", info.SongID, info.Lyrics)
	}
	if info.Cover != "" || info.SongURL != "" || info.AlbumID != 0 {
		t.Errorf("只给歌词时不该带身份: cover=%q url=%q albumID=%d", info.Cover, info.SongURL, info.AlbumID)
	}
	if f.count("music.163.com/api/song/detail") != 0 {
		t.Error("只给歌词时不该为封面去问详情接口")
	}
}

// 由 picId 算封面地址:对拍详情接口给的 picUrl(实抓)。
func TestNeteasePicURL(t *testing.T) {
	if got := neteasePicURL(109951171529987110); got != "https://p1.music.126.net/W9imJx0w_JeCGGs43dfjFg==/109951171529987110.jpg" {
		t.Errorf("neteasePicURL = %q", got)
	}
	if got := neteasePicURL(0); got != "" {
		t.Errorf("没有 picId 应给空串, got %q", got)
	}
}

// 搜索结果带 picId 时封面由它算出,不再为封面去问详情接口。
func TestResolveNeteaseInfoCoverFromSearchPicID(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":6491,"name":"U87","picId":109951171529987110},"duration":283520}]}}`
		case target == "music.163.com/api/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(neV1Lyric) + `}}`
		}
		return http.StatusNotFound, ""
	})
	info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
	if info.Cover != neteasePicURL(109951171529987110)+neteaseCoverQuery {
		t.Errorf("封面该由 picId 算出: %q", info.Cover)
	}
	if f.count("music.163.com/api/song/detail") != 0 {
		t.Error("搜索结果带了 picId,不该再问详情接口")
	}
}

// eapi 的表单字段:对拍 openssl 独立算出的密文(AES-128-ECB + PKCS#7,明文里带 md5 校验段)。
func TestNeteaseEapiParams(t *testing.T) {
	const want = "04AE33D34A93FE3EC22DA8FA305D290AB337D0FE5F36D211DE0D338CC6AA89D08812527BBFAB29BECED3E60232702DC50C24147B4CB6112263FB8C91780CEAB7A36CFDE5D88060E875F2601331EA41459665670BACAFE1FFC41D87BDF9CB2D30437B14977361FA55EA7E1DEA8620C3F1"
	got, err := neteaseEapiParams("/api/song/lyric/v1", map[string]string{"id": "66842", "lv": "-1"})
	if err != nil || got != want {
		t.Fatalf("eapi params 不对:\n got %s\nwant %s (err %v)", got, want, err)
	}
}

// neteaseEapiOpenForTest 解开 eapi 请求体(params=…)、核对校验段,交回加密进去的接口路径和参数。
func neteaseEapiOpenForTest(t *testing.T, body string) (string, map[string]string) {
	t.Helper()
	raw, err := hex.DecodeString(strings.TrimPrefix(body, "params="))
	if err != nil || len(raw) == 0 || len(raw)%aes.BlockSize != 0 {
		t.Fatalf("请求体不是 eapi 表单: %q", body)
	}
	block, _ := aes.NewCipher([]byte(neteaseEapiKey))
	for i := 0; i < len(raw); i += aes.BlockSize {
		block.Decrypt(raw[i:i+aes.BlockSize], raw[i:i+aes.BlockSize])
	}
	parts := strings.Split(string(raw[:len(raw)-int(raw[len(raw)-1])]), "-36cd479b6b5-")
	if len(parts) != 3 {
		t.Fatalf("明文该是三段: %q", raw)
	}
	if sum := md5.Sum([]byte("nobody" + parts[0] + "use" + parts[1] + "md5forencrypt")); parts[2] != hex.EncodeToString(sum[:]) {
		t.Fatalf("校验段不对: %q", parts[2])
	}
	data := map[string]string{}
	if err := json.Unmarshal([]byte(parts[1]), &data); err != nil {
		t.Fatalf("中间那段该是 JSON: %q", parts[1])
	}
	return parts[0], data
}

// /eapi/ 路径:POST 表单,查询参数加密进 params;主机照样按顺序退,不会去问明文路径。
func TestNeteaseFetchBodyEapi(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case "music.163.com/eapi/song/lyric/v1":
			return http.StatusBadGateway, ""
		case "interface.music.163.com/eapi/song/lyric/v1":
			return http.StatusOK, `{"code":200}`
		}
		return http.StatusNotFound, ""
	})
	body, err := neteaseFetchBody(qqRoundCtx(), "https://music.163.com/eapi/song/lyric/v1?id=66842&lv=-1", "", 4*time.Second)
	if err != nil || string(body) != `{"code":200}` {
		t.Fatalf("该从备用主机拿到: %s %v", body, err)
	}
	const target = "interface.music.163.com/eapi/song/lyric/v1"
	if f.last(f.methods, target) != http.MethodPost || f.last(f.ctypes, target) != "application/x-www-form-urlencoded" {
		t.Fatalf("eapi 该是 POST 表单: %s %s", f.last(f.methods, target), f.last(f.ctypes, target))
	}
	apiPath, data := neteaseEapiOpenForTest(t, f.last(f.bodies, target))
	if apiPath != "/api/song/lyric/v1" || data["id"] != "66842" || data["lv"] != "-1" || len(data) != 2 {
		t.Fatalf("加密进去的该是 /api/ 写法的路径和查询参数: %s %v", apiPath, data)
	}
	if f.count("music.163.com/api/song/lyric/v1") != 0 || f.count("interface3.music.163.com/eapi/song/lyric/v1") != 0 {
		t.Error("只问 eapi 这一条,拿到了就停")
	}
}

// 三处搜索:search/get 两条明文路径都被拒(code 405)时问 eapi 的 search/get,返回结构同首选那条。
func TestNeteaseSearchChainsFallBackToEapi(t *testing.T) {
	rejectPlain := func(hit string) func(string) (int, string) {
		return func(target string) (int, string) {
			switch target {
			case "music.163.com/api/search/get", "music.163.com/api/search/get/web":
				return http.StatusOK, `{"result":{},"code":405}`
			case "music.163.com/eapi/search/get":
				return http.StatusOK, hit
			}
			return http.StatusNotFound, ""
		}
	}
	f := withNeteaseFake(t, rejectPlain(neSearchOne))
	songs, err := neteaseSearchSongs(neteaseTestGet(), "陈奕迅 浮夸")
	if err != nil || len(songs) != 1 || songs[0].ID != 66282 {
		t.Fatalf("搜歌该从 eapi 拿到: %v %v", songs, err)
	}
	if f.count("music.163.com/api/cloudsearch/pc") != 0 {
		t.Error("eapi 答了就不该再问 cloudsearch")
	}
	if _, data := neteaseEapiOpenForTest(t, f.last(f.bodies, "music.163.com/eapi/search/get")); data["s"] != "陈奕迅 浮夸" || data["type"] != "1" || data["limit"] != "30" {
		t.Errorf("搜索词、类型、条数该原样带进去: %v", data)
	}

	withNeteaseFake(t, rejectPlain(`{"code":200,"result":{"albums":[{"id":6491,"name":"U87","artist":{"name":"陈奕迅"}}]}}`))
	if id, ok := neteaseAlbumIDByName(qqRoundCtx(), "陈奕迅", "U87"); !ok || id != 6491 {
		t.Fatalf("专辑搜索该从 eapi 拿到: %d %v", id, ok)
	}

	withNeteaseFake(t, rejectPlain(`{"code":200,"result":{"songs":[{"name":"回留","duration":236343,"artists":[{"name":"方大同"}]}]}}`))
	if found, _, ok := retryTitleFromArtistSearchDetailed(qqRoundCtx(), "方大同", "Revisited", 236.344); !ok || found != "回留" {
		t.Fatalf("按歌手泛搜该从 eapi 拿到: %q %v", found, ok)
	}
}

// 歌词:v1 几个主机都没问成时问 v1 的 eapi 写法,同一份返回(带逐字),不再退到老接口。
func TestResolveNeteaseInfoLyricFallsBackToEapi(t *testing.T) {
	const yrc = "[28948,2000](28948,500,0)有(29448,500,0)人"
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, neSearchOne
		case strings.HasSuffix(target, "/api/song/detail"):
			return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case strings.HasSuffix(target, "/api/song/lyric/v1"):
			return http.StatusInternalServerError, ""
		case target == "music.163.com/eapi/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(neV1Lyric) + `},"yrc":{"lyric":` + jsonQuoteForTest(yrc) + `}}`
		}
		return http.StatusNotFound, ""
	})
	info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
	if !strings.HasPrefix(info.Lyrics, "[00:00.00] 作词 : 黄伟文") || info.YRC != yrc {
		t.Fatalf("整行和逐字该从 eapi 拿到: lyrics=%q yrc=%q", info.Lyrics, info.YRC)
	}
	if f.count("music.163.com/api/song/lyric") != 0 {
		t.Error("eapi 答了就不该再问老歌词接口")
	}
	if _, data := neteaseEapiOpenForTest(t, f.last(f.bodies, "music.163.com/eapi/song/lyric/v1")); data["id"] != "66282" || data["yv"] != "-1" {
		t.Errorf("歌曲 id 和各项版本参数该带进去: %v", data)
	}
}

// 单曲详情:老接口和 v3 都被拒(code 405)时问老详情接口的 eapi 写法。专辑曲目:两条明文路径都被拒时问老专辑
// 接口的 eapi 写法,cookie 照样带。
func TestNeteaseDetailAndAlbumFallBackToEapi(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, neSearchOne
		case target == "music.163.com/api/song/detail", target == "music.163.com/api/v3/song/detail":
			return http.StatusOK, `{"code":405}`
		case target == "music.163.com/eapi/song/detail":
			return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case target == "music.163.com/api/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(neV1Lyric) + `}}`
		}
		return http.StatusNotFound, ""
	})
	if info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5); info.Cover != "http://p1.music.126.net/x.jpg"+neteaseCoverQuery {
		t.Errorf("封面该从 eapi 详情拿到: %q", info.Cover)
	}

	f := withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case "music.163.com/api/album/9", "music.163.com/api/v1/album/9":
			return http.StatusOK, `{"code":405}`
		case "music.163.com/eapi/album/9":
			return http.StatusOK, `{"code":200,"album":{"name":"U87","songs":[{"id":66282,"name":"浮夸","duration":283520,"artists":[{"name":"陈奕迅"}]}]}}`
		}
		return http.StatusNotFound, ""
	})
	tracks, ok := neteaseAlbumTracks(qqRoundCtx(), 9)
	if !ok || len(tracks) != 1 || tracks[0].title != "浮夸" || tracks[0].neteaseSongID != 66282 {
		t.Fatalf("专辑曲目该从 eapi 拿到: %+v %v", tracks, ok)
	}
	if f.last(f.cookies, "music.163.com/eapi/album/9") != "os=pc" {
		t.Error("eapi 写法也要带上 os=pc")
	}
}
