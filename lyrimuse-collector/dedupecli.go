package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// `collector dedupe-entries` —— 把 enrich 缓存里"其实是同一首歌"的重复条目并成一条。
//
// 为什么需要它:2026-08-16 用户在「歌词管理」里看到成对的重复,实测 108 条里有 14 组 29 条,
// 差异只在半角空格(`Susan 说` vs `Susan说`)或繁简(`千纸鹤` vs `千紙鶴`)。同一次 canonicalEnrichKey
// 的扩展只能保证**以后不再新增**——它是查询期复用,从不改动 map 本身(见那边注释),已经
// 躺在缓存里的这 29 条一条都不会消失。
//
// # 三条设计约束,每条都对应一个真实踩过的坑
//
//  1. **落盘沿用胜者的原始 key**,不用分组用的宽松键。
//     宽松键长 `陶喆|susan说|太平盛世` 这样 —— 小写、没空格、强制简体,没有任何一个平台
//     这么写,拿它当 key 就等于把「歌词管理」列表里的歌名改成一个谁都不认识的串
//     (缓存条目里没有独立的 title/artist/album 字段,列表显示的就是 key 拆出来的三段)。
//
//  2. **dry-run 跑的是同一条代码路径**,只是在真正落盘/删文件之前停手。
//     另写一份"预演版"必然会跟真实执行分叉 —— 你验收的是 A 实现、真正跑的是 B 实现,
//     而这个函数要做的恰恰是不可逆的删除。所以 planDedupe 算出完整计划,dry-run 打印它、
//     apply 执行它,中间没有第二套判断。
//
//  3. **删文件前先核对内容**。合并会删掉落败条目的 .lrc/.yrc 等导出文件(不删的话,下次
//     启动 importLyricsFromFiles 会把落败正文原样读回来,重新长出那条重复 —— 这是
//     enrichkey.go:174-180 记着的既有坑)。但 lyrics/ 是被这个项目当作歌词权威源的目录,
//     所以删之前逐个确认"这个文件确实属于落败的那个 key",不按模式批量删。
type dedupePlan struct {
	groups []dedupeGroup
	// 落败条目在 lyrics/ 下实际存在的导出文件(绝对路径),已按"确实属于落败 key"核对过。
	staleFiles []string
}

type dedupeGroup struct {
	loose string // 分组用的宽松键,只出现在日志里
	// winner 是最终**落盘并显示**的那个 key,按"哪个写法最适合给用户看"选。
	// source 是**内容**取自哪一条,按歌词质量选。两者刻意分开 —— 见 pickDisplayKey。
	winner string
	source string
	losers []string // 会被移除的 key(不含 winner)
}

// planDedupe 只读 enrichCache,算出"哪些条目要并成哪一条"。不改任何状态。
//
// ⚠️ 调用方必须已经持有 enrichMu。
func planDedupe(cache map[string]enrichEntry) dedupePlan {
	byLoose := map[string][]string{}
	for k := range cache {
		loose := loosenEnrichKey(k)
		byLoose[loose] = append(byLoose[loose], k)
	}

	looseKeys := make([]string, 0, len(byLoose))
	for loose, keys := range byLoose {
		if len(keys) > 1 {
			looseKeys = append(looseKeys, loose)
		}
	}
	// 排序纯粹为了输出稳定:map 遍历随机,不排的话同一份数据两次 dry-run 打出来的顺序不同,
	// 人工核对时会以为数据变了。
	sort.Strings(looseKeys)

	plan := dedupePlan{}
	for _, loose := range looseKeys {
		keys := byLoose[loose]
		sort.Strings(keys) // 同上,且让胜者选择在并列时也是确定的
		// 质量胜者:歌词取谁的。跟迁移合并同一套规则,结论一致。
		source := keys[0]
		for _, k := range keys[1:] {
			if betterEnrichEntry(cache[k], cache[source], k, source) {
				source = k
			}
		}
		// 显示胜者:列表里显示哪个写法。跟质量**无关**,所以两者可能不是同一条。
		winner := pickDisplayKey(keys)
		losers := make([]string, 0, len(keys)-1)
		for _, k := range keys {
			if k != winner {
				losers = append(losers, k)
			}
		}
		plan.groups = append(plan.groups, dedupeGroup{loose: loose, winner: winner, source: source, losers: losers})
	}
	return plan
}

