package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// 后台「补空扫描」:不等这首歌再被播到,主动给存量的空歌词条目再搜一轮。
//
// 为什么需要:needsLyricsFirstFill 那条补空路径设计上**只在这首歌再次被播放时**
// 触发(enrich.go trackEnrichment 缓存命中后的分派链)。对"正在听的歌"这是对的——省网络、
// 只修用户真会看到的;但「歌词管理」把全库摊开给用户看,里面躺着的空条目用户不重播就永远
// 不会动。实测 82 条非纯音乐的空条目里,范逸臣《革命》《Dalala-Dila》8-31 首解析时一个源
// 都没应答(偶发网络),五天后手动重搜 QQ 1057 / 971 分——不是没词,是没人再去问过。
//
// 两条触发:
//   - 自动:进程起来 10 分钟后扫一次,之后每 24 小时一次。每轮只处理 needsLyricsFirstFill 为真
//     的(退避到期的)条目、上限 lyricsFillSweepDailyCap 条、两首之间隔 lyricsFillSweepGap
//     (用户点出来的那一轮走更短的 lyricsManualSweepGap,见 lyricsFillSweepPace)——
//     补空本身是"每条最多每天一次、指数退避"的节奏,这里只是把"要不要问"的时机从"被播到"
//     改成"到点了",不改每条的退避账。
//   - 手动:App 侧(「歌词管理」的「重试无歌词条目」按钮)往 lyricsFillRequestPath 写一个
//     请求文件(见 lyricsFillRequest),这里 2 秒内读到就开一轮,**忽略退避**(
//     现在就搜)、不设条数上限,但仍然只碰"没歌词、没人工修正、没确证纯音乐"的条目。
//     进度写到 lyricsFillStatusPath 给界面看(形制同 collectorstatus.go / lastfm 状态通道:
//     collector 落盘、Swift 按 mtime 读,写失败只记日志)。
//
// 逐条串行、中间留间隔,不并发:Musixmatch 匿名 token 对并发 token.get 会 captcha 限流
// (musixmatch.go 头注),一次性起 80 首等于自己把这个源打哑;而且这批歌用户此刻没在听,
// 没有任何理由跟正在播放的那首抢网络。每条都走现成的 retryLyricsUpgrade(firstFill=true)
// ——补空的写回规则(升级 / 纯音乐标记 / 纯文本兜底 / 决策存档 / 计数与退避)全在那里,
// 这个文件只负责"挑哪些、什么时候、报进度"。

