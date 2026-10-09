package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type testNeteaseSong struct {
	title, album string
	artists      []string
	durationMS   int64
	randomOrder  float64 // 0 = 跟数组顺序一致(两种顺序一样,只有随机相关的用例才另给)
}

// writeTestNeteaseQueue 造一份跟真实 playingList 同构的队列文件(明文 JSON,无加密)。
func writeTestNeteaseQueue(t *testing.T, songs []testNeteaseSong) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "playingList")
	if err := os.WriteFile(path, testNeteaseQueueBody(t, songs), 0o644); err != nil {
		t.Fatalf("写测试文件: %v", err)
	}
	old := neteaseUpcomingOverride
	neteaseUpcomingOverride = path
	neteasePlayOrderMu.Lock()
	neteasePlayOrderLast = neteasePlayOrder{}
	neteasePlayOrderMu.Unlock()
	t.Cleanup(func() {
		neteaseUpcomingOverride = old
		neteasePlayOrderMu.Lock()
		neteasePlayOrderLast = neteasePlayOrder{}
		neteasePlayOrderMu.Unlock()
	})
	return path
}

// rewriteTestNeteaseQueue 像客户端那样整份重写同一个文件(「下一首播放」之后),mtime 往后挪一秒。
func rewriteTestNeteaseQueue(t *testing.T, path string, songs []testNeteaseSong) {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatalf("读测试文件: %v", err)
	}
	if err := os.WriteFile(path, testNeteaseQueueBody(t, songs), 0o644); err != nil {
		t.Fatalf("写测试文件: %v", err)
	}
	mod := st.ModTime().Add(time.Second)
	if err := os.Chtimes(path, mod, mod); err != nil {
		t.Fatalf("改 mtime: %v", err)
	}
}

// testNeteaseQueueBody 是队列文件的内容;曲目 id 取歌名,同一首歌在重写前后 id 不变。
func testNeteaseQueueBody(t *testing.T, songs []testNeteaseSong) []byte {
	t.Helper()
	list := make([]map[string]any, 0, len(songs))
	for i, s := range songs {
		artists := make([]map[string]any, 0, len(s.artists))
		for _, a := range s.artists {
			artists = append(artists, map[string]any{"id": "1", "name": a})
		}
		list = append(list, map[string]any{
			"displayOrder": i,
			"randomOrder":  map[bool]float64{true: float64(i + 1), false: s.randomOrder}[s.randomOrder == 0],
			"track": map[string]any{
				"id": s.title, "name": s.title, "artists": artists,
				"album": map[string]any{"name": s.album}, "duration": s.durationMS,
			},
		})
	}
	body, err := json.Marshal(map[string]any{"list": list})
	if err != nil {
		t.Fatalf("造 JSON: %v", err)
	}
	return body
}

func TestNeteaseUpcomingLocatesByCurrentTrack(t *testing.T) {
	writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "第一首", album: "甲专辑", artists: []string{"甲"}, durationMS: 100000},
		{title: "第二首", album: "乙专辑", artists: []string{"乙"}, durationMS: 200000},
		{title: "第三首", album: "丙专辑", artists: []string{"丙"}, durationMS: 295732},
		{title: "第四首", album: "丁专辑", artists: []string{"丁"}, durationMS: 400000},
	})
	got, ok := neteaseUpcoming("乙", "第二首", 5)
	if !ok {
		t.Fatalf("当前这首在队列里,该定位得到")
	}
	if len(got) != 2 || got[0].title != "第三首" || got[1].title != "第四首" {
		t.Fatalf("取到 %+v,期望第三首、第四首", got)
	}
	if got[0].album != "丙专辑" {
		t.Errorf("专辑名 %q —— 队列里每首的专辑各不相同", got[0].album)
	}
	// 这份文件里的 duration 是毫秒,别照搬 QQ 那边(那边的 song_Duration 本来就是秒)。
	if got[0].duration != 295.732 {
		t.Errorf("时长 %v,期望 295.732 秒(文件里是毫秒)", got[0].duration)
	}
}

// 8 首,随机序(randomOrder 从小到大)= 第5首、第2首、第7首、第0首、第3首、第6首、第1首、第4首。
func testNeteaseShuffledSongs() []testNeteaseSong {
	random := []float64{400, 700, 200, 500, 800, 100, 600, 300}
	songs := make([]testNeteaseSong, len(random))
	for i := range songs {
		songs[i] = testNeteaseSong{title: fmt.Sprintf("第%d首", i), album: "专辑", artists: []string{"甲"}, durationMS: 1000, randomOrder: random[i]}
	}
	return songs
}

func neteaseTitles(ts []upcomingTrack) []string {
	out := make([]string, 0, len(ts))
	for _, t := range ts {
		out = append(out, t.title)
	}
	return out
}

// 还没有证据(开播第一首):两种顺序各取 n 首,去重。
func TestNeteaseUpcomingTakesBothOrdersWithoutEvidence(t *testing.T) {
	writeTestNeteaseQueue(t, testNeteaseShuffledSongs())
	got, _ := neteaseUpcoming("甲", "第2首", 2)
	want := []string{"第3首", "第4首", "第7首", "第0首"} // 列表序后两首 + 随机序后两首
	if fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("得到 %v,期望 %v", neteaseTitles(got), want)
	}
}

