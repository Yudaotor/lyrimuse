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

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
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
	merged := mergeAliasedArtists(entries)
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
