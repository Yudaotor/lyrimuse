package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withTempDecisionCache(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	savedPath, savedCache, savedDirty := enrichPath, enrichCache, enrichDirty
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichPath, enrichCache, enrichDirty = savedPath, savedCache, savedDirty
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	return dir
}

func fullDecision(path string, at int64, winner string) *lyricsDecision {
	return &lyricsDecision{
		Path: path, DecidedAt: at, ScoringVersion: 23, Winner: winner, Applied: true,
		SourcesResponded: []string{winner, "lrclib"},
		Candidates: []lyricsDecisionCandidate{
			{Source: winner, Score: 1100, Artist: " Prince ", CoverURL: "https://x/a.jpg",
				ScoreTerms: []scoreTerm{{Kind: "duration", Points: 238}}},
			{Source: "lrclib", Score: 700, Artist: "prince"},
		},
		QueriesTried: []lyricQueryRecord{{Artist: "王子", Title: "Purple Rain"}},
	}
}

func readSidecarForTest(t *testing.T, dir, key string) *decisionSidecar {
	t.Helper()
	rec := readDecisionSidecar(filepath.Join(dir, clientName+"-decisions", decisionSidecarName(key)))
	if rec == nil {
		t.Fatalf("sidecar for %q missing", key)
	}
	return rec
}

// 保存时拆:主缓存里只剩顶层字段 + WinnerArtist,明细进旁路文件;两槽相同写 applied_same。
func TestSaveSplitsDecisionDetails(t *testing.T) {
	dir := withTempDecisionCache(t)
	d := fullDecision("first-resolve", 100, "kugou")
	enrichMu.Lock()
	enrichCache["王子|Purple Rain|"] = enrichEntry{Lyrics: "[00:01.00]x", LyricsDecision: d, LyricsDecisionApplied: d}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()

	raw, err := os.ReadFile(enrichPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "candidates") || strings.Contains(string(raw), "queries_tried") {
		t.Fatalf("main cache must not carry candidate details: %s", raw)
	}
	var onDisk map[string]enrichEntry
	if err := json.Unmarshal(raw, &onDisk); err != nil {
		t.Fatal(err)
	}
	got := onDisk["王子|Purple Rain|"]
	if got.LyricsDecision == nil || got.LyricsDecision.WinnerArtist != "Prince" || got.LyricsDecision.Winner != "kugou" {
		t.Fatalf("stripped decision keeps top-level fields + winner_artist, got %+v", got.LyricsDecision)
	}
	enrichMu.Lock()
	mem := enrichCache["王子|Purple Rain|"]
	enrichMu.Unlock()
	if hasDecisionDetails(mem.LyricsDecision) || mem.LyricsDecision != mem.LyricsDecisionApplied {
		t.Fatal("in-memory entry must be the stripped one, both slots still sharing one object")
	}
	if len(d.Candidates) != 2 {
		t.Fatal("the original decision object must not be mutated")
	}
	rec := readSidecarForTest(t, dir, "王子|Purple Rain|")
	if rec.Latest == nil || len(rec.Latest.Candidates) != 2 || len(rec.Latest.QueriesTried) != 1 || !rec.AppliedSame || rec.Applied != nil {
		t.Fatalf("sidecar = %+v", rec)
	}
	if !got.LyricsDecision.DetailsExternal {
		t.Fatal("stripped slot must be marked details_external")
	}
	if decisionWinnerArtist(mem.LyricsDecisionApplied) != "Prince" {
		t.Fatal("winner artist readable without candidates")
	}
}

