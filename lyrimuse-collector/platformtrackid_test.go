package main

import (
	"os"
	"strings"
	"testing"
)

// 播放侧记下的 Apple / Spotify 曲目 ID,要能按 enrichKey 原样读回来。
func TestPlaybackTrackIDHintRoundTrip(t *testing.T) {
	resetPlaybackTrackIDHints()

	notePlayingAppleCatalogID("ATEEZ", "BAD", "GOLDEN HOUR : Part.5 - EP", 1010728767)
	notePlayingSpotifyTrackID("ATEEZ", "BAD", "GOLDEN HOUR : Part.5 - EP", "4cOdK2wGLETKBW3PvgPWqT")

	apple, spotify := playbackTrackIDsFor("ATEEZ", "BAD", "GOLDEN HOUR : Part.5 - EP")
	if apple != "1010728767" {
		t.Errorf("Apple 目录 ID 读回来是 %q,想要 %q", apple, "1010728767")
	}
	if spotify != "4cOdK2wGLETKBW3PvgPWqT" {
		t.Errorf("Spotify 曲目 ID 读回来是 %q", spotify)
	}

	// 两个 ID 互不覆盖:后写的那个不能把先写的抹掉。
	notePlayingAppleCatalogID("ATEEZ", "BAD", "GOLDEN HOUR : Part.5 - EP", 6780313808)
	apple, spotify = playbackTrackIDsFor("ATEEZ", "BAD", "GOLDEN HOUR : Part.5 - EP")
	if apple != "6780313808" || spotify != "4cOdK2wGLETKBW3PvgPWqT" {
		t.Errorf("改写 Apple ID 之后成了 (%q, %q),Spotify 那个不该动", apple, spotify)
	}

	// 没记过的歌给两个空串,不是上一首的残留。
	if a, s := playbackTrackIDsFor("别人", "别的歌", ""); a != "" || s != "" {
		t.Errorf("没记过的歌读到了 (%q, %q)", a, s)
	}
}

// 本地导入文件的 UniqueIdentifier 是任意 64 位持久 ID(可以是负数),不是目录 ID ——
// 记进去的话最坏会撞上某个真实目录 ID、把别人的歌词安到这首歌上。
func TestPlaybackTrackIDHintRejectsNonCatalogID(t *testing.T) {
	resetPlaybackTrackIDHints()

	for _, id := range []int64{0, -1, -3446272063698972557} {
		notePlayingAppleCatalogID("A", "T", "AL", id)
		if a, _ := playbackTrackIDsFor("A", "T", "AL"); a != "" {
			t.Errorf("trackID=%d 不该被记下,却读到 %q", id, a)
		}
	}
	// 空曲名同理:enrichKey 在这种输入上不构成一条能对上的身份。
	notePlayingAppleCatalogID("A", "", "AL", 123)
	if a, _ := playbackTrackIDsFor("A", "", "AL"); a != "" {
		t.Errorf("空曲名不该被记下,却读到 %q", a)
	}
}

// 别名轮 / 拆分身份轮拿改写过的署名来问,必须落空 —— 提示说的是"系统报的这一条录音",
// 换了身份就不再对应同一条,宁可不给也不能给错(见 platformtrackid.go 头注)。
func TestPlaybackTrackIDHintMissesOnRewrittenIdentity(t *testing.T) {
	resetPlaybackTrackIDHints()
	notePlayingAppleCatalogID("王子", "Why You Wanna Treat Me So Bad?", "", 1010728767)

	if a, _ := playbackTrackIDsFor("Prince", "Why You Wanna Treat Me So Bad?", ""); a != "" {
		t.Errorf("别名轮的署名不该命中提示,却读到 %q", a)
	}
	if a, _ := playbackTrackIDsFor("王子", "Why You Wanna Treat Me So Bad?", ""); a == "" {
		t.Error("原署名应该照旧命中")
	}
}

// amll 的取用顺序是按「这个 ID 有多可信」排的,不是按索引全不全排:apple / spotify 是系统
// 播放时直接给的,ncm / qq 是搜出来的。顺序错了会先拿到同名的另一版录音。
func TestAMLLTryOrderPutsExactIDsFirst(t *testing.T) {
	src, err := os.ReadFile("amllttml.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	pos := map[string]int{}
	for _, dir := range []string{"am-lyrics", "spotify-lyrics", "ncm-lyrics", "qq-lyrics"} {
		i := strings.Index(s, `{"`+dir+`"`)
		if i < 0 {
			t.Fatalf("amllttml.go 的 try 列表里没有 %q", dir)
		}
		pos[dir] = i
	}
	if pos["am-lyrics"] > pos["ncm-lyrics"] || pos["spotify-lyrics"] > pos["ncm-lyrics"] {
		t.Error("am-lyrics / spotify-lyrics 必须排在 ncm-lyrics 之前(精确 ID 优先)")
	}
	if pos["ncm-lyrics"] > pos["qq-lyrics"] {
		t.Error("ncm-lyrics 仍应排在 qq-lyrics 之前(那份索引更全)")
	}
	// 四个 ID 全空才算"没法查",少一个都不算 —— 否则 amll 会在还有路可走时就报跳过。
	if !strings.Contains(s, `neteaseID == "" && qqID == "" && appleCatalogID == "" && spotifyTrackID == ""`) {
		t.Error("amllLyric 的跳过判据没有覆盖全部四个 ID")
	}
}

func resetPlaybackTrackIDHints() {
	playbackTrackIDMu.Lock()
	defer playbackTrackIDMu.Unlock()
	playbackTrackIDHints = map[string]playbackTrackIDs{}
}
