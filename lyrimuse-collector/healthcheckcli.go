package main

import (
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
// 分散在好几层——配置解析、功能开关、缓存文件、歌词导出目录的写权限、五个歌词源各自的
// 可达性、网络本身。这个子命令把它们一次性问一遍。
//
// 网络这部分故意**不**去逐个 ping 各家的域名,而是拿真实的搜索路径跑两首探测曲,看哪些源
// 给得出候选。"这个源现在能不能给我歌词"才是用户关心的问题,而端点通不通只是它的一个
// 必要条件 —— 接口改版、签名失效、地区封锁这些都能让"域名通着但一条歌词也拿不到"。
//
// 探测曲用两首(一首华语一首英文)再取并集:LRCLIB/Musixmatch 的库以英文为主,
// NetEase/QQ/酷狗以中文为主,任何单独一首都会让另一半源"查不到"而被误报成故障。
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
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: 拿不到家目录: %v\n", err)
		os.Exit(1)
	}
	configDir := filepath.Join(home, ".config", clientName)
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

	features = loadFeatureFlags(filepath.Join(configDir, clientName+"-features.json"))
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

	// 歌词导出目录:写不进去的话"歌词文件夹作为权威源"整条链路是坏的,而它不会有任何
	// 显式报错 —— 只是每次导出都静默失败。
	dir := features.LyricsDir
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
		type probeTrack struct{ artist, title, album string }
		probes := []probeTrack{
			{"周杰伦", "晴天", "叶惠美"},                  // 中文库
			{"The Beatles", "Yesterday", "Help!"}, // 英文库
		}
		answered := map[string]int{}
		start := time.Now()
		for _, p := range probes {
			_, scored := scoredLyricCandidates(toSimplified(p.artist), toSimplified(p.title), toSimplified(p.album), 0)
			for _, src := range distinctLyricSources(scored, false) {
				answered[src]++
			}
		}
		elapsed := time.Since(start).Round(time.Millisecond)
		report.NetworkLooksDown = networkLooksDown()

		if report.NetworkLooksDown {
			add("网络", healthFail, "所有请求都发不出去(DNS/连接失败),歌词解析这一轮全部无效")
		} else {
			add("网络", healthOK, "探测 %d 首用时 %s", len(probes), elapsed)
		}
		// 单个源坏掉不等于"歌词出不来"——还有另外四个。所以单源只报 warn,只有**所有**
		// 启用的源都哑了才是 fail。分级要对得上这个命令要回答的问题("歌词为什么不出来"),
		// 否则一个长期失效的源会让 healthcheck 常年顶着 fail,那个信号就不值钱了。
		dead := 0
		for _, src := range enabled {
			n := answered[src]
			switch {
			case n == len(probes):
				add("源 "+src, healthOK, "%d/%d 首探测曲给出了候选", n, len(probes))
			case n > 0:
				// 一半命中是正常的：中文源查不到英文歌，反之亦然。
				add("源 "+src, healthOK, "%d/%d 首(另一首不在它的曲库里属正常)", n, len(probes))
			default:
				dead++
				add("源 "+src, healthWarn, "两首探测曲都没有候选,这个源目前可能不可用")
			}
		}
		if dead > 0 && dead == len(enabled) {
			add("歌词源整体", healthFail, "%d 个启用的源全部没有候选,歌词不会出现", dead)
		} else if dead > 0 {
			add("歌词源整体", healthOK, "%d/%d 个源可用,歌词功能正常", len(enabled)-dead, len(enabled))
		}
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

// enabledLyricSourceNames 返回当前设置里启用的歌词源,顺序固定,便于比对输出。
func enabledLyricSourceNames() []string {
	var out []string
	for _, name := range []string{"netease", "qq", "kugou", "lrclib", "musixmatch"} {
		if features.LyricsSources == nil || features.LyricsSources[name] {
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
