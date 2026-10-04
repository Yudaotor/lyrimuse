package main

import (
	"strings"
	"testing"
)

// 连续混音版(Apple Music「DJ Mix」专辑)的识别与拒绝。
//
// 举例:Fred again..《Winnie (end of me) [Mixed]》,专辑
// 「Live from Mexico City, Mexico, Dec 12, 2025 (DJ Mix)」,本地 410s。四个源(qq/
// musixmatch/lrclib/kugou)返回的全是录音室原版《Winnie (end of me)》的词——源自报
// 242s、末句停在 3:51,只铺满前 56%,时间轴整段错位。修复前 QQ 那条 566 分夺冠:
// 版本限定词两边都是空集(词表认 "club mix"/"radio mix" 一类带前缀的写法,不认 Apple
// 用的裸「[Mixed]」/「(DJ Mix)」),liveAlbumIdentityConflict 要求候选也是 live 版所以
// 静默,durationOff 又被四源互相印证的 corroborated 豁免换成 +100,只剩
// sourceDurationOff -400 一项被 wordTiming +400 盖过。
func continuousMixCase() (artist, title, album string) {
	return "Fred again..",
		"Winnie (end of me) [Mixed]",
		"Live from Mexico City, Mexico, Dec 12, 2025 (DJ Mix)"
}

func TestContinuousMixTagsRecognised(t *testing.T) {
	_, title, album := continuousMixCase()
	candTitle, candAlbum := "Winnie (end of me)", "Actual Life 3 (January 1 - September 9 2022) [Explicit]"

	if tags := recordingVersionTags(title, album); !tags[continuousMixVersionTag] {
		t.Fatalf("本地没被认出是连续混音版: %v", tags)
	}
	if tags := recordingVersionTags(candTitle, candAlbum); tags[continuousMixVersionTag] {
		t.Fatalf("录音室原版候选不该带连续混音标记: %v", tags)
	}
	if !versionTagsMismatch(title, album, candTitle, candAlbum) {
		t.Fatal("版本限定词该判不匹配")
	}
}

func TestContinuousMixRejectsStudioCandidate(t *testing.T) {
	artist, title, album := continuousMixCase()
	var lyrics strings.Builder
	lyrics.WriteString("[00:02.71]Alright say hello\n")
	for i := 0; i < 40; i++ {
		lyrics.WriteString("[01:00.00]You will be the end of me\n")
	}
	lyrics.WriteString("[03:51.26]I wasn't here for a minute\n")

	c := lyricCandidate{
		source:                     "qq",
		lyrics:                     lyrics.String(),
		hasWordTiming:              true,
		sourceReportedDurationSecs: 242,
		title:                      "Winnie (end of me)",
		artist:                     "Fred again../Winnie Raeder",
		album:                      "Actual Life 3 (January 1 - September 9 2022) [Explicit]",
		hasUsableTranslation:       true,
	}
	score, terms := scoreLyricCandidateDetailed(artist, title, album, 410, c, true, 3)
	// 必须是 -1(不可用),不能只是重扣:打分函数末尾会把负分夹到 1,而 pickLyricCandidate
	// 只丢弃 <0 的候选——重扣挡不住它被选中。理由见 scoreRejectContinuousMix 头注。
	if score != -1 {
		t.Fatalf("score=%d,want -1;terms=%+v", score, terms)
	}
	if len(terms) != 1 || terms[0].Kind != scoreRejectContinuousMix {
		t.Fatalf("拒绝理由=%+v,want %s", terms, scoreRejectContinuousMix)
	}
}

