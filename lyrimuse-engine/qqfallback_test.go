package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// qqFake 把所有 QQ 主机(真实主机名经改写的传输层)指到一个本地服务器,按 主机 + 路径(网关请求再加
// 方法名)分发,并记下每个目标被打了几次。
type qqFake struct {
	mu   sync.Mutex
	hits map[string]int
}

func (f *qqFake) count(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[key]
}

// withQQFake 的 handle 收到 target:网页接口是 "host/path",网关是 "host/musicu:<method>"。
func withQQFake(t *testing.T, handle func(target string) (int, string)) *qqFake {
	t.Helper()
	return withQQFakeReq(t, func(_ *http.Request, target string) (int, string) { return handle(target) })
}

// withQQFakeReq 同 withQQFake,handle 另外拿到请求本身(要按查询词给不同结果时用)。
func withQQFakeReq(t *testing.T, handle func(r *http.Request, target string) (int, string)) *qqFake {
	t.Helper()
	savedGuard, savedBreaker, savedTransport := sharedHostGuard(), sharedLyricSourceBreaker(), sharedLyricSourceTransport()
	setSharedHostGuard(newHostGuard(time.Now))
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	qqSongDetailMu.Lock()
	savedDetail := qqSongDetailCache
	qqSongDetailCache = map[string]qqSongDetailInfo{}
	qqSongDetailMu.Unlock()
	qqSongMetaMu.Lock()
	savedMeta := qqSongMetaCache
	qqSongMetaCache = map[string]qqSongMeta{}
	qqSongMetaMu.Unlock()
	qqAlbumSongsMu.Lock()
	savedAlbum := qqAlbumSongsCache
	qqAlbumSongsCache = map[string][]qqAlbumSong{}
	qqAlbumSongsMu.Unlock()
	t.Cleanup(func() {
		setSharedHostGuard(savedGuard)
		setSharedLyricSourceBreaker(savedBreaker)
		setSharedLyricSourceTransport(savedTransport)
		qqSongDetailMu.Lock()
		qqSongDetailCache = savedDetail
		qqSongDetailMu.Unlock()
		qqSongMetaMu.Lock()
		qqSongMetaCache = savedMeta
		qqSongMetaMu.Unlock()
		qqAlbumSongsMu.Lock()
		qqAlbumSongsCache = savedAlbum
		qqAlbumSongsMu.Unlock()
	})

	f := &qqFake{hits: map[string]int{}}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		target := host + r.URL.Path
		if r.URL.Path == "/cgi-bin/musicu.fcg" {
			body, _ := io.ReadAll(r.Body)
			var req struct {
				Request struct {
					Method string `json:"method"`
				} `json:"request"`
			}
			_ = json.Unmarshal(body, &req)
			target = host + "/musicu:" + req.Request.Method
		}
		f.mu.Lock()
		f.hits[target]++
		f.mu.Unlock()
		status, body := handle(r, target)
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

func musicuOK(data string) string {
	return `{"code":0,"request":{"code":0,"data":` + data + `}}`
}

// 一轮歌词搜索之内跑(源级冷却那道在轮内交给 planRound),隔离出备用链本身的行为。
func qqRoundCtx() context.Context {
	ctx, _ := withLyricSourceRound(context.Background())
	return ctx
}

const qqDetailRow = `{"id":97773,"interval":269,"language":0,"album":{"mid":"alb1","name":"叶惠美"},"singer":[{"mid":"sg1","name":"周杰伦"}]}`

// 单曲详情:首选主机挂了换下一个主机,不去碰网关;取到后缓存,同一首不再请求。
func TestQQSongDetailFallsBackToNextWebHost(t *testing.T) {
	f := withQQFake(t, func(target string) (int, string) {
		switch target {
		case "c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg":
			return http.StatusInternalServerError, ""
		case "shc.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg":
			return http.StatusOK, `{"code":0,"data":[` + qqDetailRow + `]}`
		}
		return http.StatusNotFound, ""
	})
	d, ok := qqSongDetail(qqRoundCtx(), "m1")
	if !ok || d.id != 97773 || d.albumMid != "alb1" || d.albumName != "叶惠美" || len(d.singers) != 1 || d.singers[0].mid != "sg1" {
		t.Fatalf("该从备用主机取到详情: ok=%v %+v", ok, d)
	}
	if f.count("u.y.qq.com/musicu:get_song_detail_yqq") != 0 {
		t.Error("网页接口有主机答了,不该再问网关")
	}
	_, _ = qqSongDetail(qqRoundCtx(), "m1")
	if n := f.count("shc.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg"); n != 1 {
		t.Errorf("取到过的详情该缓存: 打了 %d 次", n)
	}
	// 四个取详情字段的函数共用这一份,不再各打一次。
	if qqSongAlbum(qqRoundCtx(), "m1") != "叶惠美" {
		t.Error("qqSongAlbum 该取到专辑名")
	}
	if cover, singer, album := qqSongCoverAndSinger(qqRoundCtx(), "m1"); cover != qqAlbumCoverURL("alb1") || singer != "周杰伦" || album != "叶惠美" {
		t.Errorf("qqSongCoverAndSinger: %q %q %q", cover, singer, album)
	}
	if am, sm := qqSongCatalogMids(qqRoundCtx(), "m1"); am != "alb1" || sm != "sg1" {
		t.Errorf("qqSongCatalogMids: %q %q", am, sm)
	}
	if m := qqSongMetaByMid(qqRoundCtx(), "m1"); m.id != 97773 || m.interval != 269 {
		t.Errorf("qqSongMetaByMid: %+v", m)
	}
	if m := qqSongMetaCachedOnly("m1"); m.id != 97773 {
		t.Errorf("取到详情时顺带填上只读缓存: %+v", m)
	}
	if n := f.count("shc.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg"); n != 1 {
		t.Errorf("四个函数共用一次请求,实际打了 %d 次", n)
	}
}

// 单曲详情:网页接口几个主机都挂了,退到客户端网关。
func TestQQSongDetailFallsBackToGateway(t *testing.T) {
	f := withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/v8/fcg-bin/fcg_play_single_song.fcg") {
			return http.StatusInternalServerError, ""
		}
		if target == "u.y.qq.com/musicu:get_song_detail_yqq" {
			return http.StatusOK, musicuOK(`{"track_info":` + qqDetailRow + `}`)
		}
		return http.StatusNotFound, ""
	})
	d, ok := qqSongDetail(qqRoundCtx(), "m1")
	if !ok || d.id != 97773 || d.albumMid != "alb1" {
		t.Fatalf("该从网关取到详情: ok=%v %+v", ok, d)
	}
	for _, h := range qqWebHosts {
		if f.count(h+"/v8/fcg-bin/fcg_play_single_song.fcg") != 1 {
			t.Errorf("网页接口 %s 该先试一次", h)
		}
	}
}

