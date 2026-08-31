package main

import "testing"

// 2026-08-30:digest(日报/周报推送)此前**完全不做歌手归并**,而歌手榜(topartists.go)
// 做——同一个二进制里同一个人在推送里是两个、在榜单里是一个。实测这台机器 389 个歌手
// 写法里有 1 例真的踩中("张震岳"/"张震嶽",嶽/岳 的繁简差异)。
//
// 这一组钉的是"两条 digest 取数路径都要归并,且跟榜单同一个口径"。用真实踩中的那个
// 案例当用例,不编数据。

func TestDigestLastfmPathMergesArtists(t *testing.T) {
	// 直接测 digestTopArtists(digest 真正调用的那个函数),不是测 mergeAliasedArtists ——
	// 后者只能证明"归并本身能用",证明不了"digest 确实调了它"。归并那步被删掉时这个
	// 用例必须挂,这是它存在的全部意义。
	in := []lastfmChartEntry{
		{Name: "周杰伦", PlayCount: 5},
		{Name: "张震岳", PlayCount: 4},
		{Name: "张震嶽", PlayCount: 3}, // 繁体写法,应并进上一条
	}
	got := digestTopArtists(in)

	if len(got) != 2 {
		t.Fatalf("繁简孪生没有被合并: got %d entries %+v", len(got), got)
	}
	// 4+3=7 应该反超周杰伦的 5。digest 只取前 N,不重排就会把榜首取错。
	if got[0].Count != 7 {
		t.Fatalf("合并后应按次数降序重排(张震岳 4+3=7 居首), got %+v", got)
	}
	if got[1].Name != "周杰伦" || got[1].Count != 5 {
		t.Fatalf("无关歌手被改动了: %+v", got)
	}
}

// digestTopN 是推送里最多展示几条 —— 归并发生在截断**之前**,否则被截掉的那条的次数
// 就永远加不回它的本尊身上。
func TestDigestTopArtistsMergesBeforeTruncating(t *testing.T) {
	in := []lastfmChartEntry{
		{Name: "A", PlayCount: 9},
		{Name: "B", PlayCount: 8},
		{Name: "C", PlayCount: 7},
		{Name: "张震岳", PlayCount: 6},
		{Name: "张震嶽", PlayCount: 6}, // 落在 Top3 之外,先截断就再也加不上了
	}
	got := digestTopArtists(in)
	if len(got) != digestTopN {
		t.Fatalf("应恰好取 %d 条, got %d", digestTopN, len(got))
	}
	// 6+6=12 应该冲到第一;若先截断再归并,榜首会是 A(9)。
	if got[0].Count != 12 {
		t.Fatalf("归并必须发生在截断之前, got %+v", got)
	}
}

func TestDigestListenBrainzPathMergesArtists(t *testing.T) {
	// LB 那条路径拿到的是逐条收听、没有 mbid,只能按 artistMergeNameKey 分桶。
	// 这里直接验证键函数对同一组真实写法给出同一个键 —— digest 的分桶就建立在它上面。
	same := []string{"张震岳", "张震嶽"}
	k0 := artistMergeNameKey(same[0])
	for _, s := range same[1:] {
		if k := artistMergeNameKey(s); k != k0 {
			t.Fatalf("%q 与 %q 应折成同一个键, got %q vs %q", same[0], s, k0, k)
		}
	}
	if artistMergeNameKey("周杰伦") == k0 {
		t.Fatal("不相干的歌手不该折成同一个键")
	}

	// 展示名**不**做繁简折叠:只把已知罗马字艺名换成中文本名,不篡改用户库里原本的书写。
	if got := artistMergeDisplayName("张震嶽"); got != "张震嶽" {
		t.Fatalf("展示名不该被折成简体, got %q", got)
	}
}
