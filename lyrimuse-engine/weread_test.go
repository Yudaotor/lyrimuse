package main

import "testing"

// 微信读书听书:字幕由 App 从系统会话收(PlayerSubtitles),引擎不搜歌词、整段按有声内容处理。
func TestWeReadSubtitlesSkipLyricsAndCountAsSpoken(t *testing.T) {
	if got := trackEnrichment("雪国", "16 雪国 第16集", "雪国", weReadBundleID, 362, true, false); got != nil {
		t.Fatalf("微信读书这一集不该去搜歌词,trackEnrichment 返回了 %v", got)
	}
	if !playerMarksSpoken(snapshot{Bundle: weReadBundleID, Artist: "雪国", Title: "16 雪国 第16集", Album: "雪国"}) {
		t.Fatal("微信读书放的整段都是有声内容,playerMarksSpoken 应为 true")
	}
	if playerMarksSpoken(snapshot{Bundle: appleMusicBundleID, Artist: "周杰倫", Title: "青花瓷", Album: "我很忙"}) {
		t.Fatal("别家的歌不该被当成有声内容")
	}
	if len(playerSubtitlesInArtist) != 1 || !playerSubtitlesInArtist[weReadBundleID] {
		t.Fatalf("歌手栏装字幕的只该有微信读书,现在是 %v", playerSubtitlesInArtist)
	}
}
