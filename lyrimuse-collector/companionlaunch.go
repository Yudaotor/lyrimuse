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
var lastMusicAppRunning bool

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

// checkCompanionLaunch 检测当前选定播放器(features.Player)是否发生了"从没运行变成
// 运行"这个状态跳变,跳变发生且用户开着这个开关时,启动/唤起 Lyrimuse.app。
func checkCompanionLaunch() {
	running := isMusicAppRunning()
	justLaunched := running && !lastMusicAppRunning
	lastMusicAppRunning = running
	if !justLaunched || !features.LaunchLyrimuseOnMusicOpen {
		return
	}
	log.Printf("companion launch: %s just started, launching Lyrimuse.app", playerProcessName())
	launchLyrimuseApp()
}

// isMusicAppRunning 用 pgrep 按可执行文件名精确匹配(-x)查当前选定播放器的进程是否
// 存在,不发送任何 Apple Event。函数名沿用旧名字(历史上只支持 Apple Music 时起的),
// 实际检测目标跟着 playerProcessName() 走。
func isMusicAppRunning() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "pgrep", "-x", playerProcessName()).Run() == nil
}

// playerProcessName 是当前选定播放器(features.Player)的可执行文件名,给 pgrep -x
// 用——QQ音乐.app 的 CFBundleExecutable 是 QQMusic(用 PlistBuddy 核实过),Music.app
// 是 Music。
func playerProcessName() string {
	if features.Player == playerQQMusic {
		return "QQMusic"
	}
	return "Music"
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
