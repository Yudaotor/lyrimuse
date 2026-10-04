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

// 用 Kaset 放的歌:界面专辑位和上送都用 YouTube Music 给音轨版本登记的专辑。
func TestKasetListedAlbum(t *testing.T) {
	withKasetAudioVideoIDs(t)
	withYTMusicCredits(t, map[string]ytmusicCredit{"ot0WzesOp6I": {artist: "Jhené Aiko", title: "Break", album: "Westside Whimsy"}})
	noteKasetAudioVideoIDs(map[string]string{"AJ--JpOmlog": "ot0WzesOp6I"})
	if got := kasetListedAlbumFor("AJ--JpOmlog"); got != "Westside Whimsy" {
		t.Errorf("按音轨版本取专辑: %q", got)
	}
	if got := kasetListedAlbumFor(""); got != "" {
		t.Errorf("没有 videoId 不给: %q", got)
	}
	noteKasetCurrentTrack(kasetBundleID, "Jhené Aiko", "Break", "AJ--JpOmlog")
	t.Cleanup(func() { noteKasetCurrentTrack("", "", "", "") })
	p := &poller{ctx: context.Background()}
	if got := p.albumHintFor(snapshot{Artist: "Jhené Aiko", Title: "Break", Bundle: kasetBundleID, Duration: 196}); got != "Westside Whimsy" {
		t.Errorf("上送的专辑跟界面一致: %q", got)
	}
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"youtubeMusicAlbum := kasetListedAlbumFor(kasetVideoID)",
		"if youtubeMusicAlbum != \"\" && e.YouTubeMusicAlbum != youtubeMusicAlbum {"} {
		if !strings.Contains(string(src), want) {
			t.Errorf("enrich.go 缺 %q:正在放的这首要把登记的专辑写进条目(App 从缓存读)", want)
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
	pending := func() bool {
		ytmusicCreditMu.Lock()
		defer ytmusicCreditMu.Unlock()
		return ytmusicCreditPending["ot0WzesOp6I"]
	}
	if c := ytmusicCreditCachedOrFetch("ot0WzesOp6I"); c != (ytmusicCredit{}) {
		t.Fatalf("还没问过,这一回先给空: %+v", c)
	}
	waitFor(t, "后台问完", func() bool { return !pending() })
	calls := nextCalls()
	if calls == 0 {
		t.Fatal("应该后台问过一次")
	}
	if c := ytmusicCreditCachedOrFetch("ot0WzesOp6I"); c != (ytmusicCredit{}) || pending() || nextCalls() != calls {
		t.Errorf("没问成之后隔一阵再问,不是每拍都问")
	}
	mu.Lock()
	failing = false
	mu.Unlock()
	ytmusicCreditMu.Lock()
	ytmusicCreditFailedAt["ot0WzesOp6I"] = time.Now().Add(-2 * ytmusicCreditRetryAfter)
	ytmusicCreditMu.Unlock()
	ytmusicCreditCachedOrFetch("ot0WzesOp6I")
	waitFor(t, "重试问完", func() bool { return !pending() })
	if c := ytmusicCreditCachedOrFetch("ot0WzesOp6I"); c.album != "Westside Whimsy" {
		t.Errorf("问成之后记下: %+v", c)
	}
	if c := ytmusicCreditCachedOrFetch("bad id"); c != (ytmusicCredit{}) {
		t.Error("不是 videoId 的形状不问")
	}
}
