package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 用户手动校准过时间轴的歌，两条「自动重选歌词源」的路径都必须放手 —— 换一份歌词就等于
// 把人家一句句听出来的校正值静默作废（校正值的 key 里含歌词内容指纹，见 lyricspins.go）。
func TestPinBlocksAutomaticLyricsReselection(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })

	// 版本落后 → 不 pin 该重选。
	stale := enrichEntry{Lyrics: "x", LyricsScoringVersion: lyricsScoringVersion - 1}
	if !needsLyricsRescore(stale, false) {
		t.Fatal("前提不成立：版本落后的条目本来就该重选，测试用例失效")
	}
	if needsLyricsRescore(stale, true) {
		t.Error("已校准的条目不该被 rescore 换掉歌词")
	}

	// 同源当初落选 → 不 pin 该重试。这一条尤其要紧：它是刻意越过「已经有逐字就不重试」
	// 那道闸的，pin 要是排在那两条后面就会被一起越过。
	savedNative := nativeLyricSource
	t.Cleanup(func() { nativeLyricSource = savedNative })
	nativeLyricSource = "qq"
	missed := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou", "qq"},
	}
	if !needsLyricsRetry(missed, 0, false) {
		t.Fatal("前提不成立：同源落选的条目本来就该重试，测试用例失效")
	}
	if needsLyricsRetry(missed, 0, true) {
		t.Error("已校准的条目不该被 retry 换掉歌词（哪怕是同源落选这条越闸路径）")
	}

	// 时长对不上那条同样是越闸路径，一并覆盖。
	nativeLyricSource = ""
	wrongDur := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", ResolvedDurationSecs: 300,
	}
	if !needsLyricsRetry(wrongDur, 200, false) {
		t.Fatal("前提不成立：时长差 33% 本来就该重试，测试用例失效")
	}
	if needsLyricsRetry(wrongDur, 200, true) {
		t.Error("已校准的条目不该被「时长对不上」这条路径换掉歌词")
	}

	// 「压根还没有歌词」那条路径**不**受 pin 影响：没有歌词就没有校正值要保护，
	// 挡住它只会让这首歌永远填不上词。
	empty := enrichEntry{}
	if !needsLyricsFirstFill(empty) {
		t.Fatal("前提不成立：空歌词条目本来就该首次填充，测试用例失效")
	}
}

// pin 名单必须按 mtime 自己重读，不能只在启动时读一次 —— 用户刚在菜单栏按了几下「提前」
// 的那首歌，如果要等 collector 重启才受保护，那正好错过最需要它的一刻。
func TestLyricsPinnedRereadsWhenFileChanges(t *testing.T) {
	savedPath := lyricsPinsPath
	t.Cleanup(func() {
		lyricsPinsPath = savedPath
		lyricsPins, lyricsPinsRead, lyricsPinsSize = nil, false, 0
		lyricsPinsMTime = time.Time{}
	})

	path := filepath.Join(t.TempDir(), "pins.json")
	lyricsPinsPath = path
	lyricsPins, lyricsPinsRead, lyricsPinsSize = nil, false, 0
	lyricsPinsMTime = time.Time{}

	// 文件还不存在（从没校准过任何一首）：正常状态，不是错误。
	if lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("文件不存在时不该判成已校准")
	}

	write := func(body string, when time.Time) {
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatalf("写 pin 文件失败: %v", err)
		}
		// mtime 显式钉一个值，别让「同一秒内连写两次」这种时间分辨率问题决定测试成败。
		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatalf("改 mtime 失败: %v", err)
		}
	}

	base := time.Now().Add(-time.Hour)
	write(`{"version":1,"pins":{"周杰伦|退后|依然范特西":1787200000}}`, base)
	if !lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("文件里有这个 key，该判成已校准")
	}
	if lyricsPinned("周杰伦|心雨|叶惠美") {
		t.Error("文件里没有的 key 不该判成已校准")
	}

	// 用户把校正值清成 0 → App 把这条从名单里去掉 → 这边**不重启**也要立刻跟上。
	write(`{"version":1,"pins":{}}`, base.Add(time.Minute))
	if lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("文件已经改过（key 被去掉），该按新内容判定")
	}

	// 内容坏了一律当「没有任何 pin」，不能沿用上一次的内存态 —— 否则「清空」这个动作
	// 在坏文件下永久不生效。
	write(`{"version":1,"pins":{"周杰伦|退后|依然范特西":1}}`, base.Add(2*time.Minute))
	if !lyricsPinned("周杰伦|退后|依然范特西") {
		t.Fatal("前提不成立：这一步该读到 pin")
	}
	write(`{ 这不是 JSON`, base.Add(3*time.Minute))
	if lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("文件解析失败时该当作空名单，而不是沿用上一次读到的内容")
	}

	// 路径没设置（一次性 CLI 子命令走的分支）时一切都是空操作。
	lyricsPinsPath = ""
	if lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("lyricsPinsPath 为空时不该判成已校准")
	}
}