// 单曲详情:网页接口答了「没有这首」就停,不去问网关,也不缓存。
func TestQQSongDetailStopsWhenAnswered(t *testing.T) {
	f := withQQFake(t, func(target string) (int, string) {
		if target == "c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg" {
			return http.StatusOK, `{"code":0,"data":[]}`
		}
		return http.StatusNotFound, ""
	})
	if _, ok := qqSongDetail(qqRoundCtx(), "gone"); ok {
		t.Fatal("接口答了没有这首,不该算取到")
	}
	if f.count("shc.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg") != 0 || f.count("u.y.qq.com/musicu:get_song_detail_yqq") != 0 {
		t.Error("接口正常答了就停,不该再问备用")
	}
}

const qqTestLRC = "[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句\n[00:04.00]第四句\n"

// 整行歌词:网页接口都挂了,退到网关取同一份(base64);网关这条不下「没词」的结论。
func TestQQLineLyricFallsBackToGateway(t *testing.T) {
	withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/lyric/fcgi-bin/fcg_query_lyric_new.fcg") {
			return http.StatusBadGateway, ""
		}
		if target == "u.y.qq.com/musicu:GetPlayLyricInfo" {
			return http.StatusOK, musicuOK(`{"lyric":"` + base64.StdEncoding.EncodeToString([]byte(qqTestLRC)) + `"}`)
		}
		return http.StatusNotFound, ""
	})
	res := resolveQQLyric(qqRoundCtx(), "m1")
	if res.lrc != qqTestLRC {
		t.Fatalf("该从网关拿到歌词: %+v", res)
	}

	withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/lyric/fcgi-bin/fcg_query_lyric_new.fcg") {
			return http.StatusBadGateway, ""
		}
		if target == "u.y.qq.com/musicu:GetPlayLyricInfo" {
			return http.StatusOK, musicuOK(`{"lyric":""}`)
		}
		return http.StatusNotFound, ""
	})
	if res := resolveQQLyric(qqRoundCtx(), "m1"); res.trackFoundNoLyrics || res.lrc != "" {
		t.Fatalf("网关这条不下没词的结论: %+v", res)
	}
}

