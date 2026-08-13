package main

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

// 这一组守的是"绝不重复提交"那条线。scrobble 落进 Last.fm 基本删不掉,所以下面每个用例
// 对应的都是一种"会造成永久污染"的具体走法,不是凑覆盖率。

func TestParseScrobbleEntries_SingleIsObjectNotArray(t *testing.T) {
	// Last.fm 的 JSON:一条时 scrobble 是**对象**,多条时是**数组**。只处理数组的实现
	// 会在"只补一首歌"这个最常见的收尾批次上拿不到任何回执 —— 那批会被全部判成状态未知,
	// 白白进隔离区再也不补。
	one := json.RawMessage(`{"timestamp":"1700000000","ignoredMessage":{"code":"0","#text":""}}`)
	got := parseScrobbleEntries(one)
	if len(got) != 1 || got[0].Timestamp != "1700000000" {
		t.Fatalf("single object form not parsed: %+v", got)
	}

	many := json.RawMessage(`[{"timestamp":"1","ignoredMessage":{"code":"0","#text":""}},` +
		`{"timestamp":"2","ignoredMessage":{"code":"0","#text":""}}]`)
	if got := parseScrobbleEntries(many); len(got) != 2 {
		t.Fatalf("array form not parsed: %+v", got)
	}

	if got := parseScrobbleEntries(json.RawMessage(`"garbage"`)); len(got) != 0 {
		t.Fatalf("unparseable payload should yield nothing, got %+v", got)
	}
}

func TestPendingBackfill_ExcludesSubmittedAndQuarantined(t *testing.T) {
	dir := t.TempDir()
	saved := listenLogPath
	defer func() { listenLogPath = saved }()
	listenLogPath = filepath.Join(dir, "l.jsonl")

	now := time.Now()
	fresh := now.Add(-1 * time.Hour).Unix()

	appendListen("A", "unsubmitted", "al", fresh, 200)
	appendListen("B", "already-submitted", "al", fresh+1, 200)
	appendListen("C", "quarantined", "al", fresh+2, 200)
	markBackfilled(fresh + 1)
	markQuarantined(fresh + 2)

	pending, tooOld := pendingBackfillListens(now)
	if tooOld != 0 {
		t.Errorf("tooOld should be 0, got %d", tooOld)
	}
	if len(pending) != 1 || pending[0].TI != "unsubmitted" {
		t.Fatalf("want only the unsubmitted listen, got %+v", pending)
	}
	// 隔离必须被当成"别再动它" —— 自动重试等于把一次超时变成一条永久重复。
	for _, p := range pending {
		if p.TI == "quarantined" {
			t.Fatal("a quarantined listen must never be picked up again automatically")
		}
	}
}

func TestPendingBackfill_SkipsTooOldAndSortsAscending(t *testing.T) {
	dir := t.TempDir()
	saved := listenLogPath
	defer func() { listenLogPath = saved }()
	listenLogPath = filepath.Join(dir, "l.jsonl")

	now := time.Now()
	// 超出 Last.fm 回溯窗口 —— 发出去只会被服务端静默忽略,还占一次尝试。
	appendListen("Old", "way too old", "", now.Add(-30*24*time.Hour).Unix(), 200)
	// 乱序写入,期望按 uts 升序读出(官方指南:cached scrobbles 要按顺序发)。
	appendListen("C", "third", "", now.Add(-1*time.Hour).Unix(), 200)
	appendListen("A", "first", "", now.Add(-3*time.Hour).Unix(), 200)
	appendListen("B", "second", "", now.Add(-2*time.Hour).Unix(), 200)
	// 太短,不算一次收听 —— 日志可能被手工编辑过,读侧要自己复核一遍。
	appendListen("Short", "tiny", "", now.Add(-30*time.Minute).Unix(), 5)

	pending, tooOld := pendingBackfillListens(now)
	if tooOld != 1 {
		t.Errorf("want 1 too-old listen, got %d", tooOld)
	}
	var order []string
	for _, p := range pending {
		order = append(order, p.TI)
	}
	if len(order) != 3 || order[0] != "first" || order[1] != "second" || order[2] != "third" {
		t.Fatalf("want first,second,third in ascending uts order, got %v", order)
	}
}

func TestScrobbleBatch_RejectsOversizedBatch(t *testing.T) {
	// 超过 50 条是协议违规;宁可在本地报错,也不要让服务端对一个畸形请求做出不可预测的
	// 部分处理 —— 那种情况下我们无法判断哪几条落库了。
	s := &lastfmScrobbler{apiKey: "k", secret: "s", sk: "sk"}
	items := make([]listenLogLine, backfillBatchSize+1)
	if _, err := s.scrobbleBatch(nil, items); err == nil {
		t.Fatal("oversized batch must be rejected before any request is sent")
	}
}

func TestDryRunReturnsListNewestFirst(t *testing.T) {
	// 未连接那一栏要按歌名把本地记录列出来 —— 光说"会记在本地"是空头承诺,用户没法核对。
	// 清单要**最近的排最前**(而提交顺序必须是最旧的先发,两者相反,容易写错)。
	dir := t.TempDir()
	saved := listenLogPath
	defer func() { listenLogPath = saved }()
	listenLogPath = filepath.Join(dir, "l.jsonl")

	now := time.Now()
	appendListen("A", "oldest", "al1", now.Add(-3*time.Hour).Unix(), 200)
	appendListen("B", "middle", "", now.Add(-2*time.Hour).Unix(), 200)
	appendListen("C", "newest", "al3", now.Add(-1*time.Hour).Unix(), 200)

	out := runBackfill(context.Background(), nil, true)
	if out.Eligible != 3 || len(out.Items) != 3 {
		t.Fatalf("want 3 eligible and 3 items, got %d/%d", out.Eligible, len(out.Items))
	}
	if out.Items[0].Title != "newest" || out.Items[2].Title != "oldest" {
		t.Fatalf("items must be newest-first, got %s…%s", out.Items[0].Title, out.Items[2].Title)
	}
	// 清单要带够界面显示的字段
	if out.Items[0].Artist != "C" || out.Items[0].Album != "al3" || out.Items[0].UTS == 0 {
		t.Fatalf("item missing display fields: %+v", out.Items[0])
	}
	// dry-run 绝不能碰账号 —— 这里连 scrobbler 都传的 nil,能跑通就说明它没走提交路径。
	if out.Accepted != 0 || out.Quarantined != 0 {
		t.Fatalf("dry run must not submit anything: %+v", out)
	}
}
