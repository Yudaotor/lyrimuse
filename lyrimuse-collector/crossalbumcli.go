//go:build devtools

package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"path/filepath"
	"sort"
	"strings"
)

// `collector cross-album-reuse`:列出「同一首歌落在多个专辑下、各自独立选了源、结果拿到
// 两份不一样的歌词」的条目组,并可把组内评分最高那条的歌词复用给其余条目。
//
// 问题本身、判据为什么用时长、以及 2 秒这个阈值的实测依据,都在 crossalbum.go 的头注里。
// 这里只讲这条命令自己的事:**默认预演**,`-apply` 才真改,且要求常驻 collector 已停。
//
// 它跟生产路径上的 adoptCrossAlbumSiblingLyrics 是同一条规则的两半:那边管**增量**
// (新写入的条目对齐到更好的兄弟,单向),这边管**存量**(全库扫一遍,把已经长出来的分歧
// 对齐掉)。分工的理由见 crossalbum.go 里那条「只做单向」的注释。

// crossAlbumMember 是一个候选组里的一条缓存条目。
type crossAlbumMember struct {
	key      string
	album    string
	duration float64
	source   string
	score    int
	version  int // LyricsScoringVersion:分数只在同一版本之间比
	lines    int
	lyrics   string
}

// crossAlbumGroup 是同一个 `artist|title` 下、时长互相兼容的一组条目。
type crossAlbumGroup struct {
	artist  string
	title   string
	members []crossAlbumMember
}

// diverged 报告这一组是不是真的有分歧 —— 歌词正文不完全相同。
//
// 只比正文不比来源:同一份词被两个源各自收录、正文逐字一致时,复用与否对用户没有区别,
// 列出来只会淹没真正要看的那些。
func (g crossAlbumGroup) diverged() bool {
	if len(g.members) < 2 {
		return false
	}
	first := g.members[0].lyrics
	for _, m := range g.members[1:] {
		if m.lyrics != first {
			return true
		}
	}
	return false
}

