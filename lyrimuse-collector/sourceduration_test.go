package main

import (
	"fmt"
	"strings"
	"testing"
)

// 本案例的真实数据(2026-08-22,用户报「Stranger in Moscow (Tee's In-House Club Mix)
// 配了正常版歌词」):
//
//	本地 Apple 标签:Michael Jackson | Stranger in Moscow (Tee's In-House Club Mix)
//	                | BLOOD ON THE DANCE FLOOR/ HIStory In The Mix | 414.32s
//	原冠军(错) qq   :'Stranger In Moscow' | 'HIStory - PAST, PRESENT AND FUTURE - BOOK I (Explicit)'
//	                | 源自报 344s | LRC 末句 ~335s | 有逐字 | 1027 分
//	正主(酷狗第 1 条,当时压根没被搜到):'Stranger in Moscow (Tee's In-House Club Mix)'
//	                | 'BLOOD ON THE DANCE FLOOR/ HIStory In The Mix' | 源自报 413s
//	                | LRC 末句 304.9s | 有逐字
const (
	moscowLocalTitle = "Stranger in Moscow (Tee's In-House Club Mix)"
	moscowLocalAlbum = "BLOOD ON THE DANCE FLOOR/ HIStory In The Mix"
	moscowLocalDur   = 414.32
)

// 造 LRC 用 match_test.go 里已有的 lrcEndingAt(lastSecs, lines) —— 它的正文刻意是英文,
// 本地标题是英文时中文正文会被 isProbablyWrongLanguageLyrics 直接判废(那边注释记过)。

// TestVersionTagsCoverClubMixFamily:词表补了「…mix」家族之后,俱乐部混音能被认出来。
func TestVersionTagsCoverClubMixFamily(t *testing.T) {
	tagged := []string{
		"Stranger in Moscow (Tee's In-House Club Mix)",
		"Stranger in Moscow (Tee's Radio Mix)",
		"Some Song (Deep House Mix)",
		"Some Song (Danger Dub Mix)",
		"Some Song (Dance Mix)",
		"Some Song (Vocal Mix)",
		"Some Song (Club Edit)",
	}
	for _, ti := range tagged {
		if len(titleVersionTags(ti)) == 0 {
			t.Errorf("titleVersionTags(%q) 应抽出版本限定词", ti)
		}
	}

	// ⚠️ 反例守卫:裸「club」绝不能进词表。同一张专辑上的「Earth Song」本地标题没有任何
	// 混音标记,而正确候选是 "Earth Song (Hani's club experience)" —— 收了裸 club 的话,
	// 本地空集 vs 候选有标记 = 版本不符,-600 会打在**唯一正确**的那条上。
	if got := titleVersionTags("Earth Song (Hani's club experience)"); len(got) != 0 {
		t.Errorf("titleVersionTags(\"Earth Song (Hani's club experience)\") = %v, 必须为空 —— "+
			"裸「club」进词表会把这首歌唯一正确的候选打成版本不符", got)
	}
	// 专辑名里的 "In The Mix" 也不能被误当限定词(它没在括号里、也不在最后一个 \" - \" 之后)
	if got := titleVersionTags("BLOOD ON THE DANCE FLOOR/ HIStory In The Mix"); len(got) != 0 {
		t.Errorf("专辑名 \"…HIStory In The Mix\" 不该抽出限定词,得到 %v", got)
	}
}

// TestSearchTitleVariantsPutsClubMixTitleFirst:抽得出限定词之后,检索词顺序必须翻成
// 「原样标题优先」。这是这次误判的**第一层**成因——裸标题优先时,酷狗第一条查询拿回正常版、
// 过了校验就 break,排在第 1 位的混音版原样条目从没被看到。
func TestSearchTitleVariantsPutsClubMixTitleFirst(t *testing.T) {
	got := searchTitleVariants(moscowLocalTitle)
	if len(got) == 0 || got[0] != moscowLocalTitle {
		t.Fatalf("searchTitleVariants(%q) = %#v,第一条必须是原样标题", moscowLocalTitle, got)
	}
	if len(got) < 2 || got[1] != "Stranger in Moscow" {
		t.Errorf("裸标题应保留作兜底,得到 %#v", got)
	}
}

