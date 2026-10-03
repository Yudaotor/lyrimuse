package main

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 全量扫库跑到一半换了打分版本:另起一场(起点刷新),不然本场跑过的条目会被整批跳过。
func TestFullScanVersionBumpRestartsPass(t *testing.T) {
	saved := lyricsFullScanStatePath
	t.Cleanup(func() {
		lyricsFullScanMu.Lock()
		lyricsFullScanStatePath = saved
		lyricsFullScanMu.Unlock()
	})
	for _, active := range []bool{true, false} {
		path := filepath.Join(t.TempDir(), "fullscan.json")
		old := lyricsFullScanState{ScoringVersion: lyricsScoringVersion - 1, Active: active, Done: 5}
		if active {
			old.StartedAt = 100
		}
		data, _ := json.Marshal(old)
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		setLyricsFullScanStatePath(path)
		got := readLyricsFullScanState()
		if got.Done != 0 || got.ScoringVersion != lyricsScoringVersion {
			t.Fatalf("active=%v: 版本变了计数应清零: %+v", active, got)
		}
		if active && got.StartedAt <= 100 {
			t.Errorf("正在跑的一场换了版本,起点应刷新: %d", got.StartedAt)
		}
		if !active && got.StartedAt != 0 {
			t.Errorf("没在跑的不该凭空有起点: %d", got.StartedAt)
		}
	}
}

