package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"testing"
	"time"
)

// 这一组守的是 2026-08-30 修的那条真实数据丢失:Last.fm 镜像失败时,收听在三个地方
// 同时不留痕(lfmMirrored 已标记 → 幂等守卫永久挡死;mirrorAsync 只打日志不重试;
// p.lfm != nil 时 appendListen 被跳过),一次网络抖动就永久少一条 scrobble。
// 用户真实日志:2618 次成功收听里有 13 条这样丢掉的。
//
// 修法不是"撤销标记重发"(会从 goroutine 并发写 poller 的裸 map,fatal error),而是
// 把失败落进 listens.jsonl 交给已有的回填。所以下面每个用例对应的都是"这一类失败该
// 不该、以及怎么留痕",判错任何一类的代价都是不对称的:
//   - 该留没留 → 永久少一条(修之前的状态)
//   - 不该留却留了 → 回填时往 Last.fm 写重复,而 scrobble 落进去基本删不掉

func TestProvablyNeverSent(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{
			// 实测日志里最多的一类:08-15 一次 40 分钟 DNS 故障丢了 10 条。
			// 连 TCP 都没建起来,服务端不可能见过它 → 补提交零重复风险。
			name: "DNS 解析失败 = 确定没发出去",
			err:  fmt.Errorf("post: %w", &net.DNSError{Err: "no such host", Name: "ws.audioscrobbler.com"}),
			want: true,
		},
		{
			name: "dial 阶段失败 = 确定没发出去",
			err:  fmt.Errorf("post: %w", &net.OpError{Op: "dial", Err: errors.New("connection refused")}),
			want: true,
		},
		{
			// ⚠️ 最要紧的一条:连接已建立,请求可能已经到了服务端并落库,只是回执丢了。
			// 判成 true 就会在回填时造出永久删不掉的重复。
			name: "read 阶段失败 = 不确定,必须判 false",
			err:  fmt.Errorf("post: %w", &net.OpError{Op: "read", Err: errors.New("no route to host")}),
			want: false,
		},
		{
			// context deadline 的错误链里没有 *net.OpError(只有 http 自己的 timeoutError),
			// 所以天然落到 false 这边 —— 正是想要的,但要钉住,免得以后有人"顺手"加匹配。
			name: "context deadline = 不确定,必须判 false",
			err:  fmt.Errorf("post: %w", context.DeadlineExceeded),
			want: false,
		},
		{
			name: "应用层错误 = 服务端已表态,不是没发出去",
			err:  &lastfmAPIError{Code: 11, Message: "Service Offline", Method: "track.scrobble"},
			want: false,
		},
		{
			name: "普通错误",
			err:  errors.New("boom"),
			want: false,
		},
	}
	for _, c := range cases {
		if got := provablyNeverSent(c.err); got != c.want {
			t.Errorf("%s: provablyNeverSent(%v) = %v, want %v", c.name, c.err, got, c.want)
		}
	}
}

