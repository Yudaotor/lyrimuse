package main

import "testing"

// 网易云的纯音乐信号(2026-08-20)。
//
// 用户报「歌词管理里一堆条目显示无歌词,其实都是纯音乐」——LoL 原声带
// 《The Music of League of Legends Vol. 1》十几首。查下来:lrclib 压根没有这批曲目
// (五源全空、lyrics_sources_responded 是空的),而网易云**匹配上了歌**(封面、单曲链接
// 都给了)、歌词接口顶层也明确回了 pureMusic=true、正文是「作曲 : X」+「纯音乐,请欣赏」
// 两行占位。那两行过不了 isTimedLRC 的三行门槛,于是网易云连一条候选都不产生,
// 而"纯音乐"这个明确结论在 JSON 解码那一步就被丢了(结构体里没这个字段)。
func TestIsNeteasePureMusicLyric(t *testing.T) {
	cases := []struct {
		name string
		lrc  string
		want bool
	}{
		{
			name: "真实形态:作曲署名 + 占位(id=30431011 Demacia Rising)",
			lrc:  "[00:00.00] 作曲 : Michael Barry\n[00:05.00]纯音乐，请欣赏\n",
			want: true,
		},
		{
			name: "多位作曲 + 占位(id=30431020 Freljord)",
			lrc:  "[00:00.00] 作曲 : Sebastien Najand/Alexander Temple\n[00:05.00]纯音乐，请欣赏\n",
			want: true,
		},
		{
			name: "半角逗号那种写法",
			lrc:  "[00:00.00]纯音乐,请欣赏\n",
			want: true,
		},
		{
			name: "整份职员表但没有占位:不下「纯音乐」这个结论(交给判废逻辑处理)",
			lrc:  "[00:00.00] 作曲 : A\n[00:01.00] 作词 : B\n[00:02.00] 编曲 : C\n",
			want: false,
		},
		{
			name: "真歌词里唱到「纯音乐」:不算(有真正的歌词行)",
			lrc:  "[00:01.00]我在听纯音乐\n[00:05.00]夜色很安静\n[00:09.00]风吹过窗\n",
			want: false,
		},
		{
			name: "占位 + 一句真歌词:不算(自相矛盾时宁可不下结论)",
			lrc:  "[00:00.00]纯音乐，请欣赏\n[00:10.00]这里有一句真的歌词在唱\n",
			want: false,
		},
		{name: "空串", lrc: "", want: false},
		{name: "只有空白", lrc: "\n  \n", want: false},
	}
	for _, c := range cases {
		if got := isNeteasePureMusicLyric(c.lrc); got != c.want {
			t.Errorf("%s: isNeteasePureMusicLyric = %v, want %v", c.name, got, c.want)
		}
	}
}

// 合并轮保留纯音乐标记的条件必须按**标记自己的源**判,不能写死 lrclib ——
// 否则网易云带标记时,"合并后有没有真的 lrclib 候选"跟它毫无关系,标记会被错误保留/丢弃。
func TestMergeKeepsNeteaseInstrumentalMarkerBySource(t *testing.T) {
	marker := scoredLyricCandidateResult{Source: "netease", Score: -1, Instrumental: true}
	real := scoredLyricCandidateResult{
		Source: "kugou", Score: 100,
		Lyrics: "[00:01.00]a\n[00:02.00]b\n[00:03.00]c\n",
	}
	// 只有标记 + 另一个源的真候选 → 标记要留着(网易云自己没有真候选)
	out := mergeLyricCandidateRounds("A", "T", "AL", 0, []scoredLyricCandidateResult{marker, real}, nil)
	kept := false
	for _, r := range out {
		if r.Instrumental && r.Source == "netease" {
			kept = true
		}
	}
	if !kept {
		t.Error("网易云的纯音乐标记该留下(它自己没有真候选)")
	}

	// 网易云既有真候选、又带标记 → 标记必须被丢掉(自相矛盾)
	neReal := real
	neReal.Source = "netease"
	out2 := mergeLyricCandidateRounds("A", "T", "AL", 0, []scoredLyricCandidateResult{marker, neReal}, nil)
	for _, r := range out2 {
		if r.Instrumental {
			t.Error("网易云已经给出真歌词候选,纯音乐标记不该保留")
		}
	}
}
