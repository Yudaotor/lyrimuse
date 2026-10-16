package main

import "testing"

// 换身份重入那一轮的进度:它自己的候选照原样(不按原身份重打分),原来那批里它还没出现的源接在后面,按分数排。
func TestKeepShownRoundUpdate(t *testing.T) {
	base := []scoredLyricCandidateResult{
		{Source: "lrclib", Score: -1},
		{Source: "qq", Score: -1},
	}
	var got []scoredLyricCandidateResult
	update := keepShownRoundUpdate(func(_ neteaseInfo, r []scoredLyricCandidateResult, _, _ int) { got = r }, base)
	update(neteaseInfo{}, []scoredLyricCandidateResult{{Source: "qq", Score: 300}}, 1, 12)
	if len(got) != 2 || got[0].Source != "qq" || got[0].Score != 300 || got[1].Source != "lrclib" {
		t.Fatalf("重入那一轮的 qq 顶替原来那条,lrclib 留着: %+v", got)
	}
	if keepShownRoundUpdate(nil, base) != nil {
		t.Error("没有回调就还是没有")
	}
}