// runCrossAlbumReuseCLI 是 `collector cross-album-reuse` 的入口。
//
// 跟其它一次性子命令一样走 main() 里 flag.Parse() 之前的提前分支,包级变量都还是零值,
// 所以配置目录要自己按跟 main() 一致的规则解析一遍。
//
// 不加单实例锁:全程只读。用的是 loadEnrichCacheReadOnly —— 它在解析失败时**不会**把原
// 文件改名成 .corrupt(那是常驻进程该做的事),读不出来就当没有,绝不动用户的缓存文件。
func runCrossAlbumReuseCLI(args []string) {
	fs := flag.NewFlagSet("cross-album-reuse", flag.ExitOnError)
	tolerance := fs.Float64("tolerance", crossAlbumReuseToleranceSecs,
		"判定「同一段录音」的时长差上限(秒)")
	all := fs.Bool("all", false, "连歌词完全相同的组也列出来(默认只列有分歧的)")
	apply := fs.Bool("apply", false, "真正把组内评分最高那条的歌词复用给同组其余条目;不加就是预演")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("cross-album-reuse: %v", err)
	}
	if configDir() == "" {
		log.Fatalf("cross-album-reuse: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfgDir := configDir()

	// -apply 会写缓存和 lyrics/ 下的导出文件,必须独占。常驻 collector 内存里持有一整份
	// enrichCache 并按自己的节奏整份写回 —— 它跑着的时候我们改磁盘,它下一次保存就把改动
	// 原样盖回去,而导出文件已经按新内容写过了,状态就此错开。
	//
	// 不复用 acquireSingleInstanceLock:那个在锁文件打不开时 fail-open(让常驻实例照跑),
	// 对常驻服务是对的取舍,对一个会改数据的一次性命令是错的。
	if *apply && !ensureExclusiveForMaintenance(cfgDir) {
		log.Fatalf("cross-album-reuse: collector is running (or the exclusive lock is unavailable); stop it before -apply")
	}
	setFeatures(loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json")))
	// 「已校准时间轴」的记录(菜单栏按过提前 / 推后的那几首):校准偏移按正文指纹记,换了正文偏移就当场失效。
	// rescore、全量扫库都把它当一票否决,这条命令同样要认。
	lyricsPinsPath = filepath.Join(cfgDir, clientName+"-lyrics-pins.json")
	loadEnrichForMaintenance(cfgDir, *apply)
	enrichMu.Lock()
	snapshot := make(map[string]enrichEntry, len(enrichCache))
	for k, v := range enrichCache {
		snapshot[k] = v
	}
	enrichMu.Unlock()
	if len(snapshot) == 0 {
		log.Fatalf("cross-album-reuse: enrich cache is empty or unreadable")
	}

	groups := groupCrossAlbumCandidates(snapshot, *tolerance)
	diverged := 0
	for _, g := range groups {
		if g.diverged() {
			diverged++
		}
	}

	fmt.Printf("缓存 %d 条 · 同 artist|title 落在多专辑且时长差 ≤%.1fs 的组 %d 个 · 其中歌词有分歧 %d 个\n\n",
		len(snapshot), *tolerance, len(groups), diverged)
	for _, g := range groups {
		if !g.diverged() && !*all {
			continue
		}
		mark := "  "
		if g.diverged() {
			mark = "⚠️"
		}
		fmt.Printf("%s %s | %s\n", mark, g.artist, g.title)
		best := g.bestMember()
		for i, m := range g.members {
			keep := " "
			if i == best && g.diverged() {
				keep = "★"
			}
			fmt.Printf("   %s %-34s %7.2fs  %-11s score=%-5d %d 行\n",
				keep, truncate(m.album, 34), m.duration, m.source, m.score, m.lines)
		}
		fmt.Println()
	}
	if diverged == 0 {
		return
	}
	fmt.Printf("★ = 组内评分最高的那条,复用时以它为准。\n")
	if !*apply {
		fmt.Printf("\n这是预演,没有改任何数据。加 -apply 才真的写(需要先停掉常驻 collector)。\n")
		return
	}
	n, skipped := applyCrossAlbumReuse(groups)
	saveEnrichCache()
	exportLyricsFiles()
	fmt.Printf("\n已复用 %d 条;跳过 %d 条(用户手改过内容、手动选过源或校准过时间轴的一律不动;组内最高分打平的整组不动)。\n", n, skipped)
}

// bestMember 组里歌词要复用给其余成员的那一条的下标:打分版本最新的那几条里评分最高的。旧版本的分数不在
// 一把尺子上(同 crossAlbumSiblingLyrics),不跟新版本的比。预演报告和 -apply 共用,两边结论一致。
func (g crossAlbumGroup) bestMember() int {
	best := 0
	for i, m := range g.members {
		b := g.members[best]
		if m.version > b.version || (m.version == b.version && m.score > b.score) {
			best = i
		}
	}
	return best
}

// tiedBest:组内最高分打平(同一打分版本、同分)而正文不同。这种组里谁是「对的那份」没有依据,增量那一侧
// (crossAlbumSiblingLyrics)的规则是同分不动,这里跟它一致、整组不碰。
func (g crossAlbumGroup) tiedBest() bool {
	best := g.members[g.bestMember()]
	for _, m := range g.members {
		if m.key != best.key && m.version == best.version && m.score == best.score && m.lyrics != best.lyrics {
			return true
		}
	}
	return false
}

// applyCrossAlbumReuse 把每组评分最高那条的歌词族字段复用给同组其余条目,返回改了几条、
// 跳过几条。只动内存里的 enrichCache,落盘和导出由调用方负责。
//
// 两类条目一律不碰,它们代表用户已经表过态:
//   - ManualLyrics —— 用户在"歌词管理"里手改过正文,机器不许覆盖(这正是那个标记的本意);
//   - ManualPickSHA —— 用户手动选过源。他选的可能恰好是组内评分较低的那份,
//     而"评分高的赢"在这里会把他的选择静默抹掉。
//
// 复用的是歌词族字段;封面 / 强调色 / 各家链接**不复用** —— 那些是专辑维度的,
// 同一段录音在原版和 Deluxe 下本来就该有各自的封面。
func applyCrossAlbumReuse(groups []crossAlbumGroup) (applied, skipped int) {
	// 校准过的条目先取一份(lyricsPinnedKeys 自己拿锁、读文件,不能放进 enrichMu 里)。
	pinned := lyricsPinnedKeys()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, g := range groups {
		if !g.diverged() {
			continue
		}
		if g.tiedBest() {
			skipped += len(g.members) - 1
			continue
		}
		best := g.bestMember()
		src, ok := enrichCache[g.members[best].key]
		if !ok || strings.TrimSpace(src.Lyrics) == "" {
			continue
		}
		for i, m := range g.members {
			if i == best {
				continue
			}
			dst, ok := enrichCache[m.key]
			if !ok || dst.Lyrics == src.Lyrics {
				continue
			}
			if dst.ManualLyrics || dst.ManualPickSHA != "" || pinned[m.key] {
				skipped++
				continue
			}
			dst.Lyrics = src.Lyrics
			dst.LyricsYRC = src.LyricsYRC
			dst.LyricsBG, dst.LyricsBGChecked = src.LyricsBG, src.LyricsBGChecked
			dst.LyricsSpeakers, dst.LyricsSpeakersChecked = src.LyricsSpeakers, src.LyricsSpeakersChecked
			dst.LyricsTr = src.LyricsTr
			dst.LyricsTrSource = src.LyricsTrSource
			dst.LyricsTrLang = src.LyricsTrLang
			dst.LyricsRoma = src.LyricsRoma
			dst.LyricsSource = src.LyricsSource
			dst.LyricsScore = src.LyricsScore
			dst.LyricsScoringVersion = src.LyricsScoringVersion
			if len(dst.LyricsSongwriters) == 0 {
				dst.LyricsSongwriters = src.LyricsSongwriters
			}
			// 当前歌词的出处现在确实是 src 那一轮的决策,整份搬过来再标明复用来源;
			// lyrics_decision(最近一次评估)保持不动 —— 那记的是这条自己评估过什么,
			// 是事实,不该被别人的记录盖掉。
			if src.LyricsDecisionApplied != nil {
				// 同 crossalbum.go:改指纹之前先把明细从旁路文件补回来。
				d := *withDecisionDetails(g.members[best].key, src.LyricsDecisionApplied)
				d.Path = lyricsDecisionPathCrossAlbumReuse
				d.ReusedFrom = g.members[best].key
				dst.LyricsDecisionApplied = &d
			} else {
				// 源那条没有决策记录:自己那份旧的已经描述不了现在的正文(胜者歌手、时长会被 albumhint 读去当旁证),
				// 换成一份只标明复用来源的最小记录。
				dst.LyricsDecisionApplied = &lyricsDecision{Path: lyricsDecisionPathCrossAlbumReuse, ReusedFrom: g.members[best].key}
			}
			enrichCache[m.key] = dst
			// saveEnrichCache() 在 enrichDirty 为 false 时直接 return —— 漏掉这一行的表现是
			// 命令照常报"已复用 N 条"、磁盘上却什么都没变。守卫测试 TestApplyCLIsMarkEnrichDirty
			// 扫的就是这个形状。
			enrichDirty = true
			applied++
		}
	}
	return applied, skipped
}

// groupCrossAlbumCandidates 把缓存按 `artist|title` 归并,再在组内按时长切出互相兼容的子组。
//
// 组内切分:按时长升序,子组里**每个**成员跟子组第一个(最短的)那条差都在容差内。只跟上一个成员比是链式合并:
// 200.0 / 201.9 / 203.8 秒三条会被连成一组,把 200 秒那份词写到差了 3.8 秒的那条上,比增量那一侧的 2 秒
// 阈值宽得多,两边结论对不上。真的差到容差以上就各自成组,单成员的组没有复用对象,直接丢掉。
func groupCrossAlbumCandidates(cache map[string]enrichEntry, tolerance float64) []crossAlbumGroup {
	byTitle := map[string][]crossAlbumMember{}
	for key, e := range cache {
		if strings.TrimSpace(e.Lyrics) == "" || e.DurationSecs <= 0 {
			continue
		}
		artist, title, album := splitEnrichKey(key)
		if artist == "" || title == "" {
			continue
		}
		id := artist + "|" + title
		byTitle[id] = append(byTitle[id], crossAlbumMember{
			key:      key,
			album:    album,
			duration: e.DurationSecs,
			source:   e.LyricsSource,
			score:    e.LyricsScore,
			version:  e.LyricsScoringVersion,
			lines:    strings.Count(e.Lyrics, "\n") + 1,
			lyrics:   e.Lyrics,
		})
	}

	var out []crossAlbumGroup
	ids := make([]string, 0, len(byTitle))
	for id := range byTitle {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		ms := byTitle[id]
		if len(ms) < 2 {
			continue
		}
		sort.Slice(ms, func(i, j int) bool { return ms[i].duration < ms[j].duration })
		var bucket []crossAlbumMember
		flush := func() {
			if len(bucket) >= 2 {
				albums := map[string]bool{}
				for _, m := range bucket {
					albums[m.album] = true
				}
				// key 是 artist|title|album,而这里按 artist|title 归组,所以组内 album
				// 必然互不相同 —— 这道检查当下恒真。留着是因为归组口径一旦放宽(比如改用
				// canonicalEnrichKey 折大小写),同 album 的两条就可能落进同一组,那时
				// 它们是同一首的重复条目,归 key 迁移(migrateEnrichKeys)合并,不该由跨专辑复用来动。
				if len(albums) >= 2 {
					artist, title, _ := splitEnrichKey(bucket[0].key)
					out = append(out, crossAlbumGroup{artist: artist, title: title,
						members: append([]crossAlbumMember(nil), bucket...)})
				}
			}
			bucket = nil
		}
		for _, m := range ms {
			if len(bucket) > 0 && math.Abs(m.duration-bucket[0].duration) > tolerance {
				flush()
			}
			bucket = append(bucket, m)
		}
		flush()
	}
	return out
}

// truncate 按显示宽度裁短专辑名,让输出的列对得齐。
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func init() {
	// cross-album-reuse [-tolerance N] [-all] [-apply]:同一首歌落在多张专辑下、时长兼容却各自拿到两份不同歌词的,
	// 把组内评分最高那条的歌词复用给其余条目。
	devSubcommands["cross-album-reuse"] = runCrossAlbumReuseCLI
}
