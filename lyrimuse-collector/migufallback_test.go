package main

import (
	"net/http"
	"strings"
	"sync"
	"testing"
)

func TestMiguSearchQueries(t *testing.T) {
	if got := miguSearchQueries("Ariana Grande", "oh well"); strings.Join(got, "|") != "Ariana Grande oh well|oh well" {
		t.Errorf("got %q", got)
	}
	if got := miguSearchQueries("", "oh well"); strings.Join(got, "|") != "oh well" {
		t.Errorf("没有歌手时只搜一次歌名,got %q", got)
	}
}

const miguFakeLRC = "[00:01.00]line one\n[00:05.00]line two\n[00:09.00]line three\n[00:13.00]line four\n"

// 「歌手 歌名」挑不出候选时补搜一次只用歌名,补搜的结果照样过歌名 / 歌手闸;第一次就挑得出来不补搜;请求失败不补搜。
func TestMiguFallsBackToTitleOnlySearch(t *testing.T) {
	const popular = `{"code":"000000","songResultData":{"result":[{"name":"7 rings","singers":[{"name":"Ariana Grande"}],"lyricUrl":"https://d.musicapp.migu.cn/l/7.lrc"}]}}`
	const hit = `{"code":"000000","songResultData":{"result":[` +
		`{"name":"oh well","singers":[{"name":"Someone Else"}],"lyricUrl":"https://d.musicapp.migu.cn/l/x.lrc"},` +
		`{"name":"oh well","singers":[{"name":"Ariana Grande"}],"albums":[{"id":"9","name":"petal(Explicit)"}],"lyricUrl":"https://d.musicapp.migu.cn/l/1.lrc"}]}}`
	cases := []struct {
		name       string
		responses  []string // 每次搜索依次返回的内容;"fail" = 所有主机 500
		wantLyrics bool
		wantCalls  int
	}{
		{"首搜挑不出、补搜命中", []string{popular, hit}, true, 2},
		{"首搜就命中不补搜", []string{hit, popular}, true, 1},
		{"首搜请求失败不补搜", []string{"fail", hit}, false, 1},
		{"两次都挑不出", []string{popular, popular}, false, 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var mu sync.Mutex
			calls := 0
			withKugouFake(t, func(target string) (int, string) {
				switch {
				case strings.HasSuffix(target, "/content/search_all.do"):
					mu.Lock()
					defer mu.Unlock()
					i := calls
					if c.responses[min(i, len(c.responses)-1)] == "fail" {
						if strings.Contains(target, "c.musicapp.migu.cn") && !strings.Contains(target, "pd.") {
							calls++
						}
						return http.StatusInternalServerError, ""
					}
					calls++
					return http.StatusOK, c.responses[min(i, len(c.responses)-1)]
				case strings.HasSuffix(target, "/l/1.lrc"):
					return http.StatusOK, miguFakeLRC
				}
				return http.StatusNotFound, ""
			})
			r := resolveMiguLyric(qqRoundCtx(), "Ariana Grande", "oh well", "petal [Explicit]", 0)
			if got := r.lyrics != ""; got != c.wantLyrics {
				t.Errorf("lyrics=%v want %v (%+v)", got, c.wantLyrics, r)
			}
			if c.wantLyrics && r.artist != "Ariana Grande" {
				t.Errorf("补搜挑中的得是这位歌手的那条,got %q", r.artist)
			}
			mu.Lock()
			got := calls
			mu.Unlock()
			if got != c.wantCalls {
				t.Errorf("搜索轮次 %d want %d", got, c.wantCalls)
			}
		})
	}
}

// 前几条都只有纯文本时退回第一份纯文本、标 plainOnly;有一份同步的就用同步的,哪怕它名次靠后。
func TestMiguFallsBackToPlainText(t *testing.T) {
	const plain = "@migu music@\n@migu music@\nline one\nline two\n"
	const search = `{"code":"000000","songResultData":{"result":[` +
		`{"name":"Hit the Wall","singers":[{"name":"Gracie Abrams"}],"lyricUrl":"https://d.musicapp.migu.cn/l/p.lrc","trcUrl":"https://d.musicapp.migu.cn/l/tr.lrc"},` +
		`{"name":"Hit the Wall","singers":[{"name":"Gracie Abrams"}],"lyricUrl":"https://d.musicapp.migu.cn/l/SECOND.lrc"}]}}`
	cases := []struct {
		name, second string
		wantLyrics   string
		wantPlain    bool
	}{
		{"只有纯文本", plain, "line one\nline two\n", true},
		{"名次靠后的同步歌词优先", miguFakeLRC, miguFakeLRC, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withKugouFake(t, func(target string) (int, string) {
				switch {
				case strings.HasSuffix(target, "/content/search_all.do"):
					return http.StatusOK, search
				case strings.HasSuffix(target, "/l/p.lrc"):
					return http.StatusOK, plain
				case strings.HasSuffix(target, "/l/SECOND.lrc"):
					return http.StatusOK, c.second
				case strings.HasSuffix(target, "/l/tr.lrc"):
					return http.StatusOK, miguFakeLRC
				}
				return http.StatusNotFound, ""
			})
			r := resolveMiguLyric(qqRoundCtx(), "Gracie Abrams", "Hit the Wall", "", 0)
			if r.lyrics != c.wantLyrics || r.plainOnly != c.wantPlain {
				t.Fatalf("lyrics=%q plainOnly=%v, want %q %v", r.lyrics, r.plainOnly, c.wantLyrics, c.wantPlain)
			}
			if c.wantPlain && r.tr != "" {
				t.Errorf("纯文本不带译文,got tr=%q", r.tr)
			}
		})
	}
}
