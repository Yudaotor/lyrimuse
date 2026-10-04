package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// 专辑页应答的形状(照真机《Westside Whimsy》专辑页摘的):头部艺人一段链接;多位艺人那一行只有第一位是链接,
// 中间夹着界面语言的连接词;有的专辑页艺人那一列空着。
const ytmAlbumBrowse = `{"header":{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Westside Whimsy"}]},` +
	`"straplineTextOne":{"runs":[{"text":"Jhené Aiko","navigationEndpoint":{"browseEndpoint":{"browseId":"UCZONOh3FvcDpTcsnDRsr7OQ"}}}]}}},` +
	`"contents":{"musicShelfRenderer":{"contents":[` +
	`{"musicResponsiveListItemRenderer":{"flexColumns":[` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Ghost"}]}}},` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Jhené Aiko"}]}}}],` +
	`"fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"2:04"}]}}}],` +
	`"playlistItemData":{"videoId":"m4t6YeTJFfY"}}},` +
	`{"musicResponsiveListItemRenderer":{"flexColumns":[` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Love Bomb"}]}}},` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Jhené Aiko"},{"text":"和"},{"text":"Ab-Soul"}]}}}],` +
	`"fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"2:32"}]}}}],` +
	`"playlistItemData":{"videoId":"iKWPxiflnyg"}}},` +
	`{"musicResponsiveListItemRenderer":{"flexColumns":[` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Wild Cat(s)"}]}}},` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{}}}],` +
	`"fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"1:07"}]}}}],` +
	`"playlistItemData":{"videoId":"sor9KQwW9-o"}}},` +
	`{"musicResponsiveListItemRenderer":{"flexColumns":[` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Interlude"}]}}},` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Jhené Aiko"},{"text":"和"},{"text":"Big Sean"}]}}}],` +
	`"fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"0:58"}]}}}],` +
	`"playlistItemData":{"videoId":"xYz123AbC45"}}},` +
	`{"musicResponsiveListItemRenderer":{"flexColumns":[` +
	`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"No Video"}]}}}]}}` +
	`]}}}`

func TestYTMusicAlbumRowsFromBrowse(t *testing.T) {
	got := ytmusicAlbumRowsFromBrowse([]byte(ytmAlbumBrowse))
	want := []ytmusicAlbumRow{
		{title: "Ghost", artist: "Jhené Aiko", singleArtist: true, duration: 124, videoID: "m4t6YeTJFfY"},
		{title: "Love Bomb", artist: "Jhené Aiko和Ab-Soul", duration: 152, videoID: "iKWPxiflnyg"},
		{title: "Wild Cat(s)", artist: "Jhené Aiko", singleArtist: true, duration: 67, videoID: "sor9KQwW9-o"},
		{title: "Interlude", artist: "Jhené Aiko和Big Sean", duration: 58, videoID: "xYz123AbC45"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("专辑页的行:\n got %+v\nwant %+v", got, want)
	}
	if ytmusicAlbumRowsFromBrowse([]byte("not json")) != nil {
		t.Error("不是 JSON 不出行")
	}
}

// 署名:跟当前这首写法一样的用当前这首的(App 整理过的);一位艺人的原样;别的多位艺人跳过。
func TestKasetAlbumSiblingTracks(t *testing.T) {
	rows := ytmusicAlbumRowsFromBrowse([]byte(ytmAlbumBrowse))
	// 正在放《Love Bomb》的 MV,队列里配的音轨版本是专辑页上那一行。
	got := kasetAlbumSiblingTracks(rows, "mQLzR5V2Z9c", "iKWPxiflnyg", "Jhené Aiko, Ab-Soul")
	want := []albumTrack{
		{title: "Ghost", artist: "Jhené Aiko", duration: 124},
		{title: "Love Bomb", artist: "Jhené Aiko, Ab-Soul", duration: 152},
		{title: "Wild Cat(s)", artist: "Jhené Aiko", duration: 67},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("挑出的曲目:\n got %+v\nwant %+v", got, want)
	}
	// 正在放《Ghost》:同一位艺人那几行用当前这首的署名写法;多位艺人的行都跳过。
	ghost := kasetAlbumSiblingTracks(rows, "m4t6YeTJFfY", "m4t6YeTJFfY", "Jhené Aiko")
	if len(ghost) != 2 || ghost[0].artist != "Jhené Aiko" || ghost[1].title != "Wild Cat(s)" {
		t.Errorf("当前这首是单个艺人: %+v", ghost)
	}
	// 当前这首不在专辑页上:只要单个艺人的行。
	if other := kasetAlbumSiblingTracks(rows, "nope", "nope", "Someone"); len(other) != 2 {
		t.Errorf("认不出当前这首: %+v", other)
	}
}

// 接线:Kaset 读不到队列时走专辑页那条,键里不带专辑。
func TestKasetAlbumPrefetchWired(t *testing.T) {
	b, err := os.ReadFile("albumprefetch.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, want := range []string{
		"if bundleID == kasetBundleID {\n\t\tgo prefetchKasetAlbumSiblings(currentArtist, currentTitle)",
		"prefetchAlbumTracks(album, tracks, currentArtist, currentTitle, album)",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("albumprefetch.go 缺 %q", want)
		}
	}
	k, err := os.ReadFile("kasetalbumprefetch.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(k), `prefetchAlbumTracks(verdict.album, tracks, currentArtist, currentTitle, "")`) {
		t.Error("Kaset 的同专辑预取要按 Kaset 的口径(键里不带专辑)排")
	}
}
