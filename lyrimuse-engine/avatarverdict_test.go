package main

import (
	"testing"
	"time"
)

// 头像解析结果的四种情形。重点是第一种:两个来源都说「没有」、手上有旧图时留着旧图,不让一次「没有」抹掉好头像。
func TestAvatarVerdict(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	good := avatarCacheEntry{URL: "https://img/old.jpg", TS: now.Add(-30 * 24 * time.Hour).Unix()}
	cases := []struct {
		name       string
		url        string
		definitive bool
		old        avatarCacheEntry
		hasOld     bool
		shown      string
		entry      avatarCacheEntry
		write      bool
	}{
		{"确定没有、有旧图:留旧图、刷新时间", "", true, good, true, good.URL, avatarCacheEntry{URL: good.URL, TS: now.Unix()}, true},
		{"拿到新图", "https://img/new.jpg", false, good, true, "https://img/new.jpg", avatarCacheEntry{URL: "https://img/new.jpg", TS: now.Unix()}, true},
		{"确定没有、没有旧图:记空 14 天", "", true, avatarCacheEntry{}, false, "", avatarCacheEntry{TS: now.Unix()}, true},
		{"暂时故障、有旧图:用旧的、不写", "", false, good, true, good.URL, avatarCacheEntry{}, false},
		{"暂时故障、没旧图:短负缓存", "", false, avatarCacheEntry{}, false, "", avatarCacheEntry{TS: now.Unix(), Transient: true}, true},
	}
	for _, c := range cases {
		shown, entry, write := avatarVerdict(c.url, c.definitive, c.old, c.hasOld, now)
		if shown != c.shown || entry != c.entry || write != c.write {
			t.Errorf("%s: got (%q, %+v, %v)", c.name, shown, entry, write)
		}
	}
}
