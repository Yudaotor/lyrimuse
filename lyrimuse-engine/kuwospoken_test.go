package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// 酷我的说话类内容:会话不带专辑的,按搜索结果里逐字对上的那一条的专辑去问酷我,skipStart 大于 0 是长音频专辑。

const (
	kuwoTestStoryAlbum = "10344691"
	kuwoTestSongAlbum  = "7341667"
)

func kuwoTestItem(name, artist, duration, albumID string) kuwoSearchItem {
	raw, _ := json.Marshal(albumID)
	return kuwoSearchItem{SongName: name, Artist: artist, Duration: duration, AlbumID: raw}
}

func TestKuwoSpokenAlbumID(t *testing.T) {
	items := []kuwoSearchItem{
		kuwoTestItem("【喷火龙和弟弟】妈妈爱弟弟也爱我：我要变成小宝宝【宝宝巴士故事】", "宝宝巴士", "438", "14213628"),
		kuwoTestItem("我要变成小宝宝", "宝宝巴士", "200", "1"),
		kuwoTestItem("我要变成小宝宝", "喜马拉雅", "509", "93443725"),
		kuwoTestItem("我要变成小宝宝", "宝宝巴士", "509", "0"),
		kuwoTestItem("我要变成小宝宝", "宝宝巴士", "509", "10344703"),
		kuwoTestItem("我要变成小宝宝", "宝宝巴士", "509", "10344704"),
	}
	if got := kuwoSpokenAlbumID(items, "宝宝巴士", "我要变成小宝宝", 510.06); got != "10344703" {
		t.Errorf("歌名、歌手、时长都对上的第一条带专辑的: got %q", got)
	}
	if got := kuwoSpokenAlbumID(items, "宝宝巴士", "我要变成小宝宝", 0); got != "1" {
		t.Errorf("会话时长未知不比时长: got %q", got)
	}
	if got := kuwoSpokenAlbumID(items, "宝宝巴士", "我要变成小宝宝", 520); got != "" {
		t.Errorf("时长差出 3 秒不算: got %q", got)
	}
	if got := kuwoSpokenAlbumID(items, "宝宝巴士", "小宝宝", 509); got != "" {
		t.Errorf("歌名只是包含不算: got %q", got)
	}
	promo := []kuwoSearchItem{kuwoTestItem("至少还有你-《大丈夫》电视剧主题曲", "姚贝娜", "120", "123")}
	if got := kuwoSpokenAlbumID(promo, "姚贝娜", "至少还有你", 120.5); got != "123" {
		t.Errorf("去掉宣传尾段再比: got %q", got)
	}
	if got := kuwoSpokenAlbumID([]kuwoSearchItem{{SongName: "晚安，小红伞", Artist: "宝宝巴士", Duration: "319",
		AlbumID: json.RawMessage(`10344691`)}}, "宝宝巴士", "晚安，小红伞", 319.06); got != kuwoTestStoryAlbum {
		t.Errorf("专辑 id 是数字也认: got %q", got)
	}
	if got := kuwoSpokenAlbumID(items, "", "我要变成小宝宝", 509); got != "" {
		t.Errorf("没有歌手不认: got %q", got)
	}
}

func TestKuwoAlbumSkipStart(t *testing.T) {
	story := `{'aartist':'Baby&nbsp;Bus','albumid':'10344691','name':'睡前故事：晚安宝贝','musiclist':[],'skipEnd':'0','skipStart':'3000','songnum':'88'}`
	if skip, ok := kuwoAlbumSkipStart([]byte(story), kuwoTestStoryAlbum); !ok || skip != 3000 {
		t.Errorf("故事专辑: skip=%d ok=%v", skip, ok)
	}
	song := `{"albumid":"7341667","skipEnd":"0","skipStart":"0"}`
	if skip, ok := kuwoAlbumSkipStart([]byte(song), kuwoTestSongAlbum); !ok || skip != 0 {
		t.Errorf("儿歌专辑(双引号): skip=%d ok=%v", skip, ok)
	}
	if _, ok := kuwoAlbumSkipStart([]byte(story), kuwoTestSongAlbum); ok {
		t.Error("应答不是问的那张专辑不认")
	}
	if _, ok := kuwoAlbumSkipStart([]byte(`{'albumid':'10344691','skipEnd':'0'}`), kuwoTestStoryAlbum); ok {
		t.Error("没有 skipStart 不认")
	}
}

