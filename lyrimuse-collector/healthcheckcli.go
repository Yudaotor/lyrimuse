package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// `collector healthcheck`:一次性子命令,回答"歌词为什么不出来"。
//
// 排查这件事以前只有两条路:翻 ~/Library/Logs/lyrimuse.log,或者猜。而链路上能坏的地方
// 分散在好几层——配置解析、功能开关、缓存文件、歌词导出目录的写权限、各歌词源各自的
// 可达性、网络本身。这个子命令把它们一次性问一遍。
//
// 网络这部分故意**不**去逐个 ping 各家的域名,而是拿真实的搜索路径跑两首探测曲,看哪些源
// 给得出候选。"这个源现在能不能给我歌词"才是用户关心的问题,而端点通不通只是它的一个
// 必要条件 —— 接口改版、签名失效、地区封锁这些都能让"域名通着但一条歌词也拿不到"。
//
// 探测曲用两首(一首华语一首英文)再取并集:LRCLIB/Musixmatch 的库以英文为主,
// NetEase/QQ/酷狗以中文为主,任何单独一首都会让另一半源"查不到"而被误报成故障。
//
// 选探测曲不能只挑"够红",加 kuwo 时踩过——酷我搜索结果对越红、越被
// 翻唱/改编到泛滥的歌命中率反而越低(具体见下面 probes 变量旁的注释),挑一首传唱度高
// 但没有被淹没在翻唱堆里的歌才靠得住。
type healthStatus string

const (
	healthOK   healthStatus = "ok"
	healthWarn healthStatus = "warn"
	healthFail healthStatus = "fail"
)

type healthCheckItem struct {
	Name   string       `json:"name"`
	Status healthStatus `json:"status"`
	Detail string       `json:"detail"`
}

type healthReport struct {
	Items            []healthCheckItem `json:"items"`
	NetworkLooksDown bool              `json:"networkLooksDown"`
	OK               bool              `json:"ok"`
}

