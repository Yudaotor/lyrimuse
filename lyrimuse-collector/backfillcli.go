package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// `collector backfill-lastfm [-dry-run]` —— 给 Swift 侧("账号连接"里那张回填卡)调用的
// 一次性子命令,形态跟 search-lyrics / top-artists 一致(见 main.go 里那串提前分支)。
//
// stdout 只输出**一行** JSON(backfillOutcome),stderr 留给日志。Swift 侧据此显示
// "已补 N 条 / 还有 M 条太旧 / K 条状态未知"。
//
// 为什么做成子命令而不是让常驻 collector 自己跑:
//   - 回填是**用户显式点一下**才该发生的动作,不是后台自动行为 —— 往用户的 Last.fm 写
//     不可删除的数据,必须由人按下按钮
//   - 常驻进程每次设置变更都会被 kickstart 重启,把一个跨分钟级的批量任务挂在它身上,
//     随时可能被拦腰打断;子命令的生命周期由这次点击决定,清楚得多
//   - dry-run 能在不发任何请求的前提下先给用户报数
func runBackfillLastfmCLI(args []string) {
	fs := flag.NewFlagSet("backfill-lastfm", flag.ExitOnError)
	dryRun := fs.Bool("dry-run", false, "count what would be submitted without sending anything")
	timeoutSecs := fs.Int("timeout", 600, "overall timeout in seconds")
	_ = fs.Parse(args)

	home, err := os.UserHomeDir()
	if err != nil {
		emitBackfillOutcome(backfillOutcome{AbortedReason: "cannot resolve home directory"})
		return
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	cfgPath := filepath.Join(cfgDir, "config.json")

	// 跟 searchcli.go 同一个理由:这条子命令走的是 main() 里那串提前 return 分支,
	// 包级变量 features / listenLogPath 此刻都还是零值,必须自己按同样的路径规则装一遍。
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	// 只记路径、**不做压缩**:压缩会重写整份日志,而这条命令可能与常驻 collector 的
	// 追加写并发。initListenLog 的压缩只该由启动路径做一次。
	listenLogPath = filepath.Join(cfgDir, clientName+"-listens.jsonl")

	cfg, err := loadConfig(cfgPath)
	if err != nil {
		emitBackfillOutcome(backfillOutcome{AbortedReason: fmt.Sprintf("load config: %v", err)})
		return
	}
	// 合唱串「智能」档判定缓存的路径是包级变量,平时由 main.go 跟其它落盘路径一起设 —— 这条
	// 子命令绕过了那段,自己设一次,否则回填里每首合唱歌都要重新打 track.getInfo,而且
	// 常驻 collector 已经判过的结论也拿不到(两条路径必须读同一份缓存才能发同一个名字)。
	lastfmCollapsePath = filepath.Join(cfgDir, clientName+"-lastfm-collapse.json")

	// 刻意**不**走 lastfmScrobblerIfEnabled:那个多包了一层 features.LastfmMirrorScrobble
	// 开关。回填是用户在界面上显式点的一次性动作,不该被"要不要持续镜像"这个偏好否决 ——
	// 一个只想补历史、不想让它持续跟着 scrobble 的人,是个成立的选择。
	scrobbler := newLastfmScrobbler(
		cfg.LastfmScrobbleAPIKey, cfg.LastfmScrobbleSecret, cfg.LastfmScrobbleSessionKey)
	if scrobbler != nil {
		// 用**只读**的那把 api_key:track.getInfo 不需要签名,读写本来就是两个 key
		// (理由见 lastfm.go 里同一处的注释)。
		scrobbler.collapse = newLastfmArtistCollapser(cfg.lastfmBridgeAPIKey())
	}
	// dry-run 允许在没连账号时也跑 —— 那正是"还没连,先看看攒了多少条"这个场景。
	if scrobbler == nil && !*dryRun {
		emitBackfillOutcome(backfillOutcome{AbortedReason: "last.fm not connected"})
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*timeoutSecs)*time.Second)
	defer cancel()
	emitBackfillOutcome(runBackfill(ctx, scrobbler, *dryRun))
}

func emitBackfillOutcome(out backfillOutcome) {
	enc := json.NewEncoder(os.Stdout)
	_ = enc.Encode(out)
}
