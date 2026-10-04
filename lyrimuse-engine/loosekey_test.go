package main

import "testing"

func TestLoosenEnrichKeyMemoMatchesUncached(t *testing.T) {
	inputs := []string{
		"", "方大同|春風吹之吹吹風 mix|愛愛愛", "VALORANT/Grabbitz/bbno$|Die For You|",
		"VALORANT & Grabbitz & bbno$|Die For You|", "周杰倫|妳聽得到|葉惠美", "Coldplay|My Universe|",
	}
	for round := 0; round < 2; round++ {
		for _, in := range inputs {
			if got, want := loosenEnrichKey(in), loosenEnrichKeyUncached(in); got != want {
				t.Errorf("round %d: loosenEnrichKey(%q) = %q, uncached %q", round, in, got, want)
			}
		}
	}
}

func TestLoosenEnrichKeyMemoResetsAtCap(t *testing.T) {
	looseKeyMemoMu.Lock()
	old := looseKeyMemo
	looseKeyMemo = map[string]string{}
	for i := 0; i < looseKeyMemoMax; i++ {
		looseKeyMemo[string(rune(0x10000+i))] = ""
	}
	looseKeyMemoMu.Unlock()
	t.Cleanup(func() {
		looseKeyMemoMu.Lock()
		looseKeyMemo = old
		looseKeyMemoMu.Unlock()
	})

	if got := loosenEnrichKey("周杰倫|晴天|"); got != "周杰伦|晴天|" {
		t.Fatalf("got %q", got)
	}
	looseKeyMemoMu.RLock()
	n := len(looseKeyMemo)
	looseKeyMemoMu.RUnlock()
	if n != 1 {
		t.Errorf("记忆表到上限后应该清空重来,现在有 %d 条", n)
	}
}
