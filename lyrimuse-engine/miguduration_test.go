package main

import (
	"math"
	"net/http"
	"strings"
	"sync"
	"testing"
)

func TestMiguItemDurationSecs(t *testing.T) {
	pq := miguRateFormat{Format: "020007", Size: "3577106", FileType: "mp3"}
	hq := miguRateFormat{Format: "020010", Size: "8942448", FileType: "mp3"}
	flac := miguRateFormat{Format: "011002", Size: "26134975", FileType: ""}
	for _, c := range []struct {
		name string
		item miguSearchItem
		want float64
	}{
		{"PQ 128k", miguSearchItem{NewRateFormats: []miguRateFormat{flac, pq, hq}}, 223.569},
		{"只有 HQ 320k", miguSearchItem{RateFormats: []miguRateFormat{hq}}, 223.561},
		{"没有 MP3 档用接口给的时长", miguSearchItem{RateFormats: []miguRateFormat{flac}, duration: 200}, 200},
		{"都没有", miguSearchItem{}, 0},
	} {
		if got := c.item.durationSecs(); math.Abs(got-c.want) > 0.01 {
			t.Errorf("%s: durationSecs = %.3f, want %.3f", c.name, got, c.want)
		}
	}
}

func TestMiguJadeiteSign(t *testing.T) {
	if got := miguJadeiteSign("周杰伦 稻香", "1700000000000"); got != "473cf1d21e1631f95faae91dd4f00a25" {
		t.Errorf("签名 = %s", got)
	}
}

// miguSearchJSON 拼一份 search_all.do 应答:每条歌名、歌手、歌词地址、PQ 档大小(按 128k 算时长)。
func miguSearchJSON(items ...[4]string) string {
	var parts []string
	for _, it := range items {
		parts = append(parts, `{"name":"`+it[0]+`","singers":[{"name":"`+it[1]+`"}],"lyricUrl":"`+it[2]+`",`+
			`"newRateFormats":[{"format":"020007","size":"`+it[3]+`","fileType":"mp3"}]}`)
	}
	return `{"code":"000000","songResultData":{"result":[` + strings.Join(parts, ",") + `]}}`
}

// 估出来的时长对不上的候选排到对得上的后面:咪咕排第一的是另一段录音(249 秒)时,挑排第二的(193 秒)。
func TestResolveMiguPrefersDurationFit(t *testing.T) {
	resetSourceCachesForTest(t)
	withKugouFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/content/search_all.do"):
			return http.StatusOK, miguSearchJSON(
				[4]string{"Me!", "Taylor Swift", "https://d.musicapp.migu.cn/l/wrong.lrc", "3984000"},
				[4]string{"ME!", "Taylor Swift", "https://d.musicapp.migu.cn/l/right.lrc", "3094400"})
		case strings.HasSuffix(target, "/l/wrong.lrc"):
			return http.StatusOK, "[00:01.00]wrong one\n[00:05.00]wrong two\n[00:09.00]wrong three\n[00:13.00]wrong four\n"
		case strings.HasSuffix(target, "/l/right.lrc"):
			return http.StatusOK, miguFakeLRC
		}
		return http.StatusNotFound, ""
	})
	r := resolveMiguLyric(qqRoundCtx(), "Taylor Swift", "ME!", "", 193)
	if r.lyrics != miguFakeLRC {
		t.Fatalf("应挑时长对得上的那条: %q", r.lyrics)
	}
	if math.Abs(r.durationSecs-193.4) > 0.1 {
		t.Errorf("结果该带上估出来的时长,实际 %.2f", r.durationSecs)
	}
}

// search_all.do 的主机都没问成时问 jadeite;search_all.do 答了(哪怕没结果)就不问。
func TestMiguFallsBackToJadeiteSearch(t *testing.T) {
	const jade = `{"code":"000000","songResultData":{"resultList":[[{"name":"稻香","album":"魔杰座","albumId":"25578","duration":223,` +
		`"lrcUrl":"https://d.musicapp.migu.cn/l/1.lrc","singerList":[{"name":"周杰伦"}]}]]}}`
	for _, c := range []struct {
		name       string
		searchDown bool
		wantLyrics bool
		wantJade   int
	}{
		{"主机都挂了", true, true, 1},
		{"主机答了没结果", false, false, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			resetSourceCachesForTest(t)
			var mu sync.Mutex
			jadeCalls := 0
			withKugouFake(t, func(target string) (int, string) {
				switch {
				case strings.HasSuffix(target, "/content/search_all.do"):
					if c.searchDown {
						return http.StatusInternalServerError, ""
					}
					return http.StatusOK, `{"code":"000000","songResultData":{"result":[]}}`
				case target == "https://jadeite.migu.cn/music_search/v3/search/searchAll":
					mu.Lock()
					jadeCalls++
					mu.Unlock()
					return http.StatusOK, jade
				case strings.HasSuffix(target, "/l/1.lrc"):
					return http.StatusOK, miguFakeLRC
				}
				return http.StatusNotFound, ""
			})
			r := resolveMiguLyric(qqRoundCtx(), "周杰伦", "稻香", "", 223)
			if (r.lyrics != "") != c.wantLyrics || jadeCalls != c.wantJade {
				t.Fatalf("lyrics=%q jadeite 调用 %d 次", r.lyrics, jadeCalls)
			}
			if c.wantLyrics && r.durationSecs != 223 {
				t.Errorf("备用搜索的时长取 duration 字段,实际 %.1f", r.durationSecs)
			}
		})
	}
}

// 歌词文件 https 没取到按 http 再取一次。
func TestMiguLyricFileFallsBackToHTTP(t *testing.T) {
	resetSourceCachesForTest(t)
	withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://d.musicapp.migu.cn/l/1.lrc":
			return http.StatusBadGateway, ""
		case "http://d.musicapp.migu.cn/l/1.lrc":
			return http.StatusOK, miguFakeLRC
		}
		if strings.HasSuffix(target, "/content/search_all.do") {
			return http.StatusOK, miguSearchJSON([4]string{"稻香", "周杰伦", "https://d.musicapp.migu.cn/l/1.lrc", "3577106"})
		}
		return http.StatusNotFound, ""
	})
	if r := resolveMiguLyric(qqRoundCtx(), "周杰伦", "稻香", "", 223); r.lyrics != miguFakeLRC {
		t.Fatalf("https 失败时应按 http 取到: %q", r.lyrics)
	}
}
