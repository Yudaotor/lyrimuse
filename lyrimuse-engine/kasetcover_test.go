package main

import (
	"context"
	"os"
	"strings"
	"testing"
)

func TestYTMusicLanguageFor(t *testing.T) {
	for in, want := range map[string]string{
		"zh-hans": "zh-Hans", "zh-hant": "zh-Hant", "zh": "zh-Hans", "zh-Hant-TW": "zh-Hant",
		"en": "en", "ja": "ja", "pt-br": "pt", "": "en", "  EN  ": "en",
	} {
		if got := ytmusicLanguageFor(in); got != want {
			t.Errorf("ytmusicLanguageFor(%q) = %q, want %q", in, got, want)
		}
	}
}

// 播放器没报专辑时,Kaset 这首选封面先看 YouTube Music 给它登记的专辑(按界面语言),再看 Apple 目录回填。
func TestCoverAlbumUsesKasetListedAlbum(t *testing.T) {
	withKasetAudioVideoIDs(t)
	withYTMusicCredits(t, map[string]ytmusicCredit{
		ytmusicCreditKey(ytmusicDisplayLanguage(), "57VMfkViG7c"): {artist: "方大同", title: "红豆", album: "Timeless"},
	})
	ctx := withYouTubeMusicVideoID(context.Background(), "57VMfkViG7c")
	if got := coverAlbumForTrack(ctx, "方大同", "红豆", "", 237); got != "Timeless" {
		t.Errorf("没报专辑时用登记的专辑: %q", got)
	}
	if got := coverAlbumForTrack(ctx, "方大同", "红豆", "可啦思刻", 237); got != "可啦思刻" {
		t.Errorf("播放器报了专辑就用它: %q", got)
	}
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"coverAlbum := coverAlbumForTrack(withYouTubeMusicVideoID(context.Background(), kasetVideoID), artist, title, album, durationSecs)",
		"\tctx = withCachedYouTubeMusicVideoIDLocked(ctx, key)\n\tenrichMu.Unlock()\n",
		"\t\tcoverAlbum = kasetListedAlbumFor(youTubeMusicVideoIDFrom(ctx), durationSecs, artist, title)\n",
	} {
		if !strings.Contains(string(src), want) {
			t.Errorf("enrich.go 缺 %q:选封面的三处都要先看登记的专辑", want)
		}
	}
}