const (
	lyricsFillSweepInitialDelay = 10 * time.Minute
	// 续跑用一个**短得多**的延迟,不复用上面那 10 分钟。
	//
	// 那 10 分钟是给**自动**补空扫描的礼貌窗口:没人要求过它,进程刚起来又有一堆缓存要
	// 加载、歌可能正在播,让它靠后是对的。续跑不是那回事 —— 那是用户点过「开始」、被
	// 一次重启打断的那一轮,他已经说过要了。实测:用户点开始跑了 5 分钟,
	// 装新版重启 collector 之后界面上顶着一句「稍后会自动接着跑」却十分钟一动不动,
	// 当场问「怎么没有自动呢」—— 机制是对的,延迟选错了,表现出来就跟坏了一样。
	//
	// 1 分钟够:startLyricsFillSweeper 跑在 run() 里、loadEnrichCache 之后,缓存已经在
	// 内存里了,这一分钟只是给启动那阵子的其它初始化让个路。
	lyricsFullScanResumeDelay = time.Minute
	lyricsFillSweepInterval   = 24 * time.Hour
	lyricsFillSweepGap        = 15 * time.Second
	// 用户点出来的那一轮(手动补搜、全量扫库)单独一档,比自动补空那 15 秒短。
	//
	// 两者的账完全不同:自动补空一轮最多 lyricsFillSweepDailyCap(40)条、一天一次、没人在等,
	// 15 秒×40 才 10 分钟,快不快无所谓;用户点出来的那一轮有人盯着进度。全量是 5300+ 首连着跑,
	// 15 秒 gap 让总时长变成 **26.6 小时**(实测 18 秒/首,其中 15 秒是纯等待),5 秒 → 约 8 秒/首
	// → 约 12 小时;手动补搜一轮上百首,每首的搜索本身就要 8~24 秒(没词的条目会把所有退路走一遍),
	// 15 秒 gap 让它每首约 28 秒,5 秒约 18 秒。见 11 章决策 30。
	//
	// 5 秒这个值的依据是实测各源的真实速率,不是拍脑袋(从 api call summary 读的,
	// 80 秒窗口约 4~5 首):网易云 71 次 ≈ 0.89 req/s、iTunes 68 次 ≈ 0.85、QQ smartbox 60 次
	// ≈ 0.75,**这三个源当时一次 503 都没有**。gap 15→5 让平均速率涨到约 2.3 倍(网易云约
	// 2 req/s),对这种量级的平台仍在安全区。
	//
	// 别把它当"越小越好"的旋钮往下调:一首歌会打出 100+ 个请求、散到十几个主机,gap 是
	// 这些**突发之间**唯一的喘息,而整个采集器没有任何 per-host 限流器(查过,
	// 一个 rate.Limiter 都没有)。真要再往下压,先补限流再说。
	// (musicbrainz 不在此列:它自己有 1.1 秒全局最小间隔 + 结果永久缓存,见 musicbrainz.go。)
	lyricsManualSweepGap           = 5 * time.Second
	lyricsFillSweepDailyCap        = 40
	lyricsFillRequestCheckInterval = 2 * time.Second
	// 一首搜完一个歌词源都没连上(见 lyricSourceRound.reachedAny):原地等这么久再搜同一首,
	// 连续 lyricsFillSweepOfflineLimit 次都这样就停下。75 秒 × 4 次等待 = 5 分钟,盖得住
	// 熔断最长那一档冷却;再往后多半是真断网,接着跑只会让剩下的每一首都白搜一轮。
	lyricsFillSweepOfflineWait  = 75 * time.Second
	lyricsFillSweepOfflineLimit = 5
	// 全量扫库因为断网停下之后,多久再试着接着跑(「待续」标记留着,见 runLyricsFillSweep 出口)。
	lyricsFullScanOfflineResumeDelay = 10 * time.Minute
	// lyricsFullScanHandoffDelay:补空收尾时有一场全量等着,隔多久接着跑。
	lyricsFullScanHandoffDelay = time.Minute
)

var (
	lyricsFillRequestPath string
	lyricsFillStatusPath  string

	lyricsFillSweepMu      sync.Mutex
	lyricsFillSweepRunning bool
	lyricsFillSweepCancel  context.CancelFunc

	// lyricsFillSweepReschedule:扫描那个 goroutine 请 startLyricsFillSweeper 把下一发定时器提前
	// 到给定时长之后(全量扫库断网停下时用)。容量 1、非阻塞发送,多发的丢掉。
	lyricsFillSweepReschedule = make(chan time.Duration, 1)
	// lyricsFillSweepWait 在两首之间 / 断网重试前等待,ctx 取消时立刻返回。单测换成不等。
	lyricsFillSweepWait = func(ctx context.Context, d time.Duration) {
		select {
		case <-ctx.Done():
		case <-time.After(d):
		}
	}
	// lyricsFillSweepRunOne 跑一条。单测换成假的。
	lyricsFillSweepRunOne = func(ctx context.Context, key string, full bool) lyricsSweepOutcome {
		if full {
			return lyricsFullScanOne(ctx, key)
		}
		return lyricsFillSweepOne(ctx, key)
	}
)

