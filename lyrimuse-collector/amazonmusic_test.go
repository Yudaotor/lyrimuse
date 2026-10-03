package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Amazon Music 放播客(歌手、专辑空)不拿去搜歌词。
func TestAmazonMusicArtistlessNotEnriched(t *testing.T) {
	if got := trackEnrichment("", "Fan Favorite", "", amazonMusicBundleID, 2246, true, false); got != nil {
		t.Errorf("Amazon Music 歌手空的内容不该解析: %v", got)
	}
}

// 信任列表里的 Amazon Music 升级后补进选中集合,并剔出信任列表。
func TestPromoteTrustedAmazonMusic(t *testing.T) {
	trusted := map[string]string{amazonMusicBundleID: "Amazon Music", "com.apple.Safari": "Safari"}
	got := promoteTrustedBuiltins(map[string]bool{playerAppleMusic: true}, trusted)
	if want := map[string]bool{playerAppleMusic: true, playerAmazonMusic: true}; !reflect.DeepEqual(got, want) {
		t.Errorf("没勾自动识别: got %v want %v", got, want)
	}
	if tp := resolveTrustedPlayers(trusted); tp[amazonMusicBundleID] != "" || tp["com.apple.Safari"] != "Safari" {
		t.Errorf("Amazon Music 内置之后剔出信任列表: %v", tp)
	}
}

