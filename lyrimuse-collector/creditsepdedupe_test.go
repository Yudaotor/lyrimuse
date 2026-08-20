package main

import "testing"

// 合 credit 分隔符必须参与宽松比对(2026-08-20)。
//
// 实测形态:同一次播放里两条路径对多歌手串的写法系统性不同 —— 播放器(media-control)
// 报 `VALORANT/Grabbitz/bbno$`,专辑预取从 Apple Music 自己的曲目表(AppleScript
// `artist of t`)拿到的是 `VALORANT & Grabbitz & bbno$`。缓存里因此长出 12 组、24 条
// 只差分隔符的重复条目(Arcane 原声带 / VALORANT / K/DA 这些多歌手曲目),两条相隔只有
// 2~8 秒。预取本来有 canonicalEnrichKey + looseInflightKey 两道宽松查重,但它们都建立在
// loosenEnrichKey 上 —— 折不平分隔符就一起失效。
func TestLoosenEnrichKeyFoldsCreditSeparators(t *testing.T) {
	same := [][2]string{
		{
			"VALORANT/Grabbitz/bbno$|Ticking Away|Ticking Away",
			"VALORANT & Grabbitz & bbno$|Ticking Away|Ticking Away",
		},
		{
			"英雄联盟/Mako/The Word Alive/The Glitch Mob|RISE|RISE",
			"英雄联盟 & Mako & The Word Alive & The Glitch Mob|RISE|RISE",
		},
		{
			"陶喆、卢广仲|某首歌|某专辑",
			"陶喆/卢广仲|某首歌|某专辑",
		},
		{
			// 顺带确认原有两档(空格、繁简)没被这次改动破坏
			"丁世光|無名花香|背面是我",
			"丁世光|无名花香|背面是我",
		},
	}
	for _, pair := range same {
		if loosenEnrichKey(pair[0]) != loosenEnrichKey(pair[1]) {
			t.Errorf("应判为同一首:\n  %q -> %q\n  %q -> %q",
				pair[0], loosenEnrichKey(pair[0]), pair[1], loosenEnrichKey(pair[1]))
		}
	}

	// 折平分隔符不能把**真的不同**的歌并到一起:歌名/歌手实质不同的仍要分开。
	diff := [][2]string{
		{"K/DA|POP/STARS|POP/STARS", "K/DA|MORE|MORE"},
		{"VALORANT/Grabbitz|Die For You|Die For You", "VALORANT/Grabbitz|Ticking Away|Ticking Away"},
		{"A/B|同名歌|专辑甲", "A/B|同名歌|专辑乙"},
	}
	for _, pair := range diff {
		if loosenEnrichKey(pair[0]) == loosenEnrichKey(pair[1]) {
			t.Errorf("不该判为同一首: %q vs %q(都折成 %q)",
				pair[0], pair[1], loosenEnrichKey(pair[0]))
		}
	}
}
