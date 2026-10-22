package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// 带标注的一份:四行、五个待标字(君 / 明日 / 夢 / 見),「明日」的两个字一条。
const kanaDonorSample = "[kana:1き(100,50)み2あした1ゆめ1み]\n" +
	"[00:01.00]君と\n" +
	"[00:02.00]明日へ\n" +
	"[00:03.00]Yeah\n" +
	"[00:04.00]夢を見た\n"

func TestKanaRawEntries(t *testing.T) {
	got := kanaRawEntries("x1き(100,50)み2あし(1,2)た0の１ゆ")
	want := []kanaRawEntry{{1, "1きみ"}, {2, "2あした"}, {1, "0の"}, {1, "１ゆ"}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("条目 %d: got %+v want %+v", i, got[i], want[i])
		}
	}
	if got := kanaRawEntries("1か(12,3)い"); len(got) != 1 || got[0].raw != "1かい" {
		t.Errorf("括号里的数字不该开新条目: %+v", got)
	}
}

func TestKanaLineKey(t *testing.T) {
	if a, b := kanaLineKey("君と、ＡＢ ｃ!"), kanaLineKey("君と ab c"); a != b {
		t.Errorf("%q != %q", a, b)
	}
	if kanaLineKey("君と") == kanaLineKey("君を") {
		t.Error("假名不同的两行不该同键")
	}
}

func TestKanaEntriesByLineKey(t *testing.T) {
	got := kanaEntriesByLineKey(kanaDonorSample)
	want := map[string]string{kanaLineKey("君と"): "1きみ", kanaLineKey("明日へ"): "2あした", kanaLineKey("夢を見た"): "1ゆめ1み"}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%q: got %q want %q", k, got[k], v)
		}
	}
	if got := kanaEntriesByLineKey(strings.Replace(kanaDonorSample, "1ゆめ1み", "1ゆめ", 1)); got != nil {
		t.Errorf("条目总数对不上时整份不收: %v", got)
	}
	// 「明日」拆在两行:跨行那条盖到的两行都不收,后面的行照样对得上。
	split := "[kana:1き2あした1ゆめ]\n[00:01.00]君と明\n[00:02.00]日へ\n[00:03.00]夢\n"
	if got := kanaEntriesByLineKey(split); len(got) != 1 || got[kanaLineKey("夢")] != "1ゆめ" {
		t.Errorf("跨行: %v", got)
	}
	// 同一句两处标得不一样:都不收。
	conflict := "[kana:1き1きみ1ゆめ]\n[00:01.00]君\n[00:02.00]君\n[00:03.00]夢\n"
	if got := kanaEntriesByLineKey(conflict); len(got) != 1 || got[kanaLineKey("夢")] != "1ゆめ" {
		t.Errorf("冲突: %v", got)
	}
}