// 随机播放:下一首正好是随机序里的下一位,之后只按随机序往后取(实测名次 401 → 402 → … 连续加 1)。
func TestNeteaseUpcomingFollowsShuffleOrder(t *testing.T) {
	writeTestNeteaseQueue(t, testNeteaseShuffledSongs())
	neteaseUpcoming("甲", "第5首", 3)
	got, ok := neteaseUpcoming("甲", "第2首", 3) // 随机序 第5首 → 第2首
	if want := []string{"第7首", "第0首", "第3首"}; !ok || fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("得到 ok=%v %v,期望 %v", ok, neteaseTitles(got), want)
	}
	// 用户手动点了一首(两种顺序都不是下一位):沿用随机的结论。
	got, _ = neteaseUpcoming("甲", "第1首", 2)
	if want := []string{"第4首"}; fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("手动跳转后该沿用随机序,得到 %v,期望 %v", neteaseTitles(got), want)
	}
}

// 顺序播放:下一首正好是数组里的下一位,之后只按数组顺序取;随机序的结论可以被它推翻。
func TestNeteaseUpcomingFollowsListOrder(t *testing.T) {
	writeTestNeteaseQueue(t, testNeteaseShuffledSongs())
	neteaseUpcoming("甲", "第5首", 2)
	neteaseUpcoming("甲", "第2首", 2) // 随机
	neteaseUpcoming("甲", "第3首", 2) // 列表序 第2首 → 第3首:切回顺序
	got, _ := neteaseUpcoming("甲", "第4首", 2)
	if want := []string{"第5首", "第6首"}; fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("得到 %v,期望 %v", neteaseTitles(got), want)
	}
}

func TestNeteaseUpcomingRejectsStaleQueue(t *testing.T) {
	writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "旧的", album: "甲", artists: []string{"甲"}, durationMS: 100000},
		{title: "不该取到", album: "乙", artists: []string{"乙"}, durationMS: 200000},
	})
	if got, ok := neteaseUpcoming("丙", "此刻在播的别的歌", 5); ok {
		t.Errorf("反查不到时该退回兜底,却返回了 %+v", got)
	}
}

func TestNeteaseUpcomingJoinsEveryArtist(t *testing.T) {
	writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "当前", album: "甲", artists: []string{"甲"}, durationMS: 100000},
		{title: "合唱", album: "乙", artists: []string{"乙", "丙", "丁"}, durationMS: 200000},
	})
	got, ok := neteaseUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 {
		t.Fatalf("该取到 1 首,得到 ok=%v got=%+v", ok, got)
	}
	if loosenEnrichKey(got[0].artist+"|合唱") != loosenEnrichKey("乙 & 丙 & 丁|合唱") {
		t.Errorf("歌手串 %q 跟播放器报的完整串归一后对不上", got[0].artist)
	}
}

func TestNeteaseUpcomingRejectsOversizedFile(t *testing.T) {
	// 文件异常膨胀时直接不读,别把内存吃光 —— 这是防格式变更/写坏,不是格式约束。
	path := writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "当前", album: "甲", artists: []string{"甲"}, durationMS: 100000},
	})
	big := make([]byte, neteaseUpcomingMaxBytes+1)
	for i := range big {
		big[i] = ' '
	}
	if err := os.WriteFile(path, big, 0o644); err != nil {
		t.Fatalf("写超大文件: %v", err)
	}
	if _, ok := neteaseUpcoming("甲", "当前", 5); ok {
		t.Errorf("超过大小上限时该直接放弃")
	}
}

func TestNeteaseUpcomingMatchesOneOfSeveralArtists(t *testing.T) {
	// 多人合作的歌,系统只报了其中一位:按歌名找到、歌手对得上一位就算当前这首。
	writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "合作", album: "甲", artists: []string{"甲", "乙"}, durationMS: 100000},
		{title: "下一首", album: "丙", artists: []string{"丙"}, durationMS: 200000},
	})
	got, ok := neteaseUpcoming("甲", "合作", 5)
	if want := []string{"下一首"}; !ok || fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("得到 ok=%v %v,期望 %v", ok, neteaseTitles(got), want)
	}
}

func TestNeteaseUpcomingSameTitleOtherArtistIsStale(t *testing.T) {
	// 歌名一样、歌手一位都对不上:是队列停在上一次播放的同名歌,不能当成当前这首。
	writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "当前", album: "乙", artists: []string{"乙"}, durationMS: 100000},
		{title: "不该取到", album: "丙", artists: []string{"丙"}, durationMS: 200000},
	})
	if got, ok := neteaseUpcoming("甲", "当前", 5); ok {
		t.Errorf("歌手对不上时该退回兜底,却返回了 %+v", got)
	}
}