// lyricsSweepOutcome:扫描里一条跑完的结果。
type lyricsSweepOutcome struct {
	// filled:这一轮补出了结论 / 真的更新了歌词(计入收据)。
	filled bool
	// offline:真的发出去搜了,但一个歌词源都没连上。这一条没有结论,扫描原地等网络回来再搜它。
	offline bool
	// skipped:轮到它时已经不需要搜了(被删 / 被手改 / 已有词 / 正在别处解析),没发请求。
	skipped bool
	// deferred:只有全量扫库会置。连上了歌词源,但当前歌词的来源没应答,这一轮没法判断、什么都没改
	// (见 rescoreDecidable)。整份候选跑完后再试一次。
	deferred bool
}

// lyricsFillRecent 是最近跑完的一条,给界面列「刚才搜了哪几首、结果如何」。Result 取 filled / missed / skipped /
// deferred;全量扫库那一轮 filled = 歌词更新了、missed = 重选后没变(不是「没找到」)、deferred = 这一轮没法判断,
// 界面按 Full 换措辞和图标。
type lyricsFillRecent struct {
	Key    string `json:"key"`
	Result string `json:"result"`
}

// lyricsFillRecentMax:进度里留最近几条,新的在前。
const lyricsFillRecentMax = 3

func (s *lyricsFillStatus) noteRecent(key string, out lyricsSweepOutcome) {
	result := "missed"
	switch {
	case out.skipped:
		result = "skipped"
	case out.filled:
		result = "filled"
	case out.deferred:
		result = "deferred"
	}
	s.Recent = append([]lyricsFillRecent{{Key: key, Result: result}}, s.Recent...)
	if len(s.Recent) > lyricsFillRecentMax {
		s.Recent = s.Recent[:lyricsFillRecentMax]
	}
}

// lyricsFillStatus 是写给 App 看的进度。Total 是这一轮开工时挑出的条数;Done 含"跑到一半发现
// 已经不需要(被删/被手改/已有词)而跳过"的;Filled 是这一轮真的补出了结论(拿到歌词、或纯音乐
// 标记、或纯文本兜底)的条数。
type lyricsFillStatus struct {
	Running bool `json:"running"`
	Manual  bool `json:"manual"`
	// Full:这一轮是「全量重新扫库」而不是补空(见 lyricsfullscan.go)。界面靠它决定
	// 措辞——两者的 Total 不是一个量级(百 vs 几千),说成同一件事会让人以为补空要跑两天。
	Full   bool `json:"full,omitempty"`
	Total  int  `json:"total"`
	Done   int  `json:"done"`
	Filled int  `json:"filled"`
	// RoundDone:**这一轮**(这个进程这一次开工)跑完了多少条。Done 对全量来说是跨重启的
	// 累计值,拿它配 StartedAt 反推速度会算出荒唐的结果(一开工就"已经跑了三千首"),所以
	// 界面的「大约还要 N 小时」用这个数量速度、用 Total-Done 量剩余。补空那一轮两者相等。
	RoundDone  int    `json:"roundDone,omitempty"`
	Current    string `json:"current,omitempty"`
	StartedAt  int64  `json:"startedAt"`
	UpdatedAt  int64  `json:"updatedAt"`
	FinishedAt int64  `json:"finishedAt,omitempty"`
	Cancelled  bool   `json:"cancelled,omitempty"`
	// Offline:跑着时 = 上一首一个歌词源都没连上、正在等网络回来;停下时 = 因为一直连不上而停下。
	Offline bool `json:"offline,omitempty"`
	// Skipped:Done 里轮到时已经不需要搜、没发请求的条数(Done - Filled - Skipped 就是搜了没找到的)。
	Skipped int `json:"skipped,omitempty"`
	// Deferred:全量扫库里等着最后再试一次的条数(lyricsFullScanState.Deferred 的长度)。
	Deferred int `json:"deferred,omitempty"`
	// Recent:最近跑完的几条,新的在前,见 lyricsFillRecent。
	Recent []lyricsFillRecent `json:"recent,omitempty"`
}

