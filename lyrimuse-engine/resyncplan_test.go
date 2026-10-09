//go:build devtools

package main

import "testing"

// resync-lyrics:源没给、本地生成的罗马音 / 机翻 / 逐字,正文没变时不算变、也不清掉。
func TestPlanResyncKeepsLocallyGeneratedFields(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]词", LyricsRoma: "[00:01.00]ci", LyricsTr: "[00:01.00]lyric",
		LyricsTrSource: lyricsTrSourceMachine, LyricsYRC: "[1000,500](1000,500,0)词", LyricsSource: "qq"}
	picked := &scoredLyricCandidateResult{Source: "qq", Lyrics: e.Lyrics, Score: 800}
	p := planResync(e, picked)
	if p.changed() || !p.keepLocalRoma || !p.keepMachineTr || !p.keepYRC {
		t.Fatalf("正文没变、源只是没给这几样:不算改动: %+v", p)
	}
	got := applyResync(e, picked, p, "zh", "")
	if got.LyricsRoma != e.LyricsRoma || got.LyricsTr != e.LyricsTr || got.LyricsTrSource != lyricsTrSourceMachine || got.LyricsYRC != e.LyricsYRC {
		t.Fatalf("本地那几份应当原样留着: %+v", got)
	}

	// 源自带了新译文:照换,机翻标记清掉。
	picked2 := &scoredLyricCandidateResult{Source: "netease", Lyrics: e.Lyrics, LyricsTr: "[00:01.00]社区译文", LyricsTrLang: "zh", Score: 820}
	p2 := planResync(e, picked2)
	if p2.trSame || !p2.changed() {
		t.Fatalf("源给了不同的译文就是改动: %+v", p2)
	}
	got2 := applyResync(e, picked2, p2, "zh", "")
	if got2.LyricsTr != "[00:01.00]社区译文" || got2.LyricsTrSource != "" || got2.LyricsTrLang != "zh" {
		t.Fatalf("新译文应当换上、标记跟着换: %+v", got2)
	}

	// 正文换了:本地那几份不再对得上,按冠军的来,罗马音用锁外算好的兜底。
	picked3 := &scoredLyricCandidateResult{Source: "kugou", Lyrics: "[00:01.00]新词", Score: 900}
	p3 := planResync(e, picked3)
	if p3.lyricsSame || p3.keepLocalRoma || p3.keepMachineTr || p3.keepYRC {
		t.Fatalf("正文换了就不留旧的: %+v", p3)
	}
	got3 := applyResync(e, picked3, p3, "zh", "[00:01.00]xin ci")
	if got3.Lyrics != "[00:01.00]新词" || got3.LyricsTr != "" || got3.LyricsYRC != "" || got3.LyricsRoma != "[00:01.00]xin ci" ||
		got3.LyricsSource != "kugou" || got3.lyricsScoring() != currentLyricsScoring || got3.SongLanguage != "zh" {
		t.Fatalf("got %+v", got3)
	}
}

// 正文没变、逐字的句子变了(缓存里那份缺句):算改动,逐字换成新的;只是写法不同(词标记之间的空白)不算。
func TestPlanResyncCountsChangedWordTimingLines(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]一\n[00:02.00]二\n[00:03.00]三", LyricsSource: "kugou",
		LyricsYRC: "[1000,500](1000,500,0)一\n[3000,500](3000,500,0)三"}
	full := "[1000,500](1000,500,0)一\n[2000,500](2000,500,0)二\n[3000,500](3000,500,0)三"
	picked := &scoredLyricCandidateResult{Source: "kugou", Lyrics: e.Lyrics, LyricsYRC: full, Score: 900}
	p := planResync(e, picked)
	if p.yrcSame || !p.changed() || p.keepYRC {
		t.Fatalf("逐字补回了缺的句子就是改动: %+v", p)
	}
	if got := applyResync(e, picked, p, "zh", ""); got.LyricsYRC != full {
		t.Fatalf("逐字应当换成完整的那份: %q", got.LyricsYRC)
	}

	respaced := &scoredLyricCandidateResult{Source: "kugou", Lyrics: e.Lyrics, Score: 900,
		LyricsYRC: "[1000,500](1000,500,0)一 \n[3000,500](3000,500,0) 三"}
	if p2 := planResync(e, respaced); !p2.yrcSame || p2.changed() {
		t.Fatalf("句子相同、只是空白写法不同,不算改动: %+v", p2)
	}

	gained := enrichEntry{Lyrics: e.Lyrics, LyricsSource: "kugou"}
	if p3 := planResync(gained, picked); p3.yrcSame || !p3.changed() {
		t.Fatalf("缓存里原来没有逐字、这一轮带了:算改动: %+v", p3)
	}
}
