package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"path/filepath"
	"time"
)

// `collector top-artists -period <7day|1month|12month|overall> -limit N`:拉当前配置
// 账号的 Top 歌手榜,**合并同一个人的多个名字**后输出 JSON 数组 [{name, playCount}]。
//
// 给 Lyrimuse 的 Last.fm 信息页用。App 直连 user.getTopArtists 拿到的是 Last.fm 的
// 原始记录 —— 同一个真人常被拆成多条:中英文艺名("Dean Ting"/"丁世光")、繁简
// ("周杰倫"/"周杰伦")、合唱 credit("Prince & The Revolution"/"Prince")各占一行,
// 排名和次数都被稀释。网页版"历史播放 Top 歌手"早就用 mergeAliasedArtists(名字键 +
// mbid 双信号并查集,见 topartists.go)解决过,这个子命令就是把同一套机器借给 App,
// 不在 Swift 里重抄一遍繁简表/别名表/并查集。
//
// 凭据直接读 config.json(跟常驻进程同一份),不走命令行传参 —— 少一条把 API Key 写进
// 进程参数列表(ps 里可见)的通道。
func runTopArtistsCLI(args []string) {
	fs := flag.NewFlagSet("top-artists", flag.ExitOnError)
	period := fs.String("period", "overall", "7day|1month|3month|6month|12month|overall")
	limit := fs.Int("limit", 10, "merged entries to output")
	// -all-periods:一次进程拿全 App 用的四个时段,输出 {"7day":[...],...}。
	// App 的歌手榜切时段原来每档各起一个 collector 进程(spawn + 磁盘加载 + 网络往返),
	// 四档并发取数在 Go 里只是四个 goroutine —— 一次 spawn,切时段零等待(2026-08-11
	// 发散采纳)。
	allPeriods := fs.Bool("all-periods", false, "fetch 7day/1month/12month/overall in one run")
	mbBudget := fs.Int("mb-budget", 0, "resolve up to N uncached artist identities via MusicBrainz (0 = cache only)")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("top-artists: %v", err)
	}
	// -limit 0/负数会让下面的切片截断 panic;period 打错的话 Last.fm 会静默按默认处理,
	// 返回一份跟请求对不上的数据 —— 都在本地挡掉(审阅指出)。
	if *limit < 1 {
		*limit = 10
	}
	switch *period {
	case "7day", "1month", "3month", "6month", "12month", "overall":
	default:
		log.Fatalf("top-artists: invalid -period %q", *period)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("top-artists: resolve home dir: %v", err)
	}
	cfg, err := loadConfig(filepath.Join(home, ".config", clientName, "config.json"))
	if err != nil {
		log.Fatalf("top-artists: load config: %v", err)
	}
	if cfg.LastfmUser == "" || cfg.lastfmBridgeAPIKey() == "" {
		log.Fatal("top-artists: lastfm_user / api key not configured")
	}
	// 身份缓存(mbid+中文名)与常驻进程共用同一份文件;默认预算 0 = 只读缓存不联网,
	// App 统计页那条调用路径保持毫秒级。手动导出想现场解析就传 -mb-budget(每个未缓存
	// 名字 ≤2 次 MusicBrainz 请求、全局 1.1s 限速,预算大时耐心等)。
	loadArtistIdentityCache(filepath.Join(home, ".config", clientName, clientName+"-artist-identity-cache.json"))
	// 归并的名字键(artistMergeNameKey)2026-08-31 起还会经 resolveGenericArtistCanonicalName 查
	// "英文标签 → 中文常用名"——那条链有自己的两份缓存(MusicBrainz 中文别名 / QQ 歌手名),
	// 跟常驻进程共用同一份文件,这里也得加载,否则每个名字都当"没查过"(2026-09-03 实测 CLI
	// 因此跑 1 分 49 秒被 App 看门狗杀掉)。预算为 0 时那条链同样只读缓存不联网,见
	// artistCanonicalCacheOnly。
	loadArtistAliasCache(filepath.Join(home, ".config", clientName, clientName+"-artist-alias-cache.json"))
	loadQQArtistNameCache(filepath.Join(home, ".config", clientName, clientName+"-qq-artist-name-cache.json"))
	artistCanonicalCacheOnly = *mbBudget <= 0
	resolve := budgetedArtistIdentity(*mbBudget)
	defer saveArtistIdentityCache()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if *allPeriods {
		periods := []string{"7day", "1month", "12month", "overall"}
		type periodResult struct {
			period  string
			entries []lastfmChartEntry
			err     error
		}
		ch := make(chan periodResult, len(periods))
		for _, pd := range periods {
			go func(pd string) {
				pool := topArtistsFetchPool
				if pool < *limit*3 {
					pool = *limit * 3
				}
				entries, err := lastfmTopArtistsPeriod(ctx, cfg.LastfmUser, cfg.lastfmBridgeAPIKey(), pd, pool)
				ch <- periodResult{pd, entries, err}
			}(pd)
		}
		out := map[string][]topArtistEntry{}
		for range periods {
			r := <-ch
			if r.err != nil {
				// 单个时段失败不拖垮整批 —— 缺的那档 App 侧会按失败态显示重试,
				// 其余三档照常可用。
				log.Printf("top-artists: period %s failed: %v", r.period, r.err)
				continue
			}
			merged := mergeAliasedArtistsResolved(r.entries, resolve)
			if len(merged) > *limit {
				merged = merged[:*limit]
			}
			rows := make([]topArtistEntry, 0, len(merged))
			for _, e := range merged {
				rows = append(rows, topArtistEntry{Name: e.Name, PlayCount: e.PlayCount})
			}
			out[r.period] = rows
		}
		if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
			log.Fatalf("top-artists: encode: %v", err)
		}
		return
	}
	// 跟网页推送同一个道理(topArtistsFetchPool 的注释):合并会把多条折成一条,原始
	// 条目必须拉得比要展示的多,不然合并完不足数。上限对齐那边的经验值,再按 limit
	// 放大一档兜住大 limit 的调用。
	pool := topArtistsFetchPool
	if pool < *limit*3 {
		pool = *limit * 3
	}
	entries, err := lastfmTopArtistsPeriod(ctx, cfg.LastfmUser, cfg.lastfmBridgeAPIKey(), *period, pool)
	if err != nil {
		log.Fatalf("top-artists: fetch: %v", err)
	}
	merged := mergeAliasedArtistsResolved(entries, resolve)
	if len(merged) > *limit {
		merged = merged[:*limit]
	}

	out := make([]topArtistEntry, 0, len(merged))
	for _, e := range merged {
		out = append(out, topArtistEntry{Name: e.Name, PlayCount: e.PlayCount})
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		log.Fatalf("top-artists: encode: %v", err)
	}
}
