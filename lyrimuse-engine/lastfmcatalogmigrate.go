package main

import (
	"encoding/json"
	"log"
	"os"
	"strings"
)

// 编目判定缓存(lastfmCatalogPath)的一次性存量重判:keep / match 永不重查(见 lastfmcatalog.go 头注),判据收紧之后,
// 旧判据判出、新判据不会再判出的 match 只能靠这里删掉,下次放到时按现在的判据重判。只删、不改写:重判要联网,放在
// 下次真正放到这首时做,启动时不打网络。defer 不用这里管,扩展口径版本(lastfmCatalogExtVersion)升了,lookup 会让它们重判。
//
// 删的是两类 match(lastfmCatalogStaleMatch),都是现在的 decide 不会再判出的,所以重跑这道迁移是幂等的:
//
//  1. 选中的条目没有 mbid、听众比原样少(colderThan)。Fish Leong《Man Leng》原样 335 听众 → 1 听众的「梁靜茹」那条;
//     Zico《SPOT!》原样 345,859 听众 → 2,269 听众、没有 mbid 的「지코」那条。
//  2. 扩展判定旧口径(Ext < lastfmCatalogExtNameKeyVersion,名字去重还折繁简)下的兜底档 match,原样歌手名里有繁简不同写法的字:当时繁 / 简另一种
//     写法从没查过,兜底档选的是「编目里没有正规条目」时的影子条目,而另一种写法名下可能就有正规条目
//     (「周杰伦 / 太陽之子」→ 32 听众的「ジェイ・チョウ」,「周杰倫」名下有 mbid、1,051 听众的那条)。
//
// 曲名尾巴(tail+)和 MV 标题(video+)那两路的 own / chosen 是按拆出来的写法判的,不在这里比。见 12 章决策 89。
func migrateLastfmCatalogStaleMatches() {
	scope := migrationScopeOf(migrationLastfmCatalogStale, migrationLastfmCatalogStaleVersion)
	if scope.skip() || lastfmCatalogPath == "" {
		return
	}
	// 范围照迁移水位:全库时看缓存里每一条;只补扫 lyrics/ 文件夹改过的那几条时,只看那几首歌(按歌手 + 曲名折叠键对)。
	var wanted map[string]bool
	if !scope.all {
		wanted = map[string]bool{}
		enrichMu.Lock()
		for k := range scope.entries() {
			artist, title, _ := splitEnrichKey(k)
			wanted[lastfmCatalogArtistKey(artist)+"\n"+lastfmCatalogTitleKey(title)] = true
		}
		enrichMu.Unlock()
	}
	removed, ok := pruneLastfmCatalogStaleMatches(lastfmCatalogPath, wanted)
	if !ok {
		return // 读写失败:下次启动再来
	}
	if removed > 0 {
		log.Printf("lastfm catalog: dropped %d stale match decision(s), they are re-decided the next time they play", removed)
	}
	scope.markDone(migrationLastfmCatalogStale, migrationLastfmCatalogStaleVersion)
}

// pruneLastfmCatalogStaleMatches 从缓存文件里删掉 lastfmCatalogStaleMatch 认出的条目,返回删了几条。wanted 非 nil 时
// 只看折叠键(歌手\n曲名)在里面的那几条。文件不存在算完成(0 条);读不出、解不开、写不回去算没完成。原文件先另存
// 一份 .bak-stale-matches,写回走 writeFileAtomic。
func pruneLastfmCatalogStaleMatches(path string, wanted map[string]bool) (int, bool) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return 0, true
	}
	if err != nil {
		noteFileErr("read", path, err)
		return 0, false
	}
	var m map[string]lastfmCatalogDecision
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("lastfm catalog: cache unreadable, stale-match cleanup skipped: %v", err)
		return 0, false
	}
	// 只删不认的那几条,其余字段原样写回:按原始 JSON 保留,不经结构体重编码(结构体里没有的字段不丢)。
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return 0, false
	}
	removed := 0
	for k, d := range m {
		if wanted != nil {
			artist, title, _ := strings.Cut(k, "\n")
			if !wanted[lastfmCatalogArtistKey(artist)+"\n"+lastfmCatalogTitleKey(title)] {
				continue
			}
		}
		if lastfmCatalogStaleMatch(k, d) {
			delete(raw, k)
			removed++
		}
	}
	if removed == 0 {
		return 0, true
	}
	out, err := json.Marshal(raw)
	if err != nil {
		return 0, false
	}
	if err := writeFileAtomic(path+".bak-stale-matches", data); err != nil {
		warnf("lastfm catalog: backup before stale-match cleanup failed (%v), skipped", err)
		return 0, false
	}
	if err := writeFileAtomic(path, out); err != nil {
		warnf("lastfm catalog: stale-match cleanup write failed: %v", err)
		return 0, false
	}
	return removed, true
}

// lastfmCatalogStaleMatch 判一条缓存的判定是不是上面头注里那两类。key 是缓存键「歌手\n曲名」。纯函数。
func lastfmCatalogStaleMatch(key string, d lastfmCatalogDecision) bool {
	if d.Verdict != verdictMatch || d.Own == nil || d.Chosen == nil {
		return false
	}
	via := strings.TrimSuffix(d.Via, "+fallback")
	switch via {
	case "", "base", "name", "top", "search":
	default:
		return false // tail+ / video+:见头注
	}
	own, chosen := *d.Own, *d.Chosen
	if chosen.colderThan(own) {
		return true
	}
	artist, _, _ := strings.Cut(key, "\n")
	return d.Ext < lastfmCatalogExtNameKeyVersion && strings.HasSuffix(d.Via, "+fallback") && hasHanScriptVariant(artist)
}

// lastfmCatalogExtNameKeyVersion:扩展口径从这一版起名字去重不折繁简(lastfmCatalogNameKey)。
const lastfmCatalogExtNameKeyVersion = 3

// hasHanScriptVariant:名字里有繁简写法不同的汉字(繁体字,或者有对应繁体字的简体字)。
func hasHanScriptVariant(name string) bool {
	if toSimplified(name) != name {
		return true
	}
	for _, r := range name {
		if trad, ok := s2tCharMap[string(r)]; ok && trad != string(r) {
			return true
		}
	}
	return false
}
