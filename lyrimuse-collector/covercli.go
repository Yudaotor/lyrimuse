package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

// `collector recheck-cover` —— 对指定的几条 enrich 缓存记录重新解析一次**封面**。
//
// 为什么需要它:封面一旦解析出来就永久保留,自动路径里只有"这首歌又被播到"时才会经
// backfillPeripheralFields 复查一次(见 coverNeedsAlbumCheck)。发现某首歌封面选错时,
// 除了等它下次被播放没有别的办法 —— 而"等它自己好"对一次已经看见的错误不是个交代。
//
// 三条跟 dedupe-entries 一致的约束:
//
//  1. **dry-run 跑同一条代码路径**,只在落盘前停手:重新解析、按 coverSwapAllowed 判断,
//     然后打印计划。不另写一份"预演版",省掉"验收 A 实现、真跑 B 实现"这种分叉。
//  2. **-apply 必须独占**(fail-closed):常驻 collector 内存里持有一整份 enrichCache 并
//     按自己的节奏整份写回,它跑着的时候我们改磁盘,它下一次保存就原样盖回来。
//     2026-08-16 把缓存从 204 条磨到 10 条,机制正是"两个实例各写各的"。
//  3. **只动封面四件套**(cover_url / cover_source / cover_album / accent_color),
//     歌词、译文、人工修正标记一个字都不碰 —— 那些删了就找不回来。
func runRecheckCoverCLI(args []string) {
	fs := flag.NewFlagSet("recheck-cover", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("recheck-cover: %v", err)
	}
	keys := fs.Args()
	if len(keys) == 0 {
		fmt.Fprintln(os.Stderr, `用法: collector recheck-cover [-apply] "歌手|歌名|专辑" ...`)
		fmt.Fprintln(os.Stderr, `key 就是"歌词管理"列表里那三段(enrich 缓存的 key),原样照抄。`)
		os.Exit(2)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("recheck-cover: resolve home dir: %v", err)
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	// 只读地拿一下功能开关(歌词源勾选会影响这一轮的候选挑选),跟 dedupe-entries 同款。
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	// ⚠️ 刻意**不**调 loadArtistIdentityCache / loadArtistAliasCache:那两份缓存的
	// path 留空就是"只用内存不持久化"(见 musicbrainz.go),否则这个进程会拿一份空 map
	// 把常驻实例攒下来的整份歌手身份缓存盖掉。
	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}
	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runRecheckCover(keys, *apply))
}

// recheckCoverPlan 是一条记录重新解析封面的结果,dry-run 与 -apply 共用。
type recheckCoverPlan struct {
	key                         string
	found                       bool
	oldURL, oldSource, oldAlbum string
	newURL, newSource, newAlbum string
	newAccent                   string
	swap                        bool
	reason                      string
}

func planRecheckCover(key string) recheckCoverPlan {
	p := recheckCoverPlan{key: key}
	// splitEnrichKey(lyricsexport.go)只按前两个 "|" 切,专辑名里带竖线不会打乱切分;
	// 切不出三段时它返回三个空串。
	artist, title, album := splitEnrichKey(key)
	if title == "" {
		p.reason = `key 不是 "歌手|歌名|专辑" 三段`
		return p
	}
	enrichMu.Lock()
	e, exists := enrichCache[key]
	if !exists {
		// 跟 trackEnrichment 一样,退一步找"只差大小写/空格/繁简"的同一首歌。
		if alt, found := canonicalEnrichKey(key); found {
			p.key, e, exists = alt, enrichCache[alt], true
			artist, title, album = splitEnrichKey(alt)
		}
	}
	enrichMu.Unlock()
	if !exists {
		p.reason = "缓存里没有这条记录"
		return p
	}
	p.found = true
	p.oldURL, p.oldSource, p.oldAlbum = e.CoverURL, e.CoverSource, e.CoverAlbum

	duration := e.ResolvedDurationSecs
	if duration <= 0 {
		duration = e.DurationSecs
	}
	// 一次性 CLI 命令,没有可以取消它的交互界面,context.Background() 就够。deviceCoverURL
	// 传空串:这条 CLI 没有实时播放上下文,拿不到"设备现在正在播这首歌"这个前提。
	fresh := resolveTrackEnrichment(context.Background(), artist, title, album, duration, "")
	p.newURL, p.newSource, p.newAlbum, p.newAccent = fresh.CoverURL, fresh.CoverSource, fresh.CoverAlbum, fresh.AccentColor
	p.swap = coverSwapAllowed(e, fresh, album)
	switch {
	case fresh.CoverURL == "":
		p.reason = "这一轮一个源都没给出封面(疑似限流/网络),保持原样"
	case !p.swap:
		p.reason = "coverSwapAllowed 拒绝替换(见那个函数的注释)"
	case fresh.CoverURL == e.CoverURL:
		p.reason = "还是同一张图,只补上 cover_album"
	default:
		p.reason = "换封面"
	}
	return p
}

