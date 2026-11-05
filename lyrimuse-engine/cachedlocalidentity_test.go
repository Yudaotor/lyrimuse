package main

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// 缓存里那份网易云结果是搜出来的(别的播放器放过这首),之后网易云在放它、本机认得出:不用缓存那份,换成本机认的身份。
// 别的歌那一轮、本机认不出时照用缓存。
func TestNeteaseCachedSearchIdentityYieldsToLocalForPlayingTrack(t *testing.T) {
	resetSourceCachesForTest(t)
	withPlayingPlayer(t, neteaseMusicBundleID)
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, []string{neteaseTestPlayingVersion}))
	if _, ok := neteaseLocalEntry(context.Background(), "林忆莲", "至少还有你", "属于我的林忆莲", 275); !ok {
		t.Fatal("前提:本机曲库认得出这首")
	}
	searched := neteaseCacheEntry{info: neteaseInfo{SongID: 256621, SongURL: "https://music.163.com/song?id=256621",
		Cover: "https://p1.music.126.net/x.jpg"}, ts: time.Now().Unix()}
	neteaseMu.Lock()
	neteaseCache["林忆莲|至少还有你|属于我的林忆莲|275"] = searched
	neteaseCache["别人|别的歌|别的专辑|200"] = searched
	neteaseMu.Unlock()
	// 取消了的 ctx:本机认出之后取词那一趟发不出去,单测不连网。
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if info := neteaseLookupAll(withOtherTrackRound(ctx), "林忆莲", "至少还有你", "属于我的林忆莲", 275); info.SongID != 256621 || info.FromLocalClient {
		t.Errorf("别的歌那一轮照用缓存: %+v", info)
	}
	if info := neteaseLookupAll(ctx, "别人", "别的歌", "别的专辑", 200); info.SongID != 256621 {
		t.Errorf("本机认不出时照用缓存: %+v", info)
	}
	if info := neteaseLookupAll(ctx, "林忆莲", "至少还有你", "属于我的林忆莲", 275); !info.FromLocalClient || info.SongID != 256468 {
		t.Errorf("在放这首、本机认得出:换成本机认的那一条: %+v", info)
	}
}

func TestQQCachedSearchIdentityYieldsToLocalForPlayingTrack(t *testing.T) {
	resetQQLocalIndex(t, writeTestQQDB(t, qqLocalTestRows))
	qqURLMu.Lock()
	saved := qqURLCache
	searched := qqMusicMatch{url: qqSongURL("searchedMid0001"), title: "西西里", artist: "周杰伦", album: "太阳之子"}
	qqURLCache = map[string]qqMusicMatch{"周杰伦|西西里|太阳之子|229": searched, "别人|别的歌|别的专辑|200": searched}
	qqURLMu.Unlock()
	t.Cleanup(func() {
		qqURLMu.Lock()
		qqURLCache = saved
		qqURLMu.Unlock()
	})
	ctx := context.Background()

	if m := qqMusicMatchCached(withOtherTrackRound(ctx), "周杰伦", "西西里", "太阳之子", 229); m.fromLocalLibrary || qqMidFromURL(m.url) != "searchedMid0001" {
		t.Errorf("别的歌那一轮照用缓存: %+v", m)
	}
	if m := qqMusicMatchCached(ctx, "别人", "别的歌", "别的专辑", 200); qqMidFromURL(m.url) != "searchedMid0001" {
		t.Errorf("本机认不出时照用缓存: %+v", m)
	}
	if m := qqMusicMatchCached(ctx, "周杰伦", "西西里", "太阳之子", 229); !m.fromLocalLibrary || qqMidFromURL(m.url) != "003FdJZH1wljMU" {
		t.Errorf("在放这首、本机认得出:换成本机认的那一条: %+v", m)
	}
}

func TestKugouCachedSearchLyricYieldsToLocalForPlayingTrack(t *testing.T) {
	resetSourceCachesForTest(t)
	dir := t.TempDir()
	writeTestKRC(t, dir, "周杰伦 - 搁浅_abc.krc", testKRCGeLian)
	resetKugouLocalIndex(t, dir)
	f := withKugouFake(t, func(string) (int, string) { return http.StatusNotFound, "" })
	searched := kugouResult{lrc: "[00:01.00]搜来的那份", title: "搁浅", artist: "周杰伦"}
	kugouMu.Lock()
	kugouCache["周杰伦|搁浅|七里香"] = searched
	kugouCache["别人|别的歌|别的专辑"] = searched
	kugouMu.Unlock()
	ctx := qqRoundCtx()

	if r := kugouLyric(withOtherTrackRound(ctx), "周杰伦", "搁浅", "七里香", 0); r.fromLocalClient || r.lrc != searched.lrc {
		t.Errorf("别的歌那一轮照用缓存: local=%v lrc=%q", r.fromLocalClient, r.lrc)
	}
	if r := kugouLyric(ctx, "别人", "别的歌", "别的专辑", 0); r.lrc != searched.lrc {
		t.Errorf("本机认不出时照用缓存: lrc=%q", r.lrc)
	}
	if n := f.count("http://mobilecdn.kugou.com/api/v3/search/song"); n != 0 {
		t.Errorf("用缓存的两轮不该发请求,实际 %d 次", n)
	}
	if r := kugouLyric(ctx, "周杰伦", "搁浅", "七里香", 0); !r.fromLocalClient || r.lrc == searched.lrc {
		t.Errorf("在放这首、本机有这份:换成本机那份: local=%v lrc=%q", r.fromLocalClient, r.lrc)
	}
}
