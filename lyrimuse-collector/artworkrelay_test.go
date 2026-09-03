package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// 每个用例都得把这一组进程级状态复位——它们是包级变量,用例之间会互相串。
//
// ⚠️ 退出前必须**等后台上传排空**。scheduleArtworkUpload 起的 goroutine 是在自己跑起来
// 之后才去读包级的 artworkRelayURL 的,所以上一个用例排下的上传,可能等到下一个用例把
// artworkRelayURL 指向**它自己的** httptest 服务器之后才发出请求 —— 表现就是下一个用例
// 平白多收到一次 HEAD(`-count=25` 压出来的:heads = 2)。
// 生产里这个变量在 main() 里设一次就再也不变,不存在这个问题,是测试特有的。
func resetArtworkRelayState(t *testing.T) {
	t.Helper()
	artworkMu.Lock()
	oldURL, oldToken := artworkRelayURL, artworkRelayToken
	oldDir := deviceArtworkDir
	artworkUploaded = map[string]bool{}
	artworkInflight = map[string]bool{}
	artworkNextRetry = map[string]time.Time{}
	artworkMu.Unlock()
	t.Cleanup(func() {
		waitArtworkIdle(t)
		artworkMu.Lock()
		artworkRelayURL, artworkRelayToken, deviceArtworkDir = oldURL, oldToken, oldDir
		artworkUploaded = map[string]bool{}
		artworkInflight = map[string]bool{}
		artworkNextRetry = map[string]time.Time{}
		artworkMu.Unlock()
	})
}

// waitArtworkIdle 等到没有在飞的上传。等不到就报错——那说明真漏了个 goroutine,
// 悄悄放过去只会让下一个用例莫名其妙地红。
func waitArtworkIdle(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		artworkMu.Lock()
		n := len(artworkInflight)
		artworkMu.Unlock()
		if n == 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Error("退出时仍有上传在飞,会污染下一个用例")
}

const testSHA = "567de5eb77440ca8" // 真实存在过的一张(用户那首「死神」的封面)

func TestDeviceArtworkRef(t *testing.T) {
	cases := []struct {
		name, in string
		wantSHA  string
		wantOK   bool
	}{
		{"正常 jpg", "file:///Users/x/.config/lyrimuse/artwork/" + testSHA + ".jpg", testSHA, true},
		{"正常 png", "file:///Users/x/.config/lyrimuse/artwork/" + testSHA + ".png", testSHA, true},
		{"远程 http 不认", "https://p1.music.126.net/x.jpg", "", false},
		{"空串不认", "", "", false},
		// 下面三条是"认错的代价不对称"那条注释在守的东西:误认会把本机路径当 sha 发出去。
		{"后缀不对不认", "file:///Users/x/artwork/" + testSHA + ".webp", "", false},
		{"文件名不是十六进制不认", "file:///Users/x/artwork/my-cover.jpg", "", false},
		{"十六进制但长度不对不认", "file:///Users/x/artwork/abc123.jpg", "", false},
		{"大写十六进制不认(落盘用的是小写)", "file:///Users/x/artwork/567DE5EB77440CA8.jpg", "", false},
	}
	for _, c := range cases {
		sha, _, ok := deviceArtworkRef(c.in)
		if ok != c.wantOK || sha != c.wantSHA {
			t.Errorf("%s: deviceArtworkRef(%q) = (%q, %v), want (%q, %v)", c.name, c.in, sha, ok, c.wantSHA, c.wantOK)
		}
	}
}

