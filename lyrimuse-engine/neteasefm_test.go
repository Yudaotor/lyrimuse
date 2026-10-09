package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeTestNeteaseFM 造一份跟真实 fmPlay 同构的私人漫游队列(曲目直接放在 queue 元素上),mtime 设成 mod。
func writeTestNeteaseFM(t *testing.T, current int, songs []testNeteaseSong, mod time.Time) {
	t.Helper()
	queue := make([]map[string]any, 0, len(songs))
	for _, s := range songs {
		artists := make([]map[string]any, 0, len(s.artists))
		for _, a := range s.artists {
			artists = append(artists, map[string]any{"id": 1, "name": a})
		}
		queue = append(queue, map[string]any{
			"id": 186652, "name": s.title, "artists": artists,
			"album": map[string]any{"name": s.album}, "duration": s.durationMS,
		})
	}
	body, err := json.Marshal(map[string]any{"currentIndex": current, "queue": queue})
	if err != nil {
		t.Fatalf("造 JSON: %v", err)
	}
	path := filepath.Join(t.TempDir(), "fmPlay")
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatalf("写测试文件: %v", err)
	}
	if err := os.Chtimes(path, mod, mod); err != nil {
		t.Fatalf("改 mtime: %v", err)
	}
	old := neteaseFMOverride
	neteaseFMOverride = path
	t.Cleanup(func() { neteaseFMOverride = old })
}

func setTestModTime(t *testing.T, path string, mod time.Time) {
	t.Helper()
	if err := os.Chtimes(path, mod, mod); err != nil {
		t.Fatalf("改 mtime: %v", err)
	}
}

var testFMSongs = []testNeteaseSong{
	{title: "一霎那", album: "我们的生活 充满阳光", artists: []string{"郑钧"}, durationMS: 149213},
	{title: "留月", album: "留月", artists: []string{"陈嘉俊是这个嘉"}, durationMS: 156569},
	{title: "隆盛", album: "隆盛", artists: []string{"野夫子"}, durationMS: 273788},
	{title: "骂醒我", album: "2022还在听热歌", artists: []string{"周汤豪"}, durationMS: 262866},
	{title: "Art Deco", album: "Honeymoon", artists: []string{"Lana Del Rey"}, durationMS: 295066},
}

func TestNeteaseFMTakesTracksAfterCurrentIndex(t *testing.T) {
	now := time.Now()
	list := writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "愿与愁", album: "甲", artists: []string{"林俊杰"}, durationMS: 1000},
	})
	setTestModTime(t, list, now.Add(-3*time.Minute))
	writeTestNeteaseFM(t, 1, testFMSongs, now)

	res, ok := upcomingFromQueue("陈嘉俊是这个嘉", "留月", "留月", neteaseMusicBundleID, 157, 5)
	if !ok {
		t.Fatal("私人漫游的队列里有当前这首,应取到后面几首")
	}
	got := titlesOf(res)
	want := []string{"隆盛", "骂醒我", "Art Deco"}
	if len(got) != len(want) {
		t.Fatalf("取到 %v,应为 %v(只往后数、不绕回)", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("取到 %v,应为 %v", got, want)
		}
	}
	if res[0].artist != "野夫子" || res[0].album != "隆盛" || res[0].duration != 273.788 {
		t.Fatalf("曲目字段不对: %+v", res[0])
	}
}

func TestNeteaseFMStaleIndexFallsBackToNameLookup(t *testing.T) {
	writeTestNeteaseFM(t, 0, testFMSongs, time.Now())
	res, ok := neteaseFMUpcoming("野夫子", "隆盛", 5)
	if !ok || len(res) != 2 || res[0].title != "骂醒我" {
		t.Fatalf("currentIndex 停在别的歌上时应按歌名找到位置,得到 %v ok=%v", titlesOf(res), ok)
	}
}

func TestNeteaseFMNewerButMissingFallsBackToPlayingList(t *testing.T) {
	now := time.Now()
	list := writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "第一首", album: "甲专辑", artists: []string{"甲"}, durationMS: 100000},
		{title: "第二首", album: "甲专辑", artists: []string{"甲"}, durationMS: 100000},
	})
	setTestModTime(t, list, now.Add(-time.Minute))
	writeTestNeteaseFM(t, 1, testFMSongs, now)

	res, ok := upcomingFromQueue("甲", "第一首", "甲专辑", neteaseMusicBundleID, 100, 5)
	if !ok || len(res) != 1 || res[0].title != "第二首" {
		t.Fatalf("私人漫游里没有这首时应改读 playingList,得到 %v ok=%v", titlesOf(res), ok)
	}
}

func TestNeteasePlayingListNewerStillTriesFMWhenMissing(t *testing.T) {
	now := time.Now()
	writeTestNeteaseFM(t, 1, testFMSongs, now.Add(-time.Minute))
	list := writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "第一首", album: "甲专辑", artists: []string{"甲"}, durationMS: 100000},
	})
	setTestModTime(t, list, now)

	res, ok := upcomingFromQueue("陈嘉俊是这个嘉", "留月", "留月", neteaseMusicBundleID, 157, 5)
	if !ok || len(res) != 3 {
		t.Fatalf("playingList 里没有这首时应再试私人漫游,得到 %v ok=%v", titlesOf(res), ok)
	}
}

func TestNeteasePlayingListNewerWinsWhenBothHaveTheTrack(t *testing.T) {
	now := time.Now()
	writeTestNeteaseFM(t, 1, testFMSongs, now.Add(-time.Minute))
	list := writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "留月", album: "留月", artists: []string{"陈嘉俊是这个嘉"}, durationMS: 156569},
		{title: "歌单里的下一首", album: "乙", artists: []string{"乙"}, durationMS: 100000},
	})
	setTestModTime(t, list, now)

	res, ok := upcomingFromQueue("陈嘉俊是这个嘉", "留月", "留月", neteaseMusicBundleID, 157, 5)
	if !ok || len(res) == 0 || res[0].title != "歌单里的下一首" {
		t.Fatalf("两份都有这首时应按最近改写的 playingList 取,得到 %v ok=%v", titlesOf(res), ok)
	}
}
