package main

import (
	"context"
	"regexp"
	"strings"
)

// 曲名结尾的再版 / 分级尾巴:「First Love (Remastered 2014)」「When Doves Cry (2015 Paisley Park Remaster)」
// 「Linger - Remastered 2026」「Bad - 2012 Remaster」「烦 (Explicit)」。同一份录音在 Last.fm 上会因为这条尾巴
// 拆成两个条目,两边都可能是编目正规条目(带尾巴的那条常常也有 mbid),所以折叠比对和「原样有 mbid 就不动」
// 都挡不住拆分。编目判定遇到这种曲名时先按去掉尾巴的写法整个判一遍(decideReleaseTail),判出编目条目就发它。
//
// 比 lastfmcatalogkey.go 的折叠宽:那边只认括号里恰好是「Remastered 2014」这种完整写法,这里还认夹着
// 厂牌 / 地名的写法和破折号式。宽出来的部分靠两道门兜住:带 Live / Remix / Mono 这类版本词的不剥
// (那是另一份录音或另一版混音),去掉尾巴后的写法还要自己在编目里判得出来(时长闸照旧)。决策见 12 章 §4。

// lastfmCatalogTailVersion 是尾巴判定的口径版本。缓存里带尾巴的曲名、结论早于这个版本的要重判(见 lookup);
// 不带尾巴的结论不受影响。
const lastfmCatalogTailVersion = 1

var (
	releaseTailRemasterRe = regexp.MustCompile(`(?i)\bre-?master(ed)?\b`)
	releaseTailVersionRe  = regexp.MustCompile(`(?i)\b(live|remix|mix|demo|acoustic|instrumental|edit|mono|stereo|karaoke|unplugged|session|take|single|radio|extended)\b`)
	// 最后一个破折号之后的那一段。
	releaseTailDashRe = regexp.MustCompile(`\s+[-–—]\s+([^-–—]+)$`)
)

// 尾巴最多几个词。再长就不像发行标记了(「2015 Paisley Park Remaster」是 4 个)。
const releaseTailMaxWords = 6

func isReleaseTail(s string) bool {
	s = strings.ToLower(strings.TrimSpace(cleanMediaTag(s)))
	if s == "" {
		return false
	}
	if catalogNoiseExplicitRe.MatchString(s) {
		return true
	}
	return releaseTailRemasterRe.MatchString(s) && !releaseTailVersionRe.MatchString(s) &&
		len(strings.Fields(s)) <= releaseTailMaxWords
}

// stripReleaseTail 反复剥掉结尾的再版 / 分级尾巴(括号式、破折号式都认)。第二个返回值 = 确实剥掉了东西。
// 剥完什么都不剩就停在上一步。
func stripReleaseTail(title string) (string, bool) {
	t := cleanMediaTag(title)
	stripped := false
	for {
		var m []int
		if m = catalogSubtitleTrailingRe.FindStringSubmatchIndex(t); m == nil || !isReleaseTail(t[m[2]:m[3]]) {
			if m = releaseTailDashRe.FindStringSubmatchIndex(t); m == nil || !isReleaseTail(t[m[2]:m[3]]) {
				return t, stripped
			}
		}
		rest := strings.TrimSpace(t[:m[0]])
		if rest == "" {
			return t, stripped
		}
		t, stripped = rest, true
	}
}

// catalogKeyHasReleaseTail:缓存键("歌手\n曲名")里的曲名带不带尾巴。
func catalogKeyHasReleaseTail(key string) bool {
	_, track, ok := strings.Cut(key, "\n")
	if !ok {
		return false
	}
	_, stripped := stripReleaseTail(track)
	return stripped
}

// decideReleaseTail:曲名带尾巴、而且允许改曲名时,按去掉尾巴的写法整个判一遍。判出 keep / match 就改写成它
// (done == true),原样那条有 mbid 也不用;判不出返回 done == false,调用方按原样照常判。
// 这一遍只跑基础判定、不跑扩展搜索(withCatalogBaseOnly):扩展搜索要查 MusicBrainz 别名,两遍都跑会把
// 一次判定的预算吃掉一半,而原样那一遍的扩展搜索照样会跑。
func (c *lastfmCatalogMatcher) decideReleaseTail(ctx context.Context, artist, track string, durationSecs float64,
	scope matchScope, own lastfmCatalogProbe) (lastfmCatalogDecision, bool, error) {
	if !scope.track {
		return lastfmCatalogDecision{}, false, nil
	}
	clean, ok := stripReleaseTail(track)
	if !ok || clean == track {
		return lastfmCatalogDecision{}, false, nil
	}
	td, err := c.decide(withCatalogBaseOnly(ctx), artist, clean, durationSecs, scope)
	if err != nil {
		return lastfmCatalogDecision{}, false, err
	}
	if td.Verdict != verdictKeep && td.Verdict != verdictMatch {
		return lastfmCatalogDecision{}, false, nil
	}
	chosen := td.Chosen
	if td.Verdict == verdictKeep {
		chosen = td.Own
	}
	return lastfmCatalogDecision{
		Verdict: verdictMatch, Artist: td.Artist, Track: orDefault(td.Track, clean),
		Own: &own, Chosen: chosen, Scope: scope.id(), Via: strings.TrimSuffix("tail+"+td.Via, "+"),
	}, true, nil
}

type catalogBaseOnlyKey struct{}

// withCatalogBaseOnly 让这次判定跳过扩展搜索(decideExtended 直接判 defer)。
func withCatalogBaseOnly(ctx context.Context) context.Context {
	return context.WithValue(ctx, catalogBaseOnlyKey{}, true)
}

func catalogBaseOnly(ctx context.Context) bool {
	v, _ := ctx.Value(catalogBaseOnlyKey{}).(bool)
	return v
}
