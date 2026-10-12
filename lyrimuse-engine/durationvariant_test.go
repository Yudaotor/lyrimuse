package main

import (
	"os"
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
		"if !rok && !durationVariantSteadyLocked(key, durationSecs, time.Now()) {\n\t\t\t\tenrichMu.Unlock()\n\t\t\t\treturn nil\n\t\t\t}",
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
