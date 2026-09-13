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
// ⚠️ **探测范围**没有按 -source 收窄:两首探测曲各自内部仍然会把全部启用的源一起
// 并发打一遍(跟 healthcheck/search-lyrics 完全一样),不给每个源单独写一套"只探测它自己"
// 的调用——AMLL 需要先从网易云/QQ 拿到平台 ID 才能测,拆出来反而更复杂。
//
// 但**要测的源全部有了结论之后就不再跑下去**(2026-09-13 修的 bug,下面 allReported/cancel)
// ——这条 CLI 的全部产出就是那几行 NDJSON,最后一个目标源报完之后再跑不会多出
// 任何输出,只会让调用方干等。原来两首探测曲雷打不动各跑到底,`-source deezer` 这种
// "只要一行"的调用于是在 deezer 那行打完之后还要再跑一整首探测曲(实测 5.8s 出结果、
// 12.0s 才退出),设置页那颗按钮因此在结果已经显示出来之后还持续显示"测试中…"六秒以上
// (用户实机反馈"点了单个源的测试,结束之后右边的测试状态一直没有变更")——那颗按钮的
// "测试中"是跟着子进程活着算的,见 SettingsView.isTestingLyricSources。现在最后一个目标源
// 一报完就取消这一轮探测(fetchScoredLyricCandidatesStreaming 的收集循环认 ctx.Done,跟
// "用户主动取消搜索"走的是同一条路),进程随即正常退出(退出码仍然是 0,Swift 侧
// 不会当成失败)。
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
	if configDir() != "" {
		cfgPath := filepath.Join(configDir(), "config.json")
		features = loadFeatureFlags(filepath.Join(filepath.Dir(cfgPath), clientName+"-features.json"))
	}

	targets := enabledLyricSourceNames()
	if *only != "" {
		targets = []string{*only}
	}
	if len(targets) == 0 {
		// 一个源都没启用(界面不允许关掉最后一个,只可能来自手改配置):没有任何源要测,
		// 两首探测曲跑完也不会有一行输出,直接收工。
		return
	}
	wanted := make(map[string]bool, len(targets))
	for _, t := range targets {
		wanted[t] = true
	}
	reported := make(map[string]bool, len(targets))

	// 取消闸:targets 里每个源都已经有结论之后,这一轮探测剩下的部分再跑也不会改变
	// 任何输出——取消掉让 runProbe 立刻收工,理由见函数头注那段 ⚠️。
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	allReported := func() bool {
		for _, t := range targets {
			if !reported[t] {
				return false
			}
		}
		return true
	}

	enc := json.NewEncoder(os.Stdout)
	emitResult := func(source, status, reasonCode string) {
		if reported[source] {
			return
		}
		reported[source] = true
		if err := enc.Encode(lyricSourceTestResult{
			Source: source, Status: status, ReasonCode: reasonCode,
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
				// ok 状态的 reasonCode 从来不会显示给用户(Swift 侧只在 warn/fail 时才读
				// 这个字段,见 SettingsView.sourceAccessoryTooltip),留空即可。
				emitResult(src, "ok", "")
			}
		}
		if allReported() {
			cancel()
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
			ctx, toSimplified(artist), toSimplified(title), toSimplified(album), 0, onUpdate)
		scanForPositives(results)
	}

	// 两首探测曲,一首华语一首英文,取并集——理由见 healthcheckcli.go 顶部注释:
	// NetEase/QQ/酷狗以中文库为主,LRCLIB/Musixmatch 以英文库为主,只用一首会把另一半源的
	// "库里确实没有这首"误判成"这个源坏了"。中文探测曲跟 healthcheckcli.go 保持同一首
	// (2026-08-31 从《晴天》换成《少年》,理由同样见 healthcheckcli.go 那边的注释——不重复)。
	runProbe("梦然", "少年", "")
	// 第一首就把要测的源全问出结论了(单测一个源时最常见)就不跑第二首——两首取并集是为了
	// 补"这个源的曲库里没有那一首"造成的漏判,已经有结论的源不需要补。
	if !allReported() {
		runProbe("The Beatles", "Yesterday", "Help!")
	}

	down := networkLooksDown()
	for _, src := range targets {
		if reported[src] {
			continue
		}
		// 跟具体失败原因(下面 switch 里那三个)一样,这两个通用兜底也存稳定代码不存
		// 文案——两侧必须同步维护,见 lyricsourcefailure.go 头注。
		reasonCode := lyricTestReasonNoResponse
		status := "warn"
		if down {
			status, reasonCode = "fail", lyricTestReasonNetworkDown
		} else {
			// 目前接了具体失败原因诊断的源(2026-08-31,分别见 ytmusic.go/musixmatch.go/
			// netease.go 头注——每一条都是实测复现过、不是猜的)。QQ/酷狗/LRCLIB/AMLL
			// 逐一验证过,没有找到当前能复现的失败信号(见对应文件排查记录),没有对应
			// 旁路,拿不到具体原因时统一退回上面的通用代码,不编一个没核实过的理由。
			var reason string
			switch src {
			case "lyricfind":
				reason = ytmusicLastFailureReasonNow()
			case "musixmatch":
				reason = musixmatchLastFailureReasonNow()
			case "deezer":
				// 2026-09-13,换不到匿名 JWT 那一档(deezer_auth_failed,见 deezer.go 头注)。
				// ⚠️ 这个 case 是**真机验证抓到的漏接**:接源时只补了 searchcli.go 的
				// lyricSourceFailureReasons,这条路照样退回通用的 no_response —— 设置页那颗
				// 「测试」按钮于是只会说「这个源没反应」,把"换票这一步失败"说成了"没反应"。
				// 再接新源时记得这里和 searchcli.go 是**两处**,守卫没钉住它。
				reason = deezerLastFailureReasonNow()
			case "netease":
				// 同 lyricSourceFailureReasons(2026-09-03):这一轮网易云只要成功答过
				// 一次,就不把限流当成"这个源没给出候选"的原因 —— 吃过一次 405 跟"这个源
				// 不可用"是两件事,实测对照见 netease.go 的 neteaseSawSuccessNow 头注。
				if !neteaseSawSuccessNow() {
					reason = neteaseLastFailureReasonNow()
				}
			}
			if reason != "" {
				reasonCode = reason
			}
		}
		emitResult(src, status, reasonCode)
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
	Status string `json:"status"`
	// ReasonCode:稳定代码,不是文案(2026-09-01 从 Detail 改名——见 lyricsourcefailure.go
	// 头注,人话交给 Swift 侧按 App 界面语言翻译)。ok 状态下恒为空串,Swift 侧从不读它。
	ReasonCode       string `json:"reasonCode"`
	NetworkLooksDown bool   `json:"networkLooksDown"`
}