func TestNeteaseUpcomingPrefersExactMatch(t *testing.T) {
	// 整串对得上的那首优先于只对上一位歌手的同名歌,哪怕后者排在前面。
	writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "当前", album: "甲", artists: []string{"甲", "乙"}, durationMS: 100000},
		{title: "当前", album: "甲", artists: []string{"甲"}, durationMS: 100000},
		{title: "之后", album: "丁", artists: []string{"丁"}, durationMS: 200000},
	})
	got, _ := neteaseUpcoming("甲", "当前", 1)
	if want := []string{"之后"}; fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("得到 %v,期望 %v", neteaseTitles(got), want)
	}
}

// 「下一首播放」:客户端把歌插在当前这首后面、整份重写,并把 randomOrder 全部重新随机(实测)。
func testNeteaseInsertedSongs(order []string, random []float64) []testNeteaseSong {
	songs := make([]testNeteaseSong, len(order))
	for i, title := range order {
		songs[i] = testNeteaseSong{title: title, album: "专辑", artists: []string{"甲"}, durationMS: 1000, randomOrder: random[i]}
	}
	return songs
}

// 随机播放中插歌:插进来的歌先放,换到它不推翻随机的结论;它放完接着按随机序从插歌前那首往后数。
func TestNeteaseUpcomingPutsInsertedTracksFirstInShuffle(t *testing.T) {
	path := writeTestNeteaseQueue(t, testNeteaseShuffledSongs())
	neteaseUpcoming("甲", "第5首", 3)
	neteaseUpcoming("甲", "第2首", 3) // 随机序 第5首 → 第2首:随机

	// 在第2首放到一半时插了两首:最新插的那首紧跟当前这首。randomOrder 整份重新随机。
	order := []string{"第0首", "第1首", "第2首", "插B", "插A", "第3首", "第4首", "第5首", "第6首", "第7首"}
	random := []float64{500, 900, 300, 1000, 100, 600, 800, 200, 700, 400}
	rewriteTestNeteaseQueue(t, path, testNeteaseInsertedSongs(order, random))
	got, ok := neteaseUpcoming("甲", "第2首", 3)
	// 插进来的两首在前;随机序(新名次)第2首之后、跳过插进来的:第7首(400)、第0首(500)、第3首(600)。
	if want := []string{"插B", "插A", "第7首", "第0首", "第3首"}; !ok || fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("插歌后得到 ok=%v %v,期望 %v", ok, neteaseTitles(got), want)
	}

	// 换到插进来的第一首:数组上正好是下一位,但不能据此改判成顺序播放。
	got, _ = neteaseUpcoming("甲", "插B", 3)
	if want := []string{"插A", "第7首", "第0首", "第3首"}; fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("放到插进来的歌时得到 %v,期望 %v", neteaseTitles(got), want)
	}
	neteaseUpcoming("甲", "插A", 3)
	// 插进来的放完,回到随机序里第2首的下一位:结论仍是随机,插进来的不再算。
	got, _ = neteaseUpcoming("甲", "第7首", 2)
	if want := []string{"第0首", "第3首"}; fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("插进来的放完后得到 %v,期望 %v", neteaseTitles(got), want)
	}
}

// 顺序播放中插歌(实测):插进来的放完接着放插歌前那首在数组里的下一位。
func TestNeteaseUpcomingInsertedTracksKeepListOrder(t *testing.T) {
	path := writeTestNeteaseQueue(t, testNeteaseShuffledSongs())
	neteaseUpcoming("甲", "第1首", 2)
	neteaseUpcoming("甲", "第2首", 2) // 数组 第1首 → 第2首:顺序
	order := []string{"第0首", "第1首", "第2首", "插A", "第3首", "第4首", "第5首", "第6首", "第7首"}
	random := []float64{500, 900, 300, 100, 600, 800, 200, 700, 400}
	rewriteTestNeteaseQueue(t, path, testNeteaseInsertedSongs(order, random))
	got, _ := neteaseUpcoming("甲", "第2首", 2)
	if want := []string{"插A", "第3首", "第4首"}; fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("得到 %v,期望 %v", neteaseTitles(got), want)
	}
	neteaseUpcoming("甲", "插A", 2)
	got, _ = neteaseUpcoming("甲", "第3首", 2)
	if want := []string{"第4首", "第5首"}; fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("插进来的放完后得到 %v,期望 %v", neteaseTitles(got), want)
	}
}

// 重写后少了曲目(换了一份列表,不是插歌):从头判,不沿用上一份的结论。
func TestNeteaseUpcomingNewListIsNotAnInsertion(t *testing.T) {
	path := writeTestNeteaseQueue(t, testNeteaseShuffledSongs())
	neteaseUpcoming("甲", "第5首", 3)
	neteaseUpcoming("甲", "第2首", 3) // 随机
	order := []string{"第2首", "新甲", "新乙", "新丙"}
	rewriteTestNeteaseQueue(t, path, testNeteaseInsertedSongs(order, []float64{40, 10, 30, 20}))
	got, _ := neteaseUpcoming("甲", "第2首", 3)
	// 没有结论:两种顺序各取,数组里的「新甲」也不算插进来的。
	if want := []string{"新甲", "新乙", "新丙"}; fmt.Sprint(neteaseTitles(got)) != fmt.Sprint(want) {
		t.Fatalf("得到 %v,期望 %v", neteaseTitles(got), want)
	}
}
