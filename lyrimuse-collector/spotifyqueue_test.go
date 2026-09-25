package main

import (
	"encoding/binary"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// ---- 最小的 protobuf 编码,只给测试造数据用 ----

func pbBytes(num int, b []byte) []byte {
	out := binary.AppendUvarint(nil, uint64(num<<3|2))
	out = binary.AppendUvarint(out, uint64(len(b)))
	return append(out, b...)
}

func pbStr(num int, s string) []byte { return pbBytes(num, []byte(s)) }

func pbVarint(num int, v uint64) []byte {
	return binary.AppendUvarint(binary.AppendUvarint(nil, uint64(num<<3)), v)
}

func pbMsg(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// testSpotifyID 造一个合法的 22 位 base62 曲目 id,及对应的 16 字节 gid。
func testSpotifyID(n int) (string, []byte) {
	gid := make([]byte, 16)
	binary.BigEndian.PutUint64(gid[8:], uint64(n)*0x9e3779b97f4a7c15)
	binary.BigEndian.PutUint64(gid[:8], uint64(n)+1)
	return spotifyGIDToID(gid), gid
}

// testUIDWidth:造出来的上下文 uid 位数。歌单 / 专辑上下文是 20 位,电台(自动续播)是 16 位,按歌生成的电台是 22 位。
var testUIDWidth = 20

func testUID(n int) string {
	s := strconv.FormatInt(int64(n), 16)
	for len(s) < testUIDWidth {
		s = "0" + s
	}
	return s
}

// testSpotifyStateShuffled 在 testSpotifyState 基础上加一张打乱表(order 是打乱后的曲目编号顺序)。
// 形状照搬真机:ContextNode 状态里 {2: 总数, 3: {1: .., 2: [{1: 0, 2: uid}...], 3: ..}}。
func testSpotifyStateShuffled(pages [][]int, current int, order []int) []byte {
	base := testSpotifyState(pages, current)
	var items []byte
	for _, n := range order {
		items = append(items, pbBytes(2, pbMsg(pbVarint(1, 0), pbStr(2, testUID(n))))...)
	}
	node := pbMsg(pbStr(1, "spotify.player.proto.ContextNode"),
		pbBytes(2, pbBytes(6, pbBytes(2, pbMsg(pbVarint(2, uint64(len(order))), pbBytes(3, pbMsg(pbStr(1, "abcd"), items, pbStr(3, "efgh"))))))))
	return append(base, pbBytes(18, pbBytes(16, pbBytes(12, pbBytes(1, node))))...)
}

// testSpotifyState 造一份跟真机同构的状态文件:当前曲目(1=uid 2=uri)、上下文(分页,每页若干曲目项
// 1=空 uri 2=uid 3=gid)、播放历史(每条外面包一层带时间戳的消息,一层只有一首)。
func testSpotifyState(pages [][]int, current int) []byte {
	id, _ := testSpotifyID(current)
	cur := pbMsg(pbStr(1, testUID(current)), pbStr(2, "spotify:track:"+id),
		pbBytes(7, pbMsg(pbStr(1, "context_track_index"), pbStr(2, "0"))))
	var ctx []byte
	ctx = append(ctx, pbStr(1, "spotify:playlist:test")...)
	for _, page := range pages {
		var p []byte
		for _, n := range page {
			_, gid := testSpotifyID(n)
			p = append(p, pbBytes(4, pbMsg(pbStr(1, ""), pbStr(2, testUID(n)), pbBytes(3, gid)))...)
		}
		ctx = append(ctx, pbBytes(5, p)...)
	}
	// 历史:当前这首和它前面几首,倒序 —— 形状上也「含当前这首」,但不能被当成队列。
	var hist []byte
	for n := current; n > current-3 && n > 0; n-- {
		_, gid := testSpotifyID(n)
		hist = append(hist, pbBytes(1, pbMsg(pbVarint(1, 1790000000000),
			pbBytes(2, pbMsg(pbStr(1, ""), pbStr(2, testUID(n)), pbBytes(3, gid)))))...)
	}
	root := pbMsg(pbVarint(1, 15), pbStr(2, "kb"),
		pbBytes(3, pbMsg(pbBytes(3, pbMsg(pbBytes(1, pbMsg(pbBytes(3, cur), pbBytes(19, pbBytes(1, ctx)))))))),
		pbBytes(10, hist))
	return append([]byte("1790133051907#"), root...)
}

// testSpotifyIdentity / testSpotifyTrack 造 primary.ldb 里那两类值:外层 {1: 版本, 2: Any{type_url, value}}。
func testSpotifyIdentity(title, album string, artists ...string) []byte {
	v := pbMsg(pbStr(1, "歌曲"), pbStr(2, title), pbBytes(4, pbMsg(pbStr(1, album), pbStr(2, "spotify:album:x"))))
	for _, a := range artists {
		v = append(v, pbBytes(5, pbMsg(pbStr(1, a), pbStr(2, "spotify:artist:x")))...)
	}
	return pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.contentagnostic.v2.IdentityTrait"), pbBytes(2, v))))
}

func testSpotifyTrack(ms int64) []byte {
	zz := uint64(ms<<1) ^ uint64(ms>>63)
	v := pbMsg(pbStr(2, "ignored"), pbVarint(7, zz))
	return pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Track"), pbBytes(2, v))))
}

// testSpotifyEnv 造一个账号目录:状态文件 + primary.ldb。meta 里没有的曲目就不写元数据。
type testSpotifyMeta struct {
	title, album string
	artists      []string
	ms           int64
}

func newTestSpotifyEnv(t *testing.T, state []byte, meta map[int]testSpotifyMeta) {
	t.Helper()
	root := t.TempDir()
	user := filepath.Join(root, "someone-user")
	if err := os.MkdirAll(filepath.Join(user, "primary.ldb"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(user, "context_player_state_restore"), state, 0o644); err != nil {
		t.Fatal(err)
	}
	var entries []testLDBEntry
	seq := uint64(1)
	for n, m := range meta {
		id, _ := testSpotifyID(n)
		entries = append(entries,
			testLDBEntry{key: string(spotifyXmetaKey(spotifyIdentityKind, id)), seq: seq, value: string(testSpotifyIdentity(m.title, m.album, m.artists...))},
			testLDBEntry{key: string(spotifyXmetaKey(spotifyTrackKind, id)), seq: seq + 1, value: string(testSpotifyTrack(m.ms))})
		seq += 2
	}
	if len(entries) > 0 {
		testWriteTable(t, filepath.Join(user, "primary.ldb", "000001.ldb"), entries, 3, true)
	}
	for _, p := range []*string{&spotifyISRCUsersDirOverride} {
		old := *p
		t.Cleanup(func() { *p = old })
	}
	spotifyISRCUsersDirOverride = root
	oldShuffle := spotifyShuffling
	spotifyShuffling = func() (bool, bool) { return false, true }
	t.Cleanup(func() { spotifyShuffling = oldShuffle })
	oldDelays := spotifyStateRetryDelays
	spotifyStateRetryDelays = []time.Duration{0, 0, 0}
	t.Cleanup(func() { spotifyStateRetryDelays = oldDelays })
	spotifyMetaMu.Lock()
	spotifyMetaCache = map[string]spotifyTrackMeta{}
	spotifyMetaMu.Unlock()
	t.Cleanup(func() {
		spotifyMetaMu.Lock()
		spotifyMetaCache = map[string]spotifyTrackMeta{}
		spotifyMetaMu.Unlock()
	})
}

func testSpotifyMetas(nums ...int) map[int]testSpotifyMeta {
	m := map[int]testSpotifyMeta{}
	for _, n := range nums {
		m[n] = testSpotifyMeta{title: "歌" + strconv.Itoa(n), album: "专辑" + strconv.Itoa(n), artists: []string{"甲"}, ms: int64(n) * 1000}
	}
	return m
}

// ---- 测试 ----

func TestSpotifyGIDToIDMatchesRealTrack(t *testing.T) {
	// 真机上的一对:gid 907310581c9141e6b3946c48f6afe1ea ↔ 曲目 4oztIQOTdcZgROLAvdV1tU。
	gid, _ := new(big.Int).SetString("907310581c9141e6b3946c48f6afe1ea", 16)
	if got := spotifyGIDToID(gid.Bytes()); got != "4oztIQOTdcZgROLAvdV1tU" {
		t.Errorf("得到 %s", got)
	}
}

// 分页拼起来往后数;播放历史(也含当前这首)不能被当成队列。
func TestSpotifyUpcomingFromPagedContext(t *testing.T) {
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1, 2, 3}, {4, 5, 6, 7, 8}}, 2), testSpotifyMetas(2, 3, 4, 5, 6, 7, 8))
	got, ok := spotifyUpcoming("甲", "歌2", 5)
	if !ok || len(got) != 5 {
		t.Fatalf("该取到 3..7 五首,得到 ok=%v %+v", ok, got)
	}
	for i, want := range []int{3, 4, 5, 6, 7} {
		if got[i].title != "歌"+strconv.Itoa(want) {
			t.Errorf("第 %d 首是 %q,期望 歌%d(跨页要拼起来)", i, got[i].title, want)
		}
	}
	if got[0] != (upcomingTrack{artist: "甲", title: "歌3", album: "专辑3", duration: 3}) {
		t.Errorf("字段取错: %+v", got[0])
	}
}

