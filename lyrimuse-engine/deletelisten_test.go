package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestListenLog(t *testing.T, lines []listenLogLine) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "listens.jsonl")
	var sb strings.Builder
	for _, l := range lines {
		data, err := json.Marshal(l)
		if err != nil {
			t.Fatal(err)
		}
		sb.Write(data)
		sb.WriteByte('\n')
	}
	if err := os.WriteFile(path, []byte(sb.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	saved := listenLogPath
	t.Cleanup(func() { setListenLogPath(saved) })
	setListenLogPath(path)
	return path
}

// 删除粒度是整个 uts。同一次收听可能有收听行(l)+回执行(s)+隔离行(q)，只删收听行
// 会留下指向不存在收听的孤儿回执，而那些回执还会继续参与"已提交"判定。
func TestDeleteListensRemovesEveryLineForThatUTS(t *testing.T) {
	writeTestListenLog(t, []listenLogLine{
		{T: "l", V: 1, UTS: 100, AR: "A", TI: "keep"},
		{T: "l", V: 1, UTS: 200, AR: "B", TI: "drop"},
		{T: "s", V: 1, UTS: 200},
		{T: "q", V: 1, UTS: 200},
		{T: "l", V: 1, UTS: 300, AR: "C", TI: "keep2"},
	})

	deleted, remaining, err := deleteListensByUTS([]int64{200})
	if err != nil {
		t.Fatal(err)
	}
	if deleted != 3 {
		t.Errorf("该 uts 的三行都要删掉, got %d", deleted)
	}
	if remaining != 2 {
		t.Errorf("剩下两行, got %d", remaining)
	}
	left := readListenLog()
	for _, l := range left {
		if l.UTS == 200 {
			t.Errorf("uts=200 还有残留: %+v", l)
		}
	}
	if len(left) != 2 || left[0].TI != "keep" || left[1].TI != "keep2" {
		t.Errorf("剩下的内容/顺序不对: %+v", left)
	}
}

// 没匹配上不是错误（界面上那条可能刚被别处删掉），也不该白重写一遍文件。
func TestDeleteListensMissingUTSIsNotAnError(t *testing.T) {
	path := writeTestListenLog(t, []listenLogLine{
		{T: "l", V: 1, UTS: 100, AR: "A", TI: "x"},
	})
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	deleted, remaining, err := deleteListensByUTS([]int64{999})
	if err != nil {
		t.Fatalf("没匹配上不该报错: %v", err)
	}
	if deleted != 0 || remaining != 1 {
		t.Errorf("deleted=%d remaining=%d", deleted, remaining)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !before.ModTime().Equal(after.ModTime()) {
		t.Error("一条都没删就不该重写文件")
	}
}

func TestDeleteListensMultiple(t *testing.T) {
	writeTestListenLog(t, []listenLogLine{
		{T: "l", V: 1, UTS: 1, TI: "a"},
		{T: "l", V: 1, UTS: 2, TI: "b"},
		{T: "l", V: 1, UTS: 3, TI: "c"},
	})
	deleted, remaining, err := deleteListensByUTS([]int64{1, 3})
	if err != nil {
		t.Fatal(err)
	}
	if deleted != 2 || remaining != 1 {
		t.Fatalf("deleted=%d remaining=%d", deleted, remaining)
	}
	if left := readListenLog(); len(left) != 1 || left[0].TI != "b" {
		t.Errorf("剩下的不对: %+v", left)
	}
}

// uts<=0 必须在参数解析阶段就被拒。日志里 uts=0 的行是坏数据，
// "顺手清掉所有坏数据"绝不该由一次「删这一条」的点击悄悄触发。
func TestUTSFlagRejectsNonPositive(t *testing.T) {
	for _, bad := range []string{"0", "-1", "abc", "1,0"} {
		var f utsFlag
		if err := f.Set(bad); err == nil {
			t.Errorf("%q 应该被拒绝, got %v", bad, f)
		}
	}
	var f utsFlag
	if err := f.Set("100,200"); err != nil || len(f) != 2 || f[0] != 100 || f[1] != 200 {
		t.Errorf("逗号分隔应该解析成两个: %v err=%v", f, err)
	}
}
