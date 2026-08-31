package main

import (
	"context"
	"testing"
	"time"
)

// 2026-08-31 真实bug:陶喆和盧廣仲《那個女孩》这首本地匹配不到的歌,"换个身份再搜"+
// "按标题反查"两轮兜底加起来在 13 秒内连发了 16 次网易云请求,把自己先撞成限流(见
// neteaseMinIntervalBetweenCalls 头注)。这组测试锁定 neteaseThrottle 本身的行为,跟
// musicbrainzThrottle 同一个模式、同一批判据。
func TestNeteaseThrottle(t *testing.T) {
	saved := neteaseLastCall
	t.Cleanup(func() { neteaseLastCall = saved })

	t.Run("很久没调用过时不等待", func(t *testing.T) {
		neteaseLastCall = time.Now().Add(-time.Hour)
		start := time.Now()
		if err := neteaseThrottle(context.Background()); err != nil {
			t.Fatalf("neteaseThrottle() = %v, want nil", err)
		}
		if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
			t.Errorf("不该等待,实际等了 %v", elapsed)
		}
	})

	t.Run("紧接着再调用一次要等满最小间隔", func(t *testing.T) {
		neteaseLastCall = time.Now()
		start := time.Now()
		if err := neteaseThrottle(context.Background()); err != nil {
			t.Fatalf("neteaseThrottle() = %v, want nil", err)
		}
		elapsed := time.Since(start)
		if elapsed < neteaseMinIntervalBetweenCalls-10*time.Millisecond {
			t.Errorf("等待时间 %v 短于最小间隔 %v", elapsed, neteaseMinIntervalBetweenCalls)
		}
	})

	t.Run("等待中途取消:提前返回错误,不占用这次调用名额", func(t *testing.T) {
		neteaseLastCall = time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
		defer cancel()
		beforeCall := neteaseLastCall
		start := time.Now()
		err := neteaseThrottle(ctx)
		if err == nil {
			t.Fatal("ctx 超时应该返回错误,got nil")
		}
		if elapsed := time.Since(start); elapsed > neteaseMinIntervalBetweenCalls {
			t.Errorf("应该在 ctx 超时(10ms)时就提前返回,实际等了 %v", elapsed)
		}
		if neteaseLastCall != beforeCall {
			t.Error("取消等待不该更新 neteaseLastCall,不然会占用一次不存在的调用名额")
		}
	})
}
