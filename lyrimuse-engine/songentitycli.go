//go:build devtools

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strings"
	"time"
)

// `lyrimuse-engine song-entities`:按本机缓存建一次歌曲实体表,打出诊断报告。只读:缓存按只读方式加载,
// 不写任何文件,常驻引擎开着也能跑。

func init() {
	devSubcommands["song-entities"] = runSongEntitiesCLI
}

func runSongEntitiesCLI(args []string) {
	fs := flag.NewFlagSet("song-entities", flag.ExitOnError)
	limit := fs.Int("limit", 30, "每份清单最多列几条(0 = 全列)")
	entity := fs.String("entity", "", "只列写法键含这段文字的实体:每条写法的字段、实体里的每条边")
	cpuProfile := fs.String("cpuprofile", "", "建表那一段的 CPU 采样写到这个文件")
	memProfile := fs.String("memprofile", "", "建表之后的内存分配采样写到这个文件")
	sample := fs.String("sample", "", "按证据分层抽一份标注集,写到这个目录(放仓库外);文件已经存在时不覆盖")
	stratum := fs.String("stratum", "", "跟 -sample 一起用:只抽这一层补抽的(isrc / share),写到 sample-<层>.jsonl")
	score := fs.String("score", "", "拿标好的标注集(jsonl)对照当前规则算合错率、漏合率")
	dump := fs.String("dump", "", "把每个实体的写法键写到这个文件(一行一个实体),改规则之前存一份给 -diff 用")
	diff := fs.String("diff", "", "拿 -dump 存下的那份对照这一次建表,列出新并的实体和拆开的实体")
	appleNames := fs.String("apple-names", "", "Apple 目录名字补扫结果的文件(缺省是配置目录里常驻引擎写的那份)")
	fetchNames := fs.Bool("fetch-apple-names", false, "建表前先把到期的 Apple 歌曲 id 补扫进 -apple-names 那个文件(联网)")
	neteaseNames := fs.String("netease-names", "", "网易云登记名补扫结果的文件(缺省是配置目录里常驻引擎写的那份)")
	fetchNetease := fs.Bool("fetch-netease-names", false, "建表前先把到期的网易云歌曲 id 补扫进 -netease-names 那个文件(联网)")
	mbRecordings := fs.String("mb-recordings", "", "MusicBrainz 录音补扫结果的文件(缺省是配置目录里常驻引擎写的那份)")
	fetchMB := fs.Bool("fetch-mb-recordings", false, "建表前先把到期的号按 MusicBrainz 补扫进 -mb-recordings 那个文件(联网,每秒一次)")
	sharePlan := fs.String("share-plan", "", "阶段 3 空跑:谁会换词、谁按不变式 6 留着自己那份、哪些单曲偏移会对不上,写到这个文件(只读、不联网)")
	offsetsPath := fs.String("offsets", "", "跟 -share-plan 一起用:App 单曲偏移的 JSON(defaults read me.yudaotor.lyrimuse np:lyricsOffsetsByTrackJSON 的输出)")
	shareEval := fs.String("share-eval", "", "阶段 3 正式空跑:要换词的共享组逐个以整首歌重搜一轮(联网),结果边跑边写到这个文件,不写缓存")
	shareEvalLimit := fs.Int("share-eval-limit", 0, "跟 -share-eval 一起用:只搜前这么多组(0 = 全搜)")
	shareEvalCandidates := fs.String("share-eval-candidates", "", "跟 -share-eval 一起用:每组这一轮的候选追加进这个文件(jsonl);文件里已有的组不再联网,按存下的候选重算")
	checkIncremental := fs.Int("check-incremental", 0, "随机改这么多次,每次比增量重算跟全量建表的实体表(只读)")
	checkSyncStable := fs.Bool("check-sync-stable", false, "全部共享组在内存里模拟一次同步再建表,看分组变不变(只读,不写任何文件)")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("song-entities: %v", err)
	}
	cfgDir := configDir()
	if cfgDir == "" {
		log.Fatalf("song-entities: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	setFeatures(loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json")))
	lyricsPinsPath = filepath.Join(cfgDir, clientName+"-lyrics-pins.json")
	loadArtistIdentityCache(cacheFilePath(clientName + "-artist-identity-cache.json"))
	loadArtistAliasCache(cacheFilePath(clientName + "-artist-alias-cache.json"))
	loadMBPrimaryNameCache(cacheFilePath(clientName + "-artist-primary-cache.json"))
	loadEnrichForMaintenance(cfgDir, false)
	enrichMu.Lock()
	snapshot := make(map[string]enrichEntry, len(enrichCache))
	for k, v := range enrichCache {
		snapshot[k] = v
	}
	enrichMu.Unlock()
	if len(snapshot) == 0 {
		log.Fatalf("song-entities: enrich cache is empty or unreadable")
	}
	if *checkIncremental > 0 || *checkSyncStable {
		src := &songEntitySource{cache: snapshot, pins: lyricsPinnedKeys(),
			splits: readSongEntityUserSplits(filepath.Join(cfgDir, clientName+"-song-entity-user.json")),
			dir:    filepath.Join(cfgDir, clientName+"-decisions"), prepare: songEntityPrepare()}
		if *checkSyncStable {
			runSongEntitySyncCheck(src, os.Stdout)
		} else {
			runSongEntityIncrementalCheck(src, *checkIncremental, os.Stdout)
		}
		return
	}
	if *cpuProfile != "" {
		f, err := os.Create(*cpuProfile)
		if err != nil {
			log.Fatalf("song-entities: %v", err)
		}
		defer f.Close()
		if err := pprof.StartCPUProfile(f); err != nil {
			log.Fatalf("song-entities: %v", err)
		}
		defer pprof.StopCPUProfile()
	}
	namesPath := *appleNames
	if namesPath == "" {
		namesPath = cacheFilePath(clientName + "-apple-catalog-names.json")
	}
	if *fetchNames {
		sweepAppleNames(context.Background(), namesPath, time.Now())
	}
	start := time.Now()
	variants := (&songEntitySource{cache: snapshot, pins: lyricsPinnedKeys()}).variants(songSortedKeys(snapshot))
	if features().SongEntityPhase2 {
		attachAppleNames(variants, readAppleNames(namesPath))
		nePath := *neteaseNames
		if nePath == "" {
			nePath = cacheFilePath(clientName + "-netease-names.json")
		}
		if *fetchNetease {
			sweepNeteaseNames(context.Background(), nePath, time.Now())
		}
		attachNeteaseNames(variants, readNeteaseNames(nePath))
		mbPath := *mbRecordings
		if mbPath == "" {
			mbPath = cacheFilePath(clientName + "-mb-recordings.json")
		}
		if *fetchMB {
			sweepMBRecordings(context.Background(), mbPath, time.Now())
		}
		attachMBRecordings(variants, readMBRecordings(mbPath))
		attachSpotifyLanguages(variants, spotifyLanguagesForVariants(variants))
		attachSpotifyExplicit(variants, spotifyExplicitForVariants(variants))
	}
	read := time.Since(start)
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	splits := readSongEntityUserSplits(filepath.Join(cfgDir, clientName+"-song-entity-user.json"))
	b := buildSongEntities(variants, splits, filepath.Join(cfgDir, clientName+"-decisions"))
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	if *memProfile != "" {
		if f, err := os.Create(*memProfile); err == nil {
			_ = pprof.Lookup("allocs").WriteTo(f, 0)
			f.Close()
		}
	}
	log.Printf("song-entities: %d variants, read %v, built %v, allocated %d MB during build, heap %d MB",
		len(variants), read.Round(time.Millisecond), (time.Since(start) - read).Round(time.Millisecond),
		(after.TotalAlloc-before.TotalAlloc)>>20, after.HeapAlloc>>20)
	if *entity != "" {
		b.writeEntities(os.Stdout, *entity)
		return
	}
	var err error
	switch {
	case *sample != "":
		var n int
		var path string
		if n, path, err = b.writeLabelSample(*sample, *stratum); err == nil {
			log.Printf("song-entities: wrote %d items to %s", n, path)
		}
	case *score != "":
		err = b.writeLabelScore(*score, os.Stdout)
	case *dump != "":
		err = b.writeClusterDump(*dump)
	case *diff != "":
		err = b.writeClusterDiff(*diff, os.Stdout)
	case *sharePlan != "":
		picked := songPlanPicked(snapshot)
		offsets := map[string]int{}
		if *offsetsPath != "" {
			var data []byte
			if data, err = os.ReadFile(*offsetsPath); err == nil {
				err = json.Unmarshal(data, &offsets)
			}
		}
		if err == nil {
			err = b.writeSharePlanFile(*sharePlan, picked, offsets)
		}
	case *shareEval != "":
		// 跟 search-lyrics 加载同一组旁路缓存(searchcli.go runSearchLyricsCLI),名次才跟常驻引擎的自动决策对得上;两边一起改。
		loadAppleCatalogCache(filepath.Join(cfgDir, clientName+"-apple-catalog-cache.json"))
		loadAppleStorefrontArtistCache(cacheFilePath(clientName + "-apple-storefront-artist-cache.json"))
		loadAppleStorefrontTitleCache(cacheFilePath(clientName + "-apple-storefront-title-cache.json"))
		loadQQArtistNameCache(cacheFilePath(clientName + "-qq-artist-name-cache.json"))
		refreshAccentCacheWords()
		var f *os.File
		if f, err = os.Create(*shareEval); err == nil {
			err = b.runShareEvaluation(context.Background(), bufio.NewWriter(f), songPlanPicked(snapshot), *shareEvalLimit, lyricsFillSweepPace(true), *shareEvalCandidates)
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}
	default:
		b.report().writeText(os.Stdout, *limit)
	}
	if err != nil {
		log.Fatalf("song-entities: %v", err)
	}
}

