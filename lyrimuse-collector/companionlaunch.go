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
// 已知播放器)里有没有谁发生了"从没运行变成运行"这个状态跳变,跳变发生且用户开着这个
// 开关时,启动/唤起 Lyrimuse.app。多个进程在同一轮里都从"没跑"变"在跑"的极端情况下
// (概率很低,但不是不可能——比如用户同时点开了两个播放器)只按第一个检测到的触发一次
// 启动,launchLyrimuseApp 本身对已运行的 Lyrimuse.app 也是空操作,不会有副作用。
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
	if justStarted == "" || !features.LaunchLyrimuseOnMusicOpen {
		return
	}
	log.Printf("companion launch: %s just started, launching Lyrimuse.app", justStarted)
	launchLyrimuseApp()
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

// knownPlayerProcessNames 是全部四个已知播放器的可执行文件名——QQ音乐.app 是
// QQMusic、网易云音乐.app 是 NeteaseMusic、Spotify.app 是 Spotify(都用 PlistBuddy
// 核实过),Music.app 是 Music。playerProcessName() 按 features.Player 从这份列表里
// 挑一个出来给手动选定的场景用;playerAuto 直接用整份列表。
var knownPlayerProcessNames = []string{"Music", "QQMusic", "NeteaseMusic", "Spotify"}

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
	default:
		return "Music"
	}
}

// launchLyrimuseApp 用 bundle id(不是路径)启动/唤起 Lyrimuse.app——不依赖它具体
// 装在哪个路径下,LaunchServices 自己按已注册的 bundle id 找。已经在运行时 `open`
// 本身就是空操作(不会重复启动一个新实例),不需要提前自己判断"要不要跳过"。
// 用 --background 避免把它带到前台抢用户当前的焦点(跟 AppDelegate.swift 里
// launchMusicOnLyrimuseOpen 那半用 config.activates=false 的用意一致)。
func launchLyrimuseApp() {
	if err := exec.Command("open", "--background", "-b", "me.yudaotor.lyrimuse").Start(); err != nil {
		log.Printf("companion launch: failed to open Lyrimuse.app: %v", err)
	}
}
