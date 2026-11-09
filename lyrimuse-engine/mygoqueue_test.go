package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func myGoTestTrack(id, source, name, artist string) myGoTrack {
	t := myGoTrack{ID: id, Source: source, Name: name, Duration: 200_000}
	if artist != "" {
		t.Artists = append(t.Artists, struct {
			Name string `json:"name"`
		}{artist})
	}
	return t
}

func myGoTestSession() myGoSession {
	return myGoSession{
		Queue: []myGoTrack{
			myGoTestTrack("audio/a.mp3", "lizhi", "米店", "张玮玮"),
			myGoTestTrack("audio/b.mp3", "lizhi", "山阴路的夏天", "李志"),
			myGoTestTrack("0011223344556677", "local", "浮夸", "陈奕迅"),
			myGoTestTrack("audio/d.mp3", "lizhi", "杭州", "李志"),
		},
		Order: []int{0, 1, 2, 3},
		At:    1,
	}
}

func myGoTitles(ts []upcomingTrack) []string {
	out := make([]string, 0, len(ts))
	for _, t := range ts {
		out = append(out, t.title)
	}
	return out
}

func TestMyGoUpcomingFollowsTheSnapshotOrder(t *testing.T) {
	s := myGoTestSession()
	paths := map[string]string{"0011223344556677": "/Music/陈奕迅 - 浮夸.mp3"}
	got, ok := myGoUpcomingFrom(s, paths, "李志", "山阴路的夏天", 5)
	if !ok || len(got) != 2 || got[0].title != "浮夸" || got[1].title != "杭州" {
		t.Fatalf("got %v %v, want 浮夸, 杭州", myGoTitles(got), ok)
	}
	if got[0].artist != "陈奕迅" || got[0].path != "/Music/陈奕迅 - 浮夸.mp3" || got[0].duration != 200 {
		t.Fatalf("local track = %+v, want its artist, its file path and 200 s", got[0])
	}
	if got[1].path != "" {
		t.Fatalf("plugin track path = %q, want none", got[1].path)
	}
	s.Order = []int{3, 1, 0, 2}
	if got, _ := myGoUpcomingFrom(s, paths, "李志", "山阴路的夏天", 5); len(got) != 2 || got[0].title != "米店" || got[1].title != "浮夸" {
		t.Fatalf("shuffled: got %v, want 米店, 浮夸 (the play order, not the queue order)", myGoTitles(got))
	}
}

func TestMyGoUpcomingRepeatModes(t *testing.T) {
	s := myGoTestSession()
	s.Repeat = myGoRepeatOne
	if got, ok := myGoUpcomingFrom(s, nil, "李志", "山阴路的夏天", 5); !ok || len(got) != 0 {
		t.Fatalf("repeat one: got %v %v, want nothing to prefetch", myGoTitles(got), ok)
	}
	s.Repeat = myGoRepeatAll
	if got, _ := myGoUpcomingFrom(s, nil, "李志", "山阴路的夏天", 5); len(got) != 3 || got[2].title != "米店" {
		t.Fatalf("repeat all: got %v, want 浮夸, 杭州, 米店 (back to the start, not the current one again)", myGoTitles(got))
	}
	s.Repeat = myGoRepeatOff
	s.At = 3
	if got, ok := myGoUpcomingFrom(s, nil, "李志", "杭州", 5); !ok || len(got) != 0 {
		t.Fatalf("last track, no repeat: got %v %v, want nothing", myGoTitles(got), ok)
	}
	if got, _ := myGoUpcomingFrom(myGoTestSession(), nil, "李志", "山阴路的夏天", 1); len(got) != 1 {
		t.Fatalf("n=1: got %v", myGoTitles(got))
	}
}

func TestMyGoUpcomingStaleSnapshot(t *testing.T) {
	s := myGoTestSession()
	s.At = 0
	if got, ok := myGoUpcomingFrom(s, nil, "李志", "山阴路的夏天", 5); !ok || len(got) != 2 || got[0].title != "浮夸" {
		t.Fatalf("position behind: got %v %v, want it found by name further on", myGoTitles(got), ok)
	}
	if _, ok := myGoUpcomingFrom(s, nil, "李志", "梵高先生", 5); ok {
		t.Fatal("current track not in the snapshot (queue changed less than 30 s ago): want a fallback")
	}
	s.Queue = append(s.Queue, myGoTestTrack("audio/e.mp3", "lizhi", "山阴路的夏天", "李志"))
	s.Order = append(s.Order, 4)
	if _, ok := myGoUpcomingFrom(s, nil, "李志", "山阴路的夏天", 5); ok {
		t.Fatal("two matching entries away from the recorded position: want a fallback, not a guess")
	}
	bad := myGoTestSession()
	bad.Order = []int{0, 1}
	if _, ok := myGoUpcomingFrom(bad, nil, "李志", "山阴路的夏天", 5); ok {
		t.Fatal("order shorter than the queue: want a fallback")
	}
	bad.Order = []int{0, 1, 2, 9}
	if _, ok := myGoUpcomingFrom(bad, nil, "李志", "山阴路的夏天", 5); ok {
		t.Fatal("order out of range: want a fallback")
	}
}

