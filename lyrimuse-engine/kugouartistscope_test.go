package main

import "testing"

// 本地弱证据判定过的这一首,之后几拍(署名没再变)也不能升级成播放器级结论。
func TestKugouLocalEvidenceStaysScopedAcrossTicks(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))

	for tick := 1; tick <= 3; tick++ {
		got, ok := kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195)
		if !ok || got != "Stake" {
			t.Fatalf("第 %d 拍: (%q, %v),这一首应当按本地那份纠正", tick, got, ok)
		}
		if kugouArtistPoisonConfirmed {
			t.Fatalf("第 %d 拍就把整个播放器坐实了 —— 本地那份只管这一首", tick)
		}
	}
	if a, ok := kugouFixedArtist(kugouMusicBundleID, "另一首歌", "某位歌手", 200); ok {
		t.Errorf("换歌后凭空纠正成了 %q", a)
	}
}

// 弱证据判过之后,同一首里署名真的变了:这才是结构证据,照样升级。
func TestKugouStructuralEvidenceAfterLocalEvidenceStillConfirms(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))

	kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195)
	kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195)
	if kugouArtistPoisonConfirmed {
		t.Fatal("前提:署名没变之前不坐实")
	}
	kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "下一句歌词", 195)
	if !kugouArtistPoisonConfirmed {
		t.Error("同一首里署名变了,应当升级成播放器级结论")
	}
}

// 状态机本身:本地弱证据不写 structural,署名变化和换歌时的已坐实才写。
func TestAdvanceKugouLyricArtistStructuralFlag(t *testing.T) {
	s := advanceKugouLyricArtist(kugouLyricArtistState{}, kugouMusicBundleID, "歌", "甲", 200, false)
	if s.structural || s.poisoned {
		t.Fatalf("第一拍: %+v", s)
	}
	s.poisoned = true // 模拟本地弱证据
	s = advanceKugouLyricArtist(s, kugouMusicBundleID, "歌", "甲", 200, false)
	if !s.poisoned || s.structural {
		t.Fatalf("弱证据带到下一拍不能变成结构证据: %+v", s)
	}
	s = advanceKugouLyricArtist(s, kugouMusicBundleID, "歌", "乙", 200, false)
	if !s.structural {
		t.Fatalf("署名变了应当记结构证据: %+v", s)
	}
	s = advanceKugouLyricArtist(s, kugouMusicBundleID, "下一首", "丙", 180, true)
	if !s.structural || !s.poisoned {
		t.Fatalf("已坐实的播放器换歌时两位都该带上: %+v", s)
	}
}
