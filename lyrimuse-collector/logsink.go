package main

// 日志出口(2026-09-05)。collector 侧的日志从 stdlib `log` 的无等级文本换成标准库 `log/slog`
// 的结构化分级日志,同时把三件以前各自为政(或根本没有)的事收进这一条出口链:
//
//	slog.TextHandler ──▶ repeatSquelcher ──▶ secretScrubber ──▶ rotatingLogFile(常驻)/ stderr(子命令)
//	(等级 / 时间戳)   (连续重复行折叠)    (凭据脱敏,logscrub.go)  (运行期按大小轮转,logrotate.go)
//
// 为什么现在动它(2026-09-05 拿两天 40k 行真实日志数的):63% 是 `api call` 审计行、其中
// Last.fm 每 5 秒一次的 `user.getrecenttracks` 一项就 4219 行;同一首歌的 "reusing existing
// entry" 打了 1158 遍;ListenBrainz 超时重试串上千行;没有等级只能靠前缀 grep;时间戳是 UTC
// 却不带时区标记,极易被当成本地时间读错。
//
// 几条刻意的取舍:
//   - **用 `slog.SetDefault` 桥接,不改 173 处 `log.Printf` 调用点**。桥接后 `log.Printf` 的
//     每一行以 Info 级进 handler(log 包自己的时间前缀被 slog 关掉,不会双时间戳)。新写的
//     日志用 `slog.Debug/Info/Warn/Error` + `key=value` 属性;老调用点按需逐处升级,不做一次性
//     大改(那种改法只会制造一个巨大的、没人敢细看的 diff)。
//   - **时间统一 UTC、RFC 3339 毫秒、带 Z**(`time=2026-09-05T00:00:00.000Z`)。App 侧 os.Logger
//     的记录是 `+0000`,两段日志对表不再靠脑补时区。诊断导出解析这个前缀,见
//     `CollectorLogLine.timestamp(of:)`(同时兼容老格式,.old 归档和迁移前的行仍是老格式)。
//   - **等级默认 info**,`config.json` 的 `log_level`(debug/info/warn/error)调,环境变量
//     `LYRIMUSE_LOG_LEVEL` 优先(手动在终端跑子命令排查时不用改配置文件)。审计日志的逐次
//     成功行在 Debug —— 默认不落盘,但**不是丢了**:同一目标一分钟一行汇总(见 networkobs.go
//     `recordAPICall`),失败行仍逐条 Warn。用户 2026-08-26 的要求是"所有对外请求全部记录",
//     汇总里的 count 就是那份记录,只是不再一行一次。
//   - **连续重复行折叠**(`repeatSquelcher`)走 syslog / journald 那套"last message repeated N
//     times":只折**连续**且模板相同的行(去掉 time= 与数字后一致),第一条原样立即写出、
//     不缓冲,所以不会丢信号也不会延迟首次出现。交替出现的两条(A B A B)不折——那正是
//     syslog 的语义,要更聪明的折叠留给诊断导出的 collapseRepeatedLines(它是离线全局的)。
//   - **常驻模式自己打开日志文件**,不再只依赖 launchd 把 stderr 指到文件:运行期按大小轮转
//     必须能换掉自己手里的 fd(rename 不会让 launchd 打开的那个 fd 转向新文件,见
//     logrotate.go 头注)。stderr 仍由 launchd 指着同一个文件,Go 运行时的 panic 输出照旧
//     落在那里。子命令(healthcheck 等)日志留在 stderr,终端里直接看。
//
// 退出前必须 `flushLogSink()`(exitreason.go 的 logExit 里调):折叠器里攒着的
// "repeated N times" 和审计汇总窗口里没到点的计数都在那一刻放出来。

import (
	"fmt"
	"io"
	"log"
	"log/slog"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// 时间戳格式:UTC、RFC 3339、毫秒、显式 Z。诊断导出按这个前缀解析(Swift 侧 CollectorLogLine)。
const logTimeLayout = "2006-01-02T15:04:05.000Z"

// 当前等级。默认 info;applyLogLevel 在配置加载后改它,handler 持有的是同一个 LevelVar,
// 改完即时生效,不用重建 handler。
var logLevel = new(slog.LevelVar)

// parseLogLevel 认 debug / info / warn(warning)/ error,不区分大小写;空串 = info(配置里
// 没写这项)。认不出返回 false,调用方保留当前等级并打一行提示——配置写错不该让日志静默变样。
func parseLogLevel(s string) (slog.Level, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug, true
	case "", "info":
		return slog.LevelInfo, true
	case "warn", "warning":
		return slog.LevelWarn, true
	case "error":
		return slog.LevelError, true
	}
	return slog.LevelInfo, false
}

