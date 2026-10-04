package main

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

func kgTestSong(hash, name, singer, album string, secs float64) kugouSong {
	return kugouSong{Hash: hash, SongName: name, SingerName: singer, AlbumName: album, Duration: secs}
}

// 前 10 条都挑不出时的后备,逐档。
func TestKugouFallbackSong(t *testing.T) {
	cases := []struct {
		name                 string
		pool                 []kugouSong
		artist, title, album string
		dur                  float64
		want                 string
	}{
		{"原来的闸门", []kugouSong{kgTestSong("h1", "We Can't Stop It", "MIYAVI", "NO SLEEP TILL TOKYO", 216)},
			"MIYAVI", "We Can't Stop It", "NO SLEEP TILL TOKYO", 216, "h1"},
		{"原来的闸门也过版本闸", []kugouSong{kgTestSong("h1", "简单爱 (Live)", "周杰伦", "无与伦比演唱会", 273)},
			"周杰伦", "简单爱", "范特西", 270, ""},
		{"原来的闸门先于歌手名包含", []kugouSong{kgTestSong("h1", "We Can't Stop It", "MIYAVI", "Other", 216), kgTestSong("h2", "We Can't Stop It", "雅MIYAVI", "NO SLEEP TILL TOKYO", 219)},
			"MIYAVI", "We Can't Stop It", "NO SLEEP TILL TOKYO", 216, "h1"},
		{"歌手名包含也过版本闸", []kugouSong{kgTestSong("h2", "Are You Ready (Live)", "关浩德Walter", "Live", 194)},
			"关浩德", "Are You Ready", "Just Be a Rock", 194, ""},
		{"歌手名一个包含另一个", []kugouSong{kgTestSong("h2", "Are You Ready", "关浩德Walter", "Be", 193)},
			"关浩德", "Are You Ready", "Just Be a Rock", 194, "h2"},
		{"歌手名包含、时长差超过 3%", []kugouSong{kgTestSong("h2", "Are You Ready", "关浩德Walter", "Be", 230)},
			"关浩德", "Are You Ready", "Just Be a Rock", 194, ""},
		{"歌手名包含、本地时长未知时看专辑", []kugouSong{kgTestSong("h3", "We Can't Stop It", "雅MIYAVI", "NO SLEEP TILL TOKYO", 216)},
			"MIYAVI", "We Can't Stop It", "NO SLEEP TILL TOKYO", 0, "h3"},
		{"歌手名包含、本地时长未知、专辑对不上", []kugouSong{kgTestSong("h3", "We Can't Stop It", "雅MIYAVI", "NO SLEEP TILL TOKYO", 216)},
			"MIYAVI", "We Can't Stop It", "Other", 0, ""},
		{"本地一侧的尾段", []kugouSong{kgTestSong("h4", "任性", "五月天", "电视剧《难哄》影视原声带·只喜欢你Love Moments", 265)},
			"五月天", "任性 - 電視劇《難哄》主題曲", "任性", 264, "h4"},
		{"本地一侧的尾段、时长差超过 3%", []kugouSong{kgTestSong("h4", "任性", "五月天", "电视剧《难哄》影视原声带·只喜欢你Love Moments", 290)},
			"五月天", "任性 - 電視劇《難哄》主題曲", "任性", 264, ""},
		{"酷狗一侧的尾段", []kugouSong{kgTestSong("h5", "Seven (feat. Latto) - Explicit Ver.", "Jung Kook", "Seven", 184)},
			"Jung Kook", "Seven", "", 205, "h5"},
		{"酷狗一侧的尾段、时长差太多", []kugouSong{kgTestSong("h5", "Automatic - 2004 Remastered", "宇多田ヒカル", "", 29)},
			"宇多田ヒカル", "Automatic", "First Love", 328, ""},
		{"尾段对得上、歌手对不上", []kugouSong{kgTestSong("h4", "任性", "张三", "任性", 264)},
			"五月天", "任性 - 電視劇《難哄》主題曲", "任性", 264, ""},
		{"同专辑同时长、唯一", []kugouSong{kgTestSong("h6", "二嬢", "尧十三", "飞船,宇航员", 391)},
			"尧十三", "二孃", "飞船，宇航员", 391, "h6"},
		{"同专辑同时长、不唯一就放弃", []kugouSong{kgTestSong("h6", "二嬢", "尧十三", "飞船,宇航员", 391), kgTestSong("h7", "北方女王", "尧十三", "飞船,宇航员", 391.5)},
			"尧十三", "二孃", "飞船，宇航员", 391, ""},
		{"同专辑、时长差超过 1 秒", []kugouSong{kgTestSong("h6", "二嬢", "尧十三", "飞船,宇航员", 393)},
			"尧十三", "二孃", "飞船，宇航员", 391, ""},
		{"同时长、专辑对不上", []kugouSong{kgTestSong("h6", "二嬢", "尧十三", "默认专辑", 391)},
			"尧十三", "二孃", "飞船，宇航员", 391, ""},
		{"前一档有结果就不看后一档", []kugouSong{kgTestSong("h8", "二嬢", "尧十三", "飞船,宇航员", 391), kgTestSong("h9", "二孃", "尧十三Yao", "默认专辑", 391)},
			"尧十三", "二孃", "飞船，宇航员", 391, "h9"},
	}
	for _, c := range cases {
		got := kugouFallbackSong(c.pool, c.artist, c.title, c.album, c.dur)
		h := ""
		if got != nil {
			h = got.Hash
		}
		if h != c.want {
			t.Errorf("%s: got %q, want %q", c.name, h, c.want)
		}
	}
}

