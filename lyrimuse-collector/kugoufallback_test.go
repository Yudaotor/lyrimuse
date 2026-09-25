package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// kgFake 把酷狗各主机(真实主机名经改写的传输层,80 端口走明文、443 走 TLS)指到本地,
// 按 "scheme://主机/路径" 分发并计数。
type kgFake struct {
	mu   sync.Mutex
	hits map[string]int
}

func (f *kgFake) count(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[key]
}

func withKugouFake(t *testing.T, handle func(target string) (int, string)) *kgFake {
	t.Helper()
	savedGuard, savedBreaker, savedTransport := hostGuardShared, lyricSourceBreakerShared, lyricSourceTransport
	hostGuardShared = newHostGuard(time.Now)
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	t.Cleanup(func() {
		hostGuardShared, lyricSourceBreakerShared, lyricSourceTransport = savedGuard, savedBreaker, savedTransport
	})
	f := &kgFake{hits: map[string]int{}}
	mk := func(scheme string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			host := r.Host
			if h, _, err := net.SplitHostPort(host); err == nil {
				host = h
			}
			target := scheme + "://" + host + r.URL.Path
			f.mu.Lock()
			f.hits[target]++
			f.mu.Unlock()
			status, body := handle(target)
			w.WriteHeader(status)
			_, _ = io.WriteString(w, body)
		}
	}
	plain := httptest.NewServer(mk("http"))
	secure := httptest.NewTLSServer(mk("https"))
	t.Cleanup(plain.Close)
	t.Cleanup(secure.Close)
	plainAddr, secureAddr := plain.Listener.Addr().String(), secure.Listener.Addr().String()
	lyricSourceTransport = &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			target := plainAddr
			if strings.HasSuffix(addr, ":443") {
				target = secureAddr
			}
			return (&net.Dialer{}).DialContext(ctx, network, target)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	return f
}

func TestKugouURLAlternates(t *testing.T) {
	got := kugouURLAlternates("http://mobilecdn.kugou.com/api/v3/search/song?keyword=x")
	if len(got) != 3 || !strings.HasPrefix(got[1], "http://ioscdn.kugou.com/api/v3/search/song?") {
		t.Fatalf("/api/v3 该展开成三个主机: %v", got)
	}
	if got := kugouURLAlternates("http://krcs.kugou.com/search?x=1"); len(got) != 2 || !strings.HasPrefix(got[1], "http://lyrics.kugou.com/search?") {
		t.Fatalf("krcs 的备用是 lyrics: %v", got)
	}
	if got := kugouURLAlternates("http://m.kugou.com/app/i/getSongInfo.php?hash=h"); len(got) != 2 || !strings.HasPrefix(got[1], "https://m.kugou.com/") {
		t.Fatalf("m.kugou.com 的备用是 https: %v", got)
	}
	if got := kugouURLAlternates("https://songsearch.kugou.com/song_search_v2"); len(got) != 1 {
		t.Fatalf("没有备用的原样一条: %v", got)
	}
}

const kgSearchHit = `{"status":1,"errcode":0,"data":{"info":[{"hash":"abc","songname":"浮夸","singername":"陈奕迅","album_name":"U87","album_id":"968210","duration":283}]}}`

// 首选主机没问成就换下一个主机,拿到就停。
func TestKugouGetFallsBackToNextHost(t *testing.T) {
	f := withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "http://mobilecdn.kugou.com/api/v3/search/song":
			return http.StatusBadGateway, ""
		case "http://ioscdn.kugou.com/api/v3/search/song":
			return http.StatusOK, kgSearchHit
		}
		return http.StatusNotFound, ""
	})
	songs, ok := kugouSearchSongs(qqRoundCtx(), "陈奕迅 浮夸")
	if !ok || len(songs) != 1 || songs[0].Hash != "abc" {
		t.Fatalf("该从备用主机拿到: %+v %v", songs, ok)
	}
	if f.count("http://mobiles.kugou.com/api/v3/search/song") != 0 || f.count("https://songsearch.kugou.com/song_search_v2") != 0 {
		t.Error("拿到了就停,不再问后面的主机和另一套后端")
	}
}

