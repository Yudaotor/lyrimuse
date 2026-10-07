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
// 启动流程,直接在 Swift 那边(AppDelegate.swift)实现即可,不需要引擎插手。但
// 这个方向不一样:必须有一个不依赖 Lyrimuse.app 主进程是否在运行的东西,持续盯着目标
// 播放器的启动状态——引擎正好是这样的角色(launchd KeepAlive=true 常驻,用户
// Cmd-Q 退出 Lyrimuse.app 完全不影响它继续跑,见 EngineServiceManager.swift 顶部
// 注释)。
//
// 检测方式是用 ps 直接读进程表,不问播放器的播放状态:"没有可报告的正在播放"这几种情况
// (没运行/已停止/没有曲目在加载/自动化权限被拒绝)从播放状态上分不出来,判断不了"进程到底
// 在不在跑"。读进程表只看这个可执行文件对应的进程在不在,不依赖任何 Apple Event/自动化权限,
// 所以对没有 AppleScript 支持的 QQ 音乐同样生效。
//
// 只在有必要盯的时候读进程表(companionWatchNeeded):App 可用(在跑、在写播放状态)时它本来就在,
// 开关关着、没有要盯的播放器时读到了也不会去拉起,这几种情况一个子进程都不起。要盯时每
// companionLaunchInterval 起**一个** `ps -axco pid=,comm=`,一次拿到全部进程的名字和 PID;别改成每个
// 盯着的播放器各跑一次 `pgrep -x`:勾满五个就是每轮五次 fork,而且记在临时子进程头上,活动监视器里的
// 引擎看不出来。名字取 `-c` 那一列(内核 p_comm),跟 `pgrep -x` 比的是同一个东西:16 字节上限照旧
// (见 knownPlayerProcessNames),中文的「酷狗音乐」实测能对上。别换成 `pgrep -l`:它打印的
// 名字跟匹配用的不是同一个来源(拿符号链接起的进程实测,按「酷狗音乐」匹配上、打印出来却是
// 链接目标的名字)。

// companionLaunchInterval 是要盯的时候多久读一次进程表。PID 比对认得出"两次采样之间重启过",
// 间隔只决定 Lyrimuse 最多晚几秒被拉起,3 秒够用;不复用 poller.go 的 pollInterval(5 秒)只是
// 为了让这个延迟再短一点。
const companionLaunchInterval = 3 * time.Second

// companionCheckInterval 是要盯的时候多久判一次(问一次 App 状态,不起进程),比读进程表的间隔短;盯不了播放状态所在的
// 目录时一直按它判。App 一变成不可用,下一次判断就取基准,之后才开的播放器都认得出来。
const companionCheckInterval = time.Second

// companionIdleInterval:不必盯、又盯得了播放状态所在目录时的兜底间隔。App 写状态(含退出时写的那一份)就叫醒判一次,
// 只有 App 卡死、状态停更这一种要靠它察觉。
const companionIdleInterval = 5 * time.Second

// companionWatch 是盯播放器启动的状态,只在 startCompanionLaunchWatcher 那一个 goroutine 里用。
type companionWatch struct {
	// prev 按进程名记"上一轮看到的 PID"。「刚启动」= 这一轮出现了上一轮没有的 PID,两次采样之间
	// 退出又重开(PID 换了)也认得出。playerAuto("自动识别")下同时盯全部已知播放器,任意一个刚启动
	// 都算数。记的是全部已知播放器,不只是这一轮盯着的那几个:用户新勾上一个正在跑的播放器,不该被
	// 当成"它刚启动"。
	// nil = 还没有基准:引擎刚起,或刚从「不必盯」变成「要盯」(App 刚退出、开关刚打开),这一轮只记录
	// 不判断(见 companionObserve)。
	prev map[string][]int
	// sampledAt:上一次读进程表的时刻;零值 = 下一次判断就读。
	sampledAt time.Time
}

// startCompanionLaunchWatcher 独立于 poller.go 的主轮询跑,由 run() 用单独的
// goroutine 启动,ctx 取消时退出。appAvailable 回答 App 此刻可不可用(跟 poller 读的是同一份播放状态)。
func startCompanionLaunchWatcher(ctx context.Context, appAvailable func() bool) {
	// 盯播放状态文件所在的配置目录(同 poller.go 那份监听)。
	writes := make(chan struct{}, 1)
	watched := watchDirWrites(ctx, configDir(), writes)
	interval := companionCheckInterval
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	var w companionWatch
	for {
		var now time.Time
		select {
		case <-ctx.Done():
			return
		case now = <-ticker.C:
		case <-writes:
			now = time.Now()
		}
		w.check(now, appAvailable())
		// sampledAt 非零 = 这一轮要盯(见 step)。
		next := companionCheckInterval
		if watched && w.sampledAt.IsZero() {
			next = companionIdleInterval
		}
		if next != interval {
			interval = next
			ticker.Reset(interval)
		}
	}
}

