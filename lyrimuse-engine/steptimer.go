package main

import (
	"fmt"
	"log"
	"strings"
	"time"
)

// stepTimer 给一段关键路径分段计时,总耗时到门槛才打一行,平时不出日志。
//
// 用在「歌词选好 → 写出去让界面出词」这一段:偶发整段卡十几秒,光看首尾两行日志分不清卡在生成读音、
// 等 enrichMu、写单条快照还是整份落盘。见 09 章决策 108。nil 接收者上的调用全部是空操作,调用方不用判空。
type stepTimer struct {
	start, last time.Time
	steps       []string
}

// slowCommitThreshold 首次出词这一段超过它就打分段日志。
const slowCommitThreshold = 2 * time.Second

func newStepTimer() *stepTimer {
	now := time.Now()
	return &stepTimer{start: now, last: now}
}

// mark 记下从上一个 mark(或开始)到现在这一段叫 name。
func (t *stepTimer) mark(name string) {
	if t == nil {
		return
	}
	now := time.Now()
	t.steps = append(t.steps, fmt.Sprintf("%s=%s", name, now.Sub(t.last).Round(time.Millisecond)))
	t.last = now
}

// total 从开始到现在。
func (t *stepTimer) total() time.Duration {
	if t == nil {
		return 0
	}
	return time.Since(t.start)
}

// logIfSlow 总耗时到 threshold 才打一行:what 标明是哪一段,后面是各段耗时。
func (t *stepTimer) logIfSlow(what string, threshold time.Duration) {
	if t == nil {
		return
	}
	if d := t.total(); d >= threshold {
		log.Printf("slow %s: total=%s %s", what, d.Round(time.Millisecond), strings.Join(t.steps, " "))
	}
}
