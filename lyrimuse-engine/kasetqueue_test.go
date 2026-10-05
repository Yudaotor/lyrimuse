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
