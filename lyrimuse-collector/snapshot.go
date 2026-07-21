// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"time"
)

// snapshot is the subset of the media-control state we care about.
type snapshot struct {
	Title    string
	Artist   string
	Album    string
	Bundle   string
	Duration float64
	Playing  bool
	// media-control's own reading: at McTS the position was Elapsed, advancing at
	// Rate (1 playing, 0 paused). media-control freezes Elapsed/McTS during steady
	// play (only refreshed on events) and McTS drifts stale across sleep/idle, so
	// extrapolating from McTS overcounts non-playback time. We instead track the
	// position ourselves (see updatePosition) and fill Position + AnchorTS below.
	Elapsed float64
	Rate    float64
	McTS    time.Time
	// Collector-tracked live position (seconds) at AnchorTS (= submit time). This
	// is what we publish; the web extrapolates Position + (now-AnchorTS)*Rate over
	// a short, always-fresh window rather than from media-control's stale McTS.
	Position float64
	AnchorTS time.Time
}

func (s snapshot) key() string {
	if s.Title == "" && s.Artist == "" {
		return ""
	}
	return s.Title + "|" + s.Artist + "|" + s.Album
}

func extract(state map[string]any) snapshot {
	str := func(k string) string { v, _ := state[k].(string); return v }
	num := func(k string) float64 { v, _ := state[k].(float64); return v }
	playing, _ := state["playing"].(bool)
	mcTS := time.Now()
	if ts := str("timestamp"); ts != "" {
		if t, err := time.Parse(time.RFC3339, ts); err == nil {
			mcTS = t
		}
	}
	return snapshot{
		Title:    str("title"),
		Artist:   str("artist"),
		Album:    str("album"),
		Bundle:   str("bundleIdentifier"),
		Duration: num("duration"),
		Playing:  playing,
		Elapsed:  num("elapsedTime"),
		Rate:     num("playbackRate"),
		McTS:     mcTS,
	}
}
