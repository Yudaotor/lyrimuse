package main

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func useFakeOnDevice(t *testing.T, fake func(context.Context, string, []string) ([]string, error)) {
	t.Helper()
	savedTranslator, savedTimeout := onDeviceTranslator, onDeviceTranslateTimeout
	onDeviceSkips.reset()
	onDeviceTranslator = fake
	t.Cleanup(func() {
		onDeviceTranslator, onDeviceTranslateTimeout = savedTranslator, savedTimeout
		onDeviceSkips.reset()
	})
}

var onDeviceSkipTexts = []string{"I found a secret note", "It's supernatural"}

// 端上翻译卡住:到这一组自己的时限就放手交给网络,而且接下来一段时间不再起 helper。
func TestOnDeviceTimeoutFallsBackAndIsRemembered(t *testing.T) {
	var calls int32
	useFakeOnDevice(t, func(ctx context.Context, _ string, _ []string) ([]string, error) {
		atomic.AddInt32(&calls, 1)
		<-ctx.Done()
		return nil, ctx.Err()
	})
	onDeviceTranslateTimeout = 50 * time.Millisecond

	out := make([]string, len(onDeviceSkipTexts))
	started := time.Now()
	pending := translateOnDeviceByScript(context.Background(), "zh-CN", onDeviceSkipTexts, out)
	if took := time.Since(started); took > 2*time.Second {
		t.Fatalf("卡住的端上翻译拖了 %s,没按这一组的时限放手", took)
	}
	if len(pending) != len(onDeviceSkipTexts) {
		t.Fatalf("超时的那组要整组交给网络: pending=%v", pending)
	}
	_ = translateOnDeviceByScript(context.Background(), "zh-CN", onDeviceSkipTexts, make([]string, len(onDeviceSkipTexts)))
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("超时之后还在起 helper: 调了 %d 次", got)
	}
}

// 语言包没装:记住,下一首同一种文字直接走网络。
func TestOnDevicePackMissingIsRemembered(t *testing.T) {
	var calls int32
	useFakeOnDevice(t, func(context.Context, string, []string) ([]string, error) {
		atomic.AddInt32(&calls, 1)
		return nil, errOnDevicePackMissing
	})
	if !errors.Is(errOnDevicePackMissing, errOnDeviceUnavailable) {
		t.Fatal("语言包没装也得算端上走不通,调用方才会安静退回网络")
	}
	for i := 0; i < 3; i++ {
		pending := translateOnDeviceByScript(context.Background(), "zh-CN", onDeviceSkipTexts, make([]string, len(onDeviceSkipTexts)))
		if len(pending) != len(onDeviceSkipTexts) {
			t.Fatalf("第 %d 次: 没翻成的组要交给网络, pending=%v", i, pending)
		}
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("语言包没装之后还在每首都问: 调了 %d 次", got)
	}
}

// 别的「走不通」(系统太老、源语言认不出、helper 不在)不记:那些要么立刻就返回,要么跟这一首的内容有关。
func TestOnDeviceOtherUnavailableIsNotRemembered(t *testing.T) {
	var calls int32
	useFakeOnDevice(t, func(context.Context, string, []string) ([]string, error) {
		atomic.AddInt32(&calls, 1)
		return nil, errOnDeviceUnavailable
	})
	for i := 0; i < 2; i++ {
		translateOnDeviceByScript(context.Background(), "zh-CN", onDeviceSkipTexts, make([]string, len(onDeviceSkipTexts)))
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("不该记住的不可用被记住了: 调了 %d 次", got)
	}
}

// 整首的额度先用完时不算这一组超时,不记。
func TestOnDeviceParentDeadlineIsNotRemembered(t *testing.T) {
	useFakeOnDevice(t, func(ctx context.Context, _ string, _ []string) ([]string, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	translateOnDeviceByScript(ctx, "zh-CN", onDeviceSkipTexts, make([]string, len(onDeviceSkipTexts)))
	if onDeviceSkips.skipping(dominantScript(onDeviceSkipTexts[0]), appleLangCode("zh-CN"), time.Now()) {
		t.Fatal("整首到点不是端上这一组的问题,不该被记住")
	}
}

func TestOnDeviceSkipExpires(t *testing.T) {
	onDeviceSkips.reset()
	t.Cleanup(onDeviceSkips.reset)
	t0 := time.Unix(1_800_000_000, 0)
	latin := dominantScript("hello")
	onDeviceSkips.note(latin, "zh-Hans", t0)
	if !onDeviceSkips.skipping(latin, "zh-Hans", t0.Add(onDeviceSkipFor-time.Minute)) {
		t.Fatal("记住期间应当跳过")
	}
	if onDeviceSkips.skipping(latin, "zh-Hans", t0.Add(onDeviceSkipFor+time.Minute)) {
		t.Fatal("过了期限要重新问一次(用户可能刚装了语言包)")
	}
	if onDeviceSkips.skipping(latin, "ja", t0) {
		t.Fatal("别的目标语言不受影响")
	}
	if onDeviceSkips.skipping(dominantScript("你好"), "zh-Hans", t0) {
		t.Fatal("别的文字系统不受影响")
	}
}