// recordFailedMirror 的分流:三类失败三种留痕方式,合并成一种就必然错一边。
func TestRecordFailedMirrorRouting(t *testing.T) {
	countByType := func(t *testing.T) (l, q int) {
		t.Helper()
		for _, line := range readListenLog() {
			switch line.T {
			case "l":
				l++
			case "q":
				q++
			}
		}
		return
	}

	t.Run("确定没发出去 → 只写 l,回填会正常挑走", func(t *testing.T) {
		dir := t.TempDir()
		saved := listenLogPath
		defer func() { listenLogPath = saved }()
		listenLogPath = filepath.Join(dir, "l.jsonl")

		uts := time.Now().Add(-time.Hour).Unix()
		recordFailedMirror(
			fmt.Errorf("post: %w", &net.DNSError{Err: "no such host"}),
			"周杰倫", "七里香", "七里香", uts, 300)

		l, q := countByType(t)
		if l != 1 || q != 0 {
			t.Fatalf("want 1 listen + 0 quarantine, got l=%d q=%d", l, q)
		}
		pending, _ := pendingBackfillListens(time.Now())
		if len(pending) != 1 {
			t.Fatalf("确定没发出去的这条必须能被回填挑走, got %d pending", len(pending))
		}
		// 存的必须是**播放器报的原始艺人名**,不是 collapse 折叠后的值 —— 回填会拿它
		// 重新跑一遍同样的归一化,喂折叠后的值进去等于折叠两次(见 listenLogLine.AR)。
		if pending[0].AR != "周杰倫" {
			t.Fatalf("AR 必须是原始标签, got %q", pending[0].AR)
		}
	})

	t.Run("不确定发没发到 → 写 l+q,且回填绝不自动重试", func(t *testing.T) {
		dir := t.TempDir()
		saved := listenLogPath
		defer func() { listenLogPath = saved }()
		listenLogPath = filepath.Join(dir, "l.jsonl")

		uts := time.Now().Add(-time.Hour).Unix()
		recordFailedMirror(
			fmt.Errorf("post: %w", context.DeadlineExceeded),
			"周杰倫", "七里香", "七里香", uts, 300)

		l, q := countByType(t)
		if l != 1 || q != 1 {
			t.Fatalf("want 1 listen + 1 quarantine, got l=%d q=%d", l, q)
		}
		// q 的意义就是"排除且绝不自动重试" —— 重复比漏补贵得多。
		if pending, _ := pendingBackfillListens(time.Now()); len(pending) != 0 {
			t.Fatalf("隔离的条目绝不能被自动回填, got %d pending", len(pending))
		}
	})

	t.Run("服务端拒收内容本身(accepted=0) → 什么都不写", func(t *testing.T) {
		dir := t.TempDir()
		saved := listenLogPath
		defer func() { listenLogPath = saved }()
		listenLogPath = filepath.Join(dir, "l.jsonl")

		// 实测成因:艺人名是"群星"(Various Artists),Last.fm 当非艺人拒收。
		// 换多少次也还是这首歌,重发必然同样被拒。
		recordFailedMirror(
			&lastfmIgnoredError{Method: "track.scrobble", Reason: "1 Artist was ignored"},
			"群星", "这样吧", "烧的时尚", time.Now().Unix(), 200)

		if l, q := countByType(t); l != 0 || q != 0 {
			t.Fatalf("内容被拒收不该留痕, got l=%d q=%d", l, q)
		}
	})

	// ⚠️ 这一组守的是 2026-08-30 当天抓出来的回归:首版把**全部** lastfmAPIError 都当成
	// "拒收"直接 return,于是一次限流/凭据失效就让这首歌在 Last.fm 和 listens.jsonl 两边
	// 同时没有 —— 正是这个函数本身要修的那个洞,换个门又开了一遍。
	t.Run("应用层错误按 mayHaveStored 分档,绝不一律丢弃", func(t *testing.T) {
		cases := []struct {
			name    string
			code    int
			wantQ   int
			because string
		}{
			{"限流 29 = 确定没落库,该留痕待补", 29, 0, "服务端明确拒绝了这次写入"},
			{"凭据失效 9 = 确定没落库,该留痕待补", 9, 0, "重新授权后正该靠回填补回来"},
			{"服务不可用 11 = 可能已落库,必须隔离", 11, 1, "重发是最大的自造重复源"},
			{"服务不可用 16 = 可能已落库,必须隔离", 16, 1, "同 11"},
		}
		for _, c := range cases {
			dir := t.TempDir()
			saved := listenLogPath
			listenLogPath = filepath.Join(dir, "l.jsonl")

			recordFailedMirror(
				&lastfmAPIError{Code: c.code, Message: "x", Method: "track.scrobble"},
				"周杰倫", "七里香", "七里香", time.Now().Add(-time.Hour).Unix(), 300)
			l, q := countByType(t)
			listenLogPath = saved

			if l != 1 {
				t.Errorf("%s: 必须留痕(%s), got l=%d", c.name, c.because, l)
			}
			if q != c.wantQ {
				t.Errorf("%s: quarantine 应为 %d(%s), got %d", c.name, c.wantQ, c.because, q)
			}
		}
	})
}

// mayHaveStored 是 recordFailedMirror(活路径)和 runBackfill(回填整批隔离)**共用**的
// 判据,两处都拿它决定"这一条要不要被永久排除"。判错的代价不对称:
//   - 该隔离没隔离 → 重发,用户历史里多一条永久删不掉的重复
//   - 不该隔离却隔离了 → 一条(回填时是**整批最多 50 条**)从没提交过的收听被彻底
//     踢出清单,再点多少次回填也补不回来
//
// 所以这张表就是这两处行为的规格,改它等于同时改两处。
func TestLastfmAPIErrorMayHaveStored(t *testing.T) {
	cases := []struct {
		code int
		want bool
		why  string
	}{
		{11, true, "Service Offline:服务端可能已落库、只是回执丢了"},
		{16, true, "temporarily unavailable:同 11"},
		{29, false, "限流:服务端明确拒绝了这次写入,确定没落库"},
		{4, false, "Authentication Failed:没通过鉴权,确定没落库"},
		{9, false, "Invalid session key:同上"},
		{10, false, "Invalid API key:同上"},
		{26, false, "API key suspended:同上"},
		{6, false, "参数错误:服务端表过态,确定没落库"},
	}
	for _, c := range cases {
		e := &lastfmAPIError{Code: c.code, Method: "track.scrobble"}
		if got := e.mayHaveStored(); got != c.want {
			t.Errorf("error %d: mayHaveStored() = %v, want %v (%s)", c.code, got, c.want, c.why)
		}
	}
}

// ignoredReason 把服务端给的真实原因取出来。修之前活路径整个丢掉它,只报一句笼统的
// accepted=0 —— 排查那 5 条真实失败时只能靠翻日志上下文猜是哪首歌、为什么被拒。
func TestIgnoredReason(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "带 code 和人话原因",
			raw:  `{"timestamp":"1","ignoredMessage":{"code":"1","#text":"Artist was ignored"}}`,
			want: "1 Artist was ignored",
		},
		{
			name: "只有 code",
			raw:  `{"timestamp":"1","ignoredMessage":{"code":"6","#text":""}}`,
			want: "code 6",
		},
		{
			// code 0 = 没被忽略。出现在这里说明回执自相矛盾,不该被当成原因报出去。
			name: "code 0 不当原因",
			raw:  `{"timestamp":"1","ignoredMessage":{"code":"0","#text":""}}`,
			want: "",
		},
		{
			name: "解不开时返回空,调用方那句 accepted=0 本身仍然可用",
			raw:  `"garbage"`,
			want: "",
		},
	}
	for _, c := range cases {
		if got := ignoredReason(json.RawMessage(c.raw)); got != c.want {
			t.Errorf("%s: ignoredReason() = %q, want %q", c.name, got, c.want)
		}
	}
}
