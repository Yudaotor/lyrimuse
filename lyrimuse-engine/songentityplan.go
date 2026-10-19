//go:build devtools

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"
)

// 阶段 3「歌词共享」开启前的空跑(`song-entities -share-plan <文件>`):只读、不联网、不写缓存。按方案 §5.1 算出每首歌该用
// 哪一份歌词、哪些写法会换词、哪些按不变式 6 留着自己那份、哪些单曲偏移会因换词对不上,写成给人看的文本。
//   - 手改或采纳过的(`manual_lyrics` / `manual_pick_sha`)同步到整个实体,只有对方自己的手改、校准挡得住;实体里有两份不同的
//     手改,或者手改跟校准内容不同时,不替用户选,列出来;
//   - 没有手改时按共享组:有校准的跟着校准那份(两份不同的不选),否则在组里现有的几份里挑。这一档是近似:正式重评要以整首歌
//     重搜一轮、按当前打分版本比,这里只按「有逐字 > 有时间轴 > 打分版本新 > 去掉自家源加分的分数高 > 用它的写法多」挑;
//   - 自动换词前按不变式 6 的前四条判覆盖:自己的手改、校准;当前这份是靠在放播放器自家源加分选出来的;有逐字换成没逐字的;
//     有时间轴换成纯文本的。第五条(这一轮比不了的不换)要联网才判得了,不在这里。手改同步只受第一条约束。
// 见 18 章决策 24。

func (l *songPlanLyrics) describe() string {
	kind := "纯文本"
	switch {
	case l.words:
		kind = "逐字"
	case l.timed:
		kind = "逐行"
	}
	score := "分数不知道"
	if l.score >= 0 {
		score = fmt.Sprintf("%d 分@v%d", l.score, l.version)
	}
	return fmt.Sprintf("%s %s %s", l.source, score, kind)
}

type songPlanTally struct {
	entities, groups, byManual, byPinned, byEvaluated              int
	manualConflicts, pinnedConflicts                               int
	changed, filled                                                int
	keptOwn, keptNative, keptWords, keptTimed                      int
	offsetsLost, offsetsBridged                                    int
	changedFromNative, changedToHigherVersion, changedToLowerScore int
}