// setLyricsFillPaths 在 main() 启动时调一次。顺带清掉上一次运行遗留的请求/状态文件:请求跟这次
// 进程无关(理由同 setEnrichCancelRequestPath),状态则是上一轮的陈旧进度。
func setLyricsFillPaths() {
	lyricsFillRequestPath = configFilePath(clientName + "-lyrics-fill-request.txt")
	lyricsFillStatusPath = configFilePath(clientName + "-lyrics-fill-status.json")
	_ = os.Remove(lyricsFillRequestPath)
	_ = os.Remove(lyricsFillStatusPath)
	// 全量扫库那份状态文件**不在**上面的清理范围里 —— 它记的正是"上一个进程没跑完的
	// 那一轮",删掉就等于每次重启都放弃续跑。见 lyricsfullscan.go 头注。
	setLyricsFullScanStatePath(configFilePath(clientName + "-lyrics-fullscan.json"))
	// 播放器署名纠正:App 必须跟 collector 用同一个署名,否则歌词缓存 key 对不上
	// (见 playerartistfix.go)。
	setPlayerArtistFixPath(configFilePath(clientName + "-player-artist-fix.json"))
	setPlayerPreviewFixPath(configFilePath(clientName + "-player-preview.json"))
	// App 与 collector 共享的限流窗口(sharedcooldown.go),App 侧读写同名文件。
	setSharedCooldownPath(configFilePath(clientName + "-outbound-cooldowns.json"))
}

// startLyricsFillSweeper 由 run() 单开一个 goroutine(跟 startEnrichCancelWatcher 同款),
// ctx 取消时退出。两个节奏合在一个循环里:定时器管自动扫描,ticker 管请求文件。
// 每一轮扫描都另起 goroutine 跑——这个循环必须一直转着读请求文件,否则一轮几十分钟的
// 手动扫描期间用户写下的 "cancel" 要等扫完才被看到,等于没有取消。一次只允许一轮在跑,
// 期间再来的请求由 runLyricsFillSweep 开头那道闸拒掉(并记日志),不排队——用户点两下不该跑两遍。
// lyricsFillSweepFirstDelay 决定第一发定时器等多久。抽成纯函数是因为这里**选错常量完全
// 不报错**:扫描照跑、日志照写,只是晚十分钟 —— 就是这么错的一次(见
// lyricsFullScanResumeDelay 头注)。单测把这两档钉死。
// lyricsFillSweepPace 决定两首之间隔多久:按"是不是用户点出来的"分档,不按全量 / 补空分。
// 抽成纯函数的理由跟下面 lyricsFillSweepFirstDelay 一模一样:**选错常量完全不报错**——扫描照跑、
// 进度照涨,只是多花几十分钟到十几个小时。单测把两档钉死。
func lyricsFillSweepPace(manual bool) time.Duration {
	if manual {
		return lyricsManualSweepGap
	}
	return lyricsFillSweepGap
}

func lyricsFillSweepFirstDelay(resumingFullScan bool) time.Duration {
	if resumingFullScan {
		return lyricsFullScanResumeDelay
	}
	return lyricsFillSweepInitialDelay
}

