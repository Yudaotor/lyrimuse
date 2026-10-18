package main

import (
	"encoding/json"
	"os"
	"testing"
)

// 正在播的那首换到时长变体:「正在播」挪到变体上,单条快照当场改写成变体那一条;不是正在播的那首碰到变体不动「正在播」。
func TestPlayingKeyFollowsDurationVariant(t *testing.T) {
	base := enrichKey("Prince", "Strange Relationship", "Sign O' The Times")
	variant := enrichKeyDurationVariant(base, 2)
	entries := func() map[string]enrichEntry {
		return map[string]enrichEntry{
			base: {DurationSecs: 241, Lyrics: "[00:21.39]album cut", LyricsSource: "soda", LyricsScore: 1271,
				LyricsDecisionApplied: &lyricsDecision{Path: lyricsDecisionPathFirstResolve, Winner: "soda"}},
			variant: {DurationSecs: 401.7, Lyrics: "[01:00.10]extended", LyricsSource: "soda", LyricsScore: 1197,
				LyricsDecisionApplied: &lyricsDecision{Path: lyricsDecisionPathFirstResolve, Winner: "soda"}},
		}
	}
	origPlaying := enrichPlayingKey.Load()
	t.Cleanup(func() { enrichPlayingKey.Store(origPlaying) })
	snapshot := func(t *testing.T) playingEntryFile {
		t.Helper()
		b, err := os.ReadFile(playingEntryPath())
		if err != nil {
			t.Fatal(err)
		}
		var f playingEntryFile
		if err := json.Unmarshal(b, &f); err != nil {
			t.Fatal(err)
		}
		return f
	}

	t.Run("正在播的那首", func(t *testing.T) {
		setUpEnrichEditTest(t, entries())
		enrichPlayingKey.Store(nil)
		noteEnrichPlayingKey(base)
		if f := snapshot(t); f.Key != base {
			t.Fatalf("换歌那一拍按基条目写快照: %q", f.Key)
		}
		if trackEnrichment("Prince", "Strange Relationship", "Sign O' The Times", "", 401.7, false, false) == nil {
			t.Fatal("变体已有条目:当场返回")
		}
		if cur := enrichPlayingKey.Load(); cur == nil || *cur != variant {
			t.Fatalf("「正在播」该挪到变体上: %v", cur)
		}
		if f := snapshot(t); f.Key != variant || f.Entry.Lyrics != "[01:00.10]extended" {
			t.Fatalf("单条快照该改写成变体那一条: %q %q", f.Key, f.Entry.Lyrics)
		}
		// 下一拍照样按基条目的三段进来:留在变体上,提交变体照写快照。
		trackEnrichment("Prince", "Strange Relationship", "Sign O' The Times", "", 401.7, false, false)
		if !isEnrichPlayingKey(variant) || !notePlayingEntryChanged(variant) {
			t.Fatal("下一拍「正在播」该还在变体上")
		}
	})

	t.Run("不是正在播的那首", func(t *testing.T) {
		setUpEnrichEditTest(t, entries())
		enrichPlayingKey.Store(nil)
		const other = "x|now|y"
		noteEnrichPlayingKey(other)
		trackEnrichment("Prince", "Strange Relationship", "Sign O' The Times", "", 401.7, false, false)
		if !isEnrichPlayingKey(other) {
			t.Fatalf("上一首碰到变体不该动「正在播」: %v", *enrichPlayingKey.Load())
		}
	})

	// 变体还没有条目、这一拍新起首次解析时,早上屏的目标也得是变体(earlyLyricsTargetPlaying 拿它跟「正在播」比)。
	// 那条要联网,单测跑不了,钉源码。
	t.Run("早上屏目标跟着挪", func(t *testing.T) {
		data, err := os.ReadFile("enrich.go")
		if err != nil {
			t.Fatal(err)
		}
		if !containsCode(string(data), "if isEnrichPlayingKey(rk) {\n\tplayKey = rk\n}\nkey, e, ok = rk, re, rok") {
			t.Error("trackEnrichment 换到变体时 playKey 要跟着挪")
		}
	})
}
