package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
)

func TestKuwoSongTitle(t *testing.T) {
	for in, want := range map[string]string{
		"抓狂-《最后一战3》XBOX360游戏主题曲": "抓狂",
		"能不能勇敢说爱 - 《公主小妹》电视剧插曲":  "能不能勇敢说爱",
		"雨眠":         "雨眠",
		"稻香 (3D环绕版)": "稻香 (3D环绕版)",
		"《红楼梦》":      "《红楼梦》",
		"Love-Lost":  "Love-Lost",
		// 尾段带书名号、宣传语标志词、「原唱：」的剥掉:
		"删了一百遍-汪苏泷概念创作集《联名2》作品":             "删了一百遍",
		"花田错-Sony Ericsson W900i 广告主题曲":     "花田错",
		"不将就-电影\"何以笙箫默\"片尾曲":                "不将就",
		"心升明月-2012年旅游卫视频道主题曲 现场版":           "心升明月-2012年旅游卫视频道主题曲 现场版",
		"心升明月-2012年旅游卫视频道主题曲":               "心升明月",
		"Regression-崩坏3《阿波卡利斯如是说》动画短片印象曲":   "Regression",
		"Wonderful Tonight-原唱：Eric Clapton": "Wonderful Tonight",
		"我的世界因你而改变-原唱:丢火车":                  "我的世界因你而改变",
		"不说(路过版)-电影《从你的全世界路过》主题曲":           "不说(路过版)",
		// 尾段里有版本词、尾段不是说明、前面剥空的不动:
		"阿姆斯壮 (Live)-天堂的五个朋友 07 Epic Mixing": "阿姆斯壮 (Live)-天堂的五个朋友 07 Epic Mixing",
		"你的志明-志明与春娇 粤语版":                     "你的志明-志明与春娇 粤语版",
		"月食-下雨版":                             "月食-下雨版",
		"继续-给十五岁的自己":                         "继续-给十五岁的自己",
		"E-Lover (Remastered)":               "E-Lover (Remastered)",
		"桥豆麻袋 (Live)-2016简单生活音乐节":            "桥豆麻袋 (Live)-2016简单生活音乐节",
		"-主题曲": "-主题曲",
	} {
		if got := kuwoSongTitle(in); got != want {
			t.Errorf("kuwoSongTitle(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestKuwoLyricLinesFromLRC(t *testing.T) {
	got := kuwoLyricLinesFromLRC("[ti:雨眠]\n[00:03.75]彼个有你的暗眠\n[01:02.5][02:10.25]副歌\n[03:00]没有小数\n不带时间戳的行")
	want := []kuwoLyricLine{{"3.750", "彼个有你的暗眠"}, {"62.500", "副歌"}, {"130.250", "副歌"}, {"180.000", "没有小数"}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("#%d got %+v want %+v", i, got[i], want[i])
		}
	}
}

const kuwoFakeSearch = `{"abslist":[{"MUSICRID":"MUSIC_214900","SONGNAME":"雨眠","ARTIST":"五月天","ALBUM":"爱情万岁","DURATION":"222"}]}`

// search.kuwo.cn 两种协议都没问成时换到 kuwo.cn 上同一套参数的搜索端点;前面问成了就不往后问。
func TestKuwoSearchFallsBackToWebEndpoint(t *testing.T) {
	for _, primaryDown := range []bool{true, false} {
		f := withKugouFake(t, func(target string) (int, string) {
			switch target {
			case "https://search.kuwo.cn/r.s", "http://search.kuwo.cn/r.s":
				if primaryDown {
					return http.StatusInternalServerError, ""
				}
				return http.StatusOK, kuwoFakeSearch
			case "https://kuwo.cn/search/searchMusicBykeyWord":
				return http.StatusOK, kuwoFakeSearch
			}
			return http.StatusNotFound, ""
		})
		ctx, _ := withLyricSourceRound(context.Background())
		items, err := kuwoSearch(ctx, "五月天", "雨眠")
		if err != nil || len(items) != 1 || items[0].SongName != "雨眠" {
			t.Fatalf("primaryDown=%v: items=%+v err=%v", primaryDown, items, err)
		}
		f.mu.Lock()
		webHits := f.hits["https://kuwo.cn/search/searchMusicBykeyWord"]
		f.mu.Unlock()
		if want := map[bool]int{true: 1, false: 0}[primaryDown]; webHits != want {
			t.Errorf("primaryDown=%v: 备用端点被问了 %d 次, want %d", primaryDown, webHits, want)
		}
	}
}

// kuwoFakeMobiBody 按 mlyric 的封装(kuwoDecodeLrcx 的逆过程)包一份 LRC。
func kuwoFakeMobiBody(t *testing.T, lrc string) string {
	t.Helper()
	data := []byte(lrc)
	key := []byte(kuwoLrcxKey)
	for i := range data {
		data[i] ^= key[i%len(key)]
	}
	var buf bytes.Buffer
	zw := zlib.NewWriter(&buf)
	if _, err := zw.Write([]byte(base64.StdEncoding.EncodeToString(data))); err != nil {
		t.Fatal(err)
	}
	zw.Close()
	return "TP=content\r\nlrcx=1\r\n\r\n" + buf.String()
}

// 网页端 getlyric 三个主机都没问成时退到 mlyric 的 lrcx=0;网页端正常答了「没有词」(空列表)不退。
func TestKuwoLyricFallsBackToMobiLRC(t *testing.T) {
	mobi := kuwoFakeMobiBody(t, "[ti:雨眠]\n[00:03.75]彼个有你的暗眠\n[00:09.00]第二句")
	for _, webDown := range []bool{true, false} {
		var mu sync.Mutex
		mobiHits := 0
		withKugouFake(t, func(target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/openapi/v1/www/lyric/getlyric"):
				if webDown {
					return http.StatusBadGateway, ""
				}
				return http.StatusOK, `{"code":200,"data":{"lrclist":[]}}`
			case target == "https://mlyric.kuwo.cn/mobi.s":
				mu.Lock()
				mobiHits++
				mu.Unlock()
				return http.StatusOK, mobi
			}
			return http.StatusNotFound, ""
		})
		ctx, _ := withLyricSourceRound(context.Background())
		lines, err := kuwoFetchLyric(ctx, "214900")
		mu.Lock()
		hits := mobiHits
		mu.Unlock()
		if webDown {
			if err != nil || len(lines) != 2 || lines[0].LineLyric != "彼个有你的暗眠" || lines[0].Time != "3.750" {
				t.Errorf("网页端没问成时应退到 mlyric: lines=%+v err=%v", lines, err)
			}
			if !strings.Contains(kuwoBuildLRC(lines), "[00:09.00]第二句") {
				t.Errorf("退回来的行应能照常拼成 LRC: %q", kuwoBuildLRC(lines))
			}
		} else if err != nil || len(lines) != 0 || hits != 0 {
			t.Errorf("网页端答了「没有词」时不该退到 mlyric: lines=%+v err=%v mobiHits=%d", lines, err, hits)
		}
	}
}

// 网页端 getlyric 回 HTTP 200 但 code 不是 200(实测出错时是 -1、success=false):算没问成,三个主机都这样就退到 mlyric;
// code 200、data 为空(实测查无时的形状)是答了没有词,不退。
func TestKuwoLyricRejectedCodeFallsBackToMobiLRC(t *testing.T) {
	mobi := kuwoFakeMobiBody(t, "[ti:雨眠]\n[00:03.75]彼个有你的暗眠\n[00:09.00]第二句")
	for _, c := range []struct {
		body     string
		wantMobi bool
	}{
		{`{"code":-1,"msg":"参数错误","success":false}`, true},
		{`{"code":200,"msg":"success","data":{},"success":true}`, false},
	} {
		var mu sync.Mutex
		mobiHits := 0
		withKugouFake(t, func(target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/openapi/v1/www/lyric/getlyric"):
				return http.StatusOK, c.body
			case target == "https://mlyric.kuwo.cn/mobi.s":
				mu.Lock()
				mobiHits++
				mu.Unlock()
				return http.StatusOK, mobi
			}
			return http.StatusNotFound, ""
		})
		ctx, _ := withLyricSourceRound(context.Background())
		lines, err := kuwoFetchLyric(ctx, "214900")
		mu.Lock()
		hits := mobiHits
		mu.Unlock()
		if got := hits > 0 && err == nil && len(lines) == 2; got != c.wantMobi {
			t.Errorf("%s: 退到 mlyric = %v(hits=%d lines=%d err=%v),期望 %v", c.body, got, hits, len(lines), err, c.wantMobi)
		}
		if !c.wantMobi && (err != nil || len(lines) != 0) {
			t.Errorf("%s: 查无应是空列表、不报错: %d %v", c.body, len(lines), err)
		}
	}
}