// check 判这一轮要不要盯、要盯就按节奏读进程表(见 step),有播放器刚启动、用户开着这个开关、而且
// Lyrimuse.app 当前**没有**在跑时启动它。同一轮里有两个都刚启动(用户同时点开了两个播放器)只按
// 第一个触发一次。
func (w *companionWatch) check(now time.Time, appAvailable bool) {
	enabled := len(features().LaunchLyrimuseOnPlayers) > 0
	names := companionLaunchProcessNames()
	justStarted, procs := w.step(now, companionWatchNeeded(appAvailable, enabled, names), names, processSnapshot)
	// alreadyRunning 只为了把"跳过"这一种否决单独记一条日志——这是唯一需要事后能核实的
	// 分支(开关关着/没有跳变都不值得记,每轮都记会刷爆日志)。判断本身仍然全在
	// shouldCompanionLaunch 里,这里不重复一遍条件。
	alreadyRunning := false
	if !shouldCompanionLaunch(justStarted, enabled, func() bool {
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

// companionWatchNeeded:这一轮有没有必要读进程表。App 可用时它此刻就在跑,无从拉起;开关关着、没有要盯的
// 播放器时,读到了也不会去拉起。纯函数,测试覆盖。
func companionWatchNeeded(appAvailable, enabled bool, names []string) bool {
	return !appAvailable && enabled && len(names) > 0
}

// step 走一次判断:不必盯时把记录作废、不起进程;刚开始要盯时马上读进程表(这一轮只当基准),之后距上次读
// 满 companionLaunchInterval 才读。返回刚启动的播放器名与这一轮的进程快照(没读就是 nil)。sample 读进程表,
// 单测替换。
func (w *companionWatch) step(now time.Time, needed bool, names []string, sample func() (map[string][]int, bool)) (string, map[string][]int) {
	if !needed {
		w.prev, w.sampledAt = nil, time.Time{}
		return "", nil
	}
	if now.Sub(w.sampledAt) < companionLaunchInterval {
		return "", nil
	}
	w.sampledAt = now
	procs, ok := sample()
	if !ok {
		return "", nil // ps 这一轮没跑成:不动上一轮的记录,隔满间隔再读
	}
	var justStarted string
	justStarted, w.prev = companionObserve(names, w.prev, procs)
	return justStarted, procs
}

// lyrimuseAppProcessName 是 Lyrimuse.app 的可执行文件名(/Applications/Lyrimuse.app/
// Contents/MacOS/lyrimuse)。引擎自己的可执行名是 lyrimuse-engine,以它开头,所以认 App 只能按名字
// 精确匹配(pgrep -x、按进程名取 processSnapshot 的结果),别改成前缀或子串匹配。
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
// prev 为 nil(还没有基准,见 companionWatch.prev)时只记录不判断:那一刻已经在跑的播放器是早就开着的。
// 不这样的话引擎每次重启(崩溃被 KeepAlive 拉起、自动更新)、App 每次退出之后的第一轮,都会把开着的
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
// Apple Event。launchLyrimuseApp 真要启动前那一次自查在用。
func isProcessRunning(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "pgrep", "-x", name).Run() == nil
}

// companionLaunchProcessNames 是这一轮要盯的可执行文件名列表。选中集合里有「自动识别」时(不管
// 是否同时还勾了别的具体播放器,都按超集处理)没有唯一确定的目标,盯全部内置播放器
// (knownPlayerProcessNames),任意一个启动都算数,用户不需要事先告诉 Lyrimuse 接下来要开哪个播放器;
// 否则只盯 features().Players 里选定的那几个,别的播放器启动不算。
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
	// 「跟随播放器启动」按播放器逐个勾选(features().LaunchLyrimuseOnPlayers):只盯勾了的、且仍在候选
	// (选中集合 / auto 全量)里的那几个 —— 勾了但已经取消选中的播放器不算,跟 Swift 侧 PlayerLinkage.effective
	// 同一条规则。
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

// knownPlayerProcessNames 是全部内置播放器的可执行文件名,跟逐播放器的进程名(playerProcessNames)
// 一起在 players_generated.go,生成自 shared/players.json。可执行文件名常跟 App 名不同(QQ音乐.app 是
// QQMusic,酷狗音乐.app 是中文的「酷狗音乐」),一律取 CFBundleExecutable。playerProcessNameFor 给
// features().Players 里选定的每个成员各查一个;playerAuto 在选中集合里时直接用整份列表。
//
// 这些名字交给 `pgrep -x` 精确匹配,比的是内核 p_comm:非 ASCII 名字照样能匹配,但 p_comm 只留
// 16 字节,UTF-8 下中文每字 3 字节,超出的部分被截断、`-x` 就匹配不上(「酷狗音乐」「汽水音乐」都是
// 12 字节)。往表里加播放器时这条要一起核;players.json 的 processName 字段旁边也记着。

// playerProcessNameFor 是某个具体播放器常量的可执行文件名,companionLaunchProcessNames 对
// features().Players 的每个成员各求一次,见 knownPlayerProcessNames 注释。
func playerProcessNameFor(player string) string {
	// 查不到(auto / 认不出来)退回 Music。
	if name, ok := playerProcessNames[player]; ok {
		return name
	}
	return "Music"
}

// launchLyrimuseApp 用 bundle id(不是路径)启动 Lyrimuse.app——不依赖它具体装在哪个
// 路径下,LaunchServices 自己按已注册的 bundle id 找。用 --background 避免把它带到前台
// 抢用户当前的焦点(跟 AppDelegate.swift 里「打开 Lyrimuse 时启动播放器」那半用
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
	// open 很快就退出;不 Wait 它会一直挂成僵尸进程,直到引擎退出。
	go func() { _ = cmd.Wait() }()
}
