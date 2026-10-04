package main

import (
	"context"
	"net/http"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func withKasetAudioVideoIDs(t *testing.T) {
	t.Helper()
	kasetAudioMu.Lock()
	saved := kasetAudioVideoIDs
	kasetAudioVideoIDs = map[string]string{}
	kasetAudioMu.Unlock()
	t.Cleanup(func() { kasetAudioMu.Lock(); kasetAudioVideoIDs = saved; kasetAudioMu.Unlock() })
}

func TestKasetQueueAudioVideoIDs(t *testing.T) {
	got := kasetQueueAudioVideoIDs(`{"tracks":[` +
		`{"title":"Break","artist":"Jhené Aiko","video_id":"AJ--JpOmlog","audio_video_id":"ot0WzesOp6I"},` +
		`{"title":"X","artist":"Y","video_id":"bad id","audio_video_id":"ot0WzesOp6I"},` +
		`{"title":"Z","artist":"W","video_id":"SwYN7mTi6HM"}]}`)
	if want := map[string]string{"AJ--JpOmlog": "ot0WzesOp6I"}; !reflect.DeepEqual(got, want) {
		t.Errorf("只记两个都是 videoId 形状的: got %v", got)
	}
	sample := kasetQueueAudioVideoIDs(kasetQueueSample(t))
	if len(sample) != 7 || sample["OMOGaugKpzs"] != "OMOGaugKpzs" {
		t.Errorf("共用样例那份歌单里每首的音轨版本就是它自己: %v", sample)
	}
}

func TestKasetAudioVideoIDFor(t *testing.T) {
	withKasetAudioVideoIDs(t)
	noteKasetAudioVideoIDs(map[string]string{"AJ--JpOmlog": "ot0WzesOp6I"})
	if got := kasetAudioVideoIDFor("AJ--JpOmlog"); got != "ot0WzesOp6I" {
		t.Errorf("队列里见过的换成音轨版本: %q", got)
	}
	if got := kasetAudioVideoIDFor("SwYN7mTi6HM"); got != "SwYN7mTi6HM" {
		t.Errorf("没见过的就是它自己: %q", got)
	}
}

// 用 Kaset 放的歌:界面专辑位和上送都用判出来的专辑(判法见 kasetalbum.go)。
func TestKasetListedAlbum(t *testing.T) {
	withKasetAudioVideoIDs(t)
	hl := ytmusicDisplayLanguage()
	withYTMusicCredits(t, map[string]ytmusicCredit{
		ytmusicCreditKey(hl, "mQLzR5V2Z9c"): {artist: "Jhené Aiko & Ab-Soul", title: "Love Bomb", videoType: ytmusicVideoTypeOMV, durationSecs: 153},
		ytmusicCreditKey(hl, "iKWPxiflnyg"): {artist: "Jhené Aiko & Ab-Soul", title: "Love Bomb", album: "Westside Whimsy", durationSecs: 152},
	})
	noteKasetAudioVideoIDs(map[string]string{"mQLzR5V2Z9c": "iKWPxiflnyg"})
	if got := kasetListedAlbumFor("mQLzR5V2Z9c", 152.4, "Jhené Aiko, Ab-Soul", "Love Bomb"); got != "Westside Whimsy" {
		t.Errorf("放的视频跟音轨版本一样长,用音轨版本的专辑: %q", got)
	}
	if got := kasetListedAlbumFor("", 152, "Jhené Aiko", "Love Bomb"); got != "" {
		t.Errorf("没有 videoId 不给: %q", got)
	}
	noteKasetCurrentTrack(kasetBundleID, "Jhené Aiko, Ab-Soul", "Love Bomb", "mQLzR5V2Z9c")
	t.Cleanup(func() { noteKasetCurrentTrack("", "", "", "") })
	p := &poller{ctx: context.Background()}
	if got := p.albumHintFor(snapshot{Artist: "Jhené Aiko, Ab-Soul", Title: "Love Bomb", Bundle: kasetBundleID, Duration: 152}); got != "Westside Whimsy" {
		t.Errorf("上送的专辑跟界面一致: %q", got)
	}
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"ytmVerdict, ytmSettled := kasetAlbumVerdictFor(kasetVideoID, durationSecs, artist, title)",
		"if ytmSettled && applyKasetAlbumVerdict(&e, ytmVerdict, ytmusicDisplayLanguage()) {"} {
		if !strings.Contains(string(src), want) {
			t.Errorf("enrich.go 缺 %q:正在放的这首要把判出来的专辑写进条目(App 从缓存读)", want)
		}
	}
}

// 后台问:这一回先给空,问成之后记下;没问成隔一阵再问,不是每拍都问。
func TestYTMusicCreditCachedOrFetch(t *testing.T) {
	withYTMusicCredits(t, nil)
	var mu sync.Mutex
	failing := true
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		mu.Lock()
		f := failing
		mu.Unlock()
		if req.target != ytmNextURL || f {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(ytmCreditNext))
	})
	nextCalls := func() int {
		n := 0
		for _, r := range reqs() {
			if r.target == ytmNextURL {
				n++
			}
		}
		return n
	}
	key := ytmusicCreditKey("zh-Hans", "ot0WzesOp6I")
	pending := func() bool {
		ytmusicCreditMu.Lock()
		defer ytmusicCreditMu.Unlock()
		return ytmusicCreditPending[key]
	}
	if c, ok := ytmusicListedCachedOrFetch("ot0WzesOp6I", "zh-Hans"); c != (ytmusicCredit{}) || ok {
		t.Fatalf("还没问过,这一回先给空: %+v ok=%v", c, ok)
	}
	waitFor(t, "后台问完", func() bool { return !pending() })
	calls := nextCalls()
	if calls == 0 {
		t.Fatal("应该后台问过一次")
	}
	if c, ok := ytmusicListedCachedOrFetch("ot0WzesOp6I", "zh-Hans"); c != (ytmusicCredit{}) || ok || pending() || nextCalls() != calls {
		t.Errorf("没问成之后隔一阵再问,不是每拍都问")
	}
	mu.Lock()
	failing = false
	mu.Unlock()
	ytmusicCreditMu.Lock()
	ytmusicCreditFailedAt[key] = time.Now().Add(-2 * ytmusicCreditRetryAfter)
	ytmusicCreditMu.Unlock()
	ytmusicListedCachedOrFetch("ot0WzesOp6I", "zh-Hans")
	waitFor(t, "重试问完", func() bool { return !pending() })
	if c, ok := ytmusicListedCachedOrFetch("ot0WzesOp6I", "zh-Hans"); c.album != "Westside Whimsy" || !ok {
		t.Errorf("问成之后记下: %+v ok=%v", c, ok)
	}
	for _, r := range reqs() {
		if r.target != ytmNextURL {
			continue
		}
		if client, _ := r.body["context"].(map[string]any)["client"].(map[string]any); client["hl"] != "zh-Hans" {
			t.Errorf("按给的界面语言问: %+v", r.body["context"])
		}
	}
	if c, ok := ytmusicListedCachedOrFetch("ot0WzesOp6I", "en"); c != (ytmusicCredit{}) || ok {
		t.Error("另一种界面语言没问过,先给空")
	}
	if c, ok := ytmusicListedCachedOrFetch("bad id", "zh-Hans"); c != (ytmusicCredit{}) || !ok {
		t.Error("不是 videoId 的形状不问")
	}
}
