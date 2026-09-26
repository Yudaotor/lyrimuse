package main

import (
	"os"
	"strings"
	"testing"
)

// 数字取自一次真机现场(见 02 章决策 49 追加):MediaSession 报 282.181s,队列报 4:43(283s);按 283s 打分时
// 279s 的混音版拿 1011 分胜出、报原版 228s 的几家全判 1 分,按「时长未知」重打原版胜出。

func TestLyricsChosenByVideoDuration(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]x", ResolvedDurationSecs: 283}
	if !lyricsChosenByVideoDuration(e, 282.181) {
		t.Fatal("按视频时长(整秒 283 vs 282.181)选的要认出来")
	}
	if lyricsChosenByVideoDuration(enrichEntry{Lyrics: "x", ResolvedDurationSecs: 228}, 282.181) {
		t.Fatal("按歌曲版时长选的不动")
	}
	if lyricsChosenByVideoDuration(enrichEntry{Lyrics: "x"}, 282.181) {
		t.Fatal("按未知时长选的(ResolvedDurationSecs=0)不动,重选过一次之后就是这个形态")
	}
	if lyricsChosenByVideoDuration(enrichEntry{ResolvedDurationSecs: 283}, 282.181) {
		t.Fatal("没有歌词的条目不归这条管(补空那条路负责)")
	}
	if lyricsChosenByVideoDuration(e, 0) {
		t.Fatal("没有视频时长提示(不是 MV)不动")
	}
}

func TestMusicVideoLyricsStaleUsesHint(t *testing.T) {
	saved := musicVideoDurationHints
	defer func() { musicVideoDurationHints = saved }()
	musicVideoDurationHints = map[string]float64{}
	key := enrichKey("Coldplay和BTS", "My Universe", "")
	e := enrichEntry{Lyrics: "x", ResolvedDurationSecs: 283}
	if musicVideoLyricsStaleLocked(key, e) {
		t.Fatal("没记提示时不判")
	}
	noteMusicVideoDuration("Coldplay和BTS", "My Universe", "", 282.181)
	if !musicVideoLyricsStaleLocked(key, e) {
		t.Fatal("poller 记下视频时长之后要认出来")
	}
	noteMusicVideoDuration("Coldplay和BTS", "My Universe", "", 0)
	if musicVideoDurationHints[key] != 282.181 {
		t.Fatal("非正的时长不覆盖已有提示")
	}
}

func TestLyricsBaselineForUnknownDuration(t *testing.T) {
	current := enrichEntry{Lyrics: "supernova", LyricsSource: "qq", LyricsScore: 1011}
	// 现存那份这一轮还在:按它这一轮的分比。
	scored := []scoredLyricCandidateResult{
		{Source: "musixmatch", Lyrics: "original", Score: 752},
		{Source: "qq", Lyrics: "supernova", Score: 600},
	}
	if b, ok := lyricsBaselineForUnknownDuration(current, scored); !ok || b != 600 {
		t.Fatalf("现存那份这一轮 600 分,得到 %d %v", b, ok)
	}
	// 它的源应答了、但这一轮给的是另一份(按未知时长它不再是候选):基准 0。
	scored = []scoredLyricCandidateResult{
		{Source: "musixmatch", Lyrics: "original", Score: 752},
		{Source: "qq", Lyrics: "suga remix", Score: 475},
	}
	if b, ok := lyricsBaselineForUnknownDuration(current, scored); !ok || b != 0 {
		t.Fatalf("源应答了却没再给这份,基准 0,得到 %d %v", b, ok)
	}
	// 它的源这一轮没应答:不下结论。
	scored = []scoredLyricCandidateResult{{Source: "musixmatch", Lyrics: "original", Score: 752}}
	if _, ok := lyricsBaselineForUnknownDuration(current, scored); ok {
		t.Fatal("现存那份的源这一轮没应答,不能拿 0 当基准把它换掉")
	}
	// 旧基准的问题:同打分版本时 lyricsUpgradeBaseline 直接用存的 1011 分,按未知时长重打谁都够不着。
	current.LyricsScoringVersion = lyricsScoringVersion
	if b, _ := lyricsUpgradeBaseline(current, scored); b != 1011 {
		t.Fatalf("前提:旧基准就是存的分,得到 %d", b)
	}
}

// 接线按源码钉住(两处都在要跑整轮联网检索的路径上,行为上测不到)。
func TestMusicVideoLyricsWiring(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	if !strings.Contains(s, "if musicVideoLyricsStaleLocked(hintKey, e) {\n\t\t\twrongDuration = true") {
		t.Error("trackEnrichment 命中缓存时要问 musicVideoLyricsStaleLocked,并按 wrongDuration 重来")
	}
	i := strings.Index(s, "func retryLyricsUpgrade(")
	body := s[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	if !strings.Contains(body, "baseline, comparable = lyricsBaselineForUnknownDuration(e, scored)") {
		t.Error("retryLyricsUpgrade 按未知时长重打时要换基准,否则存着的高分永远翻不过")
	}
	poller, err := os.ReadFile("poller.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(poller), "if p.cur.NotAudio {\n\t\t\t\t\tnoteMusicVideoDuration(") {
		t.Error("poller 要把正在播的 MV 的视频时长记成提示")
	}
}