// 电台上下文里的 uid 不是 20 位:自动续播进入的 spotify:station:… 是 16 位,歌单放完按一首歌接着放的
// spotify:station:track:… 是 22 位(少认一种,整份状态文件作废、预解析静默失效)。
// 当前这首、分页曲目表、打乱表都要认得出来。
func TestSpotifyUpcomingStationContextShortUID(t *testing.T) {
	t.Cleanup(func() { testUIDWidth = 20 })
	for _, w := range []int{16, 22} {
		testUIDWidth = w
		spotifyShuffling = func() (bool, bool) { return false, true }
		newTestSpotifyEnv(t, testSpotifyState([][]int{{1, 2, 3}, {4, 5, 6, 7, 8}}, 2), testSpotifyMetas(2, 3, 4, 5, 6, 7, 8))
		got, ok := spotifyUpcoming("甲", "歌2", 5)
		if !ok || len(got) != 5 || got[0].title != "歌3" || got[4].title != "歌7" {
			t.Fatalf("%d 位 uid 的上下文该取到 歌3..歌7,得到 ok=%v %+v", w, ok, got)
		}

		newTestSpotifyEnv(t, testSpotifyStateShuffled([][]int{{1, 2, 3}, {4, 5, 6}}, 6, []int{4, 3, 6, 1, 5, 2}), testSpotifyMetas(1, 2, 3, 4, 5, 6))
		spotifyShuffling = func() (bool, bool) { return true, true }
		got, ok = spotifyUpcoming("甲", "歌6", 5)
		if !ok || len(got) != 3 || got[0].title != "歌1" || got[1].title != "歌5" || got[2].title != "歌2" {
			t.Fatalf("%d 位 uid 的打乱表该取 歌1 歌5 歌2,得到 ok=%v %+v", w, ok, got)
		}
	}
}

