package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 发出去的正在播放落盘,重启后(新建一个 scrobbler 读回)回声窗口内照样认得出;过了窗口不认。
func TestSentNowPlayingSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sent-np.json")
	sentAt := time.Now().Add(-2 * time.Minute)
	before := &lastfmScrobbler{sentNPPath: path}
	before.noteSentNowPlaying("Harry Styles", "Cinema", sentAt)

	after := &lastfmScrobbler{sentNPPath: path}
	after.restoreSentNowPlaying()
	if a, tr := after.sentNowPlayingAt(time.Now()); a != "Harry Styles" || tr != "Cinema" {
		t.Fatalf("回声窗口内要认得出: %q %q", a, tr)
	}
	if _, tr := after.sentNowPlayingAt(sentAt.Add(lastfmSentNPEchoWindow + time.Second)); tr != "" {
		t.Fatalf("过了回声窗口不再认: %q", tr)
	}
}

// 文件不在、坏了、缺曲名都当没有;没配路径时不落盘。
func TestLoadSentNowPlayingRejectsBadFiles(t *testing.T) {
	dir := t.TempDir()
	if loadSentNowPlaying(filepath.Join(dir, "missing.json")) != nil {
		t.Fatal("文件不在要返回 nil")
	}
	bad := filepath.Join(dir, "bad.json")
	for _, body := range []string{"{", `{"artist":"A","track":"","at":1}`, `{"artist":"A","track":"T","at":0}`} {
		if err := os.WriteFile(bad, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if loadSentNowPlaying(bad) != nil {
			t.Fatalf("坏文件要返回 nil: %s", body)
		}
	}
	s := &lastfmScrobbler{}
	s.noteSentNowPlaying("A", "T", time.Now())
	if _, tr := s.sentNowPlayingAt(time.Now()); tr != "T" {
		t.Fatalf("没配路径时内存里照样记: %q", tr)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Fatalf("没配路径时不该多写文件: %d", len(entries))
	}
}
