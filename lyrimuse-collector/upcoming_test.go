package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// testSodaQueue 是造测试用队列文件的一条队列。lastPlayed 是"当前停在第几首"的下标,
// -1 表示这条队列没有 lastPlayedKey(还没播过)。
type testSodaQueue struct {
	savedAt    int64
	lastPlayed int
	tracks     []map[string]any
}

// writeTestSodaQueues 造一个带 lastPlayedKey 和唯一 playable key 的 QueueCache。
// 跟 sodalocal_test.go 里那个 writeTestSodaQueue 的区别就在这两样 —— 那个只喂纯音乐判定,
// 不关心顺序和位置,所有 key 都写成同一个值。
func writeTestSodaQueues(t *testing.T, queues map[string]testSodaQueue) string {
	t.Helper()
	file := map[string]any{}
	for name, q := range queues {
		playables := make([]map[string]any, 0, len(q.tracks))
		for i, tr := range q.tracks {
			playables = append(playables, map[string]any{
				"key": fmt.Sprintf("track-%s-%d", name, i), "type": "track", "track": tr,
			})
		}
		entry := map[string]any{
			"version": 2, "savedAt": q.savedAt, "hasMore": true, "playables": playables,
		}
		if q.lastPlayed >= 0 {
			entry["lastPlayedKey"] = fmt.Sprintf("track-%s-%d", name, q.lastPlayed)
		}
		file[name] = entry
	}
	body, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("造 JSON 失败: %v", err)
	}
	var buf bytes.Buffer
	buf.Write(sodaLocalMagic)
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(body); err != nil {
		t.Fatalf("压缩失败: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("关闭 gzip 失败: %v", err)
	}
	dir := filepath.Join(t.TempDir(), "LunaStorage")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("建目录失败: %v", err)
	}
	path := filepath.Join(dir, "QueueCache")
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatalf("写文件失败: %v", err)
	}
	old := sodaLocalQueueOverride
	sodaLocalQueueOverride = path
	t.Cleanup(func() { sodaLocalQueueOverride = old })
	return path
}

func sodaSong(name, artist string) map[string]any {
	return sodaTestTrack(name, artist, "专辑"+name, 200000, 1, 500)
}

func TestSodaUpcomingFollowsLastPlayedKey(t *testing.T) {
	writeTestSodaQueues(t, map[string]testSodaQueue{
		"feed": {savedAt: 100, lastPlayed: 1, tracks: []map[string]any{
			sodaSong("第一首", "甲"), sodaSong("第二首", "乙"),
			sodaSong("第三首", "丙"), sodaSong("第四首", "丁"), sodaSong("第五首", "戊"),
		}},
	})
	got, ok := sodaUpcoming("乙", "第二首", 5)
	if !ok {
		t.Fatalf("当前这首正是 lastPlayedKey 指的那条,该取得到")
	}
	want := []string{"第三首", "第四首", "第五首"}
	if len(got) != len(want) {
		t.Fatalf("取到 %d 首,期望 %d 首(只能往后取,不含当前这首)", len(got), len(want))
	}
	for i, w := range want {
		if got[i].title != w {
			t.Errorf("第 %d 首是 %q,期望 %q —— 顺序必须是队列顺序", i, got[i].title, w)
		}
	}
	if got[0].album != "专辑第三首" {
		t.Errorf("专辑名取错了: %q —— 队列里每首歌的专辑各不相同,不能统一写成当前这首的", got[0].album)
	}
	if got[0].duration != 200 {
		t.Errorf("时长 %v,期望 200 秒(队列里是毫秒)", got[0].duration)
	}
}

func TestSodaUpcomingStopsAtQueueEnd(t *testing.T) {
	// 推荐流的常态:lastPlayedKey 已经很靠后,后面不够 n 首。有几首算几首,不算失败。
	writeTestSodaQueues(t, map[string]testSodaQueue{
		"feed": {savedAt: 100, lastPlayed: 2, tracks: []map[string]any{
			sodaSong("A", "甲"), sodaSong("B", "乙"), sodaSong("C", "丙"), sodaSong("D", "丁"),
		}},
	})
	got, ok := sodaUpcoming("丙", "C", 5)
	if !ok || len(got) != 1 || got[0].title != "D" {
		t.Fatalf("队列末尾只剩 1 首时该返回那 1 首,得到 ok=%v got=%v", ok, got)
	}
}

