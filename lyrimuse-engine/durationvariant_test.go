package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestDurationVariantSteady(t *testing.T) {
	durationVariantSeen = map[string]durationVariantObs{}
	t0 := time.Unix(1_800_000_000, 0)
	const k = "赵雷|成都|成都"
	if durationVariantSteadyLocked(k, 226.2, t0) {
		t.Fatal("第一拍不该建")
	}
	if durationVariantSteadyLocked(k, 226.5, t0.Add(2*time.Second)) {
		t.Fatal("没满 4 秒不该建")
	}
	if !durationVariantSteadyLocked(k, 226.3, t0.Add(4*time.Second)) {
		t.Fatal("同一个时长连续满 4 秒该建")
	}
	if _, ok := durationVariantSeen[k]; ok {
		t.Fatal("建过之后要清掉记录")
	}
	// 换了个时长:重新计时
	durationVariantSteadyLocked(k, 226, t0)
	if durationVariantSteadyLocked(k, 30, t0.Add(5*time.Second)) {
		t.Fatal("时长换了要重新计时")
	}
	// 断流:重新计时
	durationVariantSeen = map[string]durationVariantObs{}
	durationVariantSteadyLocked(k, 226, t0)
	if durationVariantSteadyLocked(k, 226, t0.Add(20*time.Second)) {
		t.Fatal("两次观察隔太久要重新计时")
	}
	durationVariantSeen = map[string]durationVariantObs{}
}

