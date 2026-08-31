package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"
)

// `collector resync-lyrics [-apply] "歌手|歌名|专辑" ...` —— 对指定条目强制重新解析一遍,
// 补上"歌词正文没变、但译文/罗马音其实有新内容"这种 rescoreLyrics(自动路径)不会碰的情况。
//
// 为什么不能直接等自动路径自愈:rescoreLyrics 只在 `picked.Lyrics != e.Lyrics` 时才更新
// LyricsTr/LyricsRoma/LyricsYRC(见 enrich.go 那段注释——避免正文没变时白白重写、白白导出
// 一遍文件)。2026-08-26 真实bug复现(ROSÉ & Bruno Mars《APT.》):amll 候选构造那一步早就
// 在读 amll.tr,但转成最终结果那个 switch 一直没有 case "amll",分数算对了、译文内容却从来
// 没被抄进去。修好那个 switch 之后,这首歌"歌词正文"这次不会再变(上一轮自动 rescore 已经
// 拿到修过间距的版本),但"译文"从空变成有内容——`picked.Lyrics == e.Lyrics` 恒成立,等
// 下次自动 rescore 也不会触发更新,只能靠这条命令主动补一次。
//
// 顺带查了一遍库里全部 4 条 amll 来源:另外 3 条已经有译文,但来源标的是 "machine"(机翻
// 兜底当年凑巧成功、掩盖了 amll 自带译文从没被读到这个事实)。重新解析一次能把这 3 条也换
// 成 amll 自带的译文(社区/官方来源,通常比机翻准),不是必须但值得做。
//
// 三条约束跟 recheck-cover/recheck-instrumental 完全一致:dry-run 默认、-apply 才真写且
// 要求常驻实例已停;只处理指定的 key,不做启动时全量扫;人工修正过的(ManualLyrics)一律
// 跳过。字段写法直接照抄 rescoreLyrics 的那一套(decision/rescore 计数/来源名单都一起补),
// 只是把"要不要更新歌词族字段"这道闸从"正文变了"放宽成"正文/译文/罗马音有任意一个变了"。
func runResyncLyricsCLI(args []string) {
	fs := flag.NewFlagSet("resync-lyrics", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("resync-lyrics: %v", err)
	}
	keys := fs.Args()
	if len(keys) == 0 {
		fmt.Fprintln(os.Stderr, `用法: collector resync-lyrics [-apply] "歌手|歌名|专辑" ...`)
		os.Exit(2)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("resync-lyrics: resolve home dir: %v", err)
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	// 跟 searchcli.go 同一个理由(那边有详细注释):这条 CLI 每次都是新进程,不读这几份
	// 持久化缓存的话,scoredLyricCandidates 内部的 retryArtistIdentities/艺人别名重试/
	// 标题反查轮每次都要现查一遍 MusicBrainz——2026-08-28 实测坐实:这个缺口导致
	// resync-lyrics 对同一批歌手反复触发 12 秒的 MusicBrainz 超时(两次查询、每次 6 秒),
	// 白白拖慢重新匹配,且拿不到已经缓存过的别名结果。
	loadArtistAliasCache(filepath.Join(cfgDir, clientName+"-artist-alias-cache.json"))
	loadMBPrimaryNameCache(filepath.Join(cfgDir, clientName+"-artist-primary-cache.json"))
	loadAppleCatalogCache(filepath.Join(cfgDir, clientName+"-apple-catalog-cache.json"))
	loadAppleStorefrontArtistCache(filepath.Join(cfgDir, clientName+"-apple-storefront-artist-cache.json"))
	loadQQArtistNameCache(filepath.Join(cfgDir, clientName+"-qq-artist-name-cache.json"))

	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runResyncLyrics(keys, *apply))
}

