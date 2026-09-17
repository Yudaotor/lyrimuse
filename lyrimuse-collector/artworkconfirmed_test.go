package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// 写一份确认记录到磁盘,供下面几个用例当"上一次运行留下的状态"。
func writeConfirmFile(t *testing.T, path, relay string, entries map[string]int64) {
	t.Helper()
	b, err := json.Marshal(artworkConfirmFile{Relay: relay, Confirmed: entries})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// 确认记录要能落盘再读回来,并把没过期的那些灌进 artworkUploaded ——
// 补传扫描据此跳过它们,这正是这次改动省下来的那几百次 KV 读。
func TestArtworkConfirmedRoundTrip(t *testing.T) {
	resetArtworkRelayState(t)
	artworkRelayURL = "https://relay.invalid"
	artworkConfirmPath = filepath.Join(t.TempDir(), "confirmed.json")

	markArtworkConfirmed(testSHA)
	flushArtworkConfirmed()

	// 模拟重启:内存清空,只剩磁盘上那份。
	artworkMu.Lock()
	artworkUploaded = map[string]bool{}
	artworkMu.Unlock()
	artworkConfirmMu.Lock()
	artworkConfirmAt = map[string]int64{}
	artworkConfirmMu.Unlock()

	loadArtworkConfirmed()

	artworkMu.Lock()
	defer artworkMu.Unlock()
	if !artworkUploaded[testSHA] {
		t.Error("重启后该从磁盘读回已确认集合,否则补传扫描又要把整个目录 HEAD 一遍")
	}
}

// 过期条目不算数:中继侧真被清空时,漂移窗口必须有上界(见 artworkconfirmed.go 头注)。
func TestArtworkConfirmedExpires(t *testing.T) {
	resetArtworkRelayState(t)
	artworkRelayURL = "https://relay.invalid"
	artworkConfirmPath = filepath.Join(t.TempDir(), "confirmed.json")
	old := time.Now().Add(-artworkConfirmTTL - time.Hour).Unix()
	writeConfirmFile(t, artworkConfirmPath, artworkRelayURL, map[string]int64{testSHA: old})

	loadArtworkConfirmed()

	artworkMu.Lock()
	defer artworkMu.Unlock()
	if artworkUploaded[testSHA] {
		t.Error("超过 TTL 的确认不该再算数,该重新 HEAD 确认一遍")
	}
}

// 换了中继地址(换自己的 worker / 换账号)整份作废:旧确认对新中继毫无意义,
// 照单全收的话新中继上明明没有的图会被当成"有",网页那边直接 404。
func TestArtworkConfirmedInvalidatedOnRelayChange(t *testing.T) {
	resetArtworkRelayState(t)
	artworkConfirmPath = filepath.Join(t.TempDir(), "confirmed.json")
	writeConfirmFile(t, artworkConfirmPath, "https://old-relay.invalid",
		map[string]int64{testSHA: time.Now().Unix()})
	artworkRelayURL = "https://new-relay.invalid"

	loadArtworkConfirmed()

	artworkMu.Lock()
	defer artworkMu.Unlock()
	if artworkUploaded[testSHA] {
		t.Error("中继地址变了就该把旧确认整份作废")
	}
}

// 本次改动的正题:有新鲜确认记录时,启动补传扫描一次网络请求都不该发。
// 改动前这里会是每张一次 HEAD(本机 713 张 × 每天十几次重启 ≈ 每天上万次 KV 读)。
func TestSweepSkipsConfirmedFromDisk(t *testing.T) {
	resetArtworkRelayState(t)
	var mu sync.Mutex
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits++
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	artworkRelayURL = srv.URL

	dir := t.TempDir()
	deviceArtworkDir = dir
	const other = "0011223344556677"
	for _, name := range []string{testSHA + ".jpg", other + ".png"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	artworkConfirmPath = filepath.Join(t.TempDir(), "confirmed.json")
	now := time.Now().Unix()
	writeConfirmFile(t, artworkConfirmPath, srv.URL, map[string]int64{testSHA: now, other: now})

	loadArtworkConfirmed()
	sweepDeviceArtwork(context.Background())

	mu.Lock()
	defer mu.Unlock()
	if hits != 0 {
		t.Errorf("确认记录还新鲜时补传扫描不该再发请求, 实发 %d 次", hits)
	}
}

// 只确认了一半时,另一半照旧要 HEAD —— 不能因为有记录文件就整轮跳过。
func TestSweepStillChecksUnconfirmed(t *testing.T) {
	resetArtworkRelayState(t)
	var mu sync.Mutex
	seen := map[string]bool{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen[r.URL.Path] = true
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	artworkRelayURL = srv.URL

	dir := t.TempDir()
	deviceArtworkDir = dir
	const other = "0011223344556677"
	for _, name := range []string{testSHA + ".jpg", other + ".png"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	artworkConfirmPath = filepath.Join(t.TempDir(), "confirmed.json")
	writeConfirmFile(t, artworkConfirmPath, srv.URL, map[string]int64{testSHA: time.Now().Unix()})

	loadArtworkConfirmed()
	sweepDeviceArtwork(context.Background())

	mu.Lock()
	defer mu.Unlock()
	if seen["/artwork/"+testSHA+".jpg"] {
		t.Error("已确认的那张不该再问一次")
	}
	if !seen["/artwork/"+other+".png"] {
		t.Error("没确认过的那张必须照旧 HEAD 确认")
	}

	// 这一轮新确认的也要落盘,否则下次重启还得再问一遍。
	artworkConfirmMu.Lock()
	_, ok := artworkConfirmAt[other]
	artworkConfirmMu.Unlock()
	if !ok {
		t.Error("扫描里新确认的应该进确认记录")
	}
	b, err := os.ReadFile(artworkConfirmPath)
	if err != nil {
		t.Fatal(err)
	}
	var f artworkConfirmFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if _, ok := f.Confirmed[other]; !ok {
		t.Error("扫描收尾的 defer flush 没把新确认写进磁盘")
	}
}

// 尾部斜杠不算换中继:配置里多打一个 "/" 就把记录整份丢掉的话,这个修复会静默失效
// (每次启动照旧全量 HEAD),而且只在日志里留一行。
func TestArtworkConfirmedIgnoresTrailingSlash(t *testing.T) {
	resetArtworkRelayState(t)
	artworkConfirmPath = filepath.Join(t.TempDir(), "confirmed.json")
	writeConfirmFile(t, artworkConfirmPath, "https://relay.invalid",
		map[string]int64{testSHA: time.Now().Unix()})
	artworkRelayURL = "https://relay.invalid/"

	loadArtworkConfirmed()

	artworkMu.Lock()
	defer artworkMu.Unlock()
	if !artworkUploaded[testSHA] {
		t.Error("只是尾部多个斜杠,不该判成换了中继")
	}
}

// 没配状态中继时这条路整条不存在:不读盘、不预热、不写盘。绝大多数用户属于这一档
// (只用本机悬浮歌词,不搭自己的网页中继),对他们必须是零额外动作。
func TestArtworkConfirmedInertWithoutRelay(t *testing.T) {
	resetArtworkRelayState(t)
	artworkRelayURL = "" // 用户没填「状态中继地址」
	dir := t.TempDir()
	artworkConfirmPath = filepath.Join(dir, "confirmed.json")
	// 磁盘上有一份完全有效的记录(比如用户曾经配过中继、后来把地址删了)。
	writeConfirmFile(t, artworkConfirmPath, "https://relay.invalid",
		map[string]int64{testSHA: time.Now().Unix()})

	loadArtworkConfirmed()
	artworkMu.Lock()
	seeded := len(artworkUploaded)
	artworkMu.Unlock()
	if seeded != 0 {
		t.Errorf("没配中继时不该读回任何确认记录, 却灌进了 %d 条", seeded)
	}

	markArtworkConfirmed(testSHA)
	flushArtworkConfirmed()
	artworkConfirmMu.Lock()
	n := len(artworkConfirmAt)
	artworkConfirmMu.Unlock()
	if n != 0 {
		t.Errorf("没配中继时不该记任何确认, 却记了 %d 条", n)
	}
	// 文件必须原封不动 —— 没配中继就不该往用户盘上写任何东西。
	b, err := os.ReadFile(artworkConfirmPath)
	if err != nil {
		t.Fatal(err)
	}
	var f artworkConfirmFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if f.Relay != "https://relay.invalid" || len(f.Confirmed) != 1 {
		t.Errorf("没配中继时不该改写磁盘上那份记录, 现在是 %+v", f)
	}
}

// 没配中继时,启动补传扫描一次请求都不发、也不排任何上传。
func TestSweepInertWithoutRelay(t *testing.T) {
	resetArtworkRelayState(t)
	var mu sync.Mutex
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits++
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	artworkRelayURL = "" // 关键:地址为空

	dir := t.TempDir()
	deviceArtworkDir = dir
	if err := os.WriteFile(filepath.Join(dir, testSHA+".jpg"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	sweepDeviceArtwork(context.Background())
	// webSafeCoverURL 也是同一条门:返回空串(绝不透传 file://),且不排上传。
	if got := webSafeCoverURL(deviceArtworkURLPrefix + filepath.Join(dir, testSHA+".jpg")); got != "" {
		t.Errorf("没配中继时不该给出任何中继 URL, got %q", got)
	}

	mu.Lock()
	defer mu.Unlock()
	if hits != 0 {
		t.Errorf("没配中继时不该发任何请求, 实发 %d 次", hits)
	}
}
