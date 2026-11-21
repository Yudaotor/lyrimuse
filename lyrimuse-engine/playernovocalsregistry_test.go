package main

import (
	"encoding/json"
	"testing"
)

// 播放器自己的无人声信号按登记表走之后,跟迁移前按源名、按播放器写的那一版给出同样的结果。

// 每个播放器在放时,带 privPlayerNoVocals 的来源里它至多认一个是自家的:playerInstrumentalSource 按登记的先后走这份名单,
// 先后不同于迁移前那份字面量名单,靠这一条才不影响结果。
func TestPlayerOwnsAtMostOneNoVocalsSource(t *testing.T) {
	saveRankState(t)
	owned := 0
	for player, bundle := range playerBundleIDs {
		setNativeLyricSourcesForPlayer(bundle)
		var mine []string
		for _, name := range lyricProviders().playerNoVocalsNames {
			if playerOwnsLyricSource(name) {
				mine = append(mine, name)
			}
		}
		if len(mine) > 1 {
			t.Errorf("%s 在放时认 %v 都是自家的", player, mine)
		}
		owned += len(mine)
	}
	if owned < len(lyricSourcePlayerNoVocalsSources) {
		t.Errorf("各播放器合起来只认了 %d 个自家的源,期望表里有 %d 个", owned, len(lyricSourcePlayerNoVocalsSources))
	}
}

// playerInstrumentalSource:每个播放器、每个来源各说一次「没有人声」(身份由本机给、解析的是在放的这首),返回的源名跟
// 迁移前那份名单(lyricSourcePlayerNoVocalsSources)加「是它自家的」推出来的一样;不在名单里的来源说了也不算。
func TestPlayerInstrumentalSourceFollowsRegistry(t *testing.T) {
	saveRankState(t)
	hits := 0
	for player, bundle := range playerBundleIDs {
		setNativeLyricSourcesForPlayer(bundle)
		for _, d := range registryDescriptors() {
			raw := map[string]lyricSourceResult{d.Name: {source: d.Name, noVocals: true, identityFromLocalClient: true, forPlayingTrack: true}}
			want := ""
			for _, name := range lyricSourcePlayerNoVocalsSources {
				if name == d.Name && playerOwnsLyricSource(name) {
					want = name
				}
			}
			if got := playerInstrumentalSource(lyricProviders(), raw, nil); got != want {
				t.Errorf("%s 在放、%s 说没有人声:返回 %q,该是 %q", player, d.Name, got, want)
			}
			if want != "" {
				hits++
			}
		}
	}
	if hits < len(lyricSourcePlayerNoVocalsSources) {
		t.Errorf("只走到 %d 次返回源名,这条对比太空", hits)
	}
}

// 开搜前的无人声提示:网易云客户端曲库里带无人声位的一首、汽水播放队列缓存里 vocal==2 的一首、两边都没有的一首,在每个
// 播放器下问一遍,跟迁移前按播放器写的那一版(expectedPlayerLocalNoVocalsHint)一样。
func TestPreSearchNoVocalsHintMatchesExpected(t *testing.T) {
	saveRankState(t)
	var m map[string]any
	if err := json.Unmarshal([]byte(neteaseTestTrack("569213220", "像我这样的人", "毛不易", "平凡的一天", 207466)), &m); err != nil {
		t.Fatal(err)
	}
	m["mark"] = neteaseMarkNoVocals | 1<<13
	marked, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, []string{string(marked), neteaseTestTrack("1", "有人声的歌", "某歌手", "某专辑", 200000)}))
	inst := sodaTestTrack("歌（伴奏）", "单曲歌手", "歌", 240000, sodaLocalVocalInstrumental, -1)
	inst["id"] = "inst-1"
	resetSodaLocalIndex(t, writeTestSodaQueue(t, []map[string]any{inst, sodaTestTrack("有人声的歌", "某歌手", "某专辑", 200000, 1, 1000)}))

	tracks := []ProviderQuery{
		{Artist: "毛不易", Title: "像我这样的人", SourceTitle: "像我这样的人", Album: "平凡的一天", DurationSecs: 207},
		{Artist: "单曲歌手", Title: "歌（伴奏）", SourceTitle: "歌（伴奏）", Album: "歌", DurationSecs: 240},
		{Artist: "某歌手", Title: "有人声的歌", SourceTitle: "有人声的歌", Album: "某专辑", DurationSecs: 200},
		// 歌名带编号时交给各源的是带编号的那一份(SourceTitle),本机数据按它认。
		{Artist: "毛不易", Title: "别的写法", SourceTitle: "像我这样的人", Album: "平凡的一天", DurationSecs: 207},
	}
	hinted := map[string]int{}
	players := map[string]string{"": ""}
	for player, bundle := range playerBundleIDs {
		players[player] = bundle
	}
	for player, bundle := range players {
		setNativeLyricSourcesForPlayer(bundle)
		for _, q := range tracks {
			want := expectedPlayerLocalNoVocalsHint(q.Artist, q.SourceTitle, q.Album, q.DurationSecs)
			if got := playerNoVocalsHintBeforeSearch(lyricProviders(), q); got != want {
				t.Errorf("%q 在放、%s - %s:提示=%v,迁移前=%v", player, q.Artist, q.SourceTitle, got, want)
			}
			if want {
				hinted[player]++
			}
		}
	}
	if hinted[playerNetease] != 2 || hinted[playerSoda] != 1 || len(hinted) != 2 {
		t.Errorf("该只有网易云(两首写法)和汽水(一首)在放时有提示,实际 %v", hinted)
	}
}
