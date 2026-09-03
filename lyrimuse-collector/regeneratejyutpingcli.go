package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

// `collector regenerate-jyutping [-apply]`:把**已经缓存过的**粤拼按当前算法+词典
// 重新生成一遍。
//
// 为什么需要它:maybeGenerateJyutpingRoma 只在 LyricsRoma **为空**时才补(那条"绝不
// 覆盖源自带罗马音"的规矩是对的,不该改)。所以粤拼算法或词典一改,存量缓存永远停在
// 旧结果上 —— 2026-08-30 接入词表、2026-08-31 修拉丁/汉字间距,两次都是这样。
//
// 跟 dedupe-entries 同形态:默认只打印计划,-apply 才落盘;-apply 前必须确认独占
// (常驻 collector 内存里握着整份 enrichCache,它下一次保存会把我们的修改整份盖回去)。
//
// ⚠️ 只动**我们自己生成**的那份。判据是"存的这份带数字声调"——collector 生成的粤拼
// 一定带声调(jyut6ping3 的声调是拼写的一部分),而歌词源自带的罗马音在这台机器的真实
// 缓存里是不带声调的(实测 39 条粤语条目里 1 条属于这种,必须原样留着)。判不准时一律
// 跳过,不猜。
func runRegenerateJyutpingCLI(args []string) {
	fs := flag.NewFlagSet("regenerate-jyutping", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("regenerate-jyutping: %v", err)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("regenerate-jyutping: resolve home dir: %v", err)
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	lyricsDir = features.LyricsDir
	if lyricsDir == "" {
		lyricsDir = filepath.Join(cfgDir, "lyrics")
	}

	// 理由同 dedupe-entries(见 ensureExclusiveForDedupe 上方那段注释):任何一种"没能
	// 确认独占"都当作拒绝,不 fail-open。
	if *apply {
		if !ensureExclusiveForDedupe(cfgDir) {
			fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
			fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
			os.Exit(1)
		}
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	// 顺序照抄 main.go:lyrics/ 文件夹是歌词家族的权威源,先让磁盘内容覆盖刚从 JSON
	// 读出来的内存态,再在**权威内容**上重算,最后 export 写回去。跳过这一步的话,会拿
	// 一份可能已经过期的 JSON 去覆盖磁盘上更新的歌词。
	importLyricsFromFiles()
	os.Exit(runRegenerateJyutping(*apply))
}

// jyutpingTonedSyllable:带数字声调的音节。collector 生成的粤拼每个汉字都带声调,
// 源自带的罗马音(实测)不带 —— 这是区分两者唯一可靠且不需要新增字段的信号。
var jyutpingTonedSyllable = regexp.MustCompile(`[a-z]+[1-6]`)

type jyutpingRegenItem struct {
	key      string
	oldLines int
	newLines int
}

// runRegenerateJyutping 算出计划并(在 apply 时)执行。预演和执行跑的是同一条判断
// 路径,只在真正写盘前停手 —— 理由见 dedupecli.go 头部第 2 条。
func runRegenerateJyutping(apply bool) int {
	var (
		plan       []jyutpingRegenItem
		regen      = map[string]string{}
		skipNoTone int
		upToDate   int
		scanned    int
	)

	enrichMu.Lock()
	for k, e := range enrichCache {
		if e.SongLanguage != songLanguageCantonese || e.Lyrics == "" || e.LyricsRoma == "" {
			continue
		}
		scanned++
		if !jyutpingTonedSyllable.MatchString(e.LyricsRoma) {
			skipNoTone++
			continue
		}
		fresh := jyutpingLRC(e.Lyrics)
		if fresh == "" || fresh == e.LyricsRoma {
			upToDate++
			continue
		}
		plan = append(plan, jyutpingRegenItem{
			key:      k,
			oldLines: countLines(e.LyricsRoma),
			newLines: countLines(fresh),
		})
		regen[k] = fresh
	}
	enrichMu.Unlock()

	sort.Slice(plan, func(i, j int) bool { return plan[i].key < plan[j].key })

	fmt.Printf("粤语条目(有歌词+有粤拼): %d\n", scanned)
	fmt.Printf("  已经是当前算法的结果,无需处理 : %d\n", upToDate)
	fmt.Printf("  无声调(源自带罗马音),跳过不动 : %d\n", skipNoTone)
	fmt.Printf("  需要重新生成                  : %d\n", len(plan))
	for _, it := range plan {
		note := ""
		if it.oldLines != it.newLines {
			note = fmt.Sprintf("   [行数 %d → %d,旧粤拼跟当前歌词已经对不上]", it.oldLines, it.newLines)
		}
		fmt.Printf("    - %s%s\n", it.key, note)
	}

	if len(plan) == 0 {
		fmt.Println("没有需要处理的条目。")
		return 0
	}
	if !apply {
		fmt.Println()
		fmt.Println("以上是预演。确认无误后加 -apply 真正写回(需要先停掉常驻 collector)。")
		return 0
	}

	enrichMu.Lock()
	for k, fresh := range regen {
		e, ok := enrichCache[k]
		if !ok {
			continue
		}
		e.LyricsRoma = fresh
		enrichCache[k] = e
	}
	// ⚠️ 2026-09-03 补:这里原来**漏了置脏**,是一个既有 bug。saveEnrichCache() 开头有
	// `if !enrichDirty { return }`,所以 `regenerate-jyutping -apply` 一直是"文件写了、
	// 缓存没写";它之所以看起来一直正常,是因为下次启动 importLyricsFromFiles() 会把
	// lyrics/ 里的 .roma.lrc 读回缓存 —— 侥幸,不是设计。写 backfill-roma 时踩到同一个坑
	// 才发现这边也有。
	enrichDirty = true
	enrichMu.Unlock()

	saveEnrichCache()
	// 缓存改完必须把 lyrics/ 里的 .roma.lrc 一起刷新 —— 那边是权威源,不刷的话下次
	// 启动 importLyricsFromFiles 会拿旧文件把刚写好的缓存又盖回去。
	exportLyricsFiles()
	fmt.Printf("已重新生成 %d 条,并刷新 lyrics/ 里对应的 .roma.lrc。\n", len(regen))
	return 0
}

func countLines(s string) int {
	if s == "" {
		return 0
	}
	n := 1
	for _, r := range s {
		if r == '\n' {
			n++
		}
	}
	return n
}
