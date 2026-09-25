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
	// 四档并发取数在 Go 里只是四个 goroutine —— 一次 spawn,切时段零等待(
	// 发散采纳)。
	allPeriods := fs.Bool("all-periods", false, "fetch 7day/1month/12month/overall in one run")
	// -with-previous(配 -all-periods):每档再取上一期、按同一套合并对齐名次,给 App 画升降箭头。
	// 输出换成 {"7day":{"rows":[...],"previous":{...}},...},见 topArtistsPeriodOutput。
	withPrevious := fs.Bool("with-previous", false, "with -all-periods: also compare each period with the previous one")
	mbBudget := fs.Int("mb-budget", 0, "resolve up to N uncached artist identities via MusicBrainz (0 = cache only)")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("top-artists: %v", err)
	}
	// -limit 0/负数会让下面的切片截断 panic;period 打错的话 Last.fm 会静默按默认处理,
	// 返回一份跟请求对不上的数据 —— 都在本地挡掉。
	if *limit < 1 {
		*limit = 10
	}
	switch *period {
	case "7day", "1month", "3month", "6month", "12month", "overall":
	default:
		log.Fatalf("top-artists: invalid -period %q", *period)
	}

	if configDir() == "" {
		log.Fatalf("top-artists: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfg, err := loadConfig(filepath.Join(configDir(), "config.json"))
	if err != nil {
		log.Fatalf("top-artists: load config: %v", err)
	}
	if cfg.LastfmUser == "" || cfg.lastfmBridgeAPIKey() == "" {
		log.Fatal("top-artists: lastfm_user / api key not configured")
	}
	// 身份缓存(mbid+中文名)与常驻进程共用同一份文件;默认预算 0 = 只读缓存不联网,
	// App 统计页那条调用路径保持毫秒级。手动导出想现场解析就传 -mb-budget(每个未缓存
	// 名字 ≤2 次 MusicBrainz 请求、全局 1.1s 限速,预算大时耐心等)。
	loadArtistIdentityCache(filepath.Join(configDir(), clientName+"-artist-identity-cache.json"))
	// 归并的名字键(artistMergeNameKey)还会经 resolveGenericArtistCanonicalName 查
	// "英文标签 → 中文常用名"——那条链有自己的两份缓存(MusicBrainz 中文别名 / QQ 歌手名),
	// 跟常驻进程共用同一份文件,这里也得加载,否则每个名字都当"没查过"(实测 CLI
	// 因此跑 1 分 49 秒被 App 看门狗杀掉)。预算为 0 时那条链同样只读缓存不联网,见
	// artistCanonicalCacheOnly。
	loadArtistAliasCache(filepath.Join(configDir(), clientName+"-artist-alias-cache.json"))
	loadQQArtistNameCache(filepath.Join(configDir(), clientName+"-qq-artist-name-cache.json"))
	artistCanonicalCacheOnly = *mbBudget <= 0
	resolve := budgetedArtistIdentity(*mbBudget)
	defer saveArtistIdentityCache()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if *allPeriods {
		results := topArtistsAllPeriods(ctx, cfg.LastfmUser, cfg.lastfmBridgeAPIKey(), *limit, resolve, *withPrevious, time.Now())
		var out any
		if *withPrevious {
			out = results
		} else {
			plain := map[string][]topArtistEntry{}
			for pd, r := range results {
				rows := make([]topArtistEntry, 0, len(r.Rows))
				for _, row := range r.Rows {
					rows = append(rows, topArtistEntry{Name: row.Name, PlayCount: row.PlayCount})
				}
				plain[pd] = rows
			}
			out = plain
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

// topArtistsPeriodSpan 是各时段的长度,上一期 = 紧挨着的前一段同样长的窗口。按这三个长度用
// user.getWeekly*Chart 取出的本期榜跟 Last.fm 滚动榜(user.getTop* 的 7day / 1month / 12month)
// 逐条一致,两期同口径。overall 没有上一期。App 侧 LyrimuseCore.ChartComparison 用同一组长度,
// 两处必须同步改。
var topArtistsPeriodSpan = map[string]time.Duration{
	"7day":    7 * 24 * time.Hour,
	"1month":  30 * 24 * time.Hour,
	"12month": 365 * 24 * time.Hour,
}

// topArtistsCLIRow 是 -with-previous 输出里的一行。
type topArtistsCLIRow struct {
	Name      string `json:"name"`
	PlayCount int    `json:"playCount"`
	// PrevRank:上一期合并后榜里的名次;0 = 上一期榜里没有。nil = 这一档没有可比的上一期
	// (overall、上一期取数失败、或上一期一条收听都没有)。
	PrevRank *int `json:"prevRank,omitempty"`
}

// topArtistsPrevious 是这一档对比的上一期窗口。Listens 为 0 时 App 不画箭头、只说明原因。
type topArtistsPrevious struct {
	From    int64 `json:"from"`
	To      int64 `json:"to"`
	Listens int   `json:"listens"`
}

type topArtistsPeriodOutput struct {
	Rows []topArtistsCLIRow `json:"rows"`
	// Previous 为 nil = 没有上一期可比(overall 或上一期取数失败)。
	Previous *topArtistsPrevious `json:"previous,omitempty"`
}

// topArtistsAllPeriods 四个时段并发取数、合并、截断;withPrevious 时每档再取上一期并对齐名次。
// 单个时段本期失败就不出现在结果里(App 按失败态给重试);上一期失败只是这一档没有箭头。
func topArtistsAllPeriods(ctx context.Context, user, apiKey string, limit int, resolve artistIdentityFn, withPrevious bool, now time.Time) map[string]topArtistsPeriodOutput {
	periods := []string{"7day", "1month", "12month", "overall"}
	type periodResult struct {
		period   string
		entries  []lastfmChartEntry
		err      error
		previous []lastfmChartEntry
		window   *topArtistsPrevious
	}
	ch := make(chan periodResult, len(periods))
	for _, pd := range periods {
		go func(pd string) {
			pool := topArtistsFetchPool
			if pool < limit*3 {
				pool = limit * 3
			}
			r := periodResult{period: pd}
			r.entries, r.err = lastfmTopArtistsPeriod(ctx, user, apiKey, pd, pool)
			if span, ok := topArtistsPeriodSpan[pd]; ok && withPrevious && r.err == nil {
				from, to := now.Add(-2*span).Unix(), now.Add(-span).Unix()
				prev, err := lastfmWeeklyTopArtists(ctx, user, apiKey, from, to)
				if err != nil {
					log.Printf("top-artists: previous %s failed: %v", pd, err)
				} else {
					listens := 0
					for _, e := range prev {
						listens += e.PlayCount
					}
					r.previous = prev
					r.window = &topArtistsPrevious{From: from, To: to, Listens: listens}
				}
			}
			ch <- r
		}(pd)
	}
	out := map[string]topArtistsPeriodOutput{}
	for range periods {
		r := <-ch
		if r.err != nil {
			// 单个时段失败不拖垮整批 —— 缺的那档 App 侧会按失败态显示重试,
			// 其余三档照常可用。
			log.Printf("top-artists: period %s failed: %v", r.period, r.err)
			continue
		}
		merged := mergeAliasedArtistsResolved(r.entries, resolve)
		if len(merged) > limit {
			merged = merged[:limit]
		}
		var ranks []int
		if r.window != nil && r.window.Listens > 0 {
			ranks = previousMergedRanks(merged, mergeAliasedArtistsResolved(r.previous, resolve), artistMergeNameKey)
		}
		rows := make([]topArtistsCLIRow, 0, len(merged))
		for i, e := range merged {
			row := topArtistsCLIRow{Name: e.Name, PlayCount: e.PlayCount}
			if ranks != nil {
				rank := ranks[i]
				row.PrevRank = &rank
			}
			rows = append(rows, row)
		}
		out[r.period] = topArtistsPeriodOutput{Rows: rows, Previous: r.window}
	}
	return out
}

// previousMergedRanks 给本期(已合并)每一条找它在上一期(已合并)榜里的名次,找不到为 0。
// 两边都按合并用的名字键对齐,繁简 / 中英文艺名 / 合唱串跟合并本身同一把尺子;
// 上一期同一个键出现多次时取靠前的那个。
func previousMergedRanks(current, previous []lastfmChartEntry, nameKey func(string) string) []int {
	prevRank := make(map[string]int, len(previous))
	for i, e := range previous {
		k := nameKey(e.Name)
		if _, seen := prevRank[k]; k != "" && !seen {
			prevRank[k] = i + 1
		}
	}
	out := make([]int, len(current))
	for i, e := range current {
		out[i] = prevRank[nameKey(e.Name)]
	}
	return out
}
