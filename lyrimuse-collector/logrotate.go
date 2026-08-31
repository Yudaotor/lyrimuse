package main

import (
	"io"
	"os"
	"path/filepath"
)

// 日志轮转(2026-08-27 加)。
//
// 起因:~/Library/Logs/lyrimuse.log 由 launchd 通过 StandardOutPath/StandardErrorPath
// 直接打开、collector 进程继承这个 fd 写下去,从来没有轮转过——`lyricstrace.go` 的注释
// 早就点名过这一点("lyrimuse.log 也没有轮转 —— 这两个先例都别学"),实测这台机器上这个
// 文件已经涨到 13.5MB。用户明确要求做成"collector 启动时自查文件大小,超过阈值就截断/
// 归档、开一份新的",不碰系统级 newsyslog(需要 root 权限写 /etc/newsyslog.d/,跟这个
// 项目"尽量不依赖需要管理员权限的官方机制"的取向不搭——ad-hoc 签名放弃 SMAppService 走
// 文件系统方案是同一个理由,见第 14 章已知坑)。
//
// 只在**进程启动时**检查一次,不在运行期间定时轮询:collector 靠 scheduleCollectorRestart/
// launchd kickstart 本来就会被相对频繁地重启(配置变更、App 重启都会触发),启动时检查
// 已经足够把文件体量兜住,不需要为了"极端情况下几周不重启"这种边界场景多引入一个定时器
// 和"运行期间重开文件描述符"的复杂度。
//
// # 为什么不能只 os.Rename 就完事
//
// 这个进程的 os.Stderr 此刻已经指向旧文件的 inode(launchd fork/exec 时把已经打开的 fd
// 继承给我们)——rename 只改目录项,不会让一个已经打开的 fd "跟着"改名后的新路径走,
// 后续写入还是会落进被改名的那份旧文件里。所以必须在 rename 之后显式 os.OpenFile 一份
// 新文件,把它交给调用方去 log.SetOutput,而不能指望"改完名字日志就自动另起一份"。
const logRotateMaxBytes int64 = 30 * 1024 * 1024

// logFilePath 是这个日志文件的唯一路径来源——跟 launchd plist 里 StandardOutPath/
// StandardErrorPath、以及 App 侧 DiagnosticsExporter.swift 里各自硬编码的同一个路径
// 保持一致(两侧语言不同没法共享一个常量,这是这三处唯一各自维护的地方,改动时记得
// 一起改)。UserHomeDir 拿不到时返回空串,调用方据此放弃轮转,不阻塞启动。
func logFilePath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Logs/lyrimuse.log")
}

// rotateLogIfNeeded 检查 path 处的文件是否超过 maxBytes——超过就归档成 `<path>.old`
// (覆盖式,只留一份历史,这个文件本来就是"最近发生了什么"的滚动快照,不是长期归档,
// 用户真要长期保存会自己拷走)再开一份新文件。
//
// 返回值交给调用方 log.SetOutput:成功轮转时是新打开的文件,否则(不需要轮转 / 判定
// 或归档过程中任何一步失败)一律退回 io.Writer(os.Stderr)——宁可这次不轮转,也不能
// 因为轮转本身出错就让日志整个丢失或者把启动流程带崩。第二个返回值只用于"要不要打一条
// 说明这次发生过轮转"的日志,不影响第一个返回值的正确性。
func rotateLogIfNeeded(path string, maxBytes int64) (io.Writer, bool) {
	fallback := io.Writer(os.Stderr)
	if path == "" {
		return fallback, false
	}
	info, err := os.Stat(path)
	if err != nil || info.Size() < maxBytes {
		return fallback, false
	}

	oldPath := path + ".old"
	_ = os.Remove(oldPath) // 覆盖式,不管上一份 .old 是否存在
	if err := os.Rename(path, oldPath); err != nil {
		return fallback, false
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		// 已经把旧文件挪走了但开不出新的——比"什么都不做"更糟(等于让日志无处可写),
		// 尽力把旧文件挪回来,挪不回来也只能算了,至少不在这里 panic。
		_ = os.Rename(oldPath, path)
		return fallback, false
	}
	return f, true
}
