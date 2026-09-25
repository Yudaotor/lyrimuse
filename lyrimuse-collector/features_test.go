package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

// 启动快照。它的价值全在"覆盖得全不全"上:漏掉一个开关,那一项造成的行为差异事后就
// 查不出来了 —— 所以这里逐字段核对,新增开关忘了加进快照会在这里红。
func TestLogFeatureSnapshot(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })

	setFeatures(featureFlags{
		Players:                   map[string]bool{"qq": true, "applemusic": true},
		LyricsSources:             map[string]bool{"kugou": true, "netease": true, "deezer": false},
		LyricsSourceMode:          "score",
		LyricsSourceOrder:         []string{"kugou", "qq"},
		LyricsDir:                 "/somewhere/custom",
		LyricsTranslationLanguage: "zh",
		LastfmMatchMode:           "smart",
		LastfmMatchArtist:         true,
		LastfmMatchTrack:          true,
		LastfmScrobblePoint:       "half",
		AlbumPrefetch:             true,
		LyricsDecisionTrace:       true,
		TrustedPlayers:            map[string]string{"com.google.Chrome": "Chrome"},
		LastfmExcludedBundles:     map[string]bool{"com.apple.Safari": true},
	})
	logFeatureSnapshot()
	out := buf.String()

	for _, want := range []string{
		// 集合要按稳定顺序输出,不然两次启动的日志没法直接 diff。
		"players=applemusic,qq",
		// 关掉的源不该出现在"启用了哪些"里 —— "少一个源"正是要靠这一项回答。
		"lyrics_sources=kugou,netease",
		"lyrics_source_mode=score",
		"lyrics_source_order=kugou,qq",
		// 路径本身是用户的目录结构,跟排查无关,只记有没有自定义过。
		"lyrics_dir=custom",
		"lyrics_translation_language=zh",
		"lastfm_match_mode=smart",
		// 档位摊平后的三个布尔也要在快照里 —— 排查时「界面选了什么」和「实际按什么办」
		// 是两件事,只记档位的话自定义档看不出它到底开了哪几项。
		"lastfm_match_artist=true",
		"lastfm_match_track=true",
		"lastfm_match_first_artist_only=false",
		"album_prefetch=true",
		"lyrics_decision_trace=true",
		"trusted_players=com.google.Chrome",
		"lastfm_excluded_bundles=1",
		// nil 集合 = 布尔年代的老配置,跟"一个都不选"含义不同,不能都印成空。
		"launch_on_players=legacy",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("启动快照缺 %s,实际: %q", want, out)
		}
	}
	if strings.Contains(out, "/somewhere/custom") {
		t.Errorf("快照里不该出现歌词目录的真实路径: %q", out)
	}

	// 空值要写成 "-",不能留空 —— key= 后面什么都没有,读的人分不清是"空"还是字段丢了。
	buf.Reset()
	setFeatures(featureFlags{LaunchLyrimuseOnPlayers: map[string]bool{}})
	logFeatureSnapshot()
	out = buf.String()
	for _, want := range []string{"players=-", "lyrics_sources=-", "lyrics_source_mode=-", "launch_on_players=-"} {
		if !strings.Contains(out, want) {
			t.Errorf("空值该记成 -,缺 %s,实际: %q", want, out)
		}
	}
}