// 本地是连续混音版、候选**也是**时这道闸该静默:将来真有源收录了 mix 版的轴,它带同样
// 的标记,不该被拒。
func TestContinuousMixAcceptsMixCandidate(t *testing.T) {
	artist, title, album := continuousMixCase()
	c := lyricCandidate{
		source: "qq",
		lyrics: "[00:01.00]a\n[00:05.00]b\n[06:40.00]c\n",
		title:  "Winnie (end of me) [Mixed]",
		album:  "Live from Mexico City, Mexico, Dec 12, 2025 (DJ Mix)",
	}
	score, terms := scoreLyricCandidateDetailed(artist, title, album, 410, c, false, 0)
	for _, tm := range terms {
		if tm.Kind == scoreRejectContinuousMix {
			t.Fatalf("同为混音版的候选不该被拒: score=%d terms=%+v", score, terms)
		}
	}
}

// 反方向:本地是录音室原版、候选是连播混音版。这一半**不走** reject —— 那条闸刻意只在
// "本地是混音版"时开(本地才是"要配哪条时间轴"的那一侧);反方向由集合比对的
// versionTagsMismatch 接住,照既有的 -600 重扣处理,仍可被用户手动选用。
// 这个不对称是有意的,别"顺手"补成双向 reject。
func TestContinuousMixReverseDirectionPenalisesNotRejects(t *testing.T) {
	localTitle, localAlbum := "Winnie (end of me)", "Actual Life 3 (January 1 - September 9 2022)"
	candTitle, candAlbum := "Winnie (end of me) [Mixed]", "Live from Mexico City, Mexico, Dec 12, 2025 (DJ Mix)"

	if !versionTagsMismatch(localTitle, localAlbum, candTitle, candAlbum) {
		t.Fatal("本地原版 vs 候选混音版,版本限定词该判不匹配")
	}
	c := lyricCandidate{
		source: "qq",
		lyrics: "[00:01.00]a\n[00:05.00]b\n[03:40.00]c\n",
		title:  candTitle,
		album:  candAlbum,
	}
	score, terms := scoreLyricCandidateDetailed("Fred again..", localTitle, localAlbum, 224, c, false, 0)
	var penalised bool
	for _, tm := range terms {
		if tm.Kind == scoreRejectContinuousMix {
			t.Fatalf("反方向不该走 reject: score=%d terms=%+v", score, terms)
		}
		if tm.Kind == scoreTermVersionTags && tm.Points < 0 {
			penalised = true
		}
	}
	if !penalised {
		t.Fatalf("反方向该吃 versionTags 重扣,实际 terms=%+v", terms)
	}
}

// 新词表/整段判定不该误伤的形态。「[Mixed]」只按**整段精确**认,不进词表走子串或词元:
// 子串会命中 remixed,词元会命中「(Mixed by X)」这类署名括号。
func TestContinuousMixNoFalsePositives(t *testing.T) {
	for _, tc := range []struct {
		title, album string
		want         bool
		note         string
	}{
		{"Song (Remixed)", "", false, "remixed 是 remix 的形态,不是连播混音"},
		{"Song (Mixed by Serban Ghenea)", "", false, "署名括号:谁混的音"},
		{"Song (Mixed and Mastered)", "", false, "署名括号"},
		{"Song", "Greatest Hits (Deluxe Edition)", false, "Deluxe Edition"},
		{"Song (Club Mix)", "", false, "club mix 有自己的键,不折进来"},
		{"Song [Mixed]", "", true, "Apple DJ Mix 专辑的曲目后缀"},
		{"Song", "Some Set (DJ Mix)", true, "专辑名裸 DJ Mix"},
		{"Song", "Some Set (Continuous Mix)", true, "continuous mix 折同一个键"},
	} {
		if got := recordingVersionTags(tc.title, tc.album)[continuousMixVersionTag]; got != tc.want {
			t.Errorf("%q / %q -> %v, want %v (%s); tags=%v",
				tc.title, tc.album, got, tc.want, tc.note, recordingVersionTags(tc.title, tc.album))
		}
	}
	// 老行为不能被改没:Remixed 仍该命中 remix 键。
	if !recordingVersionTags("Song (Remixed)", "")["remix"] {
		t.Error("Remixed 不再命中 remix 键,老行为被破坏")
	}
}
