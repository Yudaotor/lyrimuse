package main

import (
	"context"
	"log"
	"regexp"
	"strings"
	"unicode"
)

// titleVariantRound:前面几轮跑完还有源缺着时,曲名换一种写法(titleVariantFor)只问缺着的那几个源,合并后照旧按
// 本地曲名重打分(mergeLyricCandidateRounds)。先用本地署名问,还缺着的再用它的第一个别名(retryArtistIdentitiesWithOrigin)
// 问一次:国内几家多按原文署名登记(「キタニタツヤ」对「Tatsuya Kitani」)。首轮仍用整串:Apple Music、Musixmatch 这几家
// 登记的就是整串,换成前一段反而搜不到。没有换写法的余地、或没有缺着的源时原样返回。见 09 章决策 191。
func titleVariantRound(ctx context.Context, artist, title, album string, durationSecs float64, ne neteaseInfo,
	results []scoredLyricCandidateResult, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	variant := titleVariantFor(artist, title)
	if variant == "" || len(lyricSourcesWorthAliasRetry(ctx, results)) == 0 {
		return ne, results
	}
	identities := []artistIdentity{{name: artist}}
	if alts := retryArtistIdentitiesWithOrigin(ctx, artist); len(alts) > 0 {
		identities = append(identities, alts[0])
	}
	for _, id := range identities {
		only := lyricSourcesWorthAliasRetry(ctx, results)
		if len(only) == 0 {
			break
		}
		update := mergedRoundUpdate(onUpdate, artist, title, album, durationSecs, results)
		variantCtx := withLyricQueryOrigin(withLyricQueryReason(withLyricSourceOnly(ctx, only), lyricQueryReasonTitleVariant), id.origin)
		variantNe, variantResults := fetchScoredLyricCandidatesStreaming(variantCtx, id.name, variant, album, durationSecs, update)
		for i := range variantResults {
			variantResults[i].RetryMethod = lyricQueryReasonTitleVariant
			variantResults[i].RetriedTitle = variant
		}
		merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, variantResults)
		if usableLyricSourceCount(merged) > usableLyricSourceCount(results) {
			log.Printf("lyrics: title variant %q by %s added candidates for %q - %q: usable_sources=%d->%d",
				variant, id, artist, title, usableLyricSourceCount(results), usableLyricSourceCount(merged))
		}
		if ne.Cover == "" && variantNe.Cover != "" {
			ne.Cover, ne.Album, ne.AlbumID = variantNe.Cover, variantNe.Album, variantNe.AlbumID
		}
		if ne.SongURL == "" && variantNe.SongURL != "" {
			ne.SongURL = variantNe.SongURL
		}
		results = merged
	}
	return ne, results
}

// titleVariantFor:缺着的源换哪种写法再问。「中日韩文字的歌名 - 拉丁字母的译名或读音」取前一段(translationTitleHead),
// 「歌名 / 歌手」去掉后一段(artistTitleTailHead);都不是返回空串。
func titleVariantFor(artist, title string) string {
	if head := translationTitleHead(artist, title); head != "" {
		return head
	}
	return artistTitleTailHead(artist, title)
}

// translationTitleHead:「青のすみか - Where Our Blue Is」「桜 - Sakura」这种曲名返回前一段,否则返回空串。只按最后一个
// 「 - 」切。前一段要有中日韩文字、不能有拉丁字母(「호시 (HOSHI) - STAY」是「歌手 - 歌名」),也不能就是歌手名;
// 后一段只有拉丁字母和词内标点,不带数字、版本词(titleVersionTags),也不带 translationTailNotes 里说明这一轨是什么的词
// (「鬼 - Overture」是这首歌的序曲,不是译名)。
func translationTitleHead(artist, title string) string {
	head, tail, ok := dashTailSplit(strings.TrimSpace(cleanMediaTag(title)))
	if !ok || !containsCJKScript(head) || strings.ContainsFunc(head, isASCIILetter) ||
		containsCJKScript(tail) || strings.ContainsFunc(tail, unicode.IsDigit) || countRunes(tail, isASCIILetter) < 2 ||
		len(titleVersionTags("("+tail+")")) > 0 || translationTailNotes.MatchString(tail) ||
		normLoose(head) == normLoose(cleanMediaTag(artist)) {
		return ""
	}
	return head
}

// translationTailNotes:「 - 」后面出现就说明那一段不是译名,而是版本、出处或这一轨在作品里的位置。
var translationTailNotes = regexp.MustCompile(`(?i)\b(?:feat|ft|featuring|with|from|theme|ost|soundtrack|cover|official|video|audio|lyrics?|mv|intro|outro|interlude|prelude|overture|reprise|coda|medley|remaster(?:ed)?|bonus|single|explicit|clean|version|ver|instrumental|inst|karaoke|tv|size|edit|mix|remix|live|demo|acoustic)\b`)

// artistTitleTailHead:「地上の星 / 中島みゆき」这种在歌名后面接「 / 歌手」的,返回前一段;最后一个「 / 」后面那段要跟
// 播放器报的歌手 normLoose 全等,否则返回空串(「A / B」这类串烧曲名不动)。
func artistTitleTailHead(artist, title string) string {
	t := strings.TrimSpace(cleanMediaTag(title))
	i := strings.LastIndex(t, " / ")
	if i <= 0 {
		return ""
	}
	head, tail := strings.TrimSpace(t[:i]), strings.TrimSpace(t[i+len(" / "):])
	a := normLoose(cleanMediaTag(artist))
	if head == "" || a == "" || normLoose(tail) != a {
		return ""
	}
	return head
}