// 这个函数是整条修复的闸门:任何情况下都不许把 file:// 原样放出去。
func TestWebSafeCoverURLNeverLeaksLocalPath(t *testing.T) {
	resetArtworkRelayState(t)
	// ⚠️ 指向本地 httptest 而不是一个真实域名:这个用例会真的排一次后台上传,打到外网
	// 域名上要等 DNS 超时(还可能真把用户本机的封面 POST 出去)。同理下面的本地路径也
	// 用临时目录,不用 ~/.config 里那份真文件。
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	artworkRelayURL, artworkRelayToken = srv.URL, "tok"

	// 远程封面原样透传。
	const remote = "https://p1.music.126.net/abc.jpg?param=600y600"
	if got := webSafeCoverURL(remote); got != remote {
		t.Errorf("远程封面应原样返回, got %q", got)
	}
	if got := webSafeCoverURL(""); got != "" {
		t.Errorf("空串应返回空串, got %q", got)
	}

	dir := t.TempDir()
	path := filepath.Join(dir, testSHA+".jpg")
	if err := os.WriteFile(path, []byte("\xff\xd8\xfffake"), 0o644); err != nil {
		t.Fatal(err)
	}
	local := deviceArtworkURLPrefix + path

	// 还没确认传上去 → 空串(而不是 file://)。网页据此走自己的 iTunes 兜底。
	if got := webSafeCoverURL(local); got != "" {
		t.Errorf("未上传时应返回空串,绝不能透传本地路径, got %q", got)
	}
	// 上一行会排一次后台上传,等它落定再往下走(否则它会在下面改 artworkRelayURL 之后
	// 才真正发请求)。
	waitArtworkIdle(t)

	// 确认传上去之后 → 中继上的 https 地址。
	artworkMu.Lock()
	artworkUploaded[testSHA] = true
	artworkMu.Unlock()
	want := srv.URL + "/artwork/" + testSHA + ".jpg"
	if got := webSafeCoverURL(local); got != want {
		t.Errorf("已上传时 = %q, want %q", got, want)
	}

	// 没配中继(用户没搭中继、只用 LB)→ 依然不能透传本地路径。
	artworkRelayURL = ""
	if got := webSafeCoverURL(local); got != "" {
		t.Errorf("没配中继时应返回空串, got %q", got)
	}
	// 认不出的 file://(理论上不该出现)同样不许透传。
	artworkRelayURL = srv.URL
	if got := webSafeCoverURL("file:///etc/passwd"); got != "" {
		t.Errorf("认不出的 file:// 应返回空串, got %q", got)
	}
}

