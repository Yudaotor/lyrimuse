package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// 常驻采集器里必须用 per-round 的差值。networkLooksDown() 读的是进程启动以来的累计值，
// 一旦早期有过成功，failures==attempts 就永远不成立 —— 开机有网、后来断网，它一路报正常。
func TestNetworkRoundIsRelativeNotCumulative(t *testing.T) {
	a0 := atomic.LoadInt32(&networkAttemptCount)
	f0 := atomic.LoadInt32(&networkFailureCount)
	t.Cleanup(func() {
		atomic.StoreInt32(&networkAttemptCount, a0)
		atomic.StoreInt32(&networkFailureCount, f0)
	})

	// 先制造一段"历史上成功过很多次"，这正是让累计判据失灵的前提。
	atomic.StoreInt32(&networkAttemptCount, 100)
	atomic.StoreInt32(&networkFailureCount, 0)
	if networkLooksDown() {
		t.Fatal("前提不对：全成功时累计判据不该报不通")
	}

	// 现在断网：这一轮三次全失败。
	round := beginNetworkRound()
	atomic.AddInt32(&networkAttemptCount, 3)
	atomic.AddInt32(&networkFailureCount, 3)

	attempts, failures := round()
	if attempts != 3 || failures != 3 {
		t.Fatalf("差值算错: attempts=%d failures=%d", attempts, failures)
	}
	if !roundLooksNetworkDown(attempts, failures) {
		t.Error("这一轮全失败，应该判为网络不通")
	}
	// 对照：累计判据在同样的情况下看不出问题，这就是不能用它的原因。
	if networkLooksDown() {
		t.Error("前提变了？累计判据这时本来就不该成立")
	}
}

func TestRoundLooksNetworkDownThreshold(t *testing.T) {
	cases := []struct {
		attempts, failures int32
		want               bool
	}{
		{0, 0, false},  // 什么都没发生
		{2, 2, false},  // 样本太少：可能只是这首歌信息不全，没发几个请求
		{3, 3, true},   // 三次全失败
		{5, 4, false},  // 有一次成功 → 网络是通的
		{10, 10, true}, // 全失败
	}
	for _, c := range cases {
		if got := roundLooksNetworkDown(c.attempts, c.failures); got != c.want {
			t.Errorf("attempts=%d failures=%d: got %v, want %v", c.attempts, c.failures, got, c.want)
		}
	}
}

func TestCollectorStatusWriteAndClear(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "status.json")

	saved := collectorStatusPath
	savedFlag := collectorStatusNetworkDown
	t.Cleanup(func() {
		collectorStatusMu.Lock()
		collectorStatusPath = saved
		collectorStatusNetworkDown = savedFlag
		collectorStatusMu.Unlock()
	})

	setCollectorStatusPath(path)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("刚设置路径时不该有文件（要清掉上次运行的残留）")
	}

	markCollectorNetworkDown()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("状态文件没写出来: %v", err)
	}
	var f collectorStatusFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatalf("状态文件解析不了: %v", err)
	}
	if !f.NetworkDown || f.At == 0 {
		t.Errorf("内容不对: %+v", f)
	}

	clearCollectorNetworkDown()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("恢复之后文件该被删掉")
	}
	// 再清一次不该报错（文件已经不在了）。
	clearCollectorNetworkDown()
}

// 路径没设置时一切都是空操作 —— 一次性子命令（search-lyrics 等）走的就是这条路，
// 不该让它们往一个空路径写文件。
func TestCollectorStatusNoopWithoutPath(t *testing.T) {
	saved := collectorStatusPath
	savedFlag := collectorStatusNetworkDown
	t.Cleanup(func() {
		collectorStatusMu.Lock()
		collectorStatusPath = saved
		collectorStatusNetworkDown = savedFlag
		collectorStatusMu.Unlock()
	})
	collectorStatusMu.Lock()
	collectorStatusPath = ""
	collectorStatusNetworkDown = false
	collectorStatusMu.Unlock()

	markCollectorNetworkDown()  // 不该 panic
	clearCollectorNetworkDown() // 不该 panic
	if collectorStatusNetworkDown {
		t.Error("没有路径时不该记下已写入状态")
	}
}