// kuwoSpokenFake 接管酷我搜索与专辑信息两个接口,记下各问了几次。
type kuwoSpokenFake struct {
	mu                   sync.Mutex
	searches, albumInfos int
	searchStatus         int
}

func withKuwoSpokenFake(t *testing.T) *kuwoSpokenFake {
	t.Helper()
	resetKuwoSpoken(t)
	f := &kuwoSpokenFake{searchStatus: http.StatusOK}
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		f.mu.Lock()
		defer f.mu.Unlock()
		switch {
		case strings.HasSuffix(target, "search.kuwo.cn/r.s") && r.URL.Query().Get("stype") == "albuminfo":
			f.albumInfos++
			switch r.URL.Query().Get("albumid") {
			case kuwoTestStoryAlbum:
				return http.StatusOK, `{'albumid':'10344691','skipEnd':'0','skipStart':'3000'}`
			case kuwoTestSongAlbum:
				return http.StatusOK, `{'albumid':'7341667','skipEnd':'0','skipStart':'0'}`
			}
			return http.StatusOK, `{'albumid':'0'}`
		case strings.HasSuffix(target, "/r.s") || strings.HasSuffix(target, "/searchMusicBykeyWord"):
			f.searches++
			if f.searchStatus != http.StatusOK {
				return f.searchStatus, ""
			}
			return http.StatusOK, `{"abslist":[` +
				`{"SONGNAME":"晚安，小红伞","ARTIST":"宝宝巴士","DURATION":"319","ALBUMID":"10344691"},` +
				`{"SONGNAME":"晚安，农场","ARTIST":"宝宝巴士","DURATION":"116","ALBUMID":"7341667"}]}`
		}
		return http.StatusNotFound, ""
	})
	return f
}

func (f *kuwoSpokenFake) counts() (searches, albumInfos int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.searches, f.albumInfos
}

// resetKuwoSpoken 清空结论表,那一问改成同步执行。
func resetKuwoSpoken(t *testing.T) {
	t.Helper()
	reset := func() {
		kuwoSpokenMu.Lock()
		kuwoSpokenVerdicts, kuwoSpokenAsking, kuwoSpokenFailedAt = map[string]bool{}, map[string]bool{}, map[string]time.Time{}
		kuwoSpokenMu.Unlock()
	}
	reset()
	oldGo := kuwoSpokenGo
	kuwoSpokenGo = func(f func()) { f() }
	t.Cleanup(func() {
		kuwoSpokenGo = oldGo
		reset()
	})
}

func TestKuwoSpokenVerdict(t *testing.T) {
	f := withKuwoSpokenFake(t)
	if spoken, pending := kuwoSpokenVerdict("宝宝巴士", "晚安，小红伞", "睡前故事", 319.06); spoken || pending {
		t.Fatalf("会话报了专辑的不问: spoken=%v pending=%v", spoken, pending)
	}
	if s, a := f.counts(); s != 0 || a != 0 {
		t.Fatalf("会话报了专辑的不发请求: search=%d album=%d", s, a)
	}
	if spoken, pending := kuwoSpokenVerdict("宝宝巴士", "晚安，小红伞", "", 319.06); !spoken || pending {
		t.Fatalf("故事: spoken=%v pending=%v", spoken, pending)
	}
	if spoken, _ := kuwoSpokenVerdict("宝宝巴士", "晚安，农场", "", 116.2); spoken {
		t.Fatal("儿歌不是说话类")
	}
	if spoken, _ := kuwoSpokenVerdict("宝宝巴士", "没有这一首", "", 200); spoken {
		t.Fatal("搜不到对得上的当歌")
	}
	if s, a := f.counts(); s != 3 || a != 2 {
		t.Fatalf("搜三次、问两张专辑: search=%d album=%d", s, a)
	}
	if spoken, _ := kuwoSpokenVerdict("宝宝巴士", "晚安，小红伞", "", 319.2); !spoken {
		t.Fatal("问过的记住")
	}
	if s, a := f.counts(); s != 3 || a != 2 {
		t.Fatalf("问过的不再问: search=%d album=%d", s, a)
	}
	if spoken, _ := kuwoSpokenVerdict("", "晚安，小红伞", "", 319); spoken {
		t.Fatal("没有歌手当歌")
	}
	if s, _ := f.counts(); s != 3 {
		t.Fatalf("没有歌手不发请求: search=%d", s)
	}
}

