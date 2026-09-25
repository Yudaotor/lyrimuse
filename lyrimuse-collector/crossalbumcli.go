// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
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
	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		log.Fatalf("cross-album-reuse: collector is running (or the exclusive lock is unavailable); stop it before -apply")
	}
	setFeatures(loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json")))
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
		best := 0
		for i, m := range g.members {
			if m.score > g.members[best].score {
				best = i
			}
		}
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
	fmt.Printf("\n已复用 %d 条;跳过 %d 条(用户手改过内容或手动选过源的一律不动)。\n", n, skipped)
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
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, g := range groups {
		if !g.diverged() {
			continue
		}
		best := 0
		for i, m := range g.members {
			if m.score > g.members[best].score {
				best = i
			}
		}
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
			if dst.ManualLyrics || dst.ManualPickSHA != "" {
				skipped++
				continue
			}
			dst.Lyrics = src.Lyrics
			dst.LyricsYRC = src.LyricsYRC
			dst.LyricsTr = src.LyricsTr
			dst.LyricsTrSource = src.LyricsTrSource
			dst.LyricsTrLang = src.LyricsTrLang
			dst.LyricsRoma = src.LyricsRoma
			dst.LyricsSource = src.LyricsSource
			dst.LyricsScore = src.LyricsScore
			// 当前歌词的出处现在确实是 src 那一轮的决策,整份搬过来再标明复用来源;
			// lyrics_decision(最近一次评估)保持不动 —— 那记的是这条自己评估过什么,
			// 是事实,不该被别人的记录盖掉。
			if src.LyricsDecisionApplied != nil {
				// 同 crossalbum.go:改指纹之前先把明细从旁路文件补回来。
				d := *withDecisionDetails(g.members[best].key, src.LyricsDecisionApplied)
				d.Path = "cross-album-reuse"
				d.ReusedFrom = g.members[best].key
				dst.LyricsDecisionApplied = &d
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
// 组内切分用的是「跟子组内**任一**成员时长差都在容差内」:同一段录音在不同专辑下的读数
// 抖动是零点几秒量级,不会出现链式漂移把两个真版本连起来。真的差到 2 秒以上就会各自成组,
// 而单成员的组没有复用对象,直接丢掉。
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
				// 它们属于 dedupe-entries 的职责,不该由跨专辑复用来动。
				if len(albums) >= 2 {
					artist, title, _ := splitEnrichKey(bucket[0].key)
					out = append(out, crossAlbumGroup{artist: artist, title: title,
						members: append([]crossAlbumMember(nil), bucket...)})
				}
			}
			bucket = nil
		}
		for _, m := range ms {
			if len(bucket) > 0 && math.Abs(m.duration-bucket[len(bucket)-1].duration) > tolerance {
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
