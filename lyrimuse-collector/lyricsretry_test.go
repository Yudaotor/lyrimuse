package main

import (
	"testing"
	"time"
)

// needsLyricsRetry 的回归测试。
//
// 背景(2026-08-07 实测复现):五源搜索有 20 秒总上限,到点没回来的源这一轮不参与候选,而
// 网易云既是最慢的、也最可能带逐字歌词。同一首「悟空 2003 Demo」连查两次:一次 3 秒返回、
// 候选里根本没有网易云,lrclib 以 83 分胜出;另一次跑满 20 秒,网易云回来了、525 分带逐字。
// 缓存又是"解析一次永久保留",于是那一瞬间的运气被永久固化。这个函数就是那道补救闸门,
// 它的判定条件比较绕(五个 and 关系),所以逐条钉死。
func TestNeedsLyricsRetry(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.LyricsSources = map[string]bool{"netease": true, "qq": true, "lrclib": true}

	long, recent := time.Now().Unix()-int64(lyricsRetryInterval/time.Second)-1, time.Now().Unix()

	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{
			name: "有源缺席且已过节流窗口:该重试",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: long},
			want: true,
		},
		{
			name: "所有启用的源都露过面:货真价实赢的,不折腾",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"netease", "qq", "lrclib"}, TS: long},
			want: false,
		},
		{
			name: "已经有逐字歌词:最值钱的东西已到手,没什么可升级的",
			e:    enrichEntry{Lyrics: "x", LyricsYRC: "y", LyricsSourcesSeen: []string{"lrclib"}, TS: long},
			want: false,
		},
		{
			name: "还没到节流窗口:同一首歌反复播放时不能每次都重搜",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: recent},
			want: false,
		},
		{
			name: "重试次数用尽:缺席的源可能真的没这首歌,必须有硬上限",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: long, LyricsRetryCount: lyricsRetryMaxAttempts},
			want: false,
		},
		{
			name: "压根没有歌词:交给首次解析那条路,不走这里",
			e:    enrichEntry{LyricsSourcesSeen: []string{"lrclib"}, TS: long},
			want: false,
		},
		{
			name: "老条目(没有 LyricsSourcesSeen):当初正是在没有这层保护时定的,给一次机会",
			e:    enrichEntry{Lyrics: "x", TS: long},
			want: true,
		},
		{
			name: "节流基准取 TS 和 LyricsRetryTS 里更晚的那个:刚重试过就不该又符合条件",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: long, LyricsRetryTS: recent},
			want: false,
		},
	}
	for _, c := range cases {
		if got := needsLyricsRetry(c.e, 0, false); got != c.want {
			t.Errorf("%s: needsLyricsRetry = %v, want %v", c.name, got, c.want)
		}
	}

}

// 未启用的源缺席不算数——只有**已启用**的源缺席才说明这次决定是在信息不全的情况下做的。
func TestNeedsLyricsRetryIgnoresDisabledSources(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.LyricsSources = map[string]bool{"lrclib": true, "netease": false}
	long := time.Now().Unix() - int64(lyricsRetryInterval/time.Second) - 1

	e := enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: long}
	if needsLyricsRetry(e, 0, false) {
		t.Error("只有被禁用的 netease 缺席,不该触发重试")
	}
}

func TestLyricSourcesWithCandidates(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "lrclib", Score: 83},
		{Source: "netease", Score: 525},
		{Source: "lrclib", Score: 12},                         // 同一个源多条候选,只记一次
		{Source: "musixmatch", Score: -1, Instrumental: true}, // 负分是"纯音乐"搭车标记,不算候选
	}
	got := lyricSourcesWithCandidates(scored)
	want := []string{"lrclib", "netease"}
	if len(got) != len(want) {
		t.Fatalf("lyricSourcesWithCandidates = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("lyricSourcesWithCandidates = %v, want %v", got, want)
		}
	}
}
