package main

import (
	"slices"
	"testing"
)

// 缓存 key 用完整歌名之后,按歌名记的几张表写的一边是播放器原样的歌名、读的一边常是流水线里剥过括号的,两边都按旧规则
// 算才对得上(见 legacyEnrichKey)。

func TestPlaybackTrackIDsReadWithStrippedTitle(t *testing.T) {
	saved := playbackTrackIDHints
	playbackTrackIDHints = map[string]playbackTrackIDs{}
	t.Cleanup(func() { playbackTrackIDHints = saved })
	notePlayingSpotifyTrackID("丁世光", "不散的筵席（I Miss You）", "神經志", "4uLU6hMCjMI75M1A2tKUQC")
	notePlayingAppleCatalogID("丁世光", "不散的筵席（I Miss You）", "神經志", 1440841122)
	for _, title := range []string{"不散的筵席", "不散的筵席（I Miss You）"} {
		apple, spotify := playbackTrackIDsFor("丁世光", title, "神經志")
		if apple != "1440841122" || spotify != "4uLU6hMCjMI75M1A2tKUQC" {
			t.Errorf("按 %q 读不到原样歌名记下的 id: %q %q", title, apple, spotify)
		}
	}
}

func TestSpotifyTrackIDHintReadWithStrippedTitle(t *testing.T) {
	saved, savedLast := spotifyTrackIDHints, spotifyTrackIDLastKey
	spotifyTrackIDHints, spotifyTrackIDLastKey = map[string]string{}, ""
	t.Cleanup(func() { spotifyTrackIDHints, spotifyTrackIDLastKey = saved, savedLast })
	noteSpotifyTrackID("丁世光", "不散的筵席（I Miss You）", "神經志", "4uLU6hMCjMI75M1A2tKUQC")
	if got := spotifyTrackIDHintFor("丁世光", "不散的筵席"); got != "4uLU6hMCjMI75M1A2tKUQC" {
		t.Errorf("剥过括号的歌名读不到 Spotify 曲目 id 提示: %q", got)
	}
}

// 正在播的这首记在它实际落着的那条上:旧规则那条有、完整歌名那条没有时是旧规则那条。
func TestPlayingEnrichKeyUsesLegacyEntry(t *testing.T) {
	saved := enrichCache
	t.Cleanup(func() { enrichCache = saved })
	enrichCache = map[string]enrichEntry{"丁世光|不散的筵席|神經志": {}}
	if got := playingEnrichKey("丁世光", "不散的筵席（I Miss You）", "神經志"); got != "丁世光|不散的筵席|神經志" {
		t.Errorf("playingEnrichKey = %q", got)
	}
	enrichCache = map[string]enrichEntry{}
	if got := playingEnrichKey("丁世光", "不散的筵席（I Miss You）", "神經志"); got != "丁世光|不散的筵席（I Miss You）|神經志" {
		t.Errorf("没有条目时用完整歌名的 key: %q", got)
	}
}

func TestLyricsDecisionIsPlaying(t *testing.T) {
	d := &lyricsDecision{QueryArtist: "丁世光", QueryTitle: "不散的筵席", QueryAlbum: "神經志"}
	for _, c := range []struct {
		playing string
		want    bool
	}{
		{"丁世光|不散的筵席（I Miss You）|神經志", true},
		{"丁世光|不散的筵席|神經志", true},
		{"丁世光|不散的筵席 (Live)|神經志", false},
		{"丁世光|别的歌|神經志", false},
	} {
		if got := lyricsDecisionIsPlaying(d, c.playing); got != c.want {
			t.Errorf("lyricsDecisionIsPlaying(%q) = %v, want %v", c.playing, got, c.want)
		}
	}
}

// 按「歌手 + 歌名」扫缓存的两处(歌词署名、专辑名)认得完整歌名存着的条目。
func TestPrefixScansFindFullTitleEntries(t *testing.T) {
	saved, savedPath := enrichCache, enrichPath
	t.Cleanup(func() { enrichCache, enrichPath = saved, savedPath })
	enrichPath = "x"
	enrichCache = map[string]enrichEntry{"丁世光|不散的筵席（I Miss You）|神經志": {
		LyricsDecisionApplied: &lyricsDecision{WinnerArtist: "丁世光 Walter"}}}
	if got := enrichAlbumsFor("丁世光", "不散的筵席", 3); !slices.Equal(got, []string{"神經志"}) {
		t.Errorf("enrichAlbumsFor = %v", got)
	}
	if names, pending := enrichLyricsWinnerArtists("丁世光", "不散的筵席"); pending || !slices.Equal(names, []string{"丁世光 Walter"}) {
		t.Errorf("enrichLyricsWinnerArtists = %v, pending %v", names, pending)
	}
}