func TestSodaUpcomingRejectsQueueStoppedOnAnotherTrack(t *testing.T) {
	// 队列文件停在上一次播放 —— 常态,不是异常。必须返回 false 让调用方退回同专辑预取,
	// 而不是把一批根本不会播的歌排进解析队列。
	writeTestSodaQueues(t, map[string]testSodaQueue{
		"feed": {savedAt: 100, lastPlayed: 0, tracks: []map[string]any{
			sodaSong("A", "甲"), sodaSong("B", "乙"), sodaSong("C", "丙"),
		}},
	})
	if got, ok := sodaUpcoming("丁", "别的歌", 5); ok {
		t.Errorf("当前这首不在任何队列的 lastPlayedKey 上,该退回兜底,却返回了 %v", got)
	}
}

func TestSodaUpcomingPicksQueueByCurrentTrackNotSavedAt(t *testing.T) {
	// 文件里同时存着好几条队列。认哪条要靠"lastPlayedKey 指的正是在播的这首",
	// 不能按 savedAt 最大的那条挑 —— 切换听歌模式时另一条的 savedAt 完全可能更新。
	writeTestSodaQueues(t, map[string]testSodaQueue{
		"feed": {savedAt: 999, lastPlayed: 0, tracks: []map[string]any{
			sodaSong("新的", "张三"), sodaSong("不该取到", "李四"),
		}},
		"focus": {savedAt: 1, lastPlayed: 0, tracks: []map[string]any{
			sodaSong("旧的", "王五"), sodaSong("该取到", "赵六"),
		}},
	})
	got, ok := sodaUpcoming("王五", "旧的", 5)
	if !ok || len(got) != 1 || got[0].title != "该取到" {
		t.Fatalf("该认 lastPlayedKey 对得上的那条队列(savedAt 更小),得到 ok=%v got=%v", ok, got)
	}
}

func TestSodaUpcomingJoinsEveryArtist(t *testing.T) {
	// 必须拼全部署名。只取主歌手的话,真播到那首时 MediaRemote 报的是完整串,
	// loosenEnrichKey 折平分隔符之后仍然是两个不同的键,预取好的条目命中不了。
	writeTestSodaQueues(t, map[string]testSodaQueue{
		"feed": {savedAt: 100, lastPlayed: 0, tracks: []map[string]any{
			sodaSong("当前", "甲"),
			sodaTestTrack("合唱", "乙|丙|丁", "某专辑", 180000, 1, 500),
		}},
	})
	got, ok := sodaUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 {
		t.Fatalf("该取到 1 首,得到 ok=%v got=%v", ok, got)
	}
	gotKey := loosenEnrichKey(got[0].artist + "|合唱")
	wantKey := loosenEnrichKey("乙 & 丙 & 丁|合唱")
	if gotKey != wantKey {
		t.Errorf("歌手串 %q 归一后是 %q,跟播放器报的完整串 %q 对不上 —— 预取会白做",
			got[0].artist, gotKey, wantKey)
	}
}

func TestSodaUpcomingMissingLastPlayedKey(t *testing.T) {
	// 队列还没播过(没有 lastPlayedKey):无从判断位置,退回兜底。
	writeTestSodaQueues(t, map[string]testSodaQueue{
		"feed": {savedAt: 100, lastPlayed: -1, tracks: []map[string]any{
			sodaSong("A", "甲"), sodaSong("B", "乙"),
		}},
	})
	if _, ok := sodaUpcoming("甲", "A", 5); ok {
		t.Errorf("没有 lastPlayedKey 时该退回兜底")
	}
}

// 压平那条路(纯音乐判定)不关心顺序和位置,结构改造之后行为必须一个字节都没变。
func TestDecodeSodaLocalQueueStillFlattensEveryQueue(t *testing.T) {
	path := writeTestSodaQueues(t, map[string]testSodaQueue{
		"feed":  {savedAt: 100, lastPlayed: 0, tracks: []map[string]any{sodaSong("A", "甲"), sodaSong("B", "乙")}},
		"focus": {savedAt: 200, lastPlayed: -1, tracks: []map[string]any{sodaSong("C", "丙")}},
	})
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读测试文件: %v", err)
	}
	tracks, err := decodeSodaLocalQueue(raw)
	if err != nil {
		t.Fatalf("解码失败: %v", err)
	}
	if len(tracks) != 3 {
		t.Errorf("压平后 %d 首,期望 3 首(两条队列全都要进来,跟有没有 lastPlayedKey 无关)", len(tracks))
	}
}

