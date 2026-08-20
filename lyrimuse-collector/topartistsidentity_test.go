package main

import "testing"

// 2026-08-18 用户逐条核对 Top100 导出,坐实 8 对"同一个人两个写法"漏合并(窦靖童/Leah Dou
// 等)。这批用例覆盖为此新增的第三合并信号:MusicBrainz 身份解析(mbid+中文名),经
// artistIdentityFn 注入假函数测,不碰网络。
func TestMergeAliasedArtistsIdentity(t *testing.T) {
	noID := func(string, string) mbArtistIdentity { return mbArtistIdentity{} }

	t.Run("两个名字解析到同一个 mbid 就合并,显示中文成员名", func(t *testing.T) {
		resolve := func(name, _ string) mbArtistIdentity {
			switch name {
			case "Leah Dou", "窦靖童":
				return mbArtistIdentity{Mbid: "f5cc9359"}
			}
			return mbArtistIdentity{}
		}
		got := mergeAliasedArtistsResolved([]lastfmChartEntry{
			{Name: "窦靖童", PlayCount: 46},
			{Name: "Leah Dou", PlayCount: 19},
		}, resolve)
		assertChart(t, got, []lastfmChartEntry{{Name: "窦靖童", PlayCount: 65}})
	})

	t.Run("桶里全是罗马写法时用解析出的中文名显示", func(t *testing.T) {
		resolve := func(name, _ string) mbArtistIdentity {
			if name == "Ronghao Li" {
				return mbArtistIdentity{Mbid: "abc", Zh: "李荣浩"}
			}
			return mbArtistIdentity{}
		}
		got := mergeAliasedArtistsResolved([]lastfmChartEntry{
			{Name: "Ronghao Li", PlayCount: 5},
		}, resolve)
		assertChart(t, got, []lastfmChartEntry{{Name: "李荣浩", PlayCount: 5}})
	})

	t.Run("解析出的中文名跟已有中文条目按名字键桥接(含繁简)", func(t *testing.T) {
		// 通用路径:A 解析出中文名、B 本来就用中文名(繁体写法),没有任何 mbid 也要并上。
		resolve := func(name, _ string) mbArtistIdentity {
			if name == "Test Artist" {
				return mbArtistIdentity{Zh: "测试歌手"}
			}
			return mbArtistIdentity{}
		}
		got := mergeAliasedArtistsResolved([]lastfmChartEntry{
			{Name: "測試歌手", PlayCount: 9},
			{Name: "Test Artist", PlayCount: 4},
		}, resolve)
		assertChart(t, got, []lastfmChartEntry{{Name: "測試歌手", PlayCount: 13}})
	})

	t.Run("含汉字的合唱串不抢夺显示名", func(t *testing.T) {
		// 首版实测翻车:"Michael Jackson & 克里夫兰管弦乐团"(2 次播放)把
		// "Michael Jackson"(1084 次)顶掉了。中文优先只认单人写法。
		got := mergeAliasedArtistsResolved([]lastfmChartEntry{
			{Name: "Michael Jackson", PlayCount: 1084},
			{Name: "Michael Jackson & 克里夫兰管弦乐团", PlayCount: 2},
		}, noID)
		assertChart(t, got, []lastfmChartEntry{{Name: "Michael Jackson", PlayCount: 1086}})
	})

	t.Run("解析不出身份时行为与旧逻辑一致(不并、不改名)", func(t *testing.T) {
		got := mergeAliasedArtistsResolved([]lastfmChartEntry{
			{Name: "Fan Yi Chen", PlayCount: 2},
			{Name: "ØZI", PlayCount: 2},
		}, noID)
		assertChart(t, got, []lastfmChartEntry{
			{Name: "Fan Yi Chen", PlayCount: 2},
			{Name: "ØZI", PlayCount: 2},
		})
	})

	t.Run("别名表新增条目不靠解析器也能合并并显示常用名", func(t *testing.T) {
		got := mergeAliasedArtistsResolved([]lastfmChartEntry{
			{Name: "宇多田ヒカル", PlayCount: 955},
			{Name: "Utada", PlayCount: 5},
			{Name: "Wanting", PlayCount: 16},
			{Name: "曲婉婷", PlayCount: 2},
		}, noID)
		assertChart(t, got, []lastfmChartEntry{
			{Name: "宇多田ヒカル", PlayCount: 960},
			{Name: "曲婉婷", PlayCount: 18},
		})
	})

	t.Run("合唱串不把整串的 mbid 传给第一位歌手", func(t *testing.T) {
		// "Prince & The Revolution" 在 Last.fm 有自己的 mbid(乐队实体),它不属于
		// Prince 本人;若把它当 Prince 的已知身份传给解析器,缓存会被污染。独唱行
		// 传自己的 mbid 是正确行为,这里只断言乐队串那条绝不以("Prince", 乐队mbid)
		// 的组合到达解析器。
		polluted := false
		resolve := func(name, known string) mbArtistIdentity {
			if name == "Prince" && known == "band-mbid" {
				polluted = true
			}
			return mbArtistIdentity{}
		}
		mergeAliasedArtistsResolved([]lastfmChartEntry{
			{Name: "Prince & The Revolution", PlayCount: 10, Mbid: "band-mbid"},
			{Name: "Prince", PlayCount: 900, Mbid: "prince-mbid"},
		}, resolve)
		if polluted {
			t.Fatal("合唱串的 mbid 被当成第一位歌手的已知身份传下去了")
		}
	})
}
