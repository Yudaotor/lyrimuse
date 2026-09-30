package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
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
