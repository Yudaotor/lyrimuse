package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// setupPrefetchImportTest:清单和进度落在临时目录,两首之间不等,跑一首换成 runOne(nil 时用真的)。
func setupPrefetchImportTest(t *testing.T, lines []string, runOne func(context.Context, prefetchImportItem) prefetchImportOutcome) {
	t.Helper()
	dir := t.TempDir()
	savedQueue, savedState, savedWait, savedRun := prefetchImportQueuePath, prefetchImportStatePath, prefetchImportWait, prefetchImportRunOne
	t.Cleanup(func() {
		prefetchImportQueuePath, prefetchImportStatePath, prefetchImportWait, prefetchImportRunOne = savedQueue, savedState, savedWait, savedRun
	})
	prefetchImportQueuePath = filepath.Join(dir, "queue.jsonl")
	prefetchImportStatePath = filepath.Join(dir, "state.json")
	prefetchImportWait = func(context.Context, time.Duration) {}
	if runOne != nil {
		prefetchImportRunOne = runOne
	}
	if err := os.WriteFile(prefetchImportQueuePath, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// 按清单顺序跑;写坏的行、缺歌名的行、跑出来是「已有」的都记跳过;进度落盘,中途停下再跑从停下那一首接着跑。
func TestRunPrefetchImportResumes(t *testing.T) {
	var seen []string
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	setupPrefetchImportTest(t, []string{
		`{"artist":"A","title":"One","album":"X","duration":200}`,
		`not json`,
		`{"artist":"A","title":"","album":"X"}`,
		`{"artist":"A","title":"Two","album":"X"}`,
		`{"artist":"A","title":"Three","album":"X"}`,
		`{"artist":"A","title":"Four","album":"X"}`,
	}, func(_ context.Context, it prefetchImportItem) prefetchImportOutcome {
		seen = append(seen, it.Title)
		switch it.Title {
		case "Two":
			return prefetchImportOutcome{} // 已有
		case "Three":
			cancel()
			return prefetchImportOutcome{started: true}
		}
		return prefetchImportOutcome{started: true, filled: true}
	})
	runPrefetchImport(ctx)
	if got := strings.Join(seen, ","); got != "One,Two,Three" {
		t.Fatalf("第一遍跑了 %s", got)
	}
	st := loadPrefetchImportState()
	if st.Cursor != 4 || st.Total != 6 || st.Queued != 1 || st.Filled != 1 || st.Skipped != 3 || st.Finished {
		t.Fatalf("停下时的进度 %+v", st)
	}
	runPrefetchImport(context.Background())
	if got := strings.Join(seen, ","); got != "One,Two,Three,Three,Four" {
		t.Fatalf("续跑应从停下那一首接着跑,实际 %s", got)
	}
	st = loadPrefetchImportState()
	if !st.Finished || st.Cursor != 6 || st.Queued != 3 || st.Filled != 2 {
		t.Fatalf("跑完的进度 %+v", st)
	}
	st.UpdatedAt = 1
	data, _ := json.Marshal(st)
	if err := os.WriteFile(prefetchImportStatePath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	runPrefetchImport(context.Background())
	if len(seen) != 5 {
		t.Fatalf("跑完的清单不该再跑,实际 %v", seen)
	}
	if st := loadPrefetchImportState(); st.UpdatedAt != 1 {
		t.Fatalf("跑完的清单不该再改写进度: %+v", st)
	}
}

// 一个源都没连上的那首不算数,停在它上面;清单内容变了从头跑。
func TestRunPrefetchImportOfflineAndNewList(t *testing.T) {
	offline := true
	var seen []string
	setupPrefetchImportTest(t, []string{
		`{"artist":"A","title":"One","album":"X"}`,
		`{"artist":"A","title":"Two","album":"X"}`,
	}, func(_ context.Context, it prefetchImportItem) prefetchImportOutcome {
		seen = append(seen, it.Title)
		if it.Title == "Two" && offline {
			return prefetchImportOutcome{started: true, offline: true}
		}
		return prefetchImportOutcome{started: true}
	})
	runPrefetchImport(context.Background())
	if st := loadPrefetchImportState(); st.Cursor != 1 || st.Finished {
		t.Fatalf("断网那首不该算数: %+v", st)
	}
	offline = false
	runPrefetchImport(context.Background())
	if got := strings.Join(seen, ","); got != "One,Two,Two" {
		t.Fatalf("网络回来应从断网那首接着跑,实际 %s", got)
	}
	if err := os.WriteFile(prefetchImportQueuePath, []byte(`{"artist":"B","title":"New","album":"Y"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runPrefetchImport(context.Background())
	if seen[len(seen)-1] != "New" {
		t.Fatalf("新清单应从头跑,实际 %v", seen)
	}
	if st := loadPrefetchImportState(); st.Total != 1 || st.Cursor != 1 || !st.Finished {
		t.Fatalf("新清单的进度 %+v", st)
	}
}

// 补空扫描 / 全量扫库在跑时一首都不起。
func TestRunPrefetchImportYieldsToSweep(t *testing.T) {
	setupPrefetchImportTest(t, []string{`{"artist":"A","title":"One","album":"X"}`},
		func(context.Context, prefetchImportItem) prefetchImportOutcome {
			t.Error("扫描在跑时不该起")
			return prefetchImportOutcome{}
		})
	lyricsFillSweepMu.Lock()
	lyricsFillSweepRunning = true
	lyricsFillSweepMu.Unlock()
	t.Cleanup(func() {
		lyricsFillSweepMu.Lock()
		lyricsFillSweepRunning = false
		lyricsFillSweepMu.Unlock()
	})
	runPrefetchImport(context.Background())
	if st := loadPrefetchImportState(); st.Cursor != 0 {
		t.Fatalf("让开时不该前进: %+v", st)
	}
}

// 真的解析一首:写进按清单写法算的 key;缓存里已有等价写法的不起。
func TestPrefetchImportOneResolves(t *testing.T) {
	it := prefetchImportItem{Artist: rescoreTestArtist, Title: "Import Song", Album: "Import Album", Duration: 180}
	key := enrichKey(it.Artist, it.Title, it.Album)
	claimed := false
	setupRescoreTest(t, []string{"musixmatch"}, func(context.Context) {
		enrichMu.Lock()
		claimed = enrichInflight[key]
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	out := prefetchImportOne(context.Background(), it)
	if !claimed {
		t.Error("解析期间这首要标成在途,别的路径才不会重复起")
	}
	if !out.started || !out.filled || out.offline {
		t.Fatalf("结果 %+v", out)
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	inflight := enrichInflight[key]
	enrichMu.Unlock()
	if !ok || !e.Lyrics.EqualString(rescoreTestNewBody) || inflight {
		t.Fatalf("条目 %v / 在途 %v", ok, inflight)
	}
	if out := prefetchImportOne(context.Background(), prefetchImportItem{Artist: rescoreTestArtist, Title: "IMPORT SONG", Album: "Import Album"}); out.started {
		t.Fatal("已有等价写法的不该再起")
	}
}

// 有源的小时额度不够一首用时先等腾出余量,再起这一首;等完照旧从这一首接着跑。
func TestRunPrefetchImportWaitsForBudget(t *testing.T) {
	var seen []string
	setupPrefetchImportTest(t, []string{`{"artist":"A","title":"One","album":"X"}`},
		func(_ context.Context, it prefetchImportItem) prefetchImportOutcome {
			seen = append(seen, it.Title)
			return prefetchImportOutcome{started: true}
		})
	var waits []time.Duration
	prefetchImportWait = func(_ context.Context, d time.Duration) { waits = append(waits, d) }
	budget := []time.Duration{90 * time.Second, 0}
	savedBudget := prefetchImportBudget
	t.Cleanup(func() { prefetchImportBudget = savedBudget })
	prefetchImportBudget = func() time.Duration {
		d := budget[0]
		budget = budget[1:]
		return d
	}
	runPrefetchImport(context.Background())
	if len(seen) != 1 || len(waits) < 1 || waits[0] != 90*time.Second {
		t.Fatalf("跑了 %v,等了 %v", seen, waits)
	}
}