// TestVersionTagsMismatchFlagsStandardVersion:这次误判的**第二层**——正常版候选现在会被
// 判成版本不符。
func TestVersionTagsMismatchFlagsStandardVersion(t *testing.T) {
	if !versionTagsMismatch(moscowLocalTitle, moscowLocalAlbum,
		"Stranger In Moscow", "HIStory - PAST, PRESENT AND FUTURE - BOOK I (Explicit)") {
		t.Errorf("本地是俱乐部混音、候选是正常专辑版,应判版本不符")
	}
	// 对版的混音版候选不该被误判
	if versionTagsMismatch(moscowLocalTitle, moscowLocalAlbum, moscowLocalTitle, moscowLocalAlbum) {
		t.Errorf("同一版本不该判不符")
	}
}

// TestScoreSourceDurationMismatch:新的「源自报曲长」打分项本身。
func TestScoreSourceDurationMismatch(t *testing.T) {
	hasTerm := func(terms []scoreTerm) (int, bool) {
		for _, tm := range terms {
			if tm.Kind == scoreTermSourceDurationOff {
				return tm.Points, true
			}
		}
		return 0, false
	}
	lrc := lrcEndingAt(400, 20)
	cases := []struct {
		name    string
		srcDur  float64
		wantHit bool
	}{
		{"自报 344s vs 本地 414.32s(偏 17%)→ 扣", 344, true},
		{"自报 413s vs 本地 414.32s(偏 0.3%)→ 不扣", 413, false},
		{"自报 370s(偏 10.7%,在 12% 内)→ 不扣", 370, false},
		{"自报 360s(偏 13.1%)→ 扣", 360, true},
		{"源没自报(0)→ 不扣(没有证据不等于反面证据)", 0, false},
		{"自报比本地长很多(偏 20%)→ 扣", 517.9, true},
	}
	for _, c := range cases {
		cand := lyricCandidate{source: "kugou", lyrics: lrc, sourceReportedDurationSecs: c.srcDur}
		_, terms := scoreLyricCandidateDetailed("Michael Jackson", moscowLocalTitle, moscowLocalAlbum,
			moscowLocalDur, cand, false, 0)
		pts, hit := hasTerm(terms)
		if hit != c.wantHit {
			t.Errorf("%s: 扣分项出现=%v,want %v", c.name, hit, c.wantHit)
		}
		if hit && pts != -sourceDurationMismatchPenalty {
			t.Errorf("%s: 扣了 %d,want %d", c.name, pts, -sourceDurationMismatchPenalty)
		}
	}
}

// TestMoscowClubMixOutranksStandardVersion 是这次误判的端到端回归:用真实数字重建两条
// 候选,断言修复后**混音版胜出**。刻意把跨源共识给正常版那一边(现实里 qq/musixmatch/
// lrclib 三家都是同一份正常版歌词、互相印证),混音版孤身一条、没有共识分 —— 这是更难的
// 那一侧,过了才算数。
func TestMoscowClubMixOutranksStandardVersion(t *testing.T) {
	standard := lyricCandidate{
		source: "qq", lyrics: lrcEndingAt(335, 70), hasWordTiming: true, wordTimingYRC: "x",
		sourceReportedDurationSecs: 344,
		title:                      "Stranger In Moscow",
		album:                      "HIStory - PAST, PRESENT AND FUTURE - BOOK I (Explicit)",
	}
	clubMix := lyricCandidate{
		source: "kugou", lyrics: lrcEndingAt(305, 65), hasWordTiming: true, wordTimingYRC: "x",
		sourceReportedDurationSecs: 413,
		title:                      moscowLocalTitle,
		album:                      moscowLocalAlbum,
	}
	ss, sterms := scoreLyricCandidateDetailed("Michael Jackson", moscowLocalTitle, moscowLocalAlbum,
		moscowLocalDur, standard, false, 2) // 正常版有 2 个跨源印证
	cs, cterms := scoreLyricCandidateDetailed("Michael Jackson", moscowLocalTitle, moscowLocalAlbum,
		moscowLocalDur, clubMix, false, 0) // 混音版孤身一条
	dump := func(n string, s int, ts []scoreTerm) string {
		var b strings.Builder
		fmt.Fprintf(&b, "%s=%d [", n, s)
		for _, tm := range ts {
			fmt.Fprintf(&b, "%s%+d ", tm.Kind, tm.Points)
		}
		b.WriteString("]")
		return b.String()
	}
	if cs <= ss {
		t.Errorf("混音版必须胜出\n  %s\n  %s", dump("clubMix", cs, cterms), dump("standard", ss, sterms))
	}
	t.Logf("%s\n  %s", dump("clubMix ", cs, cterms), dump("standard", ss, sterms))
}
