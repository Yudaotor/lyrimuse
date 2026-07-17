// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"flag"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

const (
	clientName    = "applemusic-nowplaying"
	clientVersion = "0.1.0"

	pollInterval      = 5 * time.Second
	playingNowRefresh = 60 * time.Second
	// 未缓存新歌:开播时挂起首条 playing_now,最多等这么久让 enrich 解析出歌词再发
	// (LB 只认换曲那条,歌词须在首条;enrichNotify 通常更早触发)。
	pnPendingMax = 8 * time.Second
	// media-control 连续读空(nullStreak≥3)会被当作"停播"清空当前曲目、终结 session；若这其实
	// 只是短暂假死、同一首歌很快又重新读到,在这个宽限期内续接旧 session(而非清零重开),避免
	// 一次连续收听被假死切成两段、各自达到阈值后向 LB 提交两条 listen。
	nullResumeGraceWindow = 60 * time.Second
	submitTimeout         = 15 * time.Second
	// 单次提交超时：playing_now 失败无妨(≤playingNowRefresh 会再发)，快超时保持 poll 循环
	// 灵敏(暂停/切歌能及时反映)；single(完成收听)丢了就永久少一条，用更长超时并重试。
	playingNowTimeout = 8 * time.Second
	singleTimeout     = 12 * time.Second
	singleMaxTries    = 2
	// Ignore accrual gaps larger than this (sleep, stream restarts).
	maxAccrualGapSecs = 60.0
	// Standard scrobble rule: half the track or 4 minutes, whichever is less.
	listenCapSecs = 240.0
	// Tracks shorter than this are never submitted as listens.
	minTrackSecs = 30.0
	// LB rejects any single listen larger than 10240 bytes. Lyrics (esp. word-level
	// yrc) are the only large fields; cap their combined size well under that, with
	// room left for cover/links/progress + JSON overhead.
	lyricBudgetBytes = 8000
)

func main() {
	log.SetFlags(log.LstdFlags)
	// `collector search-lyrics ...`:一次性子命令,desktop-lyrics 的"歌词管理"窗口靠
	// Process 调用它来手动重新搜索候选歌词(见 searchcli.go)——检查放在 flag.Parse()
	// 之前,不然位置参数 "search-lyrics" 会被当成未知 flag 报错。
	if len(os.Args) > 1 && os.Args[1] == "search-lyrics" {
		runSearchLyricsCLI(os.Args[2:])
		return
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("resolve home dir: %v", err)
	}
	cfgPath := flag.String("config", filepath.Join(home, ".config", clientName, "config.json"), "config file path")
	dryRun := flag.Bool("dry-run", false, "log submissions instead of calling ListenBrainz")
	flag.Parse()

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if cfg.Token == "" && !*dryRun {
		log.Fatalf("missing ListenBrainz token: set listenbrainz_token in %s or LISTENBRAINZ_TOKEN env", *cfgPath)
	}
	// 2026-07-15:desktop-lyrics"设置"窗口的"功能开关"分组写这份共享文件,collector
	// 启动时读一次(没有文件监听,改了要重启才生效,跟 config.json/enrichCache 同一套
	// 约定)。放在 loadEnrichCache 之前——下面 lyrics_files 分支要用到。
	features = loadFeatureFlags(filepath.Join(filepath.Dir(*cfgPath), clientName+"-features.json"))
	// 曲目元信息缓存落盘在 config 同目录，重启后不重解析同一首歌。
	loadEnrichCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-cache.json"))
	// 2026-07-15:歌词部分(lyrics/lyrics_tr/lyrics_roma/lyrics_yrc/lyrics_source/
	// manual_lyrics)现在以 lyrics/ 文件夹为权威源,不再只是 enrichCache 的只读存档——
	// 顺序很重要:先 importLyricsFromFiles() 用文件夹内容覆盖刚从 JSON 缓存加载出来的
	// 内存态(文件永远赢),再 exportLyricsFiles() 把"刚被覆盖生效的内容"重新导出一遍,
	// 让磁盘文件立刻互相对齐(老版本导出的无头文件、或者刚发生的"删除文件=删条目"调和
	// 结果,都会在这一轮里落定)。desktop-lyrics 那边"歌词管理"手动编辑/删除后
	// kickstart 重启 collector,走的也是这同一条启动路径,不用在 Swift 侧另外实现一遍
	// 调和逻辑。lyrics_files 开关关闭时整段跳过——lyrics/ 文件夹不再被当作权威源,
	// enrichCache 里已有的歌词字段保持不动(不清空),只是不再跟文件夹互相同步。
	// 2026-07-16:文件夹位置可以在"歌词"设置分类里自定义(lyrics_dir),留空才落到
	// config.json 同目录下的默认 lyrics/ 子目录——desktop-lyrics 那边选新文件夹后不会
	// 自动搬运旧文件夹里已有的文件,只是从这一刻起只认新位置读写。
	lyricsDir = features.LyricsDir
	if lyricsDir == "" {
		lyricsDir = filepath.Join(filepath.Dir(*cfgPath), "lyrics")
	}
	if features.LyricsFiles {
		importLyricsFromFiles()
		exportLyricsFiles()
	}
	forwardedPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-forwarded.json")
	lfmMirroredPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-mirrored.json")
	weeklyDigestPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-weekly.json")
	topArtistsStatePath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-top-artists.json")

	lb := &lbClient{root: cfg.APIRoot, token: cfg.Token, hc: &http.Client{}, dryRun: *dryRun, alerter: newAlerter(cfg.NotificationPlatform, cfg.NotificationWebhookURL, cfg.DingtalkSignSecret, cfg.FeishuSignSecret)}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Printf("%s %s starting (media-control: %s, bundles: %v, dry-run: %v)",
		clientName, clientVersion, cfg.MediaControlPath, cfg.BundleIDs, *dryRun)
	if err := run(ctx, cfg, lb); err != nil && ctx.Err() == nil {
		log.Fatalf("run: %v", err)
	}
}
