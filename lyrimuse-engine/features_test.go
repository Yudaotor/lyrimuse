package main

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"strings"
	"testing"
	"time"
)

// 启动快照。它的价值全在"覆盖得全不全"上:漏掉一个开关,那一项造成的行为差异事后就
// 查不出来了 —— 所以这里逐字段核对,新增开关忘了加进快照会在这里红。
func TestLogFeatureSnapshot(t *testing.T) {
	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
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
		LaunchLyrimuseOnPlayers:   map[string]bool{"qq_music": true},
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
		"launch_on_players=qq_music",
		// 同理:没有配对键 = 所有浏览器都探,跟「一个都没配」不同。
		"browser_platform_pairs=legacy",
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

// 跟上一次整行打的一样、不到一天:只打指纹,带上次整行打的时刻;开关变了、或上一次整行打已过一天,照常整行打。
func TestLogFeatureSnapshotSkipsUnchanged(t *testing.T) {
	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	full := func() bool {
		t.Helper()
		out := buf.String()
		buf.Reset()
		if strings.Contains(out, "feature flags unchanged") {
			if !strings.Contains(out, "fingerprint=") || !strings.Contains(out, "logged_in_full_at=") {
				t.Errorf("只打指纹那行要带指纹和上次整行打的时刻: %q", out)
			}
			return false
		}
		if !strings.Contains(out, "players=") {
			t.Fatalf("既不是整行也不是指纹: %q", out)
		}
		return true
	}

	setFeatures(featureFlags{Players: map[string]bool{"qq": true}})
	logFeatureSnapshot()
	if !full() {
		t.Error("第一次整行打")
	}
	logFeatureSnapshot()
	if full() {
		t.Error("没变、不到一天:只打指纹")
	}
	setFeatures(featureFlags{Players: map[string]bool{"qq": true, "spotify": true}})
	logFeatureSnapshot()
	if !full() {
		t.Error("开关变了:整行打")
	}

	path := cacheFilePath(featureSnapshotStateFile)
	var st featureSnapshotState
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatal(err)
	}
	st.LoggedAt = time.Now().Add(-featureSnapshotFullEvery - time.Minute)
	if b, err = json.Marshal(st); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	logFeatureSnapshot()
	if !full() {
		t.Error("上一次整行打已过一天:整行打")
	}
}
