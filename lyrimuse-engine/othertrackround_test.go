package main

import (
	"context"
	"testing"
)

// 别的歌那一轮(按组重搜、全量扫库……)里,QQ 本地曲库给定身份的候选不拿同源加权;不标的那一轮照常拿。见 09 章决策 299。
func TestOtherTrackRoundDropsNativeBonus(t *testing.T) {
	playingFor(t, playerQQMusic)
	qq := lyricSourceResult{source: "qq", lyr: playerTestLRC, matchTitle: "歌名", matchArtist: "歌手", srcDur: 25, identityFromLocalClient: true}
	nativePoints := func(ctx context.Context) int {
		t.Helper()
		raw := map[string]lyricSourceResult{"qq": withoutPlayerIdentity(ctx, qq), "kugou": kugouWithLyrics()}
		for _, c := range rankLyricSourceResults("歌手", "歌名", "", 25, raw) {
			if c.Source == "qq" {
				return scoreTermPoints(c.ScoreTerms, scoreTermNativeSource)
			}
		}
		t.Fatal("没有 qq 候选")
		return 0
	}
	if got := nativePoints(context.Background()); got != 250 {
		t.Fatalf("QQ 音乐在放、身份读自它的本地曲库:该拿同源加权 250,得到 %d", got)
	}
	if got := nativePoints(withOtherTrackRound(context.Background())); got != 0 {
		t.Fatalf("别的歌那一轮不给同源加权,得到 %d", got)
	}
}

// 网易云那一路的本机身份在 ne.FromLocalClient 上,一起清。
func TestOtherTrackRoundClearsNeteaseLocalIdentity(t *testing.T) {
	r := lyricSourceResult{source: "netease", ne: neteaseInfo{FromLocalClient: true}, identityFromLocalClient: true}
	if got := withoutPlayerIdentity(context.Background(), r); !got.ne.FromLocalClient || !got.identityFromLocalClient {
		t.Fatalf("没标别的歌时原样返回,得到 %+v", got)
	}
	if got := withoutPlayerIdentity(withOtherTrackRound(context.Background()), r); got.ne.FromLocalClient || got.identityFromLocalClient {
		t.Fatalf("别的歌那一轮两个本机身份都该清掉,得到 %+v", got)
	}
}

// 全量扫库、补空扫描、手动重新匹配轮到正在放的那首时照常算同源加权。
func TestOtherTrackRoundUnlessPlaying(t *testing.T) {
	playing := "歌手|歌名|专辑"
	prev := enrichPlayingKey.Load()
	t.Cleanup(func() { enrichPlayingKey.Store(prev) })
	enrichPlayingKey.Store(&playing)
	if isOtherTrackRound(withOtherTrackRoundUnlessPlaying(context.Background(), playing)) {
		t.Fatal("正在放的那首不该标成别的歌")
	}
	if !isOtherTrackRound(withOtherTrackRoundUnlessPlaying(context.Background(), "别人|另一首|")) {
		t.Fatal("不是正在放的那首该标成别的歌")
	}
}
