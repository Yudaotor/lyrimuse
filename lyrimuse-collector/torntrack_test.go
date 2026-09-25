package main

import (
	"testing"
	"time"
)

// 形态取自缓存里留下的幽灵条目:标题已是下一首,歌手/专辑/时长还是上一首(见 09 章决策 69)。
var tornPrev = snapshot{Title: "I Like It (Ballad Version)", Artist: "David Tao", Album: "乐之路", Duration: 189.666666, Bundle: spotifyBundleID}

func TestTornTrackChange(t *testing.T) {
	torn := tornPrev
	torn.Title = "What Is Love"
	if !tornTrackChange(tornPrev, torn) {
		t.Fatal("只换了标题应判为撕裂")
	}
	settled := snapshot{Title: "What Is Love", Artist: "Khalil Fong", Album: "梦想家 The Dreamer", Duration: 250.1, Bundle: spotifyBundleID}
	sameAlbumNext := snapshot{Title: "All for Joy", Artist: "David Tao", Album: "乐之路", Duration: 258.4, Bundle: spotifyBundleID}
	radio := torn
	radio.Radio = true
	otherPlayer := torn
	otherPlayer.Bundle = appleMusicBundleID
	for name, next := range map[string]snapshot{
		"正常换曲":        settled,
		"同专辑下一首时长已更新": sameAlbumNext,
		"同一首":         tornPrev,
		"电台":          radio,
		"换了播放器":       otherPlayer,
	} {
		if tornTrackChange(tornPrev, next) {
			t.Errorf("%s: 不该判为撕裂", name)
		}
	}
	if tornTrackChange(snapshot{}, torn) {
		t.Error("没有上一首时不该判为撕裂")
	}
}

func TestHoldTornTrackChange(t *testing.T) {
	t0 := time.Unix(1788110875, 0)
	torn := tornPrev
	torn.Title = "What Is Love"

	p := &poller{cur: tornPrev}
	if !p.holdTornTrackChange(torn, t0) {
		t.Fatal("第一次见到撕裂快照应按住")
	}
	if !p.holdTornTrackChange(torn, t0.Add(5*time.Second)) {
		t.Fatal("撕裂持续两拍仍应按住")
	}
	settled := snapshot{Title: "What Is Love", Artist: "Khalil Fong", Album: "梦想家 The Dreamer", Duration: 250.1, Bundle: spotifyBundleID}
	if p.holdTornTrackChange(settled, t0.Add(10*time.Second)) {
		t.Fatal("字段跟上来后应立即放行")
	}
	if p.tornHoldKey != "" {
		t.Fatal("放行后应清掉按住状态")
	}

	p = &poller{cur: tornPrev}
	p.holdTornTrackChange(torn, t0)
	if !p.holdTornTrackChange(torn, t0.Add(tornHoldMax-time.Second)) {
		t.Fatal("未满 tornHoldMax 应继续按住")
	}
	if p.holdTornTrackChange(torn, t0.Add(tornHoldMax)) {
		t.Fatal("满 tornHoldMax 应放行")
	}

	p = &poller{cur: tornPrev}
	if p.holdTornTrackChange(settled, t0) {
		t.Fatal("正常换曲不该按住")
	}
}
