package main

import "reflect"

// shareIdenticalDecisions 让内容相同的两槽判决记录(lyrics_decision / lyrics_decision_applied)在内存里
// 指向同一个对象,返回合并了多少条。
//
// collector 写入时本来就是 `e.LyricsDecisionApplied = e.LyricsDecision`(同一个指针),App 手动选词 /
// 标纯音乐时两槽也写成同一份 —— 可从磁盘读回来,JSON 会把它们解成两个独立对象。实测(
// 7928 条、97% 两槽相同)加载后常驻 200 MB,合并后 156 MB。落盘照旧两槽各写一份,文件内容逐字节不变。
//
// 共用对象成立的前提跟 saveEnrichCache 锁外 marshal 那条一样:判决记录存进缓存之后不再原地改。
// 现有的原地写(`e.LyricsDecision.SourcesSkipped = ...` 那三处)都发生在 buildLyricsDecision 刚造出
// 新对象、还没挂到 Applied 之前,不受影响。
func shareIdenticalDecisions(m map[string]enrichEntry) int {
	n := 0
	for k, e := range m {
		d, a := e.LyricsDecision, e.LyricsDecisionApplied
		if d == nil || a == nil || d == a || !reflect.DeepEqual(d, a) {
			continue
		}
		e.LyricsDecisionApplied = d
		m[k] = e
		n++
	}
	return n
}