// pickDisplayKey 从一组等价 key 里挑出**最适合给用户看**的那个写法。
//
// 为什么不能直接用质量胜者:betterEnrichEntry 按歌词分数/来源挑,跟字形毫无关系。实测这批
// 数据里 14 组有 10 组的质量胜者是**繁体**写法(`小師妹`/`千紙鶴`/`討厭紅樓夢`),而缓存
// 条目没有独立的显示字段、列表显示的就是 key 拆出来的三段 —— 直接用质量胜者当 key,简体
// 用户的歌词管理列表就会变成繁简混杂。而歌词内容跟 key 用谁的写法完全无关,分开选没有代价。
//
// 优先级:
//  1. **离简体更近的**优先(转简之后需要改动的字符更少)。这个库面向简体用户。
//     ⚠️ 不能用"整串是不是纯简体"这个布尔判据 —— 专辑名本身就是繁体的情况很常见
//     (`回到未來`/`神經志 The Journal` 是官方专辑名),那会让整串**恒**判为非简体,
//     歌名那一段的繁简差异就完全失去作用,退化成按字典序挑,实测反而挑中繁体那条。
//  2. 同档时**更长的**优先。等价 key 之间的长度差只可能来自空格,所以"更长"就等于
//     "中英文之间有空格"那个写法(`Susan 说` 胜过 `Susan说`),排版上更好看。
//  3. 再并列取字典序最小,纯粹为了确定性。
func pickDisplayKey(keys []string) string {
	rank := func(k string) (int, int, string) {
		return simplifiedDistance(k), -len([]rune(k)), k
	}
	best := keys[0]
	bs, bl, bk := rank(best)
	for _, k := range keys[1:] {
		s, l, kk := rank(k)
		if s < bs || (s == bs && l < bl) || (s == bs && l == bl && kk < bk) {
			best, bs, bl, bk = k, s, l, kk
		}
	}
	return best
}

// simplifiedDistance 数这个字符串里"转成简体时会被改掉"的字符个数。0 表示已经是纯简体。
//
// 用个数而不是布尔,是为了让"歌名是简体、专辑名固有繁体"这种混合串也能正确比较 ——
// 两条候选的专辑名都是繁体时那部分距离相等,差值就只由歌名/歌手名贡献。
func simplifiedDistance(k string) int {
	a := []rune(k)
	b := []rune(toSimplified(k))
	if len(a) != len(b) {
		// 词组替换改变了长度(OpenCC 词典里存在这种条目)。逐位比不了,给一个必然更大的
		// 值让它排在后面 —— 长度都变了,离简体显然不近。
		return len(a) + len(b)
	}
	n := 0
	for i := range a {
		if a[i] != b[i] {
			n++
		}
	}
	return n
}

