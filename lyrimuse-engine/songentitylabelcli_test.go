//go:build devtools

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSongISRCLabelReason(t *testing.T) {
	cases := []struct {
		a, b, want string
	}{
		{"Sam Smith|Stay With Me|In The Lonely Hour", "Sam Smith & Hikaru Utada|Stay With Me|In The Lonely Hour", "credit"},
		{"Sam Smith|Stay With Me (feat. Hikaru Utada)|X", "Sam Smith|Stay With Me|X", "credit"},
		{"Sam Smith|Stay With Me|In The Lonely Hour", "Sam Smith|Stay With Me|In The Lonely Hour (10 Year Anniversary Edition)", "edition"},
		{"A|Song|Album", "A|Song|Album [Explicit]", "edition"},
		{"A|Song|Is This Heaven?", "A|Song|Is This Heaven? (Extended)", "edition"},
		{"A|Song|Album", "A|Song|Other Album", ""},
		{"A|Song|Album", "A|Song|Album", ""},
	}
	for _, c := range cases {
		x := songTestVariant(c.a, enrichEntry{}, nil)
		y := songTestVariant(c.b, enrichEntry{}, nil)
		if got := songISRCLabelReason(&x, &y); got != c.want {
			t.Errorf("%s ↔ %s = %q, want %q", c.a, c.b, got, c.want)
		}
	}
}

