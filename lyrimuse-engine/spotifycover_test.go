package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 形状照搬本机实测:Track 的第 3 个字段是所属专辑,专辑的第 17 个字段是一组封面图,每张 {1: file_id(20 字节),
// 2: 尺寸档, 3: 宽, 4: 高}。合成数据,不读本机真实的 Spotify 缓存。
func testSpotifyTrackWithCover(images ...[]byte) []byte {
	var group []byte
	for _, img := range images {
		group = append(group, pbBytes(1, img)...)
	}
	album := pbMsg(pbBytes(1, make([]byte, 16)), pbStr(2, "专辑"), pbBytes(17, group))
	v := pbMsg(pbStr(2, "某首歌"), pbBytes(3, album), pbVarint(7, 360000))
	return pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Track"), pbBytes(2, v))))
}

func testSpotifyCoverImage(fill byte, size uint64) []byte {
	return pbMsg(pbBytes(1, bytes.Repeat([]byte{fill}, 20)), pbVarint(2, size), pbVarint(3, 600), pbVarint(4, 600))
}

func TestSpotifyParseTrackCoverPrefersDefaultSize(t *testing.T) {
	v := testSpotifyTrackWithCover(testSpotifyCoverImage(0x01, 1), testSpotifyCoverImage(0x02, 0), testSpotifyCoverImage(0x03, 2))
	if got, want := spotifyParseTrackCover(v), spotifyCoverImageBase+strings.Repeat("02", 20); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestSpotifyParseTrackCoverFallsBackToFirst(t *testing.T) {
	v := testSpotifyTrackWithCover(testSpotifyCoverImage(0x01, 1), testSpotifyCoverImage(0x03, 2))
	if got, want := spotifyParseTrackCover(v), spotifyCoverImageBase+strings.Repeat("01", 20); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestSpotifyParseTrackCoverMissing(t *testing.T) {
	if got := spotifyParseTrackCover(testSpotifyTrackWithISRC("USCA20801738")); got != "" {
		t.Fatalf("track without album cover: got %q", got)
	}
	if got := spotifyParseTrackCover(nil); got != "" {
		t.Fatalf("nil value: got %q", got)
	}
	short := testSpotifyTrackWithCover(pbMsg(pbBytes(1, []byte{1, 2, 3}), pbVarint(2, 0)))
	if got := spotifyParseTrackCover(short); got != "" {
		t.Fatalf("file_id not 20 bytes: got %q", got)
	}
}

func TestSpotifyLocalCoverReadsClientCache(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Users")
	dir := filepath.Join(root, "accta-user", "primary.ldb")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	entries := []testLDBEntry{{
		key: string(spotifyXmetaKey(spotifyTrackKind, testSpotifyID1)), seq: 1,
		value: string(testSpotifyTrackWithCover(testSpotifyCoverImage(0x0a, 0))),
	}}
	testWriteTable(t, filepath.Join(dir, "000123.ldb"), entries, 2, true)
	resetSpotifyISRCCache(t, root)
	if got, want := spotifyLocalCover(testSpotifyID1), spotifyCoverImageBase+strings.Repeat("0a", 20); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	if got := spotifyLocalCover(testSpotifyID2); got != "" {
		t.Fatalf("track not in cache: got %q", got)
	}
	if got := spotifyLocalCover("short"); got != "" {
		t.Fatalf("malformed id: got %q", got)
	}
}
