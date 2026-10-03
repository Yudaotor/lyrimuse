package main

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func newTestTitleSpec(samples []string) (*titleReverseSpec, context.Context) {
	ctx, cancel := context.WithCancel(context.Background())
	return &titleReverseSpec{samples: samples, done: make(chan struct{}), cancel: cancel}, ctx
}

func TestTitleReverseSpecTake(t *testing.T) {
	s, _ := newTestTitleSpec([]string{"a", "b"})
	go func() {
		time.Sleep(30 * time.Millisecond)
		s.corrected, s.method, s.artist, s.fetched = "正确曲名", "title-from-album", "歌手", true
		close(s.done)
	}()
	got := s.take([]string{"a", "b"})
	if got == nil || got.corrected != "正确曲名" || !got.fetched {
		t.Fatalf("样本一样:应等它跑完并用它的结果, got %+v", got)
	}

	s2, ctx2 := newTestTitleSpec([]string{"a"})
	if s2.take([]string{"a", "changed"}) != nil {
		t.Fatal("样本变了不该用提前跑的结果")
	}
	select {
	case <-ctx2.Done():
	case <-time.After(time.Second):
		t.Fatal("样本变了应当取消提前跑的那一轮")
	}

	var none *titleReverseSpec
	if none.take(nil) != nil {
		t.Fatal("没提前跑时返回 nil")
	}
	none.stop() // nil 上调用是空操作
}

// 接线守卫:救急时提前跑标题反查;反查那一步样本一致就用它的结果。
func TestTitleReverseSpecIsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, n := range []string{
		"defer func() { titleSpec.stop() }()",
		"if rescue {\n\t\t\ttitleSpec = startTitleReverseSpec(ctx, artist, title, album, durationSecs, lyricSamplesForStorefront(results),\n\t\t\t\ttrustedRecordingISRC(artist, title, album, durationSecs, results))",
		"spec := titleSpec.take(samples)",
		"correctedTitle, retryMethod, titleArtist = titleReverseLookup(ctx, artist, title, album, durationSecs, samples,\n\t\t\t\ttrustedRecordingISRC(artist, title, album, durationSecs, results))",
		"if spec != nil && spec.fetched {",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}
