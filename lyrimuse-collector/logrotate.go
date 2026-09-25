package main

import (
	"io"
	"os"
	"strconv"
	"syscall"
)

// 日志轮转。
//
// 起因:~/Library/Logs/lyrimuse.log 由 launchd 通过 StandardOutPath/StandardErrorPath
// 直接打开、collector 进程继承这个 fd 写下去,从来没有轮转过——`lyricstrace.go` 的注释
// 早就点名过这一点("lyrimuse.log 也没有轮转 —— 这两个先例都别学"),实测这台机器上这个
// 文件已经涨到 13.5MB。做成"collector 启动时自查文件大小,超过阈值就截断/
// 归档、开一份新的",不碰系统级 newsyslog(需要 root 权限写 /etc/newsyslog.d/,跟这个
// 项目"尽量不依赖需要管理员权限的官方机制"的取向不搭——ad-hoc 签名放弃 SMAppService 走
// 文件系统方案是同一个理由,见第 14 章已知坑)。
//
// 两个检查点:进程启动时(rotateLogIfNeeded),以及常驻运行期间每次写日志前(logsink.go 的
// rotatingLogFile,按自己累计的字节数判断)。两处归档动作都是 archiveAndReopen。
//
// # 为什么不能只 os.Rename 就完事
//
// 这个进程的 os.Stderr 此刻已经指向旧文件的 inode(launchd fork/exec 时把已经打开的 fd
// 继承给我们)——rename 只改目录项,不会让一个已经打开的 fd "跟着"改名后的新路径走,
// 后续写入还是会落进被改名的那份旧文件里。所以必须在 rename 之后显式 os.OpenFile 一份
// 新文件,把它交给调用方去 log.SetOutput,而不能指望"改完名字日志就自动另起一份"。
// fd 2 同理:常驻模式下由 redirectStderrTo 把它也指到当前文件,Go 运行时的 panic 输出直接写
// fd 2,不这样的话轮转过一次之后 panic 就落进 .old 归档,再轮转两次就被删掉。
const logRotateMaxBytes int64 = 30 * 1024 * 1024

// logRotateKeepArchives:保留几份历史归档。最近的一份仍叫 `<path>.old`(App 侧诊断导出和
// 用户的肌肉记忆都认这个名字),再往前是 `.old.1`、`.old.2`,数字越大越旧。
//
// 原来只留一份。实测产量 5~8.5 万行/天、约 11MB/天,30MB 阈值意味着两三天就轮转一次,
// 而轮转会把上一份 .old 直接删掉 —— 能回溯的窗口只有两到五天,"上周那次是怎么回事"
// 根本查不了。三份 × 30MB 封顶 90MB,对 ~/Library/Logs 是可以接受的量。
const logRotateKeepArchives = 3

// logFilePath 是这个日志文件的唯一路径来源——跟 launchd plist 里 StandardOutPath/
// StandardErrorPath、以及 App 侧 DiagnosticsExporter.swift 里各自硬编码的同一个路径
// 保持一致(两侧语言不同没法共享一个常量,这是这三处唯一各自维护的地方,改动时记得
// 一起改)。UserHomeDir 拿不到时返回空串,调用方据此放弃轮转,不阻塞启动。
// logFilePath 挪到 paths.go(跟配置目录一起按环境变量派生)。

// rotateLogIfNeeded 检查 path 处的文件是否超过 maxBytes——超过就归档成 `<path>.old`
// (既有归档整体往后挪一格,共留 logRotateKeepArchives 份,超出的最老那份删掉)再开一份
// 新文件。这几份是"最近发生了什么"的滚动快照,不是长期归档,用户真要长期保存会自己拷走。
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

	f, ok := archiveAndReopen(path)
	if !ok {
		return fallback, false
	}
	return f, true
}

// archiveAndReopen:把 path 归档成 path.old 并新开一份同名文件。
// 启动期(rotateLogIfNeeded)和运行期(logsink.go rotatingLogFile.rotateLocked)共用这一套
// 动作 —— 运行期轮转加进来时抽出来的,两处别各写一份。
//
// 顺序是刻意的:先把当前文件挪到一个中转名、把新文件开出来,**确认日志有地方写了**,
// 才去动归档序列。反过来先挪归档的话,一旦新文件开不出来要回滚,最老的那份归档已经被
// 删掉了 —— 一次失败的轮转不该顺手吃掉一份历史。
func archiveAndReopen(path string) (*os.File, bool) {
	staging := path + ".rotating"
	if err := os.Rename(path, staging); err != nil {
		return nil, false
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		// 已经把旧文件挪走了但开不出新的——比"什么都不做"更糟(等于让日志无处可写),
		// 尽力把旧文件挪回来,挪不回来也只能算了,至少不在这里 panic。此刻归档一份没动。
		_ = os.Rename(staging, path)
		return nil, false
	}
	// 到这里日志已经有地方写了,下面整理归档失败也只是少留一份历史,不影响正事。
	shiftLogArchives(path)
	if err := os.Rename(staging, logArchiveName(path, 0)); err != nil {
		_ = os.Remove(staging)
	}
	return f, true
}

// logArchiveName:第 i 代归档的文件名,0 是最近的一份(`<path>.old`),数字越大越旧。
// redirectStderrTo 把 fd 2 指到 f。只给常驻模式用(子命令的 stderr 是终端)。
func redirectStderrTo(f *os.File) {
	_ = syscall.Dup2(int(f.Fd()), 2)
}

func logArchiveName(path string, i int) string {
	if i == 0 {
		return path + ".old"
	}
	return path + ".old." + strconv.Itoa(i)
}

// shiftLogArchives 把既有归档整体往后挪一格,给新的第 0 代腾位置。
//
// 必须**从旧往新**遍历,否则前一次改名的结果会被后一次覆盖掉,几代归档挤成同一份。
// 最老的那份不用显式删:rename(2) 覆盖目标,倒数第二代挪过去时就把它顶掉了,所以
// `.old.<logRotateKeepArchives>` 这个名字根本不会出现。中间缺了哪一代也无所谓 ——
// os.Rename 对不存在的源直接返回错误,忽略即可。
func shiftLogArchives(path string) {
	for i := logRotateKeepArchives - 2; i >= 0; i-- {
		_ = os.Rename(logArchiveName(path, i), logArchiveName(path, i+1))
	}
}
