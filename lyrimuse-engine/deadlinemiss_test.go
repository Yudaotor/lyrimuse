package main

import (
	"context"
	"slices"
	"testing"
)

// 同一次解析里被总截止掐掉过的源,补缺席的轮次不再为它跑;没挂记录的 ctx 照旧。
func TestLyricSourcesWorthRetrySkipsDeadlineMisses(t *testing.T) {
	ctx := withLyricDeadlineMisses(context.Background())
	if again := withLyricDeadlineMisses(ctx); again != ctx {
		t.Fatal("已经挂了就该原样返回,同一次解析共用一份")
	}
	before := lyricSourcesWorthRetry(ctx, nil)
	if !slices.Contains(before, "kugou") {
		t.Skipf("用例前提:kugou 该在名单里(本机设置关了这个源?) %v", before)
	}
	noteLyricDeadlineMiss(ctx, "kugou")
	after := lyricSourcesWorthRetry(ctx, nil)
	if slices.Contains(after, "kugou") {
		t.Errorf("被截止掐掉过的源不该再进补缺席名单: %v", after)
	}
	if len(after) != len(before)-1 {
		t.Errorf("别的源不受影响: before=%v after=%v", before, after)
	}
	if !slices.Contains(lyricSourcesWorthRetry(context.Background(), nil), "kugou") {
		t.Error("没挂记录的 ctx 不受影响")
	}
}
