package main

import (
	"context"
	"reflect"
	"testing"
)

// 补搜的进度里带上跳过数和最近几条的结果(新的在前、最多 lyricsFillRecentMax 条);全量扫库那一轮同样记,
// 界面按 Full 把 missed 读成「重选后没变」。
func TestLyricsFillSweepRecentAndSkipped(t *testing.T) {
	outcomes := map[string]lyricsSweepOutcome{
		"a": {filled: true},
		"b": {},
		"c": {skipped: true},
		"d": {filled: true},
	}
	stubLyricsFillSweep(t, func(_ context.Context, key string) lyricsSweepOutcome { return outcomes[key] })
	st := runLyricsFillSweepKeys(context.Background(), []string{"a", "b", "c", "d"}, false, 0, lyricsFillStatus{Running: true, Total: 4})
	if st.Done != 4 || st.Filled != 2 || st.Skipped != 1 {
		t.Fatalf("计数: %+v", st)
	}
	want := []lyricsFillRecent{{Key: "d", Result: "filled"}, {Key: "c", Result: "skipped"}, {Key: "b", Result: "missed"}}
	if !reflect.DeepEqual(st.Recent, want) {
		t.Fatalf("最近结果 got %+v want %+v", st.Recent, want)
	}
	full := runLyricsFillSweepKeys(context.Background(), []string{"a", "b"}, true, 0, lyricsFillStatus{Running: true, Full: true, Total: 2})
	wantFull := []lyricsFillRecent{{Key: "b", Result: "missed"}, {Key: "a", Result: "filled"}}
	if !reflect.DeepEqual(full.Recent, wantFull) {
		t.Fatalf("全量扫库的最近结果 got %+v want %+v", full.Recent, wantFull)
	}
}
