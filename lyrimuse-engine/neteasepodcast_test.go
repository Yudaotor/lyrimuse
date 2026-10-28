package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sync/atomic"
	"testing"
	"time"
)

// 条目照真实 playingList 的形状造:单集的 track 没有 artists,主播在 creator.nickname。
func neteaseTestQueue(t *testing.T, items ...map[string]any) []byte {
	t.Helper()
	b, err := json.Marshal(map[string]any{"list": items})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func neteaseTestVoice(kind, name, host string) map[string]any {
	track := map[string]any{"name": name, "programId": "3729609589"}
	if host != "" {
		track["creator"] = map[string]any{"nickname": host, "anchor": true}
	}
	return map[string]any{"resourceType": kind, "text": "彼岸的音乐日记", "track": track}
}

func neteaseTestSong(name, artist string) map[string]any {
	return map[string]any{"resourceType": "track",
		"track": map[string]any{"name": name, "artists": []map[string]string{{"name": artist}}}}
}

func TestNeteaseEpisodesFromQueue(t *testing.T) {
	got, ok := neteaseEpisodesFromQueue(neteaseTestQueue(t,
		neteaseTestVoice("voice", "三首听了就泪目的经典老歌", "NJ彼岸"),
		neteaseTestVoice("downloadVoice", "下载的那一集", "NJ彼岸"),
		neteaseTestVoice("localVoice", "本地的一集", ""),
		neteaseTestVoice("voice", "", "没名字"),
		neteaseTestSong("念想", "喔喔"),
	))
	want := []neteaseEpisode{
		{Title: "三首听了就泪目的经典老歌", Host: "NJ彼岸"},
		{Title: "下载的那一集", Host: "NJ彼岸"},
		{Title: "本地的一集", Host: ""},
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Fatalf("episodes = %+v, %v; want %+v", got, ok, want)
	}
	if got, ok := neteaseEpisodesFromQueue(neteaseTestQueue(t, neteaseTestSong("念想", "喔喔"))); !ok || got == nil || len(got) != 0 {
		t.Fatalf("songs only = %+v, %v; want an empty list", got, ok)
	}
	for _, raw := range []string{`{}`, `not json`, `{"list":"x"}`} {
		if _, ok := neteaseEpisodesFromQueue([]byte(raw)); ok {
			t.Fatalf("%q parsed as a queue", raw)
		}
	}
}

func readTestNeteaseEpisodes(t *testing.T, path string) (neteaseEpisodesState, bool) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return neteaseEpisodesState{}, false
	}
	if err != nil {
		t.Fatal(err)
	}
	var s neteaseEpisodesState
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatalf("published %q: %v", raw, err)
	}
	return s, true
}

func TestNeteaseEpisodesPublisherRefresh(t *testing.T) {
	dir := t.TempDir()
	p := &neteaseEpisodesPublisher{statePath: filepath.Join(dir, "episodes.json"), queuePath: filepath.Join(dir, "playingList")}
	write := func(b []byte, mod time.Time) {
		t.Helper()
		if err := os.WriteFile(p.queuePath, b, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p.queuePath, mod, mod); err != nil {
			t.Fatal(err)
		}
	}
	base := time.Now().Add(-time.Hour)

	if p.refresh() {
		t.Fatal("no queue file yet, want unknown")
	}
	write(neteaseTestQueue(t, neteaseTestVoice("voice", "一集", "主播")), base)
	if !p.refresh() {
		t.Fatal("queue with an episode, want readable")
	}
	s, ok := readTestNeteaseEpisodes(t, p.statePath)
	if !ok || !reflect.DeepEqual(s.Episodes, []neteaseEpisode{{Title: "一集", Host: "主播"}}) {
		t.Fatalf("published = %+v, %v", s, ok)
	}

	// 列表重写了、单集没变:不重写名单(拿一个哨兵内容验)。
	if err := os.WriteFile(p.statePath, []byte("sentinel"), 0o644); err != nil {
		t.Fatal(err)
	}
	write(neteaseTestQueue(t, neteaseTestVoice("voice", "一集", "主播"), neteaseTestSong("歌", "人")), base.Add(time.Minute))
	p.refresh()
	if raw, _ := os.ReadFile(p.statePath); string(raw) != "sentinel" {
		t.Fatalf("same episodes rewrote the list: %q", raw)
	}

	write(neteaseTestQueue(t, neteaseTestSong("歌", "人")), base.Add(2*time.Minute))
	p.refresh()
	if s, ok := readTestNeteaseEpisodes(t, p.statePath); !ok || s.Episodes == nil || len(s.Episodes) != 0 {
		t.Fatalf("songs only = %+v, %v; want an empty list (readable, no episodes)", s, ok)
	}

	write([]byte("not json"), base.Add(3*time.Minute))
	if p.refresh() {
		t.Fatal("unreadable queue, want unknown")
	}
	if _, ok := readTestNeteaseEpisodes(t, p.statePath); ok {
		t.Fatal("unreadable queue left the list in place")
	}

	write(neteaseTestQueue(t, neteaseTestVoice("voice", "一集", "主播")), base.Add(4*time.Minute))
	p.refresh()
	if err := os.Remove(p.queuePath); err != nil {
		t.Fatal(err)
	}
	if p.refresh() {
		t.Fatal("queue file gone, want unknown")
	}
	if _, ok := readTestNeteaseEpisodes(t, p.statePath); ok {
		t.Fatal("queue file gone but the list is still there")
	}
}

