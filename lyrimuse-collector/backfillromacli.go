package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// `collector backfill-roma [-apply] [-limit N]`:给**已经缓存过的**条目补上罗马音。
//
// 为什么需要它:maybeGenerateHelperRoma 只在解析/重评那一刻跑(见它的三个调用点),所以
// 这条特性上线时,存量条目一条都不会被补上 —— 用户看到的是"加了个功能但什么都没变",
// 要等每首歌各自被重新解析一遍才慢慢生效。这跟 regenerate-jyutping 存在的理由一模一样
// (那条是算法/词典改了要重算,这条是功能刚上线要回补),形态也照抄它。
//
// ⚠️ 只补**空的**。已经有 lyrics_roma 的一律不动,不管它来自哪一路(源自带 / 粤拼) ——
// 同 maybeGenerateHelperRoma 的规矩:绝不覆盖已经可用的内容。
//
// ⚠️ 默认只打印计划,-apply 才落盘;-apply 前必须确认独占(常驻 collector 内存里握着整份
// enrichCache,它下一次保存会把我们的修改整份盖回去)。
func runBackfillRomaCLI(args []string) {
	fs := flag.NewFlagSet("backfill-roma", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回;不加就是预演,只打印计划")
	limit := fs.Int("limit", 0, "最多处理多少条(0=不限);先小批量试跑用")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("backfill-roma: %v", err)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("backfill-roma: resolve home dir: %v", err)
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	lyricsDir = features.LyricsDir
	if lyricsDir == "" {
		lyricsDir = filepath.Join(cfgDir, "lyrics")
	}

	// 理由同 regenerate-jyutping:任何一种"没能确认独占"都当作拒绝,不 fail-open。
	if *apply {
		if !ensureExclusiveForDedupe(cfgDir) {
			fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
			fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
			os.Exit(1)
		}
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	// 顺序照抄 regenerate-jyutping:lyrics/ 是歌词家族的权威源,先让磁盘内容覆盖刚从 JSON
	// 读出来的内存态,再在**权威内容**上生成,最后 export 写回去。
	importLyricsFromFiles()
	os.Exit(runBackfillRoma(*apply, *limit))
}

func runBackfillRoma(apply bool, limit int) int {
	// 先在锁内挑出候选(只读),再在锁外逐个起子进程 —— 每条要跑一次 lyrics-romanize,
	// 而整个回补可能是几千条、几分钟量级,不能把 enrichMu 一直攥着不放:常驻 collector
	// 虽然此刻不该在跑(-apply 有独占闸),但预演模式没有那道闸。
	type candidate struct {
		key    string
		lyrics string
	}
	var cands []candidate
	skipped := map[string]int{}

	enrichMu.Lock()
	for k, e := range enrichCache {
		if e.Lyrics == "" {
			skipped["没有歌词"]++
			continue
		}
		if e.LyricsRoma != "" {
			skipped["已有罗马音(源自带/粤拼),不覆盖"]++
			continue
		}
		switch dominantScript(e.Lyrics) {
		case scriptHan, scriptKana, scriptHangul:
		default:
			skipped["不是中日韩文字,无需注音"]++
			continue
		}
		cands = append(cands, candidate{key: k, lyrics: e.Lyrics})
	}
	enrichMu.Unlock()

	sort.Slice(cands, func(i, j int) bool { return cands[i].key < cands[j].key })
	if limit > 0 && len(cands) > limit {
		cands = cands[:limit]
	}

	fmt.Printf("候选(有歌词 + 没罗马音 + 中日韩文字): %d\n", len(cands))
	for _, reason := range []string{"没有歌词", "已有罗马音(源自带/粤拼),不覆盖", "不是中日韩文字,无需注音"} {
		fmt.Printf("  跳过 %-28s : %d\n", reason, skipped[reason])
	}
	if len(cands) == 0 {
		fmt.Println("没有需要处理的条目。")
		return 0
	}
	if !apply {
		fmt.Println()
		fmt.Println("以上是预演(还没有真正调用 lyrics-romanize)。")
		fmt.Println("确认无误后加 -apply 真正生成并写回(需要先停掉常驻 collector);")
		fmt.Println("可以先 -apply -limit 20 小批量试一下效果。")
		return 0
	}

	generated := map[string]string{}
	var empty, failed int
	start := time.Now()
	for i, c := range cands {
		roma, err := onDeviceRomanize(c.lyrics)
		switch {
		case err != nil:
			failed++
			log.Printf("backfill-roma: %s: %v", c.key, err)
		case roma == "":
			// helper 说"没什么可注音的"(整首都是拉丁字母之类)—— 正常结论,不是失败。
			empty++
		default:
			generated[c.key] = roma
		}
		if (i+1)%100 == 0 || i+1 == len(cands) {
			fmt.Printf("  进度 %d/%d  已生成 %d  无产出 %d  失败 %d  用时 %s\n",
				i+1, len(cands), len(generated), empty, failed, time.Since(start).Round(time.Second))
		}
	}

	if len(generated) == 0 {
		fmt.Println("一条都没能生成(helper 是不是没随包打进 Contents/Resources/?)。")
		return 0
	}

	enrichMu.Lock()
	for k, roma := range generated {
		e, ok := enrichCache[k]
		if !ok {
			continue
		}
		// 再判一次空:预演到落盘之间理论上不会有人改,但这条判断本身是这个功能的
		// 核心规矩("绝不覆盖已有罗马音"),值得在真正写的那一刻再确认一次。
		if e.LyricsRoma != "" {
			continue
		}
		e.LyricsRoma = roma
		enrichCache[k] = e
	}
	// ⚠️ **必须置脏**:saveEnrichCache() 开头有一道 `if !enrichDirty { return }`,不置就是
	// 静默不落盘 —— 而 exportLyricsFiles() 照常把文件写出去,于是"文件有、缓存没有",
	// 只有下次启动 importLyricsFromFiles() 把文件读回来才碰巧变正常。2026-09-03 实测踩到
	// (20 条试跑:.roma.lrc 写了 20 个,cache 的 mtime 纹丝不动)。
	enrichDirty = true
	enrichMu.Unlock()

	saveEnrichCache()
	// 缓存改完必须把 lyrics/ 里的 .roma.lrc 一起写出来 —— 那边是权威源,不刷的话下次启动
	// importLyricsFromFiles 会拿旧文件把刚写好的缓存又盖回去。**而"能导出成文件"正是
	// 这条特性存在的主要理由**,漏了这一步等于白做。
	exportLyricsFiles()
	fmt.Printf("已生成 %d 条,并写出 lyrics/ 里对应的 .roma.lrc(无产出 %d,失败 %d)。\n",
		len(generated), empty, failed)
	return 0
}
