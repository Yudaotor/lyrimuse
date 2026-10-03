package main

import (
	"net/http"
	"strings"
	"sync"
	"testing"
)

// miguAliasItemJSON:一条带别名的 search_all.do 结果,PQ 档大小按 128k 折出时长。
func miguAliasItemJSON(name, singer, lyricURL, size, alias, translate string) string {
	return `{"name":"` + name + `","singers":[{"name":"` + singer + `"}],"lyricUrl":"` + lyricURL + `",` +
		`"newRateFormats":[{"format":"020007","size":"` + size + `","fileType":"mp3"}],` +
		`"songAliasName":"` + alias + `","translateName":"` + translate + `"}`
}

func miguResultJSON(items ...string) string {
	return `{"code":"000000","songResultData":{"result":[` + strings.Join(items, ",") + `]}}`
}

func TestMiguAliasNames(t *testing.T) {
	it := miguSearchItem{SongAliasName: "This Love、 Love Love Love ", TranslateName: "爱爱爱"}
	if got := strings.Join(it.aliasNames(), "|"); got != "This Love|Love Love Love|爱爱爱" {
		t.Errorf("got %q", got)
	}
	if got := (miguSearchItem{}).aliasNames(); len(got) != 0 {
		t.Errorf("没有别名时该是空: %q", got)
	}
}

// 按别名认:别名归一全等、本地时长已知且差 3% 以内、歌手闸与版本闸照旧,缺一样都不收。
func TestMiguAliasCandidate(t *testing.T) {
	base := miguSearchItem{Name: "爱爱爱", LyricURL: "https://d.musicapp.migu.cn/l/a.lrc", SongAliasName: "This Love、Love Love Love",
		NewRateFormats: []miguRateFormat{{Format: "020007", Size: "3417600", FileType: "mp3"}}}
	base.Singers = append(base.Singers, struct {
		Name string `json:"name"`
	}{"方大同"})
	live := base
	live.Name = "爱爱爱 (Live)"
	noURL := base
	noURL.LyricURL = ""
	for _, c := range []struct {
		name   string
		item   miguSearchItem
		artist string
		title  string
		dur    float64
		want   bool
	}{
		{"别名对上", base, "方大同", "Love Love Love", 213, true},
		{"别名大小写空格不同", base, "方大同", "love love  love", 213, true},
		{"本地时长未知", base, "方大同", "Love Love Love", 0, false},
		{"时长差 4%", base, "方大同", "Love Love Love", 222.5, false},
		{"别名只是包含", base, "方大同", "Love", 213, false},
		{"歌手对不上", base, "王力宏", "Love Love Love", 213, false},
		{"候选是现场版", live, "方大同", "Love Love Love", 213, false},
		{"没有歌词地址", noURL, "方大同", "Love Love Love", 213, false},
		{"本地曲名为空", base, "方大同", "", 213, false},
	} {
		if got := miguAliasCandidate(c.item, c.artist, c.title, "", c.dur); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 两种搜法都挑不出候选时,用按别名认的那条。
func TestResolveMiguFallsBackToAlias(t *testing.T) {
	resetSourceCachesForTest(t)
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/content/search_all.do"):
			return http.StatusOK, miguResultJSON(miguAliasItemJSON("爱爱爱", "方大同", "https://d.musicapp.migu.cn/l/alias.lrc", "3417600", "This Love、Love Love Love", ""))
		case strings.HasSuffix(target, "/l/alias.lrc"):
			return http.StatusOK, miguFakeLRC
		}
		return http.StatusNotFound, ""
	})
	r := resolveMiguLyric(qqRoundCtx(), "方大同", "Love Love Love", "This Love", 213)
	if r.lyrics != miguFakeLRC || r.title != "爱爱爱" {
		t.Fatalf("应按别名收下「爱爱爱」: title=%q lyrics=%q", r.title, r.lyrics)
	}
}

