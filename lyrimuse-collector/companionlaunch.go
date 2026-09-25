// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"log"
	"log/slog"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"
)

// companionLaunch 是"打开当前选定的播放器(features().Players)时顺带唤起 Lyrimuse"这个
// 联动的另一半——反方向("打开 Lyrimuse 时唤起播放器")触发点就是 Lyrimuse.app 自己的
// 启动流程,直接在 Swift 那边(AppDelegate.swift)实现即可,不需要 collector 插手。但
// 这个方向不一样:必须有一个不依赖 Lyrimuse.app 主进程是否在运行的东西,持续盯着目标
// 播放器的启动状态——collector 正好是这样的角色(launchd KeepAlive=true 常驻,用户
// Cmd-Q 退出 Lyrimuse.app 完全不影响它继续跑,见 CollectorServiceManager.swift 顶部
// 注释)。
//
// 检测方式故意不复用 getState()/appleMusicPosition() 那套走 AppleScript 问 Music.app
// 播放状态的逻辑(而且 QQ 音乐压根没有对应的 AppleScript 支持)——那条路径对"没有可
// 报告的正在播放"这几种情况(没运行/已停止/没有曲目在加载/自动化权限被拒绝)完全无法
// 区分(见 system.go 顶部注释),没法单独判断"进程到底在不在跑"。改用 ps 直接读
// 进程表,纯粹是否存在这个可执行文件对应的进程,不依赖任何 Apple Event/自动化权限,
// 也不会跟"读取播放状态"那条路径的权限请求产生任何交集——这也是为什么这个方向能够
// 对 QQ 音乐同样生效。
//
// 每一轮只起**一个** `ps -axco pid=,comm=`,一次拿到全部进程的名字和 PID。原来是每个盯着的
// 播放器各跑一次 `pgrep -x`、每秒一轮:勾满五个就是每秒五次 fork,实测每次约 4ms CPU,
// 合计常驻约 2% 单核,而且记在临时子进程头上,活动监视器里的 collector 看不出来。
// 名字取 `-c` 那一列(内核 p_comm),跟原来 `pgrep -x` 比的是同一个东西:16 字节上限照旧
// (见 knownPlayerProcessNames),中文的「酷狗音乐」实测能对上。别换成 `pgrep -l`:它打印的
// 名字跟匹配用的不是同一个来源(拿符号链接起的进程实测,按「酷狗音乐」匹配上、打印出来却是
// 链接目标的名字)。
//
// lastPIDsByName 按进程名记"上一轮看到的 PID"。「刚启动」= 这一轮出现了上一轮没有的 PID ——
// 比"上一轮不在跑、这一轮在跑"多认出一种:两次采样之间退出又重开(PID 换了)。原来靠 1 秒轮询
// 去赌能采到中间那一下"不在跑"(Cmd-Q 再重开,进程只消失 1 秒左右),现在不用赌,间隔可以放宽。
// playerAuto("自动识别")下同时盯全部已知播放器,任意一个刚启动都算数。记的是全部已知播放器,
// 不只是这一轮盯着的那几个:用户新勾上一个正在跑的播放器,不该被当成"它刚启动"。
// nil = 进程刚起、还没有上一轮(见 companionObserve)。
var lastPIDsByName map[string][]int

// companionLaunchInterval 是检测目标播放器启动用的轮询间隔。PID 比对认得出"两次采样之间重启过",
// 间隔只决定 Lyrimuse 最多晚几秒被拉起,3 秒够用;不复用 poller.go 的 pollInterval(5 秒)只是
// 为了让这个延迟再短一点。
const companionLaunchInterval = 3 * time.Second

// startCompanionLaunchWatcher 独立于 poller.go 的主轮询跑,由 run() 用单独的
// goroutine 启动,ctx 取消时退出。
func startCompanionLaunchWatcher(ctx context.Context) {
	ticker := time.NewTicker(companionLaunchInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			checkCompanionLaunch()
		}
	}
}

// checkCompanionLaunch 检测目标播放器里有没有谁刚启动(见 lastPIDsByName),有、用户开着这个
// 开关、而且 Lyrimuse.app 当前**没有**在跑时,启动它。同一轮里有两个都刚启动(用户同时点开了
// 两个播放器)只按第一个触发一次。
func checkCompanionLaunch() {
	procs, ok := processSnapshot()
	if !ok {
		return // ps 这一轮没跑成:不动上一轮的记录,下一轮接着比
	}
	// 不管开关开没开、这一轮盯不盯它,每一轮都要更新记录——关着的时候跳过的话,关闭期间的
	// 真实状态变化不会被记下,开关重新打开的瞬间会把"早就在跑"误判成"刚刚启动"。
	var justStarted string
	justStarted, lastPIDsByName = companionObserve(companionLaunchProcessNames(), lastPIDsByName, procs)
	// alreadyRunning 只为了把"跳过"这一种否决单独记一条日志——这是唯一需要事后能核实的
	// 分支(开关关着/没有跳变都不值得记,每轮都记会刷爆日志)。判断本身仍然全在
	// shouldCompanionLaunch 里,这里不重复一遍条件。
	alreadyRunning := false
	if !shouldCompanionLaunch(justStarted, features().LaunchLyrimuseOnMusicOpen, func() bool {
		alreadyRunning = len(procs[lyrimuseAppProcessName]) > 0
		return alreadyRunning
	}) {
		if alreadyRunning {
			log.Printf("companion launch: %s just started, Lyrimuse.app already running, skipping", justStarted)
		}
		return
	}
	log.Printf("companion launch: %s just started, launching Lyrimuse.app", justStarted)
	launchLyrimuseApp()
}