func runResyncLyrics(keys []string, apply bool) int {
	changed, unchanged, failed := 0, 0, 0
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
		if e.ManualLyrics {
			fmt.Println("   跳过:用户手改过(一切自动路径对它一票否决)")
			continue
		}
		duration := e.ResolvedDurationSecs
		if duration <= 0 {
			duration = e.DurationSecs
		}
		// 2026-08-30 真实bug(温岚《夏日の風》,本地标签是繁体"溫嵐 (Landy Wen)"/"溫式效應"):
		// resolveTrackEnrichment(自动路径)和 search-lyrics(searchcli.go)在发起搜索前都会
		// 先转一遍简体——网易云/QQ/酷狗/LRCLIB 的搜索索引是简体中文,繁体原文直接发search
		// 请求经常直接查不到候选(不是匹配质量差,是搜索接口本身没命中)。这条 CLI 一直漏了
		// 这一步,直接拿 splitEnrichKey 出来的原始繁体去查——同一首歌 search-lyrics 稳定能
		// 搜到、resync-lyrics 稳定搜不到,分毫不差地复现了三次,查到就是这个漏转换。
		// 原地覆盖(不新开变量名)跟 resolveTrackEnrichment 头部那段是同一个写法、同一个理由:
		// 下面 buildLyricsDecision 存档也该记这次真正拿去搜索的(简体)那一版,不是原始繁体。
		// enrichCache 的 key(未拆解前的那个字符串)不受影响,依旧是原始繁体,查缓存/写缓存
		// 两头对得上号。
		artist, title, album = toSimplified(artist), toSimplified(title), toSimplified(album)
		_, scored := scoredLyricCandidates(context.Background(), artist, title, album, duration)
		picked := pickLyricCandidatePreferring(scored, e.LyricsSourceChoice)
		// 2026-08-29 实测坐实(陶喆《Airport in 10:30》):这条 CLI 手上就攥着 enrichCache
		// 里的 e,不像 searchcli.go 那样要另开一次文件读来猜"现在有没有歌词" —— 之前这里
		// 图省事硬编码 false,等于永远按"手上有一份好歌词"那套更严格的闸走(rescoreDecidable
		// 见其头注:要求全部启用的源都应答)。这首歌当时 0 条候选、Musixmatch/YTMusic 这类
		// 慢源没能在 20 秒内应答,decidable 恒为 false,resync 死活"跳过",即便新一轮已经
		// 搜到 4 个可用源也写不进去 —— 保护的是一份根本不存在的"旧歌词"。
		decidable := rescoreDecidable(scored, e.LyricsSource, e.Lyrics == "")
		seen := lyricSourcesWithCandidates(scored)
		responded := lyricSourcesResponded(scored)

		if !decidable {
			fmt.Printf("   跳过:当前源 %q 这轮没应答(见 rescoreDecidable)\n", e.LyricsSource)
			failed++
			continue
		}
		if picked == nil {
			fmt.Println("   跳过:这轮没有能用的候选")
			failed++
			continue
		}
		// 跟 rescoreLyrics 的差别就在这一行:那边只看 Lyrics 变没变,这里三项任意一项
		// 变了都算数——修的正是"正文没变、译文/罗马音其实有新内容"这类自动路径漏掉的情况。
		lyricsSame := picked.Lyrics == e.Lyrics
		trSame := picked.LyricsTr == e.LyricsTr
		romaSame := picked.LyricsRoma == e.LyricsRoma
		if lyricsSame && trSame && romaSame {
			fmt.Println("   没变化:重新解析结果跟缓存里一样")
			unchanged++
			continue
		}
		fmt.Printf("   %s(%d) -> %s(%d)  歌词%s 译文%s 罗马音%s\n",
			e.LyricsSource, e.LyricsScore, picked.Source, picked.Score,
			changedMark(!lyricsSame), changedMark(!trSame), changedMark(!romaSame))
		changed++
		if !apply {
			continue
		}
		enrichMu.Lock()
		cur, still := enrichCache[key]
		if !still {
			enrichMu.Unlock()
			fmt.Println("   写回时这条已不在缓存里,跳过")
			continue
		}
		cur.LyricsRescoreCount++
		cur.LyricsRescoreTS = time.Now().Unix()
		if len(seen) > 0 {
			cur.LyricsSourcesSeen = seen
		}
		if len(responded) > 0 {
			cur.LyricsSourcesResponded = responded
		}
		cur.LyricsDecision = buildLyricsDecision(
			lyricsDecisionPathRescore, artist, title, album, duration, scored, picked,
			!lyricsSame || !trSame || !romaSame)
		traceLyricsDecision(key, cur.LyricsDecision)
		cur.LyricsDecisionApplied = cur.LyricsDecision
		cur.Lyrics = picked.Lyrics
		cur.LyricsTr, cur.LyricsRoma, cur.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
		if !trSame {
			// 译文换人了(哪怕正文没变),描述译文的两个字段必须跟着换——不然旧的
			// "machine" 标记会让新换上来的源自带译文被误标成机翻,见 rescoreLyrics 同款注释。
			cur.LyricsTrLang, cur.LyricsTrSource = picked.LyricsTrLang, ""
		}
		cur.LyricsSource = picked.Source
		cur.LyricsScore = picked.Score
		cur.LyricsScoringVersion = lyricsScoringVersion
		cur.ResolvedDurationSecs = duration
		enrichCache[key] = cur
		enrichDirty = true
		enrichMu.Unlock()
		fmt.Println("   已写入")
	}
	if apply && changed > 0 {
		saveEnrichCache()
		exportLyricsFiles()
	}
	verb := "预演"
	if apply {
		verb = "完成"
	}
	fmt.Printf("\n%s:%d 条改动,%d 条没变化,%d 条失败\n", verb, changed, unchanged, failed)
	if failed > 0 {
		return 1
	}
	return 0
}

func changedMark(v bool) string {
	if v {
		return "✓变"
	}
	return "不变"
}
