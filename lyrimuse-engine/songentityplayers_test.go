package main

import (
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
)

// 放过这条写法的播放器按第一次放的先后记,不重复、空串不记、记满为止。
func TestNotePlayerLocked(t *testing.T) {
	var e enrichEntry
	if !notePlayerLocked(&e, "com.apple.Music") || notePlayerLocked(&e, "com.apple.Music") || notePlayerLocked(&e, "") {
		t.Fatalf("第一次记、重复不记、空串不记: %v", e.Players)
	}
	notePlayerLocked(&e, "com.spotify.client")
	if !slices.Equal(e.Players, []string{"com.apple.Music", "com.spotify.client"}) {
		t.Errorf("按先后排: %v", e.Players)
	}
	for i := 0; i < maxNotedPlayers+3; i++ {
		notePlayerLocked(&e, fmt.Sprintf("x.%d", i))
	}
	if len(e.Players) != maxNotedPlayers {
		t.Errorf("最多记 %d 个: %d", maxNotedPlayers, len(e.Players))
	}
}

// 播放时每一拍进来的那条路(条目已经存在的分支)记下播放器,跟别的「变了才落盘」的字段一起落盘。
func TestTrackEnrichmentNotesPlayer(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func trackEnrichment(")
	if i < 0 {
		t.Fatal("找不到 trackEnrichment")
	}
	body = body[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	if !strings.Contains(body, "\t\tif notePlayerLocked(&e, bundleID) {\n\t\t\tspotifyHintDirty = true\n\t\t}\n") {
		t.Error("trackEnrichment 要记下放这首的播放器")
	}
}
