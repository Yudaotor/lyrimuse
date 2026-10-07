package main

import (
	"bytes"
	"log"
	"os"
	"strings"
	"testing"
	"time"
)

// 出词之前只做粤拼:lyricsEntryFromScored 不起 lyrics-romanize,helper 那一步由 resolveTrackEnrichment
// 在提交出词之后补。
func TestLyricsEntryFromScoredDefersHelperRoma(t *testing.T) {
	calls := 0
	saved := onDeviceRomanizer
	onDeviceRomanizer = func(string) (string, error) { calls++; return "[00:01.00]ni hao", nil }
	t.Cleanup(func() { onDeviceRomanizer = saved })

	scored := []scoredLyricCandidateResult{{Source: "kugou", Score: 900, Lyrics: "[00:01.00]你好世界\n[00:02.00]今天天气很好"}}
	e, picked := lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "某人", "某歌", "", 200, neteaseInfo{}, scored, nil, nil, false, "", nil)
	if picked == nil || e.Lyrics == "" {
		t.Fatalf("picked=%v", picked)
	}
	if calls != 0 || e.LyricsRoma != "" {
		t.Fatalf("出词之前不该起 helper: calls=%d roma=%q", calls, e.LyricsRoma)
	}
	e.maybeGenerateRoma()
	if calls != 1 || e.LyricsRoma == "" {
		t.Fatalf("出词之后要补上: calls=%d roma=%q", calls, e.LyricsRoma)
	}
}

// 接线守卫:resolveTrackEnrichment 先把歌词交给 onLyrics,再补读音;周边补全遇到已有歌词的条目只查网易云,
// 那一支在整套歌词搜索之前返回。
func TestSearchAuditWiring(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	early := strings.Index(src, "\t\tonLyrics(e)\n\t\ttimer.mark(\"commit\")")
	roma := strings.Index(src, "\te.maybeGenerateRoma()\n\treturn finishTrackEnrichment(")
	if early < 0 || roma < 0 || early > roma {
		t.Error("resolveTrackEnrichment 要先 onLyrics(e) 出词、再 maybeGenerateRoma")
	}
	only := strings.Index(src, "\tif peripheralOnly(ctx) {")
	search := strings.Index(src, "\tne, scored = scoredLyricCandidates(roundCtx, artist, title, searchAlbum, durationSecs)")
	if only < 0 || search < 0 || only > search {
		t.Error("peripheralOnly 那一支要排在整套歌词搜索之前")
	}
	if !strings.Contains(src, "\tif skipLyrics {\n\t\tctx = withPeripheralOnly(ctx)\n\t}") {
		t.Error("backfillPeripheralFields 没接 withPeripheralOnly")
	}
	prov, _ := os.ReadFile("provisionallyrics.go")
	if strings.Contains(string(prov), "maybeGenerateRoma()") || strings.Contains(string(prov), "maybeGenerateHelperRoma()") {
		t.Error("lyricsEntryFromScored 里不该起 helper")
	}
}

// 已有歌词(或手改过、判定过纯音乐)的条目跳过歌词搜索;跳过的这些,adoptBackfilledLyrics 本来也不会收。
func TestPeripheralBackfillSkipsLyricsMatchesAdopt(t *testing.T) {
	fresh := enrichEntry{Lyrics: "[00:01.00]new", LyricsSource: "qq"}
	for _, c := range []struct {
		name string
		e    enrichEntry
		skip bool
	}{
		{"有歌词", enrichEntry{Lyrics: "[00:01.00]old"}, true},
		{"手改过", enrichEntry{ManualLyrics: true}, true},
		{"纯音乐", enrichEntry{Instrumental: true}, true},
		{"空条目", enrichEntry{}, false},
	} {
		if got := peripheralBackfillSkipsLyrics(c.e); got != c.skip {
			t.Errorf("%s: skip=%v want %v", c.name, got, c.skip)
		}
		e := c.e
		if adopted := adoptBackfilledLyrics(&e, fresh); adopted == c.skip {
			t.Errorf("%s: skip=%v 但 adoptBackfilledLyrics=%v,两处判据对不上", c.name, c.skip, adopted)
		}
	}
}

func TestStepTimerLogsOnlyWhenSlow(t *testing.T) {
	var buf bytes.Buffer
	saved := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(saved) })

	var nilTimer *stepTimer
	nilTimer.mark("x")
	nilTimer.logIfSlow("nil", 0)

	fast := newStepTimer()
	fast.mark("a")
	fast.logIfSlow("fast", time.Hour)
	slow := newStepTimer()
	time.Sleep(5 * time.Millisecond)
	slow.mark("lock")
	slow.mark("save")
	slow.logIfSlow("commit for k", time.Millisecond)
	out := buf.String()
	if strings.Contains(out, "fast") || strings.Contains(out, "nil") {
		t.Fatalf("没到门槛不该打: %q", out)
	}
	if !strings.Contains(out, "slow commit for k: total=") || !strings.Contains(out, "lock=") || !strings.Contains(out, "save=") {
		t.Fatalf("分段日志: %q", out)
	}
}

func TestLrclibHostRate(t *testing.T) {
	r := hostRateFor("lrclib.net")
	if r.perSec != 1 || r.burst < 5 || r.reserve >= r.burst {
		t.Fatalf("lrclib 限速 %+v", r)
	}
}
