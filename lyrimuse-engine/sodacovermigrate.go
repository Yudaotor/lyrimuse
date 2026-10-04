package main

import "log"

// migrateSodaCoverURLs 给决策存档里缺了 `~模板-处理参数` 的汽水候选封面补上后缀(见
// sodaCoverURL)。只动存档里的 cover_url,不改候选的任何评分字段;幂等,每次启动跑一遍。
//
// 存档是指针:按「缓存条目只整条替换、不原地改」的约束(见 saveEnrichCache),改之前先复制
// 决策对象和候选切片。
func migrateSodaCoverURLs() {
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		d, n1 := fixSodaCoverURLsInDecision(e.LyricsDecision)
		a, n2 := fixSodaCoverURLsInDecision(e.LyricsDecisionApplied)
		if n1+n2 == 0 {
			continue
		}
		e.LyricsDecision, e.LyricsDecisionApplied = d, a
		enrichCache[k] = e
		fixed += n1 + n2
	}
	if fixed > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("soda cover migration: fixed %d archived candidate cover URLs", fixed)
		saveEnrichCache()
	}
}

// fixSodaCoverURLsInDecision 返回补好后缀的副本和改动条数;没有要改的原样返回原指针。
func fixSodaCoverURLsInDecision(d *lyricsDecision) (*lyricsDecision, int) {
	if d == nil {
		return nil, 0
	}
	n := 0
	for _, c := range d.Candidates {
		if sodaCoverNeedsTransform(c.CoverURL) {
			n++
		}
	}
	if n == 0 {
		return d, 0
	}
	cp := *d
	cp.Candidates = append([]lyricsDecisionCandidate(nil), d.Candidates...)
	for i := range cp.Candidates {
		if u := cp.Candidates[i].CoverURL; sodaCoverNeedsTransform(u) {
			cp.Candidates[i].CoverURL = u + "~" + sodaImageTemplate + "-" + sodaCoverTransform
		}
	}
	return &cp, n
}