// 整页和每条的 Group 按 hash 去重接进 pool。
func TestKugouMergeSongs(t *testing.T) {
	a := kgTestSong("a", "x", "y", "合辑", 100)
	a.Group = []kugouSong{kgTestSong("b", "x", "y", "原专辑", 100), kgTestSong("c", "x", "y", "单曲", 100)}
	pool := kugouMergeSongs([]kugouSong{kgTestSong("c", "x", "y", "单曲", 100)}, []kugouSong{a, kgTestSong("", "x", "y", "", 0), kgTestSong("b", "x", "y", "", 0)})
	var hashes []string
	for _, s := range pool {
		hashes = append(hashes, s.Hash)
	}
	if strings.Join(hashes, ",") != "c,a,b" {
		t.Fatalf("got %v", hashes)
	}
}

// kgTestKRCContent 把一份 KRC 正文加密成下载接口 content 字段的样子(krc1 + 异或 + zlib,再 base64)。
func kgTestKRCContent(t *testing.T, body string) string {
	t.Helper()
	var z bytes.Buffer
	w := zlib.NewWriter(&z)
	if _, err := w.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	w.Close()
	raw := z.Bytes()
	out := append([]byte("krc1"), make([]byte, len(raw))...)
	for i, b := range raw {
		out[4+i] = b ^ krcXORKey[i%len(krcXORKey)]
	}
	return base64.StdEncoding.EncodeToString(out)
}

const kgTestKRC = "[ar:陈奕迅]\n[ti:浮夸]\n[hash:abc]\n[offset:0]\n" +
	"[1000,900]<0,300,0>第<300,300,0>一<600,300,0>句\n" +
	"[2000,900]<0,300,0>第<300,300,0>二<600,300,0>句\n" +
	"[3000,900]<0,300,0>第<300,300,0>三<600,300,0>句\n" +
	"[4000,900]<0,300,0>第<300,300,0>四<600,300,0>句"