// 整行歌词:网页接口答了「没词」(-1901)就是结论,不去问网关。
func TestQQLineLyricWebAnswerIsFinal(t *testing.T) {
	f := withQQFake(t, func(target string) (int, string) {
		if target == "c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg" {
			return http.StatusOK, `{"retcode":-1901,"code":-1901,"subcode":-1901}`
		}
		return http.StatusNotFound, ""
	})
	res := resolveQQLyric(qqRoundCtx(), "m1")
	if !res.trackFoundNoLyrics {
		t.Fatalf("网页接口明确说没词: %+v", res)
	}
	if f.count("shc.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg") != 0 || f.count("u.y.qq.com/musicu:GetPlayLyricInfo") != 0 {
		t.Error("答了就停,不该再问备用")
	}
}

// 网关:没问成才换下一个网关主机;网关答了业务错误码(比如查无此歌),换主机也是同一个答案,不换。
func TestQQMusicuPostSwitchesHostOnlyWhenNotReached(t *testing.T) {
	f := withQQFake(t, func(target string) (int, string) {
		switch target {
		case "u.y.qq.com/musicu:M":
			return http.StatusBadGateway, ""
		case "u6.y.qq.com/musicu:M":
			return http.StatusOK, musicuOK(`{"x":1}`)
		}
		return http.StatusNotFound, ""
	})
	data, err := qqMusicuPost(qqRoundCtx(), "M", "mod", map[string]any{}, qqCommBase)
	if err != nil || string(data) != `{"x":1}` {
		t.Fatalf("该从备用网关主机拿到: %s %v", data, err)
	}
	if f.count("shu.y.qq.com/musicu:M") != 0 {
		t.Error("拿到了就停")
	}

	f = withQQFake(t, func(target string) (int, string) {
		if target == "u.y.qq.com/musicu:M" {
			return http.StatusOK, `{"code":0,"request":{"code":404}}`
		}
		return http.StatusOK, musicuOK(`{}`)
	})
	if _, err := qqMusicuPost(qqRoundCtx(), "M", "mod", map[string]any{}, qqCommBase); err == nil {
		t.Fatal("网关回了业务错误码,该报错")
	}
	if f.count("u6.y.qq.com/musicu:M") != 0 {
		t.Error("网关答了就不该换主机再问")
	}
}

// 专辑曲目表:网关几个主机都挂了,退到网页版专辑接口。
func TestQQAlbumSongsFallsBackToWeb(t *testing.T) {
	withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/musicu:GetAlbumSongList") {
			return http.StatusInternalServerError, ""
		}
		if target == "c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg" {
			return http.StatusOK, `{"code":0,"data":{"list":[{"songmid":"s1","songname":"晴天","interval":269,"singer":[{"name":"周杰伦"}]}]}}`
		}
		return http.StatusNotFound, ""
	})
	songs, err := qqAlbumSongs(qqRoundCtx(), "alb1")
	if err != nil || len(songs) != 1 || songs[0].mid != "s1" || songs[0].singer != "周杰伦" || songs[0].interval != 269 {
		t.Fatalf("该从网页版专辑接口拿到曲目: %+v %v", songs, err)
	}
}

// 网页版专辑接口回 1101(实测没有这张专辑就是它):答了、没有曲目,不当没问成;别的非零 code 照旧算没问成。
func TestQQAlbumSongsWebNotFoundIsAnswer(t *testing.T) {
	for _, c := range []struct {
		code    int
		wantErr bool
	}{{qqAlbumNotFoundCode, false}, {500, true}} {
		withQQFake(t, func(target string) (int, string) {
			if strings.HasSuffix(target, "/musicu:GetAlbumSongList") {
				return http.StatusInternalServerError, ""
			}
			if strings.HasSuffix(target, "/v8/fcg-bin/fcg_v8_album_info_cp.fcg") {
				return http.StatusOK, fmt.Sprintf(`{"code":%d,"subcode":%d,"message":"para error!"}`, c.code, c.code)
			}
			return http.StatusNotFound, ""
		})
		songs, err := qqAlbumSongs(qqRoundCtx(), fmt.Sprintf("missing%d", c.code))
		if (err != nil) != c.wantErr || len(songs) != 0 {
			t.Errorf("code %d: songs=%d err=%v,期望报错 %v", c.code, len(songs), err, c.wantErr)
		}
	}
}

