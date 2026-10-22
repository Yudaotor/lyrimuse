package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 墙钟往回拨过(上次探盘时刻在「将来」):差值是负的,当作已到期照常探盘,不能一直停在节流里。
func TestFeaturesReloadAfterClockMovedBack(t *testing.T) {
	resetFeaturesForTest(t)
	path := filepath.Join(t.TempDir(), "f.json")
	if err := os.WriteFile(path, []byte(`{"lyrics_source_mode":"smart"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setFeatures(loadFeatureFlags(path))
	setFeaturesPath(path)
	if err := os.WriteFile(path, []byte(`{"lyrics_source_mode":"priority"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	featuresCheckedAt.Store(time.Now().Add(10 * time.Minute).UnixNano())
	if got := features().LyricsSourceMode; got != lyricsModePriority {
		t.Errorf("时钟回拨后该照常重读,got %q", got)
	}
}

func TestConfigReloadThrottleTreatsNegativeGapAsDue(t *testing.T) {
	src, err := os.ReadFile("configreload.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "if d := now - last; d >= 0 && d < int64(configReloadInterval) {") {
		t.Error("config.json 热重读节流:负差(时钟回拨)要当作已到期")
	}
}