func TestSpotifyIsContextUID(t *testing.T) {
	for s, want := range map[string]bool{
		"55c1408c5348d584":         true,  // 电台上下文,16 位
		"fd0d416f30878b9c8a94":     true,  // 歌单 / 专辑上下文,20 位
		"5078566d566a46577a586f":   true,  // 按歌生成的电台,22 位(真机取样)
		"5078566d566a46577a586":    false, // 21 位
		"5078566d566a46577a586f00": false, // 24 位
		"55c1408c5348d58":          false, // 15 位
		"fd0d416f30878b9c8a9":      false, // 19 位
		"55c1408c5348d58z":         false, // 不是十六进制
		"q0":                       false, // 播放队列的 uid 另有判定
	} {
		if got := spotifyIsContextUID(s); got != want {
			t.Errorf("spotifyIsContextUID(%q) = %v, want %v", s, got, want)
		}
	}
}

// 多歌手只取第一位 —— Spotify 报给系统的就是第一位。
func TestSpotifyUpcomingUsesFirstArtistOnly(t *testing.T) {
	meta := testSpotifyMetas(1)
	meta[2] = testSpotifyMeta{title: "合唱", album: "某专辑", artists: []string{"Taylor Swift", "Lana Del Rey"}, ms: 256124}
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1, 2}}, 1), meta)
	got, ok := spotifyUpcoming("甲", "歌1", 5)
	if !ok || len(got) != 1 || got[0].artist != "Taylor Swift" || got[0].duration != 256.124 {
		t.Fatalf("得到 ok=%v %+v", ok, got)
	}
}

