//go:build devtools

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 偏移键里的歌词指纹跟 App 的 LyricsOffsetStore.contentFingerprint 同一算法:开头的 BOM 不算,两样都空时是空串。
func TestSongOffsetFingerprint(t *testing.T) {
	if got := songOffsetFingerprint("a", "b"); got != "82d34c7d68cf" {
		t.Errorf("指纹 = %q", got)
	}
	if songOffsetFingerprint("\uFEFFa", "\uFEFFb") != songOffsetFingerprint("a", "b") {
		t.Error("开头的 BOM 不算内容")
	}
	if songOffsetFingerprint("", "") != "" {
		t.Error("没有歌词时指纹为空")
	}
}

// 空跑:现有几份里逐字的胜出;自家源加分的、换过去会丢逐字的留着自己那份;没词的补上;手改同步到整个实体、不受自家源和
// 逐字约束;两份手改不替用户选;有校准的跟着校准;换词后偏移对不上、能读穿接上的分别记。
func TestSongEntitySharePlan(t *testing.T) {
	lrc := func(seed string) string { return songTestLRC(0, songTestWords(seed, 4)) }
	entry := func(isrc, seed, yrc, source string) enrichEntry {
		e := enrichEntry{DurationSecs: 200, ISRCs: []string{isrc}, LyricsSource: source}
		if seed != "" {
			e.Lyrics = bt(lrc(seed))
		}
		e.LyricsYRC = bt(yrc)
		return e
	}
	decided := func(v songVariant, source string, version, score, native int) songVariant {
		c := lyricsDecisionCandidate{Source: source, Score: score + native}
		if native > 0 {
			c.ScoreTerms = []scoreTerm{{Kind: scoreTermNativeSource, Points: native}}
		}
		v.applied = &lyricsDecision{Winner: source, ScoringVersion: version, Candidates: []lyricsDecisionCandidate{c}}
		return v
	}
	manual := func(v songVariant) songVariant { v.manual = true; return v }
	pinned := func(v songVariant) songVariant { v.pinned = true; return v }
	vs := []songVariant{
		decided(songTestVariant("A|Song|Album1", entry("USAAA1100001", "a1", "", "qq"), nil), "qq", 28, 900, 0),
		decided(songTestVariant("A|Song|Album2", entry("USAAA1100001", "a2", "y2", "kugou"), nil), "kugou", 27, 1200, 0),
		decided(songTestVariant("A|Song|Album3", entry("USAAA1100001", "a3", "y3", "applemusic"), nil), "applemusic", 25, 1100, 250),
		songTestVariant("A|Song|Album4", entry("USAAA1100001", "", "", ""), nil),
		songTestVariant("A|Song|Album5", entry("USAAA1100001", "a5", "", "lrclib"), nil),
		manual(songTestVariant("B|Tune|X", entry("USAAA1100002", "b1", "", "manual"), nil)),
		decided(songTestVariant("B|Tune|Y", entry("USAAA1100002", "b2", "yb", "qq"), nil), "qq", 25, 1000, 0),
		decided(songTestVariant("B|Tune|Z", entry("USAAA1100002", "b3", "yz", "applemusic"), nil), "applemusic", 25, 1000, 250),
		manual(songTestVariant("C|Air|1", entry("USAAA1100003", "c1", "", "manual"), nil)),
		songTestVariant("C|Air|2", entry("USAAA1100003", "c2", "", "qq"), nil),
		pinned(songTestVariant("D|Wind|1", entry("USAAA1100004", "d1", "", "netease"), nil)),
		songTestVariant("D|Wind|2", entry("USAAA1100004", "d2", "yd", "qq"), nil),
		songTestVariant("D|Wind|3", entry("USAAA1100004", "d3", "", "kugou"), nil),
	}
	b, _ := songTestBuild(t, vs, nil)
	fp := func(key string) string {
		for i := range b.variants {
			if b.variants[i].key == key {
				return songOffsetFingerprint(b.variants[i].lyrics.String(), b.variants[i].yrc.String())
			}
		}
		t.Fatalf("没有 %s", key)
		return ""
	}
	offsets := map[string]int{
		"A|Song|" + fp("A|Song|Album1"): 300,
		"A|Song|" + fp("A|Song|Album2"): 500,
		"B|Tune|" + fp("B|Tune|Y"):      200,
	}
	var out bytes.Buffer
	b.writeSharePlan(&out, map[string]bool{"C|Air|2": true}, offsets)
	s := out.String()
	for _, want := range []string{
		"多写法的歌 4 首,其中两条写法以上的共享组 4 个",
		"会动的:整首跟着手改 1 首,共享组跟着校准 1 个,共享组在现有几份里挑 1 个;不替你选的:两份手改或手改跟校准不同 1 首,两份校准 0 个",
		"换词的写法 5 条(原来是自家源加分选的 1 条,换成打分版本更新的 1 条,同版本换成分数更低的 0 条);没词补上的 1 条",
		"按不变式 6 留着自己那份的 2 条:自己的手改或校准 0、在放播放器自家的词 1、有逐字 1、有时间轴 0",
		"单曲偏移 3 条,指纹对得上某条写法现在的歌词的 3 条;换词后对不上 1 条,读穿能接上 1 条",
		"    换  A|Song|Album1  qq 900 分@v28 逐行  →  kugou 1200 分@v27 逐字",
		"    留  A|Song|Album3  applemusic 1100 分@v25 逐字(在放播放器自家的词)",
		"    补  A|Song|Album4",
		"    偏移 A|Song|Album1  原来 300 毫秒,换词后读穿接上 500 毫秒",
		"    换  B|Tune|Z  applemusic 1000 分@v25 逐字  →  manual 分数不知道 逐行",
		"    偏移 B|Tune|Y  原来 200 毫秒,换词后对不上",
		"  两份手改(或手改跟校准不同),不替你选:",
		"    留  D|Wind|2  qq 分数不知道 逐字(有逐字,换过去就没了)",
		"    换  D|Wind|3  kugou 分数不知道 逐行  →  netease 分数不知道 逐行",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("缺这一行:%s\n全文:\n%s", want, s)
		}
	}
	if strings.Contains(s, "    换  C|Air") {
		t.Errorf("两份手改时不该换词:\n%s", s)
	}
}

