// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"flag"
	"fmt"
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

// clientVersion 是这份 collector 自报的版本号——`collector version` 子命令、
// ListenBrainz 的 submission_client_version、以及 musicbrainz/lrclib 两处 User-Agent
// 都用它。
//
// ⚠️ **构建时由 -ldflags 注入,不要在这里手写版本号**。两个构建脚本都注入同一个值:
// lyrimuse/build.sh(打包 App 时构建这份 collector,CI 发版也走它)和
// lyrimuse-collector/build.sh(本地只重建 collector 时用),注入的都是跟 App 的
// CFBundleShortVersionString **同一个来源**的版本号(LYRIMUSE_VERSION 环境变量,
// 没有就取最近一个 git tag)。
//
// ⚠️ **必须是 var,不能是 const** —— Go 的 `-ldflags -X` 只能写 var,对 const
// **静默失败**:构建照样 exit 0、不报错不警告,而值原封不动。2026-09-02 实测坐实
// (`go build -ldflags "-X main.clientVersion=9.9.9"` 之后 `collector version`
// 仍然打印旧值)。谁要是哪天顺手把它改回 const,注入就会无声无息地失效,回到下面
// 说的那个老毛病——`versioninjection_test.go` 有一条断言专门钉住这件事。
//
// **为什么改成注入**(2026-09-02):在此之前这里是手动维护的字面量,而 App 侧版本号
// 一直是从 git tag 自动派生的——两个版本号一个自动一个手动,靠人在发版时记得改这一行
// 来同步。实际记录:v1.1.0 补同步一次、v1.2.0 补一次、**v1.3.0 漏了**(User-Agent/
// ListenBrainz submission_client 谎报了一整个发布周期)、v1.4.0 补上、**v1.5.0 又漏了**
// (用户在另一台机器装了 1.5.0 的 dmg,设置页报「App 1.5.0 · 采集服务 1.4.0」)。
// 同一个坑两年内踩两次,说明问题不在"谁不小心",在于机制本身要求人工同步两个本该
// 同源的值。改成从构建脚本注入之后,这一行不再需要任何人手动维护。
//
// 默认值 "dev" 是**故意选的一眼假值**,不是占位版本号:裸 `go build`/`go test` 出来的
// 二进制会自报 dev,一眼看出"这不是发布构建"。刻意不写成某个具体版本号——那正是这次
// 事故最坏的形态:一个看起来完全正常、实际早就过时的版本号,没有任何人会起疑。
// (同一条原则见 lyrimuse/build.sh 里 APP_VERSION 退到 0.0.0 那段注释。)
var clientVersion = "dev"

const (
	// 2026-07-23:项目最早叫 applemusic-nowplaying,后来改名 Lyrimuse 时这个常量
	// 没跟着一起改——配置目录/文件名前缀/User-Agent/ListenBrainz submission_client
	// 全部由它派生,现在统一改过来,不做旧路径兼容(不写自动迁移代码)。
	clientName = "lyrimuse"

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
	// Tracks shorter than this are not submitted as listens unless the user opts in
	// (features.ScrobbleShortTracks; see tooShortToScrobble in poller.go). Last.fm's
	// scrobbling guidelines: "The track must be longer than 30 seconds."
	minTrackSecs = 30.0
	// LB rejects any single listen larger than 10240 bytes. Lyrics (esp. word-level
	// yrc) are the only large fields; cap their combined size well under that, with
	// room left for cover/links/progress + JSON overhead.
	lyricBudgetBytes = 8000
)