// writeEntities 列出写法键含 needle 的实体:每条写法的字段,实体里的每条边(被否决的标出否决种类)。
func (b *songEntityBuild) writeEntities(w io.Writer, needle string) {
	vetoOf := map[int]string{}
	for i := range b.edges {
		if !b.edgeVeto[i] {
			continue
		}
		for _, v := range b.vetoed {
			if v.edge == b.edges[i] {
				vetoOf[i] = v.reason + " " + b.variants[v.x].key + " × " + b.variants[v.y].key
				break
			}
		}
	}
	for ci, members := range b.clusters {
		hit := false
		for _, m := range members {
			if strings.Contains(b.variants[m].key, needle) {
				hit = true
			}
		}
		if !hit {
			continue
		}
		in := map[int]bool{}
		for _, m := range members {
			in[m] = true
		}
		fmt.Fprintf(w, "== 实体 %d,%d 条写法\n", ci, len(members))
		for _, m := range members {
			v := &b.variants[m]
			var ids []string
			for _, g := range v.ids {
				ids = append(ids, g.ns+":"+g.id+"("+g.level.String()+")")
			}
			v.loadDecisionTitles(b.decisionsDir)
			fmt.Fprintf(w, "  [%d] %s\n      时长 %.3f  歌词时长 %.3f  族 %q  中文名 %v  带尾巴 %v  版本 %v  人声 %d  共享组 %d  歌词 %s  登记 %v  候选歌名 %q\n      id %s\n",
				m, v.key, v.durationSecs, v.resolvedSecs, v.family, v.han, v.tailed, v.versionTags, v.vocalsKind(), b.shareOf[m],
				v.lyricsSource, v.registered, v.winnerTitle, strings.Join(ids, " "))
		}
		for i, e := range b.edges {
			if !in[e.a] && !in[e.b] {
				continue
			}
			mark := ""
			switch {
			case vetoOf[i] != "":
				mark = "否决:" + vetoOf[i]
			case !in[e.a] || !in[e.b]:
				mark = "连到实体外"
			}
			fmt.Fprintf(w, "    边 %-13s [%d]-[%d] %s 计数用=%v 共享=%v %s\n", e.kind, e.a, e.b, e.value, e.countOnly, e.share, mark)
		}
	}
}
