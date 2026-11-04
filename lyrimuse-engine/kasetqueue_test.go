package main

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func kasetQueueSample(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("../shared/testdata/kaset-queue/reply.json")
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func kasetTitles(tracks []upcomingTrack) []string {
	var out []string
	for _, tr := range tracks {
		out = append(out, tr.artist+" - "+tr.title)
	}
	return out
}

func TestParseKasetQueue(t *testing.T) {
	sample := kasetQueueSample(t)
	got, ok := parseKasetQueue(sample, "The Police", "Every Breath You Take", 3)
	want := []string{"Van Halen - Jump (45 Version)", "a-ha - Take On Me", "Eurythmics, Annie Lennox, Dave Stewart - Sweet Dreams (Are Made Of This)"}
	if !ok || !reflect.DeepEqual(kasetTitles(got), want) {
		t.Fatalf("当前这首之后的 3 首: ok=%v got=%v", ok, kasetTitles(got))
	}
	if got[0].album != "" || got[0].duration != 243 || got[0].videoID != "SwYN7mTi6HM" {
		t.Errorf("不给专辑、时长与 videoId 照样例: %+v", got[0])
	}
	// 队列标的那一格跟播放器报的对不上(换歌那一下):按歌名 + 歌手找。
	got, ok = parseKasetQueue(sample, "a-ha", "Take On Me", 5)
	if !ok || len(got) != 3 || got[0].title != "Sweet Dreams (Are Made Of This)" {
		t.Errorf("按歌名歌手找到当前这首,取到队尾: ok=%v got=%v", ok, kasetTitles(got))
	}
	if _, ok := parseKasetQueue(sample, "Nobody", "Not In The Queue", 5); ok {
		t.Error("队列里没有当前这首应退回同专辑预取")
	}
	if _, ok := parseKasetQueue("not json", "The Police", "Every Breath You Take", 5); ok {
		t.Error("解析不出应退回")
	}
}

func TestParseKasetQueueRepeatModes(t *testing.T) {
	var r map[string]any
	if err := json.Unmarshal([]byte(kasetQueueSample(t)), &r); err != nil {
		t.Fatal(err)
	}
	with := func(mode string) string {
		r["repeating"] = mode
		b, _ := json.Marshal(r)
		return string(b)
	}
	if got, ok := parseKasetQueue(with("one"), "The Police", "Every Breath You Take", 5); !ok || len(got) != 0 {
		t.Errorf("单曲循环:没有要预取的、也不退回同专辑: ok=%v got=%v", ok, kasetTitles(got))
	}
	got, ok := parseKasetQueue(with("all"), "Cyndi Lauper", "Girls Just Want To Have Fun", 2)
	if !ok || !reflect.DeepEqual(kasetTitles(got), []string{"Michael Jackson - Thriller 7\" (Special Edit)", "The Police - Every Breath You Take"}) {
		t.Errorf("列表循环:队尾接回开头: ok=%v got=%v", ok, kasetTitles(got))
	}
	if got, ok := parseKasetQueue(with("off"), "Cyndi Lauper", "Girls Just Want To Have Fun", 2); !ok || len(got) != 0 {
		t.Errorf("不循环:队尾之后没有了: ok=%v got=%v", ok, kasetTitles(got))
	}
}

// 队列标的那一格对不上、按歌名歌手又找到不止一处:认不出是哪一格,退回同专辑预取。
// 接下来那几格里缺歌名或歌手的跳过,不当成一首。
func TestParseKasetQueueAmbiguousAndBlankRows(t *testing.T) {
	dup := `{"current_index":0,"repeating":"off","tracks":[
		{"title":"Intro","artist":"Band"},
		{"title":"Song","artist":"Band"},
		{"title":"Other","artist":"Band"},
		{"title":"Song","artist":"Band"}]}`
	if got, ok := parseKasetQueue(dup, "Band", "Song", 3); ok {
		t.Errorf("同一首出现两次应退回: got=%v", kasetTitles(got))
	}
	blanks := `{"current_index":0,"repeating":"off","tracks":[
		{"title":"Song","artist":"Band"},
		{"title":"","artist":"Band"},
		{"title":"No Artist","artist":""},
		{"title":"Next","artist":"Band"}]}`
	got, ok := parseKasetQueue(blanks, "Band", "Song", 3)
	if !ok || !reflect.DeepEqual(kasetTitles(got), []string{"Band - Next"}) {
		t.Errorf("缺歌名或歌手的跳过: ok=%v got=%v", ok, kasetTitles(got))
	}
}

// Pear Desktop 的队列由 App 整理成同一种回包,每格多一个专辑(PearDesktopAPI.queueReply):专辑带进预解析,缓存键才跟真播时对得上。
func TestParseKasetQueueCarriesAlbum(t *testing.T) {
	out := `{"current_index":0,"repeating":"off","tracks":[` +
		`{"title":"青花瓷","artist":"周杰倫","duration":239,"video_id":"Q8Tiz6INF7I","audio_video_id":"Q8Tiz6INF7I","album":"我很忙"},` +
		`{"title":"晴天","artist":"周杰伦","duration":318,"video_id":"DYptgVvkVLQ","audio_video_id":"DYptgVvkVLQ"},` +
		`{"title":"稻香","artist":"周杰倫","duration":223,"video_id":"sHD_z90ZKV0","audio_video_id":"sHD_z90ZKV0","album":"魔杰座"}]}`
	got, ok := parseKasetQueue(out, "周杰倫", "青花瓷", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("取到后两首: ok=%v got=%v", ok, kasetTitles(got))
	}
	if got[0].album != "" || got[1].album != "魔杰座" {
		t.Errorf("专辑原样带上,没有的为空: %q %q", got[0].album, got[1].album)
	}
}

func TestYouTubeMusicClient(t *testing.T) {
	for b, want := range map[string]bool{kasetBundleID: true, pearDesktopBundleID: true, appleMusicBundleID: false, "": false} {
		if youtubeMusicClient(b) != want {
			t.Errorf("youtubeMusicClient(%q) 应为 %v", b, want)
		}
	}
	noteKasetCurrentTrack(pearDesktopBundleID, "周杰倫", "青花瓷", "Q8Tiz6INF7I")
	defer noteKasetCurrentTrack("", "", "", "")
	if got := kasetVideoIDFor(pearDesktopBundleID, "周杰倫", "青花瓷"); got != "Q8Tiz6INF7I" {
		t.Errorf("Pear Desktop 带来的 videoId 记下来: %q", got)
	}
	if got := kasetVideoIDFor(appleMusicBundleID, "周杰倫", "青花瓷"); got != "" {
		t.Errorf("换成别的播放器不给: %q", got)
	}
}