// applyLogLevel:环境变量 LYRIMUSE_LOG_LEVEL 优先于配置文件的 log_level(环境变量是临时的、
// 给手动排查用;配置是持久的)。两者都认不出就保持默认。
func applyLogLevel(configured string) {
	if env := os.Getenv("LYRIMUSE_LOG_LEVEL"); env != "" {
		if lv, ok := parseLogLevel(env); ok {
			logLevel.Set(lv)
			return
		}
		log.Printf("log: unrecognized LYRIMUSE_LOG_LEVEL %q, falling back to config", env)
	}
	lv, ok := parseLogLevel(configured)
	if !ok {
		log.Printf("log: unrecognized log_level %q in config, keeping %s", configured, logLevel.Level())
		return
	}
	logLevel.Set(lv)
}

// newLogHandler:TextHandler(logfmt 风格,`time=… level=… msg=… key=value`),时间改成
// logTimeLayout。不用 JSONHandler:这份文件的第一读者是人(和 grep),不是日志平台。
func newLogHandler(w io.Writer) slog.Handler {
	return slog.NewTextHandler(w, &slog.HandlerOptions{
		Level: logLevel,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && a.Key == slog.TimeKey {
				if t, ok := a.Value.Any().(time.Time); ok {
					return slog.String(slog.TimeKey, t.UTC().Format(logTimeLayout))
				}
			}
			return a
		},
	})
}

// isDaemonInvocation:没有子命令(只有 flag 形式的参数,或什么都没有)= 常驻模式。
// 子命令(healthcheck / search-lyrics …)是人在终端跑的,日志留在 stderr。
func isDaemonInvocation(args []string) bool {
	return len(args) < 2 || strings.HasPrefix(args[1], "-")
}

// ---- 连续重复行折叠 ----

// 同一条重复超过这么久没再出现,就把攒着的计数放出来,并让下一次出现重新完整打印
// (否则一条几小时前的错误,今天再出现时只会变成一个 "+1")。
const repeatSquelchWindow = 60 * time.Second

var (
	logTimeAttrRe = regexp.MustCompile(`^time=\S+ `)
	logDigitsRe   = regexp.MustCompile(`\d+`)
)

// lineTemplate:判"同一条"的口径——去掉行首 time= 属性,再把所有数字段抹成 #。跟诊断导出的
// collapseRepeatedLines 同一个口径(那边也是抹数字),两处对"重复"的定义一致。
func lineTemplate(line string) string {
	line = logTimeAttrRe.ReplaceAllString(line, "")
	return logDigitsRe.ReplaceAllString(line, "#")
}

type repeatSquelcher struct {
	mu           sync.Mutex
	w            io.Writer
	lastTemplate string
	lastAt       time.Time
	repeats      int
	now          func() time.Time // 测试注入
}

func newRepeatSquelcher(w io.Writer) *repeatSquelcher {
	return &repeatSquelcher{w: w, now: time.Now}
}

// Write 收到的是 handler 写出的**一整行**(TextHandler 一条记录一次 Write)。
func (s *repeatSquelcher) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	tmpl := lineTemplate(string(p))
	if tmpl == s.lastTemplate && now.Sub(s.lastAt) <= repeatSquelchWindow {
		s.repeats++
		s.lastAt = now
		// 吞掉这一行,但向上游报"写成功了":这不是错误,是折叠。
		return len(p), nil
	}
	if err := s.flushLocked(now); err != nil {
		return 0, err
	}
	s.lastTemplate = tmpl
	s.lastAt = now
	return s.w.Write(p)
}

// flushLocked 把攒着的重复计数写成一行。调用方持锁。
func (s *repeatSquelcher) flushLocked(now time.Time) error {
	if s.repeats == 0 {
		return nil
	}
	n := s.repeats
	s.repeats = 0
	_, err := fmt.Fprintf(s.w, "time=%s level=INFO msg=\"last message repeated %d times\"\n",
		now.UTC().Format(logTimeLayout), n)
	return err
}

// Flush:退出前 / 定时维护调。超过窗口没再出现的重复也在这里结算,并清掉模板,让下一次
// 出现重新完整打印。
func (s *repeatSquelcher) Flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if s.repeats > 0 && now.Sub(s.lastAt) <= repeatSquelchWindow {
		// 还在窗口内、可能马上又来一条——不动,等下一轮维护或下一条不同的行来结算。
		return
	}
	_ = s.flushLocked(now)
	s.lastTemplate = ""
}

