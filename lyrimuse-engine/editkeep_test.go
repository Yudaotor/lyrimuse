package main

import (
	"context"
	"testing"
)

// 只改字的保存:背景人声的行头还挂得上就留着;正文、逐字逐行比行数和每行时间戳都没变,演唱者标注换成新正文的指纹接着用。
func TestSaveEditKeepsLineBoundExtrasWhenOnlyTextChanged(t *testing.T) {
	yrc := "[1000,1000](1000,500,0)记(1500,500,0)得\n[3000,1000](3000,1000,0)第二句"
	lrc := "[00:01.00]记得\n[00:03.00]第二句"
	bg := "[1000,800](1200,600,0)(和声)"
	base := enrichEntry{TS: 1, Lyrics: lrc, LyricsYRC: yrc, LyricsBG: bg,
		LyricsSpeakers: &lyricSpeakers{For: lyricSpeakersFingerprint(lrc, yrc), LRC: []string{"v1", "v2"}, YRC: []string{"v1", "v2"}}}

	e := base
	typoYRC := "[1000,1000](1000,500,0)忘(1500,500,0)得\n[3000,1000](3000,1000,0)第二句"
	if err := applySaveEdit(&e, enrichEditRequest{Key: editKey, Lyrics: "[00:01.00]忘得\n[00:03.00]第二句", YRC: &typoYRC, MarkManual: true}); err != nil {
		t.Fatal(err)
	}
	if e.LyricsBG != bg {
		t.Errorf("只改字,背景人声该留着: %q", e.LyricsBG)
	}
	if e.LyricsSpeakers == nil || e.LyricsSpeakers.For != lyricSpeakersFingerprint(e.Lyrics, e.LyricsYRC) || len(e.LyricsSpeakers.LRC) != 2 {
		t.Errorf("只改字,演唱者标注换成新正文的指纹接着用: %+v", e.LyricsSpeakers)
	}

	e = base
	dropYRC := "[3000,1000](3000,1000,0)第二句"
	if err := applySaveEdit(&e, enrichEditRequest{Key: editKey, Lyrics: "[00:03.00]第二句", YRC: &dropYRC, MarkManual: true}); err != nil {
		t.Fatal(err)
	}
	if e.LyricsBG != "" {
		t.Errorf("删了背景人声挂的那一行,背景人声该清掉: %q", e.LyricsBG)
	}
	if e.LyricsSpeakers == nil || e.LyricsSpeakers.For != lyricSpeakersFingerprint(lrc, yrc) {
		t.Errorf("行数变了,演唱者标注不换指纹: %+v", e.LyricsSpeakers)
	}

	e = base
	movedYRC := "[1200,1000](1200,500,0)记(1700,500,0)得\n[3000,1000](3000,1000,0)第二句"
	if err := applySaveEdit(&e, enrichEditRequest{Key: editKey, Lyrics: "[00:01.20]记得\n[00:03.00]第二句", YRC: &movedYRC, MarkManual: true}); err != nil {
		t.Fatal(err)
	}
	if e.LyricsSpeakers.For != lyricSpeakersFingerprint(lrc, yrc) {
		t.Errorf("改了时间戳不算只改字,演唱者标注不换指纹: %+v", e.LyricsSpeakers)
	}
}

// 给缓存里没有的歌存纯文本:新建的条目带解析时刻,在飞的首轮解析停掉;已有条目的解析时刻不动。
func TestSavePlainTextOnMissingKeyStampsTS(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{"a|t|old": {TS: 5}})
	savedCancels := enrichCancelFuncs
	t.Cleanup(func() { enrichCancelFuncs = savedCancels })
	cancelled := false
	enrichCancelFuncs = map[string]context.CancelFunc{"a|t|b": func() { cancelled = true }}
	enrichMu.Lock()
	out := applyEnrichEditLocked(enrichEditRequest{Op: "save_plain_text", Key: "a|t|b", PlainLyrics: "纯文本"})
	added := enrichCache["a|t|b"]
	kept := applyEnrichEditLocked(enrichEditRequest{Op: "save_plain_text", Key: "a|t|old", PlainLyrics: "另一份"})
	old := enrichCache["a|t|old"]
	enrichMu.Unlock()
	if out.err != nil || added.TS <= 0 || added.PlainLyrics != "纯文本" || !cancelled {
		t.Fatalf("新建条目应当带 TS、停掉在飞的那一轮: %+v err=%v cancelled=%v", added, out.err, cancelled)
	}
	if kept.err != nil || old.TS != 5 || old.PlainLyrics != "另一份" {
		t.Fatalf("已有条目只换纯文本: %+v err=%v", old, kept.err)
	}
}

func TestSameLineHeads(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"[ti:x]\n[00:01.00]a\n[00:02.00]b", "[ti:x]\n[00:01.00]甲\n[00:02.00]乙", true},
		{"[1000,500](1000,500,0)a", "[1000,500](1000,500,0)b", true},
		{"[00:01.00]a\n[00:02.00]b", "[00:01.00]a\n[00:02.50]b", false},
		{"[00:01.00]a\n[00:02.00]b", "[00:01.00]a", false},
		{"[ti:x]\n[00:01.00]a", "[ti:y]\n[00:01.00]a", false},
		{"[1000,500](1000,500,0)a", "[1000,600](1000,600,0)a", false},
	} {
		if got := sameLineHeads(c.a, c.b); got != c.want {
			t.Errorf("sameLineHeads(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}
