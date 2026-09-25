package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestShareIdenticalDecisions(t *testing.T) {
	mk := func(winner string) *lyricsDecision {
		return &lyricsDecision{Path: "first-resolve", Winner: winner, Applied: true,
			Candidates: []lyricsDecisionCandidate{{Source: winner, Score: 900}}}
	}
	m := map[string]enrichEntry{
		"same":     {LyricsDecision: mk("qq"), LyricsDecisionApplied: mk("qq")},
		"differ":   {LyricsDecision: mk("qq"), LyricsDecisionApplied: mk("kugou")},
		"onlyLast": {LyricsDecision: mk("qq")},
		"none":     {},
	}
	before, _ := json.Marshal(m)
	if n := shareIdenticalDecisions(m); n != 1 {
		t.Fatalf("shared = %d, want 1", n)
	}
	if m["same"].LyricsDecision != m["same"].LyricsDecisionApplied {
		t.Fatal("identical pair must share one object")
	}
	if m["differ"].LyricsDecision == m["differ"].LyricsDecisionApplied {
		t.Fatal("different pair must stay separate")
	}
	if m["onlyLast"].LyricsDecisionApplied != nil {
		t.Fatal("missing applied slot must stay nil")
	}
	after, _ := json.Marshal(m)
	if !bytes.Equal(before, after) {
		t.Fatal("sharing must not change what gets written")
	}
	if n := shareIdenticalDecisions(m); n != 0 {
		t.Fatalf("second pass shared = %d, want 0 (already shared)", n)
	}
}
