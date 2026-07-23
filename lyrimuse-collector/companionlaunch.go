// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"log"
	"os/exec"
	"time"
)

// companionLaunch 是"打开 Apple Music 时顺带唤起 Lyrimuse"这个联动的另一半——反方向
// ("打开 Lyrimuse 时唤起 Music")触发点就是 Lyrimuse.app 自己的启动流程,直接在 Swift
// 那边(AppDelegate.swift)实现即可,不需要 collector 插手。但这个方向不一样:必须有
// 一个不依赖 Lyrimuse.app 主进程是否在运行的东西,持续盯着 Music.app 的启动状态——
// collector 正好是这样的角色(launchd KeepAlive=true 常驻,用户 Cmd-Q 退出
// Lyrimuse.app 完全不影响它继续跑,见 CollectorServiceManager.swift 顶部注释)。
//
// 检测方式故意不复用 getState()/appleMusicPosition() 那套走 AppleScript 问 Music.app
// 播放状态的逻辑——那条路径对"Music.app 没有可报告的正在播放"这几种情况(没运行/已
// 停止/没有曲目在加载/自动化权限被拒绝)完全无法区分(见 system.go 顶部注释),没法
// 单独判断"进程到底在不在跑"。改用 pgrep 直接查进程表,纯粹是否存在这个可执行文件对应
// 的进程,不依赖任何 Apple Event/自动化权限,也不会跟"读取播放状态"那条路径的权限
// 请求产生任何交集。
var lastMusicAppRunning bool

// checkCompanionLaunch 检测 Music.app 是否发生了"从没运行变成运行"这个状态跳变,
// 跳变发生且用户开着这个开关时,启动/唤起 Lyrimuse.app。跟 poller.go 的 poll() 同一个
// 节奏调用(pollInterval,目前 5 秒),不需要单独起一个定时器。
func checkCompanionLaunch() {
	running := isMusicAppRunning()
	justLaunched := running && !lastMusicAppRunning
	lastMusicAppRunning = running
	if !justLaunched || !features.LaunchLyrimuseOnMusicOpen {
		return
	}
	log.Print("companion launch: Music.app just started, launching Lyrimuse.app")
	launchLyrimuseApp()
}

// isMusicAppRunning 用 pgrep 按可执行文件名精确匹配(-x),只看进程存不存在,不发送
// 任何 Apple Event。
func isMusicAppRunning() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "pgrep", "-x", "Music").Run() == nil
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
