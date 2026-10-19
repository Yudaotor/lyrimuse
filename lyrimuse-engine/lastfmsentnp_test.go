package main

import (
	"context"
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

// Last.fm 自动纠正过写法(发 `Leehom Wang`,挂着的是 `王力宏`):回执里纠正之后的写法也认作自己的回声,重启后照样认得出。
func TestLfmNowPlayingEchoUsesCorrectedTags(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) {
		return `{"nowplaying":{"artist":{"corrected":"1","#text":"王力宏"},"track":{"corrected":"0","#text":"Xin Ren"},` +
			`"ignoredMessage":{"code":"0","#text":""}}}`, nil
	})
	p := env.p
	path := filepath.Join(t.TempDir(), "sent-np.json")
	p.lfm.sentNPPath = path
	p.cur = snapshot{Artist: "洛雪那首", Title: "暂停着的另一首"}
	if err := p.lfm.updateNowPlaying(context.Background(), "Leehom Wang", "Xin Ren", "", 200); err != nil {
		t.Fatal(err)
	}
	if !p.lfmNowPlayingEcho("王力宏", "Xin Ren", time.Now()) {
		t.Fatal("跟回执里纠正之后的写法对得上应算回声")
	}
	if !p.lfmNowPlayingEcho("Leehom Wang", "Xin Ren", time.Now()) {
		t.Error("发出去的写法照旧算回声")
	}
	after := &lastfmScrobbler{sentNPPath: path}
	after.restoreSentNowPlaying()
	if v := after.sentNowPlayingEntryAt(time.Now()); v == nil || v.corrArtist != "王力宏" || v.corrTrack != "Xin Ren" {
		t.Fatalf("纠正之后的写法要落盘、重启读回: %+v", v)
	}
}

// 回执晚到、说的已经不是现在挂着的那条:不记到后来那条上。
func TestNowPlayingCorrectionIgnoresStaleReceipt(t *testing.T) {
	s := &lastfmScrobbler{}
	t1 := time.Now().Add(-time.Minute)
	s.noteSentNowPlaying("A", "T", t1)
	s.noteSentNowPlaying("B", "U", time.Now())
	s.noteNowPlayingCorrection("A", "T", t1, "甲", "T")
	if v := s.sentNowPlayingEntryAt(time.Now()); v == nil || v.artist != "B" || v.corrArtist != "" {
		t.Fatalf("迟到的回执不该改到后来那条上: %+v", v)
	}
}

// `&` 和单词 `and` 当成同一个写法:Last.fm 把 `Beautiful, Loved & Blessed` 挂成 `… and …`。
func TestLfmNowPlayingEchoFoldsAmpersand(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return `{"nowplaying":{}}`, nil })
	p := env.p
	p.cur = snapshot{Artist: "Prince", Title: "Beautiful, Loved & Blessed"}
	if !p.lfmNowPlayingEcho("Prince", "Beautiful, Loved and Blessed", time.Now()) {
		t.Error("& 与 and 应算同一个写法")
	}
	if p.lfmNowPlayingEcho("Prince", "Beautiful, Loved and Cursed", time.Now()) {
		t.Error("别的曲名不该被当成同一首")
	}
}