// 状态文件里的当前这首不是此刻在播的这首(文件停在上一次播放):放弃,不拿一批不会播的歌去占带宽。
func TestSpotifyUpcomingRejectsStaleState(t *testing.T) {
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1, 2, 3}}, 1), testSpotifyMetas(1, 2, 3))
	if got, ok := spotifyUpcoming("乙", "别的歌", 5); ok {
		t.Errorf("名字对不上该放弃,却返回了 %+v", got)
	}
}

// 换歌那一拍 Spotify 还没写好新状态(实测会跟 collector 落在同一秒):重读几次,等它写好再取。
func TestSpotifyUpcomingRetriesUntilStateCatchesUp(t *testing.T) {
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1, 2, 3}}, 1), testSpotifyMetas(1, 2, 3))
	path := filepath.Join(spotifyActiveUserDir(), "context_player_state_restore")
	oldSleep := spotifySleep
	t.Cleanup(func() { spotifySleep = oldSleep })

	// 第一次读到的还是上一首(歌1);第一次「等待」时 Spotify 写好了新状态(歌2)。
	waits := 0
	spotifySleep = func(time.Duration) {
		waits++
		if err := os.WriteFile(path, testSpotifyState([][]int{{1, 2, 3}}, 2), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got, ok := spotifyUpcoming("甲", "歌2", 5)
	if !ok || len(got) != 1 || got[0].title != "歌3" {
		t.Fatalf("状态文件追上来之后该取到歌3,得到 ok=%v %+v", ok, got)
	}
	if waits != 1 {
		t.Errorf("该只等一次,实际等了 %d 次", waits)
	}

	// 一直追不上:重试次数用完就放弃,不无限等。
	waits = 0
	spotifySleep = func(time.Duration) { waits++ }
	if got, ok := spotifyUpcoming("甲", "一直没写进来的歌", 5); ok {
		t.Errorf("一直对不上该放弃,却返回了 %+v", got)
	}
	if waits != len(spotifyStateRetryDelays) {
		t.Errorf("该等满 %d 次再放弃,实际 %d 次", len(spotifyStateRetryDelays), waits)
	}
}

// 有换曲时记下的曲目 id 就只认它,名字对得上也不行。
func TestSpotifyUpcomingPrefersTrackIDHint(t *testing.T) {
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1, 2, 3}}, 1), testSpotifyMetas(1, 2, 3))
	enrichMu.Lock()
	old := spotifyTrackIDHints
	spotifyTrackIDHints = map[string]string{enrichKey("甲", "歌1", "专辑1"): "0000000000000000000000"}
	enrichMu.Unlock()
	t.Cleanup(func() { enrichMu.Lock(); spotifyTrackIDHints = old; enrichMu.Unlock() })
	if got, ok := spotifyUpcoming("甲", "歌1", 5); ok {
		t.Errorf("曲目 id 对不上该放弃,却返回了 %+v", got)
	}
	id, _ := testSpotifyID(1)
	enrichMu.Lock()
	spotifyTrackIDHints = map[string]string{enrichKey("甲", "歌1", "专辑1"): id}
	enrichMu.Unlock()
	if _, ok := spotifyUpcoming("甲", "歌1", 5); !ok {
		t.Errorf("曲目 id 对得上该取到")
	}
}

// 开着随机但状态文件里没有打乱表:放弃,不拿原始顺序冒充;问不到随机状态也放弃(拿不准就不猜)。
func TestSpotifyUpcomingShuffleFallsBack(t *testing.T) {
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1, 2, 3}}, 1), testSpotifyMetas(1, 2, 3))
	for _, s := range []struct{ on, ok bool }{{true, true}, {false, false}} {
		spotifyShuffling = func() (bool, bool) { return s.on, s.ok }
		if got, ok := spotifyUpcoming("甲", "歌1", 5); ok {
			t.Errorf("shuffle on=%v ok=%v 不该取,却返回了 %+v", s.on, s.ok, got)
		}
	}
}

