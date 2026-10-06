package main

import "testing"

func TestExplicitnessOf(t *testing.T) {
	cases := []struct{ title, album, want string }{
		{"Wasted Years (Explicit Version)", "Overexposed (Deluxe)", "explicit"},
		{"Wasted Years (Edited Version)", "Overexposed (Deluxe)", "clean"},
		{"yes, and?", "eternal sunshine (slightly deluxe) [Clean]", "clean"},
		{"yes, and?", "eternal sunshine (Explicit)", "explicit"},
		{"Song (Album Version|Edited)", "", "clean"},
		{"Song", "Album (Standard Version [Edited])", "clean"},
		{"Song", "HIStory: PAST, PRESENT AND FUTURE, BOOK I (Explicit)", "explicit"},
		{"Song - Clean", "", "clean"},
		{"Song (Clean Radio Edit)", "", "clean"},
		{"Song (feat. Ol' Dirty Bastard)", "", ""},
		{"Clean", "", ""},
		{"Song (Explicit)", "Album (Clean)", ""},
		{"Song", "Album", ""},
		{"Phresh Out The Runway", "Unapologetic (Deluxe Explicit Version)", "explicit"},
		{"Intro (Album Version Explicit)", "Tical 0: The Prequel", "explicit"},
		{"Song (Album Version Edited)", "", "clean"},
		{"About the Money", "Paperwork (Deluxe Clean)", "clean"},
		{"I'm The Man (Censored Radio Version)", "", "clean"},
		{"Robi-Rob's Boriqua Anthem (Edited Versión)", "", "clean"},
		{"Song", "Living Proof (Live) [1995 Edited Version]", "clean"},
		{"Song", "Like Father Like Son (iTunes Exclusive/ Limited Edition Explicit Album)", "explicit"},
		{"Song", "2023 Flow (Parental Advisory, Explicit Content)", "explicit"},
		{"Song", "Madd Jeanius (Radio Edit-Clean Version)", "clean"},
		{"Song", "LAX (iTunes Edited)", "clean"},
		{"Song \uff08\uff23\uff4c\uff45\uff41\uff4e\uff09", "", "clean"},
		{"Song", "NIGHTCRAWLERS (Plus Edition) [Non Explicit]", ""},
		{"Song", "TAMED (No Explicit Content)", ""},
		{"Song", "Big Brother (Censored Artwork Version)", ""},
		{"Song", "Wednesday BassPower (Explicit Dance Edition)", ""},
		{"Telepath (Dirty Projectors Version)", "", ""},
		{"Song (Explicit Radio Edit)", "", ""},
		{"Song (Explicit Clean Version)", "", ""},
		{"Messiah (Edited by Donald Burrows)", "", ""},
	}
	for _, c := range cases {
		if got := explicitnessOf(c.title, c.album); got != c.want {
			t.Errorf("explicitnessOf(%q, %q) = %q, want %q", c.title, c.album, got, c.want)
		}
	}
}

func TestVersionTagsMismatchExplicitClean(t *testing.T) {
	cases := []struct {
		lt, la, ct, ca string
		want           bool
	}{
		{"Wasted Years (Explicit Version)", "Overexposed (Deluxe)", "Wasted Years (Edited Version)", "Overexposed (Deluxe)", true},
		{"Wasted Years (Explicit Version)", "Overexposed (Deluxe)", "Wasted Years", "Overexposed (Deluxe)", false},
		{"yes, and?", "eternal sunshine (slightly deluxe) [Clean]", "yes, and?", "eternal sunshine (Explicit)", true},
		{"yes, and?", "eternal sunshine", "yes, and?", "eternal sunshine (Explicit)", false},
		{"Song (Explicit)", "", "Song (Explicit)", "", false},
	}
	for _, c := range cases {
		if got := versionTagsMismatch(c.lt, c.la, c.ct, c.ca); got != c.want {
			t.Errorf("versionTagsMismatch(%q, %q, %q, %q) = %v, want %v", c.lt, c.la, c.ct, c.ca, got, c.want)
		}
	}
	// 两版伴奏、时长一样,同一次录音的豁免不吃这种冲突。
	if sameRecordingDespiteVersionTags("Wasted Years (Explicit Version)", "Overexposed (Deluxe)", 213, "Wasted Years (Edited Version)", "Overexposed (Deluxe)", 213) {
		t.Error("删减版不该算同一次录音")
	}
	lrc := "[00:10.00]Wasted years\n[01:00.00]Wasted tears\n[02:00.00]Wasted time\n[03:30.00]Wasted all the years\n"
	c := lyricCandidate{source: "kugou", lyrics: lrc, title: "Wasted Years (Edited Version)", album: "Overexposed (Deluxe)", sourceReportedDurationSecs: 213}
	_, terms := scoreLyricCandidateDetailed("Maroon 5", "Wasted Years (Explicit Version)", "Overexposed (Deluxe)", 213, c, false, 0)
	found := false
	for _, tm := range terms {
		if tm.Kind == scoreTermVersionTags && tm.Points == -versionMismatchPenalty {
			found = true
		}
	}
	if !found {
		t.Errorf("删减版候选该扣版本不符:%v", terms)
	}
}
