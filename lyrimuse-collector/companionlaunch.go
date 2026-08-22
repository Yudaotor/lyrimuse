// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"log"
	"os/exec"
	"time"
)

// companionLaunch 是"打开当前选定的播放器(features.Player)时顺带唤起 Lyrimuse"这个
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
// 区分(见 system.go 顶部注释),没法单独判断"进程到底在不在跑"。改用 pgrep 直接查
// 进程表,纯粹是否存在这个可执行文件对应的进程,不依赖任何 Apple Event/自动化权限,
// 也不会跟"读取播放状态"那条路径的权限请求产生任何交集——这也是为什么这个方向能够
// 对 QQ 音乐同样生效。
//
// lastRunningByName 按进程名分别记"上一轮是否在跑"——playerAuto("自动识别")下要
// 同时盯着 companionLaunchProcessNames() 返回的全部已知播放器,任意一个从没运行变成
// 运行都算数,不能只用一个笼统的 bool(会丢失"到底是哪一个刚跳变"这个信息,也没法
// 正确处理"A 在跑、B 刚启动"这种多个进程同时存在的情况)。手动选定单一播放器时这份
// map 里实际上永远只有一个 key,行为跟旧版单 bool 完全等价。
var lastRunningByName = map[string]bool{}

// companionLaunchInterval 是专门检测目标播放器启动状态用的轮询间隔——不能复用
// poller.go 的 pollInterval(5 秒)。实测坐实(用 Music.app 验证的):真的用 Cmd-Q/Dock
// 菜单退出再重新打开,从进程消失到重新出现整个窗口只有 1 秒左右,5 秒轮询大概率会两次
// 采样都落在"已经重新在跑"这一侧,完全跳过中间那个短暂的"没在跑"状态,导致这次真实的
// 跳变被彻底漏检(不是偶发,是复现过的真实 bug)。1 秒本身也不能 100% 保证覆盖所有
// 场景,但 pgrep 这个检测本身开销极小,加密到 1 秒不会有任何可感知的资源代价,换来的
// 是覆盖绝大多数真实使用节奏的可靠性。
const companionLaunchInterval = 1 * time.Second

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