// writeSharePlan:见文件头。picked 是采纳过歌词的写法键(manual_pick_sha),offsets 是 App 的单曲偏移(「歌手|歌名|歌词指纹」→ 毫秒)。
func (b *songEntityBuild) writeSharePlan(w io.Writer, picked map[string]bool, offsets map[string]int) {
	own := make([]*songPlanLyrics, len(b.variants))
	for i := range b.variants {
		own[i] = b.songPlanLyricsOf(i, picked)
	}
	offsetByFP := map[string]int{}
	for k, ms := range offsets {
		if i := strings.LastIndexByte(k, '|'); i >= 0 && ms != 0 && k[i+1:] != "" {
			offsetByFP[k[i+1:]] = ms
		}
	}
	var t songPlanTally
	var blocks []string
	for _, members := range b.clusters {
		if len(members) < 2 {
			continue
		}
		t.entities++
		var lines []string
		// 手改:整个实体。
		manual := map[string]*songPlanLyrics{}
		pinnedOther := false
		for _, m := range members {
			if l := own[m]; l != nil && l.manual {
				manual[l.fp] = l
			}
		}
		for _, m := range members {
			if l := own[m]; l != nil && l.pinned && len(manual) == 1 && manual[l.fp] == nil {
				pinnedOther = true
			}
		}
		groups := map[int][]int{}
		for _, m := range members {
			groups[b.shareOf[m]] = append(groups[b.shareOf[m]], m)
		}
		roots := make([]int, 0, len(groups))
		for r, ms := range groups {
			roots = append(roots, r)
			if len(ms) >= 2 {
				t.groups++
			}
		}
		sort.Ints(roots)
		apply := func(ms []int, to *songPlanLyrics, byManual bool) {
			for _, m := range ms {
				key := b.variants[m].key
				cur := own[m]
				switch {
				case cur == nil && b.variants[m].instrumental:
					continue
				case cur == nil:
					t.filled++
					lines = append(lines, "    补  "+key)
					continue
				case cur.fp == to.fp:
					continue
				}
				if why := songPlanKeep(cur, to, byManual); why != "" {
					switch why {
					case songKeepOwn:
						t.keptOwn++
					case songKeepNative:
						t.keptNative++
					case songKeepWords:
						t.keptWords++
					default:
						t.keptTimed++
					}
					lines = append(lines, fmt.Sprintf("    留  %s  %s(%s)", key, cur.describe(), why))
					continue
				}
				t.changed++
				if cur.native {
					t.changedFromNative++
				}
				if to.version > cur.version {
					t.changedToHigherVersion++
				} else if to.version == cur.version && to.score >= 0 && cur.score >= 0 && to.score < cur.score {
					t.changedToLowerScore++
				}
				lines = append(lines, fmt.Sprintf("    换  %s  %s  →  %s", key, cur.describe(), to.describe()))
				if ms, ok := offsetByFP[cur.fp]; ok {
					if nms, ok := offsetByFP[to.fp]; ok {
						t.offsetsBridged++
						lines = append(lines, fmt.Sprintf("    偏移 %s  原来 %d 毫秒,换词后读穿接上 %d 毫秒", key, ms, nms))
					} else {
						t.offsetsLost++
						lines = append(lines, fmt.Sprintf("    偏移 %s  原来 %d 毫秒,换词后对不上", key, ms))
					}
				}
			}
		}
		switch {
		case len(manual) >= 2 || pinnedOther:
			t.manualConflicts++
			lines = append(lines, "  两份手改(或手改跟校准不同),不替你选:")
			for _, m := range members {
				if l := own[m]; l != nil && (l.manual || l.pinned) {
					lines = append(lines, fmt.Sprintf("    %s  %s", b.variants[m].key, l.describe()))
				}
			}
		case len(manual) == 1:
			var to *songPlanLyrics
			for _, l := range manual {
				to = l
			}
			before := len(lines)
			apply(members, to, true)
			if len(lines) > before {
				t.byManual++
				lines = append(lines[:before], append([]string{"  整首跟着手改那份:" + to.describe()}, lines[before:]...)...)
			}
		default:
			for _, r := range roots {
				ms := groups[r]
				if len(ms) < 2 {
					continue
				}
				versions := map[string]*songPlanLyrics{}
				count := map[string]int{}
				pinned := map[string]bool{}
				for _, m := range ms {
					l := own[m]
					if l == nil {
						continue
					}
					count[l.fp]++
					if l.pinned {
						pinned[l.fp] = true
					}
					if v, ok := versions[l.fp]; !ok || l.version > v.version || (l.version == v.version && l.score > v.score) {
						versions[l.fp] = l
					}
				}
				if len(versions) == 0 {
					continue
				}
				if len(pinned) >= 2 {
					t.pinnedConflicts++
					lines = append(lines, "  共享组里两份不同的校准,不替你选:")
					for _, m := range ms {
						if l := own[m]; l != nil && l.pinned {
							lines = append(lines, fmt.Sprintf("    %s  %s", b.variants[m].key, l.describe()))
						}
					}
					continue
				}
				var to *songPlanLyrics
				basis := "组里现有最好的一份(近似)"
				for fp := range pinned {
					to, basis = versions[fp], "跟着校准那份"
				}
				if to == nil {
					for fp, l := range versions {
						if to == nil || songPlanBetter(l, to, count[fp], count[to.fp]) {
							to = l
						}
					}
				}
				before := len(lines)
				apply(ms, to, false)
				if len(lines) > before {
					if basis == "跟着校准那份" {
						t.byPinned++
					} else {
						t.byEvaluated++
					}
					head := fmt.Sprintf("  共享组(%d 条):%s,%s", len(ms), basis, to.describe())
					lines = append(lines[:before], append([]string{head}, lines[before:]...)...)
				}
			}
		}
		if len(lines) > 0 {
			blocks = append(blocks, fmt.Sprintf("== %s(%d 条写法)\n%s", b.variants[members[0]].key, len(members), strings.Join(lines, "\n")))
		}
	}
	fmt.Fprintf(w, "阶段 3 空跑(不联网;「组里现有最好的一份」是近似,正式重评要以整首歌重搜一轮)\n")
	fmt.Fprintf(w, "多写法的歌 %d 首,其中两条写法以上的共享组 %d 个\n", t.entities, t.groups)
	fmt.Fprintf(w, "会动的:整首跟着手改 %d 首,共享组跟着校准 %d 个,共享组在现有几份里挑 %d 个;不替你选的:两份手改或手改跟校准不同 %d 首,两份校准 %d 个\n",
		t.byManual, t.byPinned, t.byEvaluated, t.manualConflicts, t.pinnedConflicts)
	fmt.Fprintf(w, "换词的写法 %d 条(原来是自家源加分选的 %d 条,换成打分版本更新的 %d 条,同版本换成分数更低的 %d 条);没词补上的 %d 条\n",
		t.changed, t.changedFromNative, t.changedToHigherVersion, t.changedToLowerScore, t.filled)
	fmt.Fprintf(w, "按不变式 6 留着自己那份的 %d 条:自己的手改或校准 %d、在放播放器自家的词 %d、有逐字 %d、有时间轴 %d\n",
		t.keptOwn+t.keptNative+t.keptWords+t.keptTimed, t.keptOwn, t.keptNative, t.keptWords, t.keptTimed)
	matched := 0
	current := map[string]bool{}
	for _, l := range own {
		if l != nil {
			current[l.fp] = true
		}
	}
	for fp := range offsetByFP {
		if current[fp] {
			matched++
		}
	}
	fmt.Fprintf(w, "单曲偏移 %d 条,指纹对得上某条写法现在的歌词的 %d 条;换词后对不上 %d 条,读穿能接上 %d 条\n\n",
		len(offsetByFP), matched, t.offsetsLost, t.offsetsBridged)
	for _, blk := range blocks {
		fmt.Fprintln(w, blk)
	}
}