// 专辑分类:smartbox 几个主机都挂了,退到网关的专辑搜索。
func TestQQSmartboxAlbumsFallsBackToGatewaySearch(t *testing.T) {
	withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/splcloud/fcgi-bin/smartbox_new.fcg") {
			return http.StatusInternalServerError, ""
		}
		if target == "u.y.qq.com/musicu:DoSearchForQQMusicDesktop" {
			return http.StatusOK, musicuOK(`{"body":{"album":{"list":[{"albumMID":"alb1","albumName":"叶惠美","singerName":"周杰伦"}]}}}`)
		}
		return http.StatusNotFound, ""
	})
	items, err := qqSmartboxAlbums(qqRoundCtx(), "周杰伦 叶惠美")
	if err != nil || len(items) != 1 || items[0].Mid != "alb1" || items[0].Name != "叶惠美" || items[0].Singer != "周杰伦" {
		t.Fatalf("该从网关专辑搜索拿到: %+v %v", items, err)
	}
}

// 搜歌:网页搜索几个主机都挂了,退到网关搜索。
func TestQQClientSearchFallsBackToGatewaySearch(t *testing.T) {
	withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/soso/fcgi-bin/client_search_cp") {
			return http.StatusInternalServerError, ""
		}
		if target == "u.y.qq.com/musicu:DoSearchForQQMusicDesktop" {
			return http.StatusOK, musicuOK(`{"body":{"song":{"list":[{"mid":"m1","title":"Gravity Blues","interval":241,"singer":[{"name":"Geese"}],"album":{"name":"3D Country"}}]}}}`)
		}
		return http.StatusNotFound, ""
	})
	items, err := qqClientSearch(qqRoundCtx(), "Geese Gravity Blues")
	if err != nil || len(items) != 1 || items[0].Mid != "m1" || items[0].Singer != "Geese" || items[0].Album != "3D Country" || items[0].Interval != 241 {
		t.Fatalf("该从网关搜索拿到: %+v %v", items, err)
	}
}

// 歌手联想:只换 smartbox 的主机,都挂了就报没问成,不退到网关的歌手搜索。
func TestQQSingerSuggestionsOnlySwitchesHosts(t *testing.T) {
	withQQFake(t, func(target string) (int, string) {
		switch target {
		case "c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg":
			return http.StatusInternalServerError, ""
		case "shc.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg":
			return http.StatusOK, `{"code":0,"data":{"singer":{"itemlist":[{"name":"周杰伦","pic":"http://y.gtimg.cn/x.jpg"}]}}}`
		}
		return http.StatusNotFound, ""
	})
	items, ok := qqSingerSuggestions(context.Background(), "Jay Chou")
	if !ok || len(items) != 1 || items[0].Name != "周杰伦" {
		t.Fatalf("该从备用主机拿到: %+v %v", items, ok)
	}

	f := withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/splcloud/fcgi-bin/smartbox_new.fcg") {
			return http.StatusBadGateway, ""
		}
		return http.StatusOK, musicuOK(`{}`)
	})
	if _, ok := qqSingerSuggestions(context.Background(), "Jay Chou"); ok {
		t.Fatal("几个主机都挂了该报没问成")
	}
	if f.count("u.y.qq.com/musicu:DoSearchForQQMusicDesktop") != 0 {
		t.Error("歌手联想不该退到网关的歌手搜索")
	}
}