// 只要有一种搜法挑得出正常的候选,就不用按别名认的:同一次搜索里有正常候选时不看别名;第一次只有别名对得上时,
// 照常只用歌名再搜一次,那次有正常候选就用它。
func TestResolveMiguAliasOnlyWhenNoDirectMatch(t *testing.T) {
	alias := miguAliasItemJSON("爱爱爱", "方大同", "https://d.musicapp.migu.cn/l/alias.lrc", "3417600", "Love Love Love", "")
	direct := miguAliasItemJSON("Love Love Love", "方大同", "https://d.musicapp.migu.cn/l/direct.lrc", "3417600", "", "")
	const directLRC = "[00:01.00]direct one\n[00:05.00]direct two\n[00:09.00]direct three\n[00:13.00]direct four\n"
	for _, c := range []struct {
		name               string
		first, second      string
		wantSearches       int
		wantLyrics, wantTi string
	}{
		{"同一次搜索里有正常候选", miguResultJSON(alias, direct), miguResultJSON(), 1, directLRC, "Love Love Love"},
		{"只用歌名那次有正常候选", miguResultJSON(alias), miguResultJSON(direct), 2, directLRC, "Love Love Love"},
	} {
		t.Run(c.name, func(t *testing.T) {
			resetSourceCachesForTest(t)
			var mu sync.Mutex
			searches := 0
			withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
				switch {
				case strings.HasSuffix(target, "/content/search_all.do"):
					mu.Lock()
					searches++
					mu.Unlock()
					if r.URL.Query().Get("text") == "方大同 Love Love Love" {
						return http.StatusOK, c.first
					}
					return http.StatusOK, c.second
				case strings.HasSuffix(target, "/l/alias.lrc"):
					return http.StatusOK, miguFakeLRC
				case strings.HasSuffix(target, "/l/direct.lrc"):
					return http.StatusOK, directLRC
				}
				return http.StatusNotFound, ""
			})
			r := resolveMiguLyric(qqRoundCtx(), "方大同", "Love Love Love", "", 213)
			if r.lyrics != c.wantLyrics || r.title != c.wantTi {
				t.Fatalf("title=%q lyrics=%q", r.title, r.lyrics)
			}
			mu.Lock()
			defer mu.Unlock()
			if searches != c.wantSearches {
				t.Errorf("搜索 %d 次,want %d", searches, c.wantSearches)
			}
		})
	}
}

// 进程内缓存按时长分开:带时长时按别名收下的结果,不带时长再问同一首时不能直接拿去用。
func TestMiguLyricCacheKeyedByDuration(t *testing.T) {
	resetSourceCachesForTest(t)
	miguMu.Lock()
	saved := miguCache
	miguCache = map[string]miguResult{}
	miguMu.Unlock()
	t.Cleanup(func() {
		miguMu.Lock()
		miguCache = saved
		miguMu.Unlock()
	})
	var mu sync.Mutex
	searches := 0
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/content/search_all.do"):
			mu.Lock()
			searches++
			mu.Unlock()
			return http.StatusOK, miguResultJSON(miguAliasItemJSON("爱爱爱", "方大同", "https://d.musicapp.migu.cn/l/alias.lrc", "3417600", "Love Love Love", ""))
		case strings.HasSuffix(target, "/l/alias.lrc"):
			return http.StatusOK, miguFakeLRC
		}
		return http.StatusNotFound, ""
	})
	if r := miguLyric(qqRoundCtx(), "方大同", "Love Love Love", "This Love", 213); r.title != "爱爱爱" {
		t.Fatalf("带时长时该按别名收下: title=%q", r.title)
	}
	mu.Lock()
	n := searches
	mu.Unlock()
	if r := miguLyric(qqRoundCtx(), "方大同", "Love Love Love", "This Love", 0); r.lyrics != "" {
		t.Fatalf("不带时长时不该拿到按别名收下的结果: title=%q", r.title)
	}
	mu.Lock()
	defer mu.Unlock()
	if searches == n {
		t.Error("换了时长该重新搜")
	}
}