// 先下 KRC,整行从它压出来、不再下 fmt=lrc;KRC 没问成、解不开或压不出带时间戳的整行才下 fmt=lrc。
func TestResolveKugouLyricLineFromKRC(t *testing.T) {
	lrc := "[ti:浮夸]\n[hash:abc]\n[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句\n[00:04.00]第四句\n"
	lrcContent := base64.StdEncoding.EncodeToString([]byte(lrc))
	for _, c := range []struct {
		name      string
		krc       func() (int, string)
		wantLRC   string
		wantYRC   bool
		wantLRCDL int
	}{
		{"KRC 好的", func() (int, string) {
			return http.StatusOK, `{"status":200,"content":"` + kgTestKRCContent(t, kgTestKRC) + `"}`
		},
			krcToLRC(kgTestKRC), true, 0},
		{"KRC 没问成", func() (int, string) { return http.StatusServiceUnavailable, "" }, lrc, false, 1},
		{"KRC 解不开", func() (int, string) { return http.StatusOK, `{"status":200,"content":"` + lrcContent + `"}` }, lrc, false, 1},
		{"KRC 只有头部标签", func() (int, string) {
			return http.StatusOK, `{"status":200,"content":"` + kgTestKRCContent(t, "[ar:陈奕迅]\n[ti:浮夸]") + `"}`
		}, lrc, false, 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			lrcDownloads := 0
			withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
				switch {
				case target == "http://mobilecdn.kugou.com/api/v3/search/song":
					return http.StatusOK, kgSearchHit
				case target == "http://krcs.kugou.com/search":
					return http.StatusOK, `{"status":200,"candidates":[{"id":"1","accesskey":"k"}]}`
				case strings.HasSuffix(target, ".kugou.com/download"):
					if r.URL.Query().Get("fmt") == "krc" {
						return c.krc()
					}
					lrcDownloads++
					return http.StatusOK, `{"status":200,"content":"` + lrcContent + `"}`
				}
				return http.StatusNotFound, ""
			})
			res := resolveKugouLyric(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
			if res.lrc != c.wantLRC || (usableYRC(res.lrc, res.yrc) != "") != c.wantYRC {
				t.Fatalf("lrc=%q yrc=%q", res.lrc, res.yrc)
			}
			if lrcDownloads != c.wantLRCDL {
				t.Errorf("fmt=lrc 下了 %d 次,期望 %d", lrcDownloads, c.wantLRCDL)
			}
		})
	}
}

// 端到端:前 10 条都挑不出,正主排在第 11 条、或者只挂在某条的 Group 里,照样挑得出。
func TestResolveKugouLyricLooksPastFirstPage(t *testing.T) {
	filler := `{"hash":"f%d","songname":"别的歌","singername":"陈奕迅","album_name":"别的专辑","duration":200}`
	var items []string
	for i := 0; i < kugouSearchPrimaryItems; i++ {
		items = append(items, strings.Replace(filler, "%d", string(rune('a'+i)), 1))
	}
	right := `{"hash":"right","songname":"浮夸","singername":"陈奕迅","album_name":"U87","duration":283}`
	for name, page := range map[string][]string{
		"排在第 11 条":   append(append([]string{}, items...), right),
		"挂在 Group 里": append([]string{strings.Replace(items[0], `"duration":200}`, `"duration":200,"group":[`+right+`]}`, 1)}, items[1:]...),
	} {
		t.Run(name, func(t *testing.T) {
			var asked string
			withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
				switch {
				case target == "http://mobilecdn.kugou.com/api/v3/search/song":
					return http.StatusOK, kgTestPage(r, page)
				case target == "http://krcs.kugou.com/search":
					asked = r.URL.Query().Get("hash")
					return http.StatusOK, `{"status":200,"candidates":[{"id":"1","accesskey":"k"}]}`
				case strings.HasSuffix(target, ".kugou.com/download"):
					return http.StatusOK, `{"status":200,"content":"` + kgTestKRCContent(t, kgTestKRC) + `"}`
				}
				return http.StatusNotFound, ""
			})
			res := resolveKugouLyric(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
			if asked != "right" || res.album != "U87" || res.lrc == "" {
				t.Fatalf("该挑出 right: asked=%q %+v", asked, res)
			}
		})
	}
}

// kgTestPage 按请求的 pagesize 截出一页搜索结果。
func kgTestPage(r *http.Request, items []string) string {
	if n, _ := strconv.Atoi(r.URL.Query().Get("pagesize")); n > 0 && len(items) > n {
		items = items[:n]
	}
	return `{"status":1,"errcode":0,"data":{"info":[` + strings.Join(items, ",") + `]}}`
}

