package main

import (
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// 同分决胜的源序(lyricCandidateTieOrder)必须就是 rankLyricSourceResults 构造候选的顺序:合并几轮结果时按它重建,
// 两边不一致的话,同一首歌走没走补查轮,同分时选出的源不一样。按源码里 `source: …` 出现的先后比。
func TestLyricCandidateTieOrderMatchesConstruction(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	start := strings.Index(s, "\nfunc rankLyricSourceResults(")
	if start < 0 {
		t.Fatal("找不到 rankLyricSourceResults")
	}
	end := strings.Index(s[start+1:], "\nfunc ")
	body := s[start : start+1+end]
	consts := map[string]string{
		"kkboxLocalLyricsSource":   kkboxLocalLyricsSource,
		"amazonLocalLyricsSource":  amazonLocalLyricsSource,
		"lxMusicLocalLyricsSource": lxMusicLocalLyricsSource,
		"localFileLyricsSource":    localFileLyricsSource,
		"spotifyLocalLyricsSource": spotifyLocalLyricsSource,
	}
	var built []string
	for _, m := range regexp.MustCompile(`source:\s*("(\w+)"|(\w+LyricsSource)\b)`).FindAllStringSubmatch(body, -1) {
		name := m[2]
		if name == "" {
			v, ok := consts[m[3]]
			if !ok {
				t.Fatalf("rankLyricSourceResults 里有新的源常量 %s:加进 lyricCandidateTieOrder 和这里的对照表", m[3])
			}
			name = v
		}
		if !slices.Contains(built, name) {
			built = append(built, name)
		}
	}
	if !slices.Equal(built, lyricCandidateTieOrder) {
		t.Errorf("构造顺序 %v\n决胜顺序 %v", built, lyricCandidateTieOrder)
	}
	for _, name := range lyricSourceNames {
		if !slices.Contains(lyricCandidateTieOrder, name) {
			t.Errorf("lyricCandidateTieOrder 缺了 %s", name)
		}
	}
}

// 两个源同分时,直接排序和「过一遍合并(另一轮为空)」选出同一个源。
func TestMergeLyricCandidateRoundsKeepsTieOrder(t *testing.T) {
	lrc := "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n"
	raw := map[string]lyricSourceResult{
		"musixmatch": {source: "musixmatch", lyr: lrc, matchTitle: "测试", matchArtist: "歌手"},
		"lrclib":     {source: "lrclib", lyr: lrc, matchTitle: "测试", matchArtist: "歌手"},
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
