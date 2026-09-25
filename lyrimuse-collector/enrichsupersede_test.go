package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func enrichStampNow() uint64 {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	return enrichEditStampLocked()
}

// 首次解析跑着的时候条目被删:那一轮(包括被这次删除取消后的收尾)不能把它写回;删完之后新开的一轮照常落盘。
func TestResolveRoundDroppedAfterDelete(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {Lyrics: "[00:01.00]早提交的歌词", TS: 1}})
	stamp := enrichStampNow()
	if res := applyEnrichEdit(enrichEditRequest{Op: "delete", Keys: []string{editKey}}); !res.OK || res.Changed != 1 {
		t.Fatalf("delete: %+v", res)
	}
	commitEnrichEntrySince(editKey, enrichEntry{Lyrics: "[00:01.00]早提交的歌词", TS: 2}, stamp)
	if _, ok := cacheEntry(t, editKey); ok {
		t.Fatal("删除之前开跑的那一轮不该把条目写回")
	}
	commitEnrichEntrySince(editKey, enrichEntry{Lyrics: "[00:01.00]重新解析", TS: 3}, enrichStampNow())
	if e, ok := cacheEntry(t, editKey); !ok || e.TS != 3 {
		t.Fatalf("删除之后新开的一轮要照常落盘 got %+v ok=%v", e, ok)
	}
}

// 采纳候选(开关关着,不置 ManualLyrics)之后,之前开跑的那一轮落盘作废,别的歌不受影响。
func TestResolveRoundDroppedAfterSaveEdit(t *testing.T) {
	other := enrichKey("Other Artist", "Other Song", "")
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {Lyrics: "[00:01.00]自动", TS: 1}})
	stamp := enrichStampNow()
	res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]采纳的", FromManualPick: true})
	if !res.OK {
		t.Fatalf("save_edit: %+v", res)
	}
	commitEnrichEntrySince(editKey, enrichEntry{Lyrics: "[00:01.00]自动", TS: 2}, stamp)
	if e, _ := cacheEntry(t, editKey); e.Lyrics != "[00:01.00]采纳的" {
		t.Fatalf("刚采纳的歌词被换掉了: %q", e.Lyrics)
	}
	commitEnrichEntrySince(other, enrichEntry{Lyrics: "[00:01.00]别的", TS: 2}, stamp)
	if _, ok := cacheEntry(t, other); !ok {
		t.Fatal("没被改过的歌照常落盘")
	}
}

// 清空之前开跑的每一轮都作废,不论 key 当时在不在缓存里。
func TestResolveRoundDroppedAfterClearAll(t *testing.T) {
	fresh := enrichKey("Fresh Artist", "Fresh Song", "")
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {Lyrics: "[00:01.00]x", TS: 1}})
	stamp := enrichStampNow()
	if res := applyEnrichEdit(enrichEditRequest{Op: "clear_all"}); !res.OK {
		t.Fatalf("clear_all: %+v", res)
	}
	commitEnrichEntrySince(editKey, enrichEntry{Lyrics: "[00:01.00]x", TS: 2}, stamp)
	commitEnrichEntrySince(fresh, enrichEntry{Lyrics: "[00:01.00]y", TS: 2}, stamp)
	enrichMu.Lock()
	n := len(enrichCache)
	enrichMu.Unlock()
	if n != 0 {
		t.Fatalf("清空之前开跑的轮次不该写回, 缓存里还有 %d 条", n)
	}
}

// 失败的改动不算改动:那一轮照常落盘。
func TestFailedEditDoesNotSupersede(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{})
	stamp := enrichStampNow()
	if res := applyEnrichEdit(enrichEditRequest{Op: "save_edit"}); res.OK {
		t.Fatal("空 key 的 save_edit 应该失败")
	}
	commitEnrichEntrySince(editKey, enrichEntry{Lyrics: "[00:01.00]x", TS: 2}, stamp)
	if _, ok := cacheEntry(t, editKey); !ok {
		t.Fatal("没有改动成功时不该作废这一轮")
	}
}

// App 没等到就走了的结果文件,过期后清掉;新的留着给 App 读。
func TestProcessEnrichEditRequestsRemovesStaleResults(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{})
	enrichEditDir = t.TempDir()
	stale := filepath.Join(enrichEditDir, "0001-a.result.json")
	fresh := filepath.Join(enrichEditDir, "0002-b.result.json")
	for _, p := range []string{stale, fresh} {
		if err := os.WriteFile(p, []byte(`{"ok":true}`), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-2 * enrichEditStaleAfter)
	_ = os.Chtimes(stale, old, old)

	processEnrichEditRequests()

	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("过期的结果文件应删掉")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Error("新的结果文件要留着给 App 读")
	}
}

// 升级重试 / 重评分要跑整轮联网检索,行为上测不到,按源码钉住:开跑时记序号,写回前核对。
func TestRetryAndRescoreCheckEditStamp(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range []string{"func retryLyricsUpgrade(", "func rescoreLyrics("} {
		body := string(src)
		i := strings.Index(body, fn)
		if i < 0 {
			t.Fatalf("找不到 %s", fn)
		}
		body = body[i+len(fn):]
		if j := strings.Index(body, "\nfunc "); j >= 0 {
			body = body[:j]
		}
		if !strings.Contains(body, "stamp := enrichEditStampLocked()") ||
			!strings.Contains(body, "enrichEditedSinceLocked(key, stamp)") {
			t.Errorf("%s 没有核对改动序号:跑着的时候用户采纳的候选会被这一轮换掉", fn)
		}
	}
}

// 不导出文件的单条改动(标纯音乐、存纯文本、记判决)同样作废之前开跑的那一轮:不然纯音乐标记会被整条覆盖掉。
func TestResolveRoundDroppedAfterSetInstrumental(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {TS: 1}})
	stamp := enrichStampNow()
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: editKey, Value: true}); !res.OK {
		t.Fatalf("set_instrumental: %+v", res)
	}
	commitEnrichEntrySince(editKey, enrichEntry{TS: 2}, stamp)
	if e, _ := cacheEntry(t, editKey); !e.Instrumental {
		t.Fatal("刚标上的纯音乐被之前开跑的那一轮盖掉了")
	}
}