// 增量读:每次只读新写的行、记住最近一行 updateQueue 与最近一次开播的种类;文件变短从头读;读不到文件什么都不变。
func TestAmazonLogTail(t *testing.T) {
	path := filepath.Join(t.TempDir(), "AmazonMusic.log")
	appendAmazonLog(t, path, amazonTestCQStart, amazonTestQueueLine("asin-//B0TESTAAA1", "asin-//B0TESTAAA2", "asin-//B0TESTAAA3"))
	tail := &amazonLogTail{path: path}
	tail.poll()
	if strings.Join(tail.queue, ",") != "asin://B0TESTAAA1,asin://B0TESTAAA2,asin://B0TESTAAA3" || !tail.cloudQueue {
		t.Fatalf("第一次读: queue=%v cloud=%v", tail.queue, tail.cloudQueue)
	}
	appendAmazonLog(t, path, "260928:025700      Browser INFO in Harley : DT:M [TrackPreFetcher.cpp:74] new track playing : asin://B0TESTAAA2:1:1",
		amazonTestQueueLine("asin-//B0TESTAAA2", "asin-//B0TESTAAA3", "asin-//B0TESTAAA4"))
	tail.poll()
	if strings.Join(tail.queue, ",") != "asin://B0TESTAAA2,asin://B0TESTAAA3,asin://B0TESTAAA4" || !tail.cloudQueue {
		t.Fatalf("追加之后: queue=%v cloud=%v", tail.queue, tail.cloudQueue)
	}
	if err := os.WriteFile(path, []byte(amazonTestPlainStart+"\n"+amazonTestQueueLine("asin-//B0TESTBBB1")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tail.poll()
	if strings.Join(tail.queue, ",") != "asin://B0TESTBBB1" || tail.cloudQueue {
		t.Fatalf("文件变短从头读: queue=%v cloud=%v", tail.queue, tail.cloudQueue)
	}
	// 半行先不认,等换行写完再认。
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	line := amazonTestQueueLine("asin-//B0TESTCCC1", "asin-//B0TESTCCC2")
	f.WriteString(line[:40])
	tail.poll()
	if strings.Join(tail.queue, ",") != "asin://B0TESTBBB1" {
		t.Fatalf("半行不认: %v", tail.queue)
	}
	f.WriteString(line[40:] + "\n")
	f.Close()
	tail.poll()
	if strings.Join(tail.queue, ",") != "asin://B0TESTCCC1,asin://B0TESTCCC2" {
		t.Fatalf("写完那一行再认: %v", tail.queue)
	}
	missing := &amazonLogTail{path: filepath.Join(t.TempDir(), "none.log"), queue: []string{"asin://B0TESTAAA1"}}
	missing.poll()
	if len(missing.queue) != 1 {
		t.Error("读不到文件时什么都不变")
	}
}

// App 报的当前曲目:只记 Amazon Music 的、带曲目标识的;别的一律清空。
func TestNoteAmazonCurrentTrack(t *testing.T) {
	amazonCurrentMu.Lock()
	saved := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	t.Cleanup(func() { amazonCurrentMu.Lock(); amazonCurrentTrack = saved; amazonCurrentMu.Unlock() })
	noteAmazonCurrentTrack(amazonMusicBundleID, "Kane Brown", "Boots", "asin://B0H9LD5H83")
	if amazonTrackURLFor(amazonMusicBundleID, "Kane Brown", "Boots") == "" {
		t.Fatal("Amazon Music 带曲目标识的要记下")
	}
	// 解析那一轮拿到的歌名剥过 ` [Explicit]`,App 报的是原样的。
	noteAmazonCurrentTrack(amazonMusicBundleID, "Morgan Wallen", "Love Somebody [Explicit]", "asin://B0H9LD5H84")
	if amazonTrackURLFor(amazonMusicBundleID, "Morgan Wallen", normEnrichTitle("Love Somebody [Explicit]")) == "" {
		t.Error("歌名两边归一了再比,[Explicit] 不该让它挂不上曲目页")
	}
	if amazonTrackURLFor(amazonMusicBundleID, "Morgan Wallen", "Lies Lies Lies") != "" {
		t.Error("别的歌不能挂上这首的曲目页")
	}
	noteAmazonCurrentTrack(amazonMusicBundleID, "Kane Brown", "Boots", "")
	if amazonTrackURLFor(amazonMusicBundleID, "Kane Brown", "Boots") != "" {
		t.Error("App 没从日志认出这首(标识为空)就清空")
	}
	noteAmazonCurrentTrack(amazonMusicBundleID, "Kane Brown", "Boots", "asin://B0H9LD5H83")
	noteAmazonCurrentTrack(spotifyBundleID, "Kane Brown", "Boots", "asin://B0H9LD5H83")
	if amazonTrackURLFor(amazonMusicBundleID, "Kane Brown", "Boots") != "" {
		t.Error("换到别的播放器就清空")
	}
}

func TestAmazonTrackURL(t *testing.T) {
	if got := amazonTrackURL("asin://B0H9LD5H83"); got != "https://music.amazon.com/tracks/B0H9LD5H83" {
		t.Errorf("ASIN 曲目页: %q", got)
	}
	for _, bad := range []string{"podcast://x/y.mp3", "asin://B0H9LD5H8", "asin://b0h9ld5h83", "asin://B0H9LD5H83X", ""} {
		if got := amazonTrackURL(bad); got != "" {
			t.Errorf("%q 不该给链接: %q", bad, got)
		}
	}
	amazonCurrentMu.Lock()
	saved := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	defer func() { amazonCurrentMu.Lock(); amazonCurrentTrack = saved; amazonCurrentMu.Unlock() }()
	noteAmazonCurrentTrack(amazonMusicBundleID, "Kane Brown", "Boots", "asin://B0H9LD5H83")
	if got := amazonTrackURLFor(amazonMusicBundleID, "Kane Brown", "Boots"); got == "" {
		t.Error("当前这首给曲目页")
	}
	if got := amazonTrackURLFor(amazonMusicBundleID, "Kane Brown", "Other"); got != "" {
		t.Error("不是当前这首不给")
	}
	if got := amazonTrackURLFor(spotifyBundleID, "Kane Brown", "Boots"); got != "" {
		t.Error("别的播放器不给")
	}
}

// 开播后暂停得久,开播行会被推到末尾那段之前:第一次读至少从最后一次开播(连同它前面的 End of stream)读起。
func TestAmazonReplayStart(t *testing.T) {
	start := "260928:122914      Browser INFO in Harley : DT:M [Filter.cpp:157] End of stream reached\n" +
		"260928:122914      Browser INFO in Harley : DT:M [TrackPreFetcher.cpp:74] new track playing : asin://B0TESTAAA1:286:87015\n"
	filler := strings.Repeat("260928:123000      Browser INFO in Harley : DT:M idle while paused\n", 400)
	data := []byte(strings.Repeat("260928:120000 earlier line\n", 200) + start + filler)
	got := amazonReplayStart(data, 1000)
	if !strings.Contains(string(data[got:]), "new track playing") || !strings.Contains(string(data[got:]), "End of stream") {
		t.Fatalf("开播行在末尾那段之前,要往前读到它(连同 End of stream): start=%d", got)
	}
	if got > 0 && data[got-1] != '\n' {
		t.Error("从一行的开头读起")
	}
	recent := []byte(string(data) + start + "260928:130000 after\n")
	if got := amazonReplayStart(recent, 1000); got != len(recent)-1000 {
		t.Errorf("末尾那段里就有开播,照旧只读末尾: %d", got)
	}
	if got := amazonReplayStart([]byte(filler), 1000); got != len(filler)-1000 {
		t.Errorf("整份日志都没有开播,照旧只读末尾: %d", got)
	}
}