// 接线:要另开的变体还空着时先过去抖,时长对上就清记录。
func TestDurationVariantSteadyIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{
		"steady := rok || durationVariantSteadyLocked(key, durationSecs, time.Now())\n\t\t\tif !steady && !sameRecording {\n\t\t\t\tenrichMu.Unlock()\n\t\t\t\treturn nil\n\t\t\t}",
		"sameRecording := sameRecordingAsPlaying(e, bundleID, playingSongID)",
		"durationMismatch(e.ResolvedDurationSecs, durationSecs) && !sameRecordingStay, durationSecs",
		"case sameRecording:\n\t\t\t\t// 时长稳定成另一个值",
		"correctDuration, sameRecordingStay = true, true",
		"playingSongID := playingSongIDFor(bundleID, anchorLink, catalogIDs)\n\tenrichMu.Lock()",
		"} else {\n\t\t\tdelete(durationVariantSeen, key)\n\t\t}",
	} {
		if !strings.Contains(string(b), n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}

// 同一次播放里刚建的条目才算;换过一首再回来放同一首不算(见 enrichCreatedThisPlay)。
func TestEnrichCreatedThisPlay(t *testing.T) {
	savedPlaying, savedCreated := enrichPlayingKey.Load(), enrichCreatedThisPlay
	t.Cleanup(func() {
		enrichPlayingKey.Store(savedPlaying)
		enrichCreatedThisPlay = savedCreated
	})
	const k = "蔡徐坤|Jasmine|Jasmine"
	play := k
	enrichPlayingKey.Store(&play)
	noteEnrichCreatedLocked("别的|歌|名")
	if enrichCreatedThisPlayLocked("别的|歌|名") {
		t.Fatal("不是正在播的那首不记")
	}
	noteEnrichCreatedLocked(k)
	if !enrichCreatedThisPlayLocked(k) {
		t.Fatal("这次播放里刚建的要认(挂起之后那一拍起的解析也算)")
	}
	again := k
	enrichPlayingKey.Store(&again)
	if enrichCreatedThisPlayLocked(k) {
		t.Fatal("换过歌再回来放同一首,不是同一次播放")
	}
}

// 接线:这次播放刚建的条目时长对不上时原地改(首次解析还在跑就先不动),别的照旧另开变体;首次解析开跑时记一笔。
func TestDurationCorrectedInPlaceIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{
		"case !rok && enrichCreatedThisPlayLocked(key) && enrichInflight[key]:",
		"case !rok && enrichCreatedThisPlayLocked(key):",
		"\t\t\t\tcorrectDuration = true\n",
		"if correctDuration {\n\t\t\te.DurationSecs = durationSecs\n\t\t\tspotifyHintDirty = true\n\t\t}",
		"stamp := enrichEditStampLocked()\n\tnoteEnrichCreatedLocked(key)\n",
	} {
		if !strings.Contains(string(b), n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}

// 播放器这一拍报的曲目 id 跟条目记下的一样才算同一段录音;不报 id、或换了播放器,判不了。
func TestSameRecordingAsPlaying(t *testing.T) {
	e := enrichEntry{PlayerSongIDs: map[string]string{appleMusicBundleID: "312654337", qqMusicBundleID: "0039MnYb0qxYhV"}}
	for _, c := range []struct {
		name, bundle, id string
		want             bool
	}{
		{"同一个 id", appleMusicBundleID, "312654337", true},
		{"别的 id", appleMusicBundleID, "1440857781", false},
		{"不报 id", appleMusicBundleID, "", false},
		{"这个播放器没记过", neteaseMusicBundleID, "312654337", false},
		{"QQ 音乐", qqMusicBundleID, "0039MnYb0qxYhV", true},
	} {
		if got := sameRecordingAsPlaying(e, c.bundle, c.id); got != c.want {
			t.Errorf("%s: sameRecordingAsPlaying = %v, want %v", c.name, got, c.want)
		}
	}
	if sameRecordingAsPlaying(enrichEntry{}, appleMusicBundleID, "") {
		t.Error("两边都空不能算同一段")
	}
}

func TestPlayingSongIDFor(t *testing.T) {
	ids := playerCatalogIDs{songID: "0039MnYb0qxYhV"}
	if got := playingSongIDFor(qqMusicBundleID, "", ids); got != "0039MnYb0qxYhV" {
		t.Errorf("QQ 音乐取本机歌曲 id,得到 %q", got)
	}
	if got := playingSongIDFor(spotifyBundleID, "", ids); got != "" {
		t.Errorf("没对应字段的播放器返回空,得到 %q", got)
	}
	if got := playingSongIDFor(appleMusicBundleID, "", ids); got != "" {
		t.Errorf("Apple Music 没有锚点时返回空,得到 %q", got)
	}
}

func TestDurationVariantBaseKey(t *testing.T) {
	for _, c := range []struct {
		key, want string
		ok        bool
	}{
		{"王力宏|唯一~dur2|The Only One", "王力宏|唯一|The Only One", true},
		{"李宗盛|山丘~dur3|山丘 - Single", "李宗盛|山丘|山丘 - Single", true},
		{"王力宏|唯一|The Only One", "", false},
		{"某人|~dur2|专辑", "", false},
	} {
		got, ok := durationVariantBaseKey(c.key)
		if got != c.want || ok != c.ok {
			t.Errorf("durationVariantBaseKey(%q) = %q, %v; want %q, %v", c.key, got, ok, c.want, c.ok)
		}
	}
	if k := enrichKeyDurationVariant("王力宏|唯一|The Only One", 2); k != "王力宏|唯一~dur2|The Only One" {
		t.Fatalf("enrichKeyDurationVariant 跟 durationVariantBaseKey 对不上:%q", k)
	}
}

// 启动迁移:跟基条目是同一段录音的「~durN」并回去(留分高的那份),id 不同或时长差太多的照旧单独留着。
func TestPlanEnrichKeyMigrationFoldsSameRecordingVariant(t *testing.T) {
	am := func(id string) map[string]string { return map[string]string{appleMusicBundleID: id} }
	cache := map[string]enrichEntry{
		"王力宏|唯一|The Only One":      {LyricsSource: "qq", LyricsScore: 1100, DurationSecs: 262.013, PlayerSongIDs: am("312654337")},
		"王力宏|唯一~dur2|The Only One": {LyricsSource: "applemusic", LyricsScore: 1444, DurationSecs: 262.013, PlayerSongIDs: am("312654337")},
		"周杰伦|太陽之子|":                {LyricsSource: "qq", DurationSecs: 298, PlayerSongIDs: am("1000")},
		"周杰伦|太陽之子~dur2|":           {LyricsSource: "qq", DurationSecs: 418.141, PlayerSongIDs: am("1000")},
		"某人|歌|专辑":                  {LyricsSource: "kugou", DurationSecs: 200, PlayerSongIDs: am("1")},
		"某人|歌~dur2|专辑":             {LyricsSource: "kugou", DurationSecs: 202, PlayerSongIDs: am("2")},
	}
	got := planEnrichKeyMigration(cache)
	if g := got["王力宏|唯一|The Only One"]; !reflect.DeepEqual(g, []string{"王力宏|唯一|The Only One", "王力宏|唯一~dur2|The Only One"}) {
		t.Errorf("同一段录音的变体要并进基条目那一组,得到 %#v", g)
	}
	if _, ok := got["王力宏|唯一~dur2|The Only One"]; ok {
		t.Error("并掉的变体不该再单独成组")
	}
	if g := got["周杰伦|太陽之子~dur2|"]; !reflect.DeepEqual(g, []string{"周杰伦|太陽之子~dur2|"}) {
		t.Errorf("同一个 id 但时长差太多(MV 跟音轨)不并,得到 %#v", g)
	}
	if g := got["某人|歌~dur2|专辑"]; !reflect.DeepEqual(g, []string{"某人|歌~dur2|专辑"}) {
		t.Errorf("曲目 id 不同不并,得到 %#v", g)
	}
}