// 重评:当前这份没参与比较、又是这一版规则打的分时,冠军不比它高就不换。
func TestRescoreKeepsCurrent(t *testing.T) {
	cur := enrichEntry{Lyrics: "old", LyricsSource: "lrclib", LyricsScore: 820, LyricsScoringVersion: lyricsScoringVersion}
	winner := &scoredLyricCandidateResult{Source: "migu", Lyrics: "new", Score: 500}
	other := []scoredLyricCandidateResult{{Source: "lrclib", Lyrics: "another version", Score: -1}, *winner}
	cases := []struct {
		name   string
		e      enrichEntry
		scored []scoredLyricCandidateResult
		picked *scoredLyricCandidateResult
		want   bool
	}{
		{"当前这份没进比较、冠军更低", cur, other, winner, true},
		{"当前这份参与了比较、输了就换", cur, append(other, scoredLyricCandidateResult{Source: "lrclib", Lyrics: "old", Score: 400}), winner, false},
		{"冠军更高", cur, other, &scoredLyricCandidateResult{Source: "migu", Lyrics: "new", Score: 900}, false},
		{"旧版本的分数不比", enrichEntry{Lyrics: "old", LyricsScore: 820, LyricsScoringVersion: lyricsScoringVersion - 1}, other, winner, false},
		{"冠军就是当前这份", cur, other, &scoredLyricCandidateResult{Lyrics: "old", Score: 100}, false},
	}
	for _, c := range cases {
		if got := rescoreKeepsCurrent(c.e, c.scored, c.picked); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 回填:确定没发出去 / 服务端明确没收的批次不隔离;排在重发队列里、已经交过的这边不发。
func TestBackfillBatchClassificationAndRecheck(t *testing.T) {
	notSent := errors.Join(errScrobbleBatchNotSent, errors.New("context deadline exceeded"))
	cases := []struct {
		err  error
		want bool
	}{
		{notSent, true},
		{&net.DNSError{Err: "no such host", Name: "ws.audioscrobbler.com"}, true},
		{&lastfmAPIError{Code: 29}, true},
		{&lastfmAPIError{Code: 16}, false},
		{errors.New("unexpected EOF"), false},
	}
	for _, c := range cases {
		if got := backfillBatchNeverStored(c.err); got != c.want {
			t.Errorf("%v: got %v, want %v", c.err, got, c.want)
		}
	}

	dir := t.TempDir()
	savedLog, savedRetry := listenLogPath, lfmRetryPath
	t.Cleanup(func() { listenLogPath, lfmRetryPath = savedLog, savedRetry })
	listenLogPath = filepath.Join(dir, "l.jsonl")
	lfmRetryPath = filepath.Join(dir, "retry.json")
	now := time.Now()
	base := now.Add(-time.Hour).Unix()
	for i, title := range []string{"keep", "submitted", "queued"} {
		appendListen("A", title, "al", base+int64(i), 200)
	}
	batch, _ := pendingBackfillListens(now)
	markBackfilled(base + 1)
	data, _ := json.Marshal([]lfmRetryItem{{Timestamp: base + 2, Title: "queued"}})
	if err := os.WriteFile(lfmRetryPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	got := stillPendingForBackfill(batch, now)
	if len(got) != 1 || got[0].TI != "keep" {
		t.Fatalf("只该剩下 keep: %+v", got)
	}
}

// 拆出候选明细之后,MV 配专辑要的歌曲版时长还在。
func TestStripDecisionKeepsSongDuration(t *testing.T) {
	d := &lyricsDecision{Winner: "qq", Candidates: []lyricsDecisionCandidate{
		{Source: "netease", SourceReportedDurationSecs: 250},
		{Source: "qq", SourceReportedDurationSecs: 241},
	}}
	stripped := stripDecision(d)
	if len(stripped.Candidates) != 0 {
		t.Fatal("前提:拆完不带候选")
	}
	if got := decisionSongDurationSecs(stripped); got != 241 {
		t.Fatalf("拆完的歌曲版时长 = %v, want 241", got)
	}
}

// 同专辑借封面:专辑名繁简不同也认。
func TestSiblingCoverMatchesAcrossScript(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"周杰倫|稻香|魔杰座": {CoverURL: "https://example.invalid/c.jpg", CoverSource: "qq"},
	})
	enrichMu.Lock()
	url, _ := siblingCoverLocked("", "周杰倫", "魔杰座", false)
	enrichMu.Unlock()
	if url == "" {
		t.Fatal("前提:同写法能借到")
	}
	withEnrichCache(t, map[string]enrichEntry{
		"周杰倫|稻香|回到過去": {CoverURL: "https://example.invalid/c.jpg", CoverSource: "qq"},
	})
	enrichMu.Lock()
	url, _ = siblingCoverLocked("", "周杰倫", "回到过去", false)
	enrichMu.Unlock()
	if url == "" {
		t.Fatal("简体专辑名应当借得到繁体写法那张专辑的封面")
	}
}

// 导入换了正文:按旧正文生成的机翻和罗马音清掉;歌词源自带的译文不动。
func TestImportDropsStaleMachineTranslationAndRoma(t *testing.T) {
	key := "歌手|歌名|专辑"
	for _, trSource := range []string{lyricsTrSourceMachine, ""} {
		dir := withExportFixture(t, map[string]enrichEntry{key: {
			Lyrics: "[00:01.00]原文", LyricsTr: "[00:01.00]译文", LyricsTrSource: trSource,
			LyricsRoma: "[00:01.00]yuan wen", LyricsSource: "netease",
		}})
		exportLyricsFiles()
		p := filepath.Join(dir, sanitizeLyricsFilename(key)+".lrc")
		orig := string(mustRead(t, p))
		if err := os.WriteFile(p, []byte(strings.Replace(orig, "原文", "改过的原文", 1)), 0o644); err != nil {
			t.Fatal(err)
		}
		importLyricsFrom(dir, false)
		e := enrichCache[key]
		if e.Lyrics != "[00:01.00]改过的原文" || e.LyricsRoma != "" {
			t.Fatalf("trSource=%q: 正文应采纳、旧罗马音应清掉: %+v", trSource, e)
		}
		if wantTr := trSource != lyricsTrSourceMachine; (e.LyricsTr != "") != wantTr {
			t.Fatalf("trSource=%q: 译文 = %q", trSource, e.LyricsTr)
		}
	}
}

// 碰撞组缩回一个 key 后留下的 `~hash` 旧文件:导出顺手清掉;清掉之前导入按修改时间让新的那组赢。
func TestStaleDisambiguatedFilesLoseAndGetRemoved(t *testing.T) {
	key := "歌手|歌名|专辑"
	dir := withExportFixture(t, map[string]enrichEntry{key: {Lyrics: "[00:01.00]新的", LyricsSource: "netease"}})
	exportLyricsFiles()
	header := lyricsFileHeader("歌手", "歌名", "专辑", "netease", false)
	hashed := filepath.Join(dir, lyricsDisambiguatedBase(key)+".lrc")
	if err := os.WriteFile(hashed, []byte(header+"[00:01.00]旧的"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(hashed, old, old); err != nil {
		t.Fatal(err)
	}
	for range 10 {
		importLyricsFrom(dir, false)
		if got := enrichCache[key].Lyrics; got != "[00:01.00]新的" {
			t.Fatalf("旧的 ~hash 文件不该赢: %q", got)
		}
	}
	exportLyricsFiles()
	if _, err := os.Stat(hashed); !os.IsNotExist(err) {
		t.Fatalf("导出应当清掉 ~hash 旧文件: %v", err)
	}
}

// key 归一化迁移:每次真的合并都另留一份这次要并掉的条目。
func TestKeyMigrationBacksUpEachMerge(t *testing.T) {
	dir := withTempDecisionCache(t)
	enrichMu.Lock()
	enrichCache["a|t|b"] = enrichEntry{Lyrics: "one"}
	enrichCache["a|t |b"] = enrichEntry{Lyrics: "two"}
	err := backupEnrichKeyMergeGroups(map[string][]string{"a|t|b": {"a|t|b", "a|t |b"}, "c|d|e": {"c|d|e"}})
	enrichMu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	matches, _ := filepath.Glob(filepath.Join(dir, "*.keynorm-*.bak"))
	if len(matches) != 1 {
		t.Fatalf("应当写一份合并备份: %v", matches)
	}
	var got map[string]enrichEntry
	if err := json.Unmarshal(mustRead(t, matches[0]), &got); err != nil || len(got) != 2 {
		t.Fatalf("备份里应当正好是要合并的两条: %v %v", got, err)
	}
}
