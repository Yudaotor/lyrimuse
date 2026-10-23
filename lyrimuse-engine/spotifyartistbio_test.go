package main

import (
	"os"
	"strings"
	"testing"
)

// testSpotifyAny 造 primary.ldb 里的一类值:外层 {1: 版本, 2: Any{type_url, value}}。
func testSpotifyAny(typeName string, value []byte) []byte {
	return pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/"+typeName), pbBytes(2, value))))
}

func TestSpotifyBioText(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"A<br/>B<br>C<BR />D", "A\nB\nC\nD"},
		{`See <a href="spotify:artist:x">Yanzi</a> &amp; friends &#xff0c;好`, "See Yanzi & friends ，好"},
		{"  一 \n\n\n\n 二  ", "一\n\n二"},
		{"<br/><br/>", ""},
		{"", ""},
	} {
		if got := spotifyBioText(c.in); got != c.want {
			t.Errorf("%q → %q, want %q", c.in, got, c.want)
		}
	}
}

// 三处按顺序:metadata.Artist 的 12.1、DetailedEvaluationTrait 的 1、IdentityTrait 的 3;前一处没有字才看后一处。
func TestSpotifyPickArtistBio(t *testing.T) {
	meta := testSpotifyAny("spotify.metadata.Artist", pbMsg(pbStr(2, "Khalil Fong"), pbBytes(12, pbMsg(pbStr(1, "Bio from metadata")))))
	eval := testSpotifyAny("spotify.contentagnostic.v2.DetailedEvaluationTrait", pbMsg(pbStr(1, "Bio<br/>from eval")))
	identity := testSpotifyAny("spotify.contentagnostic.v2.IdentityTrait", pbMsg(pbStr(1, "x"), pbStr(3, "Bio from identity")))
	if got := spotifyPickArtistBio(meta, eval, identity); got != "Bio from metadata" {
		t.Errorf("metadata 那份优先: %q", got)
	}
	if got := spotifyPickArtistBio(nil, eval, identity); got != "Bio\nfrom eval" {
		t.Errorf("没有 metadata 时取 eval: %q", got)
	}
	empty := testSpotifyAny("spotify.metadata.Artist", pbMsg(pbStr(2, "No Bio"), pbBytes(12, pbMsg(pbStr(1, "<br/>")))))
	if got := spotifyPickArtistBio(empty, nil, identity); got != "Bio from identity" {
		t.Errorf("前两处整理完没字时取 identity: %q", got)
	}
	wrongType := testSpotifyAny("spotify.metadata.Track", pbMsg(pbBytes(12, pbMsg(pbStr(1, "not a bio")))))
	if got := spotifyPickArtistBio(wrongType, nil, nil); got != "" {
		t.Errorf("类型不对不认: %q", got)
	}
	if got := spotifyPickArtistBio(nil, nil, nil); got != "" {
		t.Errorf("都没有: %q", got)
	}
}

// 按歌手 ID 在各个账号的 primary.ldb 里找。
func TestSpotifyArtistBioReadsLedger(t *testing.T) {
	root := t.TempDir()
	dir := root + "/acct-user/primary.ldb"
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	const id = "1YrtUPrWcPfgdl9BaD9nhd"
	key := spotifyXmetaKeyURI(spotifyArtistEvalKind, "spotify:artist:"+id)
	testWriteLog(t, dir+"/000003.log", [][]testLDBEntry{
		{{key: string(key), seq: 2, value: string(testSpotifyAny("spotify.contentagnostic.v2.DetailedEvaluationTrait", pbMsg(pbStr(1, "Soul-pop singer."))))}},
	})
	saved := spotifyISRCUsersDirOverride
	spotifyISRCUsersDirOverride = root
	t.Cleanup(func() { spotifyISRCUsersDirOverride = saved })
	if got := spotifyArtistBio(id); got != "Soul-pop singer." {
		t.Errorf("读到: %q", got)
	}
	if got := spotifyArtistBio("2" + id[1:]); got != "" {
		t.Errorf("别的歌手: %q", got)
	}
	if got := spotifyArtistBio(""); got != "" {
		t.Errorf("没有 ID: %q", got)
	}
}

func TestSpotifyArtistBioIsWired(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "if len(os.Args) > 1 && os.Args[1] == \"spotify-artist-bio\" {\n\t\trunSpotifyArtistBioCLI(os.Args[2:])") {
		t.Error("main.go 没接 spotify-artist-bio")
	}
}