// checkCompanionLaunch 检测目标播放器(手动选定时只有一个;playerAuto 下是全部四个
// 已知播放器)里有没有谁发生了"从没运行变成运行"这个状态跳变,跳变发生、用户开着这个
// 开关、而且 Lyrimuse.app 当前**没有**在跑时,启动它。多个进程在同一轮里都从"没跑"变
// "在跑"的极端情况下(概率很低,但不是不可能——比如用户同时点开了两个播放器)只按第一个
// 检测到的触发一次启动。
func checkCompanionLaunch() {
	// 不管开关开没开,每一轮都要照跑下面这个循环维护 lastRunningByName——开关关着的
	// 时候如果直接跳过,关闭期间的真实状态变化不会被记录,开关重新打开的瞬间会凭空把
	// "早就在跑"误判成"刚刚启动"。
	var justStarted string
	for _, name := range companionLaunchProcessNames() {
		running := isProcessRunning(name)
		if running && !lastRunningByName[name] && justStarted == "" {
			justStarted = name
		}
		lastRunningByName[name] = running
	}
	// alreadyRunning 只为了把"跳过"这一种否决单独记一条日志——这是唯一需要事后能核实的
	// 分支(开关关着/没有跳变都不值得记,每秒一轮会刷爆日志)。判断本身仍然全在
	// shouldCompanionLaunch 里,这里不重复一遍条件。
	alreadyRunning := false
	if !shouldCompanionLaunch(justStarted, features.LaunchLyrimuseOnMusicOpen, func() bool {
		alreadyRunning = isProcessRunning(lyrimuseAppProcessName)
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
// lyrimuseRunning 传的是函数而不是 bool,为的是保住短路:前两个条件绝大多数轮次就已经
// 否决了,而查 Lyrimuse 在不在跑要 fork 一次 pgrep,没必要每秒都白跑一次。
//
// ⚠️ 第三个条件(已在运行就跳过)是 2026-08-05 补的,之前这里和 launchLyrimuseApp 的注释
// 都断言"已经在运行时 open 是空操作、不需要提前判断",这个前提是错的,当天日志里有两种
// 反例:
//
//	① `open` 会给已运行的实例投递 reopen 事件,而 AppDelegate.applicationShouldHandleReopen
//	   在没有可见窗口时(菜单栏常驻 App 的常态)会把设置窗口当"主窗口"打开——表现成
//	   "打开 Music 之后 Lyrimuse 的设置窗口自己弹出来了"(用户反馈)。
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

// isProcessRunning 用 pgrep 按可执行文件名精确匹配(-x)查进程是否存在,不发送任何
// Apple Event。
func isProcessRunning(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "pgrep", "-x", name).Run() == nil
}

// companionLaunchProcessNames 是这一轮要盯的可执行文件名列表——手动选定某个播放器时
// 只有它自己这一个(行为跟合并前完全一致,不会因为多了 playerAuto 而误报别的播放器
// 启动);playerAuto("自动识别")下没有唯一确定的目标,同时盯着全部四个已知播放器,
// 任意一个启动都算数,这也是自动识别模式下这个方向反而更有用的地方——用户不需要
// 事先告诉 Lyrimuse 自己接下来要开哪个播放器。
func companionLaunchProcessNames() []string {
	if features.Player == playerAuto {
		return knownPlayerProcessNames
	}
	return []string{playerProcessName()}
}

// knownPlayerProcessNames 是全部五个已知播放器的可执行文件名——QQ音乐.app 是
// QQMusic、网易云音乐.app 是 NeteaseMusic、Spotify.app 是 Spotify、酷狗音乐.app 是
// **中文的**「酷狗音乐」(都用 PlistBuddy 读 CFBundleExecutable 核实过),Music.app 是
// Music。playerProcessName() 按 features.Player 从这份列表里挑一个出来给手动选定的
// 场景用;playerAuto 直接用整份列表。
//
// ⚠️ 酷狗那一项是非 ASCII 的,2026-08-22 实测确认两件事都成立才敢这么写:
//   1. `pgrep -x 酷狗音乐` 能匹配到 comm 为中文的进程(拿一个中文名符号链接起进程验过);
//   2. UTF-8 下「酷狗音乐」是 12 字节,没超过内核 p_comm 的 16 字节上限(pgrep 比的就是
//      这个被截断过的名字)——再长两个汉字就会被截断、`-x` 精确匹配当场失效。往这份列表
//      里加新播放器时这条限制要一起核。
var knownPlayerProcessNames = []string{"Music", "QQMusic", "NeteaseMusic", "Spotify", "酷狗音乐"}

// playerProcessName 是当前选定播放器(features.Player)的可执行文件名,给手动选定的
// 场景用,见 knownPlayerProcessNames 注释。
func playerProcessName() string {
	switch features.Player {
	case playerQQMusic:
		return "QQMusic"
	case playerNetease:
		return "NeteaseMusic"
	case playerSpotify:
		return "Spotify"
	case playerKugou:
		return "酷狗音乐"
	default:
		return "Music"
	}
}

// launchLyrimuseApp 用 bundle id(不是路径)启动 Lyrimuse.app——不依赖它具体装在哪个
// 路径下,LaunchServices 自己按已注册的 bundle id 找。用 --background 避免把它带到前台
// 抢用户当前的焦点(跟 AppDelegate.swift 里 launchMusicOnLyrimuseOpen 那半用
// config.activates=false 的用意一致)。
//
// ⚠️ 调用方必须先确认 Lyrimuse.app 没在跑(见 shouldCompanionLaunch 的注释)。这里再自查
// 一次是纵深防御:对已运行的实例 `open` **不是**空操作,会弹设置窗口、甚至起第二个实例。
func launchLyrimuseApp() {
	if isProcessRunning(lyrimuseAppProcessName) {
		return
	}
	if err := exec.Command("open", "--background", "-b", "me.yudaotor.lyrimuse").Start(); err != nil {
		log.Printf("companion launch: failed to open Lyrimuse.app: %v", err)
	}
}
