package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 一页 recenttracks 的样本(字段形状照 Last.fm 真实响应:数字全是字符串、now-playing 行
// 没有 date 只有 @attr.nowplaying、image 是按 size 分档的数组)。歌名全是合成的。
const sampleRecentJSON = `{"recenttracks":{"track":[
 {"artist":{"#text":"A"},"name":"Now","album":{"#text":"NP"},
  "image":[{"size":"small","#text":"s.png"},{"size":"large","#text":"l-np.png"}],
  "@attr":{"nowplaying":"true"}},
 {"artist":{"#text":"B"},"name":"One","album":{"#text":"Alb"},
  "image":[{"size":"small","#text":"s1.png"},{"size":"extralarge","#text":"xl1.png"}],
  "date":{"uts":"1700000100"}},
 {"artist":{"#text":"C"},"name":"Two","album":{"#text":""},
  "image":[{"size":"small","#text":"only-small.png"}],
  "date":{"uts":"1700000000"}},
 {"artist":{"#text":"D"},"name":"","date":{"uts":"1699999999"}}
],"@attr":{"user":"u","totalPages":"486","page":"1","perPage":"50","total":"24271"}}}`

func TestParseLastfmRecent(t *testing.T) {
	page, err := parseLastfmRecent([]byte(sampleRecentJSON))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if page.Total != 24271 {
		t.Fatalf("total: got %d want 24271", page.Total)
	}
	if page.NowPlaying == nil || page.NowPlaying.Title != "Now" || page.NowPlaying.Image != "l-np.png" {
		t.Fatalf("now playing: %+v", page.NowPlaying)
	}
	if len(page.Done) != 2 {
		t.Fatalf("done rows: got %d want 2 (空歌名那行要丢掉)", len(page.Done))
	}
	// large 缺席退 extralarge;只有 small 时退最后一档。
	if page.Done[0].Image != "xl1.png" || page.Done[1].Image != "only-small.png" {
		t.Fatalf("image pick: %q %q", page.Done[0].Image, page.Done[1].Image)
	}
	if page.Done[0].UTS != 1700000100 || page.Done[1].UTS != 1700000000 {
		t.Fatalf("uts: %d %d", page.Done[0].UTS, page.Done[1].UTS)
	}
}

func TestLastfmFeedInterval(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	if got := lastfmFeedInterval(true, time.Time{}, now); got != feedIntervalActive {
		t.Fatalf("本机在放应当 15s,got %v", got)
	}
	if got := lastfmFeedInterval(false, now.Add(-5*time.Minute), now); got != feedIntervalActive {
		t.Fatalf("5 分钟内有动静应当 15s,got %v", got)
	}
	if got := lastfmFeedInterval(false, now.Add(-11*time.Minute), now); got != feedIntervalIdle {
		t.Fatalf("11 分钟没动静应当 60s,got %v", got)
	}
	if got := lastfmFeedInterval(false, time.Time{}, now); got != feedIntervalIdle {
		t.Fatalf("从没有过记录应当 60s,got %v", got)
	}
}

func TestLastfmFeedActivityAt(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	np := &lastfmTrack{Title: "x"}
	if got := lastfmFeedActivityAt(lastfmRecentPage{NowPlaying: np}, now); !got.Equal(now) {
		t.Fatalf("有 now-playing 应当算此刻,got %v", got)
	}
	page := lastfmRecentPage{Done: []lastfmTrack{{UTS: 1700000100}, {UTS: 1700000000}}}
	if got := lastfmFeedActivityAt(page, now); got.Unix() != 1700000100 {
		t.Fatalf("没 now-playing 应当取最新一条 scrobble,got %v", got)
	}
	if got := lastfmFeedActivityAt(lastfmRecentPage{}, now); !got.IsZero() {
		t.Fatalf("空页应当零值,got %v", got)
	}
}

func TestShouldWriteLastfmFeed(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	if !shouldWriteLastfmFeed("a", "b", now, now) {
		t.Fatal("内容变了必须写")
	}
	if shouldWriteLastfmFeed("a", "a", now.Add(-30*time.Second), now) {
		t.Fatal("内容没变、30s 内写过:不该重写")
	}
	if !shouldWriteLastfmFeed("a", "a", now.Add(-feedHeartbeat), now) {
		t.Fatal("内容没变但满一个心跳周期:该写")
	}
	if !shouldWriteLastfmFeed("", "", time.Time{}, now) {
		t.Fatal("从没写过:该写")
	}
}

func TestLastfmFeedContentKeyIgnoresImageAndAlbum(t *testing.T) {
	a := lastfmRecentPage{Total: 1, Done: []lastfmTrack{{Title: "t", UTS: 5, Image: "x", Album: "p"}}}
	b := lastfmRecentPage{Total: 1, Done: []lastfmTrack{{Title: "t", UTS: 5, Image: "y", Album: "q"}}}
	if lastfmFeedContentKey(a) != lastfmFeedContentKey(b) {
		t.Fatal("image/album 不该参与内容键")
	}
	c := lastfmRecentPage{Total: 2, Done: a.Done}
	if lastfmFeedContentKey(a) == lastfmFeedContentKey(c) {
		t.Fatal("total 变了必须算内容变化")
	}
	d := lastfmRecentPage{Total: 1, NowPlaying: &lastfmTrack{Artist: "x", Title: "y"}, Done: a.Done}
	if lastfmFeedContentKey(a) == lastfmFeedContentKey(d) {
		t.Fatal("now-playing 出现必须算内容变化")
	}
}

func TestWriteLastfmRecentFeedShape(t *testing.T) {
	dir := t.TempDir()
	prevPath, prevKey, prevWrite := lastfmFeedPath, lastfmFeedLastKey, lastfmFeedLastWrite
	t.Cleanup(func() { lastfmFeedPath, lastfmFeedLastKey, lastfmFeedLastWrite = prevPath, prevKey, prevWrite })
	lastfmFeedPath = filepath.Join(dir, "feed.json")
	lastfmFeedLastKey, lastfmFeedLastWrite = "", time.Time{}

	page, err := parseLastfmRecent([]byte(sampleRecentJSON))
	if err != nil {
		t.Fatal(err)
	}
	at := time.Unix(1_800_000_000, 0)
	writeLastfmRecentFeed("KhalilChan3", page, at)
	raw, err := os.ReadFile(lastfmFeedPath)
	if err != nil {
		t.Fatalf("feed 文件没写出来: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("feed 不是合法 JSON: %v", err)
	}
	// 字段名是 App 侧(LastfmRecentFeed.swift)逐字对应的契约。
	for _, k := range []string{"username", "fetchedAt", "total", "nowPlaying", "tracks"} {
		if _, ok := got[k]; !ok {
			t.Fatalf("缺字段 %q: %s", k, raw)
		}
	}
	if got["username"] != "KhalilChan3" || got["total"].(float64) != 24271 || got["fetchedAt"].(float64) != 1_800_000_000 {
		t.Fatalf("头部字段不对: %s", raw)
	}
	tracks := got["tracks"].([]any)
	if len(tracks) != 2 {
		t.Fatalf("tracks 应当只含已完成的 2 条: %s", raw)
	}
	first := tracks[0].(map[string]any)
	if first["uts"].(float64) != 1700000100 || first["image"] != "xl1.png" || first["album"] != "Alb" {
		t.Fatalf("首行字段不对: %v", first)
	}
	np := got["nowPlaying"].(map[string]any)
	if _, has := np["uts"]; has {
		t.Fatalf("now-playing 行不该带 uts: %v", np)
	}

	// 内容没变、心跳未到:不重写(mtime 不动)。
	info1, _ := os.Stat(lastfmFeedPath)
	writeLastfmRecentFeed("KhalilChan3", page, at.Add(10*time.Second))
	info2, _ := os.Stat(lastfmFeedPath)
	if !info1.ModTime().Equal(info2.ModTime()) {
		t.Fatal("内容没变、10s 内不该重写")
	}
	// 没有 now-playing 了 → 内容变了 → 重写,且 nowPlaying 键消失。
	page.NowPlaying = nil
	writeLastfmRecentFeed("KhalilChan3", page, at.Add(20*time.Second))
	raw, _ = os.ReadFile(lastfmFeedPath)
	got = map[string]any{}
	_ = json.Unmarshal(raw, &got)
	if _, has := got["nowPlaying"]; has {
		t.Fatalf("停播后 nowPlaying 键应当省略: %s", raw)
	}
	if _, err := os.Stat(filepath.Join(dir, ".feed.json.tmp")); !os.IsNotExist(err) {
		t.Fatal("临时文件应当被 rename 掉")
	}
}

func TestLastfmFeedNudge(t *testing.T) {
	lastfmFeedNudgeAt.Store(0)
	t.Cleanup(func() { lastfmFeedNudgeAt.Store(0) })
	if lastfmFeedNudgeDue(time.Now()) {
		t.Fatal("没有请求时不该到期")
	}
	requestLastfmFeedRefresh(5 * time.Second)
	if lastfmFeedNudgeDue(time.Now()) {
		t.Fatal("5s 之内不该到期")
	}
	// 更晚的第二次请求不能把已有的更早待办推后。
	first := lastfmFeedNudgeAt.Load()
	requestLastfmFeedRefresh(30 * time.Second)
	if lastfmFeedNudgeAt.Load() != first {
		t.Fatal("更晚的请求不该推后已有待办")
	}
	if !lastfmFeedNudgeDue(time.Now().Add(6 * time.Second)) {
		t.Fatal("6s 后应当到期")
	}
	if lastfmFeedNudgeDue(time.Now().Add(7 * time.Second)) {
		t.Fatal("到期一次就该被消费掉")
	}
}

// 跨进程信号文件(2026-09-03):回填子命令 touch、常驻进程消费。钉三件事:没文件不触发;
// touch 之后恰好触发一次并把文件删掉;路径为空(单测/未配置)整个通道关闭、touch 也不写。
func TestLastfmFeedNudgeFile(t *testing.T) {
	saved := lastfmFeedNudgePath
	defer func() { lastfmFeedNudgePath = saved }()

	lastfmFeedNudgePath = ""
	touchLastfmFeedNudgeFile()
	if lastfmFeedNudgeFileDue() {
		t.Fatal("路径为空时通道应关闭")
	}

	lastfmFeedNudgePath = filepath.Join(t.TempDir(), "feed-nudge")
	if lastfmFeedNudgeFileDue() {
		t.Fatal("没有信号文件不该触发")
	}
	touchLastfmFeedNudgeFile()
	if _, err := os.Stat(lastfmFeedNudgePath); err != nil {
		t.Fatalf("touch 后文件应存在: %v", err)
	}
	if !lastfmFeedNudgeFileDue() {
		t.Fatal("touch 后应触发一次")
	}
	if _, err := os.Stat(lastfmFeedNudgePath); !os.IsNotExist(err) {
		t.Fatalf("触发后信号文件应被消费(删除),stat err=%v", err)
	}
	if lastfmFeedNudgeFileDue() {
		t.Fatal("消费过一次之后不该再触发")
	}
}

// 回填的跨进程信号必须走**延迟**拉取,不能当场拉(2026-09-12)。
//
// 这是「补提交之后下面的列表没刷新」第三次被报出来的根因。bridge() 原来把
// lastfmFeedNudgeFileDue() 直接摆进"要不要现在拉"的或条件里,信号一到就立刻拉一次 ——
// 而那一刻 Last.fm 还没把刚补进去的 scrobble 并进 recenttracks,拉回来的是旧内容,却照样
// 把 feed 的 fetchedAt 刷成此刻。App 侧那道「feed 不新鲜才补一发强刷」的兜底判据是
// fetchedAt 落在 180 s 窗口内,于是永远判"新鲜"、永远不触发;而 feed 只要 collector 活着
// 就每 feedHeartbeat 重写一次,fetchedAt 跟内容变没变根本无关。两头一叠,用户只能干等
// 下一个 15 s/60 s 周期 —— 表现就是"点了补提交,下面的列表半天不动"。
//
// 钉的是:信号在、周期没到 → 这一拍**不拉**,但排下一个 backfillFeedNudgeDelay 之后到期的请求。
func TestBackfillFeedNudgeIsDelayedNotImmediate(t *testing.T) {
	savedPath := lastfmFeedNudgePath
	lastfmFeedNudgeAt.Store(0)
	t.Cleanup(func() {
		lastfmFeedNudgePath = savedPath
		lastfmFeedNudgeAt.Store(0)
	})
	lastfmFeedNudgePath = filepath.Join(t.TempDir(), "feed-nudge")

	if backfillFeedNudgeDelay <= 0 {
		t.Fatalf("回填信号必须带延迟,当前 %v", backfillFeedNudgeDelay)
	}

	now := time.Now()
	p := &poller{
		ctx: context.Background(),
		cfg: &config{LastfmUser: "someone", LastfmAPIKey: "key"},
		// 周期刚走过,这一拍唯一可能的触发源就是信号文件。
		lastfmCheckedAt: now,
	}
	touchLastfmFeedNudgeFile()
	p.bridge(now)

	if p.bridgeFetching {
		t.Fatal("回填信号不该让这一拍就去拉 feed —— 那一刻 Last.fm 还没并进去,拉回来的是旧内容")
	}
	if _, err := os.Stat(lastfmFeedNudgePath); !os.IsNotExist(err) {
		t.Fatalf("信号文件应当已被消费掉,stat err=%v", err)
	}
	if lastfmFeedNudgeDue(now) {
		t.Fatal("延迟还没到就不该到期")
	}
	if !lastfmFeedNudgeDue(now.Add(backfillFeedNudgeDelay + time.Second)) {
		t.Fatal("延迟到了之后应当到期一次")
	}
}
