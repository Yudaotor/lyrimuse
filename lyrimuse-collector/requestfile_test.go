package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 认领之后才投递的请求不能被这一轮删掉;没有请求时报不存在。
func TestClaimRequestFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "req.txt")
	if _, err := claimRequestFile(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("没有请求时该报不存在: %v", err)
	}
	if err := os.WriteFile(path, []byte("first"), 0o644); err != nil {
		t.Fatal(err)
	}
	data, err := claimRequestFile(path)
	if err != nil || string(data) != "first" {
		t.Fatalf("认领到的内容不对: %q %v", data, err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("认领后原路径该空出来")
	}
	// 模拟「认领之后 App 又投递了一份」:原路径上的新请求留给下一轮。
	if err := os.WriteFile(path, []byte("second"), 0o644); err != nil {
		t.Fatal(err)
	}
	if data, err := claimRequestFile(path); err != nil || string(data) != "second" {
		t.Fatalf("新请求该留到下一轮: %q %v", data, err)
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 0 {
		t.Fatalf("认领用的临时文件该删掉: %v", entries)
	}
}

// 头像缓存落盘时合并磁盘上的最新版本,只覆盖本进程查过的歌手。
func TestMergeAvatarCacheKeepsOtherProcessEntries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "avatars.json")
	if err := os.WriteFile(path, []byte(`{"A":{"url":"a-new","ts":2},"B":{"url":"b","ts":1}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	merged := mergeAvatarCache(path, map[string]avatarCacheEntry{"A": {URL: "a-mine", TS: 3}, "C": {URL: "c", TS: 3}})
	if merged["A"].URL != "a-mine" || merged["B"].URL != "b" || merged["C"].URL != "c" {
		t.Fatalf("合并结果不对: %+v", merged)
	}
}

// delete-listen 的整份重写要在跨进程锁内读全文:另一个进程(常驻 collector)拿着锁追加的那条收听,
// 在锁放开之后的重写里必须还在。
func TestDeleteListensKeepsAppendMadeUnderLock(t *testing.T) {
	dir := t.TempDir()
	listenLogMu.Lock()
	saved := listenLogPath
	listenLogPath = filepath.Join(dir, "listens.jsonl")
	path := listenLogPath
	listenLogMu.Unlock()
	t.Cleanup(func() {
		listenLogMu.Lock()
		listenLogPath = saved
		listenLogMu.Unlock()
	})
	appendListenLogLine(listenLogLine{T: "l", V: listenLogSchemaVersion, UTS: 1, TI: "one"})
	appendListenLogLine(listenLogLine{T: "l", V: listenLogSchemaVersion, UTS: 2, TI: "two"})

	unlock := lockListenLogFile(path) // 扮演另一个进程
	done := make(chan error, 1)
	go func() {
		_, _, err := deleteListensByUTS([]int64{1})
		done <- err
	}()
	time.Sleep(150 * time.Millisecond)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(`{"t":"l","v":1,"uts":3,"ti":"three"}` + "\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	unlock()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	var got []int64
	for _, line := range readListenLog() {
		got = append(got, line.UTS)
	}
	if len(got) != 2 || got[0] != 2 || got[1] != 3 {
		t.Fatalf("锁内追加的收听被重写弄丢了: %v", got)
	}
}