// /api/v3 几个主机都挂了、或回了拒绝码,退到 songsearch,字段归一回 kugouSong。
func TestKugouSearchFallsBackToSongSearch(t *testing.T) {
	const songsearch = `{"status":1,"error_code":0,"data":{"lists":[{"FileHash":"8909E1809908CD8E3BF6CF85D98B93F0","SongName":"稻香","SingerName":"周杰伦","AlbumName":"魔杰座","AlbumID":"960399","Duration":223,"trans_param":{"language":"国语"}}]}}`
	for name, v3 := range map[string]func() (int, string){
		"都挂了":  func() (int, string) { return http.StatusInternalServerError, "" },
		"回拒绝码": func() (int, string) { return http.StatusOK, `{"status":0,"errcode":1002,"data":{"info":[]}}` },
	} {
		t.Run(name, func(t *testing.T) {
			withKugouFake(t, func(target string) (int, string) {
				if strings.HasSuffix(target, "/api/v3/search/song") {
					return v3()
				}
				if target == "https://songsearch.kugou.com/song_search_v2" {
					return http.StatusOK, songsearch
				}
				return http.StatusNotFound, ""
			})
			songs, ok := kugouSearchSongs(qqRoundCtx(), "周杰伦 稻香")
			if !ok || len(songs) != 1 {
				t.Fatalf("该从 songsearch 拿到: %+v %v", songs, ok)
			}
			s := songs[0]
			if s.Hash != "8909e1809908cd8e3bf6cf85d98b93f0" || s.SongName != "稻香" || s.SingerName != "周杰伦" ||
				s.AlbumName != "魔杰座" || s.AlbumID != "960399" || s.Duration != 223 || s.TransParam.Language != "国语" {
				t.Fatalf("字段没归一对: %+v", s)
			}
		})
	}
}

// 端到端:歌词候选和歌词正文的首选主机都挂了,各自换到另一个主机拿到。
func TestResolveKugouLyricFallsBackAcrossLyricHosts(t *testing.T) {
	lrc := "[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句\n[00:04.00]第四句\n"
	f := withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "http://mobilecdn.kugou.com/api/v3/search/song":
			return http.StatusOK, kgSearchHit
		case "http://krcs.kugou.com/search", "http://lyrics.kugou.com/download":
			return http.StatusServiceUnavailable, ""
		case "http://lyrics.kugou.com/search":
			return http.StatusOK, `{"status":200,"candidates":[{"id":"1","accesskey":"k"}]}`
		case "http://krcs.kugou.com/download":
			return http.StatusOK, `{"status":200,"content":"` + base64.StdEncoding.EncodeToString([]byte(lrc)) + `"}`
		}
		return http.StatusNotFound, ""
	})
	res := resolveKugouLyric(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if res.lrc != lrc {
		t.Fatalf("该从备用主机拿到歌词: %+v", res)
	}
	if f.count("http://lyrics.kugou.com/search") != 1 || f.count("http://krcs.kugou.com/download") < 1 {
		t.Error("候选和正文都该各自换到另一个主机")
	}
}

// 待播队列查专辑:http 挂了换 https。
func TestKugouAlbumIDByHashFallsBackToHTTPS(t *testing.T) {
	kugouAlbumMu.Lock()
	saved := kugouAlbumIDCache
	kugouAlbumIDCache = map[string]string{}
	kugouAlbumMu.Unlock()
	t.Cleanup(func() {
		kugouAlbumMu.Lock()
		kugouAlbumIDCache = saved
		kugouAlbumMu.Unlock()
	})
	withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "http://m.kugou.com/app/i/getSongInfo.php":
			return http.StatusBadGateway, ""
		case "https://m.kugou.com/app/i/getSongInfo.php":
			return http.StatusOK, `{"status":0,"albumid":968210}`
		}
		return http.StatusNotFound, ""
	})
	if id := kugouAlbumIDByHash(qqRoundCtx(), "abc"); id != "968210" {
		t.Fatalf("该从 https 拿到专辑 id: %q", id)
	}
}
