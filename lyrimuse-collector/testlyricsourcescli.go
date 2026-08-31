package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"path/filepath"
)

// runTestLyricSourcesCLI implements `collector test-lyric-sources [-source <name>]`:
// 设置页"歌词来源"卡片的测试按钮用——每个源一颗独立的"测试"按钮,右上角一颗"全部测试"。
// 跟 healthcheckcli.go 同一个探测思路(两首固定探测曲,一首华语一首英文,取并集——理由见
// healthcheckcli.go 顶部注释,这里不重复),但输出形状不一样:healthcheck 是"一次性诊断
// 报告"(给诊断导出用,一整份 JSON/文本),这里要的是"每个源一行、边测边出结果"的 NDJSON
// 流,好让设置页的每一行独立显示"测试中…"转"可用/疑似不可用",不用等全部测完才有反应
// ——跟 search-lyrics 那条"陆续出结果"是同一个体验诉求,复用它的流式底层
// (scoredLyricCandidatesStreaming)而不是另起一套。
//
// ⚠️ 没有做"只等目标源自己回来就提前退出"这层优化:两首探测曲各自内部仍然会把全部启用的
// 源一起并发打一遍(跟 healthcheck/search-lyrics 完全一样),即使 -source 只要一个源的
// 结果,后台也要等这一轮里最慢的那个源。选择接受这个代价而不是给每个源单独写一套"只探测
// 它自己"的调用——AMLL 需要先从网易云/QQ 拿到平台 ID 才能测,直接调用它自己的探测函数
// 反而更复杂;而"单独测一个源"和"全部测"用户点下去的实际等待时间在这个仓库里从来就没有
// 区分过(联网搜索候选歌词弹窗同样是等最慢的那个源),不是这次改动新引入的体验倒退。
//
// 每个源的"边到边报"靠 scoredLyricCandidatesStreaming 返回的累积结果实现:probe1 跑完
// 就检查里面有没有某个目标源的候选(不看分数是否有效——见下面 scanForPositives 的注释),
// 有就立刻报一行并标记"已出结果";probe1 结束后仍未出结果的目标,再拿 probe2 走一遍同样的
// 逐源检查;两轮都没有结果的,最后统一报 warn(或网络整体不通时报 fail)。
func runTestLyricSourcesCLI(args []string) {
	fs := flag.NewFlagSet("test-lyric-sources", flag.ExitOnError)
	only := fs.String("source", "", "只测这一个源(留空 = 测所有已启用的源)")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("test-lyric-sources: %v", err)
	}

	// 跟 search-lyrics 同一段boilerplate:这条 CLI 子命令在 main() 的 loadFeatureFlags(...)
	// 之前就 return 了,features 这个包级变量不自己补一遍加载的话是零值(LyricsSources 为
	// nil map),lyricSourceEnabled 对任何源都会返回 false —— 测试功能会把每一个源都误判成
	// "没启用",一个都测不了。
	home, err := os.UserHomeDir()
	if err == nil {
		cfgPath := filepath.Join(home, ".config", clientName, "config.json")
		features = loadFeatureFlags(filepath.Join(filepath.Dir(cfgPath), clientName+"-features.json"))
	}

	targets := enabledLyricSourceNames()
	if *only != "" {
		targets = []string{*only}
	}
	wanted := make(map[string]bool, len(targets))
	for _, t := range targets {
		wanted[t] = true
	}
	reported := make(map[string]bool, len(targets))

	enc := json.NewEncoder(os.Stdout)
	emitResult := func(source, status, detail string) {
		if reported[source] {
			return
		}
		reported[source] = true
		if err := enc.Encode(lyricSourceTestResult{
			Source: source, Status: status, Detail: detail,
			NetworkLooksDown: networkLooksDown(),
		}); err != nil {
			log.Fatalf("test-lyric-sources: encode result: %v", err)
		}
	}

	// probe1/probe2 各跑一遍这套逻辑:results 是"到目前为止全部已知结果"的累积列表
	// (跟 search-lyrics 的 emit 语义一致),每次 onUpdate 触发都重新扫一遍——已经报过的
	// 源会被 emitResult 的 reported 挡住,反复扫同一批不会重复上报,只是找"这一批里
	// 有没有新出现的目标源"。
	//
	// 不看分数是否有效(跟 healthcheckcli.go 的 answered 计数同一个理由):这里回答的是
	// "这个源的接口现在能不能连通、给出响应",不是"这次探测曲在它库里能不能找到高质量
	// 结果"——一条被判成低分/无效的候选,只要它是这个源真的答复回来的,就足以证明这个源
	// 本身是活的。
	scanForPositives := func(results []scoredLyricCandidateResult) {
		for _, src := range lyricSourcesResponded(results) {
			if wanted[src] && !reported[src] {
				emitResult(src, "ok", "接口有响应")
			}
		}
	}

	runProbe := func(artist, title, album string) {
		// onUpdate 在这里**不能**是空操作——它才是"边测边出结果"真正的触发点:每有一个
		// 源在这一轮里完成,onUpdate 就会带着"到目前为止全部已知结果"重新调一次,这里当场
		// 扫一遍、命中目标源就立刻报,不等这一轮剩下的源。只在函数返回后再补扫一次纯粹是
		// 保险(万一最后一次 onUpdate 和返回值之间有遗漏),reported 去重保证不会重复上报。
		onUpdate := func(_ neteaseInfo, results []scoredLyricCandidateResult, _ int, _ int) {
			scanForPositives(results)
		}
		_, results := scoredLyricCandidatesStreaming(
			context.Background(), toSimplified(artist), toSimplified(title), toSimplified(album), 0, onUpdate)
		scanForPositives(results)
	}

	// 两首探测曲,一首华语一首英文,取并集——理由见 healthcheckcli.go 顶部注释:
	// NetEase/QQ/酷狗以中文库为主,LRCLIB/Musixmatch 以英文库为主,只用一首会把另一半源的
	// "库里确实没有这首"误判成"这个源坏了"。中文探测曲跟 healthcheckcli.go 保持同一首
	// (2026-08-31 从《晴天》换成《少年》,理由同样见 healthcheckcli.go 那边的注释——不重复)。
	runProbe("梦然", "少年", "")
	runProbe("The Beatles", "Yesterday", "Help!")

	down := networkLooksDown()
	for _, src := range targets {
		if reported[src] {
			continue
		}
		detail := "两首探测曲都没有响应,这个源目前可能不可用"
		status := "warn"
		if down {
			status, detail = "fail", "网络请求全部失败(DNS/连接问题),这一轮探测本身就没跑起来"
		} else {
			// 目前接了具体失败原因诊断的源(2026-08-31,分别见 ytmusic.go/musixmatch.go/
			// netease.go 头注——每一条都是实测复现过、不是猜的)。QQ/酷狗/LRCLIB/AMLL
			// 逐一验证过,没有找到当前能复现的失败信号(见对应文件排查记录),没有对应
			// 旁路,拿不到具体原因时统一退回上面的通用文案,不编一个没核实过的理由。
			var reason string
			switch src {
			case "lyricfind":
				reason = ytmusicLastFailureReasonNow()
			case "musixmatch":
				reason = musixmatchLastFailureReasonNow()
			case "netease":
				reason = neteaseLastFailureReasonNow()
			}
			if reason != "" {
				detail = reason
			}
		}
		emitResult(src, status, detail)
	}
}

// lyricSourceTestResult 是 test-lyric-sources 每行 stdout 的实际结构(NDJSON,一个源
// 一行)。字段名大写导出是 encoding/json 序列化的要求,Swift 侧按同样字段名(小写开头)
// 解码,跟 searchLyricsUpdate 是同一套约定。
type lyricSourceTestResult struct {
	Source string `json:"source"`
	// "ok" | "warn" | "fail" —— 语义跟 healthcheckcli.go 的 healthStatus 三档一致:
	// ok=这个源这一轮有响应;warn=两首探测曲都没响应但网络本身是通的(源大概率真的不可用,
	// 但也可能只是恰好都没收录这两首,不排除极小概率误判);fail=网络整体不通,这一轮探测
	// 本身就没有意义,不能拿来对这个源下任何结论。
	Status           string `json:"status"`
	Detail           string `json:"detail"`
	NetworkLooksDown bool   `json:"networkLooksDown"`
}