func TestKanaDonorLRC(t *testing.T) {
	cur := "[00:00.50]作词:某\n[00:01.10]君と!\n[00:02.10]明日へ\n[00:03.10]知らない\n"
	cands := []scoredLyricCandidateResult{
		{Source: "qq", Score: 1100, Lyrics: kanaDonorSample},
		{Source: "kugou", Score: -1, Lyrics: kanaDonorSample + "[00:05.00]知らない\n"},
	}
	got := kanaDonorLRC(cur, "", cands)
	want := "[kana:1きみ2あした]\n[00:00.00]君と!\n[00:00.00]明日へ"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	if m := kanaEntriesByLineKey(got); len(m) != 2 {
		t.Errorf("产物要能按同一口径整份对上: %v", m)
	}
	if got := kanaDonorLRC("[kana:1111きみ2あした1し]\n"+cur, "", cands); got != "" {
		t.Errorf("正文自带标注对得齐时不借: %q", got)
	}
	if got := kanaDonorLRC("[00:01.00]君と\n[00:02.00]明日へ\n[00:03.00]"+strings.Repeat("我爱你中国", 10)+"\n", "", cands); got != "" {
		t.Errorf("不像日文的不借: %q", got)
	}
	if got := kanaDonorLRC("[00:01.00]君と\n[00:02.00]ねえ\n", "", cands); got != "" {
		t.Errorf("只对上一行时不借: %q", got)
	}
	if got := kanaDonorLRC("[00:01.00]君と\n[00:02.00]ねえ\n", "[1000,500](1000,250,0)君 (1250,250,0)と", cands); got != "" {
		t.Errorf("整行和逐字只差空白的同一句只算一行: %q", got)
	}
	compat := "[kana:1きみ1ゆめ1み]\n[00:01.00]君と\n[00:02.00]夢が⾒える\n[00:03.00]見て\n"
	if got := kanaDonorLRC("[00:01.00]君と\n[00:02.00]夢が⾒える\n[00:03.00]見て\n", "",
		[]scoredLyricCandidateResult{{Source: "qq", Score: 1000, Lyrics: compat}}); strings.Contains(got, "⾒") {
		t.Errorf("带康熙部首的行不借(App 换成标准字后待标字会多一个): %q", got)
	}
	// 逐字歌词的写法跟整行不同时,两种写法都借。
	yrc := "[1000,500](1000,500,0)夢を(1500,500,0)見た"
	if got := kanaDonorLRC(cur, yrc, cands); !strings.HasSuffix(got, "\n[00:00.00]夢を見た") || !strings.HasPrefix(got, "[kana:1きみ2あした1ゆめ1み]") {
		t.Errorf("逐字行: %q", got)
	}
	// 挑对上行数最多的那家。
	more := strings.Replace(kanaDonorSample, "1み]", "1み1し]", 1) + "[00:05.00]知らない\n"
	cands = append(cands, scoredLyricCandidateResult{Source: "kugou", Score: 900, Lyrics: more})
	if got := kanaDonorLRC(cur, "", cands); !strings.Contains(got, "知らない") {
		t.Errorf("该挑对上三行的那家: %q", got)
	}
}

func TestRefreshKana(t *testing.T) {
	cur := "[00:01.10]君と\n[00:02.10]明日へ\n"
	qq := scoredLyricCandidateResult{Source: "qq", Score: 1100, Lyrics: kanaDonorSample}
	e := enrichEntry{Lyrics: bt(cur)}
	refreshKana(&e, []scoredLyricCandidateResult{qq})
	if !strings.HasPrefix(e.LyricsKana, "[kana:1きみ2あした]") || e.LyricsKanaChecked != lyricsKanaVersion {
		t.Fatalf("借到了: %q checked=%d", e.LyricsKana, e.LyricsKanaChecked)
	}
	old := e.LyricsKana
	e.LyricsKanaChecked = 0
	refreshKana(&e, []scoredLyricCandidateResult{{Source: "netease", Score: 1200, Lyrics: cur}})
	if e.LyricsKana != old || e.LyricsKanaChecked != 0 {
		t.Errorf("这一轮没问到带标注的源:旧的留着、不记已查: %q checked=%d", e.LyricsKana, e.LyricsKanaChecked)
	}
	refreshKana(&e, []scoredLyricCandidateResult{{Source: "kugou", Score: 1000, Lyrics: "[00:01.00]別の歌\n"}})
	if e.LyricsKana != old || e.LyricsKanaChecked != lyricsKanaVersion {
		t.Errorf("问到了但没借到:旧的留着、记已查: %q checked=%d", e.LyricsKana, e.LyricsKanaChecked)
	}
	e.Lyrics = bt("[00:01.00]別の歌です\n[00:02.00]空を見上げて\n")
	refreshKana(&e, nil)
	if e.LyricsKana != "" {
		t.Errorf("正文换成别的歌、这一轮没借到:旧的对不上就清掉: %q", e.LyricsKana)
	}
	e.LyricsKana = old
	e.Lyrics = bt(kanaDonorSample)
	refreshKana(&e, []scoredLyricCandidateResult{qq})
	if e.LyricsKana != "" {
		t.Errorf("正文自带标注时清掉借来的: %q", e.LyricsKana)
	}
}

