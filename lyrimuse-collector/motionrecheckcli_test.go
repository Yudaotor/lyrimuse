//go:build devtools

package main

import "testing"

// motionCoverAlbumHasKnownVideo 跟 motionCoverWorthBackfill 只差一处,而正是那一处让它
// 敢被拿去扫全表:专辑还没查过时它回 false,所以扫描不会连带发起几千次专辑页抓取。
func TestMotionCoverAlbumHasKnownVideo(t *testing.T) {
	const albumID = "1474635061"
	setMotion := func(mc *motionCover) {
		motionCoverMu.Lock()
		defer motionCoverMu.Unlock()
		if mc == nil {
			delete(motionCoverCache, albumID)
			return
		}
		motionCoverCache[albumID] = *mc
	}
	defer setMotion(nil)

	viaURL := enrichEntry{AppleURL: "https://music.apple.com/cn/album/aim-high/" + albumID + "?i=1"}

	// ① 缓存里确认这张有动画 到 是。
	setMotion(&motionCover{Master: "https://mvod/x.m3u8", Checked: true})
	if !motionCoverAlbumHasKnownVideo(viaURL, "", "查无此歌", "查无此辑") {
		t.Error("缓存里确认这张专辑有动态封面时该回 true")
	}

	// ② 缓存里确认这张没有 到 否。
	setMotion(&motionCover{Checked: true})
	if motionCoverAlbumHasKnownVideo(viaURL, "", "查无此歌", "查无此辑") {
		t.Error(`缓存里"查过了没有"时该回 false`)
	}

	// ③ **还没查过 到 否**。这一条是它跟 motionCoverWorthBackfill 的唯一分歧,也是它存在的
	//    全部理由:那个回 true(该去查),这个回 false(别把它扫进一次性清理)。
	setMotion(nil)
	if motionCoverAlbumHasKnownVideo(viaURL, "", "查无此歌", "查无此辑") {
		t.Error("专辑还没查过时该回 false —— 否则全量扫描会连带抓几千张专辑页")
	}
	if !motionCoverWorthBackfill(viaURL, "", "查无此歌", "查无此辑") {
		t.Error("同一状态下 motionCoverWorthBackfill 该回 true(两者的分歧点)")
	}

	// ④ 两条来路都没有 → 否。
	setMotion(&motionCover{Master: "https://mvod/x.m3u8", Checked: true})
	if motionCoverAlbumHasKnownVideo(enrichEntry{}, "", "查无此歌", "查无此辑") {
		t.Error("既无锚点也无 apple_music_url 时该回 false")
	}
}
