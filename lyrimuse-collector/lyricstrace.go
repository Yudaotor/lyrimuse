package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
)

// 歌词解析决策 trace(2026-08-17 加,吸收自对 lyra 的对比审阅 C1)。
//
// 跟 decision.go 的缓存内决策记录是同一份数据的两个去处:缓存里只留**最近一次**评估
// (后一次覆盖前一次),trace 是 append-only 的**流水账** —— 想看"这首歌三次重试分别
// 发生了什么"只能靠它。默认关(features.json 的 lyrics_decision_trace),开着时每次
// 评估追加一行 NDJSON。
//
// 为什么是 NDJSON 而不是 lyra 那种人读的自由文本:我们的得分明细本来就是机器可读的
// scoreTerm(kind/points),序列化成文本再让人肉眼解析回去是白扔结构 —— search-lyrics
// 的 NDJSON 契约(searchcli.go)是先例。要人读,`jq` 一行就够。
//
// ⚠️ search-lyrics(「歌词管理」的手动重搜)**不会**写这里:它是用户发起的重跑,不是
// 决策 —— 结构上也进不来:那条 CLI 路径从不调 loadFeatureFlags,features 是零值,
// 开关恒为 false(跟 pickLyricCandidate 对 LyricsSources 的既有约定同一个机制)。
//
// 体量控制:lyra 的 trace 没有封顶,lyrimuse.log 也没有轮转 —— 这两个先例都别学。
// 超过 2MB 就把现有文件挪成 .old(只留一代),再开新文件。一行 ~1-2KB,2MB ≈ 一两千次
// 评估,个人听歌量够查几个月。
var lyricsTraceMu sync.Mutex

const lyricsTraceMaxBytes = 2 << 20

// traceLyricsDecision 把一份决策记录追加进 trace 文件。d 为 nil 或开关关着时是空操作。
// 失败只记日志不返回错误 —— trace 是旁路诊断,绝不能反过来影响解析主流程。
func traceLyricsDecision(key string, d *lyricsDecision) {
	if d == nil || !features.LyricsDecisionTrace {
		return
	}
	if enrichPath == "" {
		// 只用内存不持久化的运行模式(测试),trace 也没有落脚点。
		return
	}
	rec := struct {
		Key string `json:"key"`
		*lyricsDecision
	}{key, d}
	blob, err := json.Marshal(rec)
	if err != nil {
		log.Printf("lyrics trace: marshal: %v", err)
		return
	}
	path := filepath.Join(filepath.Dir(enrichPath), clientName+"-lyrics-decision-trace.ndjson")

	lyricsTraceMu.Lock()
	defer lyricsTraceMu.Unlock()
	if st, err := os.Stat(path); err == nil && st.Size() > lyricsTraceMaxBytes {
		// 只留一代:上一个 .old 直接被顶掉。轮转失败(权限?)就地截断也比无限膨胀强,
		// 但 Rename 同目录内几乎不会失败,不为它再写一条分支。
		if err := os.Rename(path, path+".old"); err != nil {
			log.Printf("lyrics trace: rotate: %v", err)
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Printf("lyrics trace: open: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(blob, '\n')); err != nil {
		log.Printf("lyrics trace: write: %v", err)
	}
}
