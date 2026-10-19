package main

import (
	"testing"
	"time"
)

// canonicalEnrichKey 的结果记忆(canonicalMemo):同一首歌反复问时用记下的结论,缓存增删条目、整张替换、
// 记下的那条没了都要重扫,不能把旧结论一直用下去。
func TestCanonicalEnrichKeyMemo(t *testing.T) {
	savedCache, savedTTL := enrichCache, canonicalMemoTTL
	t.Cleanup(func() {
		enrichCache, canonicalMemoTTL = savedCache, savedTTL
		canonicalMemoReset()
	})
	canonicalMemoTTL = time.Minute
	canonicalMemoReset()
	query := "A|Song|B"
	expect := func(step, want string) {
		t.Helper()
		got, ok := canonicalEnrichKey(query)
		if !ok {
			got = ""
		}
		if got != want {
			t.Errorf("%s: canonicalEnrichKey(%q) = %q, want %q", step, query, got, want)
		}
	}

	enrichCache = map[string]enrichEntry{"Other|X|Y": {}}
	expect("没有宽松等价的条目", "")
	enrichCache["A|SONG|B"] = enrichEntry{}
	expect("记下「没有」之后新加一条", "A|SONG|B")
	expect("没变时照旧", "A|SONG|B")

	delete(enrichCache, "A|SONG|B")
	enrichCache["A|sOng|B"] = enrichEntry{}
	expect("记下的那条删掉、换成另一条(条目数不变)", "A|sOng|B")

	enrichCache["A|soNG|B"] = enrichEntry{Lyrics: bt("[00:01.00]x"), LyricsScore: 900}
	expect("加了一条更好的", "A|soNG|B")

	enrichCache = map[string]enrichEntry{"Other|X|Y": {}, "A|song|B": {}, "A|SONG|B": {Lyrics: bt("[00:01.00]x"), LyricsScore: 900}}
	canonicalMemoReset()
	expect("整张替换后按新表挑", "A|SONG|B")

	// 条目数不变、内容变了:没过期时沿用记下的那条,过期之后按新内容重挑。
	enrichCache["A|song|B"] = enrichEntry{Lyrics: bt("[00:01.00]x"), LyricsScore: 990}
	expect("内容变了但还没过期", "A|SONG|B")
	canonicalMemoTTL = 0
	expect("过期之后按新内容重挑", "A|song|B")
}
