package main

import (
	"context"
	"log"
	"sort"
	"time"
)

// 存量条目里取不到的 Musixmatch 800 档封面换回同一张图的 500 档(见 musixmatch.go musixmatchCheckedCover,03 章决策 60)。
// 那一档是按形状拼的,个别专辑图没有,存下去的就是一张一直 403 的封面:界面上没图,给专辑定封面那一步每一遍都去取它、
// 取不到又不定。要联网,放后台跑、不挡启动;有地址这一轮没问成(网络出错)就不记水位,下次启动再来。
const (
	migrationMusixmatchCovers        = "musixmatch_dead_800_covers"
	migrationMusixmatchCoversVersion = 1

	// musixmatchCoverRepairDelay:启动后等这么久再开始,让开启动那阵子的取词和扫库。
	musixmatchCoverRepairDelay = 3 * time.Minute
)

// startMusixmatchCoverRepair:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startMusixmatchCoverRepair(ctx context.Context) {
	scope := migrationScopeOf(migrationMusixmatchCovers, migrationMusixmatchCoversVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(musixmatchCoverRepairDelay):
		}
		repairMusixmatchCovers(withBackgroundOutbound(ctx), scope)
	}()
}

// repairMusixmatchCovers 核 scope 里封面是 Musixmatch 800 档的条目,明确取不到的换成 500 档、清掉按旧图算的主色,
// 全部问成了才记水位。返回换了几条。
func repairMusixmatchCovers(ctx context.Context, scope migrationScope) int {
	enrichMu.Lock()
	byURL := map[string][]string{}
	for k, e := range scope.entries() {
		if musixmatchCover500For(e.CoverURL) != "" {
			byURL[e.CoverURL] = append(byURL[e.CoverURL], k)
		}
	}
	enrichMu.Unlock()
	urls := make([]string, 0, len(byURL))
	for u := range byURL {
		urls = append(urls, u)
	}
	sort.Strings(urls)
	replace := map[string]string{}
	complete := true
	for _, u := range urls {
		if ctx.Err() != nil {
			return 0
		}
		exists, ok := musixmatchCoverExists(ctx, u)
		if !ok {
			complete = false
			continue
		}
		if !exists {
			replace[u] = musixmatchCover500For(u)
		}
	}
	changed := 0
	enrichMu.Lock()
	for u, to := range replace {
		for _, k := range byURL[u] {
			e, ok := enrichCache[k]
			if !ok || e.CoverURL != u || enrichInflight[k] {
				continue
			}
			e.CoverURL, e.AccentColor = to, ""
			if e.CoverSettled == u {
				e.CoverSettled = to
			}
			enrichCache[k] = e
			changed++
			log.Printf("musixmatch cover repair: %q had an 800px cover the image host does not serve, using the 500px one", k)
		}
	}
	if changed > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if changed > 0 {
		saveEnrichCache()
	}
	log.Printf("musixmatch cover repair: %d covers checked, %d dead, %d entries changed, complete=%v", len(urls), len(replace), changed, complete)
	if complete {
		scope.markDone(migrationMusixmatchCovers, migrationMusixmatchCoversVersion)
	}
	return changed
}