// 一轮没被采纳的升级评估只换了 latest:applied 那份明细要从旧文件原样留住。
func TestSidecarKeepsAppliedDetailsWhenOnlyLatestChanges(t *testing.T) {
	dir := withTempDecisionCache(t)
	key := "a|t|b"
	first := fullDecision("first-resolve", 100, "kugou")
	enrichMu.Lock()
	enrichCache[key] = enrichEntry{LyricsDecision: first, LyricsDecisionApplied: first}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()

	enrichMu.Lock()
	e := enrichCache[key]
	up := fullDecision("upgrade", 200, "qq")
	up.Applied = false
	e.LyricsDecision = up // applied 仍是拆过的那一份(first-resolve)
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()

	rec := readSidecarForTest(t, dir, key)
	if rec.Latest == nil || rec.Latest.Path != "upgrade" || rec.Latest.Winner != "qq" {
		t.Fatalf("latest slot = %+v", rec.Latest)
	}
	if rec.AppliedSame || rec.Applied == nil || rec.Applied.Path != "first-resolve" || len(rec.Applied.Candidates) != 2 {
		t.Fatalf("applied slot must keep the first-resolve details, got %+v", rec.Applied)
	}
}

// 跨专辑复用:按指纹从兄弟的旁路文件补回明细;指纹对不上不补。
func TestWithDecisionDetailsRehydratesByFingerprint(t *testing.T) {
	withTempDecisionCache(t)
	d := fullDecision("first-resolve", 100, "kugou")
	enrichMu.Lock()
	enrichCache["s|t|x"] = enrichEntry{LyricsDecision: d, LyricsDecisionApplied: d}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	enrichMu.Lock()
	stripped := enrichCache["s|t|x"].LyricsDecisionApplied
	enrichMu.Unlock()

	full := withDecisionDetails("s|t|x", stripped)
	if len(full.Candidates) != 2 || full == stripped || hasDecisionDetails(stripped) || full.DetailsExternal {
		t.Fatalf("rehydrate must return a new object with details, got %+v", full)
	}
	other := *stripped
	other.DecidedAt = 999
	if got := withDecisionDetails("s|t|x", &other); hasDecisionDetails(got) {
		t.Fatal("fingerprint mismatch must not attach another round's candidates")
	}
}

// key 归一改名、撤回删除、启动清理孤儿文件。
func TestDecisionSidecarFollowsKeys(t *testing.T) {
	dir := withTempDecisionCache(t)
	sdir := filepath.Join(dir, clientName+"-decisions")
	for _, k := range []string{"old|t|b", "gone|t|b"} {
		d := fullDecision("first-resolve", 100, "qq")
		enrichMu.Lock()
		enrichCache[k] = enrichEntry{LyricsDecision: d, LyricsDecisionApplied: d}
		enrichDirty = true
		enrichMu.Unlock()
	}
	saveEnrichCache()

	renameDecisionSidecar("old|t|b", "new|t|b")
	if _, err := os.Stat(filepath.Join(sdir, decisionSidecarName("old|t|b"))); !os.IsNotExist(err) {
		t.Fatal("old sidecar must be gone after rename")
	}
	if rec := readSidecarForTest(t, dir, "new|t|b"); rec.Key != "new|t|b" || rec.Latest == nil {
		t.Fatalf("renamed sidecar = %+v", rec)
	}

	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{"new|t|b": {}}
	enrichMu.Unlock()
	sweepDecisionSidecars()
	if _, err := os.Stat(filepath.Join(sdir, decisionSidecarName("gone|t|b"))); !os.IsNotExist(err) {
		t.Fatal("orphaned sidecar must be swept")
	}
	readSidecarForTest(t, dir, "new|t|b")

	removeDecisionSidecar("new|t|b")
	if _, err := os.Stat(filepath.Join(sdir, decisionSidecarName("new|t|b"))); !os.IsNotExist(err) {
		t.Fatal("removed sidecar must be gone")
	}
}

// 文件名跟 App 侧 DecisionSidecar.fileName 逐字节一致(期望值由 Python hashlib 独立算出,selftest 钉同一个)。
func TestDecisionSidecarNameMatchesApp(t *testing.T) {
	if got := decisionSidecarName("王子|Purple Rain|"); got != "55248cfcc659699af70190eca1ba1e17.json" {
		t.Fatalf("decisionSidecarName = %s", got)
	}
}
