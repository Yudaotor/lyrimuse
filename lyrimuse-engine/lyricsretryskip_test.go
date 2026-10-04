package main

import (
	"path/filepath"
	"sort"
	"testing"
	"time"
)

// 没歌手没专辑、补空失败够次数的才放弃;缺一项、次数不够、有专辑的都照常。
func TestLyricsNoAnchorGaveUp(t *testing.T) {
	cases := []struct {
		key   string
		count int
		want  bool
	}{
		{"|Episode 743|", lyricsNoAnchorGiveUpCount, true},
		{"|Episode 743|", lyricsNoAnchorGiveUpCount - 1, false},
		// 连歌手都缺也常能靠歌名搜到(本机缓存里真实存在),失败次数不够不放弃。
		{"|蒲公英的约定|", 0, false},
		{"|歌名|专辑", 10, false},
		{"歌手|歌名|", 10, false},
	}
	for _, c := range cases {
		if got := lyricsNoAnchorGaveUp(c.key, enrichEntry{LyricsFillCount: c.count}); got != c.want {
			t.Errorf("%q count=%d: got %v, want %v", c.key, c.count, got, c.want)
		}
	}
}

func sortedKeys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// 两种污染形态(歌词在 artist 里 / 在 title 里)都认得出;只标空歌词条目。
func TestLyricsPollutedKeysFindsBothShapes(t *testing.T) {
	cache := map[string]enrichEntry{
		// 歌词在 artist 里,「歌名 - 歌手」在 title 里。
		"作曲: 中岛美雪|漫步人生路 - 邓丽君|漫步人生路":   {},
		"在你身边路虽远未疲倦|漫步人生路 - 邓丽君|漫步人生路": {},
		"伴你漫步一段又一段|漫步人生路 - 邓丽君|漫步人生路":  {},
		"有歌词的那一条|漫步人生路 - 邓丽君|漫步人生路":    {Lyrics: "[00:01.00]x"},
		// 歌词在 title 里,「歌手 - 歌名」在 artist 里。
		"陈慧琳 - 记事本|作曲: 周传雄|记事本":    {},
		"陈慧琳 - 记事本|翻开随身携带的记事本|记事本": {},
		"陈慧琳 - 记事本|再写下最后一行|记事本":    {},
	}
	got := sortedKeys(lyricsPollutedKeys(cache))
	want := []string{
		"作曲: 中岛美雪|漫步人生路 - 邓丽君|漫步人生路",
		"伴你漫步一段又一段|漫步人生路 - 邓丽君|漫步人生路",
		"在你身边路虽远未疲倦|漫步人生路 - 邓丽君|漫步人生路",
		"陈慧琳 - 记事本|作曲: 周传雄|记事本",
		"陈慧琳 - 记事本|再写下最后一行|记事本",
		"陈慧琳 - 记事本|翻开随身携带的记事本|记事本",
	}
	sort.Strings(want)
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

// 正常数据一条都不标:一张专辑多首歌、歌名自带破折号但只有一个歌手、只有两个不同值。
func TestLyricsPollutedKeysLeavesNormalDataAlone(t *testing.T) {
	cache := map[string]enrichEntry{
		"周杰伦|晴天|叶惠美": {}, "周杰伦|以父之名|叶惠美": {}, "周杰伦|东风破|叶惠美": {},
		"盧廣仲|魚仔 - 電視劇<花甲男孩轉大人>主題曲|魚仔":                                         {},
		"方大同|Love Song - 15 Khalil Live in HK 2011|15 Khalil Live in HK 2011": {},
		"歌手甲|Intro - Live|现场":                                                 {},
		"歌手乙|Intro - Live|现场":                                                 {},
	}
	if got := lyricsPollutedKeys(cache); len(got) != 0 {
		t.Errorf("正常数据不该被标: %v", sortedKeys(got))
	}
}

// 自动补空跳过这两类,手动「重试无歌词条目」照搜。
func TestLyricsFillSweepCandidatesSkipsHopelessOnlyWhenAutomatic(t *testing.T) {
	old := time.Now().Add(-60 * 24 * time.Hour).Unix()
	withEnrichCache(t, map[string]enrichEntry{
		"|Episode 743|": {TS: old, LyricsFillTS: old, LyricsFillCount: lyricsNoAnchorGiveUpCount},
		"作曲: 中岛美雪|漫步人生路 - 邓丽君|漫步人生路":   {TS: old},
		"在你身边路虽远未疲倦|漫步人生路 - 邓丽君|漫步人生路": {TS: old},
		"伴你漫步一段又一段|漫步人生路 - 邓丽君|漫步人生路":  {TS: old},
		"周杰伦|晴天|叶惠美": {TS: old},
	})
	if got := lyricsFillSweepCandidates(lyricsFillRequest{}); len(got) != 1 || got[0] != "周杰伦|晴天|叶惠美" {
		t.Errorf("自动这一轮只该剩正常的空条目: %v", got)
	}
	if got := lyricsFillSweepCandidates(lyricsFillRequest{manual: true, all: true}); len(got) != 5 {
		t.Errorf("手动重试照搜全部 5 条: %v", got)
	}
}

// 全量扫库:这一场已经跑过的(尝试时刻不早于起点)续跑时跳过;再搜也不会有的空条目也不进。
func TestLyricsFullScanCandidatesSkipsDoneAndHopeless(t *testing.T) {
	cur := lyricsScoringVersion
	savedPins := lyricsPinsPath
	t.Cleanup(func() {
		lyricsPinsPath = savedPins
		lyricsPins, lyricsPinsRead = nil, false
		setLyricsFullScanStatePath("")
	})
	lyricsPinsPath = ""
	lyricsPins, lyricsPinsRead = nil, false
	setLyricsFullScanStatePath(filepath.Join(t.TempDir(), "fullscan.json"))
	setLyricsFullScanActive(true)
	start := readLyricsFullScanState().StartedAt
	before, after := start-3600, start+10
	withEnrichCache(t, map[string]enrichEntry{
		"a|empty done|":    {LyricsFillTS: after},
		"b|empty todo|":    {LyricsFillTS: before},
		"c|line done|":     {Lyrics: "[00:01.00]x", LyricsScoringVersion: cur, LyricsRescoreTS: after},
		"d|line todo|":     {Lyrics: "[00:01.00]x", LyricsScoringVersion: cur, LyricsRescoreTS: before},
		"e|stale done|":    {Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur - 1, LyricsRescoreTS: after},
		"f|stale todo|":    {Lyrics: "x", LyricsYRC: "y", LyricsScoringVersion: cur - 1},
		"|Episode 743|":    {LyricsFillCount: lyricsNoAnchorGiveUpCount},
		"作曲: 中岛美雪|X - Y|X": {}, "第二句|X - Y|X": {}, "第三句|X - Y|X": {},
	})
	got := lyricsFullScanCandidates()
	want := []string{"b|empty todo|", "d|line todo|", "f|stale todo|"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}