func TestNeteaseEpisodesWatcherFollowsRenamedQueue(t *testing.T) {
	dir := t.TempDir()
	p := &neteaseEpisodesPublisher{statePath: filepath.Join(dir, "episodes.json"), queuePath: filepath.Join(dir, "playingList")}
	// 先放一份只有歌的列表:监听起来时的那次刷新写出空名单,之后的单集只能靠跟着目录改动收到。
	if err := os.WriteFile(p.queuePath, neteaseTestQueue(t, neteaseTestSong("歌", "人")), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		runNeteaseEpisodesWatcher(ctx, p, time.Hour, time.Hour, func() string { return p.queuePath })
	}()
	defer func() {
		cancel()
		<-done
	}()
	waitFor := func(what string, n int) {
		t.Helper()
		deadline := time.Now().Add(2 * time.Second)
		for {
			if s, ok := readTestNeteaseEpisodes(t, p.statePath); ok && len(s.Episodes) == n {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("watcher did not publish %s", what)
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	waitFor("the empty list on start", 0)

	// 客户端的写法:临时文件写完再改名换上去。
	tmp := filepath.Join(dir, "playingList.tmp")
	if err := os.WriteFile(tmp, neteaseTestQueue(t, neteaseTestVoice("voice", "一集", "主播")), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, p.queuePath); err != nil {
		t.Fatal(err)
	}
	waitFor("the episode after the queue was renamed in", 1)

	cancel()
	<-done
	if _, ok := readTestNeteaseEpisodes(t, p.statePath); ok {
		t.Fatal("stopped watcher left the list behind")
	}
}

// 网易云沙盒版、非沙盒版换着用时列表换了根:盯着的时候重新取路径,变了就换目录重盯,新根里的单集照样进名单。
func TestNeteaseEpisodesWatcherFollowsQueueToAnotherRoot(t *testing.T) {
	dir := t.TempDir()
	oldRoot, newRoot := filepath.Join(dir, "container"), filepath.Join(dir, "standalone")
	for _, d := range []string{oldRoot, newRoot} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	oldQueue, newQueue := filepath.Join(oldRoot, "playingList"), filepath.Join(newRoot, "playingList")
	if err := os.WriteFile(oldQueue, neteaseTestQueue(t, neteaseTestSong("歌", "人")), 0o644); err != nil {
		t.Fatal(err)
	}
	var current atomic.Value
	current.Store(oldQueue)
	p := &neteaseEpisodesPublisher{statePath: filepath.Join(dir, "episodes.json")}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		runNeteaseEpisodesWatcher(ctx, p, time.Hour, 10*time.Millisecond, func() string { return current.Load().(string) })
	}()
	defer func() {
		cancel()
		<-done
	}()
	waitFor := func(what string, n int) {
		t.Helper()
		deadline := time.Now().Add(2 * time.Second)
		for {
			if s, ok := readTestNeteaseEpisodes(t, p.statePath); ok && len(s.Episodes) == n {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("watcher did not publish %s", what)
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	waitFor("the empty list from the old root", 0)

	if err := os.WriteFile(newQueue, neteaseTestQueue(t, neteaseTestVoice("voice", "一集", "主播")), 0o644); err != nil {
		t.Fatal(err)
	}
	current.Store(newQueue)
	waitFor("the episode from the new root", 1)
}