// 开着随机:按打乱表往后数,不是按上下文原始顺序(实测两者完全不同,见 spotifyqueue.go 头注「随机播放」)。
func TestSpotifyUpcomingFollowsShuffleOrder(t *testing.T) {
	// 原始顺序 1..6,打乱后 4 3 6 1 5 2,当前是 6(打乱表第 3 位)→ 接下来 1 5 2。
	newTestSpotifyEnv(t, testSpotifyStateShuffled([][]int{{1, 2, 3}, {4, 5, 6}}, 6, []int{4, 3, 6, 1, 5, 2}), testSpotifyMetas(1, 2, 3, 4, 5, 6))
	spotifyShuffling = func() (bool, bool) { return true, true }
	got, ok := spotifyUpcoming("甲", "歌6", 5)
	if !ok || len(got) != 3 || got[0].title != "歌1" || got[1].title != "歌5" || got[2].title != "歌2" {
		t.Fatalf("随机时该按打乱表取 歌1 歌5 歌2,得到 ok=%v %+v", ok, got)
	}
	// 关着随机:同一份状态文件按原始顺序取(当前 6 是最后一首,后面没有了)。
	spotifyShuffling = func() (bool, bool) { return false, true }
	if got, ok := spotifyUpcoming("甲", "歌6", 5); ok {
		t.Errorf("关着随机时 6 是原始顺序的最后一首,不该有下一首,却返回了 %+v", got)
	}
	spotifyShuffling = func() (bool, bool) { return false, true }
	if got, ok := spotifyUpcoming("甲", "歌4", 5); ok && got[0].title != "歌5" {
		t.Errorf("关着随机时 4 的下一首该是原始顺序的 歌5,得到 %+v", got)
	}
}

// 打乱表里混着上下文以外的 uid(不是这个上下文的表)、或不含当前这首:不采用。
func TestSpotifyShuffleOrderMustMatchContext(t *testing.T) {
	for name, order := range map[string][]int{
		"混进别的 uid": {3, 1, 99, 2},
		"不含当前这首":   {3, 2},
	} {
		newTestSpotifyEnv(t, testSpotifyStateShuffled([][]int{{1, 2, 3}}, 1, order), testSpotifyMetas(1, 2, 3))
		spotifyShuffling = func() (bool, bool) { return true, true }
		if got, ok := spotifyUpcoming("甲", "歌1", 5); ok {
			t.Errorf("%s: 不该采用这张打乱表,却返回了 %+v", name, got)
		}
	}
}

