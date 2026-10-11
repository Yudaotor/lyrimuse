package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

// 歌曲实体阶段 3 按共享组换词的判据:每条写法现有的那份歌词、要重搜的共享组、拿去搜的写法与时长、整组改用一份时每条写法的
// 去留。常驻引擎的同步(songentityshare.go)和两种空跑(songentityplan.go)共用这一份,见 18 章决策 24～26。

// songPlanLyrics:同一首歌里的一份歌词(按单曲偏移键里的歌词指纹分)和它的出处。
type songPlanLyrics struct {
	fp      string
	source  string
	score   int  // 胜者在它那一轮的分数,去掉自家源加分;不知道时 -1
	version int  // 那一轮的打分版本,不知道时 0
	native  bool // 胜者的分数里有自家源加分
	words   bool
	timed   bool
	manual  bool // 手改或采纳的就是这一份
	pinned  bool
}

// songOffsetFingerprint:App 单曲偏移键里的歌词指纹(LyricsOffsetStore.contentFingerprint):正文、逐字各去掉开头一个 BOM,
// 用 \x01 连起来取 SHA256 前 12 位十六进制;两样都空时是空串。两边必须一起改。
func songOffsetFingerprint(lyrics, yrc string) string {
	lyrics, yrc = strings.TrimPrefix(lyrics, "\uFEFF"), strings.TrimPrefix(yrc, "\uFEFF")
	if lyrics == "" && yrc == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(lyrics + "\x01" + yrc))
	return hex.EncodeToString(sum[:])[:12]
}

// songPlanLyricsOf:这条写法现在那份歌词;没有歌词时为 nil。分数、打分版本取采用那一轮胜者的(胜者源跟现在的来源对得上才算)。
func (b *songEntityBuild) songPlanLyricsOf(i int, picked map[string]bool) *songPlanLyrics {
	v := &b.variants[i]
	fp := songOffsetFingerprint(v.lyrics, v.yrc)
	if fp == "" {
		return nil
	}
	l := &songPlanLyrics{fp: fp, source: v.lyricsSource, score: -1, words: strings.TrimSpace(v.yrc) != "",
		timed: isTimedLRC(v.lyrics), manual: v.manual || picked[v.key], pinned: v.pinned}
	d := v.applied
	if d == nil || d.Winner == "" || (l.source != "" && d.Winner != l.source) {
		return l
	}
	l.source, l.version = d.Winner, d.ScoringVersion
	pool := readDecisionSidecar(filepath.Join(b.decisionsDir, decisionSidecarName(v.key))).slots()
	if det := resolveSlot(d, pool); det != nil {
		for _, c := range det.Candidates {
			if c.Source == d.Winner {
				nb := scoreTermPoints(c.ScoreTerms, scoreTermNativeSource)
				l.score, l.native = c.Score-nb, nb > 0
				break
			}
		}
	}
	return l
}

// songPlanBetter:在组里现有的几份之间挑时 a 是不是比 b 好。
func songPlanBetter(a, b *songPlanLyrics, na, nb int) bool {
	switch {
	case a.words != b.words:
		return a.words
	case a.timed != b.timed:
		return a.timed
	case a.version != b.version:
		return a.version > b.version
	case a.score != b.score:
		return a.score > b.score
	case na != nb:
		return na > nb
	}
	return a.fp < b.fp
}

// 不变式 6 留着自己那份的原因,快速空跑和正式空跑共用。
const (
	songKeepOwn         = "自己的手改或校准"
	songKeepNative      = "在放播放器自家的词"
	songKeepUndecidable = "这一轮比不了,现有那份的来源没应答"
	songKeepUnscored    = "这一轮没搜到它,冠军不比它存的分高"
	songKeepWords       = "有逐字,换过去就没了"
	songKeepShown       = "换过去屏上看不出差别"
	songKeepTimed       = "有时间轴,换过去是纯文本"
)

// songPlanPicked:采纳的那一份还在的写法键(manual_pick_sha 对得上现在的正文,跟 manualPickShouldFlip 同一判据)。
func songPlanPicked(cache map[string]enrichEntry) map[string]bool {
	out := map[string]bool{}
	for k, e := range cache {
		if songSharePickHeld(e) {
			out[k] = true
		}
	}
	return out
}

// songSharePickHeld:用户采纳的那一份还是现在的正文。
func songSharePickHeld(e enrichEntry) bool {
	return e.ManualPickSHA != "" && e.ManualPickSHA == manualPickFingerprint(e.Lyrics)
}

// shareEvalGroups:正式空跑要重搜的共享组:实体里没有手改或采纳、组里没有校准、两条写法以上,而且组里歌词不止一份
// (或者有写法没词)。手改、校准那几首不用搜,快速版已经按规则定了。
func (b *songEntityBuild) shareEvalGroups(own []*songPlanLyrics) [][]int {
	var out [][]int
	for _, members := range b.clusters {
		if len(members) < 2 || slices.ContainsFunc(members, func(m int) bool { return own[m] != nil && own[m].manual }) {
			continue
		}
		groups := map[int][]int{}
		for _, m := range members {
			groups[b.shareOf[m]] = append(groups[b.shareOf[m]], m)
		}
		roots := make([]int, 0, len(groups))
		for r := range groups {
			roots = append(roots, r)
		}
		sort.Ints(roots)
		for _, r := range roots {
			ms := groups[r]
			if len(ms) < 2 {
				continue
			}
			fps := map[string]bool{}
			empty, pinned := false, false
			for _, m := range ms {
				switch l := own[m]; {
				case l == nil && !b.variants[m].instrumental:
					empty = true
				case l != nil:
					fps[l.fp] = true
					pinned = pinned || l.pinned
				}
			}
			if pinned || len(fps) == 0 || (len(fps) == 1 && !empty) {
				continue
			}
			out = append(out, ms)
		}
	}
	return out
}