func startLyricsFillSweeper(ctx context.Context) {
	if lyricsFillRequestPath == "" {
		return
	}
	// 上一个进程有一轮全量扫库没跑完的话,第一发定时器提前到 lyricsFullScanResumeDelay ——
	// 那一轮是用户点出来的,不该陪着自动补空一起等 10 分钟。见 lyricsfullscan.go「跨重启续跑」。
	next := time.NewTimer(lyricsFillSweepFirstDelay(lyricsFullScanActive()))
	defer next.Stop()
	poll := time.NewTicker(lyricsFillRequestCheckInterval)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-next.C:
			req := lyricsFillRequest{}
			// **每一发**都重新看盘上那个标记,而不是启动时读一次就消费掉:这一发万一正好
			// 撞上别的一轮在跑(runLyricsFillSweep 开头那道闸会把它拒掉、且不碰标记),
			// 一次性的标志位就把续跑意图永久丢了,界面会一直顶着「稍后会自动接着跑」。
			// 重新读一次,下一发还能接着试。
			if lyricsFullScanActive() {
				// manual:续跑仍然是用户点出来的那一轮,照样忽略退避、不设条数上限。
				req = lyricsFillRequest{manual: true, full: true}
				slog.Info("lyrics full scan: resuming the round left over from a previous process")
			}
			go runLyricsFillSweep(ctx, req)
			next.Reset(lyricsFillSweepInterval)
		case d := <-lyricsFillSweepReschedule:
			if !next.Stop() {
				select {
				case <-next.C:
				default:
				}
			}
			next.Reset(d)
		case <-poll.C:
			publishLyricsFullScanPending()
			req, ok := readLyricsFillRequest()
			if !ok {
				continue
			}
			if req.cancel {
				cancelLyricsFillSweep()
				continue
			}
			go runLyricsFillSweep(ctx, req)
		}
	}
}

// lyricsFillRequest 是请求文件解出来的内容。文件格式(纯文本,App 侧 LyricsManagerView 写):
//   - 一行 "all":全部符合条件的空条目;
//   - 一行 "full":全量重新扫库(见 lyricsfullscan.go),范围比 "all" 大得多;
//   - 一行 "cancel":停掉正在跑的这一轮;
//   - 否则每行一个缓存 key("artist|title|album",跟 EnrichCacheKeys 同一个 key 空间)。
//
// 旧版 collector 碰上 "full" 会把它当成一个普通的 key —— 缓存里没有叫 "full" 的条目,
// 于是挑出 0 条候选、这一轮空跑结束。降级成"什么都不做",不会误伤任何数据。
type lyricsFillRequest struct {
	manual bool
	cancel bool
	all    bool
	full   bool
	keys   map[string]bool
}

func parseLyricsFillRequest(text string) lyricsFillRequest {
	req := lyricsFillRequest{manual: true}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "":
		case line == "all":
			req.all = true
		case line == "full":
			req.full = true
		case line == "cancel":
			req.cancel = true
		default:
			if req.keys == nil {
				req.keys = map[string]bool{}
			}
			req.keys[line] = true
		}
	}
	return req
}

// readLyricsFillRequest 读一次请求文件并无条件消费掉(一次性信号,同 checkEnrichCancelRequest)。
func readLyricsFillRequest() (lyricsFillRequest, bool) {
	data, err := claimRequestFile(lyricsFillRequestPath)
	if err != nil {
		return lyricsFillRequest{}, false
	}
	req := parseLyricsFillRequest(string(data))
	if !req.all && !req.full && !req.cancel && len(req.keys) == 0 {
		return lyricsFillRequest{}, false
	}
	return req, true
}

