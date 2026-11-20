package main

import (
	"slices"
	"strings"
	"testing"
)

// tieOrderProbeRaw:全部来源交同一份逐行歌词(网易云、AMLL 的在各自的子结构里),歌名歌手对得上查询。
func tieOrderProbeRaw() map[string]lyricSourceResult {
	const lrc = "[00:01.00]第一句歌词在这里\n[00:05.00]第二句歌词在这里\n[00:09.00]第三句歌词在这里\n" +
		"[00:13.00]第四句歌词在这里\n[00:17.00]第五句歌词在这里\n[00:21.00]第六句歌词在这里\n"
	raw := map[string]lyricSourceResult{}
	for _, s := range lyricCandidateTieOrder {
		r := lyricSourceResult{source: s, lyr: lrc, matchTitle: "测试", matchArtist: "歌手"}
		switch s {
		case lyricSourceNetease:
			r = lyricSourceResult{source: s, ne: neteaseInfo{Lyrics: lrc, Title: "测试", Artist: "歌手"}}
		case lyricSourceAMLL:
			r = lyricSourceResult{source: s, amll: amllResult{lrc: lrc}}
		}
		raw[s] = r
	}
	return raw
}

// 同分决胜的源序(登记表的 tieOrder,期望表 lyricCandidateTieOrder)就是排序里候选的先后:合并几轮结果时按同一份重建,
// 两边不一致的话,同一首歌走没走补查轮,同分时选出的源不一样。全部来源交同一份歌词:导入库自带 300 分排最前,其余
// 二十一个同分,它们在结果里的先后就是决胜序。
func TestTiedCandidatesRankInTieOrder(t *testing.T) {
	ranked := rankLyricSourceResults("歌手", "测试", "", 0, tieOrderProbeRaw())
	if len(ranked) != len(lyricCandidateTieOrder) || ranked[0].Source != importLyricsSource {
		t.Fatalf("用例前提:%d 个来源各一条候选、导入库领先,得到 %d 条、最前是 %s", len(lyricCandidateTieOrder), len(ranked), ranked[0].Source)
	}
	var got, want []string
	for _, r := range ranked[1:] {
		if r.Score != ranked[1].Score {
			t.Fatalf("用例前提:导入库之外该同分,%s 是 %d、%s 是 %d", ranked[1].Source, ranked[1].Score, r.Source, r.Score)
		}
		got = append(got, r.Source)
	}
	for _, s := range lyricCandidateTieOrder {
		if s != importLyricsSource {
			want = append(want, s)
		}
	}
	if !slices.Equal(got, want) {
		t.Errorf("同分时的先后 %v\n决胜顺序     %v", got, want)
	}
	for _, name := range lyricSourceNames {
		if !slices.Contains(lyricCandidateTieOrder, name) {
			t.Errorf("lyricCandidateTieOrder 缺了 %s", name)
		}
	}
}

// 候选的先后只由 candidateSlots 定:不管按什么先后放进去,吐出来都是决胜序;没登记的源名不吐。
func TestCandidateSlotsEmitInTieOrder(t *testing.T) {
	slots := candidateSlots{}
	slots.put(lyricCandidate{source: "nope"})
	for i := len(lyricCandidateTieOrder) - 1; i >= 0; i-- {
		slots.put(lyricCandidate{source: lyricCandidateTieOrder[i]})
	}
	var got []string
	for _, c := range slots.inTieOrder() {
		got = append(got, c.source)
	}
	if !slices.Equal(got, lyricCandidateTieOrder) {
		t.Errorf("吐出来的先后 %v\n决胜顺序     %v", got, lyricCandidateTieOrder)
	}
	body := goFuncSource(t, "enrich.go", "rankLyricSourceResults")
	if !containsCode(body, "candidates := slots.inTieOrder()") || strings.Contains(body, "append(candidates") {
		t.Error("rankLyricSourceResults 的候选要全部经 candidateSlots 收、按 inTieOrder 吐,别另外往 candidates 里接")
	}
}

// 两个源同分时,直接排序和「过一遍合并(另一轮为空)」选出同一个源。
func TestMergeLyricCandidateRoundsKeepsTieOrder(t *testing.T) {
	lrc := "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n"
	raw := map[string]lyricSourceResult{
		"deezer": {source: "deezer", lyr: lrc, matchTitle: "测试", matchArtist: "歌手"},
		"lrclib": {source: "lrclib", lyr: lrc, matchTitle: "测试", matchArtist: "歌手"},
	}
	direct := rankLyricSourceResults("歌手", "测试", "", 0, raw)
	if len(direct) < 2 || direct[0].Score != direct[1].Score {
		t.Fatalf("用例前提:两个源该同分 %v", direct)
	}
	merged := mergeLyricCandidateRounds("歌手", "测试", "", 0, direct, nil)
	if direct[0].Source != merged[0].Source {
		t.Errorf("同分时直接排序选 %s,过合并选 %s", direct[0].Source, merged[0].Source)
	}
}
