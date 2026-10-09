//go:build devtools

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

// `lyrimuse-engine resync-lyrics [-apply] "歌手|歌名|专辑" ...` —— 对指定条目强制重新解析一遍,
// 补上"歌词正文没变、但译文/罗马音其实有新内容"这种 rescoreLyrics(自动路径)不会碰的情况。
//
// 为什么不能直接等自动路径自愈:rescoreLyrics 只在 `picked.Lyrics != e.Lyrics` 时才更新
// LyricsTr/LyricsRoma/LyricsYRC(见 enrich.go 那段注释——避免正文没变时白白重写、白白导出
// 一遍文件)。当某个字段的取值逻辑改了、但"歌词正文"本身没变时,`picked.Lyrics == e.Lyrics`
// 恒成立,自动路径永远不会再触发更新(例如 ROSÉ & Bruno Mars《APT.》:某次改动修好了一处
// "分数算对但译文没被抄进最终结果"的问题,这首歌正文不变、译文从空变成有内容,自动路径
// 看不到这个差异),只能靠这条命令主动补一次。
//
// 顺带查了一遍库里全部 4 条 amll 来源:另外 3 条已经有译文,但来源标的是 "machine"(机翻
// 兜底当年凑巧成功、掩盖了 amll 自带译文从没被读到这个事实)。重新解析一次能把这 3 条也换
// 成 amll 自带的译文(社区/官方来源,通常比机翻准),不是必须但值得做。
//
// 三条约束跟 recheck-cover/recheck-instrumental 完全一致:dry-run 默认、-apply 才真写且
// 要求常驻实例已停;只处理指定的 key,不做启动时全量扫;人工修正过的(ManualLyrics)一律
// 跳过。字段写法跟 rescoreLyrics 同一套(decision/rescore 计数/来源名单都一起补,语种、台语 / 粤语的
// 罗马音规则、锁外先算好的罗马音兜底也照做),只是把"要不要更新歌词族字段"这道闸从"正文变了"放宽成
// "正文/译文/罗马音有任意一个变了,或者逐字的句子变了(多出、少了、文字不同)",见 planResync。
// 刻意**不**做跨专辑对齐(adoptCrossAlbumSiblingLyrics):这条命令就是要把指定的这条按这一轮重新解析,
// 对齐回兄弟那份等于白跑。
func runResyncLyricsCLI(args []string) {
	fs := flag.NewFlagSet("resync-lyrics", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("resync-lyrics: %v", err)
	}
	keys := fs.Args()
	if len(keys) == 0 {
		fmt.Fprintln(os.Stderr, `用法: lyrimuse-engine resync-lyrics [-apply] "歌手|歌名|专辑" ...`)
		os.Exit(2)
	}

	if configDir() == "" {
		log.Fatalf("resync-lyrics: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfgDir := configDir()
	setFeatures(loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json")))
	// 跟 searchcli.go 同一个理由(那边有详细注释):这条 CLI 每次都是新进程,不读这几份
	// 持久化缓存的话,scoredLyricCandidates 内部的 retryArtistIdentities/艺人别名重试/
	// 标题反查轮每次都要现查一遍 MusicBrainz,对同一批歌手反复触发 12 秒的 MusicBrainz
	// 超时(两次查询、每次 6 秒),白白拖慢重新匹配,且拿不到已经缓存过的别名结果。
	loadArtistAliasCache(filepath.Join(cfgDir, clientName+"-artist-alias-cache.json"))
	loadMBPrimaryNameCache(filepath.Join(cfgDir, clientName+"-artist-primary-cache.json"))
	loadAppleCatalogCache(filepath.Join(cfgDir, clientName+"-apple-catalog-cache.json"))
	loadAppleStorefrontArtistCache(filepath.Join(cfgDir, clientName+"-apple-storefront-artist-cache.json"))
	loadQQArtistNameCache(filepath.Join(cfgDir, clientName+"-qq-artist-name-cache.json"))

	if *apply && !ensureExclusiveForMaintenance(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:引擎正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}

	loadEnrichForMaintenance(cfgDir, *apply)
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
		// resolveTrackEnrichment(自动路径)和 search-lyrics(searchcli.go)在发起搜索前都会
		// 先转一遍简体——网易云/QQ/酷狗/LRCLIB 的搜索索引是简体中文,繁体原文直接发search
		// 请求经常查不到候选(不是匹配质量差,是搜索接口本身没命中,如本地标签是繁体
		// "溫嵐 (Landy Wen)"/"溫式效應"这类)。这条 CLI 同样要走这一步,不能直接拿
		// splitEnrichKey 出来的原始繁体去查。
		// 原地覆盖(不新开变量名)跟 resolveTrackEnrichment 头部那段是同一个写法、同一个理由:
		// 下面 buildLyricsDecision 存档也该记这次真正拿去搜索的(简体)那一版,不是原始繁体。
		// enrichCache 的 key(未拆解前的那个字符串)不受影响,依旧是原始繁体,查缓存/写缓存
		// 两头对得上号。
		queryCtx := withLearnedAliasSelf(withSearchQueryOriginal(context.Background(), artist, title, album), key)
		artist, title, album = searchQueryFields(artist, title, album)
		_, scored := scoredLyricCandidates(queryCtx, artist, title, album, duration)
		picked := pickLyricCandidatePreferring(scored, e.LyricsSourceChoice)
		// 这条 CLI 手上就攥着 enrichCache 里的 e,按它有没有词传 —— 如果这里图省事硬编码 false,等于永远按"手上有一份好歌词"
		// 那套更严格的闸走(rescoreDecidable 见其头注:要求全部启用的源都应答)。0 条候选、
		// 慢源(Musixmatch/YTMusic 这类)没能在 20 秒内应答时 decidable 恒为 false,即便
		// 新一轮已经搜到可用源也会被当成"跳过"——保护的是一份根本不存在的"旧歌词"
		// (如陶喆《Airport in 10:30》这类曾撞上这个坑的例子)。
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
		plan := planResync(e, picked)
		if !plan.changed() {
			fmt.Println("   没变化:重新解析结果跟缓存里一样")
			unchanged++
			continue
		}
		fmt.Printf("   %s(%d) -> %s(%d)  歌词%s 译文%s 罗马音%s 逐字%s\n",
			e.LyricsSource, e.LyricsScore, picked.Source, picked.Score,
			changedMark(!plan.lyricsSame), changedMark(!plan.trSame), changedMark(!plan.romaSame), changedMark(!plan.yrcSame))
		changed++
		if !apply {
			continue
		}
		// 罗马音兜底在上锁之前算好(可能起 lyrics-romanize 子进程),同 rescoreLyrics。
		songLanguage := entrySongLanguage(picked.Lyrics, scored)
		var preparedRoma string
		if !plan.lyricsSame && picked.LyricsRoma == "" {
			preparedRoma = generatedRomaFor(picked.Lyrics, "", songLanguage)
		}
		enrichMu.Lock()
		cur, still := enrichCache[key]
		if !still {
			enrichMu.Unlock()
			fmt.Println("   写回时这条已不在缓存里,跳过")
			continue
		}
		// 跟 rescoreLyrics 同一份口径:计数按打分版本归零(见 enrichEntry.LyricsRescoreVersion)。
		// 这条 CLI 不过 needsLyricsRescore 那道上限闸,所以它推进的次数此前可以超过 3
		// (本机有 2 条计到 4);按版本计之后这几次只影响本版剩余的自动尝试次数。
		if cur.lyricsRescoreScoring() != currentLyricsScoring {
			cur.LyricsRescoreCount = 0
			cur.stampLyricsRescore()
		}
		cur.LyricsRescoreCount++
		cur.LyricsRescoreTS = time.Now().Unix()
		if len(seen) > 0 {
			cur.LyricsSourcesSeen = seen
		}
		if len(responded) > 0 {
			cur.LyricsSourcesResponded = responded
		}
		if sw := songwritersFromScored(scored); len(sw) > 0 {
			cur.LyricsSongwriters = sw
		}
		cur.ISRCs = mergeRecordingISRCs(cur.ISRCs, recordingISRCsFromScored("", scored, duration))
		cur.LyricsDecision = buildLyricsDecision(
			lyricsDecisionPathRescore, artist, title, album, duration, scored, picked, plan.changed())
		traceLyricsDecision(key, cur.LyricsDecision)
		cur.LyricsDecisionApplied = cur.LyricsDecision
		cur = applyResync(cur, picked, plan, songLanguage, preparedRoma)
		refreshSpeakers(&cur, scored)
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

// resyncPlan 是 resync-lyrics 对一条的比较结论。
//
// 候选里的罗马音、译文只来自歌词源,缓存里却可能是本地生成的(helper / 粤拼的罗马音,机翻的
// 译文)。正文没变、源没给这两样时,本地那份仍然对得上:不算「变了」,也不清掉(keepLocalRoma / keepMachineTr)。
// 原来逐字比,这类条目每次都被报成改动,-apply 之后罗马音和机翻就没了。逐字同理:正文没变、这一轮的冠军没带
// 逐字时留着缓存里那份(keepYRC)。
type resyncPlan struct {
	lyricsSame, trSame, romaSame, yrcSame bool
	keepMachineTr, keepLocalRoma, keepYRC bool
}

func (p resyncPlan) changed() bool {
	return !p.lyricsSame || !p.trSame || !p.romaSame || !p.yrcSame
}

func planResync(e enrichEntry, picked *scoredLyricCandidateResult) resyncPlan {
	p := resyncPlan{lyricsSame: picked.Lyrics == e.Lyrics}
	p.keepLocalRoma = p.lyricsSame && picked.LyricsRoma == "" && e.LyricsRoma != ""
	p.keepMachineTr = p.lyricsSame && picked.LyricsTr == "" && e.LyricsTr != "" && e.LyricsTrSource == lyricsTrSourceMachine
	p.keepYRC = p.lyricsSame && picked.LyricsYRC == "" && e.LyricsYRC != ""
	p.trSame = picked.LyricsTr == e.LyricsTr || p.keepMachineTr
	p.romaSame = picked.LyricsRoma == e.LyricsRoma || p.keepLocalRoma
	p.yrcSame = p.keepYRC || sameYRCLines(e.LyricsYRC, picked.LyricsYRC)
	return p
}

// sameYRCLines:两份逐字的句子一样(行数相同、逐行文字归一后相同)。只比句子不比字节:缓存里那份做过
// 空白 / 残缺词条的迁移,跟新取回来的原始写法逐字节比会恒报改动。
func sameYRCLines(a, b string) bool {
	ha, hb := yrcLineHeads(a), yrcLineHeads(b)
	if len(ha) != len(hb) {
		return false
	}
	for i := range ha {
		if normTimelineText(ha[i].text) != normTimelineText(hb[i].text) {
			return false
		}
	}
	return true
}

// applyResync 把冠军写进这一条,口径同 rescoreLyrics 换词那一支。preparedRoma 是锁外按 generatedRomaFor 算好的
// 罗马音兜底(正文没换时为空,只补粤拼)。
func applyResync(cur enrichEntry, picked *scoredLyricCandidateResult, p resyncPlan, songLanguage, preparedRoma string) enrichEntry {
	cur.Lyrics = picked.Lyrics
	if !p.keepMachineTr {
		cur.LyricsTr = picked.LyricsTr
	}
	if !p.keepLocalRoma {
		cur.LyricsRoma = picked.LyricsRoma
	}
	if !p.keepYRC {
		cur.LyricsYRC = picked.LyricsYRC
		cur.LyricsBG, cur.LyricsBGChecked = picked.LyricsBG, lyricsBGParserVersion
	}
	if !p.trSame {
		// 译文换人了(哪怕正文没变),描述译文的两个字段必须跟着换——不然旧的
		// "machine" 标记会让新换上来的源自带译文被误标成机翻,见 rescoreLyrics 同款注释。
		cur.LyricsTrLang, cur.LyricsTrSource = picked.LyricsTrLang, ""
	}
	cur.SongLanguage = songLanguage
	cur.dropHokkienRoma()
	cur.dropUnusableCantoneseRoma()
	cur.applyPregeneratedRoma(preparedRoma)
	cur.LyricsSource = picked.Source
	cur.LyricsScore = picked.Score
	cur.stampLyricsScoring()
	return cur
}

func changedMark(v bool) string {
	if v {
		return "✓变"
	}
	return "不变"
}

func init() {
	// resync-lyrics [-apply] "歌手|歌名|专辑" ...:对指定条目强制重新解析,补上正文没变、译文 / 罗马音有新内容的情况。
	devSubcommands["resync-lyrics"] = runResyncLyricsCLI
}
