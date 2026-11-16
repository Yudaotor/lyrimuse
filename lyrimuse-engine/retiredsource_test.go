package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

const retiredTestLRC = "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句"

// 歌词来源是下架源的条目整族清空(手改、锁定、选定来源的也算),别的源的条目只去掉下架源留下的东西,自己的歌词原样。
func TestScrubRetiredLyricSources(t *testing.T) {
	retired := retiredLyricSources[0]
	mxCover := "https://s." + retiredLyricSourceCoverHosts[0] + "/images-storage/albums/1/2_500_500.jpg"
	mine := enrichEntry{
		Lyrics: bt(retiredTestLRC), LyricsYRC: bt("[1000,500](1000,500,0)第一句"), LyricsTr: bt("[00:01.00]one"),
		LyricsSource: retired, LyricsScore: 900, ManualLyrics: true, ManualPickSHA: "abc", LyricsSourceChoice: retired,
		LyricsSourcesSeen: []string{retired, "qq"}, LyricsRetryCount: 3, LyricsFillCount: 2, LyricsRescoreVersion: 9,
		LyricsDecision: &lyricsDecision{Winner: retired}, CoverURL: "https://p1.music.126.net/a.jpg", DurationSecs: 200,
	}
	changed, reset := scrubRetiredLyricSources(&mine)
	if !changed || !reset {
		t.Fatalf("来源是下架源:changed=%v reset=%v", changed, reset)
	}
	if !mine.Lyrics.IsZero() || !mine.LyricsYRC.IsZero() || !mine.LyricsTr.IsZero() || mine.LyricsSource != "" ||
		mine.ManualLyrics || mine.ManualPickSHA != "" || mine.LyricsSourceChoice != "" || mine.LyricsDecision != nil ||
		mine.LyricsSourcesSeen != nil || mine.LyricsRetryCount != 0 || mine.LyricsFillCount != 0 || mine.LyricsRescoreVersion != 0 {
		t.Errorf("歌词那一族、手改与选定、出处、退避账都该清掉: %+v", mine)
	}
	if mine.CoverURL != "https://p1.music.126.net/a.jpg" || mine.DurationSecs != 200 {
		t.Errorf("跟歌词无关的封面、时长留着: %+v", mine)
	}

	shared := &lyricsDecision{Winner: "qq", SourcesResponded: []string{"qq", retired}, SourcesSkipped: []string{retired},
		Candidates: []lyricsDecisionCandidate{
			{Source: "qq", Score: 900, ConsensusPeers: []string{retired, "kugou"}},
			{Source: retired, Score: 800, CoverURL: mxCover},
		},
		QueriesTried: []lyricQueryRecord{{Artist: "a", Sources: []string{retired}}, {Artist: "b", Sources: []string{"qq", retired}}, {Artist: "c"}},
	}
	other := enrichEntry{
		Lyrics: bt(retiredTestLRC), LyricsSource: "qq", LyricsTr: bt("[00:01.00]one"), LyricsTrSource: "borrowed:" + retired,
		LyricsTrLang: "en", PlainLyrics: bt("纯文本"), PlainLyricsSource: retired, CoverURL: mxCover, CoverSource: retired,
		AccentColor: "#112233", CoverSettled: mxCover, MotionCoverFor: mxCover, MotionCoverChecked: true,
		PublicCoverURL: mxCover, PublicCoverFor: "file:///x.jpg",
		PlayerLyrics:      map[string]playerLyricsAlt{"com.spotify.client": {Source: retired}, "com.apple.Music": {Source: "applemusic"}},
		LyricsSourcesSeen: []string{"qq", retired}, LyricsSourcesResponded: []string{retired},
		LyricsSourcesSkipped: []string{retired, "kuwo"}, LyricsSourcesEnabled: []string{"qq", retired},
		LyricsDecision: shared, LyricsDecisionApplied: shared,
	}
	changed, reset = scrubRetiredLyricSources(&other)
	if !changed || reset {
		t.Fatalf("别的源的条目:changed=%v reset=%v", changed, reset)
	}
	if !other.Lyrics.EqualString(retiredTestLRC) || other.LyricsSource != "qq" {
		t.Errorf("自己的歌词原样: %+v", other)
	}
	if !other.LyricsTr.IsZero() || other.LyricsTrSource != "" || !other.PlainLyrics.IsZero() || other.PlainLyricsSource != "" {
		t.Errorf("借来的译文、它给的纯文本清掉: tr=%q plain=%q", other.LyricsTr, other.PlainLyrics)
	}
	if other.CoverURL != "" || other.CoverSource != "" || other.AccentColor != "" || other.CoverSettled != "" ||
		other.MotionCoverFor != "" || other.MotionCoverChecked || other.PublicCoverURL != "" {
		t.Errorf("它图床上的封面连同主色、定下的封面、动态封面结论清掉: %+v", other)
	}
	if _, ok := other.PlayerLyrics["com.spotify.client"]; ok || len(other.PlayerLyrics) != 1 {
		t.Errorf("按播放器存的只去掉它那份: %+v", other.PlayerLyrics)
	}
	if !slices.Equal(other.LyricsSourcesSeen, []string{"qq"}) || other.LyricsSourcesResponded != nil ||
		!slices.Equal(other.LyricsSourcesSkipped, []string{"kuwo"}) || !slices.Equal(other.LyricsSourcesEnabled, []string{"qq"}) {
		t.Errorf("源名单去掉它: %+v", other)
	}
	d := other.LyricsDecision
	if d == nil || d == shared || other.LyricsDecisionApplied != d {
		t.Fatalf("判决换成新拷贝,两槽共用的照旧共用: %p %p %p", shared, d, other.LyricsDecisionApplied)
	}
	if !slices.Equal(d.SourcesResponded, []string{"qq"}) || d.SourcesSkipped != nil || len(d.Candidates) != 1 ||
		!slices.Equal(d.Candidates[0].ConsensusPeers, []string{"kugou"}) || len(d.QueriesTried) != 2 ||
		!slices.Equal(d.QueriesTried[0].Sources, []string{"qq"}) {
		t.Errorf("判决里去掉它的候选、名单和只问它的查询: %+v", d)
	}
	if len(shared.Candidates) != 2 {
		t.Error("原来的判决对象不能原地改")
	}

	clean := enrichEntry{Lyrics: bt(retiredTestLRC), LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou"},
		LyricsDecision: &lyricsDecision{Winner: "kugou", SourcesResponded: []string{"kugou"}}}
	before, _ := json.Marshal(clean)
	if changed, _ := scrubRetiredLyricSources(&clean); changed {
		t.Error("跟下架源无关的条目不算改过")
	}
	if after, _ := json.Marshal(clean); string(after) != string(before) {
		t.Errorf("跟下架源无关的条目一个字节都不动:\n%s\n%s", before, after)
	}
}

