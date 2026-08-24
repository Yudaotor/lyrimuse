package main

import (
	"testing"
	"time"
)

// 2026-08-17 补上的"补空歌词"重试路径。
//
// 背景:resolveTrackEnrichment 里缓存命中之后只可能触发四种后台任务,而 needsLyricsRescore
// 和 needsLyricsRetry **两个的第一行都是 `if e.Lyrics == "" 就 return false`**,另两个只管
// 外围字段和译文 —— 于是"条目已存在但歌词为空"落在所有路径之外,一首歌解析失败过一次就
// **永久卡住**。实测坐实过:修好 `Medley: ` 前缀那个搜索 bug 之后,已经在缓存里的那首歌
// 盯了 48 秒仍然是 0 字。
//
// 这一组用例守两件事:该重试的会重试(而且退避正确),不该重试的一次都不碰。
func TestNeedsLyricsFirstFill(t *testing.T) {
	now := time.Now().Unix()
	day := int64(24 * 3600)

	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{
			name: "空歌词 + 当初解析已超过一天 → 重试",
			e:    enrichEntry{TS: now - day - 60},
			want: true,
		},
		{
			name: "空歌词但刚解析完 → 先别急",
			e:    enrichEntry{TS: now - 60},
			want: false,
		},
		{
			// 这一条是整条路径存在的理由:它以前恒为 false。
			name: "已经有歌词 → 不是这条路径的事(交给升级重试)",
			e:    enrichEntry{TS: now - 30*day, Lyrics: "[00:01.00]x"},
			want: false,
		},
		{
			name: "用户手改过 → 绝不自动重搜",
			e:    enrichEntry{TS: now - 30*day, ManualLyrics: true},
			want: false,
		},
		{
			// 纯音乐是**有依据的结论**,不是"没搜到"这种含糊状态。
			name: "明确判定为纯音乐 → 不重搜",
			e:    enrichEntry{TS: now - 30*day, Instrumental: true},
			want: false,
		},
		{
			name: "退避:已试 1 次,才过 1 天(要 2 天) → 等着",
			e:    enrichEntry{TS: now - 10*day, LyricsFillCount: 1, LyricsFillTS: now - day - 60},
			want: false,
		},
		{
			name: "退避:已试 1 次,过了 2 天 → 重试",
			e:    enrichEntry{TS: now - 10*day, LyricsFillCount: 1, LyricsFillTS: now - 2*day - 60},
			want: true,
		},
		{
			name: "退避封顶:已试 9 次,过了 16 天 → 仍然重试(没有次数上限)",
			e:    enrichEntry{TS: now - 100*day, LyricsFillCount: 9, LyricsFillTS: now - 16*day - 60},
			want: true,
		},
		{
			name: "退避封顶:已试 9 次,只过了 15 天 → 等着",
			e:    enrichEntry{TS: now - 100*day, LyricsFillCount: 9, LyricsFillTS: now - 15*day},
			want: false,
		},
		{
			// TS 比 LyricsFillTS 更晚(条目被重写过)时以更晚的那个为起算点。
			name: "起算点取 TS 和 LyricsFillTS 里更晚的那个",
			e:    enrichEntry{TS: now - 60, LyricsFillCount: 0, LyricsFillTS: now - 10*day},
			want: false,
		},
	}
	for _, c := range cases {
		if got := needsLyricsFirstFill(c.e); got != c.want {
			t.Errorf("%s: needsLyricsFirstFill = %v, want %v", c.name, got, c.want)
		}
	}
}

// 退避是"没有次数上限、但浪费随时间衰减"的关键,单独钉住它的形状。
func TestLyricsFillBackoff(t *testing.T) {
	want := []time.Duration{
		24 * time.Hour,      // 0 次
		48 * time.Hour,      // 1
		96 * time.Hour,      // 2
		8 * 24 * time.Hour,  // 3
		16 * 24 * time.Hour, // 4
		16 * 24 * time.Hour, // 5 起封顶
		16 * 24 * time.Hour, // 99
	}
	counts := []int{0, 1, 2, 3, 4, 5, 99}
	for i, c := range counts {
		if got := lyricsFillBackoff(c); got != want[i] {
			t.Errorf("lyricsFillBackoff(%d) = %v, want %v", c, got, want[i])
		}
	}
}

// ⚠️ 这一条是"白跑一轮网络"的守卫:空歌词条目必须 comparable=true、baseline=0,
// 否则 retryLyricsUpgrade 里 upgraded 恒为 false,搜出来的歌词一个字都写不回去。
func TestLyricsUpgradeBaselineEmptyEntry(t *testing.T) {
	// 空条目:两个字段都是空串、LyricsScoringVersion 是 0,下面两条退路都走不通。
	baseline, comparable := lyricsUpgradeBaseline(enrichEntry{}, nil)
	if baseline != 0 || !comparable {
		t.Errorf("空歌词条目: baseline=%d comparable=%v, want 0/true", baseline, comparable)
	}
	// 有歌词、版本又是当前版本 → 照旧用它自己的分数当基准(不能被上面那一支吃掉)。
	e := enrichEntry{Lyrics: "[00:01.00]x", LyricsScore: 900, LyricsScoringVersion: lyricsScoringVersion}
	if baseline, comparable = lyricsUpgradeBaseline(e, nil); baseline != 900 || !comparable {
		t.Errorf("有歌词同版本: baseline=%d comparable=%v, want 900/true", baseline, comparable)
	}
}