func runHealthcheckCLI(args []string) {
	fs := flag.NewFlagSet("healthcheck", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "output JSON instead of text")
	skipNetwork := fs.Bool("local-only", false, "skip the lyric source probes (no network)")
	probeTimeout := fs.Duration("probe-timeout", healthProbeBudget, "time limit for the lyric source probes")
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}
	if *probeTimeout <= 0 {
		fmt.Fprintf(os.Stderr, "healthcheck: -probe-timeout must be positive\n")
		os.Exit(2)
	}

	if configDir() == "" {
		fmt.Fprintf(os.Stderr, "healthcheck: 拿不到家目录(LYRIMUSE_CONFIG_DIR 也没设)\n")
		os.Exit(1)
	}
	configDir := configDir()
	cfgPath := filepath.Join(configDir, "config.json")

	var report healthReport
	add := func(name string, status healthStatus, format string, a ...any) {
		report.Items = append(report.Items, healthCheckItem{
			Name: name, Status: status, Detail: fmt.Sprintf(format, a...),
		})
	}

	// ---- 本地:不联网、结论确定的部分先跑完 ----
	cfg, err := loadConfig(cfgPath)
	switch {
	case err != nil:
		// loadConfig 只在"文件在但读不出来"时才返回错误(内容有问题会降级,见它的注释)。
		add("配置文件", healthFail, "%v", err)
		cfg = &config{}
	case len(cfg.loadIssues) > 0:
		add("配置文件", healthWarn, "%d 个字段被跳过: %s",
			len(cfg.loadIssues), strings.Join(cfg.loadIssues, "; "))
	default:
		add("配置文件", healthOK, "%s", cfgPath)
	}

	setFeatures(loadFeatureFlags(filepath.Join(configDir, clientName+"-features.json")))
	enabled := enabledLyricSourceNames()
	if len(enabled) == 0 {
		add("歌词来源开关", healthFail, "一个源都没启用,永远不会有歌词")
	} else {
		add("歌词来源开关", healthOK, "已启用 %s", strings.Join(enabled, "/"))
	}

	// 缓存文件:能不能解析比大小重要 —— 解析不了等于每首歌都要重查。
	cachePath := filepath.Join(configDir, clientName+"-enrich-cache.json")
	if data, err := os.ReadFile(cachePath); err != nil {
		if os.IsNotExist(err) {
			add("歌词缓存", healthWarn, "还没有缓存文件(第一次运行时正常)")
		} else {
			add("歌词缓存", healthFail, "读不了: %v", err)
		}
	} else {
		var m map[string]json.RawMessage
		if err := json.Unmarshal(data, &m); err != nil {
			add("歌词缓存", healthFail, "解析失败,每首歌都会被重新解析一遍: %v", err)
		} else {
			add("歌词缓存", healthOK, "%d 条", len(m))
		}
	}

	// 播放状态:collector 认「此刻在放什么」只读 App 写的这一份,不可用时待机(见 appsource.go)。
	stateRec, stateAvail := newAppStateReader(filepath.Join(configDir, clientName+"-playback-state.json")).read(time.Now())
	switch stateAvail {
	case appStateAvailable:
		add("播放状态", healthOK, "读 App 写的播放状态(%.1f 秒前写入,%s)",
			time.Since(time.UnixMilli(stateRec.WrittenAtMs)).Seconds(), stateRec.State)
	case appStateMissing:
		add("播放状态", healthWarn, "App 还没写过播放状态,collector 在待机:不推送正在播放、不记收听")
	default:
		add("播放状态", healthWarn, "App 的播放状态不可用(%s),collector 在待机:不推送正在播放、不记收听", stateAvail)
	}

	// 靠解析网页 / 客户端本地文件取数的路径:常驻实例把连续认不出的记在这份文件里(parserdrift.go)。
	// 这些路径坏了会安静地退回备用,只有这里看得出上游改了版。
	if drift := loadParserDriftFile(filepath.Join(configDir, clientName+"-parser-drift.json")); len(drift) == 0 {
		add("网页与本地文件解析", healthOK, "没有连续认不出的路径")
	} else {
		names := make([]string, 0, len(drift))
		for name := range drift {
			names = append(names, name)
		}
		sort.Strings(names)
		parts := make([]string, 0, len(names))
		for _, name := range names {
			e := drift[name]
			parts = append(parts, fmt.Sprintf("%s 连续 %d 次认不出(自 %s;%s)",
				name, e.Streak, time.Unix(e.FirstAt, 0).Format("2006-01-02 15:04"), e.Detail))
		}
		add("网页与本地文件解析", healthWarn, "上游可能改版,已退回备用路径:%s", strings.Join(parts, ";"))
	}

	// 歌词导出目录:写不进去的话"歌词文件夹作为权威源"整条链路是坏的,而它不会有任何
	// 显式报错 —— 只是每次导出都静默失败。
	dir := features().LyricsDir
	if dir == "" {
		dir = filepath.Join(configDir, "lyrics")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		add("歌词导出目录", healthFail, "建不了 %s: %v", dir, err)
	} else {
		probe := filepath.Join(dir, ".lyrimuse-healthcheck-write-probe")
		if err := os.WriteFile(probe, []byte("probe"), 0o600); err != nil {
			add("歌词导出目录", healthFail, "%s 写不进去: %v", dir, err)
		} else {
			os.Remove(probe)
			n := 0
			if entries, err := os.ReadDir(dir); err == nil {
				for _, e := range entries {
					if strings.HasSuffix(strings.ToLower(e.Name()), ".lrc") {
						n++
					}
				}
			}
			add("歌词导出目录", healthOK, "%s(%d 个 .lrc,可写)", dir, n)
		}
	}

	// 提交后端是可选的 —— 没配不影响歌词，只是不往外提交，所以是 warn 不是 fail。
	if cfg.Token == "" {
		add("ListenBrainz", healthWarn, "未配置 token,不会提交收听(不影响歌词显示)")
	} else {
		add("ListenBrainz", healthOK, "已配置 token,api_root=%s", cfg.APIRoot)
	}
	switch {
	case cfg.LastfmScrobbleSessionKey != "":
		add("Last.fm", healthOK, "已授权,会镜像写入")
	case cfg.LastfmUser != "" && cfg.lastfmBridgeAPIKey() != "":
		add("Last.fm", healthOK, "已配置读取(iPhone 播放桥接可用),未授权写入")
	default:
		add("Last.fm", healthWarn, "未配置(不影响歌词显示)")
	}

	// ---- 网络:拿真实搜索路径探两首 ----
	if !*skipNetwork {
		// 中文探测曲从《晴天》(周杰伦)换成《少年》(梦然):酷我(kuwo)接入后
		// 暴露出一个跟"能不能连通"无关的结构性问题——酷我搜索对**越红越被翻唱/改编到
		// 泛滥**的歌命中率反而越低(前排全是 DJ 改编/伴奏/演唱会现场,原唱裸版本挤不进去),
		// 《晴天》《稻香》《童话》《Yesterday》《Shape of You》这类超级热门曲目实测全部
		// 落空,导致 healthcheck 对 kuwo 常年报"两首探测曲都没有候选,这个源目前可能不可用"
		// ——而 kuwo 的网络连通性其实完全正常,只是这两首探测曲恰好踩中它的已知短板,不是
		// 真故障。《少年》(梦然)是同样传唱度极高的网络时代金曲,但实测在酷我搜索结果里
		// 排第一的就是原唱本人的完整单曲(带 MV 副标题),能通过跟其它源同一套身份闸;同时
		// 保留了对中文库其它源(netease/qq/kugou/musixmatch/amll)一贯的高命中率,不会让
		// 探测曲的目的从"测连通性"退化成"测某个源的曲库覆盖率"。英文探测曲(Yesterday)
		// 未受影响、原样保留——kuwo 对英文曲库本来就没有覆盖,不指望这首帮它过关。
		probes := []healthProbeTrack{
			{"梦然", "少年", ""},                      // 中文库
			{"The Beatles", "Yesterday", "Help!"}, // 英文库
		}
		outcome := probeLyricSourcesWithin(probes, *probeTimeout, healthProbeGrace)
		report.NetworkLooksDown = networkLooksDown()
		report.Items = append(report.Items,
			healthProbeItems(enabled, len(probes), outcome, *probeTimeout, report.NetworkLooksDown)...)
	}

	report.OK = true
	for _, it := range report.Items {
		if it.Status == healthFail {
			report.OK = false
		}
	}

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(report)
	} else {
		width := 0
		for _, it := range report.Items {
			if n := displayWidth(it.Name); n > width {
				width = n
			}
		}
		for _, it := range report.Items {
			fmt.Printf("  %-4s %s%s  %s\n", it.Status,
				it.Name, strings.Repeat(" ", width-displayWidth(it.Name)), it.Detail)
		}
		fmt.Println()
		if report.OK {
			fmt.Println("没有发现会导致歌词不显示的问题。")
		} else {
			fmt.Println("有 fail 项 —— 上面标 fail 的那几条会直接导致歌词出不来。")
		}
	}
	if !report.OK {
		os.Exit(1)
	}
}

