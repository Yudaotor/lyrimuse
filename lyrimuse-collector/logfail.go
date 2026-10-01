package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"
)

// 失败类日志的两个出口,用法跟 log.Printf 一样(格式串 + 参数,错误值放最后)。
//
//   - warnf:要人看的失败(上报 / 回填 / 中继 / 通知没发出去、数据没写成、配置文件解析不了、功能被停用)。
//   - infoFailf:已经有兜底、或同一次请求已由 doHTTPTracked 逐条记过 WARN 的失败,再记一行 Warn 就是重复。
//
// 两者都认调用方主动取消(退出时的 SIGTERM、切歌、这一轮已经选出结果):参数里有 context.Canceled
// 的错误就降到 Debug,那是正常收尾。错误被 %v 包进字符串、链上认不出来的,按文案结尾认。
func warnf(format string, args ...any) { logFailuref(slog.LevelWarn, format, args...) }

func infoFailf(format string, args ...any) { logFailuref(slog.LevelInfo, format, args...) }

func logFailuref(level slog.Level, format string, args ...any) {
	for _, a := range args {
		if err, ok := a.(error); ok && isCanceledErr(err) {
			level = slog.LevelDebug
			break
		}
	}
	slog.Log(context.Background(), level, fmt.Sprintf(format, args...))
}

func isCanceledErr(err error) bool {
	return errors.Is(err, context.Canceled) || strings.HasSuffix(err.Error(), context.Canceled.Error())
}

// logClock:日志正文里的时刻一律按 UTC 写、带 Z,跟行首的 time= 同一口径。写成本地时间
// 又不标时区的话,跟行首差着时区,读日志时要自己换算。
func logClock(t time.Time) string { return t.UTC().Format("15:04:05Z") }