// 分数相同时专辑对得上的在前;分数不同时照分数排,专辑不管;都对不上专辑时保留搜索顺序;没有 MUSICRID 的不要,最多 5 条。
func TestKuwoRankItemsAlbumBreaksTie(t *testing.T) {
	items := []kuwoSearchItem{
		{SongName: "不说(路过版)-电影《从你的全世界路过》主题曲", Artist: "李荣浩", Album: "不说", Duration: "326", MusicRID: "MUSIC_1"},
		{SongName: "不说 (路过版)-《从你的全世界路过》电影路过版主题曲", Artist: "李荣浩", Album: "嗯", Duration: "326", MusicRID: "MUSIC_2"},
		{SongName: "不说 (路过版)", Artist: "李荣浩", Album: "嗯", Duration: "300", MusicRID: "MUSIC_3"},
		{SongName: "不说 (路过版)", Artist: "李荣浩", Album: "嗯", Duration: "326"},
		{SongName: "不说(路过版)", Artist: "李荣浩", Album: "热歌", Duration: "326", MusicRID: "MUSIC_4"},
		{SongName: "不说(路过版)", Artist: "李荣浩", Album: "金曲", Duration: "326", MusicRID: "MUSIC_5"},
		{SongName: "不说(路过版)", Artist: "李荣浩", Album: "合辑", Duration: "326", MusicRID: "MUSIC_6"},
	}
	var got []string
	for _, it := range kuwoRankItems(items, "李荣浩", "不说 (路过版)", "嗯", 326.474) {
		got = append(got, it.MusicRID)
	}
	want := []string{"MUSIC_2", "MUSIC_1", "MUSIC_4", "MUSIC_5", "MUSIC_6"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("排序 %v,期望 %v", got, want)
	}
}