// 专辑名:首选主机挂了换下一个,取到后按 mid 缓存;QQ 答查无(code 非 0)算问成了、名字为空;几个主机都挂了返回错误、不缓存。
func TestQQAlbumName(t *testing.T) {
	qqAlbumNameMu.Lock()
	savedNames := qqAlbumNameCache
	qqAlbumNameCache = map[string]string{}
	qqAlbumNameMu.Unlock()
	t.Cleanup(func() {
		qqAlbumNameMu.Lock()
		qqAlbumNameCache = savedNames
		qqAlbumNameMu.Unlock()
	})
	f := withQQFakeReq(t, func(r *http.Request, target string) (int, string) {
		mid := r.URL.Query().Get("albummid")
		switch {
		case target == "c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg":
			return http.StatusInternalServerError, ""
		case mid == "0034Gnut4OoYpJ":
			return http.StatusOK, `{"code":0,"data":{"name":" Bad "}}`
		case mid == "missing":
			return http.StatusOK, `{"code":1101,"subcode":1101,"message":"para error!"}`
		}
		return http.StatusBadGateway, ""
	})
	ctx := qqRoundCtx()
	for range 2 {
		if name, err := qqAlbumName(ctx, "0034Gnut4OoYpJ"); err != nil || name != "Bad" {
			t.Fatalf("该从备用主机取到专辑名: %q %v", name, err)
		}
	}
	if n := f.count("shc.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg"); n != 1 {
		t.Errorf("取到过的专辑名该缓存: 打了 %d 次", n)
	}
	if name, err := qqAlbumName(ctx, "missing"); err != nil || name != "" {
		t.Errorf("查无算问成了、名字为空: %q %v", name, err)
	}
	if _, err := qqAlbumName(ctx, "down"); err == nil {
		t.Error("几个主机都挂了该返回错误")
	}
	qqAlbumNameMu.Lock()
	_, missingCached := qqAlbumNameCache["missing"]
	_, downCached := qqAlbumNameCache["down"]
	qqAlbumNameMu.Unlock()
	if !missingCached || downCached {
		t.Errorf("问成了的缓存、没问成的不缓存: missing=%v down=%v", missingCached, downCached)
	}
}

// 从 QQ 专辑封面地址取专辑 mid:带尺寸、带查询参数的都认;歌手头像(T001)、别的主机、没有 mid 的不认。
func TestQQCoverAlbumMid(t *testing.T) {
	for url, want := range map[string]string{
		qqAlbumCoverURL("0034Gnut4OoYpJ"):                                                "0034Gnut4OoYpJ",
		"https://y.gtimg.cn/music/photo_new/T002R300x300M000003Gnut.jpg?max_age=2592000": "003Gnut",
		"https://y.qq.com/music/photo_new/T001R800x800M000003Nz2So3XXYek.jpg":            "",
		"https://example.com/music/photo_new/T002R800x800M0000034Gnut4OoYpJ.jpg":         "",
		"https://y.qq.com/music/photo_new/T002R800x800.jpg":                              "",
		"": "",
	} {
		if got := qqCoverAlbumMid(url); got != want {
			t.Errorf("qqCoverAlbumMid(%q) = %q, want %q", url, got, want)
		}
	}
}

// QQ 兜底封面带回这张图在 QQ 上所属的专辑:是单曲详情里的专辑名,不是搜索结果里那首报的专辑。
func TestQQCoverFallbackReturnsTheCoverAlbum(t *testing.T) {
	withQQFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/soso/fcgi-bin/client_search_cp"):
			return http.StatusOK, `{"code":0,"data":{"song":{"list":[{"mid":"m1","title":"Off the Wall","interval":246,"singer":[{"name":"Michael Jackson"}],"album":{"name":"Off the Wall"}}]}}}`
		case strings.HasSuffix(target, "/splcloud/fcgi-bin/smartbox_new.fcg"):
			return http.StatusOK, `{"code":0,"data":{"song":{"itemlist":[]},"album":{"itemlist":[]},"singer":{"itemlist":[]}}}`
		case strings.HasSuffix(target, "/v8/fcg-bin/fcg_play_single_song.fcg"):
			return http.StatusOK, `{"code":0,"data":[{"id":1,"interval":246,"language":0,"album":{"mid":"0034Gnut4OoYpJ","name":"Bad"},"singer":[{"mid":"s1","name":"Michael Jackson"}]}]}`
		}
		return http.StatusNotFound, ""
	})
	cover, _, album := qqCoverFallback(qqRoundCtx(), "Michael Jackson", "Off the Wall", "世纪典藏【绝赞版】")
	if cover != qqAlbumCoverURL("0034Gnut4OoYpJ") || album != "Bad" {
		t.Fatalf("got cover=%q album=%q", cover, album)
	}
}
