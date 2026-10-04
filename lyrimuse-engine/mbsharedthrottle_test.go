package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func useTempSharedCooldown(t *testing.T) {
	t.Helper()
	setSharedCooldownPath(filepath.Join(t.TempDir(), "cooldowns.json"))
	t.Cleanup(func() { setSharedCooldownPath("") })
}

func TestMusicbrainzPauseFor(t *testing.T) {
	cases := map[string]time.Duration{"": musicbrainzThrottledPause, "5": 5 * time.Second, "600": time.Minute, "abc": musicbrainzThrottledPause, "0": musicbrainzThrottledPause}
	for in, want := range cases {
		if got := musicbrainzPauseFor(in); got != want {
			t.Errorf("Retry-After %q: got %v, want %v", in, got, want)
		}
	}
}

// 共享窗口:别的进程把「下一个请求最早什么时候发」推到了几百毫秒后 → 等一小会儿就发;推得很远(503 停手)→ 这次不发。
// 发之前自己也把窗口往后推一个间隔。
func TestMusicbrainzThrottleHonorsSharedWindow(t *testing.T) {
	useTempSharedCooldown(t)
	musicbrainzRateMu.Lock()
	musicbrainzLastCall = time.Time{}
	musicbrainzRateMu.Unlock()

	publishSharedCooldown("musicbrainz.org", sharedCooldownMusicBrainz, time.Now().Add(30*time.Second))
	if err := musicbrainzThrottle(context.Background()); !errors.Is(err, errHostGuarded) {
		t.Fatalf("窗口还要等 30 秒时这次不发: %v", err)
	}

	useTempSharedCooldown(t)
	publishSharedCooldown("musicbrainz.org", sharedCooldownMusicBrainz, time.Now().Add(300*time.Millisecond))
	start := time.Now()
	if err := musicbrainzThrottle(context.Background()); err != nil {
		t.Fatal(err)
	}
	if waited := time.Since(start); waited < 250*time.Millisecond {
		t.Fatalf("窗口没到要等: 只等了 %v", waited)
	}
	if until := sharedCooldownUntilFresh(sharedCooldownMusicBrainz, time.Now()); until.IsZero() {
		t.Fatal("发之前要把共享窗口往后推一个间隔")
	}
}

// 没问成(这里是共享窗口停手)不写身份缓存:缓存查一次永久生效,写进去就永远是「没有身份」。
func TestResolveArtistIdentityDoesNotCacheWhenNotAsked(t *testing.T) {
	useTempSharedCooldown(t)
	publishSharedCooldown("musicbrainz.org", sharedCooldownMusicBrainz, time.Now().Add(time.Minute))
	const name = "测试用歌手不存在的名字"
	artistIdentityMu.Lock()
	delete(artistIdentityCache, name)
	artistIdentityMu.Unlock()
	t.Cleanup(func() {
		artistIdentityMu.Lock()
		delete(artistIdentityCache, name)
		artistIdentityMu.Unlock()
	})
	resolveArtistIdentityMB(name, "")
	if _, ok := cachedArtistIdentity(name); ok {
		t.Fatal("没问成的歌手不该写进身份缓存")
	}
}
