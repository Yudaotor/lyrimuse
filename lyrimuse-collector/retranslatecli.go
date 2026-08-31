package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// `collector retranslate-repeated [-apply]` —— 扫描整份 enrich 缓存,把"歌词有重复行、
// 当前译文疑似被那批重复坑过"的条目重新机翻一遍。
//
// 为什么需要它:2026-08-26 修的那个 bug(machineTranslateLRCWithBase 现在按原文去重再
// 送翻,见 translate.go 头注释)只改了"以后新翻译的行为"——已经缓存的译文不会自己刷新。
// `needsTranslationBackfill` 只要 `lyrics_tr` 非空、语言对得上就直接跳过(见
// `translationUsable`),不会因为内容"看起来不太全"就主动重翻。用户报的 Michael
// Jackson《Beat It》就是这么一条:53 行歌词只翻出 3 行,而且会一直停在那里,直到有人
// 手动清一次——这条命令就是那个"手动清"的批量版本。
//
// 三条约束:
//  1. 只挑**真的会受益**的条目——歌词里"需要翻译的那批行"必须真的有重复文本,否则去重
//     前后送去翻译的内容完全一样,重新翻一遍纯粹白烧一次网络请求/端上翻译调用,不做无
//     谓的事。判据复用 translate.go 里已经在用的 parseLRCLines / isCreditLineWithSpeakers
//     / lineNeedsTranslation,跟真正翻译时用的是同一套过滤逻辑,不会判断不一致。
//  2. 跟 recheck-instrumental 一样尊重人工:`ManualLyrics` 一律跳过——用户手改过的,
//     一切自动路径不碰;当前译文语言跟目标对不上的也跳过,那不是这条命令的职责
//     (`needsTranslationBackfill` 自己的路径会处理)。
//  3. dry-run 默认、-apply 才真写,且要求跟常驻 collector 互斥——理由跟 dedupe-entries /
//     recheck-cover 完全一致:常驻实例整份写回会把这边刚改的东西原样盖掉。
func runRetranslateRepeatedCLI(args []string) {
	fs := flag.NewFlagSet("retranslate-repeated", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("retranslate-repeated: %v", err)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("retranslate-repeated: resolve home dir: %v", err)
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))

	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runRetranslateRepeated(*apply))
}

// hasRepeatedTranslatableLine 判断"需要翻译的那批行"里有没有原文完全相同的两行——只有
// 这种情况才会撞上 2026-08-26 修的那个 bug(逐行独立发请求,同一句话的结果不保证一致)。
func hasRepeatedTranslatableLine(lyrics, target string) bool {
	lines := parseLRCLines(lyrics)
	speakers := lyricSpeakerLabels(lyrics)
	seen := map[string]bool{}
	for _, l := range lines {
		if isCreditLineWithSpeakers(strings.TrimSpace(l.text), speakers) {
			continue
		}
		if !lineNeedsTranslation(l.text, target) {
			continue
		}
		if seen[l.text] {
			return true
		}
		seen[l.text] = true
	}
	return false
}

func runRetranslateRepeated(apply bool) int {
	target := myMemoryLangCode(features.LyricsTranslationLanguage)
	if target == "" {
		fmt.Fprintln(os.Stderr, "没有配置译文目标语言,无事可做")
		return 1
	}

	enrichMu.Lock()
	var keys []string
	for k, e := range enrichCache {
		if e.ManualLyrics || e.Lyrics == "" || e.LyricsTr == "" {
			continue
		}
		if !translationUsable(e, target) {
			continue
		}
		if !hasRepeatedTranslatableLine(e.Lyrics, target) {
			continue
		}
		keys = append(keys, k)
	}
	enrichMu.Unlock()
	sort.Strings(keys) // 输出顺序稳定,方便人工核对

	fmt.Printf("扫描完成:%d 条命中(歌词有重复行、当前译文可能被旧的逐行翻译 bug 坑过)\n\n", len(keys))

	ctx := context.Background()
	changed, unchanged, failed := 0, 0, 0
scan:
	for i, key := range keys {
		enrichMu.Lock()
		e, ok := enrichCache[key]
		lyrics, oldTr := e.Lyrics, e.LyricsTr
		enrichMu.Unlock()
		if !ok {
			continue
		}
		res, err := machineTranslateLRC(ctx, translateClient, lyrics, target)
		oldLines := strings.Count(oldTr, "\n") + 1
		fmt.Printf("── %s\n", key)
		switch {
		case res.quotaReached:
			// 配额是全局的,继续跑剩下的条目只会一次次撞同一堵墙——直接停手,
			// 剩下的等下次配额重置(或端上翻译可用时)再跑。
			fmt.Println("   跳过:MyMemory 当天配额用尽,停止扫描剩余条目")
			failed += len(keys) - i
			break scan
		case err != nil:
			fmt.Printf("   失败:%v\n", err)
			failed++
			continue
		case res.lrc == "":
			fmt.Println("   跳过:这轮没翻出可用结果,保留原有译文")
			unchanged++
			continue
		case res.lrc == oldTr:
			fmt.Println("   没变化:重翻结果跟原来一样")
			unchanged++
			continue
		}
		newLines := strings.Count(res.lrc, "\n") + 1
		fmt.Printf("   %d 行 → %d 行\n", oldLines, newLines)
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
		cur.LyricsTr = res.lrc
		cur.LyricsTrSource = lyricsTrSourceMachine
		cur.LyricsTrLang = target
		cur.TranslationTS = time.Now().Unix()
		cur.TranslationRetryCount = 0
		enrichCache[key] = cur
		enrichDirty = true
		enrichMu.Unlock()
		changed++
		fmt.Println("   已写入")
	}
	if apply && changed > 0 {
		saveEnrichCache()
	}
	verb := "预演"
	if apply {
		verb = "完成"
	}
	fmt.Printf("\n%s:%d 条改动,%d 条没变化,%d 条失败", verb, changed, unchanged, failed)
	if !apply {
		fmt.Print("(加 -apply 才真写)")
	}
	fmt.Println()
	if failed > 0 {
		return 1
	}
	return 0
}
