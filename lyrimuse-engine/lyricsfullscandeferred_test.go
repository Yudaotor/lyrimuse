package main

import (
	"context"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func useTempLyricsFullScanState(t *testing.T) {
	t.Helper()
	saved := lyricsFullScanStatePath
	t.Cleanup(func() {
		lyricsFullScanMu.Lock()
		lyricsFullScanStatePath = saved
		lyricsFullScanMu.Unlock()
	})
	setLyricsFullScanStatePath(filepath.Join(t.TempDir(), "fullscan.json"))
}

// 主循环里没法判断的那首记进状态文件,整份候选跑完后再试一次;再试那一遍不重复计 Done。
func TestLyricsFullScanRetriesDeferredAtEnd(t *testing.T) {
	useTempLyricsFullScanState(t)
	tries := map[string]int{}
	calls, _ := stubLyricsFillSweep(t, func(_ context.Context, key string) lyricsSweepOutcome {
		tries[key]++
		if key == "b" && tries[key] == 1 {
			return lyricsSweepOutcome{deferred: true}
		}
		return lyricsSweepOutcome{filled: key == "b"}
	})
	st := runLyricsFillSweepKeys(context.Background(), []string{"a", "b", "c"}, true, 0, lyricsFillStatus{Running: true, Full: true, Total: 3})
	if st.Done != 3 || st.Filled != 0 || st.Deferred != 1 {
		t.Fatalf("主循环计数: %+v", st)
	}
	if got := readLyricsFullScanState().Deferred; !reflect.DeepEqual(got, []string{"b"}) {
		t.Fatalf("待再试名单 got %v", got)
	}
	st = runLyricsFullScanDeferredKeys(context.Background(), 0, st)
	if strings.Join(*calls, ",") != "a,b,c,b" {
		t.Fatalf("调用顺序 got %v", *calls)
	}
	if st.Done != 3 || st.Filled != 1 || st.Deferred != 0 {
		t.Fatalf("收尾计数: %+v", st)
	}
	if got := readLyricsFullScanState().Deferred; len(got) != 0 {
		t.Fatalf("再试过的应当从名单划掉 got %v", got)
	}
	if st.Recent[0] != (lyricsFillRecent{Key: "b", Result: "filled"}) {
		t.Fatalf("最近结果 got %+v", st.Recent)
	}
}

// 再试一次仍没法判断就放下,不会没完没了地重试。
func TestLyricsFullScanDeferredRetriedOnlyOnce(t *testing.T) {
	useTempLyricsFullScanState(t)
	calls, _ := stubLyricsFillSweep(t, func(context.Context, string) lyricsSweepOutcome {
		return lyricsSweepOutcome{deferred: true}
	})
	st := runLyricsFillSweepKeys(context.Background(), []string{"a"}, true, 0, lyricsFillStatus{Running: true, Full: true, Total: 1})
	st = runLyricsFullScanDeferredKeys(context.Background(), 0, st)
	if strings.Join(*calls, ",") != "a,a" {
		t.Fatalf("调用 got %v", *calls)
	}
	if st.Deferred != 0 || len(readLyricsFullScanState().Deferred) != 0 {
		t.Fatalf("再试过一次就该放下: %+v", st)
	}
	if st.Recent[0].Result != "deferred" {
		t.Fatalf("最近结果 got %+v", st.Recent)
	}
}

// 再试那一遍断网停下:没试到的留在名单里等续跑。
func TestLyricsFullScanDeferredKeptWhenOffline(t *testing.T) {
	useTempLyricsFullScanState(t)
	noteLyricsFullScanDeferred("a")
	noteLyricsFullScanDeferred("b")
	stubLyricsFillSweep(t, func(context.Context, string) lyricsSweepOutcome {
		return lyricsSweepOutcome{offline: true}
	})
	st := runLyricsFullScanDeferredKeys(context.Background(), 0, lyricsFillStatus{Running: true, Full: true})
	if !st.Offline {
		t.Fatalf("应当标断网: %+v", st)
	}
	if got := readLyricsFullScanState().Deferred; !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Fatalf("断网时名单不该动 got %v", got)
	}
}

// 名单里的条目这一轮主循环本来就会跑到时去掉,免得同一首搜两遍;重复记一条不重复进名单。
func TestPruneLyricsFullScanDeferred(t *testing.T) {
	useTempLyricsFullScanState(t)
	noteLyricsFullScanDeferred("a")
	noteLyricsFullScanDeferred("b")
	if n := noteLyricsFullScanDeferred("a"); n != 2 {
		t.Fatalf("重复记应当不变 got %d", n)
	}
	if got := pruneLyricsFullScanDeferred([]string{"a", "c"}); !reflect.DeepEqual(got, []string{"b"}) {
		t.Fatalf("去重后 got %v", got)
	}
	if got := readLyricsFullScanState().Deferred; !reflect.DeepEqual(got, []string{"b"}) {
		t.Fatalf("去重应当落盘 got %v", got)
	}
	resetLyricsFullScanProgress()
	if got := readLyricsFullScanState().Deferred; len(got) != 0 {
		t.Fatalf("一场结束应当清掉名单 got %v", got)
	}
}