// lyricsFillSweepCandidates 在锁内挑出这一轮要处理的 key,按字典序排好(确定、可复现)。
// 三道硬闸对两种触发都生效:有歌词的、人工修正过的、确证纯音乐的一律不碰——这跟
// needsLyricsFirstFill 的前三行同一口径。退避只对自动扫描生效;手动请求是用户明确要现在搜。
// 正在飞的(enrichInflight)跳过:那条此刻已经有人在查。
func lyricsFillSweepCandidates(req lyricsFillRequest) []string {
	// 全量扫库的口径完全不同(三层、多一道 pin 闸、按收益排序),整个交给那边。
	if req.full {
		return lyricsFullScanCandidates()
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	var polluted map[string]bool
	if !req.manual {
		polluted = lyricsPollutedKeys(enrichCache)
	}
	var keys []string
	for key, e := range enrichCache {
		if req.keys != nil && !req.keys[key] {
			continue
		}
		if e.Lyrics != "" || e.ManualLyrics || e.Instrumental || enrichInflight[key] {
			continue
		}
		if !req.manual && !needsLyricsFirstFill(e) {
			continue
		}
		// 自动这一轮跳过再搜也不会有的,见 lyricsretryskip.go;手动点了就照搜。
		if !req.manual && (lyricsNoAnchorGaveUp(key, e) || polluted[key]) {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if !req.manual && len(keys) > lyricsFillSweepDailyCap {
		keys = keys[:lyricsFillSweepDailyCap]
	}
	return keys
}

// cancelLyricsFillSweep 停掉正在跑的这一轮。
//
// 顺带清掉全量扫库的"待续"标记,而且**只能**在这里清 —— 扫描循环的出口分不清"用户
// 按了停止"和"进程正在关机"(两者都是 ctx 被取消),放在那里会让每次重启都把该续的一轮
// 擦掉。这里是用户按停止的唯一入口,语义明确:他不想要了。见 lyricsfullscan.go 头注。
//
// 无条件清,不看此刻有没有一轮在跑:请求文件的轮询和扫描是两个 goroutine,用户完全可能在
// 进程刚起来、续跑还没被触发的那 10 分钟里按下停止,那时 lyricsFillSweepRunning 还是 false。
func cancelLyricsFillSweep() {
	setLyricsFullScanActive(false)
	lyricsFillSweepMu.Lock()
	defer lyricsFillSweepMu.Unlock()
	if lyricsFillSweepRunning && lyricsFillSweepCancel != nil {
		lyricsFillSweepCancel()
	}
}

// runLyricsFillSweep 跑一轮。同一时刻只允许一轮在跑。
func runLyricsFillSweep(parent context.Context, req lyricsFillRequest) {
	lyricsFillSweepMu.Lock()
	if lyricsFillSweepRunning {
		lyricsFillSweepMu.Unlock()
		// 全量那一发(用户点的,或进程重启后的续跑)撞上了正在跑的补空:记下「待续」,这一轮收尾时接着跑
		// (见下面 defer),别静默丢掉、等一整天。
		if req.full {
			setLyricsFullScanActive(true)
		}
		slog.Info("lyrics fill sweep: already running, ignoring new request", "manual", req.manual, "full", req.full)
		return
	}
	ctx, cancel := context.WithCancel(parent)
	lyricsFillSweepRunning = true
	lyricsFillSweepCancel = cancel
	lyricsFillSweepMu.Unlock()
	defer func() {
		cancel()
		lyricsFillSweepMu.Lock()
		lyricsFillSweepRunning = false
		lyricsFillSweepCancel = nil
		lyricsFillSweepMu.Unlock()
		// 这一轮是补空,跑的时候有一场全量等着(续跑或用户点的那一发被上面拒掉了):收尾就接着跑。
		if !req.full && lyricsFullScanActive() {
			select {
			case lyricsFillSweepReschedule <- lyricsFullScanHandoffDelay:
			default:
			}
		}
	}()

	// 挑候选**之前**就把"待续"标记置上:候选列表几千条、一轮要跑一两天,进程在这中间
	// 任何一刻被杀都得能续上。置在后面的话,刚起步那几十秒被杀就白点了。
	if req.full {
		setLyricsFullScanActive(true)
	}
	keys := lyricsFillSweepCandidates(req)
	var deferred []string
	if req.full {
		deferred = pruneLyricsFullScanDeferred(keys)
	}
	status := lyricsFillStatus{
		Running: true, Manual: req.manual, Full: req.full,
		Total: len(keys), StartedAt: time.Now().Unix(),
	}
	// 全量的分母/分子跨重启、跨"停一下再点"累计(见 lyricsFullScanProgressBase);补空那一轮
	// 不走这条 —— 它一轮就是一轮,没有"续跑"这回事。
	if req.full {
		status.Total, status.Done, status.Filled = lyricsFullScanBaseline(len(keys))
		status.Deferred = len(deferred)
	}
	writeLyricsFillStatus(status)
	slog.Info("lyrics fill sweep: start", "manual", req.manual, "full", req.full, "candidates", len(keys), "deferred", len(deferred))
	if len(keys) == 0 && len(deferred) == 0 {
		status.Running = false
		status.FinishedAt = time.Now().Unix()
		writeLyricsFillStatus(status)
		// 一条候选都没有 = 全库已经追平,这一轮就此了结,别留着标记让下次启动再空跑一遍。
		if req.full {
			setLyricsFullScanActive(false)
			resetLyricsFullScanProgress()
		}
		return
	}
	status = runLyricsFillSweepKeys(ctx, keys, req.full, lyricsFillSweepPace(req.manual), status)
	if req.full && !status.Cancelled && !status.Offline {
		status = runLyricsFullScanDeferredKeys(ctx, lyricsFillSweepPace(req.manual), status)
	}
	status.Running = false
	status.Current = ""
	status.FinishedAt = time.Now().Unix()
	writeLyricsFillStatus(status)
	// 断网停下的全量扫库:「待续」标记留着(下面那个分支不走),10 分钟后让定时器再试一次。
	if req.full && status.Offline {
		select {
		case lyricsFillSweepReschedule <- lyricsFullScanOfflineResumeDelay:
		default:
		}
	}
	// 整份候选列表跑完了才清"待续"。被取消的两种情形都不在这里清:用户按停止由
	// cancelLyricsFillSweep 负责,进程关机则**必须**留着标记等下次续跑 —— 这里分不清
	// 这两者(都只表现为 ctx 被取消),所以这个分支只认"没被取消"。断网停下的同样留着。
	// 见 lyricsfullscan.go 头注。
	if req.full && !status.Cancelled && !status.Offline {
		setLyricsFullScanActive(false)
		// 整份候选列表跑完 = 这一场全量结束,累计分母/分子就此清零,下次点「开始」是新的一场。
		// 被取消的两种情形都不走这里,累计值留在盘上等着接着数。
		resetLyricsFullScanProgress()
	}
	slog.Info("lyrics fill sweep: done", "manual", req.manual, "full", req.full, "total", status.Total, "done", status.Done, "filled", status.Filled, "cancelled", status.Cancelled)
}

// runLyricsFillSweepKeys 逐条跑 keys,返回跑完(或停下)那一刻的状态。
//
// 一条搜完一个歌词源都没连上(outcome.offline)时不往下走:这一条不算进度,等
// lyricsFillSweepOfflineWait 再搜它;连续 lyricsFillSweepOfflineLimit 次都这样就停下、标 Offline。
// 往下走的话,断网期间剩下的每一首都会白搜一轮,收据上还显示成「搜了、没补出来」。
// 搜到一半被停(ctx 取消)的那一条什么都没写,同样不算进度。
func runLyricsFillSweepKeys(ctx context.Context, keys []string, full bool, gap time.Duration, status lyricsFillStatus) lyricsFillStatus {
	return runSweepKeys(ctx, keys, full, false, gap, status)
}

// runLyricsFullScanDeferredKeys 是全量扫库的收尾:把主循环里「没法判断」的那几首(lyricsFullScanState.Deferred)
// 各再试一次。只试这一次,再没法判断就放下 —— 日志里同一首接连没法判断的,多半是当前来源已经不收录它了,
// 再试也一样。断网停下、被取消时没试到的留在名单里,续跑时接着试。
func runLyricsFullScanDeferredKeys(ctx context.Context, gap time.Duration, status lyricsFillStatus) lyricsFillStatus {
	keys := readLyricsFullScanState().Deferred
	status.Deferred = len(keys)
	if len(keys) == 0 {
		return status
	}
	slog.Info("lyrics full scan: retrying deferred", "count", len(keys))
	return runSweepKeys(ctx, keys, true, true, gap, status)
}

// runSweepKeys:retry = true 是全量扫库收尾那一遍(runLyricsFullScanDeferredKeys),这些条目在 Done 里已经
// 算过一次,只更新 Filled 和待再试名单。
func runSweepKeys(ctx context.Context, keys []string, full, retry bool, gap time.Duration, status lyricsFillStatus) lyricsFillStatus {
	offlineStreak := 0
	var wait time.Duration
	if retry {
		wait = gap
	}
	for i := 0; i < len(keys); {
		if wait > 0 {
			lyricsFillSweepWait(ctx, wait)
		}
		if ctx.Err() != nil {
			status.Cancelled = true
			break
		}
		status.Current = keys[i]
		writeLyricsFillStatus(status)
		out := lyricsFillSweepRunOne(ctx, keys[i], full)
		if ctx.Err() != nil {
			status.Cancelled = true
			break
		}
		if out.offline {
			offlineStreak++
			status.Offline = true
			if offlineStreak >= lyricsFillSweepOfflineLimit {
				slog.Warn("lyrics fill sweep: no lyric source reachable, stopping", "attempts", offlineStreak, "key", keys[i])
				if full {
					releaseLyricsFullScanAttempt(keys[i])
				}
				break
			}
			writeLyricsFillStatus(status)
			wait = lyricsFillSweepOfflineWait
			continue
		}
		offlineStreak = 0
		status.Offline = false
		if out.filled {
			status.Filled++
		}
		status.noteRecent(keys[i], out)
		status.Current = ""
		switch {
		case retry:
			status.Deferred = dropLyricsFullScanDeferred(keys[i])
		default:
			if out.skipped {
				status.Skipped++
			}
			if full && out.deferred {
				status.Deferred = noteLyricsFullScanDeferred(keys[i])
			}
			status.Done++
			status.RoundDone++
		}
		// 先落盘再写状态:进程在这两行之间被杀时,宁可界面少算一条,也不要续跑时把已经
		// 跑过的那条重新算进"还剩"。
		if full {
			saveLyricsFullScanProgress(status.Done, status.Filled)
		}
		writeLyricsFillStatus(status)
		i++
		wait = gap
	}
	return status
}

// lyricsFillSweepOne 对一条走一次补空。进门再核一遍资格:挑候选到轮到它可能隔了几十分钟,
// 期间它可能被播到(自己补上了)、被用户手改/删除 —— 那种情形什么都不做,也不算断网。
func lyricsFillSweepOne(ctx context.Context, key string) lyricsSweepOutcome {
	artist, title, album := splitEnrichKey(key)
	enrichMu.Lock()
	before, ok := enrichCache[key]
	if !ok || before.Lyrics != "" || before.ManualLyrics || before.Instrumental || enrichInflight[key] {
		enrichMu.Unlock()
		return lyricsSweepOutcome{skipped: true}
	}
	dur := before.ResolvedDurationSecs
	if dur <= 0 {
		dur = before.DurationSecs
	}
	enrichInflight[key] = true
	enrichMu.Unlock()
	// 外层套一个 round:里层 retryLyricsUpgrade 那一轮连上过哪个源会传上来(见 markReached)。
	roundCtx, round := withLyricSourceRound(ctx)
	// 同步跑:retryLyricsUpgrade 自己负责清 enrichInflight、落盘、导出、通知重推。
	retryLyricsUpgrade(withBackgroundOutbound(roundCtx), key, artist, title, album, dur, true)
	enrichMu.Lock()
	after := enrichCache[key]
	enrichMu.Unlock()
	return lyricsSweepOutcome{
		filled:  after.Lyrics != "" || after.Instrumental || (after.PlainLyrics != "" && before.PlainLyrics == ""),
		offline: !round.reachedAny(),
	}
}

func writeLyricsFillStatus(s lyricsFillStatus) {
	if lyricsFillStatusPath == "" {
		return
	}
	s.UpdatedAt = time.Now().Unix()
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	if err := writeFileAtomic(lyricsFillStatusPath, data); err != nil {
		slog.Warn("lyrics fill sweep: status write failed", "err", err)
	}
}
