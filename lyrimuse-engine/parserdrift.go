package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"
)

// errPageUnrecognized:拿到了页面,但不是认得的形状。
var errPageUnrecognized = errors.New("page not recognized")

// ---- 解析型取数路径的「认不出」计数 ----
//
// 靠解析第三方网页 / 客户端本地文件取数的路径,上游改版后通常不报错,只是再也认不出来;调用方照常退回
// 备用路径,功能看着正常、只是变慢变少。这里按路径记连续认不出的次数:到 parserDriftThreshold 写一条
// 警告日志并记进 lyrimuse-parser-drift.json(healthcheck 读它,诊断导出里就有),认出一次就清零。
//
// 「认不出」只在拿到了内容、但内容不是预期形状时记:页面缺那段内嵌数据、JSON 字段路径不在、文件解不开。
// 请求失败、查无此歌、播放器没装、没用这个播放器放过都不算,那些不说明上游变了。
//
// 文件只由常驻实例写(setParserDriftPath 在 main 里设);一次性子命令里 path 为空,只记内存。

// parserDriftThreshold:连续认不出多少次算上游变了。
const parserDriftThreshold = 5

// parserDriftRelogEvery:过了阈值之后每再认不出这么多次重记一条日志,免得只在跨过阈值那一刻留一行。
const parserDriftRelogEvery = 50

type parserDriftEntry struct {
	Streak  int    `json:"streak"`
	FirstAt int64  `json:"first_at"`
	LastAt  int64  `json:"last_at"`
	Detail  string `json:"detail,omitempty"`
}

var (
	parserDriftMu   sync.Mutex
	parserDrift     = map[string]*parserDriftEntry{}
	parserDriftPath string
	parserDriftNow  = time.Now
)

// setParserDriftPath 设定落盘位置并读回上次留下的记录:改版之后长期认不出的状态跨重启保留,
// 不然每次重启都要再攒满阈值才重新报出来。
func setParserDriftPath(path string) {
	loaded := loadParserDriftFile(path)
	parserDriftMu.Lock()
	defer parserDriftMu.Unlock()
	parserDriftPath = path
	for name, e := range loaded {
		e := e
		parserDrift[name] = &e
	}
}

// loadParserDriftFile 读落盘的记录;文件不在或解不开返回空。
func loadParserDriftFile(path string) map[string]parserDriftEntry {
	out := map[string]parserDriftEntry{}
	if path == "" {
		return out
	}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return out
	}
	if err := json.Unmarshal(data, &out); err != nil {
		noteFileErr("decode", path, err)
		return map[string]parserDriftEntry{}
	}
	return out
}

// noteParserUnrecognized 记一次认不出。detail 是给人看的一句线索(缺了哪一段),不带 URL 里的查询参数。
func noteParserUnrecognized(name, detail string) {
	parserDriftMu.Lock()
	defer parserDriftMu.Unlock()
	now := parserDriftNow().Unix()
	e := parserDrift[name]
	if e == nil {
		e = &parserDriftEntry{FirstAt: now}
		parserDrift[name] = e
	}
	e.Streak++
	e.LastAt = now
	e.Detail = detail
	if e.Streak < parserDriftThreshold {
		return
	}
	if e.Streak == parserDriftThreshold || (e.Streak-parserDriftThreshold)%parserDriftRelogEvery == 0 {
		log.Printf("parser drift: %s unrecognized %d times in a row since %s (%s); falling back",
			name, e.Streak, time.Unix(e.FirstAt, 0).Format(time.RFC3339), detail)
	}
	saveParserDriftLocked()
}

// noteParserRecognized 记一次认出来了,清掉这条路径的计数。
func noteParserRecognized(name string) {
	parserDriftMu.Lock()
	defer parserDriftMu.Unlock()
	e := parserDrift[name]
	if e == nil {
		return
	}
	delete(parserDrift, name)
	if e.Streak >= parserDriftThreshold {
		log.Printf("parser drift: %s recognized again after %d misses", name, e.Streak)
		saveParserDriftLocked()
	}
}

// parserDriftingNames 返回当前已过阈值的路径名(排好序)。
func parserDriftingNames() []string {
	parserDriftMu.Lock()
	defer parserDriftMu.Unlock()
	var out []string
	for name, e := range parserDrift {
		if e.Streak >= parserDriftThreshold {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// saveParserDriftLocked 只落已过阈值的记录。调用方持有 parserDriftMu。
func saveParserDriftLocked() {
	if parserDriftPath == "" {
		return
	}
	out := map[string]parserDriftEntry{}
	for name, e := range parserDrift {
		if e.Streak >= parserDriftThreshold {
			out[name] = *e
		}
	}
	data, err := json.Marshal(out)
	if err != nil {
		return
	}
	if err := writeFileAtomic(parserDriftPath, data); err != nil {
		log.Printf("parser drift: save %s: %v", parserDriftPath, err)
	}
}

// sqliteSchemaMismatch:/usr/bin/sqlite3 报的是表或列不存在,即客户端改了库结构。
// 库被锁、超时、文件读不了都不算。
func sqliteSchemaMismatch(err error) bool {
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		return false
	}
	msg := string(ee.Stderr)
	return strings.Contains(msg, "no such table") || strings.Contains(msg, "no such column")
}

// sqliteErrorDetail 取 sqlite3 stderr 的第一行。
func sqliteErrorDetail(err error) string {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if line, _, _ := strings.Cut(strings.TrimSpace(string(ee.Stderr)), "\n"); line != "" {
			return line
		}
	}
	return err.Error()
}
