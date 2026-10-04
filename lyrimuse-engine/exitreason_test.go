package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

// 退出原因日志的形态是被 grep 依赖的契约:前缀固定、原因码英文 snake_case。
func TestLogExitFormat(t *testing.T) {
	var buf bytes.Buffer
	prevOut, prevFlags := log.Writer(), log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	defer func() {
		log.SetOutput(prevOut)
		log.SetFlags(prevFlags)
	}()

	logExit(exitReasonAlreadyRunning, "")
	logExit(exitReasonRunError, "err=boom")
	got := buf.String()
	if !strings.Contains(got, "exiting reason=already_running\n") {
		t.Fatalf("detail 为空时应只有前缀,got %q", got)
	}
	if !strings.Contains(got, "exiting reason=run_error err=boom\n") {
		t.Fatalf("带 detail 的形态不对,got %q", got)
	}

	for _, code := range []string{
		exitReasonAlreadyRunning, exitReasonSignal, exitReasonRunError,
		exitReasonConfigUnreadable, exitReasonHomeDirUnresolved, exitReasonRunReturned,
	} {
		for _, ch := range code {
			if ch != '_' && (ch < 'a' || ch > 'z') {
				t.Fatalf("原因码 %q 不是英文 snake_case,grep 时要转义", code)
			}
		}
	}
}