// isrc 层只抽靠 ISRC 连着的写法对;同一对只出一条;已有的文件不覆盖。
func TestSongLabelISRCStratum(t *testing.T) {
	isrc := func(code string, secs float64) enrichEntry {
		return enrichEntry{DurationSecs: secs, ISRCs: []string{code}}
	}
	vs := []songVariant{
		songTestVariant("Sam Smith|Like I Can|In The Lonely Hour", isrc("GBUM71400001", 167), nil),
		songTestVariant("Sam Smith & Aitana|Like I Can|In The Lonely Hour (10 Year Anniversary Edition)", isrc("GBUM71400001", 167.2), nil),
		songTestVariant("B|Song|Album", isrc("USAAA1100001", 200), nil),
		songTestVariant("B|Song|Album (Deluxe)", isrc("USAAA1100001", 200.1), nil),
		songTestVariant("B|Song|Other", isrc("USAAA1100001", 200.2), nil),
		songTestVariant("C|Tune|Album", enrichEntry{DurationSecs: 180}, nil),
		songTestVariant("C|Tune|Album (Deluxe)", enrichEntry{DurationSecs: 180}, nil),
	}
	b, of := songTestBuild(t, vs, nil)
	if !songTestSame(of, "C|Tune|Album", "C|Tune|Album (Deluxe)") {
		t.Fatal("没有 ISRC 的那一对应当靠写法族并上,用来确认 isrc 层不抽它")
	}
	got := map[string]string{}
	for _, it := range b.sampleISRC() {
		if it.Stratum != "isrc" || len(it.Variants) != 2 || len(it.Pairs) != 1 {
			t.Fatalf("条目形态不对: %+v", it)
		}
		k := songPairKey(it.Variants[0].Key, it.Variants[1].Key)
		if _, dup := got[k]; dup {
			t.Errorf("同一对抽了两次: %s", k)
		}
		got[k] = it.Why
	}
	want := map[string]string{
		songPairKey("Sam Smith & Aitana|Like I Can|In The Lonely Hour (10 Year Anniversary Edition)", "Sam Smith|Like I Can|In The Lonely Hour"): "credit",
		songPairKey("B|Song|Album", "B|Song|Album (Deluxe)"): "edition",
	}
	if len(got) != len(want) {
		t.Errorf("抽到 %v, want %v", got, want)
	}
	for k, why := range want {
		if got[k] != why {
			t.Errorf("%s: why=%q, want %q", k, got[k], why)
		}
	}

	dir := t.TempDir()
	n, path, err := b.writeLabelSample(dir, "isrc")
	if err != nil || n != 2 || path != filepath.Join(dir, "sample-isrc.jsonl") {
		t.Fatalf("writeLabelSample = %d, %q, %v", n, path, err)
	}
	if err := os.WriteFile(path, []byte("labeled\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := b.writeLabelSample(dir, "isrc"); err == nil {
		t.Error("文件已经存在时应当报错")
	}
	if data, _ := os.ReadFile(path); string(data) != "labeled\n" {
		t.Error("已有的文件被覆盖了")
	}
	if _, _, err := b.writeLabelSample(dir, "nope"); err == nil {
		t.Error("不认的层应当报错")
	}
}

// share 层只抽检索 id 靠「另有一种中证据」进共享组、不认这一路就分开的写法对,Why 记中证据种类;强证据连着的不抽。
func TestSongLabelShareStratum(t *testing.T) {
	ne := func(id string, secs float64) enrichEntry {
		return enrichEntry{DurationSecs: secs, NeteaseURL: "https://music.163.com/song?id=" + id}
	}
	reg := func(id, title string) map[string]string { return map[string]string{"netease_song:" + id: title} }
	vs := []songVariant{
		songTestVariant("A|Song|Album", ne("1", 200), reg("1", "Song")),
		songTestVariant("A feat. B|Song|Single", ne("1", 200.3), reg("1", "Song")),
		songTestVariant("C|Tune|Album", enrichEntry{DurationSecs: 180, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("C feat. D|Tune|Single", enrichEntry{DurationSecs: 180.2, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("E|Air|Album", enrichEntry{DurationSecs: 150, NeteaseURL: "https://music.163.com/song?id=2", ISRCs: []string{"USAAA1100002"}}, reg("2", "Air")),
		songTestVariant("E feat. F|Air|Single", enrichEntry{DurationSecs: 150.1, NeteaseURL: "https://music.163.com/song?id=2", ISRCs: []string{"USAAA1100002"}}, reg("2", "Air")),
	}
	b, of := songTestBuild(t, vs, nil)
	idx := map[string]int{}
	for i := range b.variants {
		idx[b.variants[i].key] = i
	}
	if !songTestSame(of, "A|Song|Album", "A feat. B|Song|Single") || b.shareOf[idx["A|Song|Album"]] != b.shareOf[idx["A feat. B|Song|Single"]] {
		t.Fatal("前提:网易云 id 加写法族边应当把两条写法连进同一个共享组")
	}
	items := b.sampleShare()
	if len(items) != 1 || items[0].Stratum != "share" || items[0].Why != "family+netease_song" || len(items[0].Pairs) != 1 ||
		songPairKey(items[0].Variants[0].Key, items[0].Variants[1].Key) != songPairKey("A|Song|Album", "A feat. B|Song|Single") {
		t.Fatalf("只该抽到靠写法族旁证进组的那一对: %+v", items)
	}
	dir := t.TempDir()
	if n, path, err := b.writeLabelSample(dir, "share"); err != nil || n != 1 || path != filepath.Join(dir, "sample-share.jsonl") {
		t.Fatalf("writeLabelSample = %d, %q, %v", n, path, err)
	}
	var out bytes.Buffer
	labeled := items[0]
	labeled.Label = "different"
	data, _ := json.Marshal(labeled)
	scorePath := filepath.Join(t.TempDir(), "sample-share.jsonl")
	if err := os.WriteFile(scorePath, append(data, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := b.writeLabelScore(scorePath, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "标了 1 对(判不了 0),抽样时其实不是同一首 1 对(100.0%);现在仍在同一个共享组 1 对") {
		t.Errorf("share 层的数不对:\n%s", out.String())
	}
}

// isrc 层标 different 的一对现在仍在一起时算并错;文件里没有的层不报。
func TestSongLabelScoreISRC(t *testing.T) {
	vs := []songVariant{
		songTestVariant("A|Song|Album", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("A & B|Song|Album", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA1100001"}}, nil),
	}
	b, _ := songTestBuild(t, vs, nil)
	items := []songLabelItem{
		{ID: "isrc-1", Stratum: "isrc", Why: "credit", Label: "different",
			Variants: []songLabelVariant{{Key: "A & B|Song|Album"}, {Key: "A|Song|Album"}}},
		{ID: "isrc-2", Stratum: "isrc", Why: "credit", Label: "unsure",
			Variants: []songLabelVariant{{Key: "A & B|Song|Album"}, {Key: "A|Song|Album"}}},
	}
	var lines []string
	for _, it := range items {
		data, _ := json.Marshal(it)
		lines = append(lines, string(data))
	}
	path := filepath.Join(t.TempDir(), "sample-isrc.jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := b.writeLabelScore(path, &out); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	if !strings.Contains(s, "标了 2 对(判不了 1),抽样时其实不是同一首 1 对(100.0%);现在仍在一起 1 对") {
		t.Errorf("isrc 层的数不对:\n%s", s)
	}
	if strings.Contains(s, "多写法实体") || strings.Contains(s, "被否决") || strings.Contains(s, "相近") {
		t.Errorf("文件里没有的层不该报:\n%s", s)
	}
}
