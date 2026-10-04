package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
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
				"id": "100", "name": s.title, "artists": artists,
				"album": map[string]any{"name": s.album}, "duration": s.durationMS,
			},
		})
	}
	body, err := json.Marshal(map[string]any{"list": list})
	if err != nil {
		t.Fatalf("造 JSON: %v", err)
	}
	path := filepath.Join(t.TempDir(), "playingList")
	if err := os.WriteFile(path, body, 0o644); err != nil {
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