// lyrimuseAppProcessName 是 Lyrimuse.app 的可执行文件名(/Applications/Lyrimuse.app/
// Contents/MacOS/lyrimuse),给 pgrep -x 用。collector 自己的可执行名是 collector,
// 两者不会互相误命中(实测核实过)。
const lyrimuseAppProcessName = "lyrimuse"

// shouldCompanionLaunch 把"这一轮到底要不要去启动 Lyrimuse.app"收成一个纯函数,便于
// 单测覆盖三个否决条件。
//
// lyrimuseRunning 传的是函数而不是 bool:前两个条件绝大多数轮次就已经否决了,只有真要启动时
// 才需要问 Lyrimuse 在不在跑。
//
// 第三个条件(已在运行就跳过)是补的,之前这里和 launchLyrimuseApp 的注释
// 都断言"已经在运行时 open 是空操作、不需要提前判断",这个前提是错的,当天日志里有两种
// 反例:
//
//	① `open` 会给已运行的实例投递 reopen 事件,而 AppDelegate.applicationShouldHandleReopen
//	   在没有可见窗口时(菜单栏常驻 App 的常态)会把设置窗口当"主窗口"打开——表现成
//	   "打开 Music 之后 Lyrimuse 的设置窗口自己弹出来了"。
//	② 更糟的一种:launchd 直接拉起的 App 进程没有以 GUI 实例身份注册进 LaunchServices,
//	   `open` 当它不存在、又起了第二个实例(当天 launchctl list 里同时出现
//	   me.yudaotor.lyrimuse 和 application.me.yudaotor.lyrimuse.* 两条,两个进程跑同一个
//	   .app,菜单栏出现两个图标)。
//
// 这个功能的语义本来就是"播放器起来了、顺手把没在跑的 Lyrimuse 拉起来",已经在跑时跳过
// 不损失任何东西。
func shouldCompanionLaunch(justStarted string, enabled bool, lyrimuseRunning func() bool) bool {
	if justStarted == "" || !enabled {
		return false
	}
	return !lyrimuseRunning()
}

// companionObserve 用这一轮的进程快照算出新的记录,并返回刚启动的播放器名(没有就是空串)。
// prev 为 nil(collector 刚起、还没有上一轮)时只记录不判断:那一刻已经在跑的播放器是早就开着的。
// 不这样的话 collector 每次重启(改设置、崩溃被 KeepAlive 拉起、自动更新)的第一轮,都会把开着的
// 播放器当成刚启动;用户这时已经退出了 Lyrimuse,就会被违背意愿拉起来。
func companionObserve(names []string, prev, procs map[string][]int) (string, map[string][]int) {
	next := make(map[string][]int, len(knownPlayerProcessNames))
	for _, name := range knownPlayerProcessNames {
		if pids := procs[name]; len(pids) > 0 {
			next[name] = pids
		}
	}
	if prev == nil {
		return "", next
	}
	return companionJustStarted(names, prev, procs), next
}

// companionJustStarted 返回 names 里第一个「这一轮出现了上一轮没有的 PID」的进程名,没有就是空串。
func companionJustStarted(names []string, prev, now map[string][]int) string {
	for _, name := range names {
		for _, pid := range now[name] {
			if !slices.Contains(prev[name], pid) {
				return name
			}
		}
	}
	return ""
}

// processSnapshot 起一次 ps,返回 进程名(内核 p_comm) → PID 列表。选这条路的理由见文件头注。
func processSnapshot() (map[string][]int, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/bin/ps", "-axco", "pid=,comm=").Output()
	if err != nil {
		return nil, false
	}
	return parseProcessList(string(out)), true
}

// parseProcessList 解 `ps -axco pid=,comm=` 的输出:每行「PID 名字」,PID 前面有对齐用的空格,
// 名字本身可能带空格(「Google Chrome Helper」),所以只按第一个空格切。
func parseProcessList(out string) map[string][]int {
	procs := map[string][]int{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		i := strings.IndexByte(line, ' ')
		if i <= 0 {
			continue
		}
		pid, err := strconv.Atoi(line[:i])
		if err != nil {
			continue
		}
		if name := strings.TrimSpace(line[i+1:]); name != "" {
			procs[name] = append(procs[name], pid)
		}
	}
	return procs
}

// isProcessRunning 用 pgrep 按可执行文件名精确匹配(-x)查进程是否存在,不发送任何
// Apple Event。只剩 launchLyrimuseApp 真要启动前那一次自查在用。
func isProcessRunning(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "pgrep", "-x", name).Run() == nil
}