// 分发表必须覆盖每一个"拿得到队列"的播放器。漏接一家的表现是它静默退回同专辑预取 ——
// 功能看着还在,只是永远走不到新路径,不会有任何报错。
func TestUpcomingFromQueueCoversEveryPlayerWithAQueue(t *testing.T) {
	// 把五家都指到不存在的路径:要的不是"取得到",而是"分发到了各自的实现、
	// 并且在读不到时老实返回 false"。
	missing := filepath.Join(t.TempDir(), "nope")
	for _, p := range []*string{&sodaLocalQueueOverride, &qqUpcomingOverride, &kugouUpcomingOverride,
		&kugouQueuePlistOverride, &kugouConfigPlistOverride, &kugouLibraryDBOverride, &neteaseUpcomingOverride} {
		old := *p
		*p = missing
		defer func(dst *string, v string) { *dst = v }(p, old)
	}
	for _, bundle := range []string{sodaMusicBundleID, qqMusicBundleID, kugouMusicBundleID, neteaseMusicBundleID} {
		if _, ok := upcomingFromQueue("甲", "乙", "丙", bundle, 0, 5); ok {
			t.Errorf("%s: 队列文件不存在时该返回 false", bundle)
		}
	}
	// Apple Music 走 AppleScript,没有可指的路径,不在这条测试里 —— 它的守卫由
	// TestAppleMusicUpcomingScriptKeepsItsGuards 钉着。
}

// Spotify 拿不到队列是**查实过的结论**,不是还没做:AppleScript 字典里只有单个
// current track,本地落盘只有广告状态和埋点,7768 那个 JSON-RPC 端口要私有二进制帧,
// 官方 Web API 要 OAuth。这条钉住它不会被人"顺手补上"一个猜出来的实现。
// Spotify 分发到自己的实现(spotifyqueue.go),读不到文件时老实返回 false。它的队列在
// PersistentCache/Users/<账号>-user/ 下,不在上一层 Users/ 目录。
func TestUpcomingFromQueueSpotifyAndUnknownPlayers(t *testing.T) {
	old := spotifyISRCUsersDirOverride
	spotifyISRCUsersDirOverride = filepath.Join(t.TempDir(), "nope")
	defer func() { spotifyISRCUsersDirOverride = old }()
	if _, ok := upcomingFromQueue("甲", "乙", "丙", spotifyBundleID, 0, 5); ok {
		t.Errorf("Spotify 的状态文件不存在时该返回 false 退回同专辑预取")
	}
	// 不认识的播放器(信任列表里的第三方 App、浏览器)一律 false。
	if _, ok := upcomingFromQueue("甲", "乙", "丙", "com.example.player", 0, 5); ok {
		t.Errorf("未知播放器该返回 false")
	}
}

func TestPrefetchUpcomingSkipsRepeatOfSameTrack(t *testing.T) {
	// 同一首歌重复触发(暂停恢复、位置校正)不该再排一轮。
	old := lastUpcomingKey
	t.Cleanup(func() {
		upcomingMu.Lock()
		lastUpcomingKey = old
		upcomingMu.Unlock()
	})
	upcomingMu.Lock()
	lastUpcomingKey = ""
	upcomingMu.Unlock()

	// bundle 用未知播放器:分发一定返回 false,不会真的起解析 goroutine,
	// 这条测的是去重那把锁本身。
	prefetchUpcoming("甲", "乙", "丙", "com.example.player", 0)
	upcomingMu.Lock()
	first := lastUpcomingKey
	upcomingMu.Unlock()
	if first == "" {
		t.Fatalf("第一次调用该记下当前这首")
	}
	prefetchUpcoming("甲", "乙", "丙", "com.example.player", 0)
	upcomingMu.Lock()
	again := lastUpcomingKey
	upcomingMu.Unlock()
	if again != first {
		t.Errorf("同一首歌重复触发不该改写去重键")
	}
}
