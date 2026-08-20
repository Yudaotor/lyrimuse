package main

import "testing"

// 2026-08-17 用户报的第二个现象:Top 歌手榜里 K/DA 显示成 **"K"**。
//
// 根因跟歌词搜索那个是同一个:`/` 既在 isArtistCreditSep 里、又是 "K/DA" 这个名字自身的
// 一部分。原来 artistMergeDisplayName 第一步用 firstCreditedArtist 从串里"猜第一个歌手",
// 于是 "K/DA" 被切成 ["K","DA"]、显示成一个**数据里根本没出现过的** "K"。
//
// ⚠️ 合并本身一直是对的(两者的 nameKey 都塌缩成 "k",次数正确相加)—— 所以这一组用例
// 的重点是"次数别改坏 + 显示名从真实出现过的写法里挑"。
func TestMergeAliasedArtistsDisplayName(t *testing.T) {
	const kdaCollab = "K/DA/Madison Beer/(G)I-DLE/Jaira Burns"

	t.Run("名字自带斜杠的歌手显示本名而不是被切开的前半截", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "K/DA", PlayCount: 30},
			{Name: kdaCollab, PlayCount: 12},
			{Name: "Madison Beer", PlayCount: 20},
		})
		want := []lastfmChartEntry{
			{Name: "K/DA", PlayCount: 42},        // 30 + 12,显示本名
			{Name: "Madison Beer", PlayCount: 20}, // 联合署名的第二位不该被并进去
		}
		assertChart(t, got, want)
	})

	t.Run("本名条目排在合credit 串后面也要胜出", func(t *testing.T) {
		// 播放次数少的本名条目会排在后面 —— 显示名不能是"先遇到谁用谁"。
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: kdaCollab, PlayCount: 40},
			{Name: "K/DA", PlayCount: 3},
		})
		assertChart(t, got, []lastfmChartEntry{{Name: "K/DA", PlayCount: 43}})
	})

	t.Run("合credit 串单独出现时原样显示,不猜第一个歌手", func(t *testing.T) {
		// 桶里没有本名条目可挑,只能显示这个真实出现过的完整写法 ——
		// 这是刻意的:好过显示一个凭空切出来的名字。
		got := mergeAliasedArtists([]lastfmChartEntry{{Name: kdaCollab, PlayCount: 7}})
		assertChart(t, got, []lastfmChartEntry{{Name: kdaCollab, PlayCount: 7}})
	})

	t.Run("经典合唱串跟本名同时在榜时显示本名", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "Prince & The Revolution", PlayCount: 25},
			{Name: "Prince", PlayCount: 9},
		})
		assertChart(t, got, []lastfmChartEntry{{Name: "Prince", PlayCount: 34}})
	})

	t.Run("已知别名仍然换成中文名", func(t *testing.T) {
		// artistAliasTable 里登记了 "dean ting" → "丁世光"。这一步不能被这次改动弄丢。
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "Dean Ting", PlayCount: 11},
			{Name: "丁世光", PlayCount: 4},
		})
		assertChart(t, got, []lastfmChartEntry{{Name: "丁世光", PlayCount: 15}})
	})

	t.Run("mbid 相同照旧合并", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "Sigur Rós", PlayCount: 8, Mbid: "abc"},
			{Name: "Sigur Ros", PlayCount: 5, Mbid: "abc"},
		})
		assertChart(t, got, []lastfmChartEntry{{Name: "Sigur Rós", PlayCount: 13}})
	})

	t.Run("毫无关系的歌手不合并", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "IU", PlayCount: 9},
			{Name: "K/DA", PlayCount: 6},
		})
		assertChart(t, got, []lastfmChartEntry{
			{Name: "IU", PlayCount: 9},
			{Name: "K/DA", PlayCount: 6},
		})
	})
}

func assertChart(t *testing.T, got, want []lastfmChartEntry) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("条目数 = %d, want %d；实际 = %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i].Name != want[i].Name || got[i].PlayCount != want[i].PlayCount {
			t.Errorf("第 %d 条 = {%q, %d}, want {%q, %d}",
				i, got[i].Name, got[i].PlayCount, want[i].Name, want[i].PlayCount)
		}
	}
}
