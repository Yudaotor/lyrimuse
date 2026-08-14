// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
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
	// 2026-07-23:项目最早叫 applemusic-nowplaying,后来改名 Lyrimuse 时这个常量
	// 没跟着一起改——配置目录/文件名前缀/User-Agent/ListenBrainz submission_client
	// 全部由它派生,现在统一改过来,不做旧路径兼容(不写自动迁移代码)。
	clientName = "lyrimuse"
	// 2026-07-27:之前一直没跟着 App 的 CFBundleShortVersionString 走(App 侧由
	// LYRIMUSE_VERSION 从 git tag 自动派生,这个常量完全独立、从改名到现在没手动
	// 动过)——收到 v1.1.0 发布时顺手同步一次,不代表以后每次发版都会自动跟着改,
	// 这里仍然是纯手动维护的字面量。2026-08-03 随 v1.2.0 发布再同步一次。
	clientVersion = "1.2.0"

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
	// `collector artist-avatars ...`:同 search-lyrics 的形态,给 Last.fm 信息页解析
	// 歌手头像(见 avatarcli.go)。
	if len(os.Args) > 1 && os.Args[1] == "artist-avatars" {
		runArtistAvatarsCLI(os.Args[2:])
		return
	}
	// `collector backfill-lastfm [-dry-run]`:把本地收听日志里还没提交过的收听补到
	// Last.fm(见 backfillcli.go / backfill.go)。跟上面几个一样是一次性子命令。
	if len(os.Args) > 1 && os.Args[1] == "backfill-lastfm" {
		runBackfillLastfmCLI(os.Args[2:])
		return
	}
	// `collector healthcheck [-json] [-local-only]`:一次性诊断"歌词为什么不出来"
	// (见 healthcheckcli.go)。跟上面几个一样,不进入常驻循环。
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		runHealthcheckCLI(os.Args[2:])
		return
	}
	// `collector top-artists ...`:合并同名歌手后的 Top 榜(见 topartistscli.go)。
	if len(os.Args) > 1 && os.Args[1] == "top-artists" {
		runTopArtistsCLI(os.Args[2:])
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
		// 走到这儿只剩"文件在但读不出来"(权限/IO)一种情况——内容有问题已经在
		// loadConfig 里降级成 loadIssues 了,不再打死进程。见 loadConfig 的注释:
		// KeepAlive 下 Fatal 等于崩溃循环,而核心功能根本不需要配置。
		log.Fatalf("load config: %v", err)
	}
	for _, issue := range cfg.loadIssues {
		// 这条要显眼:配置没有完整生效,但服务照常在跑,用户看到的是"某个功能不工作"
		// 而不是"服务挂了",没有这行日志就无从下手。
		log.Printf("config: %s", issue)
	}
	// listenbrainz_token 是可选的:没填也能正常启动,只是不会提交到 ListenBrainz(见
	// lbClient.submit 里的空 token 直接跳过网络调用)——media-control 采集、歌词/封面
	// 解析、写本地缓存(desktop-lyrics 悬浮窗要用的那份)全都照常工作,不依赖这个 token。
	if cfg.Token == "" {
		log.Printf("no listenbrainz_token configured: ListenBrainz submission disabled, running locally only (media-control + lyrics/cover enrichment still work)")
	}
	// desktop-lyrics"设置"窗口的"功能开关"分组写这份共享文件,collector 启动时读一次
	// (没有文件监听,改了要重启才生效,跟 config.json/enrichCache 同一套约定)。放在
	// loadEnrichCache 之前——下面读 features.LyricsDir 要用到。
	features = loadFeatureFlags(filepath.Join(filepath.Dir(*cfgPath), clientName+"-features.json"))
	// 曲目元信息缓存落盘在 config 同目录，重启后不重解析同一首歌。
	loadEnrichCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-cache.json"))
	// 按歌手(不是按曲目)缓存的 MusicBrainz 中文别名查询结果,同目录下单独一份文件——
	// 见 musicbrainz.go 顶部注释。
	loadArtistAliasCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-artist-alias-cache.json"))
	// 歌词部分(lyrics/lyrics_tr/lyrics_roma/lyrics_yrc/lyrics_source/manual_lyrics)以
	// lyrics/ 文件夹为权威源,不只是 enrichCache 的只读存档——顺序很重要:先
	// importLyricsFromFiles() 用文件夹内容覆盖刚从 JSON 缓存加载出来的内存态(文件
	// 永远赢),再 exportLyricsFiles() 把"刚被覆盖生效的内容"重新导出一遍,让磁盘
	// 文件立刻互相对齐(老版本导出的无头文件、或者刚发生的"删除文件=删条目"调和结果,
	// 都会在这一轮里落定)。desktop-lyrics 那边"歌词管理"手动编辑/删除后 kickstart
	// 重启 collector,走的也是这同一条启动路径,不用在 Swift 侧另外实现一遍调和逻辑。
	// 这是固定行为,不可关闭。
	// 文件夹位置可以在"歌词"设置分类里自定义(lyrics_dir),留空则落到 config.json 同
	// 目录下的默认 lyrics/ 子目录——切换新文件夹后不会自动搬运旧文件夹里已有的文件,
	// 只从这一刻起只认新位置读写。
	lyricsDir = features.LyricsDir
	if lyricsDir == "" {
		lyricsDir = filepath.Join(filepath.Dir(*cfgPath), "lyrics")
	}
	// 存量 key 归一化,必须夹在这里:要在 importLyricsFromFiles() 之前(否则老文件会按
	// 旧头部标签把刚合并掉的条目又导回来,而且两份文件抢同一个 key,内容每次重启随机翻转),
	// 又要在 lyricsDir 定下来之后(它得删掉落选条目的导出文件)。见 enrichkey.go。
	migrateEnrichKeys()
	importLyricsFromFiles()
	// 夹在 import 和 export 之间:见 invalidateStaleTranslations 的注释——前者让
	// lyrics/ 文件夹赢,后者负责把这里清空的译文同步成删掉对应的 .tr.lrc。
	invalidateStaleTranslations()
	exportLyricsFiles()
	// 本地收听日志:刻意**不带** lastfm-/lb- 这类账号域前缀 —— 这份日志存在的全部意义
	// 就是"不依赖任何账号",挂上某个账号的名字就说反了。
	initListenLog(filepath.Join(filepath.Dir(*cfgPath), clientName+"-listens.jsonl"))
	forwardedPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-forwarded.json")
	lastfmCollapsePath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-collapse.json")
	lfmMirroredPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-mirrored.json")
	lastfmStatusPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-status.json")
	// collector→App 的状态通道(眼下只报"网络不通",见 collectorstatus.go)。设置这个
	// 路径的同时会清掉上次运行留下的文件 —— 那份状态跟这次进程无关。
	setCollectorStatusPath(filepath.Join(filepath.Dir(*cfgPath), clientName+"-collector-status.json"))
	weeklyDigestPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-weekly.json")
	dailyDigestPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lb-daily.json")
	topArtistsStatePath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-top-artists.json")

	lb := &lbClient{root: cfg.APIRoot, token: cfg.Token, hc: &http.Client{}, dryRun: *dryRun, alerter: newAlerter(cfg.NotificationPlatform, cfg.NotificationWebhookURL, cfg.DingtalkSignSecret, cfg.FeishuSignSecret)}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Printf("%s %s starting (bundles: %v, dry-run: %v)",
		clientName, clientVersion, cfg.BundleIDs, *dryRun)
	if err := run(ctx, cfg, lb); err != nil && ctx.Err() == nil {
		log.Fatalf("run: %v", err)
	}
}