// HEAD 命中就绝不 POST —— KV 免费版 1000 写/天,这一条是省额度的关键(重启后内存里的
// 已传集合是空的,没有 HEAD 就会把整个目录重传一遍)。
func TestEnsureArtworkUploadedSkipsPostWhenAlreadyThere(t *testing.T) {
	resetArtworkRelayState(t)
	var mu sync.Mutex
	var heads, posts int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.Method {
		case http.MethodHead:
			heads++
			w.WriteHeader(http.StatusOK)
		case http.MethodPost:
			posts++
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()
	artworkRelayURL, artworkRelayToken = srv.URL, "tok"

	dir := t.TempDir()
	path := filepath.Join(dir, testSHA+".jpg")
	if err := os.WriteFile(path, []byte("\xff\xd8\xfffake-jpeg"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ensureArtworkUploaded(context.Background(), testSHA, path); err != nil {
		t.Fatalf("ensureArtworkUploaded: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if heads != 1 {
		t.Errorf("应该先 HEAD 问一句, heads = %d", heads)
	}
	if posts != 0 {
		t.Errorf("HEAD 命中之后不该再 POST(白烧一次 KV 写额度), posts = %d", posts)
	}
}

func TestEnsureArtworkUploadedPostsWhenMissing(t *testing.T) {
	resetArtworkRelayState(t)
	body := []byte("\xff\xd8\xffreal-bytes-here")
	var mu sync.Mutex
	var gotBody []byte
	var gotCT, gotToken, gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		gotBody = make([]byte, r.ContentLength)
		r.Body.Read(gotBody)
		gotCT, gotToken, gotPath = r.Header.Get("Content-Type"), r.Header.Get("x-token"), r.URL.Path
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	artworkRelayURL, artworkRelayToken = srv.URL, "sekrit"

	dir := t.TempDir()
	path := filepath.Join(dir, testSHA+".jpg")
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ensureArtworkUploaded(context.Background(), testSHA, path); err != nil {
		t.Fatalf("ensureArtworkUploaded: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if string(gotBody) != string(body) {
		t.Errorf("上传的字节跟磁盘上的不一致: %q", gotBody)
	}
	if gotCT != "image/jpeg" {
		t.Errorf("content-type = %q, want image/jpeg", gotCT)
	}
	if gotToken != "sekrit" {
		t.Errorf("x-token = %q, 中继会 401", gotToken)
	}
	// 路由前缀必须跟 state-worker 那边逐字一致。
	if gotPath != "/artwork/"+testSHA+".jpg" {
		t.Errorf("上传路径 = %q", gotPath)
	}
}

func TestEnsureArtworkUploadedPNGContentType(t *testing.T) {
	resetArtworkRelayState(t)
	var mu sync.Mutex
	var gotCT string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		mu.Lock()
		gotCT = r.Header.Get("Content-Type")
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	artworkRelayURL = srv.URL

	dir := t.TempDir()
	path := filepath.Join(dir, testSHA+".png")
	if err := os.WriteFile(path, []byte("\x89PNGfake"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ensureArtworkUploaded(context.Background(), testSHA, path); err != nil {
		t.Fatalf("ensureArtworkUploaded: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if gotCT != "image/png" {
		t.Errorf("PNG 应该发 image/png, got %q", gotCT)
	}
}

// 中继报错时必须回错(调用方据此进冷却期,而不是每几秒重试一次)。
func TestEnsureArtworkUploadedReportsRelayFailure(t *testing.T) {
	resetArtworkRelayState(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable) // KV 写额度爆了就是这个
	}))
	defer srv.Close()
	artworkRelayURL = srv.URL

	dir := t.TempDir()
	path := filepath.Join(dir, testSHA+".jpg")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := ensureArtworkUploaded(context.Background(), testSHA, path)
	if err == nil || !strings.Contains(err.Error(), "503") {
		t.Errorf("中继 503 应该回错, got %v", err)
	}
}

func TestEnsureArtworkUploadedRejectsOversize(t *testing.T) {
	resetArtworkRelayState(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound) // HEAD 未命中,逼它走到大小检查
	}))
	defer srv.Close()
	artworkRelayURL = srv.URL

	dir := t.TempDir()
	path := filepath.Join(dir, testSHA+".jpg")
	if err := os.WriteFile(path, make([]byte, artworkMaxUploadBytes+1), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ensureArtworkUploaded(context.Background(), testSHA, path); err == nil {
		t.Error("超过上限的图不该被传出去")
	}
}

// 启动补传:目录里认得出的都要确认一遍,认不出的文件不许被当成封面传上去。
func TestSweepDeviceArtwork(t *testing.T) {
	resetArtworkRelayState(t)
	var mu sync.Mutex
	seen := map[string]bool{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen[r.URL.Path] = true
		mu.Unlock()
		w.WriteHeader(http.StatusOK) // HEAD 一律命中 → 全程零写入
	}))
	defer srv.Close()
	artworkRelayURL = srv.URL

	dir := t.TempDir()
	deviceArtworkDir = dir
	for _, name := range []string{testSHA + ".jpg", "0011223344556677.png", "README.txt", "not-a-sha.jpg"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	sweepDeviceArtwork(context.Background())

	mu.Lock()
	defer mu.Unlock()
	if !seen["/artwork/"+testSHA+".jpg"] || !seen["/artwork/0011223344556677.png"] {
		t.Errorf("两张合法封面都该被确认一遍, seen = %v", seen)
	}
	if seen["/artwork/README.txt"] || seen["/artwork/not-a-sha.jpg"] {
		t.Errorf("非封面文件不该被传上去, seen = %v", seen)
	}
	// HEAD 全命中,所以这一轮不该有任何东西被标成"这次刚传上去"以外的状态问题——
	// 关键是它们现在都在已确认集合里,后续 webSafeCoverURL 能直接给出 URL。
	artworkMu.Lock()
	defer artworkMu.Unlock()
	if !artworkUploaded[testSHA] {
		t.Error("补传确认过的应该进已上传集合,否则每次推送都会重新排队")
	}
}

// 失败之后进冷却期:lbMeta 每次轮询都会调 webSafeCoverURL,没有这道闸就是每几秒重试一次。
func TestScheduleArtworkUploadBacksOffAfterFailure(t *testing.T) {
	resetArtworkRelayState(t)
	var mu sync.Mutex
	attempts := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		attempts++
		mu.Unlock()
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	artworkRelayURL = srv.URL

	dir := t.TempDir()
	deviceArtworkDir = dir
	path := filepath.Join(dir, testSHA+".jpg")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	local := deviceArtworkURLPrefix + path

	webSafeCoverURL(local)
	// 等第一次上传跑完(它是后台 goroutine)。
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		artworkMu.Lock()
		done := !artworkInflight[testSHA] && !artworkNextRetry[testSHA].IsZero()
		artworkMu.Unlock()
		if done {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	mu.Lock()
	after1 := attempts
	mu.Unlock()
	if after1 == 0 {
		t.Fatal("第一次应该真的尝试过")
	}
	// 冷却期内再调若干次,不该产生新的尝试。
	for i := 0; i < 5; i++ {
		if got := webSafeCoverURL(local); got != "" {
			t.Errorf("失败期间仍然只能返回空串, got %q", got)
		}
	}
	time.Sleep(150 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if attempts != after1 {
		t.Errorf("冷却期内不该重试, attempts %d → %d", after1, attempts)
	}
}
