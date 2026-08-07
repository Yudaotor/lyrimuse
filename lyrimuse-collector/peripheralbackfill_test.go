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
		if got := needsPeripheralBackfill(c.e, c.artist); got != c.want {
			t.Errorf("%s: needsPeripheralBackfill = %v, want %v", c.name, got, c.want)
		}
	}
}