func songEvalKind(lyrics, yrc string) string {
	switch {
	case strings.TrimSpace(yrc) != "":
		return "逐字"
	case isTimedLRC(lyrics):
		return "逐行"
	}
	return "纯文本"
}

// songEvalLine:一条写法在某个整组选择下的去留;action 是 换 / 补 / 补逐字 / 留,不动的不出现。found:现有那份这一轮搜到了;
// contradicted:现有那份跟这一轮哪一份都对不上(rescoreCurrentContradicted)。
type songEvalLine struct {
	key, action, before, why string
	found, contradicted      bool
}

// shareEvalPlan:整组改用 choice 时每条写法的去留。先判不变式 6 里自动重评没有的两条:自己的手改、校准;当前这份是靠在放
// 播放器自家源加分选出来的。其余跟自动重评(rescoreLyricsWith)同一套:现有那份的来源这一轮没应答的比不了(rescoreDecidable),
// 跟这一轮哪一份都对不上的另一首歌的词除外(rescoreCurrentContradicted);rescoreKeepsLyrics 判留的留。最后是有时间轴换成
// 纯文本的,只有署名的不算。自动重评的判据直接调,不另抄一份。
func shareEvalPlan(keys []string, entries []enrichEntry, own []*songPlanLyrics, scored []scoredLyricCandidateResult, choice *scoredLyricCandidateResult) []songEvalLine {
	var out []songEvalLine
	for i, e := range entries {
		switch {
		case e.Lyrics == "" && e.Instrumental:
			continue
		case e.Lyrics == "":
			out = append(out, songEvalLine{key: keys[i], action: "补"})
			continue
		case e.Lyrics == choice.Lyrics:
			if gainsWordTiming(e, choice) {
				out = append(out, songEvalLine{key: keys[i], action: "补逐字"})
			}
			continue
		}
		var cur *scoredLyricCandidateResult
		for j := range scored {
			if scored[j].Source == e.LyricsSource && scored[j].Lyrics == e.Lyrics {
				cur = &scored[j]
				break
			}
		}
		before := fmt.Sprintf("%s 这一轮没找到 %s", e.LyricsSource, songEvalKind(e.Lyrics, e.LyricsYRC))
		if cur != nil {
			before = fmt.Sprintf("%s %d 分 %s", e.LyricsSource, cur.Score, songEvalKind(e.Lyrics, e.LyricsYRC))
		}
		contradicted := rescoreCurrentContradicted(e.Lyrics, scored, choice)
		why := ""
		switch {
		case own[i] != nil && (own[i].manual || own[i].pinned):
			why = songKeepOwn
		case own[i] != nil && own[i].native:
			why = songKeepNative
		case !contradicted && !rescoreDecidable(scored, e.LyricsSource, false):
			why = songKeepUndecidable
		case rescoreKeepsLyrics(e, scored, choice, false, contradicted):
			why = shareEvalKeepWhy(e, scored, choice)
		case !lyricsAreCreditsOnly(e.Lyrics) && isTimedLRC(e.Lyrics) && !isTimedLRC(choice.Lyrics):
			why = songKeepTimed
		}
		action := "换"
		if why != "" {
			action = "留"
		}
		out = append(out, songEvalLine{key: keys[i], action: action, before: before, why: why, found: cur != nil, contradicted: contradicted})
	}
	return out
}

// shareEvalKeepWhy:rescoreKeepsLyrics 判留时是它里面的哪一条,顺序跟它一致。
func shareEvalKeepWhy(e enrichEntry, scored []scoredLyricCandidateResult, choice *scoredLyricCandidateResult) string {
	switch {
	case rescoreKeepsCurrent(e, scored, choice):
		return songKeepUnscored
	case rescoreWouldLoseWordTiming(e, scored, choice):
		return songKeepWords
	}
	return songKeepShown
}

// shareEvalRound:正式空跑一组这一轮的检索:搜的名字、时长和打过分的全部候选。存进 -share-eval-candidates 的文件,改了判据
// 不联网重算。
type shareEvalRound struct {
	Key      string                       `json:"key"`
	Artist   string                       `json:"artist"`
	Title    string                       `json:"title"`
	Album    string                       `json:"album"`
	Duration float64                      `json:"duration"`
	Scored   []scoredLyricCandidateResult `json:"scored"`
}

// shareEvalRep:组里拿去搜的那条写法(现有歌词最好的那份所在的;方案:优先当前歌词选择来自的那条)和组里各写法时长的中位数。
func (b *songEntityBuild) shareEvalRep(ms []int, own []*songPlanLyrics) (int, float64) {
	count := map[string]int{}
	for _, m := range ms {
		if l := own[m]; l != nil {
			count[l.fp]++
		}
	}
	rep := ms[0]
	for _, m := range ms {
		if l := own[m]; l != nil && (own[rep] == nil || songPlanBetter(l, own[rep], count[l.fp], count[own[rep].fp])) {
			rep = m
		}
	}
	var durs []float64
	for _, m := range ms {
		if d := b.variants[m].durationSecs; d > 0 {
			durs = append(durs, d)
		}
	}
	sort.Float64s(durs)
	dur := 0.0
	if len(durs) > 0 {
		dur = durs[len(durs)/2]
	}
	return rep, dur
}
