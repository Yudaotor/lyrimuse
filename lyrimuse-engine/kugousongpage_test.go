package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// 签名的金值按网页版的算法独立算出(盐 + 键名排序后「键=值」连起来 + 盐,md5),这组参数打真接口回 status 1。
func TestKugouSearchParamsSignature(t *testing.T) {
	p := kugouSearchParams("周杰伦 稻香", "0123456789abcdef0123456789abcdef", time.UnixMilli(1700000000000))
	if got := p.Get("signature"); got != "f91e8327666ecf5a1063f8a893a966f9" {
		t.Errorf("signature = %s", got)
	}
	if p.Get("keyword") != "周杰伦 稻香" || p.Get("userid") != "0" || p.Get("token") != "" || p.Get("appid") != "1014" {
		t.Errorf("参数 = %v", p)
	}
}

func TestKugouSongPageFromSearch(t *testing.T) {
	body := []byte(`callback123({"status":1,"data":{"lists":[{"MixSongID":11,"EMixSongID":"aaaa11"},` +
		`{"MixSongID":32042828,"EMixSongID":"j2sek95"},{"MixSongID":"77","EMixSongID":"../x"}]}})`)
	if got, ok := kugouSongPageFromSearch(body, "32042828"); !ok || got != "https://www.kugou.com/mixsong/j2sek95.html" {
		t.Errorf("mixId 对得上那一条: %q %v", got, ok)
	}
	if got, ok := kugouSongPageFromSearch(body, "99"); !ok || got != "" {
		t.Errorf("没有这一首: %q %v", got, ok)
	}
	if got, _ := kugouSongPageFromSearch(body, "77"); got != "" {
		t.Errorf("EMixSongID 形状不对不认: %q", got)
	}
	for _, bad := range []string{`callback123({"status":0,"error_code":20010})`, `{"status":1}`, `callback123(<html>)`} {
		if got, ok := kugouSongPageFromSearch([]byte(bad), "11"); ok || got != "" {
			t.Errorf("%s: %q %v", bad, got, ok)
		}
	}
}

func TestKugouSongPageJobLocked(t *testing.T) {
	saved := kugouSongPageTried
	t.Cleanup(func() { kugouSongPageTried = saved })
	kugouSongPageTried = map[string]bool{}
	e := enrichEntry{PlayerSongIDs: map[string]string{kugouMusicBundleID: "32042828"}}
	if _, ok := kugouSongPageJobLocked("k", e, qqMusicBundleID, "周杰伦", "稻香"); ok {
		t.Error("不是酷狗在放不找")
	}
	if _, ok := kugouSongPageJobLocked("k", enrichEntry{}, kugouMusicBundleID, "周杰伦", "稻香"); ok {
		t.Error("没记下 mixId 不找")
	}
	withPage := e
	withPage.KugouURL = "https://www.kugou.com/mixsong/j2sek95.html"
	if _, ok := kugouSongPageJobLocked("k", withPage, kugouMusicBundleID, "周杰伦", "稻香"); ok {
		t.Error("已有网页歌曲页不找")
	}
	job, ok := kugouSongPageJobLocked("k", e, kugouMusicBundleID, "周杰伦", "稻香")
	if !ok || job.mixID != "32042828" || job.key != "k" || job.title != "稻香" {
		t.Errorf("job = %+v %v", job, ok)
	}
	if _, ok := kugouSongPageJobLocked("k", e, kugouMusicBundleID, "周杰伦", "稻香"); ok {
		t.Error("同一个 mixId 这次启动只试一次")
	}
}

func TestRunKugouSongPageJob(t *testing.T) {
	withTempDecisionCache(t)
	savedURL, savedKeys := kugouSearchURL, enrichPendingKeys
	savedNow, savedSave := enrichPendingNow, enrichSaveNow
	t.Cleanup(func() {
		kugouSearchURL = savedURL
		enrichMu.Lock()
		enrichPendingKeys = savedKeys
		enrichMu.Unlock()
		enrichPendingNow, enrichSaveNow = savedNow, savedSave
	})
	enrichPendingNow, enrichSaveNow = func() {}, func() {}
	var keywords []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		keywords = append(keywords, r.URL.Query().Get("keyword"))
		if r.URL.Query().Get("keyword") == "稻香" {
			w.Write([]byte(`callback123({"status":1,"data":{"lists":[{"MixSongID":32042828,"EMixSongID":"j2sek95"}]}})`))
			return
		}
		w.Write([]byte(`callback123({"status":1,"data":{"lists":[]}})`))
	}))
	defer srv.Close()
	kugouSearchURL = srv.URL
	const key = "周杰伦|稻香|魔杰座"
	for _, c := range []struct {
		name, noted, want string
	}{
		{"歌手 + 歌名没搜到、歌名搜到", "32042828", "https://www.kugou.com/mixsong/j2sek95.html"},
		{"搜的这段时间条目换了 mixId 不写", "11", ""},
	} {
		keywords = nil
		enrichMu.Lock()
		enrichPendingKeys = map[string]uint64{}
		enrichCache[key] = enrichEntry{PlayerSongIDs: map[string]string{kugouMusicBundleID: c.noted}}
		enrichMu.Unlock()
		runKugouSongPageJob(kugouSongPageJob{key: key, mixID: "32042828", artist: "周杰伦", title: "稻香"})
		enrichMu.Lock()
		got := enrichCache[key].KugouURL
		_, pending := enrichPendingKeys[key]
		enrichMu.Unlock()
		if got != c.want || pending != (c.want != "") {
			t.Errorf("%s: kugou_url = %q, 进待落盘 = %v", c.name, got, pending)
		}
		if len(keywords) != 2 || keywords[0] != "周杰伦 稻香" || keywords[1] != "稻香" {
			t.Errorf("%s: 搜的词 = %v", c.name, keywords)
		}
	}
}

func TestKugouSongPageFollowsMixID(t *testing.T) {
	page := "https://www.kugou.com/mixsong/j2sek95.html"
	e := enrichEntry{PlayerSongIDs: map[string]string{kugouMusicBundleID: "32042828"}, KugouURL: page}
	notePlayerSongIDLocked(&e, kugouMusicBundleID, "32042828")
	if e.KugouURL != page {
		t.Error("同一个 mixId 留着")
	}
	notePlayerSongIDLocked(&e, qqMusicBundleID, "001")
	if e.KugouURL != page {
		t.Error("别的播放器的 id 不碰它")
	}
	notePlayerSongIDLocked(&e, kugouMusicBundleID, "11")
	if e.KugouURL != "" {
		t.Error("mixId 换了,按旧 id 找的歌曲页删掉")
	}

	loser := enrichEntry{PlayerSongIDs: map[string]string{kugouMusicBundleID: "32042828"}, KugouURL: page}
	if got := mergePeripheralInto(enrichEntry{}, loser); got.KugouURL != page {
		t.Errorf("胜者没记 mixId:连同 mixId 带过来, %q", got.KugouURL)
	}
	other := enrichEntry{PlayerSongIDs: map[string]string{kugouMusicBundleID: "11"}}
	if got := mergePeripheralInto(other, loser); got.KugouURL != "" {
		t.Errorf("两条 mixId 不同不带, %q", got.KugouURL)
	}
}