// 没问成当歌,冷却期内不再问;后台还在问时报「还在判」。
func TestKuwoSpokenVerdictFailureAndPending(t *testing.T) {
	f := withKuwoSpokenFake(t)
	f.searchStatus = http.StatusInternalServerError
	if spoken, pending := kuwoSpokenVerdict("宝宝巴士", "晚安，小红伞", "", 319); spoken || pending {
		t.Fatalf("没问成当歌: spoken=%v pending=%v", spoken, pending)
	}
	searches, _ := f.counts()
	if searches == 0 {
		t.Fatal("问过一次")
	}
	kuwoSpokenVerdict("宝宝巴士", "晚安，小红伞", "", 319)
	if again, _ := f.counts(); again != searches {
		t.Fatalf("冷却期内不再问: %d → %d", searches, again)
	}

	var later func()
	asks := 0
	kuwoSpokenGo = func(fn func()) { later, asks = fn, asks+1 }
	f.searchStatus = http.StatusOK
	if spoken, pending := kuwoSpokenVerdict("宝宝巴士", "晚安，农场", "", 116); spoken || !pending {
		t.Fatalf("后台还在问: spoken=%v pending=%v", spoken, pending)
	}
	if _, pending := kuwoSpokenVerdict("宝宝巴士", "晚安，农场", "", 116); !pending || asks != 1 {
		t.Fatalf("同一首在问着不另起一问: pending=%v asks=%d", pending, asks)
	}
	later()
	if spoken, pending := kuwoSpokenVerdict("宝宝巴士", "晚安，农场", "", 116); spoken || pending {
		t.Fatalf("问完有结论: spoken=%v pending=%v", spoken, pending)
	}
}

// 结论表满了整表清掉,只留刚问完的那一条。
func TestKuwoSpokenVerdictTableIsCapped(t *testing.T) {
	withKuwoSpokenFake(t)
	kuwoSpokenMu.Lock()
	for i := 0; i < kuwoSpokenMaxVerdicts; i++ {
		kuwoSpokenVerdicts[kuwoSpokenKey("歌手", "歌"+string(rune('a'+i%26))+strings.Repeat("x", i/26), 200)] = false
	}
	kuwoSpokenMu.Unlock()
	if spoken, _ := kuwoSpokenVerdict("宝宝巴士", "晚安，小红伞", "", 319); !spoken {
		t.Fatal("满表时照常问、照常记")
	}
	kuwoSpokenMu.Lock()
	n := len(kuwoSpokenVerdicts)
	kuwoSpokenMu.Unlock()
	if n != 1 {
		t.Fatalf("满了清表只留这一条: %d", n)
	}
}

func kuwoSpokenTick(title string, dur, pos float64, at time.Time) snapshot {
	return snapshot{Title: title, Artist: "宝宝巴士", Bundle: kuwoMusicBundleID, Duration: dur,
		Playing: true, Rate: 1, Position: pos, AnchorTS: at}
}

// 会话流程:开播那一拍结论还在问 → 正在播放先等;结论到了是说话类 → 不宣布、过线不提交;儿歌照常当歌。
func TestHandleKuwoStoryIsNotASong(t *testing.T) {
	resetPlayerCatalogMemo(t)
	resetKuwoLocalIndex(t, t.TempDir())
	withKuwoSpokenFake(t)
	var later []func()
	kuwoSpokenGo = func(fn func()) { later = append(later, fn) }

	at := handleClock()
	story := kuwoSpokenTick("晚安，小红伞", 319.06, 0, at(0))
	p := handleTestPoller(t, story)
	handleTick(p, at(0), story)
	if p.sess.isSpoken || !p.sess.pnPending || !p.sess.prefetchDeferred || p.sess.announcing {
		t.Fatalf("结论没到先等: spoken=%v pending=%v deferred=%v announcing=%v",
			p.sess.isSpoken, p.sess.pnPending, p.sess.prefetchDeferred, p.sess.announcing)
	}
	if len(later) != 1 {
		t.Fatalf("开播交给后台问一次: %d", len(later))
	}
	later[0]()
	for s := 1; s <= 200; s += 3 {
		handleTick(p, at(s), kuwoSpokenTick("晚安，小红伞", 319.06, float64(s), at(s)))
	}
	if !p.sess.isSpoken || p.sess.announcing || !p.sess.listenSent || len(p.submitsInflight) != 0 {
		t.Fatalf("说话类不当歌: spoken=%v announcing=%v sent=%v inflight=%d",
			p.sess.isSpoken, p.sess.announcing, p.sess.listenSent, len(p.submitsInflight))
	}

	kuwoSpokenGo = func(fn func()) { fn() }
	song := kuwoSpokenTick("晚安，农场", 116.2, 0, at(0))
	q := handleTestPoller(t, song)
	handleTick(q, at(0), song)
	for s := 1; s <= 80; s += 3 {
		handleTick(q, at(s), kuwoSpokenTick("晚安，农场", 116.2, float64(s), at(s)))
	}
	if q.sess.isSpoken || q.sess.prefetchDeferred {
		t.Fatalf("儿歌照常当歌: spoken=%v deferred=%v", q.sess.isSpoken, q.sess.prefetchDeferred)
	}
}

