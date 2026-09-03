package main

import (
	"testing"
	"time"
)

// 「自动跟进算法升级」这个开关(2026-09-03 用户要求:「控制是否会有自动按照最新版本的算法
// 优化调整歌词的能力;开了就是现状,不开就是一开始选了什么就不会后台自动给换了」)。
//
// 闸门只加在**换掉已有歌词**的两条路径上,这组断言把"该挡的挡住、不该挡的一个都别挡"钉死:
// 关掉之后重打分和升级重搜都不该发生,而首次填充(needsLyricsFirstFill)必须照常 —— 那是
// "这首歌一条歌词都没有",不属于"把用户已经拿到的那份换掉"。
func TestLyricsAutoUpgradeGate(t *testing.T) {
	// 打分版本落后 → 开着时该重打分
	stale := enrichEntry{Lyrics: "[00:01.00]x", LyricsScoringVersion: lyricsScoringVersion - 1}
	if !needsLyricsRescore(stale, false, true) {
		t.Error("开着时:打分版本落后应该触发重打分")
	}
	if needsLyricsRescore(stale, false, false) {
		t.Error("关掉之后:不该再因为打分规则升级换掉已有歌词")
	}

	// 有源当初缺席、且已过节流窗口 → 开着时该升级重搜(构造方式照 lyricsretry_test.go 那组)
	savedFeatures := features
	defer func() { features = savedFeatures }()
	features.LyricsSources = map[string]bool{"netease": true, "qq": true, "lrclib": true}
	long := time.Now().Unix() - int64(lyricsRetryInterval/time.Second) - 1
	missed := enrichEntry{Lyrics: "[00:01.00]x", LyricsSourcesSeen: []string{"lrclib"}, TS: long}
	if !needsLyricsRetry(missed, false, false, true) {
		t.Error("开着时:有源缺席应该触发升级重搜")
	}
	if needsLyricsRetry(missed, false, false, false) {
		t.Error("关掉之后:不该再自动重搜升级已有歌词")
	}

	// ⚠️ 关掉这个开关**不该**连"这首歌一条歌词都没有"也一起挡住 —— 那条是首次填充,
	// 不是"把选好的换掉"。它走的是另一个判据(needsLyricsFirstFill),这里顺手钉一下,
	// 免得以后有人图省事把闸加到那条路径上。
	empty := enrichEntry{Lyrics: "", LyricsSourcesSeen: []string{"lrclib"}}
	if !needsLyricsFirstFill(empty) {
		t.Error("空歌词条目应该照常走首次填充(跟这个开关无关)")
	}

	// 手改过 / 钉过时间轴的,不管开关怎么设都不动(既有保护不能被这次改动削弱)
	manual := enrichEntry{Lyrics: "[00:01.00]x", ManualLyrics: true,
		LyricsScoringVersion: lyricsScoringVersion - 1}
	for _, auto := range []bool{true, false} {
		if needsLyricsRescore(manual, false, auto) {
			t.Errorf("手改过的歌词永远不该被重打分(autoUpgrade=%v)", auto)
		}
		if needsLyricsRetry(manual, false, false, auto) {
			t.Errorf("手改过的歌词永远不该被重搜(autoUpgrade=%v)", auto)
		}
		if needsLyricsRescore(stale, true, auto) {
			t.Errorf("钉过时间轴的永远不该被重打分(autoUpgrade=%v)", auto)
		}
	}
}

// 配置读取:缺字段=开(现状),显式 false 才关。两侧默认值必须一致(Swift 属性初值 true)。
func TestLyricsAutoUpgradeDefaultsOn(t *testing.T) {
	if got := boolOr(nil, true); !got {
		t.Error("缺字段时应当默认开启(跟 Swift 侧 lyricsAutoUpgrade = true 对齐)")
	}
	off := false
	if got := boolOr(&off, true); got {
		t.Error("显式写 false 时应当关闭")
	}
}