// 联网探测的时限:几首探测曲一共给 healthProbeBudget,到点取消、按已经回来的结果出报告;取消之后最多再等
// healthProbeGrace 让搜索收尾,还没回来的不等了。诊断导出给整个子命令 15 秒并显式传 -probe-timeout
// (Core DiagnosticsHealthCheck),本地检查不到 1 秒:时限 + 收尾 + 本地检查必须留在那 15 秒以内,两处一起改。
const (
	healthProbeBudget = 10 * time.Second
	healthProbeGrace  = 2 * time.Second
)

type healthProbeTrack struct{ artist, title, album string }

// healthProbeSearch 是联网探测实际发的那次搜索。单测换成假的。
var healthProbeSearch = func(ctx context.Context, p healthProbeTrack) []scoredLyricCandidateResult {
	qa, qt, qal := searchQueryFields(p.artist, p.title, p.album)
	_, scored := scoredLyricCandidates(ctx, qa, qt, qal, 0)
	return scored
}

type healthProbeOutcome struct {
	answered  map[string]int // 源 → 给出过候选的探测曲数,不看分数(跟 test-lyric-sources 同一口径)
	elapsed   time.Duration
	truncated bool // 时限到了还没跑完
}

// probeLyricSourcesWithin 让几首探测曲并发跑、共用一个时限。到点用 cancel 收工,别换成 context.WithTimeout:
// 到点的请求会报 DeadlineExceeded,被记成网络失败、喂进熔断,全部卡住时还会被 networkLooksDown 判成网络不通;
// 主动取消(context.Canceled)这几处都不算(见 doHTTPTracked)。
func probeLyricSourcesWithin(probes []healthProbeTrack, budget, grace time.Duration) healthProbeOutcome {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	start := time.Now()
	search := healthProbeSearch
	results := make(chan []scoredLyricCandidateResult, len(probes))
	for _, p := range probes {
		go func(p healthProbeTrack) { results <- search(ctx, p) }(p)
	}
	out := healthProbeOutcome{answered: map[string]int{}}
	budgetTimer := time.NewTimer(budget)
	defer budgetTimer.Stop()
	var giveUp <-chan time.Time
	for pending := len(probes); pending > 0; {
		select {
		case scored := <-results:
			pending--
			for _, src := range lyricSourcesResponded(scored) {
				out.answered[src]++
			}
		case <-budgetTimer.C:
			out.truncated = true
			cancel()
			giveUp = time.After(grace)
		case <-giveUp:
			pending = 0
		}
	}
	out.elapsed = time.Since(start).Round(time.Millisecond)
	return out
}