// 取到词的几名里采纳时间轴对得上曲长的那名;都对不上、曲长未知时取名次最前的;都没取到返回 -1。
func TestKuwoPickFetchedRank(t *testing.T) {
	lrc := func(lastSecs int) string {
		return fmt.Sprintf("[00:01.00]第一句\n[%02d:%02d.00]最后一句\n", lastSecs/60, lastSecs%60)
	}
	for _, c := range []struct {
		name string
		lrcs []string
		dur  float64
		want int
	}{
		{"名次最前的截断了,取对得上的那名", []string{lrc(120), lrc(280)}, 290, 1},
		{"都对得上取名次最前的", []string{lrc(280), lrc(285)}, 290, 0},
		{"最前的超出曲长", []string{lrc(330), lrc(285)}, 290, 1},
		{"没取到的跳过", []string{"", lrc(285)}, 290, 1},
		{"都对不上取名次最前的", []string{lrc(100), lrc(120)}, 290, 0},
		{"曲长未知取名次最前的", []string{"", lrc(100), lrc(280)}, 0, 1},
		{"都没取到", []string{"", ""}, 290, -1},
	} {
		if got := kuwoPickFetchedRank(c.lrcs, c.dur); got != c.want {
			t.Errorf("%s: %d,期望 %d", c.name, got, c.want)
		}
	}
}

// 取词没问成的那几名可能本该采纳时,这一份不进缓存:名次更靠前的没问成;采纳的这份对不上曲长、后面有没问成的。
func TestKuwoFailedRankMayBeat(t *testing.T) {
	lrc := func(lastSecs int) string {
		return fmt.Sprintf("[00:01.00]第一句\n[%02d:%02d.00]最后一句\n", lastSecs/60, lastSecs%60)
	}
	for _, c := range []struct {
		name   string
		failed []bool
		lrcs   []string
		rank   int
		dur    float64
		want   bool
	}{
		{"前面一名没问成", []bool{true, false}, []string{"", lrc(280)}, 1, 290, true},
		{"采纳的对得上,后面没问成的不算", []bool{false, true}, []string{lrc(280), ""}, 0, 290, false},
		{"采纳的截断了,后面有没问成的", []bool{false, true}, []string{lrc(120), ""}, 0, 290, true},
		{"采纳的截断了,都问成了", []bool{false, false}, []string{lrc(120), lrc(130)}, 0, 290, false},
		{"曲长未知只看名次", []bool{false, true}, []string{lrc(120), ""}, 0, 0, false},
	} {
		if got := kuwoFailedRankMayBeat(c.failed, c.lrcs, c.rank, c.dur); got != c.want {
			t.Errorf("%s: %v,期望 %v", c.name, got, c.want)
		}
	}
}

// 名次最前的那份末句对不上曲长、排在后面的那名取词没问成:这一份交出去,但不算完整(不进缓存,下次再问)。
// 采纳的那份对得上时后面的不算,见 TestKuwoFailedRankMayBeat。
func TestKuwoTruncatedPickWithFailedLaterRankIsIncomplete(t *testing.T) {
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/r.s"):
			return http.StatusOK, `{"abslist":[` +
				`{"MUSICRID":"MUSIC_1","SONGNAME":"雨眠","ARTIST":"五月天","ALBUM":"爱情万岁","DURATION":"222"},` +
				`{"MUSICRID":"MUSIC_2","SONGNAME":"雨眠","ARTIST":"五月天","ALBUM":"爱情万岁","DURATION":"222"}]}`
		case strings.HasSuffix(target, "/openapi/v1/www/lyric/getlyric"):
			if r.URL.Query().Get("musicId") == "1" {
				return http.StatusOK, `{"code":200,"data":{"lrclist":[{"lineLyric":"第一句","time":"3.00"},` +
					`{"lineLyric":"第二句","time":"9.00"},{"lineLyric":"最后一句","time":"100.00"}]}}`
			}
			return http.StatusBadGateway, ""
		case strings.HasSuffix(target, "/mobi.s"):
			// 第一名的逐字接口答了(这首没有 lrcx);第二名退到 mlyric 也没问成。
			if r.URL.Query().Get("rid") == "1" {
				return http.StatusOK, "no lrcx"
			}
			return http.StatusBadGateway, ""
		}
		return http.StatusNotFound, ""
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	if r := resolveKuwoLyric(ctx, "五月天", "雨眠", "爱情万岁", 222); r.lyrics == "" {
		t.Fatal("第一名的词应当交出去")
	}
	if sub.complete(ctx) {
		t.Error("后面那名没问成,可能就是对得上曲长的那份,不该算完整")
	}
}