// testSpotifyStateQueued 造「正在放播放队列里的歌」这种状态,照搬真机形状:
//   - 当前这首:{1: "q0", 2: uri};
//   - 播放队列:一个带 "queue" 字符串字段的消息,下面每项 {2: "qN", 3: gid},正在放的那首也还在里面;
//   - 播放历史:插队前最后一首上下文曲目(lastCtx),以及正在放的 q0 本身(历史里也会有 q0 这条)。
//
// queue 是队列里的曲目编号(第一个就是正在放的);order 非空时再挂一张打乱表。
func testSpotifyStateQueued(pages [][]int, queue []int, lastCtx int, order []int) []byte {
	curID, _ := testSpotifyID(queue[0])
	cur := pbMsg(pbStr(1, "q0"), pbStr(2, "spotify:track:"+curID))
	var ctx []byte
	ctx = append(ctx, pbStr(1, "spotify:playlist:test")...)
	for _, page := range pages {
		var p []byte
		for _, n := range page {
			_, gid := testSpotifyID(n)
			p = append(p, pbBytes(4, pbMsg(pbStr(1, ""), pbStr(2, testUID(n)), pbBytes(3, gid)))...)
		}
		ctx = append(ctx, pbBytes(5, p)...)
	}
	var items []byte
	for i, n := range queue {
		_, gid := testSpotifyID(n)
		items = append(items, pbBytes(1, pbMsg(pbStr(1, ""), pbStr(2, "q"+strconv.Itoa(i)), pbBytes(3, gid)))...)
	}
	queueNode := pbMsg(pbStr(1, "spotify.player.proto.PlayQueueNode"), pbBytes(2, pbBytes(2, pbMsg(items, pbVarint(2, 7708966845135407562), pbStr(6, "queue")))))
	_, lastGID := testSpotifyID(lastCtx)
	_, curGID := testSpotifyID(queue[0])
	hist := pbMsg(
		pbBytes(1, pbMsg(pbVarint(1, 1790000000000), pbBytes(2, pbMsg(pbStr(1, ""), pbStr(2, testUID(lastCtx)), pbBytes(3, lastGID))))),
		pbBytes(1, pbMsg(pbVarint(1, 1790000100000), pbBytes(2, pbMsg(pbStr(1, ""), pbStr(2, "q0"), pbBytes(3, curGID))))))
	nodes := pbBytes(1, queueNode)
	if len(order) > 0 {
		var o []byte
		for _, n := range order {
			o = append(o, pbBytes(2, pbMsg(pbVarint(1, 0), pbStr(2, testUID(n))))...)
		}
		shuffleState := pbMsg(pbVarint(2, uint64(len(order))), pbBytes(3, pbMsg(pbStr(1, "abcd"), o, pbStr(3, "efgh"))))
		ctxNode := pbMsg(pbStr(1, "spotify.player.proto.ContextNode"), pbBytes(2, pbBytes(6, pbBytes(2, shuffleState))))
		nodes = append(nodes, pbBytes(1, ctxNode)...)
	}
	root := pbMsg(pbVarint(1, 15), pbStr(2, "kb"),
		pbBytes(3, pbMsg(pbBytes(3, pbMsg(pbBytes(1, pbMsg(pbBytes(3, cur), pbBytes(18, pbBytes(16, pbBytes(12, nodes))), pbBytes(19, pbBytes(1, ctx)))))))),
		pbBytes(10, hist))
	return append([]byte("1790133051907#"), root...)
}

// 正在放队列里的歌:先放队列里剩下的,再从插队前停下的位置接着放上下文。
func TestSpotifyUpcomingWhilePlayingQueuedTrack(t *testing.T) {
	// 上下文 1..6,插队前放到 3;队列 [90(正在放), 91];接下来 = 91, 然后 4 5 6。
	newTestSpotifyEnv(t, testSpotifyStateQueued([][]int{{1, 2, 3, 4, 5, 6}}, []int{90, 91}, 3, nil), testSpotifyMetas(1, 2, 3, 4, 5, 6, 90, 91))
	got, ok := spotifyUpcoming("甲", "歌90", 5)
	if !ok || len(got) != 4 {
		t.Fatalf("该取到 歌91 歌4 歌5 歌6,得到 ok=%v %+v", ok, got)
	}
	for i, want := range []string{"歌91", "歌4", "歌5", "歌6"} {
		if got[i].title != want {
			t.Errorf("第 %d 首是 %q,期望 %q", i, got[i].title, want)
		}
	}
}

// 同上,但开着随机:上下文按打乱表从插队前那首之后接着数。
func TestSpotifyUpcomingQueuedTrackWithShuffle(t *testing.T) {
	// 打乱表 5 2 6 1 3 4,插队前停在 6 → 接下来 = 队列里的 91,然后 1 3 4。
	newTestSpotifyEnv(t, testSpotifyStateQueued([][]int{{1, 2, 3, 4, 5, 6}}, []int{90, 91}, 6, []int{5, 2, 6, 1, 3, 4}), testSpotifyMetas(1, 2, 3, 4, 5, 6, 90, 91))
	spotifyShuffling = func() (bool, bool) { return true, true }
	got, ok := spotifyUpcoming("甲", "歌90", 5)
	if !ok || len(got) != 4 || got[0].title != "歌91" || got[1].title != "歌1" || got[2].title != "歌3" || got[3].title != "歌4" {
		t.Fatalf("该取到 歌91 歌1 歌3 歌4,得到 ok=%v %+v", ok, got)
	}
}

