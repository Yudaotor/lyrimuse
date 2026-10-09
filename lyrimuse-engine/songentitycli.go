//go:build devtools

package main

import (
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
	if err := fs.Parse(args); err != nil {
		log.Fatalf("song-entities: %v", err)
	}
	cfgDir := configDir()
	if cfgDir == "" {
		log.Fatalf("song-entities: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	setFeatures(loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json")))
	lyricsPinsPath = filepath.Join(cfgDir, clientName+"-lyrics-pins.json")
	loadArtistIdentityCache(filepath.Join(cfgDir, clientName+"-artist-identity-cache.json"))
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
	start := time.Now()
	variants := songVariantsFromCache(snapshot, lyricsPinnedKeys())
	read := time.Since(start)
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	b := buildSongEntities(variants, nil, filepath.Join(cfgDir, clientName+"-decisions"))
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
	b.report().writeText(os.Stdout, *limit)
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