// 借来的标注留在索引里;候选输出不带它。
func TestLyricsKanaSerialization(t *testing.T) {
	e := leanForIndex(enrichEntry{Lyrics: bt("[00:01.00]a"), LyricsKana: "[kana:1き]\n[00:00.00]君", LyricsKanaChecked: lyricsKanaVersion}, 7)
	b, _ := json.Marshal(e)
	if !strings.Contains(string(b), `"lyrics_kana":"[kana:1き]\n[00:00.00]君","lyrics_kana_checked":1`) {
		t.Errorf("索引里没有借来的标注: %s", b)
	}
}

// 写正文的几个入口都刷新借来的标注,整份搬正文的几处都带上它。
func TestLyricsKanaIsWired(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if n := strings.Count(read("enrich.go"), "\trefreshSpeakers(&e, scored)\n\trefreshKana(&e, scored)\n"); n != 2 {
		t.Errorf("enrich.go 升级重试和重选两处该刷新,找到 %d 处", n)
	}
	for f, s := range map[string]string{
		"provisionallyrics.go": "refreshSpeakers(&e, scored)\n\trefreshKana(&e, scored)\n",
		"resynclyricscli.go":   "refreshSpeakers(&cur, scored)\n\t\trefreshKana(&cur, scored)\n",
		"songentityshare.go":   "refreshSpeakers(e, r.Scored)\n\trefreshKana(e, r.Scored)\n",
		"backfilllyrics.go":    "e.LyricsKana, e.LyricsKanaChecked, e.LyricsKanaRomaFor = fresh.LyricsKana, fresh.LyricsKanaChecked, fresh.LyricsKanaRomaFor\n",
		"crossalbum.go":        "e.LyricsKana, e.LyricsKanaChecked, e.LyricsKanaRomaFor = src.LyricsKana, src.LyricsKanaChecked, src.LyricsKanaRomaFor\n",
		"crossalbumcli.go":     "dst.LyricsKana, dst.LyricsKanaChecked, dst.LyricsKanaRomaFor = src.LyricsKana, src.LyricsKanaChecked, src.LyricsKanaRomaFor\n",
	} {
		if !containsCode(read(f), s) {
			t.Errorf("%s 缺 %q", f, s)
		}
	}
	if !containsCode(read("songentityshare.go"), "dst.LyricsKana, dst.LyricsKanaChecked, dst.LyricsKanaRomaFor = src.LyricsKana, src.LyricsKanaChecked, src.LyricsKanaRomaFor\n") {
		t.Error("songentityshare.go 搬正文时缺借来的标注")
	}
}

// 手改、采纳候选换了正文:借来的标注对到新正文上,对不上的去掉;采纳候选还要当没问过。
func TestSaveEditRefitsLyricsKana(t *testing.T) {
	cur := "[00:01.10]君と\n[00:02.10]明日へ\n"
	donor := kanaDonorLRC(cur, "", []scoredLyricCandidateResult{{Source: "qq", Score: 1100, Lyrics: kanaDonorSample}})
	e := enrichEntry{Lyrics: bt(cur), LyricsKana: donor, LyricsKanaChecked: lyricsKanaVersion}
	if err := applySaveEdit(&e, enrichEditRequest{Lyrics: cur + "[00:03.10]ねえ\n"}); err != nil {
		t.Fatal(err)
	}
	if e.LyricsKana != donor || e.LyricsKanaChecked != lyricsKanaVersion {
		t.Errorf("只加了一行:标注照旧: %q checked=%d", e.LyricsKana, e.LyricsKanaChecked)
	}
	if err := applySaveEdit(&e, enrichEditRequest{Lyrics: "[00:01.00]別の歌です\n[00:02.00]空を見上げて\n", FromManualPick: true}); err != nil {
		t.Fatal(err)
	}
	if e.LyricsKana != "" || e.LyricsKanaChecked != 0 {
		t.Errorf("采纳了另一份正文:旧标注清掉、当没问过: %q checked=%d", e.LyricsKana, e.LyricsKanaChecked)
	}
}
