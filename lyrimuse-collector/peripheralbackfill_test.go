package main

import (
	"testing"
	"time"
)

// needsPeripheralBackfill 的回归测试。
//
// 两条都是 2026-08-07 补上的:
//   - canonical_artist 之前不在触发条件里,而它在 backfillPeripheralFields 里本来就有补全
//     分支 —— 于是那四个字段一旦齐了,缺 canonical 的记录就再也没机会补。实测撞到过:同一张
//     专辑里一半曲目报 "Leah Dou"、一半报"窦靖童",后者其中两条 canonical 是空的。
//   - 以前只有 10 分钟节流、没有次数上限,真的补不上的字段会让这条记录只要还在被播放就
//     每 10 分钟重发一轮网络请求,永远停不下来。
func TestNeedsPeripheralBackfill(t *testing.T) {
	long := time.Now().Unix() - int64(enrichPeripheralRetryInterval/time.Second) - 1
	full := enrichEntry{
		AccentColor: "#fff", AppleURL: "a", QQURL: "q", NeteaseURL: "n",
		CanonicalArtist: "窦靖童", TS: long,
	}

	cases := []struct {
		name   string
		e      enrichEntry
		artist string
		want   bool
	}{
		{"什么都不缺:不补", full, "窦靖童", false},
		{"缺主色:补", func() enrichEntry { e := full; e.AccentColor = ""; return e }(), "窦靖童", true},
		{"缺网易云链接:补", func() enrichEntry { e := full; e.NeteaseURL = ""; return e }(), "窦靖童", true},
		{
			name:   "单一歌手缺 canonical:补(这条以前会被漏掉)",
			e:      func() enrichEntry { e := full; e.CanonicalArtist = ""; return e }(),
			artist: "窦靖童", want: true,
		},
		{
			name:   "合唱曲目缺 canonical:不补 —— collector 只在单一歌手时才给值,空是正常的",
			e:      func() enrichEntry { e := full; e.CanonicalArtist = ""; return e }(),
			artist: "窦靖童 & Lionman", want: false,
		},
		{
			name:   "还没到节流窗口:不补",
			e:      func() enrichEntry { e := full; e.AccentColor = ""; e.TS = time.Now().Unix(); return e }(),
			artist: "窦靖童", want: false,
		},
		{
			name: "重试次数用尽:不补(以前没有这道闸,会无限重试)",
			e: func() enrichEntry {
				e := full
				e.AccentColor = ""
				e.PeripheralRetryCount = peripheralBackfillMaxAttempts
				return e
			}(),
			artist: "窦靖童", want: false,
		},
		{
			name: "差一次到上限:还补",
			e: func() enrichEntry {
				e := full
				e.AccentColor = ""
				e.PeripheralRetryCount = peripheralBackfillMaxAttempts - 1
				return e
			}(),
			artist: "窦靖童", want: true,
		},
	}
	for _, c := range cases {
		if got := needsPeripheralBackfill(c.e, c.artist, ""); got != c.want {
			t.Errorf("%s: needsPeripheralBackfill = %v, want %v", c.name, got, c.want)
		}
	}
}

// 外围补全的节流时间戳必须**跟条目的解析时刻分开**。
//
// 2026-08-09 拆分之前两者共用 e.TS:backfillPeripheralFields 每跑一次就把它推到当下
// (最多 5 次、每次隔 10 分钟),而 needsLyricsRetry 的 6 小时起算点正是 e.TS —— 于是
// 补个封面主色就能把"去别的源再搜一遍歌词"整体往后拖近一小时。两件事本来毫无关系。
func TestPeripheralThrottleDoesNotDelayLyricsRetry(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.LyricsSources = map[string]bool{"netease": true, "kugou": true}

	// 一条 6 小时前解析出来的记录,当时只有网易云给了候选 —— 酷狗没出现过,该重搜。
	longAgo := time.Now().Unix() - int64(lyricsRetryInterval/time.Second) - 1
	e := enrichEntry{
		Lyrics:            "[00:01.00]hello",
		LyricsSourcesSeen: []string{"netease"},
		TS:                longAgo,
	}
	if !needsLyricsRetry(e, false, false) {
		t.Fatal("间隔已过、又确实缺源,本来就该重搜")
	}

	// 外围补全刚跑过一次(只推它自己的时间戳)。歌词重搜不该因此被推迟。
	e.PeripheralTS = time.Now().Unix()
	e.PeripheralRetryCount++
	if !needsLyricsRetry(e, false, false) {
		t.Error("补了一次外围字段就把歌词重搜挡掉了 —— 两个节流又耦合回去了")
	}
	// 而外围补全自己的节流要照常生效。
	if needsPeripheralBackfill(e, "someone", "") {
		t.Error("外围补全刚跑过,10 分钟内不该再来")
	}
}