// 判出来的记进条目的 player_spoken(App 读它让 Discord 不显示);只看酷我,别的播放器不为这一判发请求。
func TestKuwoSpokenReachesCatalogIDs(t *testing.T) {
	resetPlayerCatalogMemo(t)
	resetKuwoLocalIndex(t, t.TempDir())
	f := withKuwoSpokenFake(t)
	ids := playerCatalogIDsFor(kuwoMusicBundleID, "宝宝巴士", "晚安，小红伞", "", 319.06)
	if !ids.spoken || ids.spokenPending {
		t.Fatalf("酷我故事: %+v", ids)
	}
	var e enrichEntry
	if !applyPlayerCatalogIDsLocked(&e, kuwoMusicBundleID, ids) || !e.PlayerSpoken {
		t.Fatalf("记进条目: %+v", e)
	}
	if !playerMarksSpoken(kuwoSpokenTick("晚安，小红伞", 319.06, 0, time.Now())) {
		t.Fatal("playerMarksSpoken 认酷我")
	}
	before, _ := f.counts()
	playerMarksSpoken(snapshot{Title: "晚安，小红伞", Artist: "宝宝巴士", Bundle: qqMusicBundleID, Duration: 319})
	playerSpokenPending(snapshot{Title: "晚安，农场", Artist: "宝宝巴士", Bundle: neteaseMusicBundleID, Duration: 116})
	if after, _ := f.counts(); after != before {
		t.Fatalf("别的播放器不问酷我: %d → %d", before, after)
	}
}

// 结论到了、会话还没置上 isSpoken 的那几拍(推送由桥接、收听提交的结果触发):网页中继同样不推这一首。
func TestPushRelayStateSkipsKuwoStoryBeforeSessionMarks(t *testing.T) {
	resetPlayerCatalogMemo(t)
	resetKuwoLocalIndex(t, t.TempDir())
	withKuwoSpokenFake(t)
	t0 := time.Now()
	cur := kuwoSpokenTick("晚安，小红伞", 319.06, 0, t0)
	if !playerMarksSpoken(cur) {
		t.Fatal("结论已经到了")
	}
	p := &poller{ctx: context.Background(), cfg: &config{StateRelayURL: "http://127.0.0.1:9"}, relayDoneCh: make(chan relayPushResult, 1),
		cur: cur, sess: &playSession{key: cur.key(), startedAt: t0}}
	p.pushRelayState(t0.Add(spokenVerdictWait), false)
	key := p.relayDeferKey
	if p.relayInflight {
		key = (<-p.relayDoneCh).key
	}
	if strings.HasPrefix(key, "mac") {
		t.Fatalf("说话类不当 Mac 在放推: %q", key)
	}
}

func TestAwaitsSpokenVerdictWaitsForKuwo(t *testing.T) {
	resetPlayerCatalogMemo(t)
	resetKuwoLocalIndex(t, t.TempDir())
	withKuwoSpokenFake(t)
	kuwoSpokenGo = func(func()) {}
	t0 := time.Now()
	s := kuwoSpokenTick("晚安，小红伞", 319, 0, t0)
	if !awaitsSpokenVerdict(s, t0, t0.Add(time.Second)) {
		t.Fatal("酷我还在问 → 等")
	}
	if awaitsSpokenVerdict(s, t0, t0.Add(spokenVerdictWait)) {
		t.Fatal("等到上限就不等了")
	}
	s.Album = "睡前故事"
	if awaitsSpokenVerdict(s, t0, t0.Add(time.Second)) {
		t.Fatal("报了专辑的不问、不等")
	}
}
