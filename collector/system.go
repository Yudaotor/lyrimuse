// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// getState reads the current now-playing state once via `media-control get`.
// It is the authoritative fallback: the stream subscription can go silent for
// play/pause/seek notifications (observed on this macOS beta), so the ticker
// re-reads ground truth here to catch state changes the stream missed.
func getState(ctx context.Context, mcPath string) (map[string]any, bool) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, mcPath, "get").Output()
	if err != nil {
		return nil, false
	}
	var state map[string]any
	if err := json.Unmarshal(out, &state); err != nil {
		return nil, false
	}
	delete(state, "artworkData")
	return state, true
}

// appleMusicPosition returns Apple Music.app's authoritative player position
// (seconds) via AppleScript — exact to ~0.1s, vs media-control's elapsed+timestamp
// which drifts ~1-2s. Only valid when Music.app itself is playing (so it's empty
// for other players / the iPhone bridge). Short timeout; ok=false on any failure
// so the caller falls back to media-control tracking.
func appleMusicPosition(ctx context.Context) (float64, bool) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	const script = `tell application "Music"
	if player state is playing then return (player position as text)
	return "x"
end tell`
	out, err := exec.CommandContext(ctx, "osascript", "-e", script).Output()
	if err != nil {
		return 0, false
	}
	p, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil || p < 0 {
		return 0, false
	}
	return p, true
}