// 关着「随匹配算法更新重新选择」:没词的照补,已经有词的一律留(补逐字也不补),理由写明是开关。
func TestShareEvalPlanAutoUpgradeOff(t *testing.T) {
	lrc := func(seed string) string { return songTestLRC(0, songTestWords(seed, 4)) }
	keys := []string{"e0", "e1", "e2"}
	entries := []enrichEntry{{}, {Lyrics: bt(lrc("c")), LyricsSource: "netease"}, {Lyrics: bt(lrc("l4")), LyricsSource: "qq"}}
	scored := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: lrc("c"), LyricsYRC: "[0,500]y", Score: 1200},
		{Source: "qq", Lyrics: lrc("l4"), Score: 900},
	}
	got := map[string]songEvalLine{}
	for _, l := range shareEvalPlan(keys, entries, []*songPlanLyrics{nil, {}, {}}, scored, &scored[0], false) {
		got[l.key] = l
	}
	if got["e0"].action != "补" {
		t.Errorf("没词的照补: %+v", got["e0"])
	}
	if _, ok := got["e1"]; ok {
		t.Errorf("正文相同只缺逐字的不补逐字: %+v", got["e1"])
	}
	if l := got["e2"]; l.action != "留" || l.why != songKeepNoUpgrade {
		t.Errorf("有词的留、理由是开关: %+v", l)
	}
}

