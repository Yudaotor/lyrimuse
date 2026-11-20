package main

import (
	"bytes"
	"encoding/json"
	"log"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// ---- 下架的歌词源 ----
//
// 代码里已经删掉的歌词源在本机留下的东西,新版启动时清一遍(见 09 章决策 370):
//   - 歌词来源是它的条目(手改过、锁定、选定来源的也算):歌词那一族字段连同手改标记、出处、退避账一起清空,导出到
//     lyrics/ 的文件、正文小文件、判决旁路文件一起删,交给补空扫描和播放到时重新自动匹配。
//   - 别的条目上它留下的:纯文本兜底、借来的译文、它的图床上的封面、按播放器存的那份、几张源名单、胜者是它的判决
//     那一槽、判决明细里它的候选和只问它的查询。
//   - 同步留底里的那份条目照同样的规则清(恢复时不能把它带回来)。
//   - 它自己的缓存文件(retiredLyricSourceFiles)和小时额度里它那一份;各源近况统计在读进来时剔掉(dropRetiredLyricSourceStats)。
//   - 只有它供数据、随它整列删掉的条目字段(retiredEnrichKeys):这个构建不认识它们,解码时进 enrichEntry.Unknown 原样保留,
//     不清就永远留在缓存里。
//
// 带水位(migrationRetiredLyricSources):lyrics/ 导入进来的那几条下次启动补扫,配置搬家带进来的整库重扫。只动本机数据,不联网。

// retiredLyricSources:下架的歌词源名(跟下架前登记的源名逐字一样)。
var retiredLyricSources = []string{"musixmatch"}

// retiredLyricSourceCoverHosts:下架源的封面图床,封面在这些主机(含子域)上的清掉,交给补封面重新取。
var retiredLyricSourceCoverHosts = []string{"mxmcdn.net"}

// retiredEnrichKeys:随下架源整列删掉的条目字段的 JSON 键。删掉 enrichEntry 的字段时,键加进这里、水位加一
// (enrichjson.go 头注,09 章决策 372)。
var retiredEnrichKeys = []string{"lyrics_speakers", "lyrics_speakers_checked"}

// retiredLyricSourceFiles:下架源自己的缓存文件,去掉 clientName 前缀之后的名字。新旧两个目录(cacheFilePath /
// configFilePath)都删。
var retiredLyricSourceFiles = []string{"-musixmatch-token.json", "-clash-node-blocks.json"}

const (
	migrationRetiredLyricSources        = "retired_lyric_sources"
	migrationRetiredLyricSourcesVersion = 2
)

func isRetiredLyricSource(s string) bool { return slices.Contains(retiredLyricSources, s) }

// retiredLyricSourceCover:这个封面地址在下架源的图床上。
func retiredLyricSourceCover(u string) bool {
	if u == "" {
		return false
	}
	rest, ok := strings.CutPrefix(strings.ToLower(u), "https://")
	if !ok {
		rest, ok = strings.CutPrefix(strings.ToLower(u), "http://")
	}
	if !ok {
		return false
	}
	host, _, _ := strings.Cut(rest, "/")
	host, _, _ = strings.Cut(host, ":")
	for _, h := range retiredLyricSourceCoverHosts {
		if host == h || strings.HasSuffix(host, "."+h) {
			return true
		}
	}
	return false
}

// withoutRetiredSources:去掉名单里的下架源。没有要去的原样返回(不复制);去完是空的返回 nil。
func withoutRetiredSources(list []string) []string {
	if !slices.ContainsFunc(list, isRetiredLyricSource) {
		return list
	}
	out := slices.DeleteFunc(slices.Clone(list), isRetiredLyricSource)
	if len(out) == 0 {
		return nil
	}
	return out
}

// scrubRetiredDecision:一槽判决去掉下架源。胜者是它的整槽不要(返回 nil);别的只去掉源名单、候选、候选的共识名单,
// 以及只问它的那几组查询。不改原对象(缓存条目里的指针存进去之后不许原地改),有改动才返回新拷贝。
func scrubRetiredDecision(d *lyricsDecision) (*lyricsDecision, bool) {
	if d == nil {
		return nil, false
	}
	if isRetiredLyricSource(d.Winner) {
		return nil, true
	}
	cp := *d
	changed := false
	if l := withoutRetiredSources(cp.SourcesResponded); !slices.Equal(l, cp.SourcesResponded) {
		cp.SourcesResponded, changed = l, true
	}
	if l := withoutRetiredSources(cp.SourcesSkipped); !slices.Equal(l, cp.SourcesSkipped) {
		cp.SourcesSkipped, changed = l, true
	}
	if c, ok := scrubRetiredCandidates(cp.Candidates); ok {
		cp.Candidates, changed = c, true
	}
	if q, ok := scrubRetiredQueries(cp.QueriesTried); ok {
		cp.QueriesTried, changed = q, true
	}
	if !changed {
		return d, false
	}
	return &cp, true
}

func scrubRetiredCandidates(cands []lyricsDecisionCandidate) ([]lyricsDecisionCandidate, bool) {
	changed := false
	var out []lyricsDecisionCandidate
	for _, c := range cands {
		if isRetiredLyricSource(c.Source) {
			changed = true
			continue
		}
		if l := withoutRetiredSources(c.ConsensusPeers); !slices.Equal(l, c.ConsensusPeers) {
			c.ConsensusPeers, changed = l, true
		}
		out = append(out, c)
	}
	if !changed {
		return cands, false
	}
	return out, true
}

// scrubRetiredQueries:只问下架源的那组查询整组去掉(名单去空了会被读成「不限源」);问了好几个源的只去掉它的名字。
func scrubRetiredQueries(qs []lyricQueryRecord) ([]lyricQueryRecord, bool) {
	changed := false
	var out []lyricQueryRecord
	for _, q := range qs {
		if l := withoutRetiredSources(q.Sources); !slices.Equal(l, q.Sources) {
			changed = true
			if len(l) == 0 {
				continue
			}
			q.Sources = l
		}
		out = append(out, q)
	}
	if !changed {
		return qs, false
	}
	return out, true
}

// resetRetiredLyrics:歌词来源是下架源的条目,清成「还没解析过歌词」的样子:歌词那一族(songShareLyricsFields 管的那些,
// 连同手改标记、出处、源名单)、选定的来源、判决、退避账、导出读音都清掉。封面、链接、时长这些跟歌词无关的留着。
func resetRetiredLyrics(e *enrichEntry) {
	songShareLyricsFields(e, enrichEntry{})
	e.LyricsSourceChoice = ""
	e.LyricsDecision = nil
	e.LyricsRetryTS, e.LyricsRetryCount = 0, 0
	e.LyricsFillTS, e.LyricsFillCount = 0, 0
	e.LyricsRescoreCount, e.LyricsRescoreTS, e.LyricsRescoreVersion, e.LyricsRescoreRevision = 0, 0, 0, 0
	e.LyricsRomaExport, e.LyricsRomaExportSrc, e.LyricsRomaExportRules = nil, 0, 0
}

// scrubRetiredLyricSources 清掉 e 上下架源留下的东西,见文件头。reset:这条的歌词就是下架源给的,整族清空了
// (调用方还要删它导出的文件、正文小文件和判决旁路文件)。
func scrubRetiredLyricSources(e *enrichEntry) (changed, reset bool) {
	if isRetiredLyricSource(e.LyricsSource) {
		resetRetiredLyrics(e)
		changed, reset = true, true
	}
	if isRetiredLyricSource(e.LyricsSourceChoice) {
		e.LyricsSourceChoice, changed = "", true
	}
	if isRetiredLyricSource(e.PlainLyricsSource) {
		e.PlainLyrics, e.PlainLyricsSource, changed = bodyText{}, "", true
	}
	if src, ok := strings.CutPrefix(e.LyricsTrSource, "borrowed:"); ok && isRetiredLyricSource(src) {
		e.LyricsTr, e.LyricsTrSource, e.LyricsTrLang, changed = bodyText{}, "", "", true
	}
	if isRetiredLyricSource(e.CoverSource) || retiredLyricSourceCover(e.CoverURL) {
		old := e.CoverURL
		e.CoverURL, e.CoverSource, e.AccentColor = "", "", ""
		if e.CoverSettled == old {
			e.CoverSettled = ""
		}
		changed = true
	}
	if retiredLyricSourceCover(e.CoverSettled) {
		e.CoverSettled, changed = "", true
	}
	if retiredLyricSourceCover(e.MotionCoverFor) {
		e.clearMotionVerdict()
		e.MotionCoverFor, changed = "", true
	}
	if retiredLyricSourceCover(e.PublicCoverURL) || retiredLyricSourceCover(e.PublicCoverFor) {
		e.PublicCoverURL, e.PublicCoverFor, changed = "", "", true
	}
	retiredAlt := false
	for _, a := range e.PlayerLyrics {
		retiredAlt = retiredAlt || isRetiredLyricSource(a.Source)
	}
	if retiredAlt {
		e.PlayerLyrics = maps.Clone(e.PlayerLyrics)
		maps.DeleteFunc(e.PlayerLyrics, func(_ string, a playerLyricsAlt) bool { return isRetiredLyricSource(a.Source) })
		if len(e.PlayerLyrics) == 0 {
			e.PlayerLyrics = nil
		}
		changed = true
	}
	for _, l := range []*[]string{&e.LyricsSourcesSeen, &e.LyricsSourcesResponded, &e.LyricsSourcesSkipped, &e.LyricsSourcesEnabled} {
		if n := withoutRetiredSources(*l); !slices.Equal(n, *l) {
			*l, changed = n, true
		}
	}
	if slices.ContainsFunc(retiredEnrichKeys, func(k string) bool { _, ok := e.Unknown[k]; return ok }) {
		e.Unknown = maps.Clone(e.Unknown)
		for _, k := range retiredEnrichKeys {
			delete(e.Unknown, k)
		}
		if len(e.Unknown) == 0 {
			e.Unknown = nil
		}
		changed = true
	}
	latest, applied := e.LyricsDecision, e.LyricsDecisionApplied
	if d, ok := scrubRetiredDecision(latest); ok {
		e.LyricsDecision, changed = d, true
	}
	if applied == latest {
		e.LyricsDecisionApplied = e.LyricsDecision
	} else if d, ok := scrubRetiredDecision(applied); ok {
		e.LyricsDecisionApplied, changed = d, true
	}
	return changed, reset
}

// purgeRetiredLyricSources:启动迁移,见文件头。排在 importLyricsFromFiles 之后、exportLyricsFiles 之前(main.go)。
func purgeRetiredLyricSources() {
	scope := migrationScopeOf(migrationRetiredLyricSources, migrationRetiredLyricSourcesVersion)
	if scope.skip() {
		return
	}
	enrichMu.Lock()
	var resetKeys []string
	scrubbed := 0
	for k, e := range scope.entries() {
		changed, reset := scrubRetiredLyricSources(&e)
		if !changed {
			continue
		}
		cancelInFlightEnrichLocked(k)
		enrichCache[k] = e
		scrubbed++
		if reset {
			resetKeys = append(resetKeys, k)
		}
	}
	if scrubbed > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	slices.Sort(resetKeys)
	if scrubbed > 0 {
		saveEnrichCache()
	}
	files := 0
	for _, k := range resetKeys {
		paths := lyricsFilesOwnedBy(k)
		for _, p := range paths {
			if os.Remove(p) == nil {
				files++
			}
		}
		removeDecisionSidecar(k)
		removeRetiredLyricsBody(k)
	}
	var sidecars, pres, cacheFiles int
	if scope.all {
		sidecars = scrubRetiredDecisionSidecars()
		pres = scrubRetiredSongSharePres()
		cacheFiles = removeRetiredLyricSourceFiles()
	}
	log.Printf("retired lyric sources: reset %d entries for a new match, scrubbed %d, removed %d lyrics files; "+
		"rewrote %d decision files and %d sync snapshots; removed %d cache files",
		len(resetKeys), scrubbed, files, sidecars, pres, cacheFiles)
	scope.markDone(migrationRetiredLyricSources, migrationRetiredLyricSourcesVersion)
}

// removeRetiredLyricsBody:清空了的条目的正文小文件删掉 —— 没有正文的条目保存时不写小文件,旧的那份不会被盖掉。
// 这一刻条目又有了正文(别处刚写进来)就不删。
func removeRetiredLyricsBody(key string) {
	dir := enrichBodiesDir()
	if dir == "" {
		return
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	empty := ok && e.Lyrics.IsZero() && e.LyricsYRC.IsZero() && e.LyricsTr.IsZero() && e.LyricsRoma.IsZero() &&
		e.PlainLyrics.IsZero() && e.LyricsBG.IsZero()
	enrichMu.Unlock()
	if !empty {
		return
	}
	if err := os.Remove(bodySidePath(dir, key)); err != nil && !os.IsNotExist(err) {
		noteFileErr("remove", bodySidePath(dir, key), err)
	}
}

// scrubRetiredDecisionSidecars:判决旁路文件里的明细去掉下架源(scrubRetiredDecision 的规则),胜者是它的那份明细不要,
// 两份都不要了就删文件。返回改写 / 删掉了几个文件。指纹字段不变,主缓存那一槽照样对得上。
func scrubRetiredDecisionSidecars() int {
	dir := decisionSidecarDir()
	if dir == "" {
		return 0
	}
	names, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	n := 0
	for _, ent := range names {
		name := ent.Name()
		if ent.IsDir() || !strings.HasSuffix(name, ".json") {
			continue
		}
		path := filepath.Join(dir, name)
		raw, err := os.ReadFile(path)
		if err != nil || !retiredSourceMentioned(raw) {
			continue
		}
		var rec decisionSidecar
		if json.Unmarshal(raw, &rec) != nil {
			continue
		}
		if !scrubRetiredSidecar(&rec) {
			continue
		}
		if rec.Latest == nil && rec.Applied == nil {
			if os.Remove(path) == nil {
				n++
			}
			continue
		}
		if err := writeDecisionSidecarFile(path, rec); err != nil {
			noteFileErr("write", path, err)
			continue
		}
		n++
	}
	return n
}

// scrubRetiredSidecar:一个旁路文件的两份明细去掉下架源,返回改没改。applied_same 时 applied 那份就是 latest。
func scrubRetiredSidecar(rec *decisionSidecar) bool {
	changed := false
	scrub := func(d *decisionDetails) *decisionDetails {
		if d == nil {
			return nil
		}
		if isRetiredLyricSource(d.Winner) {
			changed = true
			return nil
		}
		cp := *d
		if c, ok := scrubRetiredCandidates(cp.Candidates); ok {
			cp.Candidates, changed = c, true
		}
		if q, ok := scrubRetiredQueries(cp.QueriesTried); ok {
			cp.QueriesTried, changed = q, true
		}
		return &cp
	}
	if rec.AppliedSame && rec.Latest != nil && isRetiredLyricSource(rec.Latest.Winner) {
		rec.AppliedSame = false
	}
	rec.Latest = scrub(rec.Latest)
	rec.Applied = scrub(rec.Applied)
	if rec.Latest == nil && rec.AppliedSame {
		rec.AppliedSame = false
	}
	return changed
}

// scrubRetiredSongSharePres:同步留底里的条目照 scrubRetiredLyricSources 清,返回改写了几个文件。
func scrubRetiredSongSharePres() int {
	dir := songSharePreDir()
	names, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	n := 0
	for _, ent := range names {
		name := ent.Name()
		if ent.IsDir() || !strings.HasSuffix(name, ".json") {
			continue
		}
		path := filepath.Join(dir, name)
		raw, err := os.ReadFile(path)
		if err != nil || !retiredSourceMentioned(raw) {
			continue
		}
		var rec songSharePre
		if json.Unmarshal(raw, &rec) != nil || len(rec.Entry) == 0 {
			continue
		}
		var e enrichEntry
		if json.Unmarshal(rec.Entry, &e) != nil {
			continue
		}
		if changed, _ := scrubRetiredLyricSources(&e); !changed {
			continue
		}
		entry, err := json.Marshal(e)
		if err != nil {
			continue
		}
		rec.Entry = entry
		data, err := json.Marshal(rec)
		if err != nil {
			continue
		}
		if err := writeFileAtomic(path, data); err != nil {
			noteFileErr("write", path, err)
			continue
		}
		n++
	}
	return n
}

// removeRetiredLyricSourceFiles:下架源自己的缓存文件和小时额度里它那一份。返回删掉 / 改写了几个文件。
func removeRetiredLyricSourceFiles() int {
	n := 0
	for _, suffix := range retiredLyricSourceFiles {
		for _, path := range []string{cacheFilePath(clientName + suffix), configFilePath(clientName + suffix)} {
			if filepath.IsAbs(path) && os.Remove(path) == nil {
				n++
			}
		}
	}
	path := configFilePath(clientName + "-source-budget.json")
	raw, err := os.ReadFile(path)
	if err != nil || !filepath.IsAbs(path) {
		return n
	}
	var saved map[string][]int64
	if json.Unmarshal(raw, &saved) != nil {
		return n
	}
	before := len(saved)
	maps.DeleteFunc(saved, func(src string, _ []int64) bool { return isRetiredLyricSource(src) })
	if len(saved) == before {
		return n
	}
	if len(saved) == 0 {
		if os.Remove(path) == nil {
			n++
		}
		return n
	}
	if data, err := json.Marshal(saved); err == nil && writeFileAtomic(path, data) == nil {
		n++
	}
	return n
}

// dropRetiredLyricSourceStats:各源近况统计里下架源的那几份去掉(loadLyricSourceStats 读进来时调,摘要落盘时现算)。
func dropRetiredLyricSourceStats(f *lyricSourceStatsFile) {
	for _, d := range f.Days {
		if d != nil {
			maps.DeleteFunc(d.Sources, func(src string, _ *lyricSourceDayCounts) bool { return isRetiredLyricSource(src) })
		}
	}
	maps.DeleteFunc(f.Recent, func(src string, _ []lyricSourceRecentRound) bool { return isRetiredLyricSource(src) })
	f.Summary = slices.DeleteFunc(f.Summary, func(s lyricSourceStatsSummary) bool { return isRetiredLyricSource(s.Source) })
	for i := range f.Summary {
		f.Summary[i].NetworkPeers = withoutRetiredSources(f.Summary[i].NetworkPeers)
	}
}

// retiredSourceMentioned:文件内容里出现了下架源的名字、它的图床或随它删掉的字段,值得解出来看。
func retiredSourceMentioned(raw []byte) bool {
	lower := bytes.ToLower(raw)
	for _, s := range retiredLyricSources {
		if bytes.Contains(lower, []byte(s)) {
			return true
		}
	}
	for _, h := range retiredLyricSourceCoverHosts {
		if bytes.Contains(lower, []byte(h)) {
			return true
		}
	}
	for _, k := range retiredEnrichKeys {
		if bytes.Contains(raw, []byte(`"`+k+`"`)) {
			return true
		}
	}
	return false
}