// writeSharePlanFile:writeSharePlan 写到 path。
func (b *songEntityBuild) writeSharePlanFile(path string, picked map[string]bool, offsets map[string]int) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	bw := bufio.NewWriter(f)
	b.writeSharePlan(bw, picked, offsets)
	if err := bw.Flush(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func songEvalDescribe(c *scoredLyricCandidateResult) string {
	return fmt.Sprintf("%s %d 分 %s", c.Source, c.Score, songEvalKind(c.Lyrics, c.LyricsYRC))
}

type songEvalTally struct {
	groups, searched, noWinner, changed, notFound, contradicted, filled, gainedWords int
	kept                                                                             map[string]int
	stableChanged                                                                    int
}

func songEvalChanges(lines []songEvalLine) int {
	n := 0
	for _, l := range lines {
		if l.action == "换" || l.action == "补" {
			n++
		}
	}
	return n
}

// readShareEvalRounds:存档里每组的检索,按搜的那条写法的键,同一个键取最后一行;path 为空或文件不存在时为空。
func readShareEvalRounds(path string) (map[string]shareEvalRound, error) {
	out := map[string]shareEvalRound{}
	if path == "" {
		return out, nil
	}
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec := json.NewDecoder(f)
	for {
		var r shareEvalRound
		if err := dec.Decode(&r); err == io.EOF {
			return out, nil
		} else if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		out[r.Key] = r
	}
}

// runShareEvaluation:正式空跑(`song-entities -share-eval <文件>`):shareEvalGroups 挑出的共享组,以整首歌重搜一轮、按当前打分
// 版本比(方案 §5.1 的 evaluated)。这一轮的冠军是整组那一份,去留见 shareEvalPlan;另算一个参照:冠军只比组里多数那份高不到
// lyricsUpgradeMinGain 时,留多数那份要换几条。只读,不写缓存;联网的两组之间隔 pace,每组写完落一次盘,中途停下已经写出的
// 照样能看。archive 非空时每组这一轮的候选追加进这个文件,文件里已有的组(搜的写法和时长都对得上)不再联网。limit 大于 0 时
// 只搜前这么多组。见 18 章决策 25。
func (b *songEntityBuild) runShareEvaluation(ctx context.Context, w *bufio.Writer, picked map[string]bool, limit int, pace time.Duration, archive string) error {
	own := make([]*songPlanLyrics, len(b.variants))
	for i := range b.variants {
		own[i] = b.songPlanLyricsOf(i, picked)
	}
	groups := b.shareEvalGroups(own)
	total := len(groups)
	if limit > 0 && len(groups) > limit {
		groups = groups[:limit]
	}
	saved, err := readShareEvalRounds(archive)
	if err != nil {
		return err
	}
	var save *os.File
	if archive != "" {
		if save, err = os.OpenFile(archive, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600); err != nil {
			return err
		}
		defer save.Close()
	}
	fmt.Fprintf(w, "正式空跑:以整首歌重搜一轮、按打分版本 v%d 比;要搜的共享组 %d 个,这次搜 %d 个,联网的两组之间隔 %v\n\n",
		lyricsScoringVersion, total, len(groups), pace)
	if err := w.Flush(); err != nil {
		return err
	}
	t := songEvalTally{kept: map[string]int{}}
	for _, ms := range groups {
		rep, dur := b.shareEvalRep(ms, own)
		round, ok := saved[b.variants[rep].key]
		if !ok || round.Duration != dur {
			if t.searched > 0 {
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(pace):
				}
			}
			round = b.searchShareGroup(ctx, rep, dur)
			t.searched++
			if save != nil {
				line, err := json.Marshal(round)
				if err != nil {
					return err
				}
				if _, err := save.Write(append(line, '\n')); err != nil {
					return err
				}
			}
		}
		b.evaluateShareGroup(w, ms, own, round, &t)
		if err := w.Flush(); err != nil {
			return err
		}
	}
	fmt.Fprintf(w, "\n小结:搜了 %d 组(联网 %d 组,其余按存档重算),没有可用候选 %d 组;换词 %d 条(现有那份这一轮没找到的 %d 条,"+
		"其中跟这一轮哪份都对不上的 %d 条),没词补上 %d 条,补上逐字 %d 条\n",
		t.groups, t.searched, t.noWinner, t.changed, t.notFound, t.contradicted, t.filled, t.gainedWords)
	keptTotal := 0
	var kept []string
	for _, k := range [][2]string{{songKeepNative, "在放播放器自家的词"}, {songKeepUndecidable, "这一轮比不了"},
		{songKeepUnscored, "没搜到而冠军不比它存的分高"}, {songKeepWords, "有逐字"}, {songKeepShown, "屏上看不出差别"}, {songKeepTimed, "有时间轴"}} {
		keptTotal += t.kept[k[0]]
		kept = append(kept, fmt.Sprintf("%s %d", k[1], t.kept[k[0]]))
	}
	fmt.Fprintf(w, "按不变式 6 留着自己那份的 %d 条:%s\n", keptTotal, strings.Join(kept, "、"))
	fmt.Fprintf(w, "参照:冠军只比多数那份高不到 %d 分时留多数那份,换词和补词合计 %d 条(按冠军是 %d 条)\n",
		lyricsUpgradeMinGain, t.stableChanged, t.changed+t.filled)
	return w.Flush()
}