func main() {
	// LUTC:诊断导出（DiagnosticsExporter.swift）同一份报告里并排放着 App 侧日志（os.Logger，
	// 显式带 +0000）和这份 collector 日志——不加这个标志，这里打的是本地墙钟且不带任何时区
	// 标记，两段日志的时间轴对不上（实测坐实：8 小时时区差，排查时得自己心算），这个标志把
	// 两边统一到 UTC。
	log.SetFlags(log.LstdFlags | log.LUTC)
	// 凭据不进日志。必须在这里、在任何子命令分流之前 —— 子命令各自 loadConfig、
	// 不走下面的主流程,漏了它们同样会把 api_key 写进日志。见 logscrub.go。
	installLogScrubbing()
	// `collector version`:一次性子命令,只打印 clientVersion 就退出——App 侧设置页
	// "后台采集服务"卡片靠它检测"App 本体版本"跟"实际打包进这份 App 的 collector 版本"
	// 是否一致(2026-08-31 加)。起因是 main.go 里 clientVersion 这个字面量一直是手动
	// 同步的,发布时忘记同步过至少一次(v1.3.0 那次漏了,见 clientVersion 声明处注释,
	// User-Agent/ListenBrainz submission_client 因此谎报了一整个发布周期)——当时没有
	// 任何机制能让用户/开发者自己发现这个不一致,这条子命令就是补上这道自检。跟
	// search-lyrics 一样,检查要放在 flag.Parse() 之前。
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(clientVersion)
		return
	}
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
	// `collector delete-listen -uts <秒>`:从本地收听日志里删掉指定记录(见
	// deletelistencli.go)。给"本地已记录 N 首"那个清单上的删除按钮用。
	if len(os.Args) > 1 && os.Args[1] == "delete-listen" {
		runDeleteListenCLI(os.Args[2:])
		return
	}
	// `collector healthcheck [-json] [-local-only]`:一次性诊断"歌词为什么不出来"
	// (见 healthcheckcli.go)。跟上面几个一样,不进入常驻循环。
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		runHealthcheckCLI(os.Args[2:])
		return
	}
	// `collector test-lyric-sources [-source <name>]`:逐个歌词源探测可用性,边测边出
	// NDJSON 结果,给设置页"歌词来源"卡片的测试按钮用(见 testlyricsourcescli.go)。跟
	// healthcheck 同一套探测逻辑,输出形状不同(一个源一行,不是一次性整份报告)。
	if len(os.Args) > 1 && os.Args[1] == "test-lyric-sources" {
		runTestLyricSourcesCLI(os.Args[2:])
		return
	}
	// `collector top-artists ...`:合并同名歌手后的 Top 榜(见 topartistscli.go)。
	if len(os.Args) > 1 && os.Args[1] == "top-artists" {
		runTopArtistsCLI(os.Args[2:])
		return
	}
	// `collector regenerate-jyutping [-apply]`:按当前算法+词典重算存量粤拼(见
	// regeneratejyutpingcli.go)。maybeGenerateJyutpingRoma 只补空值、从不覆盖,所以
	// 算法/词典改了之后要靠这个命令回头刷存量。跟 dedupe-entries 同形态:默认预演。
	if len(os.Args) > 1 && os.Args[1] == "regenerate-jyutping" {
		runRegenerateJyutpingCLI(os.Args[2:])
		return
	}
	// `collector backfill-roma [-apply] [-limit N]`:给存量条目补罗马音(见
	// backfillromacli.go)。maybeGenerateHelperRoma 只在解析/重评那一刻跑,所以这条特性
	// 上线时存量一条都不会被补上;跟 regenerate-jyutping 同形态,默认预演。
	if len(os.Args) > 1 && os.Args[1] == "backfill-roma" {
		runBackfillRomaCLI(os.Args[2:])
		return
	}
	// `collector dedupe-entries [-apply]`:把 enrich 缓存里"其实是同一首歌"的重复条目
	// 并成一条(见 dedupecli.go)。默认预演,-apply 才真改。
	if len(os.Args) > 1 && os.Args[1] == "dedupe-entries" {
		runDedupeEntriesCLI(os.Args[2:])
		return
	}
	// `collector recheck-cover [-apply] "歌手|歌名|专辑" ...`:对指定条目重新解析一次封面
	// (见 covercli.go)。默认预演,-apply 才真改、且要求常驻实例已停。
	if len(os.Args) > 1 && os.Args[1] == "recheck-cover" {
		runRecheckCoverCLI(os.Args[2:])
		return
	}
	// `collector recheck-instrumental [-apply] "歌手|歌名|专辑" ...`:给缺「纯音乐」标记的
	// 条目补上这个结论(见 covercli.go)。默认预演,-apply 才真改、且要求常驻实例已停。
	if len(os.Args) > 1 && os.Args[1] == "recheck-instrumental" {
		runRecheckInstrumentalCLI(os.Args[2:])
		return
	}
	// `collector retranslate-repeated [-apply]`:扫描整份缓存,把"歌词有重复行、可能被
	// 2026-08-26 那个逐行独立翻译 bug 坑过"的存量译文重新机翻一遍(见 retranslatecli.go)。
	// 默认预演,-apply 才真改、且要求常驻实例已停。
	if len(os.Args) > 1 && os.Args[1] == "retranslate-repeated" {
		runRetranslateRepeatedCLI(os.Args[2:])
		return
	}
	// `collector resync-lyrics [-apply] "歌手|歌名|专辑" ...`:对指定条目强制重新解析,
	// 补上"歌词正文没变、但译文/罗马音其实有新内容"这种自动 rescore 不会碰的情况(见
	// resynclyricscli.go)。默认预演,-apply 才真改、且要求常驻实例已停。
	if len(os.Args) > 1 && os.Args[1] == "resync-lyrics" {
		runResyncLyricsCLI(os.Args[2:])
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
	// 常驻路径才加单实例锁(上面的一次性子命令都在更早的分支里 return 了,不受影响)。
	// 拿不到锁说明已有实例在跑:退出码 0,launchd 的 KeepAlive 会按自己的节流重试,
	// 等旧实例真退了再接管。
	if !acquireSingleInstanceLock(filepath.Dir(*cfgPath)) {
		log.Printf("another collector instance is already running; exiting to avoid clobbering shared caches")
		os.Exit(0)
	}
	features = loadFeatureFlags(filepath.Join(filepath.Dir(*cfgPath), clientName+"-features.json"))
	// (2026-09-02 删掉了这里的 `nativeLyricSources = resolveNativeLyricSources(features.Players)`。
	//  同源加权的判据不该是"用户勾了哪些播放器",而是"**这一刻在放的是哪个**"——现在由
	//  trackEnrichment 每首歌按 bundleID 设一次,见 match.go 里 nativeLyricSources 的注释。
	//  顺带,原注释那句"换播放器本来就要重启 collector"对多选年代也不成立了。)
	// 曲目元信息缓存落盘在 config 同目录，重启后不重解析同一首歌。
	loadEnrichCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-cache.json"))
	// 按歌手(不是按曲目)缓存的 MusicBrainz 中文别名查询结果,同目录下单独一份文件——
	// 见 musicbrainz.go 顶部注释。
	loadArtistAliasCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-artist-alias-cache.json"))
	// 用户校准过歌词时间轴的曲目名单(App 侧写、这边只读),见 lyricspins.go。刻意不在
	// 这里读一次就完 —— lyricsPinned 每次按 mtime 自己判断要不要重读。
	lyricsPinsPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lyrics-pins.json")
	// MB 主名(本名 ↔ 艺名)那份缓存,见 musicBrainzPrimaryArtistName。
	loadMBPrimaryNameCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-artist-primary-cache.json"))
	// Apple 目录曲目 ID → 权威元数据。ID 是不变映射,这份缓存永久有效、只落盘查到了的
	// 条目,见 applecatalog.go。
	loadAppleCatalogCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-apple-catalog-cache.json"))
	// "艺人|专辑" → Apple 各商店曲目署名,见 appleStorefrontArtistIdentities。
	loadAppleStorefrontArtistCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-apple-storefront-artist-cache.json"))
	// 按歌手缓存的 QQ 音乐歌手搜索建议结果,见 qq.go 的 qqArtistCanonicalName。
	loadQQArtistNameCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-qq-artist-name-cache.json"))
	// 歌手身份缓存(mbid+中文名),给 Top 歌手榜归并当第三合并信号——见 musicbrainz.go
	// mbArtistIdentity 注释。与 top-artists CLI 共用同一份文件。
	loadArtistIdentityCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-artist-identity-cache.json"))
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
	// 设备直送封面(deviceartwork.go)落盘目录——跟 lyrics/ 平级,不跟着 lyrics_dir 这个
	// 用户可改的设置走:那个设置管的是"歌词权威源放哪",封面缓存是内部实现细节,不需要
	// 暴露成一项用户配置。
	deviceArtworkDir = filepath.Join(filepath.Dir(*cfgPath), "artwork")
	// 这些设备封面同时要托管到状态中继上,否则推给网页/ListenBrainz 的是别的机器
	// 根本读不到的 file:// 本地路径(2026-09-02 用户报「网页上没有封面了」)。
	// 复用 /push 那套地址与令牌 —— 是同一个中继、同一份认证。见 artworkrelay.go 头注。
	artworkRelayURL, artworkRelayToken = cfg.StateRelayURL, cfg.StateRelayToken
	// 存量 key 归一化,必须夹在这里:要在 importLyricsFromFiles() 之前(否则老文件会按
	// 旧头部标签把刚合并掉的条目又导回来,而且两份文件抢同一个 key,内容每次重启随机翻转),
	// 又要在 lyricsDir 定下来之后(它得删掉落选条目的导出文件)。见 enrichkey.go。
	// 「配置搬家」带过来的决策数据(enrich 缓存的非歌词字段),见 enrichrestore.go 头注。
	// 位置有三条硬约束:要在 loadEnrichCache 之后(要有 enrichPath 才落得了盘)、
	// migrateEnrichKeys 之前(备份里的 key 是导出那台机器当时的写法,得跟着一起归一化)、
	// importLyricsFromFiles 之前(那一步负责让 lyrics/ 文件族赢下六个歌词字段)。
	// 绝大多数启动这个文件不存在,直接早退,零成本。
	adoptEnrichRestore(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-restore.json"))
	migrateEnrichKeys()
	importLyricsFromFiles()
	// 夹在 import 和 export 之间:见 invalidateStaleTranslations 的注释——前者让
	// lyrics/ 文件夹赢,后者负责把这里清空的译文同步成删掉对应的 .tr.lrc。
	invalidateStaleTranslations()
	// 逐字歌词的空白词条清洗(2026-08-19,Musixmatch richsync 存量,见 yrcwhitespace.go)。
	// 必须夹在 import(权威内容已从 lyrics/ 文件夹导回缓存)与 export(把修好的内容写回
	// 导出文件)之间,顺序错了修的就是马上要被覆盖的那一份。
	migrateYRCWhitespaceTokens()
	// 行级时间轴与逐字轴打架时以逐字轴为准重挂(2026-08-27,见 lyricstimeline.go)。
	// 同样夹在 import 与 export 之间,理由同上;放在空白词条清洗**之后**,因为那一步会
	// 改动 YRC 的词条结构,重挂要读的是清洗完的最终逐字轴。
	migrateLyricTimelines()
	// 存量「用户选定的源」→「手动选定」留痕(2026-09-01,见 manualpickmigrate.go)。
	// ⚠️ 必须排在上面三步**之后**:import / YRC 空白清洗 / 时间轴重挂都会重写 Lyrics 和
	// LyricsYRC,而这一步要按最终内容算指纹。排在它们之前的话指纹当场过期,老用户打开
	// 「手动选定歌词后锁定」照样一首都锁不上,且没有任何迹象。
	migrateManualPickMarks()
	exportLyricsFiles()
	// 本地收听日志:刻意**不带** lastfm-/lb- 这类账号域前缀 —— 这份日志存在的全部意义
	// 就是"不依赖任何账号",挂上某个账号的名字就说反了。
	initListenLog(filepath.Join(filepath.Dir(*cfgPath), clientName+"-listens.jsonl"))
	forwardedPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-forwarded.json")
	lfmMirroredPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-mirrored.json")
	lastfmStatusPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-status.json")
	// 合唱串「智能」档的判定缓存(见 lastfmcollapse.go)。必须在 lastfmScrobblerIfEnabled
	// 之前设好 —— 判定器构造时就读它。backfillcli.go 用同一个文件名,两条路径共读一份。
	lastfmCollapsePath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-collapse.json")
	// collector→App 的 Last.fm「最近记录」feed(见 lastfmfeed.go):桥接每次拉到的
	// recenttracks 落盘,App 读它代替自己直连轮询。
	lastfmFeedPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-recent-feed.json")
	// collector→App 的状态通道(眼下只报"网络不通",见 collectorstatus.go)。设置这个
	// 路径的同时会清掉上次运行留下的文件 —— 那份状态跟这次进程无关。
	setCollectorStatusPath(filepath.Join(filepath.Dir(*cfgPath), clientName+"-collector-status.json"))
	// App 侧"停止搜索"按钮的信号文件路径(见 enrichcancel.go)——跟 Swift 那边
	// LyricsManagerView.cancelPlaceholderSearch 写入的路径逐字节一致。
	setEnrichCancelRequestPath(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-cancel-request.txt"))
	weeklyDigestPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-weekly.json")
	dailyDigestPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lb-daily.json")
	topArtistsStatePath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-top-artists.json")

	lb := &lbClient{root: cfg.APIRoot, token: cfg.Token, hc: &http.Client{}, dryRun: *dryRun, alerter: newAlerter(cfg.NotificationPlatform, cfg.NotificationWebhookURL, cfg.DingtalkSignSecret, cfg.FeishuSignSecret)}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Printf("%s %s starting (bundles: %v, dry-run: %v)",
		clientName, clientVersion, cfg.BundleIDs, *dryRun)
	// 存量设备封面补传。放后台:它只是把已有的图确认/补到中继上,不该挡住 run()。
	// 绝大多数启动里每张都会在 HEAD 那步命中,整个扫描就是几十次廉价的读(见头注)。
	go sweepDeviceArtwork(ctx)
	if err := run(ctx, cfg, lb); err != nil && ctx.Err() == nil {
		log.Fatalf("run: %v", err)
	}
}
