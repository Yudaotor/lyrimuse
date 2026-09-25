package main

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"
)

// 每一个歌词源都必须有主机映射到它 —— 没有的话 observe 拿到空源名直接 return,
// 那个源的失败一次都不会被记录,熔断对它永远不触发。
//
// applemusic 曾是唯一一个从未被熔断过的源(另外十个累计触发
// 1000+ 次,它 0 次),不是因为它稳,是因为 amp-api.music.apple.com 不在表里。
// 这条用例按 lyricSourceNames 逐个反查,再添新源时漏掉映射会立刻失败。
func TestEveryLyricSourceHasAHostMapping(t *testing.T) {
	// 每个源至少一个真实会被请求到的主机。新增源时这里也要补一条。
	hosts := map[string][]string{
		"netease":    {"music.163.com"},
		"qq":         {"c.y.qq.com", "u.y.qq.com"},
		"kugou":      {"mobilecdn.kugou.com", "lyrics.kugou.com", "krcs.kugou.com"},
		"lrclib":     {"lrclib.net"},
		"musixmatch": {"apic-appmobile.musixmatch.com"},
		"amll":       {"raw.githubusercontent.com"},
		"lyricfind":  {"music.youtube.com"},
		"kuwo":       {"search.kuwo.cn"},
		"migu":       {"pd.musicapp.migu.cn", "d.musicapp.migu.cn"},
		"deezer":     {"api.deezer.com", "pipe.deezer.com", "auth.deezer.com"},
		"applemusic": {"amp-api.music.apple.com"},
		"soda":       {sodaSeoTrackHost, sodaSearchHost},
	}
	for _, source := range lyricSourceNames {
		hs, ok := hosts[source]
		if !ok {
			t.Errorf("歌词源 %q 在这张表里没有登记主机 —— 补上,或者确认它真的不发 HTTP 请求", source)
			continue
		}
		for _, h := range hs {
			if got := lyricSourceForHost(h); got != source {
				t.Errorf("lyricSourceForHost(%q) = %q, 期望 %q —— 该源的失败不会被熔断记录", h, got, source)
			}
		}
	}
}

// 反面:Apple 的另外两个主机用途完全不同,绝不能被卷进 applemusic 这个歌词源。
// 把它们归进去,等于让目录检索的限流 / 没连账号去停掉一个能出歌词的源。
func TestNonLyricAppleHostsStayUnmapped(t *testing.T) {
	for _, h := range []string{
		"itunes.apple.com",      // 公开目录检索,有自己的端点级退避(apple.go)
		"music.apple.com",       // 抓 developer token 的 web origin
		"mvod.itunes.apple.com", // 试听流
		"is1-ssl.mzstatic.com",  // 封面 CDN
	} {
		if got := lyricSourceForHost(h); got != "" {
			t.Errorf("lyricSourceForHost(%q) = %q —— 这个主机跟歌词正文无关,不该进歌词源熔断", h, got)
		}
	}
}

// ---- MusicBrainz "刚刚没查成"的负缓存 ----
//
// 这条路径挂在别名轮的构造阶段,每次查询都要排 musicbrainzThrottle 那把 1.1 秒的全局锁。
// 原来查失败连内存都不写(刻意的:一次偶发 503 不该把歌手钉死成"无别名"),于是同一位
// 歌手在一轮轮别名轮里反复重查 —— 实测 9531 次调用只攒下 311 条缓存,1743 次是限速 503,
// 而且均匀铺在每个小时。负缓存把重试节奏收敛成"最多每 TTL 一次",原意不变。

func resetMBLookupBackoff(t *testing.T) {
	t.Helper()
	clear := func() {
		mbPrimaryNameMu.Lock()
		mbLookupFailedUntil = map[string]time.Time{}
		mbPrimaryNameMu.Unlock()
	}
	clear()
	t.Cleanup(clear)
}

func TestMBLookupFailureBackoff(t *testing.T) {
	base := time.Date(2026, 9, 20, 4, 0, 0, 0, time.UTC)
	const who = "Khalil Fong"

	t.Run("没失败过就不退避", func(t *testing.T) {
		resetMBLookupBackoff(t)
		if mbLookupInFailureBackoff(who, base) {
			t.Error("初始状态不该在退避里")
		}
	})

	t.Run("失败后按 TTL 退避", func(t *testing.T) {
		resetMBLookupBackoff(t)
		noteMBLookupFailure(who, errors.New("503"), base)
		if !mbLookupInFailureBackoff(who, base.Add(mbLookupFailureTTL-time.Second)) {
			t.Error("TTL 内该退避")
		}
		if mbLookupInFailureBackoff(who, base.Add(mbLookupFailureTTL+time.Second)) {
			t.Error("TTL 过了就该放行 —— 不能把歌手永久钉死成「无别名」")
		}
	})

	t.Run("退避只针对这一位歌手", func(t *testing.T) {
		resetMBLookupBackoff(t)
		noteMBLookupFailure(who, errors.New("503"), base)
		if mbLookupInFailureBackoff("另一位歌手", base) {
			t.Error("一位歌手查失败不该连累别人")
		}
	})

	// ctx 取消是用户主动取消解析,不是 MusicBrainz 的毛病 —— 跟熔断器对
	// context.Canceled 的处理同一条理由。记了的话用户取消一次就白退避 10 分钟。
	t.Run("ctx 取消不计入退避", func(t *testing.T) {
		resetMBLookupBackoff(t)
		noteMBLookupFailure(who, context.Canceled, base)
		if mbLookupInFailureBackoff(who, base.Add(time.Second)) {
			t.Error("用户取消不该让这位歌手退避")
		}
		// 包装过的 context.Canceled 同样要认出来。
		noteMBLookupFailure(who, fmt.Errorf("lookup: %w", context.Canceled), base)
		if mbLookupInFailureBackoff(who, base.Add(time.Second)) {
			t.Error("被包装的 context.Canceled 也该豁免")
		}
	})

	t.Run("超时这类真失败要计入", func(t *testing.T) {
		resetMBLookupBackoff(t)
		noteMBLookupFailure(who, context.DeadlineExceeded, base)
		if !mbLookupInFailureBackoff(who, base.Add(time.Second)) {
			t.Error("超时是真的没查成,该退避")
		}
	})
}
