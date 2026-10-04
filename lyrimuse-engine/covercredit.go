package main

import (
	"context"
	"log"
	"regexp"
	"strings"
)

// 翻唱重入:曲名写着「(Cover by 翻唱者)」、播放器的歌手位是团体 / 频道名时,歌词源把这首翻唱挂在翻唱者名下,
// 拿歌手位去查一个候选都没有。换成(翻唱者, 去掉署名的曲名)整个重入一次,只认翻唱版本身:
// 这一轮的换名只用翻唱者自己的别名,不从曲名 / 专辑反推别的歌手(那会把原唱的词带进来)。
// 决策见 09 章。

// coverBracketPairs:认的括号对。
var coverBracketPairs = [][2]string{{"(", ")"}, {"[", "]"}, {"（", "）"}, {"【", "】"}}

var (
	// 括号内的翻唱者署名:「Cover by X」「Covered by: X」。
	coverPerformerInner = regexp.MustCompile(`(?i)^cover(?:ed)?\s+by(?:\s*[:：]\s*|\s+)(\S.*)$`)
	// 不带括号、跟在曲名后面的翻唱者署名:「Song Covered by X」。前面必须有曲名。
	coverPerformerBare = regexp.MustCompile(`(?i)^(.*\S)\s+cover(?:ed)?\s+by(?:\s*[:：]\s*|\s+)(\S.*)$`)
)

type coverSegment struct {
	start, end int // 含括号的字节区间 [start, end)
	inner      string
}

// coverBracketSegments 按出现顺序列出曲名里所有成对括号段(不处理嵌套:取同类型的第一个闭括号)。
func coverBracketSegments(title string) []coverSegment {
	var out []coverSegment
	for i := 0; i < len(title); {
		matched := false
		for _, br := range coverBracketPairs {
			if !strings.HasPrefix(title[i:], br[0]) {
				continue
			}
			innerStart := i + len(br[0])
			closeRel := strings.Index(title[innerStart:], br[1])
			if closeRel < 0 {
				continue
			}
			end := innerStart + closeRel + len(br[1])
			out = append(out, coverSegment{start: i, end: end, inner: strings.TrimSpace(title[innerStart : innerStart+closeRel])})
			i = end
			matched = true
			break
		}
		if !matched {
			i++
		}
	}
	return out
}

// coverPerformerIdentity 从曲名里取出翻唱者,并返回去掉这段署名(以及开头的方括号标签)之后的曲名。
// 没有翻唱者署名、或拆出来的任一段为空时 ok=false。只写了「(Cover)」、没有名字的不算:没有可换的人。
func coverPerformerIdentity(title string) (performer, song string, ok bool) {
	song = title
	for _, seg := range coverBracketSegments(title) {
		if m := coverPerformerInner.FindStringSubmatch(seg.inner); m != nil {
			performer = strings.TrimSpace(m[1])
			song = title[:seg.start] + " " + title[seg.end:]
			break
		}
	}
	song = strings.Join(strings.Fields(song), " ")
	if performer == "" {
		m := coverPerformerBare.FindStringSubmatch(song)
		if m == nil {
			return "", "", false
		}
		song, performer = strings.TrimSpace(m[1]), strings.TrimSpace(m[2])
	}
	song = stripLeadingBracketTags(song)
	if normLoose(performer) == "" || normLoose(song) == "" {
		return "", "", false
	}
	return performer, song, true
}

// stripLeadingBracketTags 去掉曲名开头的方括号标签(「[Special]」「【MV】」),去完为空就原样返回。
func stripLeadingBracketTags(s string) string {
	out := strings.TrimSpace(s)
	for {
		segs := coverBracketSegments(out)
		if len(segs) == 0 || segs[0].start != 0 {
			break
		}
		rest := strings.TrimSpace(out[segs[0].end:])
		if normLoose(rest) == "" {
			break
		}
		out = rest
	}
	return out
}

type coverPerformerOnlyKey struct{}

// withCoverPerformerOnly / coverPerformerOnly:ctx 上标记「这一轮只认翻唱者本人」。别名轮据此只用
// retryArtistIdentities(翻唱者自己的别名),跳过从曲名 / 专辑反推署名的几路;拆分重入也不跑(它会把曲名里
// 别的名字当歌手)。同 withLyricQueryReason 走 ctx,重入里的每一层都带着。
func withCoverPerformerOnly(ctx context.Context) context.Context {
	return context.WithValue(ctx, coverPerformerOnlyKey{}, true)
}

func coverPerformerOnly(ctx context.Context) bool {
	v, _ := ctx.Value(coverPerformerOnlyKey{}).(bool)
	return v
}

// coverRescueSearch:重入用的检索,nil = scoredLyricCandidatesStreaming。变量只为单测可替换
// (不能直接初始化成 scoredLyricCandidatesStreaming:那边调这里,会成初始化环)。
var coverRescueSearch func(ctx context.Context, artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult)

// coverRescue 返回 ok=false 表示曲名里没有翻唱者署名、翻唱者就是原署名、或者翻唱版没查到,调用方照旧用原来那份结果。
func coverRescue(ctx context.Context, artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult, bool) {
	if coverPerformerOnly(ctx) {
		return neteaseInfo{}, nil, false
	}
	performer, song, ok := coverPerformerIdentity(title)
	if !ok || artistMatches(performer, artist) {
		return neteaseInfo{}, nil, false
	}
	search := coverRescueSearch
	if search == nil {
		search = scoredLyricCandidatesStreaming
	}
	log.Printf("lyrics: %q - %q has no usable candidate, retrying as cover-credit identity %q - %q", artist, title, performer, song)
	coverCtx := withCoverPerformerOnly(withLyricQueryReason(ctx, lyricQueryReasonCoverCredit))
	ne, results := search(coverCtx, performer, song, album, durationSecs, onUpdate)
	if !hasUsableLyricCandidate(results) {
		return neteaseInfo{}, nil, false
	}
	log.Printf("lyrics: cover-credit identity fallback succeeded: original=%q - %q identity=%q - %q candidates=%d sources=%v",
		artist, title, performer, song, len(results), lyricSourcesWithCandidates(results))
	return ne, results, true
}
