package main

import "testing"

func TestTitleClaimsInstrumentalVersion(t *testing.T) {
	for _, c := range []struct {
		title string
		want  bool
	}{
		{"Lady In My Life (Inst.)", true},
		{"Lady In My Life (inst)", true},
		{"夜に駆ける (Off Vocal)", true},
		{"Song [Off-Vocal Ver.]", true},
		{"Lady In My Life (Instrumental)", true},
		{"告白气球 (伴奏)", true},
		{"Lady In My Life", false},
		{"Instant Crush", false},
		{"Song (feat. Instinct)", false},
	} {
		if got := titleClaimsInstrumentalVersion(c.title, ""); got != c.want {
			t.Errorf("%q: 得到 %v,要 %v", c.title, got, c.want)
		}
	}
}

func hasInstrumentalMarker(scored []scoredLyricCandidateResult) bool {
	for _, r := range scored {
		if r.Instrumental {
			return true
		}
	}
	return false
}

// 真机:汽水在放《Lady In My Life》,QQ 按歌名搜到同专辑的《Lady In My Life (Inst.)》、回了纯音乐占位(09 章决策 238)。
func TestInstrumentalClaimFromAnotherVersion(t *testing.T) {
	playingFor(t, playerSoda)
	qqInst := func(matched string) lyricSourceResult {
		return lyricSourceResult{source: "qq", instrumental: true, matchTitle: matched, matchArtist: "Michael Jackson"}
	}
	rank := func(title string, raw map[string]lyricSourceResult) []scoredLyricCandidateResult {
		return rankLyricSourceResults("Michael Jackson", title, "He's The King, Im The DJ", 207, raw)
	}
	if hasInstrumentalMarker(rank("Lady In My Life", map[string]lyricSourceResult{"qq": qqInst("Lady In My Life (Inst.)")})) {
		t.Error("QQ 匹配到的是伴奏版、在放的是原曲:不该标纯音乐")
	}
	if !hasInstrumentalMarker(rank("Lady In My Life (Inst.)", map[string]lyricSourceResult{"qq": qqInst("Lady In My Life (Inst.)")})) {
		t.Error("在放的本身就是伴奏版:照旧标纯音乐")
	}
	if !hasInstrumentalMarker(rank("Intro", map[string]lyricSourceResult{"qq": qqInst("Intro")})) {
		t.Error("QQ 匹配到的就是这一首:照旧标纯音乐")
	}
	ne := lyricSourceResult{source: "netease", ne: neteaseInfo{PureMusic: true, NoVocals: true, Title: "Lady In My Life (Off Vocal)", SongID: 1}}
	if hasInstrumentalMarker(rank("Lady In My Life", map[string]lyricSourceResult{"netease": ne})) {
		t.Error("网易云匹配到的是 Off Vocal 版:它的 PureMusic 不算这一首的")
	}
	migu := lyricSourceResult{source: "migu", lyr: "[00:00.00]此歌曲为纯音乐，请欣赏", matchTitle: "Lady In My Life (Inst.)"}
	if hasInstrumentalMarker(rank("Lady In My Life", map[string]lyricSourceResult{"migu": migu})) {
		t.Error("咪咕匹配到的是伴奏版:它的占位歌词不算这一首的")
	}
}