// companionLaunchProcessNames 是这一轮要盯的可执行文件名列表——手动选定播放器时盯
// features().Players 里的每一个(可多选;单选年代只有一个 key,行为跟合并
// 前完全一致,不会因为多了 playerAuto 而误报别的播放器启动);「自动识别」在选中集合里
// (不管是否同时还勾了别的具体播放器,都按超集处理)时没有唯一确定的目标,同时盯着
// 全部五个已知播放器,任意一个启动都算数,这也是自动识别模式下这个方向反而更有用的
// 地方——用户不需要事先告诉 Lyrimuse 自己接下来要开哪个播放器。
func companionLaunchProcessNames() []string {
	var candidates []string
	if features().Players[playerAuto] {
		candidates = knownPlayerProcessNames
	} else {
		candidates = make([]string, 0, len(features().Players))
		for player := range features().Players {
			candidates = append(candidates, playerProcessNameFor(player))
		}
	}
	// 「跟随播放器启动」按播放器逐个勾选(features().LaunchLyrimuseOnPlayers):键在就
	// 只盯勾了的、且仍在候选(选中集合 / auto 全量)里的那几个 —— 勾了但已经取消选中的播放器不算,跟 Swift 侧
	// PlayerLinkage.effective 同一条规则;键缺失是布尔年代的老配置,退回盯整个候选集合。
	if features().LaunchLyrimuseOnPlayers == nil {
		return candidates
	}
	names := make([]string, 0, len(features().LaunchLyrimuseOnPlayers))
	for player := range features().LaunchLyrimuseOnPlayers {
		name := playerProcessNameFor(player)
		for _, candidate := range candidates {
			if candidate == name {
				names = append(names, name)
				break
			}
		}
	}
	return names
}

// knownPlayerProcessNames 是全部五个已知播放器的可执行文件名——QQ音乐.app 是
// QQMusic、网易云音乐.app 是 NeteaseMusic、Spotify.app 是 Spotify、酷狗音乐.app 是
// **中文的**「酷狗音乐」(都用 PlistBuddy 读 CFBundleExecutable 核实过),Music.app 是
// Music。playerProcessNameFor() 给 features().Players 里手动选定的每个成员各查一个出来;
// playerAuto 在选中集合里时直接用整份列表。
//
// 酷狗那一项是非 ASCII 的,实测确认两件事都成立才敢这么写:
//  1. `pgrep -x 酷狗音乐` 能匹配到 comm 为中文的进程(拿一个中文名符号链接起进程验过);
//  2. UTF-8 下「酷狗音乐」是 12 字节,没超过内核 p_comm 的 16 字节上限(pgrep 比的就是
//     这个被截断过的名字)——再长两个汉字就会被截断、`-x` 精确匹配当场失效。往这份列表
//     里加新播放器时这条限制要一起核。
// knownPlayerProcessNames 与逐播放器的进程名都在 players_generated.go
// (生成自 shared/players.json)——上面那两条限制(p_comm 16 字节、-x 精确匹配)在那份
// JSON 的 processName 字段旁边也记着一份。

// playerProcessNameFor 是某个具体播放器常量的可执行文件名,给手动选定的场景用,见
// knownPlayerProcessNames 注释。从读包级 features().Player 的 playerProcessName
// 改成纯函数——多选之后 companionLaunchProcessNames 要对 features().Players 里的每个
// 成员分别求进程名,不能再读一个包级单值。
func playerProcessNameFor(player string) string {
	// 查不到(auto / 认不出来)退回 Music,跟 playerBundleID 的兜底方向一致。
	if name, ok := playerProcessNames[player]; ok {
		return name
	}
	return "Music"
}

// launchLyrimuseApp 用 bundle id(不是路径)启动 Lyrimuse.app——不依赖它具体装在哪个
// 路径下,LaunchServices 自己按已注册的 bundle id 找。用 --background 避免把它带到前台
// 抢用户当前的焦点(跟 AppDelegate.swift 里 launchMusicOnLyrimuseOpen 那半用
// config.activates=false 的用意一致)。
//
// 调用方必须先确认 Lyrimuse.app 没在跑(见 shouldCompanionLaunch 的注释)。这里再自查
// 一次是纵深防御:对已运行的实例 `open` **不是**空操作,会弹设置窗口、甚至起第二个实例。
func launchLyrimuseApp() {
	if isProcessRunning(lyrimuseAppProcessName) {
		return
	}
	// bundle id 来自 paths.go appBundleID()(环境变量可覆盖,缺省正式 id),上面按可执行名 `lyrimuse` 查"在不在跑"。
	cmd := exec.Command("open", "--background", "-b", appBundleID())
	if err := cmd.Start(); err != nil {
		slog.Warn("companion launch: failed to open Lyrimuse.app", "err", err)
		return
	}
	// open 很快就退出;不 Wait 它会一直挂成僵尸进程,直到 collector 退出。
	go func() { _ = cmd.Wait() }()
}
