package main

import (
	"os"
	"strings"
	"testing"
)

// 查询词来路(querylog.go 的 lyricQueryReason*)与 App 侧中文译名的**成对**守卫。
// 跟 TestLyricsDecisionPathsHaveChineseLabels / TestScoreTermKindsHaveChineseLabels 同一个
// 路子、同一个教训:那两处的 Swift switch default 都是"原样显示原始值",漏补译名不会编译
// 报错、selftest 也不报错,只会在用户界面上印一个英文串出来 —— 2026-08 已经为此翻过两次车
// (决策 path "manual-rematch"、打分项 "sourceDurationOff")。
//
// queryReasonLabel 的 default 同样是 `return reason ?? ""`,所以这一类从加进来的第一天就钉死。
func TestLyricQueryReasonsHaveChineseLabels(t *testing.T) {
	const sheet = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsDecisionSheet.swift"
	data, err := os.ReadFile(sheet)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", sheet, err)
	}
	src := string(data)
	// 只在 queryReasonLabel 这个函数体内找 —— 同一个文件里 pathLabel 也有一堆 `case "…":`,
	// 不切出来的话两份清单会互相"顶替"对方的缺口。
	const fnMarker = "private func queryReasonLabel("
	start := strings.Index(src, fnMarker)
	if start < 0 {
		t.Fatalf("%s 里找不到 queryReasonLabel —— 函数改名了就同步改这个测试", sheet)
	}
	body := src[start:]
	if end := strings.Index(body, "\n    }\n"); end > 0 {
		body = body[:end]
	}

	for _, reason := range lyricQueryReasons() {
		needle := `case "` + reason + `":`
		if !strings.Contains(body, needle) {
			t.Errorf("查询来路 %q 在 LyricsDecisionSheet.queryReasonLabel 里没有中文译名(缺 %s)——"+
				"不补的话界面上会直接把这个英文串印给用户看", reason, needle)
		}
	}
	// 首轮那一档取值是空串,单独钉一次:它不在 lyricQueryReasons() 里(那份清单刻意不含空串),
	// 但界面上必须有话说 —— 缺了它 default 会回一个空字符串,渲染成「歌手 - 曲名（）」。
	if !strings.Contains(body, `case "":`) {
		t.Error(`queryReasonLabel 缺 case ""(首轮)—— 没有它首轮那一行会渲染成「歌手 - 曲名（）」`)
	}

	// 反方向:Swift 写了译名、Go 这边没登记进 lyricQueryReasons(),说明清单漏了。
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, `case "`) {
			continue
		}
		rest := strings.TrimPrefix(line, `case "`)
		idx := strings.Index(rest, `"`)
		if idx < 0 {
			continue
		}
		got := rest[:idx]
		if got == "" { // 首轮,上面单独钉过
			continue
		}
		found := false
		for _, reason := range lyricQueryReasons() {
			if reason == got {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Swift 里有 case %q 的译名,但 lyricQueryReasons() 没登记它 —— 清单漏了", got)
		}
	}
}

// 五个查询轮都必须真的把来路标进 ctx,否则决策留痕里全是"首轮",等于没记。
// 源码级守卫,跟 aliasround_test.go 的 TestAliasRoundTargetingIsWired 同一个形态。
func TestLyricQueryLogIsWiredIntoEveryRound(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, needle := range []string{
		// 唯一的记录点 —— 所有轮次都经过 fetchScoredLyricCandidatesStreaming。
		"lyricQueryLogFrom(ctx).record(artist, title, lyricQueryReasonFrom(ctx), sortedLyricSourceOnly(ctx))",
		// 五个轮次各自的标注。
		"withLyricQueryReason(ctx, lyricQueryReasonTitleSplit)",
		"aliasReason := lyricQueryReasonAliasMissing",
		"withLyricQueryReason(ctx, lyricQueryReasonPrimaryVar)",
		"titleCtx := withLyricQueryReason(ctx, retryMethod)",
		// 三处写缓存点回填。
		"e.LyricsDecision.QueriesTried = queries.queries()",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("enrich.go 缺 %q —— 少一处标注,决策留痕里那一轮就会被记成「首轮」", needle)
		}
	}
}

// 标题反查那两个 retryMethod 字面量必须跟 lyricQueryReason* 常量逐字相同 ——
// enrich.go 直接把 retryMethod 当来路用(titleCtx := withLyricQueryReason(ctx, retryMethod)),
// 对不上就会在界面上印出一个没有译名的英文串。
func TestRetryMethodMatchesQueryReasonConstants(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, want := range []string{lyricQueryReasonTitleAlbum, lyricQueryReasonTitleSearch} {
		if !strings.Contains(src, `"`+want+`"`) {
			t.Errorf("enrich.go 里找不到 retryMethod 字面量 %q —— 它跟 lyricQueryReason* 常量必须逐字相同", want)
		}
	}
}
