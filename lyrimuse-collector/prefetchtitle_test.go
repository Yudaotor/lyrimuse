package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 每个发起首次解析的调用点,交给歌词源的曲名都必须先过 normEnrichTitle —— 跟 trackEnrichment 同一份查询词。
// key 里剥掉的尾括号(播放队列里的「（合作音乐人:X）」这类)原样发出去,歌词源全部落空,落下的空条目
// 正好占着播放时要用的 key,播放时就不再重搜。源码级守卫:预取路径没有可注入的检索桩。
func TestResolveEnrichCallersNormalizeTitle(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "go resolveEnrichAsync(") {
				continue
			}
			calls++
			if f == "enrich.go" {
				continue // trackEnrichment:下面单独核对它在发起前归一过 title
			}
			if !strings.Contains(line, "normEnrichTitle(") {
				t.Errorf("%s:%d 发起首次解析时曲名没过 normEnrichTitle: %s", f, i+1, line)
			}
		}
	}
	if calls < 3 {
		t.Fatalf("只找到 %d 处 go resolveEnrichAsync( —— 调用点改名或改写法了,同步改这个守卫", calls)
	}
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	norm := strings.Index(src, "\ttitle = normEnrichTitle(title)\n")
	call := strings.Index(src, "go resolveEnrichAsync(cancelCtx, key, artist, title, album, bundleID, durationSecs, isNewTrack)")
	if norm < 0 || call < 0 || norm > call {
		t.Fatal("trackEnrichment 必须在发起首次解析之前把 title 归一(title = normEnrichTitle(title))")
	}
}
