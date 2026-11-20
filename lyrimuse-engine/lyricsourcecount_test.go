package main

import (
	"context"
	"slices"
	"sort"
	"testing"
	"time"
)

// 按源数数、按源名单遍历的地方只认联网源:本机类源(读播放器本机数据的、导入库)由调度同步问完,不进进度分母、到齐判断、
// 设置里的开关、近况统计和健康检查。登记表里两类都有,读名单的地方换错口径(联网源 ↔ 全部来源)时这里红。

// localKindSourceNames:登记表里的本机类源。
func localKindSourceNames(t *testing.T) []string {
	t.Helper()
	var out []string
	for _, d := range registryDescriptors() {
		if d.Kind != providerKindNetwork {
			out = append(out, d.Name)
		}
	}
	if len(out) == 0 {
		t.Fatal("登记表里没有本机类源,这组用例什么都没比")
	}
	return out
}

func oneCandidatePerSource(sources []string) []scoredLyricCandidateResult {
	out := make([]scoredLyricCandidateResult, 0, len(sources))
	for _, s := range sources {
		out = append(out, scoredLyricCandidateResult{Source: s, Score: 10, Lyrics: "[00:01.00]la"})
	}
	return out
}

func TestProgressDenominatorCountsNetworkSourcesOnly(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = nil
	if got := enabledLyricSourceCount(); got != len(lyricSourceNames) {
		t.Errorf("全开时进度分母 = %d,应是联网源数 %d", got, len(lyricSourceNames))
	}
	featuresRef().LyricsSources = map[string]bool{"netease": true, "qq": true}
	if got := enabledLyricSourceCount(); got != 2 {
		t.Errorf("只开两个联网源时进度分母 = %d,本机类源不该算进来", got)
	}
	if got := enabledNetworkLyricSources(); !slices.Equal(got, []string{"netease", "qq"}) {
		t.Errorf("开着的联网源 = %v", got)
	}
}

func TestAllEnabledSourcesRespondedIgnoresLocalKinds(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = nil
	if !allEnabledLyricSourcesResponded(oneCandidatePerSource(lyricSourceNames)) {
		t.Error("联网源都给了候选就算到齐,不等本机类源")
	}
	if allEnabledLyricSourcesResponded(oneCandidatePerSource(lyricSourceNames[1:])) {
		t.Error("少一个联网源不算到齐")
	}
	local := localKindSourceNames(t)
	if allEnabledLyricSourcesResponded(oneCandidatePerSource(append(slices.Clone(lyricSourceNames[1:]), local...))) {
		t.Error("本机类源的候选顶不了缺席的联网源")
	}
}

func TestSourceListReadersWalkNetworkSourcesOnly(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = nil
	local := localKindSourceNames(t)

	sorted := slices.Clone(lyricSourceNames)
	sort.Strings(sorted)
	if got := enabledLyricSourceNames(); !slices.Equal(got, sorted) {
		t.Errorf("健康检查要探的源 = %v\n应是全部联网源 %v", got, sorted)
	}

	var summarized []string
	for _, s := range summarizeLyricSourceStats(nil, nil, lyricSourceStatsTestToday, allLyricSourcesOn) {
		summarized = append(summarized, s.Source)
	}
	if !slices.Equal(summarized, lyricSourceNames) {
		t.Errorf("近况统计的摘要 = %v\n应是全部联网源、按源名单的先后 %v", summarized, lyricSourceNames)
	}

	o := lyricSourceOutcomeFromDecision(&lyricsDecision{}, allLyricSourcesOn, allLyricSourcesOn, nil)
	if !slices.Equal(o.enabled, lyricSourceNames) {
		t.Errorf("一轮决策里记成「问了」的源 = %v\n应是全部联网源 %v", o.enabled, lyricSourceNames)
	}

	// 「有歌没词」标记只看联网源的应答,源序按源名单。
	raw := map[string]lyricSourceResult{}
	for _, s := range append(slices.Clone(local), "qq", "kugou") {
		raw[s] = lyricSourceResult{source: s, trackFoundNoLyrics: true}
	}
	var marked []string
	for _, m := range noLyricsMarkers(raw, nil) {
		marked = append(marked, m.Source)
	}
	if !slices.Equal(marked, []string{"qq", "kugou"}) {
		t.Errorf("「有歌没词」标记 = %v,应只有联网源、按源名单的先后", marked)
	}

	// 别名轮「只查这些源」的名单落盘:联网源按源名单的先后,之外的名字垫在后面。
	only := withLyricSourceOnly(context.Background(), append([]string{"kugou", "netease"}, local[0]))
	if got := sortedLyricSourceOnly(only); !slices.Equal(got, []string{"netease", "kugou", local[0]}) {
		t.Errorf("名单落盘 = %v", got)
	}

	// 每日额度停着的源:只报联网源。
	if got := lyricSourceResumeAts(nil, allLyricSourcesOn, time.Now()); len(got) != 0 {
		t.Errorf("没有源停在每日额度里时 = %v", got)
	}

	// 设置里的启用列表只认联网源:本机类源的名字不算认识的源,列表里只有它们时按全集兜底。
	if got := resolveLyricsSources(local); len(got) != len(lyricSourceNames) {
		t.Errorf("列表里只有本机类源的名字时 = %v,应按全部联网源兜底", sortedKeys(got))
	}
	if got := resolveLyricsSources(append(slices.Clone(local), "qq")); len(got) != 1 || !got["qq"] {
		t.Errorf("本机类源的名字不进启用集合: %v", sortedKeys(got))
	}
}

// 合并几轮结果时按同分决胜序重建顺序,不是按联网源名单:AMLL 在名单里排第五、决胜时排最后,本机类源不在名单里、
// 决胜时夹在联网源和 AMLL 之间。
func TestMergeLyricCandidateRoundsRebuildsByTieRank(t *testing.T) {
	lrc := "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n"
	cand := func(source string) scoredLyricCandidateResult {
		return scoredLyricCandidateResult{Source: source, Score: 1, Lyrics: lrc, Title: "测试", Artist: "歌手"}
	}
	base := []scoredLyricCandidateResult{cand("amll"), cand(kkboxLocalLyricsSource), cand("applemusic")}
	merged := mergeLyricCandidateRounds("歌手", "测试", "", 0, base, nil)
	var got []string
	for _, r := range merged {
		got = append(got, r.Source)
		if r.Score != merged[0].Score {
			t.Fatalf("用例前提:三个来源该同分 %v", merged)
		}
	}
	if want := []string{"applemusic", kkboxLocalLyricsSource, "amll"}; !slices.Equal(got, want) {
		t.Errorf("同分时合并出来的先后 = %v,应按决胜序 %v", got, want)
	}
}
