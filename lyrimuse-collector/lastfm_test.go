package main

import (
	"testing"
	"time"
)

// shouldDisable 的裁决规则:9/10/26 一击致命;4 要两击坐实(间隔 ≥30s、≤30min);
// 非致命码永不熔断;成功洗清嫌疑;过期嫌疑重新开桩。时间全部显式传入,不碰真实时钟。
func TestShouldDisableErrorFourNeedsConfirmation(t *testing.T) {
	e4 := &lastfmAPIError{Code: 4, Message: "Authentication Failed", Method: "track.updateNowPlaying"}
	t0 := time.Unix(1_800_000_000, 0)

	t.Run("非致命码永不熔断", func(t *testing.T) {
		s := &lastfmScrobbler{}
		e16 := &lastfmAPIError{Code: 16, Message: "temporarily unavailable", Method: "track.scrobble"}
		if s.shouldDisable(e16, t0) {
			t.Fatal("error 16 是暂时性错误,不该熔断")
		}
		if s.suspect4.Load() != 0 {
			t.Fatal("非致命码不该记 error 4 嫌疑")
		}
	})

	t.Run("9/10/26 一击致命", func(t *testing.T) {
		for _, code := range []int{9, 10, 26} {
			s := &lastfmScrobbler{}
			e := &lastfmAPIError{Code: code, Message: "x", Method: "track.scrobble"}
			if !s.shouldDisable(e, t0) {
				t.Fatalf("error %d 是明确的凭据死亡,该立即熔断", code)
			}
		}
	})

	t.Run("单发 error 4 只记嫌疑", func(t *testing.T) {
		s := &lastfmScrobbler{}
		if s.shouldDisable(e4, t0) {
			t.Fatal("首发 error 4 不该熔断(可能是服务端误报)")
		}
		if s.suspect4.Load() != t0.UnixNano() {
			t.Fatal("首发 error 4 该记下嫌疑时刻")
		}
	})

	t.Run("30s 内的重复失败算同一击", func(t *testing.T) {
		s := &lastfmScrobbler{}
		s.shouldDisable(e4, t0)
		// 换歌那一刻 nowPlaying+scrobble 几乎同时各失败一发,是同一次故障。
		if s.shouldDisable(e4, t0.Add(2*time.Second)) {
			t.Fatal("burst 内的第二发不该坐实")
		}
		if s.suspect4.Load() != t0.UnixNano() {
			t.Fatal("burst 内不该刷新嫌疑起点(否则持续失败永远凑不满间隔)")
		}
	})

	t.Run("间隔 30s 后复发即坐实", func(t *testing.T) {
		s := &lastfmScrobbler{}
		s.shouldDisable(e4, t0)
		if !s.shouldDisable(e4, t0.Add(40*time.Second)) {
			t.Fatal("真撤销时每次调用都失败,第二击该熔断")
		}
	})

	t.Run("成功洗清嫌疑", func(t *testing.T) {
		s := &lastfmScrobbler{}
		s.shouldDisable(e4, t0)
		s.suspect4.Store(0) // mirrorAsync 成功路径做的事
		if s.shouldDisable(e4, t0.Add(40*time.Second)) {
			t.Fatal("嫌疑被成功洗清后,再发 error 4 是新的首发,不该熔断")
		}
	})

	t.Run("超过 30min 的旧嫌疑作废", func(t *testing.T) {
		s := &lastfmScrobbler{}
		s.shouldDisable(e4, t0)
		second := t0.Add(31 * time.Minute)
		if s.shouldDisable(e4, second) {
			t.Fatal("隔了半小时的孤立误报不该累积成死刑")
		}
		if s.suspect4.Load() != second.UnixNano() {
			t.Fatal("过期后该以这一发重新开桩")
		}
		if !s.shouldDisable(e4, second.Add(40*time.Second)) {
			t.Fatal("重新开桩后按正常两击规则坐实")
		}
	})
}