// searchShareGroup:以 rep 那条写法的名字、时长 dur 重搜一轮。检索的上下文跟 rescoreLyricsWith 同一套;没有在放的播放器,
// 分数里不会有自家源加分。
func (b *songEntityBuild) searchShareGroup(ctx context.Context, rep int, dur float64) shareEvalRound {
	v := &b.variants[rep]
	return searchShareRound(ctx, v.key, v.artist, v.title, v.album, dur).shareEvalRound
}

func (b *songEntityBuild) evaluateShareGroup(w io.Writer, ms []int, own []*songPlanLyrics, round shareEvalRound, t *songEvalTally) {
	t.groups++
	keys := make([]string, len(ms))
	entries := make([]enrichEntry, len(ms))
	groupOwn := make([]*songPlanLyrics, len(ms))
	enrichMu.Lock()
	for i, m := range ms {
		keys[i], entries[i], groupOwn[i] = b.variants[m].key, enrichCache[b.variants[m].key], own[m]
	}
	enrichMu.Unlock()
	scored := round.Scored
	head := fmt.Sprintf("== %s(共享组 %d 条)\n  搜的是 %s|%s|%s,时长 %.1f 秒;", round.Key, len(ms), round.Artist, round.Title, round.Album, round.Duration)
	top := pickLyricCandidatePreferring(scored, "")
	if top == nil {
		t.noWinner++
		fmt.Fprintln(w, head+"这一轮没有可用候选,整组不动")
		return
	}
	fmt.Fprintln(w, head+"这一轮冠军 "+songEvalDescribe(top))
	lines := shareEvalPlan(keys, entries, groupOwn, scored, top, features().LyricsAutoUpgrade)
	for _, l := range lines {
		switch l.action {
		case "补":
			t.filled++
			fmt.Fprintf(w, "    补  %s\n", l.key)
		case "补逐字":
			t.gainedWords++
			fmt.Fprintf(w, "    补逐字  %s\n", l.key)
		case "留":
			t.kept[l.why]++
			fmt.Fprintf(w, "    留  %s  %s(%s)\n", l.key, l.before, l.why)
		default:
			t.changed++
			if !l.found {
				t.notFound++
			}
			mark := ""
			if l.contradicted {
				t.contradicted++
				mark = "(现有那份跟这一轮哪份都对不上)"
			}
			fmt.Fprintf(w, "    换  %s  %s  →  %s%s\n", l.key, l.before, songEvalDescribe(top), mark)
		}
	}
	strict := songEvalChanges(lines)
	votes := map[string]int{}
	var stable *scoredLyricCandidateResult
	for _, e := range entries {
		for j := range scored {
			if scored[j].Source != e.LyricsSource || !e.Lyrics.EqualString(scored[j].Lyrics) {
				continue
			}
			c := &scored[j]
			votes[c.Lyrics]++
			if stable == nil || votes[c.Lyrics] > votes[stable.Lyrics] || (votes[c.Lyrics] == votes[stable.Lyrics] && c.Score > stable.Score) {
				stable = c
			}
			break
		}
	}
	if stable == nil || stable.Lyrics == top.Lyrics || stable.Score < top.Score-lyricsUpgradeMinGain {
		t.stableChanged += strict
		return
	}
	n := songEvalChanges(shareEvalPlan(keys, entries, groupOwn, scored, stable, features().LyricsAutoUpgrade))
	t.stableChanged += n
	fmt.Fprintf(w, "  参照:冠军只比组里多数那份(%s)高 %d 分,留多数那份要动 %d 条(按冠军动 %d 条)\n", songEvalDescribe(stable), top.Score-stable.Score, n, strict)
}