// 正式空跑的去留:没词的补,正文相同只缺逐字的补逐字,纯音乐跳过;自家源的、自己手改的留着;其余跟自动重评同一套 —— 来源这一轮
// 没应答的、没参与比较而冠军不比它存的分高的、会丢逐字的、换过去屏上看不出差别的留着,另一首歌的词一律不留;再加会丢时间轴的
// 留着,只有署名的不算。其余换,现有那份这一轮找得到时带上它这一轮的分数。
func TestShareEvalPlan(t *testing.T) {
	lrc := func(seed string) string { return songTestLRC(0, songTestWords(seed, 4)) }
	keys := []string{"e0", "e1", "e2", "e3", "e4", "e5", "e6"}
	entries := []enrichEntry{
		{},
		{Lyrics: bt(lrc("c")), LyricsSource: "netease"},
		{Lyrics: bt(lrc("l2")), LyricsSource: "qq"},
		{Lyrics: bt(lrc("l3")), LyricsSource: "kuwo"},
		{Lyrics: bt(lrc("l4")), LyricsSource: "qq"},
		{Lyrics: bt(lrc("l5")), LyricsSource: "qq"},
		{Instrumental: true},
	}
	own := []*songPlanLyrics{nil, {}, {native: true}, {}, {}, {}, nil}
	scored := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: lrc("c"), LyricsYRC: "[0,500]y", Score: 1200},
		{Source: "qq", Lyrics: lrc("l4"), Score: 900},
	}
	got := map[string]songEvalLine{}
	for _, l := range shareEvalPlan(keys, entries, own, scored, &scored[0], true) {
		got[l.key] = l
	}
	want := map[string]string{"e0": "补", "e1": "补逐字", "e2": "留", "e3": "留", "e4": "换", "e5": "换"}
	if len(got) != len(want) {
		t.Errorf("去留条数 %d,应为 %d: %+v", len(got), len(want), got)
	}
	for k, a := range want {
		if got[k].action != a {
			t.Errorf("%s: %q,应为 %q", k, got[k].action, a)
		}
	}
	if got["e2"].why != songKeepNative || got["e3"].why != songKeepUndecidable {
		t.Errorf("留的原因不对: %q / %q", got["e2"].why, got["e3"].why)
	}
	if !got["e4"].found || got["e4"].before != "qq 900 分 逐行" || got["e5"].found || got["e5"].before != "qq 这一轮没找到 逐行" {
		t.Errorf("现有那份这一轮的分数: %+v / %+v", got["e4"], got["e5"])
	}
	if n := songEvalChanges(shareEvalPlan(keys, entries, own, scored, &scored[0], true)); n != 3 {
		t.Errorf("换和补合计 %d,应为 3", n)
	}

	timed := songTestLRC(0, songTestWords("t", 3))
	credits := "[00:01.00]作词 : 某人\n[00:02.00]作曲 : 某人\n[00:03.00]编曲 : 某人\n"
	plain := []scoredLyricCandidateResult{{Source: "lrclib", Lyrics: "P", Score: 800}, {Source: "qq", Lyrics: "Q", Score: 700}}
	keys2 := []string{"words", "timed", "manual", "credits"}
	entries2 := []enrichEntry{
		{Lyrics: bt(timed), LyricsYRC: bt("[0,500]w"), LyricsSource: "qq"},
		{Lyrics: bt(timed), LyricsSource: "qq"},
		{Lyrics: bt("M"), LyricsSource: "qq"},
		{Lyrics: bt(credits), LyricsSource: "qq"},
	}
	own2 := []*songPlanLyrics{{}, {}, {manual: true}, {}}
	checkWhys(t, shareEvalPlan(keys2, entries2, own2, plain, &plain[0], true), map[string]string{
		"words": "留:" + songKeepWords, "timed": "留:" + songKeepTimed, "manual": "留:" + songKeepOwn, "credits": "换:"})

	terms := []scoreTerm{{Kind: scoreTermTitleMatch, Points: 100}, {Kind: scoreTermConsensus, Points: 250}, {Kind: scoreTermDuration, Points: 100}}
	champ, other := lrc("a"), lrc("b")
	full := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: champ, Score: 1200, ScoreTerms: terms},
		{Source: "qq", Lyrics: other, Score: 1000},
	}
	stamped := func(score int) enrichEntry {
		// 跟 qq 那份同一段词、多一行:这一轮没搜到它,又不是另一首歌的词。
		return enrichEntry{Lyrics: bt(other + "[00:40.00]bonus words here\n"), LyricsSource: "qq", LyricsScore: score,
			LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision}
	}
	stale := stamped(1300)
	stale.LyricsScoringVersion = lyricsScoringVersion - 1
	keys3 := []string{"unscored", "lower", "stale", "shown", "wrong"}
	entries3 := []enrichEntry{
		stamped(1300),
		stamped(1100),
		stale,
		{Lyrics: bt(champ + "\n"), LyricsSource: "netease"},
		{Lyrics: bt(lrc("z")), LyricsYRC: bt("[0,500]z"), LyricsSource: "kuwo"},
	}
	lines3 := shareEvalPlan(keys3, entries3, []*songPlanLyrics{{}, {}, {}, {}, {}}, full, &full[0], true)
	checkWhys(t, lines3, map[string]string{
		"unscored": "留:" + songKeepUnscored, "lower": "换:", "stale": "换:", "shown": "留:" + songKeepShown, "wrong": "换:"})
	for _, l := range lines3 {
		if l.contradicted != (l.key == "wrong") {
			t.Errorf("%s: contradicted = %v", l.key, l.contradicted)
		}
	}
}

