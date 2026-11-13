package main

import (
	"context"
	"testing"
)

// 只改字的保存:背景人声的行头还挂得上就留着。
func TestSaveEditKeepsLineBoundExtrasWhenOnlyTextChanged(t *testing.T) {
	yrc := "[1000,1000](1000,500,0)记(1500,500,0)得\n[3000,1000](3000,1000,0)第二句"
	lrc := "[00:01.00]记得\n[00:03.00]第二句"
	bg := "[1000,800](1200,600,0)(和声)"
	base := enrichEntry{TS: 1, Lyrics: bt(lrc), LyricsYRC: bt(yrc), LyricsBG: bt(bg)}

	e := base
	typoYRC := "[1000,1000](1000,500,0)忘(1500,500,0)得\n[3000,1000](3000,1000,0)第二句"
	if err := applySaveEdit(&e, enrichEditRequest{Key: editKey, Lyrics: "[00:01.00]忘得\n[00:03.00]第二句", YRC: &typoYRC, MarkManual: true}); err != nil {
		t.Fatal(err)
	}
	if !e.LyricsBG.EqualString(bg) {
		t.Errorf("只改字,背景人声该留着: %q", e.LyricsBG)
	}

	e = base
	dropYRC := "[3000,1000](3000,1000,0)第二句"
	if err := applySaveEdit(&e, enrichEditRequest{Key: editKey, Lyrics: "[00:03.00]第二句", YRC: &dropYRC, MarkManual: true}); err != nil {
		t.Fatal(err)
	}
	if !e.LyricsBG.IsZero() {
		t.Errorf("删了背景人声挂的那一行,背景人声该清掉: %q", e.LyricsBG)
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
	if out.err != nil || added.TS <= 0 || !added.PlainLyrics.EqualString("纯文本") || !cancelled {
		t.Fatalf("新建条目应当带 TS、停掉在飞的那一轮: %+v err=%v cancelled=%v", added, out.err, cancelled)
	}
	if kept.err != nil || old.TS != 5 || !old.PlainLyrics.EqualString("另一份") {
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