// 前 10 条里挑得出就用它,不拿后面更像的去换(原来挑得中的歌不变)。
func TestResolveKugouLyricKeepsFirstPagePick(t *testing.T) {
	var items []string
	items = append(items, `{"hash":"first","songname":"浮夸","singername":"陈奕迅","album_name":"别的专辑","duration":283}`)
	for i := 1; i < kugouSearchPrimaryItems; i++ {
		items = append(items, `{"hash":"f`+strconv.Itoa(i)+`","songname":"别的歌","singername":"陈奕迅","album_name":"别的专辑","duration":200}`)
	}
	items = append(items, `{"hash":"deep","songname":"浮夸","singername":"陈奕迅","album_name":"U87","duration":283}`)
	var asked string
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case target == "http://mobilecdn.kugou.com/api/v3/search/song":
			return http.StatusOK, kgTestPage(r, items)
		case target == "http://krcs.kugou.com/search":
			asked = r.URL.Query().Get("hash")
			return http.StatusOK, `{"status":200,"candidates":[{"id":"1","accesskey":"k"}]}`
		case strings.HasSuffix(target, ".kugou.com/download"):
			return http.StatusOK, `{"status":200,"content":"` + kgTestKRCContent(t, kgTestKRC) + `"}`
		}
		return http.StatusNotFound, ""
	})
	resolveKugouLyric(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if asked != "first" {
		t.Fatalf("前 10 条挑得出就用它: asked=%q", asked)
	}
}

// 封面:搜索结果自带的 union_cover 是专辑图就直接用,不再问 album/info;是歌手头像或没有才问。
func TestKugouSongCoverURL(t *testing.T) {
	for _, c := range []struct {
		name      string
		union     string
		want      string
		wantAsked int
	}{
		{"专辑图", "http://imge.kugou.com/stdmusic/{size}/20241118/a.jpg", "https://imge.kugou.com/stdmusic/0/20241118/a.jpg", 0},
		{"歌手头像", "http://singerimg.kugou.com/uploadpic/softhead/{size}/20240904/b.jpg", "https://imge.kugou.com/stdmusic/0/info.jpg", 1},
		{"没有", "", "https://imge.kugou.com/stdmusic/0/info.jpg", 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := withKugouFake(t, func(target string) (int, string) {
				if target == "http://mobilecdn.kugou.com/api/v3/album/info" {
					return http.StatusOK, `{"data":{"imgurl":"http://imge.kugou.com/stdmusic/{size}/info.jpg"}}`
				}
				return http.StatusNotFound, ""
			})
			s := kgTestSong("h", "浮夸", "陈奕迅", "U87", 283)
			s.AlbumID, s.TransParam.UnionCover = "968210", c.union
			if got := kugouSongCoverURL(qqRoundCtx(), &s); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
			if got := f.count("http://mobilecdn.kugou.com/api/v3/album/info"); got != c.wantAsked {
				t.Errorf("album/info 问了 %d 次,期望 %d", got, c.wantAsked)
			}
		})
	}
}

// songsearch 后端的 Grp 和封面也归一进 kugouSong。
func TestKugouSongSearchKeepsGroupsAndCover(t *testing.T) {
	const songsearch = `{"status":1,"error_code":0,"data":{"lists":[{"FileHash":"AAA","SongName":"Are You Ready","SingerName":"关浩德Walter","AlbumName":"Be","Duration":193,` +
		`"trans_param":{"union_cover":"http://imge.kugou.com/stdmusic/{size}/a.jpg"},"Grp":[{"FileHash":"BBB","SongName":"Are You Ready","SingerName":"关浩德Walter","AlbumName":"Just Be A Rock","Duration":193}]}]}}`
	withKugouFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/api/v3/search/song") {
			return http.StatusInternalServerError, ""
		}
		if target == "https://songsearch.kugou.com/song_search_v2" {
			return http.StatusOK, songsearch
		}
		return http.StatusNotFound, ""
	})
	songs, ok := kugouSearchSongs(qqRoundCtx(), "关浩德 Are You Ready")
	if !ok || len(songs) != 1 || songs[0].TransParam.UnionCover == "" || len(songs[0].Group) != 1 ||
		songs[0].Group[0].Hash != "bbb" || songs[0].Group[0].AlbumName != "Just Be A Rock" {
		t.Fatalf("Grp 和封面该归一进来: %+v", songs)
	}
}
