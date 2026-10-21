package main

import (
	"context"
	"os"
	"slices"
	"testing"
	"time"
)

// 没歌词的条目:设置里新开了歌词源、上一轮开搜时它还没开,不等退避马上补一次;名单跟现在一样就照退避走。
func TestNeedsLyricsFirstFillAfterSourceEnabled(t *testing.T) {
	path := withFeaturesFile(t, `{"lyrics_sources":["netease","qq"]}`)
	now := time.Now().Unix()
	empty := enrichEntry{TS: now, LyricsSourcesEnabled: []string{"netease", "qq"}}
	if needsLyricsFirstFill(empty) {
		t.Fatal("名单没变、刚搜过,该等退避")
	}

	rewrite(t, path, `{"lyrics_sources":["netease","qq","musixmatch"]}`)
	if !needsLyricsFirstFill(empty) {
		t.Error("新开了 musixmatch,该马上补搜")
	}
	for name, e := range map[string]enrichEntry{
		"老条目没记名单":  {TS: now},
		"标了纯音乐":    {TS: now, LyricsSourcesEnabled: []string{"netease"}, Instrumental: true},
		"手改过":      {TS: now, LyricsSourcesEnabled: []string{"netease"}, ManualLyrics: true},
		"有歌词":      {TS: now, LyricsSourcesEnabled: []string{"netease"}, Lyrics: bt("[00:01.00]x")},
		"刚补过、没连上源": {TS: now, LyricsSourcesEnabled: []string{"netease", "qq"}, LyricsFillTS: now - 5},
	} {
		if needsLyricsFirstFill(e) {
			t.Errorf("%s:不该补搜", name)
		}
	}
	retried := enrichEntry{TS: now, LyricsSourcesEnabled: []string{"netease", "qq"},
		LyricsFillTS: now - int64(lyricsFillSkippedReadyRetryInterval/time.Second)}
	if !needsLyricsFirstFill(retried) {
		t.Error("上次补空没连上、已经隔了 30 秒,该再来")
	}

	// 关掉一个源不算新开。
	rewrite(t, path, `{"lyrics_sources":["netease"]}`)
	if needsLyricsFirstFill(empty) {
		t.Error("只是关掉了 qq,不该补搜")
	}
}

// 名单在开搜那一刻取:搜的这十几秒里新开的源这一轮没问到,不能记进名单。
func TestLyricSourceRoundEnabledCapturedAtStart(t *testing.T) {
	path := withFeaturesFile(t, `{"lyrics_sources":["netease"]}`)
	_, round := withLyricSourceRound(context.Background())
	rewrite(t, path, `{"lyrics_sources":["netease","qq"]}`)
	if got := round.enabledSources(); !slices.Equal(got, []string{"netease"}) {
		t.Errorf("enabledSources() = %v, 要开搜那一刻的 [netease]", got)
	}
	if !lyricSourceEnabledSince(round.enabledSources()) {
		t.Error("qq 是开搜之后才开的,该算新开")
	}
	var none *lyricSourceRound
	if none.enabledSources() != nil {
		t.Error("没有 round(CLI 路径)该返回 nil")
	}
}

// 补空那一轮连上了源才更新名单;一个源都没连上时留着旧名单,新开的源下一次还认。首次解析那一支也记。
func TestLyricsSourcesEnabledWrittenAtRoundEnd(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	if !containsCode(src, `if reached {
		e.LyricsListedAlbum = listedAlbum
		e.LyricsNativeVideoID = kasetNativeLyricsVideoID(ctx, round, scored)
		e.LyricsSourcesEnabled = round.enabledSources()
	}`) {
		t.Error("补空 / 升级重试那一支该只在 reached 时更新名单")
	}
	if !containsCode(src, `e.LyricsListedAlbum = listedAlbum
	e.LyricsSourcesEnabled = round.enabledSources()
	recordISRCs(`) {
		t.Error("首次解析那一支没记名单")
	}
	if n := countCode(src, "e.LyricsSourcesEnabled = round.enabledSources()"); n != 2 {
		t.Errorf("enrich.go 里写名单 %d 处,该是 2 处", n)
	}
}