// flushNow:无条件结算(退出前用)。
func (s *repeatSquelcher) flushNow() {
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.flushLocked(s.now())
	s.lastTemplate = ""
}

// ---- 运行期按大小轮转的日志文件 ----

// rotatingLogFile:每次写之前看一眼"写完会不会超过上限",会就先归档再写。判据用自己累计的
// 字节数,不每次 Stat(那是一次系统调用;而这个文件除了我们只有 launchd 指着的 stderr 偶尔
// 写几行 panic,累计值足够准)。
type rotatingLogFile struct {
	mu       sync.Mutex
	path     string
	maxBytes int64
	f        *os.File
	size     int64
	// 启动时就轮转过了(给 installLogSink 打那行提示用)。
	rotatedAtOpen bool
}

// openRotatingLogFile:路径为空 / 打不开返回 nil,调用方退回 stderr。
func openRotatingLogFile(path string, maxBytes int64) *rotatingLogFile {
	if path == "" {
		return nil
	}
	w, rotated := rotateLogIfNeeded(path, maxBytes)
	f, ok := w.(*os.File)
	if !ok || f == os.Stderr {
		// 没到阈值(或路径不可轮转):自己追加打开这份文件。
		opened, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return nil
		}
		f = opened
	}
	r := &rotatingLogFile{path: path, maxBytes: maxBytes, f: f, rotatedAtOpen: rotated}
	if info, err := f.Stat(); err == nil {
		r.size = info.Size()
	}
	return r
}

func (r *rotatingLogFile) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.size > 0 && r.size+int64(len(p)) > r.maxBytes {
		r.rotateLocked()
	}
	n, err := r.f.Write(p)
	r.size += int64(n)
	return n, err
}

// rotateLocked:归档 + 新开。失败就继续写旧文件——宁可文件超大,也不能因为轮转失败丢日志。
// 轮转事件那一行直接写进新文件,不经 log 包(此刻持着锁,经 log 包会绕回 Write 自锁)。
func (r *rotatingLogFile) rotateLocked() {
	newF, ok := archiveAndReopen(r.path)
	if !ok {
		return
	}
	_ = r.f.Close()
	r.f = newF
	r.size = 0
	line := fmt.Sprintf("time=%s level=INFO msg=\"log: rotated, previous file exceeded %dMB, archived to lyrimuse.log.old\"\n",
		time.Now().UTC().Format(logTimeLayout), r.maxBytes/1024/1024)
	n, _ := r.f.WriteString(line)
	r.size += int64(n)
}

// ---- 装配 ----

var logSink struct {
	squelch *repeatSquelcher
	file    *rotatingLogFile
}

// installLogSink 是 main 里最早的一步(比解析参数还早,启动期任何一行日志都该走脱敏)。
// daemon = 常驻模式:写自己打开的日志文件、起后台维护;否则写 stderr。
func installLogSink(daemon bool) {
	var base io.Writer = os.Stderr
	if daemon {
		if f := openRotatingLogFile(logFilePath(), logRotateMaxBytes); f != nil {
			base = f
			logSink.file = f
		}
	}
	sq := newRepeatSquelcher(secretScrubber{w: base})
	logSink.squelch = sq
	slog.SetDefault(slog.New(newLogHandler(sq)))
	if logSink.file != nil && logSink.file.rotatedAtOpen {
		log.Printf("log: rotated at startup, previous file exceeded %dMB, archived to lyrimuse.log.old",
			logRotateMaxBytes/1024/1024)
	}
	if daemon {
		go logSinkMaintenanceLoop()
	}
}

// logSinkMaintenanceLoop:每 30 秒结算一次超过窗口的重复计数和到点的审计汇总。只在常驻模式跑;
// 子命令生命周期短,退出时 flushLogSink 一次性结算就够。
func logSinkMaintenanceLoop() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for range t.C {
		flushAPICallSummaries(time.Now(), false)
		if logSink.squelch != nil {
			logSink.squelch.Flush()
		}
	}
}

// flushLogSink:退出前把两处攒着的东西全放出来。顺序刻意:先汇总(它们经 handler 走到折叠器),
// 再结算折叠器。
func flushLogSink() {
	flushAPICallSummaries(time.Now(), true)
	if logSink.squelch != nil {
		logSink.squelch.flushNow()
	}
}
