package main

import (
	"os"
	"strings"
	"testing"
)

// 锁外算好的罗马音在锁里怎么填:源自带的不动;算好了就用;没算时只补粤拼(纯查表)。
func TestApplyPregeneratedRoma(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]日本語", LyricsRoma: "[00:01.00]nihongo"}
	e.applyPregeneratedRoma("[00:01.00]other")
	if e.LyricsRoma != "[00:01.00]nihongo" {
		t.Fatalf("源自带的罗马音不能被覆盖: %q", e.LyricsRoma)
	}
	e = enrichEntry{Lyrics: "[00:01.00]日本語"}
	e.applyPregeneratedRoma("[00:01.00]nihongo")
	if e.LyricsRoma != "[00:01.00]nihongo" {
		t.Fatalf("算好的要填进来: %q", e.LyricsRoma)
	}
	e = enrichEntry{Lyrics: "[00:01.00]我哋一齊", SongLanguage: songLanguageCantonese}
	e.applyPregeneratedRoma("")
	if e.LyricsRoma == "" || !strings.Contains(e.LyricsRoma, "[00:01.00]") {
		t.Fatalf("没预算时粤语歌仍要补粤拼: %q", e.LyricsRoma)
	}
	e = enrichEntry{Lyrics: "[00:01.00]日本語"}
	e.applyPregeneratedRoma("")
	if e.LyricsRoma != "" {
		t.Fatalf("没预算时不在锁里起 helper: %q", e.LyricsRoma)
	}
}

// generatedRomaFor 跟 maybeGenerateRoma 同一套规则:源自带的原样返回,粤语走粤拼。
func TestGeneratedRomaFor(t *testing.T) {
	if got := generatedRomaFor("[00:01.00]我哋", "[00:01.00]src", songLanguageCantonese); got != "[00:01.00]src" {
		t.Fatalf("源自带的原样返回: %q", got)
	}
	want := enrichEntry{Lyrics: "[00:01.00]我哋一齊", SongLanguage: songLanguageCantonese}
	want.maybeGenerateRoma()
	if got := generatedRomaFor("[00:01.00]我哋一齊", "", songLanguageCantonese); got == "" || got != want.LyricsRoma {
		t.Fatalf("粤语歌应与 maybeGenerateRoma 一致: got %q want %q", got, want.LyricsRoma)
	}
}

// 升级重试 / 重评分改条目时持着 enrichMu,里面不许起罗马音 helper 子进程:按源码钉住。
func TestRetryAndRescoreDoNotRomanizeUnderLock(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range []string{"func retryLyricsUpgrade(", "func rescoreLyrics("} {
		body := string(src)
		i := strings.Index(body, fn)
		if i < 0 {
			t.Fatalf("找不到 %s", fn)
		}
		body = body[i+len(fn):]
		if j := strings.Index(body, "\nfunc "); j >= 0 {
			body = body[:j]
		}
		if strings.Contains(body, "e.maybeGenerateRoma()") {
			t.Errorf("%s 在持锁时调了 maybeGenerateRoma(会起 helper 子进程)", fn)
		}
		pre, lock := strings.Index(body, "generatedRomaFor("), strings.Index(body, "e, ok := enrichCache[key]")
		if pre < 0 || lock < 0 || pre > lock || !strings.Contains(body, "e.applyPregeneratedRoma(preparedRoma)") {
			t.Errorf("%s 要在上锁改条目之前算好罗马音、锁里只填", fn)
		}
	}
}