func TestMyGoUpcomingSkipsEpisodesAndUnplayable(t *testing.T) {
	s := myGoTestSession()
	s.Queue[2].ShowID = "show-1"
	s.Queue[3].Unavailable = true
	if got, ok := myGoUpcomingFrom(s, nil, "李志", "山阴路的夏天", 5); !ok || len(got) != 0 {
		t.Fatalf("got %v %v, want the episode and the unplayable track skipped", myGoTitles(got), ok)
	}
}

func TestMyGoLocalTrackID(t *testing.T) {
	// 本机实测:session.json 里这两个文件的曲目 ID。
	for path, want := range map[string]string{
		"/Users/chenyuhao/Music/Lyrimuse测试/MyGo/MyGo Click M.mp3": "34b2897a8e6d7690",
		"/Users/chenyuhao/Music/Lyrimuse测试/MyGo/MyGo Click B.wav": "75f8939f2d4b2040",
	} {
		if got := myGoLocalTrackID(path); got != want {
			t.Fatalf("myGoLocalTrackID(%q) = %q, want %q", path, got, want)
		}
	}
}

func myGoWriteJSON(t *testing.T, path string, v any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestMyGoUpcomingReadsTheFiles(t *testing.T) {
	dir := t.TempDir()
	old := myGoDataDirOverride
	myGoDataDirOverride = dir
	t.Cleanup(func() { myGoDataDirOverride = old })
	file := "/Music/陈奕迅 - 浮夸.mp3"
	s := myGoTestSession()
	s.Queue[2].ID = myGoLocalTrackID(file)
	myGoWriteJSON(t, filepath.Join(dir, "session.json"), map[string]any{
		"queue": s.Queue, "order": s.Order, "at": s.At, "shuffle": false, "repeat": 0, "position": 1234,
	})
	myGoWriteJSON(t, filepath.Join(dir, "local", "index.json"), map[string]any{
		"version": 1, "tracks": []map[string]any{{"path": file, "title": "浮夸", "duration": 200000}},
	})
	got, ok := upcomingFromQueue("李志", "山阴路的夏天", "", myGoMusicBundleID, 0, 5)
	if !ok || len(got) != 2 || got[0].path != file {
		t.Fatalf("got %+v %v, want 浮夸 with its file path", got, ok)
	}
	myGoDataDirOverride = filepath.Join(dir, "missing")
	if _, ok := upcomingFromQueue("李志", "山阴路的夏天", "", myGoMusicBundleID, 0, 5); ok {
		t.Fatal("no session file: want a fallback")
	}
}

func TestMyGoQueueStampIgnoresThePosition(t *testing.T) {
	dir := t.TempDir()
	old := myGoDataDirOverride
	myGoDataDirOverride = dir
	t.Cleanup(func() { myGoDataDirOverride = old })
	path := filepath.Join(dir, "session.json")
	s := myGoTestSession()
	write := func(position int, at int, mod time.Time) {
		myGoWriteJSON(t, path, map[string]any{"queue": s.Queue, "order": s.Order, "at": at, "repeat": s.Repeat, "position": position})
		if err := os.Chtimes(path, mod, mod); err != nil {
			t.Fatal(err)
		}
	}
	base := time.Now().Add(-time.Hour)
	write(1000, 1, base)
	first := upcomingQueueStamp(myGoMusicBundleID)
	if first == "" {
		t.Fatal("no stamp for a readable snapshot")
	}
	write(31000, 2, base.Add(30*time.Second))
	if got := upcomingQueueStamp(myGoMusicBundleID); got != first {
		t.Fatal("stamp changed when only the position moved on: the queue would be read again every 30 s")
	}
	s.Queue = append(s.Queue, myGoTestTrack("audio/e.mp3", "lizhi", "梵高先生", "李志"))
	s.Order = append(s.Order, 4)
	write(32000, 2, base.Add(60*time.Second))
	if got := upcomingQueueStamp(myGoMusicBundleID); got == first {
		t.Fatal("stamp unchanged after a track was queued")
	}
	second := upcomingQueueStamp(myGoMusicBundleID)
	s.Queue[0] = myGoTestTrack("audio/x.mp3", "lizhi", "热河", "李志")
	write(33000, 2, base.Add(75*time.Second))
	if got := upcomingQueueStamp(myGoMusicBundleID); got == second {
		t.Fatal("stamp unchanged after a track was swapped for another one in the same slot")
	}
	second = upcomingQueueStamp(myGoMusicBundleID)
	s.Repeat = myGoRepeatAll
	write(32000, 2, base.Add(90*time.Second))
	if got := upcomingQueueStamp(myGoMusicBundleID); got == second {
		t.Fatal("stamp unchanged after the repeat mode changed")
	}
}