// resolveStaleFiles 把每个落败 key 在磁盘上真实存在的导出文件列出来。
//
// ⚠️ 只列**确实存在**的,而且只列 enrichExportedFileNames 给出的那 8 个候选名 —— 不做任何
// 模式匹配/前缀匹配。胜者的文件名绝不会出现在这里:enrichExportedFileNames 是按 key 逐字节
// 算出来的,而胜者和落败者的 key 不同(它们的差异正是空格/大小写/字形,而 sanitizeLyricsFilename
// 只替换 `|` 和几个非法字符,不折叠空格也不折叠字形)。这里仍然显式再核一遍,不靠推理。
func resolveStaleFiles(plan dedupePlan) []string {
	if lyricsDir == "" {
		return nil
	}
	// 这些文件属于"内容和显示是同一条"的胜者,内容已经正确,绝不能删。
	winnerFiles := map[string]bool{}
	for _, g := range plan.groups {
		if g.winner != g.source {
			continue
		}
		for _, name := range enrichExportedFileNames(g.winner) {
			winnerFiles[name] = true
		}
	}
	var out []string
	for _, g := range plan.groups {
		stale := append([]string{}, g.losers...)
		if g.winner != g.source {
			// ⚠️ 显示 key 跟内容来源不是同一条时,winner **自己**磁盘上那份文件装的还是它
			// 原来那条(质量较低)的正文。不删的话,下次启动 importLyricsFromFiles 会拿文件
			// 覆盖内存(lyrics/ 是权威源),把刚合并掉的差正文原样读回来 —— 这正是
			// enrichkey.go:174-180 记着的坑。删掉,由随后的 exportLyricsFiles 用新内容重建。
			stale = append(stale, g.winner)
		}
		for _, loser := range stale {
			for _, name := range enrichExportedFileNames(loser) {
				if winnerFiles[name] {
					// 理论上到不了这里。真到了说明两个 key 的文件名撞了,删就等于删胜者的
					// 歌词 —— 宁可留一个孤儿文件,也不能删。
					log.Printf("dedupe: refusing to delete %q — it is also the winner's export file", name)
					continue
				}
				p := filepath.Join(lyricsDir, name)
				if _, err := os.Stat(p); err == nil {
					out = append(out, p)
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

func runDedupeEntries(apply bool) int {
	enrichMu.Lock()
	plan := planDedupe(enrichCache)
	total := len(enrichCache)
	enrichMu.Unlock()

	plan.staleFiles = resolveStaleFiles(plan)

	if len(plan.groups) == 0 {
		fmt.Println("没有发现重复条目。")
		return 0
	}

	removed := 0
	for _, g := range plan.groups {
		removed += len(g.losers)
	}

	mode := "预演(不会改动任何东西)"
	if apply {
		mode = "执行"
	}
	fmt.Printf("== %s ==\n", mode)
	fmt.Printf("缓存条目 %d → %d(合并 %d 组,移除 %d 条)\n\n", total, total-removed, len(plan.groups), removed)
	for _, g := range plan.groups {
		if g.winner == g.source {
			fmt.Printf("  保留  %s\n", g.winner)
		} else {
			fmt.Printf("  保留  %s   (歌词内容取自 %s)\n", g.winner, g.source)
		}
		for _, l := range g.losers {
			fmt.Printf("  移除  %s\n", l)
		}
		fmt.Println()
	}
	fmt.Printf("待删除的导出文件 %d 个:\n", len(plan.staleFiles))
	for _, f := range plan.staleFiles {
		fmt.Printf("  %s\n", strings.TrimPrefix(f, lyricsDir+"/"))
	}

	if !apply {
		fmt.Println("\n这是预演。确认无误后加 -apply 真正执行。")
		fmt.Println("⚠️ 执行前请先备份 ~/.config/lyrimuse/lyrimuse-enrich-cache.json 和 lyrics/ 整个目录 ——")
		fmt.Println("   删除不可逆,而这条路径 2026-08-16 有过把 lyrics/ 删到只剩 25 个文件的事故。")
		return 0
	}

	// 真正执行。顺序刻意是"先删文件、再改缓存、最后落盘":
	// 反过来的话(先落盘再删文件)一旦中途失败,缓存里落败条目已经没了、文件还在,下次启动
	// importLyricsFromFiles 会把它们原样读回来,重新长出这批重复 —— 白做一遍还看不出来。
	// 现在这个顺序的失败态是"文件删了但缓存没改",下次再跑一遍 -apply 即可收敛,而落败条目
	// 的正文本来就跟胜者是同一首歌的另一份解析,不是唯一副本。
	for _, f := range plan.staleFiles {
		if err := os.Remove(f); err != nil && !os.IsNotExist(err) {
			log.Printf("dedupe: failed to remove %q: %v", f, err)
		}
	}

	enrichMu.Lock()
	for _, g := range plan.groups {
		// 先取内容再删,顺序不能反 —— source 有可能正好在 losers 里。
		entry := enrichCache[g.source]
		for _, l := range g.losers {
			delete(enrichCache, l)
		}
		enrichCache[g.winner] = entry
	}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()

	// 重新导出一遍,让磁盘立刻跟合并后的缓存对齐:上面可能删掉了 winner 自己的旧文件
	// (内容来自别处时),不补回来的话这首歌在 lyrics/ 下就缺文件了。常驻 collector 下次
	// 启动也会做这件事,但一个一次性命令不该把磁盘留在中间态等别人来收拾。
	exportLyricsFiles()

	fmt.Printf("\n完成:移除 %d 条重复条目,删除 %d 个导出文件。\n", removed, len(plan.staleFiles))
	return 0
}

// runDedupeEntriesCLI 是 `collector dedupe-entries [-apply]` 的入口。
//
// 跟其它一次性子命令一样走 main() 里 flag.Parse() 之前的提前分支,所以 features /
// enrichCache / lyricsDir 这几个包级变量在这里都还是零值,必须按跟 main() 完全一致的
// 默认路径规则自己加载一遍(searchcli.go 里有同样的说明)。
func runDedupeEntriesCLI(args []string) {
	fs := flag.NewFlagSet("dedupe-entries", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正执行合并;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("dedupe-entries: %v", err)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("dedupe-entries: resolve home dir: %v", err)
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	lyricsDir = features.LyricsDir
	if lyricsDir == "" {
		lyricsDir = filepath.Join(cfgDir, "lyrics")
	}

	// ⚠️ 严格的单实例检查,而且**只对 -apply 生效前必须过**。
	//
	// 常驻 collector 内存里持有一整份 enrichCache,并且会在自己的节奏上整份写回磁盘。
	// 我们在它跑着的时候删掉磁盘上的条目,它下一次保存就会把删掉的原样盖回来 —— 而
	// 导出文件已经被我们删了,于是缓存里有条目、磁盘上没文件,状态错开。2026-08-16 那次
	// 把 enrich 缓存从 204 条磨到 10 条,机制正是"两个实例各写各的"。
	//
	// 不复用 acquireSingleInstanceLock:那个函数在锁文件打不开时 **fail-open**(返回
	// true 让常驻实例照跑)——对常驻服务是对的取舍,对一个会删文件的一次性命令是错的。
	// 这里任何一种"没能确认独占"都当作拒绝。
	if *apply {
		if !ensureExclusiveForDedupe(cfgDir) {
			fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
			fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
			os.Exit(1)
		}
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runDedupeEntries(*apply))
}

// ensureExclusiveForDedupe 跟 acquireSingleInstanceLock 拿同一把锁,但语义相反:
// 任何拿不到/打不开的情况一律返回 false(fail-closed)。理由见调用处。
func ensureExclusiveForDedupe(dir string) bool {
	f, err := os.OpenFile(filepath.Join(dir, "collector.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		log.Printf("dedupe: cannot open lock file: %v", err)
		return false
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return false
	}
	singleInstanceLockFile = f // 挂住防 GC,进程退出时内核自动释放
	return true
}