// 胜者是下架源的那一槽判决整槽不要,另一槽照常只去名单。
func TestScrubRetiredDecisionDropsRetiredWinner(t *testing.T) {
	retired := retiredLyricSources[0]
	e := enrichEntry{Lyrics: bt(retiredTestLRC), LyricsSource: "qq",
		LyricsDecision:        &lyricsDecision{Winner: retired},
		LyricsDecisionApplied: &lyricsDecision{Winner: "qq", SourcesResponded: []string{"qq", retired}}}
	scrubRetiredLyricSources(&e)
	if e.LyricsDecision != nil || e.LyricsDecisionApplied == nil || !slices.Equal(e.LyricsDecisionApplied.SourcesResponded, []string{"qq"}) {
		t.Errorf("latest=%+v applied=%+v", e.LyricsDecision, e.LyricsDecisionApplied)
	}
}

func TestRetiredLyricSourceCover(t *testing.T) {
	host := retiredLyricSourceCoverHosts[0]
	for u, want := range map[string]bool{
		"https://s." + host + "/a_500_500.jpg":      true,
		"http://" + host + "/a.jpg":                 true,
		"https://S." + strings.ToUpper(host) + "/a": true,
		"https://evil" + host + "/a.jpg":            false,
		"https://example.com/" + host + "/a.jpg":    false,
		"":                                          false,
		"file:///Users/x/" + host + ".jpg":          false,
	} {
		if got := retiredLyricSourceCover(u); got != want {
			t.Errorf("%q: got %v want %v", u, got, want)
		}
	}
}