// 队列里只剩正在放的这一首(实测形态):接下来就是上下文从插队前那首之后接着放。
func TestSpotifyUpcomingLastQueuedTrack(t *testing.T) {
	newTestSpotifyEnv(t, testSpotifyStateQueued([][]int{{1, 2, 3, 4}}, []int{90}, 2, nil), testSpotifyMetas(1, 2, 3, 4, 90))
	got, ok := spotifyUpcoming("甲", "歌90", 5)
	if !ok || len(got) != 2 || got[0].title != "歌3" || got[1].title != "歌4" {
		t.Fatalf("该取到 歌3 歌4,得到 ok=%v %+v", ok, got)
	}
}

// 正在放上下文里的歌、队列里还有歌:队列先放。
func TestSpotifyUpcomingQueueBeforeContext(t *testing.T) {
	st, err := spotifyParseState(testSpotifyStateQueued([][]int{{1, 2, 3}}, []int{90, 91}, 1, nil))
	if err != nil {
		t.Fatal(err)
	}
	if len(st.queue) != 2 || st.queue[0].uid != "q0" || st.queue[1].uid != "q1" {
		t.Fatalf("队列该认出 q0 q1 两项,得到 %+v", st.queue)
	}
	// 播放历史里也有 uid 为 q0 的那条 —— 它不能被当成队列,也不能被当成「最近一首上下文曲目」。
	if st.lastCtxUID != testUID(1) {
		t.Errorf("最近一首上下文曲目该是 1,得到 %q", st.lastCtxUID)
	}
}

// 本地没有元数据的那首跳过,不拿空名字去猜。
func TestSpotifyUpcomingSkipsTracksWithoutMetadata(t *testing.T) {
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1, 2, 3, 4}}, 1), testSpotifyMetas(1, 2, 4))
	got, ok := spotifyUpcoming("甲", "歌1", 5)
	if !ok || len(got) != 2 || got[0].title != "歌2" || got[1].title != "歌4" {
		t.Fatalf("该取到歌2、歌4,得到 ok=%v %+v", ok, got)
	}
}

// 歌单里同一首歌出现两次:按 uid 定位,认得出是哪一次。
func TestSpotifyLocateCurrentByUID(t *testing.T) {
	a, _ := testSpotifyID(1)
	tracks := []spotifyCtxTrack{{uid: testUID(10), id: a}, {uid: testUID(11), id: "b"}, {uid: testUID(12), id: a}}
	if got := spotifyLocateCurrent(tracks, spotifyCurrent{uid: testUID(12), id: a}); got != 2 {
		t.Errorf("按 uid 该定位到第二次出现(下标 2),得到 %d", got)
	}
	if got := spotifyLocateCurrent(tracks, spotifyCurrent{uid: "对不上", id: a}); got != 0 {
		t.Errorf("uid 对不上时退回比 id,得到 %d", got)
	}
}

// 格式不认识(没有时间戳前缀 / 不是 protobuf / 找不到当前这首)一律报错,调用方退回第二层。
func TestSpotifyParseStateRejectsGarbage(t *testing.T) {
	for _, raw := range [][]byte{
		[]byte("没有前缀"),
		[]byte("12x#abc"),
		append([]byte("1790133051907#"), 0xff, 0xff, 0xff),
		append([]byte("1790133051907#"), pbStr(1, "只有一个字段")...),
	} {
		if _, err := spotifyParseState(raw); err == nil {
			t.Errorf("%q 该报错", raw)
		}
	}
}

func TestSpotifyXmetaKeyShape(t *testing.T) {
	// 真机 key:`!xmeta#cache#` + 01 d2 + `#` + 长度前缀(0x24 = 36 = "spotify:track:" 14 + 22)+ uri + `#`
	got := spotifyXmetaKey(spotifyIdentityKind, "1wtOxkiel43cVs0Yux5Q4h")
	want := "!xmeta#cache#\x01\xd2#$spotify:track:1wtOxkiel43cVs0Yux5Q4h#"
	if string(got) != want {
		t.Errorf("得到 %q\n期望 %q", got, want)
	}
}