func runRecheckCover(keys []string, apply bool) int {
	changed, failed := 0, 0
	for _, key := range keys {
		p := planRecheckCover(key)
		fmt.Printf("── %s\n", p.key)
		if !p.found {
			fmt.Printf("   跳过:%s\n", p.reason)
			failed++
			continue
		}
		fmt.Printf("   旧:%-8s %-28s %s\n", p.oldSource, abbrev(p.oldAlbum, 28), abbrev(p.oldURL, 96))
		fmt.Printf("   新:%-8s %-28s %s\n", p.newSource, abbrev(p.newAlbum, 28), abbrev(p.newURL, 96))
		fmt.Printf("   判定:%s\n", p.reason)
		if !p.swap {
			continue
		}
		if !apply {
			changed++
			continue
		}
		enrichMu.Lock()
		e, exists := enrichCache[p.key]
		if !exists {
			// 这期间被"歌词管理"删掉了 —— 不要把它复活回去,跟 backfillPeripheralFields 同款。
			enrichMu.Unlock()
			fmt.Println("   写回时这条已不在缓存里,跳过")
			continue
		}
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = p.newURL, p.newSource, p.newAlbum, p.newAccent
		enrichCache[p.key] = e
		enrichDirty = true
		enrichMu.Unlock()
		changed++
		fmt.Println("   已写入")
	}
	if apply && changed > 0 {
		saveEnrichCache()
	}
	if apply {
		fmt.Printf("\n完成:%d 条改动,%d 条没找到\n", changed, failed)
	} else {
		fmt.Printf("\n预演:%d 条会改动,%d 条没找到(加 -apply 才真写)\n", changed, failed)
	}
	if failed > 0 {
		return 1
	}
	return 0
}

func abbrev(s string, n int) string {
	if s == "" {
		return "—"
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// `collector recheck-instrumental` —— 对指定条目重新解析一次,只把「纯音乐」结论写回。
//
// 为什么单独一条:纯音乐标记一旦缺了,补上它的自动路径是 needsLyricsFirstFill —— 那条
// 的退避是 24 小时起步(见 lyricsFillBaseInterval),而这个标记的用户可见后果是列表里
// 一整批曲目显示「无歌词」而不是「纯音乐」。发现之后等一天不是个交代。
//
// 只写 instrumental 一个字段:这轮如果某个源真给出了歌词,交给正常的补空路径去采纳
// (那条有完整的打分/升级判据),这里不掺和 —— 一条一次性命令不该顺手改歌词。
// 锁与 dry-run 的约束跟 recheck-cover 完全一致,理由见那边。
func runRecheckInstrumentalCLI(args []string) {
	fs := flag.NewFlagSet("recheck-instrumental", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("recheck-instrumental: %v", err)
	}
	keys := fs.Args()
	if len(keys) == 0 {
		fmt.Fprintln(os.Stderr, `用法: collector recheck-instrumental [-apply] "歌手|歌名|专辑" ...`)
		os.Exit(2)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("recheck-instrumental: resolve home dir: %v", err)
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	// 跟 recheck-cover 同款:刻意不读歌手身份/别名缓存,免得拿空 map 盖掉常驻实例攒的那份。
	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}
	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runRecheckInstrumental(keys, *apply))
}

func runRecheckInstrumental(keys []string, apply bool) int {
	changed, failed := 0, 0
	for _, key := range keys {
		artist, title, album := splitEnrichKey(key)
		enrichMu.Lock()
		e, exists := enrichCache[key]
		if !exists {
			if alt, found := canonicalEnrichKey(key); found {
				key, e, exists = alt, enrichCache[alt], true
				artist, title, album = splitEnrichKey(alt)
			}
		}
		enrichMu.Unlock()
		fmt.Printf("── %s\n", key)
		if !exists || title == "" {
			fmt.Println("   跳过:缓存里没有这条记录")
			failed++
			continue
		}
		switch {
		case e.ManualLyrics:
			fmt.Println("   跳过:用户手改过(一切自动路径对它一票否决)")
			continue
		case e.Instrumental:
			fmt.Println("   跳过:已经标着纯音乐了")
			continue
		case e.Lyrics != "":
			fmt.Println("   跳过:这条已经有歌词(有词就不是纯音乐)")
			continue
		}
		duration := e.ResolvedDurationSecs
		if duration <= 0 {
			duration = e.DurationSecs
		}
		_, scored := scoredLyricCandidates(context.Background(), artist, title, album, duration)
		marker := ""
		for _, c := range scored {
			if c.Instrumental {
				marker = c.Source
				break
			}
		}
		if picked := pickLyricCandidate(scored); picked != nil {
			fmt.Printf("   这轮居然搜到歌词了(%s,%d 分)—— 不在这条命令的职责内,交给补空路径\n",
				picked.Source, picked.Score)
			continue
		}
		if marker == "" {
			fmt.Println("   判定:没有任何源说它是纯音乐,保持原样")
			continue
		}
		fmt.Printf("   判定:%s 明确说这是纯音乐\n", marker)
		if !apply {
			changed++
			continue
		}
		enrichMu.Lock()
		cur, still := enrichCache[key]
		if !still {
			enrichMu.Unlock()
			fmt.Println("   写回时这条已不在缓存里,跳过")
			continue
		}
		cur.Instrumental = true
		enrichCache[key] = cur
		enrichDirty = true
		enrichMu.Unlock()
		changed++
		fmt.Println("   已写入")
	}
	if apply && changed > 0 {
		saveEnrichCache()
	}
	verb := "预演:"
	if apply {
		verb = "完成:"
	}
	fmt.Printf("\n%s%d 条标记为纯音乐,%d 条没找到\n", verb, changed, failed)
	if failed > 0 {
		return 1
	}
	return 0
}