// 整条迁移:只清下架源的条目、连同导出文件 / 正文小文件 / 判决旁路文件 / 同步留底 / 它自己的缓存文件 / 额度里它那一份,
// 别的源的条目和文件原样;记了水位之后再启动不再跑。
func TestPurgeRetiredLyricSources(t *testing.T) {
	retired := retiredLyricSources[0]
	withTempMigrationState(t)
	dir := withTempDecisionCache(t)
	lyrics := withLyricsDir(t)
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	cache := t.TempDir()
	t.Setenv("LYRIMUSE_CACHE_DIR", cache)

	const gone, kept, touched = "A|Retired Song|Album", "B|Kept Song|Album", "C|Other Song|Album"
	mxCover := "https://s." + retiredLyricSourceCoverHosts[0] + "/a_500_500.jpg"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{
		gone:    {Lyrics: bt(retiredTestLRC), LyricsSource: retired, ManualLyrics: true, LyricsDecision: &lyricsDecision{Winner: retired}},
		kept:    {Lyrics: bt(retiredTestLRC), LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou"}},
		touched: {Lyrics: bt(retiredTestLRC), LyricsSource: "qq", CoverURL: mxCover, LyricsSourcesSeen: []string{"qq", retired}},
	}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	exportLyricsFiles()
	if len(lyricsFilesOwnedBy(gone)) == 0 || len(lyricsFilesOwnedBy(kept)) == 0 {
		t.Fatal("用例前提:两首都导出了歌词文件")
	}
	bodies := enrichBodiesDir()
	if err := os.MkdirAll(bodies, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{gone, kept} {
		if err := os.WriteFile(bodySidePath(bodies, k), []byte(`{}`), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	sidecars := decisionSidecarDir()
	if err := os.MkdirAll(sidecars, 0o755); err != nil {
		t.Fatal(err)
	}
	writeSidecar := func(key string, rec decisionSidecar) {
		if err := writeDecisionSidecarFile(filepath.Join(sidecars, decisionSidecarName(key)), rec); err != nil {
			t.Fatal(err)
		}
	}
	writeSidecar(gone, decisionSidecar{Key: gone, Latest: &decisionDetails{Winner: retired, Candidates: []lyricsDecisionCandidate{{Source: retired}}}})
	writeSidecar(touched, decisionSidecar{Key: touched, Latest: &decisionDetails{Winner: "qq",
		Candidates: []lyricsDecisionCandidate{{Source: "qq"}, {Source: retired, CoverURL: mxCover}}}, AppliedSame: true})
	writeSidecar(kept, decisionSidecar{Key: kept, Latest: &decisionDetails{Winner: "kugou", Candidates: []lyricsDecisionCandidate{{Source: "kugou"}}}})
	keptSidecar, _ := os.ReadFile(filepath.Join(sidecars, decisionSidecarName(kept)))

	pre := songSharePreDir()
	if err := os.MkdirAll(pre, 0o700); err != nil {
		t.Fatal(err)
	}
	preEntry, _ := json.Marshal(enrichEntry{Lyrics: bt(retiredTestLRC), LyricsSource: retired})
	preRec, _ := json.Marshal(songSharePre{Key: gone, SavedAt: 1, Entry: preEntry})
	if err := os.WriteFile(songSharePrePath(gone), preRec, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range retiredLyricSourceFiles {
		for _, p := range []string{cacheFilePath(clientName + suffix), configFilePath(clientName + suffix)} {
			if err := os.WriteFile(p, []byte(`{}`), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	budget := configFilePath(clientName + "-source-budget.json")
	if err := os.WriteFile(budget, []byte(`{"`+retired+`":[1],"deezer":[2]}`), 0o600); err != nil {
		t.Fatal(err)
	}

	purgeRetiredLyricSources()

	enrichMu.Lock()
	g, k, o := enrichCache[gone], enrichCache[kept], enrichCache[touched]
	enrichMu.Unlock()
	if !g.Lyrics.IsZero() || g.LyricsSource != "" || g.ManualLyrics || g.LyricsDecision != nil {
		t.Errorf("下架源的条目(手改锁定的也算)清空: %+v", g)
	}
	if !k.Lyrics.EqualString(retiredTestLRC) || k.LyricsSource != "kugou" {
		t.Errorf("别的源的条目原样: %+v", k)
	}
	if !o.Lyrics.EqualString(retiredTestLRC) || o.CoverURL != "" || !slices.Equal(o.LyricsSourcesSeen, []string{"qq"}) {
		t.Errorf("别的源的条目只去掉下架源留下的: %+v", o)
	}
	if len(lyricsFilesOwnedBy(gone)) != 0 || len(lyricsFilesOwnedBy(kept)) == 0 {
		t.Errorf("只删下架源那首的歌词文件: gone=%v kept=%v", lyricsFilesOwnedBy(gone), lyricsFilesOwnedBy(kept))
	}
	if entries, _ := os.ReadDir(lyrics); len(entries) == 0 {
		t.Error("歌词文件夹里别的文件留着")
	}
	if _, err := os.Stat(bodySidePath(bodies, gone)); !os.IsNotExist(err) {
		t.Errorf("清空那首的正文小文件删掉: %v", err)
	}
	if _, err := os.Stat(bodySidePath(bodies, kept)); err != nil {
		t.Errorf("别的正文小文件留着: %v", err)
	}
	if _, err := os.Stat(filepath.Join(sidecars, decisionSidecarName(gone))); !os.IsNotExist(err) {
		t.Errorf("清空那首的判决旁路文件删掉: %v", err)
	}
	rec := readDecisionSidecar(filepath.Join(sidecars, decisionSidecarName(touched)))
	if rec == nil || rec.Latest == nil || len(rec.Latest.Candidates) != 1 || rec.Latest.Candidates[0].Source != "qq" || !rec.AppliedSame {
		t.Errorf("别的判决旁路文件只去掉它的候选: %+v", rec)
	}
	if b, _ := os.ReadFile(filepath.Join(sidecars, decisionSidecarName(kept))); string(b) != string(keptSidecar) {
		t.Error("跟它无关的判决旁路文件一个字节都不动")
	}
	if b, _ := os.ReadFile(songSharePrePath(gone)); strings.Contains(string(b), retired) || !strings.Contains(string(b), `"key"`) {
		t.Errorf("同步留底里那份条目清掉它: %s", b)
	}
	for _, suffix := range retiredLyricSourceFiles {
		for _, p := range []string{cacheFilePath(clientName + suffix), configFilePath(clientName + suffix)} {
			if _, err := os.Stat(p); !os.IsNotExist(err) {
				t.Errorf("它自己的缓存文件删掉: %s", p)
			}
		}
	}
	if b, _ := os.ReadFile(budget); string(b) != `{"deezer":[2]}` {
		t.Errorf("小时额度里只去掉它那一份: %s", b)
	}
	if !migrationDone(migrationRetiredLyricSources, migrationRetiredLyricSourcesVersion) {
		t.Fatal("跑完记水位")
	}

	// 记了水位:再启动整道跳过,之后新写进来的东西不再碰。
	enrichMu.Lock()
	enrichCache[gone] = enrichEntry{Lyrics: bt(retiredTestLRC), LyricsSource: retired}
	enrichMu.Unlock()
	purgeRetiredLyricSources()
	enrichMu.Lock()
	again := enrichCache[gone]
	enrichMu.Unlock()
	if again.LyricsSource != retired {
		t.Error("水位到了就不再跑")
	}
}

// 各源近况统计读进来时剔掉下架源那几份,摘要里的网络同伴名单也去掉它。
func TestDropRetiredLyricSourceStats(t *testing.T) {
	retired := retiredLyricSources[0]
	f := lyricSourceStatsFile{
		Days:    map[string]*lyricSourceStatsDay{"2026-11-01": {Sources: map[string]*lyricSourceDayCounts{retired: {Asked: 1}, "qq": {Asked: 2}}}},
		Recent:  map[string][]lyricSourceRecentRound{retired: {{At: 1}}, "qq": {{At: 2}}},
		Summary: []lyricSourceStatsSummary{{Source: retired}, {Source: "lrclib", NetworkPeers: []string{retired, "deezer"}}},
	}
	dropRetiredLyricSourceStats(&f)
	if _, ok := f.Days["2026-11-01"].Sources[retired]; ok || f.Days["2026-11-01"].Sources["qq"] == nil {
		t.Errorf("按天计数: %+v", f.Days["2026-11-01"].Sources)
	}
	if _, ok := f.Recent[retired]; ok || len(f.Recent["qq"]) != 1 {
		t.Errorf("逐轮记录: %+v", f.Recent)
	}
	if len(f.Summary) != 1 || f.Summary[0].Source != "lrclib" || !slices.Equal(f.Summary[0].NetworkPeers, []string{"deezer"}) {
		t.Errorf("摘要: %+v", f.Summary)
	}
}

// 引擎和 App 各有一份下架源名单(App 加载设置时剔掉它们),两份必须一致。
func TestRetiredLyricSourcesMatchSwift(t *testing.T) {
	b, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Models/RetiredLyricsSources.swift")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "names: Set<String> = [")
	if i < 0 {
		t.Fatal("App 侧找不到 RetiredLyricsSources.names")
	}
	body := src[i+len("names: Set<String> = ["):]
	body = body[:strings.Index(body, "]")]
	var swift []string
	for _, part := range strings.Split(body, ",") {
		if s := strings.Trim(strings.TrimSpace(part), `"`); s != "" {
			swift = append(swift, s)
		}
	}
	slices.Sort(swift)
	engine := slices.Clone(retiredLyricSources)
	slices.Sort(engine)
	if !slices.Equal(swift, engine) {
		t.Fatalf("两份下架源名单不一致:\n  App:  %v\n  引擎: %v", swift, engine)
	}
}

// 随下架源整列删掉的字段(retiredEnrichKeys):主缓存和同步留底里都清掉,别的不认识的键照旧原样留着;没有这些键的条目
// 不算改动。
func TestPurgeRetiredEnrichKeys(t *testing.T) {
	withTempMigrationState(t)
	dir := withTempDecisionCache(t)
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	t.Setenv("LYRIMUSE_CACHE_DIR", t.TempDir())

	decode := func(raw string) enrichEntry {
		var e enrichEntry
		if err := json.Unmarshal([]byte(raw), &e); err != nil {
			t.Fatal(err)
		}
		return e
	}
	const both, only, clean = "A|Duet|Album", "B|Solo|Album", "C|Plain|Album"
	withBoth := decode(`{"lyrics_source":"qq","lyrics_speakers":{"for":"a9","lrc":["v1"]},"lyrics_speakers_checked":1,"future_field":7}`)
	withOnly := decode(`{"lyrics_source":"kugou","lyrics_speakers_checked":1}`)
	if len(withBoth.Unknown) != 3 || len(withOnly.Unknown) != 1 {
		t.Fatalf("用例前提:这些键这个构建不认识: %v %v", withBoth.Unknown, withOnly.Unknown)
	}
	plain := decode(`{"lyrics_source":"qq","future_field":7}`)
	if changed, _ := scrubRetiredLyricSources(&plain); changed || len(plain.Unknown) != 1 {
		t.Fatalf("没有这些键的条目不算改动、别的未知键不动: changed=%v %v", changed, plain.Unknown)
	}
	original := withBoth.Unknown
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{both: withBoth, only: withOnly, clean: decode(`{"lyrics_source":"qq"}`)}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()

	pre := songSharePreDir()
	if err := os.MkdirAll(pre, 0o700); err != nil {
		t.Fatal(err)
	}
	preRec, _ := json.Marshal(songSharePre{Key: both, SavedAt: 1, Entry: json.RawMessage(`{"lyrics_source":"qq","lyrics_speakers_checked":1}`)})
	if err := os.WriteFile(songSharePrePath(both), preRec, 0o600); err != nil {
		t.Fatal(err)
	}

	purgeRetiredLyricSources()

	enrichMu.Lock()
	gotBoth, gotOnly := enrichCache[both], enrichCache[only]
	enrichMu.Unlock()
	if _, ok := gotBoth.Unknown["future_field"]; !ok || len(gotBoth.Unknown) != 1 || gotBoth.LyricsSource != "qq" {
		t.Errorf("只去掉随它删掉的键,别的未知键留着: %v", gotBoth.Unknown)
	}
	if gotOnly.Unknown != nil {
		t.Errorf("清空了就不留空表: %v", gotOnly.Unknown)
	}
	if len(original) != 3 {
		t.Errorf("改的是拷贝,原来那份未知键表不动: %v", original)
	}
	if b, _ := os.ReadFile(enrichPath); bytes.Contains(b, []byte("lyrics_speakers")) || !bytes.Contains(b, []byte("future_field")) {
		t.Errorf("落盘的主缓存里不再有这些键: %s", b)
	}
	if b, _ := os.ReadFile(songSharePrePath(both)); bytes.Contains(b, []byte("lyrics_speakers")) || !bytes.Contains(b, []byte(`"qq"`)) {
		t.Errorf("同步留底里那份条目也清掉: %s", b)
	}
}