// healthProbeItems 把联网探测的结果写成报告项。
//
// 单个源坏掉不等于"歌词出不来"——还有别的源。所以单源只报 warn,只有**所有**启用的源都哑了才是 fail。
// 分级要对得上这个命令要回答的问题("歌词为什么不出来"),否则一个长期失效的源会让 healthcheck 常年顶着
// fail,那个信号就不值钱了。探测被时限截断时,没给出候选只说明这段时间里没回,不报"可能不可用",也不报 fail。
func healthProbeItems(enabled []string, probes int, o healthProbeOutcome, budget time.Duration, networkDown bool) []healthCheckItem {
	var items []healthCheckItem
	add := func(name string, status healthStatus, format string, a ...any) {
		items = append(items, healthCheckItem{Name: name, Status: status, Detail: fmt.Sprintf(format, a...)})
	}
	switch {
	case networkDown:
		add("网络", healthFail, "所有请求都发不出去(DNS/连接失败),歌词解析这一轮全部无效")
	case o.truncated:
		add("网络", healthWarn, "探测 %d 首超过 %s 没跑完,已截断:网络可能很慢,下面没给出候选的源不一定坏了", probes, budget)
	default:
		add("网络", healthOK, "探测 %d 首用时 %s", probes, o.elapsed)
	}
	dead := 0
	for _, src := range enabled {
		n := o.answered[src]
		switch {
		case n == probes:
			add("源 "+src, healthOK, "%d/%d 首探测曲给出了候选", n, probes)
		case n > 0 && o.truncated:
			add("源 "+src, healthOK, "%d/%d 首(探测被截断,另一首可能没来得及)", n, probes)
		case n > 0:
			// 一半命中是正常的：中文源查不到英文歌，反之亦然。
			add("源 "+src, healthOK, "%d/%d 首(另一首不在它的曲库里属正常)", n, probes)
		case o.truncated:
			dead++
			add("源 "+src, healthWarn, "%s 内没给出候选(探测被截断,不一定坏了)", budget)
		default:
			dead++
			add("源 "+src, healthWarn, "两首探测曲都没有候选,这个源目前可能不可用")
		}
	}
	switch {
	case dead > 0 && dead == len(enabled) && o.truncated:
		add("歌词源整体", healthWarn, "%d 个启用的源在 %s 内都没给出候选,网络很慢时歌词会出得很慢", dead, budget)
	case dead > 0 && dead == len(enabled):
		add("歌词源整体", healthFail, "%d 个启用的源全部没有候选,歌词不会出现", dead)
	case dead > 0 && o.truncated:
		add("歌词源整体", healthOK, "%d/%d 个源在 %s 内给出了候选,歌词功能正常", len(enabled)-dead, len(enabled), budget)
	case dead > 0:
		add("歌词源整体", healthOK, "%d/%d 个源可用,歌词功能正常", len(enabled)-dead, len(enabled))
	}
	return items
}

// enabledLyricSourceNames 返回当前设置里启用的歌词源,顺序固定,便于比对输出。
func enabledLyricSourceNames() []string {
	var out []string
	for _, name := range lyricSourceNames {
		if lyricSourceEnabled(name) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// displayWidth 按**终端显示列数**算宽度,不是 rune 数 —— 中日韩表意文字和全角标点在等宽
// 终端里占两列,拿 rune 数补空格会让中英混排的那几行歪掉。
func displayWidth(s string) int {
	w := 0
	for _, r := range s {
		switch {
		case r >= 0x1100 && r <= 0x115F, // 韩文字母
			r >= 0x2E80 && r <= 0xA4CF, // 部首扩展 ~ 注音、CJK 统一表意
			r >= 0xAC00 && r <= 0xD7A3, // 韩文音节
			r >= 0xF900 && r <= 0xFAFF, // CJK 兼容表意
			r >= 0xFE30 && r <= 0xFE6F, // CJK 兼容形式
			r >= 0xFF00 && r <= 0xFF60, // 全角 ASCII
			r >= 0xFFE0 && r <= 0xFFE6:
			w += 2
		default:
			w++
		}
	}
	return w
}