func checkWhys(t *testing.T, lines []songEvalLine, want map[string]string) {
	t.Helper()
	got := map[string]string{}
	for _, l := range lines {
		got[l.key] = l.action + ":" + l.why
	}
	if len(got) != len(want) {
		t.Errorf("去留 %v,应为 %v", got, want)
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s: %q,应为 %q", k, got[k], w)
		}
	}
}

// 正式空跑按存档重算:存档里有的组不联网、也不往存档里追加;拿去搜的是现有歌词最好的那条写法,时长取各写法的中位数;
// 另一首歌的词标出来,留着的按原因计数;冠军只比多数那份高不到 30 分时另报留多数那份要动几条。
func TestShareEvalReplay(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsAutoUpgrade: true})
	lrc := func(seed string) string { return songTestLRC(0, songTestWords(seed, 4)) }
	cache := map[string]enrichEntry{
		"A|Song|Album1": {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}, Lyrics: bt(lrc("a1")), LyricsSource: "qq"},
		"A|Song|Album2": {DurationSecs: 200.4, ISRCs: []string{"USAAA1100001"}, Lyrics: bt(lrc("a2")), LyricsYRC: bt("[0,500]y"), LyricsSource: "kugou"},
		"A|Song|Album3": {DurationSecs: 201, ISRCs: []string{"USAAA1100001"}},
		"A|Song|Album4": {DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}, Lyrics: bt(lrc("z")), LyricsSource: "kuwo"},
		"A|Song|Album5": {DurationSecs: 200.6, ISRCs: []string{"USAAA1100001"}, Lyrics: bt(lrc("a1") + "[00:40.00]bonus words here\n"), LyricsSource: "migu"},
	}
	withEnrichCache(t, cache)
	var vs []songVariant
	for k, e := range cache {
		vs = append(vs, songTestVariant(k, e, nil))
	}
	b, _ := songTestBuild(t, vs, nil)
	own := make([]*songPlanLyrics, len(b.variants))
	for i := range b.variants {
		own[i] = b.songPlanLyricsOf(i, nil)
	}
	groups := b.shareEvalGroups(own)
	if len(groups) != 1 {
		t.Fatalf("要搜的共享组 %d 个,应为 1", len(groups))
	}
	// 搜的写法或时长不对时下面会去联网,先停在这里。
	if rep, dur := b.shareEvalRep(groups[0], own); b.variants[rep].key != "A|Song|Album2" || dur != 200.4 {
		t.Fatalf("搜的写法 %s,时长 %v", b.variants[rep].key, dur)
	}
	round := shareEvalRound{Key: "A|Song|Album2", Artist: "A", Title: "Song", Album: "Album2", Duration: 200.4, Scored: []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: lrc("n"), LyricsYRC: "[0,500]n", Score: 1300,
			ScoreTerms: []scoreTerm{{Kind: scoreTermTitleMatch, Points: 100}, {Kind: scoreTermConsensus, Points: 250}, {Kind: scoreTermDuration, Points: 100}}},
		{Source: "kugou", Lyrics: lrc("a2"), LyricsYRC: "[0,500]y", Score: 1280},
		{Source: "qq", Lyrics: lrc("a1"), Score: 900},
	}}
	stale := round
	stale.Scored = nil
	path := filepath.Join(t.TempDir(), "candidates.jsonl")
	var data []byte
	for _, r := range []shareEvalRound{stale, round} {
		line, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		data = append(append(data, line...), '\n')
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	// 存档没对上时会去联网:先把 ctx 取消掉,搜也搜不出东西,断言会挂在「没有可用候选」上。
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var out bytes.Buffer
	w := bufio.NewWriter(&out)
	if err := b.runShareEvaluation(ctx, w, nil, 0, time.Hour, path); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	for _, want := range []string{
		"要搜的共享组 1 个,这次搜 1 个",
		"== A|Song|Album2(共享组 5 条)\n  搜的是 A|Song|Album2,时长 200.4 秒;这一轮冠军 netease 1300 分 逐字\n",
		"    换  A|Song|Album1  qq 900 分 逐行  →  netease 1300 分 逐字\n",
		"    换  A|Song|Album2  kugou 1280 分 逐字  →  netease 1300 分 逐字\n",
		"    补  A|Song|Album3\n",
		"    换  A|Song|Album4  kuwo 这一轮没找到 逐行  →  netease 1300 分 逐字(现有那份跟这一轮哪份都对不上)\n",
		"    留  A|Song|Album5  migu 这一轮没找到 逐行(这一轮比不了,现有那份的来源没应答)\n",
		"  参照:冠军只比组里多数那份(kugou 1280 分 逐字)高 20 分,留多数那份要动 2 条(按冠军动 4 条)\n",
		"小结:搜了 1 组(联网 0 组,其余按存档重算),没有可用候选 0 组;换词 3 条(现有那份这一轮没找到的 1 条,其中跟这一轮哪份都对不上的 1 条),没词补上 1 条,补上逐字 0 条\n",
		"按不变式 6 留着自己那份的 1 条:在放播放器自家的词 0、这一轮比不了 1、没搜到而冠军不比它存的分高 0、有逐字 0、屏上看不出差别 0、有时间轴 0\n",
		"参照:冠军只比多数那份高不到 30 分时留多数那份,换词和补词合计 2 条(按冠军是 4 条)\n",
	} {
		if !containsCode(s, want) {
			t.Errorf("缺这一段:%s\n全文:\n%s", want, s)
		}
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(after, data) {
		t.Error("按存档重算时不该往存档里追加")
	}
	if rounds, err := readShareEvalRounds(filepath.Join(t.TempDir(), "missing.jsonl")); err != nil || len(rounds) != 0 {
		t.Errorf("没有存档时应为空: %v, %v", rounds, err)
	}
	bad := filepath.Join(t.TempDir(), "bad.jsonl")
	if err := os.WriteFile(bad, []byte("{\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readShareEvalRounds(bad); err == nil {
		t.Error("存档坏了应当报错")
	}
}
