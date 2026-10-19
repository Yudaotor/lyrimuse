package main

import (
	"os"
	"path/filepath"
	"testing"
)

// 断网后第一轮源还没进冷却、请求全挂,记上「网络不通」;之后大部分源在冷却里被跳过,一轮只剩一两个请求、照样全挂,
// 不能当成网络通了把它撤掉;一个都没发的也不动;有一个请求成功才撤。
func TestNoteLyricsRoundNetworkKeepsDownThroughThinRounds(t *testing.T) {
	path := filepath.Join(t.TempDir(), "engine-status.json")
	setEngineStatusPath(path)
	t.Cleanup(func() { setEngineStatusPath("") })
	down := func() bool {
		_, err := os.Stat(path)
		return err == nil
	}

	noteLyricsRoundNetwork(12, 12)
	if !down() {
		t.Fatal("一轮 12 个请求全挂应记上网络不通")
	}
	for _, r := range [][2]int32{{2, 2}, {1, 1}, {0, 0}} {
		noteLyricsRoundNetwork(r[0], r[1])
		if !down() {
			t.Fatalf("attempts=%d failures=%d 这种轮次不该撤掉网络不通", r[0], r[1])
		}
	}
	noteLyricsRoundNetwork(2, 1)
	if down() {
		t.Fatal("有一个请求成功应撤掉网络不通")
	}
}
