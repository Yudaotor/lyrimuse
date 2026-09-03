package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

// 2026-08-31 真实bug:陶喆和盧廣仲《那個女孩》这首本地匹配不到的歌,"换个身份再搜"+
// "按标题反查"两轮兜底加起来在 13 秒内连发了 16 次网易云请求,把自己先撞成限流(见
// neteaseMinIntervalBetweenCalls 头注)。这组测试锁定 neteaseThrottle 本身的行为,跟
// musicbrainzThrottle 同一个模式、同一批判据。
func TestNeteaseThrottle(t *testing.T) {
	savedCall := neteaseLastCall
	savedCooldown := neteaseCooldownUntil
	t.Cleanup(func() {
		neteaseLastCall = savedCall
		neteaseCooldownUntil = savedCooldown
	})
	resetCooldowns := func() { neteaseCooldownUntil = map[string]time.Time{} }

	t.Run("很久没调用过时不等待", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		start := time.Now()
		if err := neteaseThrottle(context.Background(), "https://music.163.com/api/search/get/web"); err != nil {
			t.Fatalf("neteaseThrottle() = %v, want nil", err)
		}
		if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
			t.Errorf("不该等待,实际等了 %v", elapsed)
		}
	})

	t.Run("紧接着再调用一次要等满最小间隔", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now()
		start := time.Now()
		if err := neteaseThrottle(context.Background(), "https://music.163.com/api/search/get/web"); err != nil {
			t.Fatalf("neteaseThrottle() = %v, want nil", err)
		}
		elapsed := time.Since(start)
		if elapsed < neteaseMinIntervalBetweenCalls-10*time.Millisecond {
			t.Errorf("等待时间 %v 短于最小间隔 %v", elapsed, neteaseMinIntervalBetweenCalls)
		}
	})

	t.Run("等待中途取消:提前返回错误,不占用这次调用名额", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
		defer cancel()
		beforeCall := neteaseLastCall
		start := time.Now()
		err := neteaseThrottle(ctx, "https://music.163.com/api/search/get/web")
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

	// 2026-09-02 新增:探测到网易云 body 拒绝之后的退避行为(neteaseReportBlocked)。
	// 见 neteaseBlockCooldownBase 头注 —— 为什么退避必须按端点桶,不能是全局的。
	// ⚠️ 这一条 2026-09-02 当天改过语义。**原来断言的是「被标记退避的端点应该等到退避期满」**
	// (返回 nil、耗时 >= 退避期),现在断言的是「立刻返回 errNeteaseBucketCooling、一点都不等」。
	//
	// 改的理由是实测,不是口味:「搜索候选歌词」搜 DAOKO×米津玄師《打上花火》,逐条打时间戳量到
	// **整次搜索 150 秒以上,其中约 120 秒睡在这层退避里**,而且睡出来是一条 30/60/90/120/150 秒
	// 的等差数列。调用方(retryTitleFromArtistSearchDetailed / neteaseAlbumIDByName)都是
	// "主端点不行就换备用端点"的两段式写法,而备用端点是**另一个桶、当时完全健康、150ms 就回**——
	// 睡满 30 秒只是为了醒来再被 405 拒一次,然后才轮到那条本来就通的路。
	//
	// 立刻返回错误对「被限流就别继续敲门」这个原始意图**更强**:退避期内一个请求都不发
	// (旧写法睡完还要发一个去试)。
	t.Run("退避期内的端点桶立刻拒绝,不睡", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour) // 最小间隔那层不参与,只看退避
		const blocked = "https://music.163.com/api/search/get/web?type=1&s=a"
		neteaseReportBlocked(blocked, time.Second)

		start := time.Now()
		err := neteaseThrottle(context.Background(), blocked)
		if !errors.Is(err, errNeteaseBucketCooling) {
			t.Fatalf("neteaseThrottle() = %v, want errNeteaseBucketCooling", err)
		}
		if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
			t.Errorf("退避期内应当立刻返回,实际等了 %v", elapsed)
		}
	})

	t.Run("退避期过了就正常放行", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		const blocked = "https://music.163.com/api/search/get/web?type=1&s=a"
		neteaseReportBlocked(blocked, 20*time.Millisecond)
		time.Sleep(40 * time.Millisecond) // 等退避期自然过掉

		if err := neteaseThrottle(context.Background(), blocked); err != nil {
			t.Fatalf("退避期已过,应当放行,got %v", err)
		}
	})

	t.Run("不同路径不共享退避:换成另一个端点的备用桶立刻放行", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		const primary = "https://music.163.com/api/search/get/web?type=1&s=a"
		const fallback = "https://music.163.com/api/search/get?type=1&s=a" // 不同路径,独立分桶
		neteaseReportBlocked(primary, time.Second)

		start := time.Now()
		if err := neteaseThrottle(context.Background(), fallback); err != nil {
			t.Fatalf("neteaseThrottle() = %v, want nil", err)
		}
		if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
			t.Errorf("备用端点不该被主端点的退避连带卡住,实际等了 %v", elapsed)
		}
	})

	t.Run("同一路径不同 query 共享同一个桶", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		neteaseReportBlocked("https://music.163.com/api/search/get/web?type=1&s=a", time.Second)

		// 同路径、不同 query(type=10,专辑搜索用的那种)——应该被同一个桶挡住。
		// 「挡住」的表现 2026-09-02 起是**立刻拒绝**而不是等满,见上面那条的说明。
		err := neteaseThrottle(context.Background(), "https://music.163.com/api/search/get/web?type=10&s=b")
		if !errors.Is(err, errNeteaseBucketCooling) {
			t.Fatalf("同路径不同 query 应该共享退避,got %v", err)
		}
	})

	t.Run("退避只会延长不会缩短", func(t *testing.T) {
		resetCooldowns()
		const u = "https://music.163.com/api/search/get/web"
		neteaseReportBlocked(u, 200*time.Millisecond)
		neteaseReportBlocked(u, 20*time.Millisecond) // 更短的一次不该覆盖更长的
		until := neteaseCooldownUntil[neteaseEndpointBucket(u)]
		if time.Until(until) < 150*time.Millisecond {
			t.Errorf("更短的退避不该覆盖已有的更长退避,剩余 %v", time.Until(until))
		}
	})
}

func TestNeteaseEndpointBucket(t *testing.T) {
	cases := []struct {
		name string
		a, b string
		same bool
	}{
		{"同路径不同query同桶", "https://music.163.com/api/search/get/web?type=1", "https://music.163.com/api/search/get/web?type=10", true},
		{"不同路径不同桶", "https://music.163.com/api/search/get/web", "https://music.163.com/api/search/get", false},
		{"不同端点族不同桶", "https://music.163.com/api/song/lyric?id=1", "https://music.163.com/api/song/lyric/v1?id=1", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := neteaseEndpointBucket(c.a) == neteaseEndpointBucket(c.b)
			if got != c.same {
				t.Errorf("neteaseEndpointBucket(%q)==neteaseEndpointBucket(%q) = %v, want %v", c.a, c.b, got, c.same)
			}
		})
	}
}

// 2026-09-03 新增:指数退避 + 成功清零 + "成功过就不报限流"那道判据。
//
// 起因是 25 小时真实日志里的分布(见 neteaseBlockCooldownBase 头注):171 次拒绝有 89 次
// 跟上一次间隔 ≤35 秒,最长连撞 21 次 —— 固定 30 秒的退避等于自己把服务端的惩罚窗口一直
// 续着。这组断言钉住"越撞越久、成功就复原"这两件事。
func TestNeteaseBlockBackoff(t *testing.T) {
	savedCooldown := neteaseCooldownUntil
	savedStreak := neteaseBlockStreak
	savedSuccess := neteaseAnySuccess
	t.Cleanup(func() {
		neteaseCooldownUntil = savedCooldown
		neteaseBlockStreak = savedStreak
		neteaseAnySuccess = savedSuccess
	})
	reset := func() {
		neteaseCooldownUntil = map[string]time.Time{}
		neteaseBlockStreak = map[string]int{}
		neteaseAnySuccess = false
	}

	t.Run("连撞几次就退避几档,到上限封顶", func(t *testing.T) {
		cases := []struct {
			streak int
			want   time.Duration
		}{
			{1, neteaseBlockCooldownBase},
			{2, 2 * neteaseBlockCooldownBase},
			{3, 4 * neteaseBlockCooldownBase},
			{4, neteaseBlockCooldownMax}, // 8×2min = 16min 已超上限
			{9, neteaseBlockCooldownMax},
		}
		for _, c := range cases {
			if got := neteaseCooldownForStreak(c.streak); got != c.want {
				t.Errorf("neteaseCooldownForStreak(%d) = %v, want %v", c.streak, got, c.want)
			}
		}
	})

	// ⚠️ 这一条守的是一个会让退避**整个失效**的坑:time.Duration 是 int64,base 左移几十位
	// 会溢出成**负数**,而负的退避在 neteaseReportBlocked 那边等于"已经过期"——连撞越多反而
	// 越不退避,正好反了。所以移位前必须先把 streak 卡住。
	t.Run("streak 大到会移位溢出时仍然是正数且不超上限", func(t *testing.T) {
		for _, streak := range []int{32, 63, 64, 1 << 20} {
			got := neteaseCooldownForStreak(streak)
			if got <= 0 {
				t.Fatalf("neteaseCooldownForStreak(%d) = %v,负/零退避等于没有退避", streak, got)
			}
			if got != neteaseBlockCooldownMax {
				t.Errorf("neteaseCooldownForStreak(%d) = %v, want 封顶 %v", streak, got, neteaseBlockCooldownMax)
			}
		}
		// streak < 1(理论不该发生)按第一次处理,别算出负数
		if got := neteaseCooldownForStreak(0); got != neteaseBlockCooldownBase {
			t.Errorf("neteaseCooldownForStreak(0) = %v, want %v", got, neteaseBlockCooldownBase)
		}
	})

	t.Run("同一个桶连续被拒:退避一次比一次长,连撞计数递增", func(t *testing.T) {
		reset()
		const u = "https://music.163.com/api/search/get/web?type=1&s=a"
		d1, s1 := neteaseReportRejected(u)
		d2, s2 := neteaseReportRejected(u)
		if s1 != 1 || s2 != 2 {
			t.Fatalf("连撞计数 = %d,%d, want 1,2", s1, s2)
		}
		if !(d2 > d1) {
			t.Errorf("第二次退避 %v 不比第一次 %v 长", d2, d1)
		}
		if d1 != neteaseBlockCooldownBase {
			t.Errorf("首次退避 = %v, want %v", d1, neteaseBlockCooldownBase)
		}
	})

	t.Run("不同桶各自记连撞,不互相污染", func(t *testing.T) {
		reset()
		_, _ = neteaseReportRejected("https://music.163.com/api/search/get/web?type=1&s=a")
		_, _ = neteaseReportRejected("https://music.163.com/api/search/get/web?type=10&s=b") // 同桶
		_, streak := neteaseReportRejected("https://music.163.com/api/search/get?type=1&s=a")  // 另一个桶
		if streak != 1 {
			t.Errorf("另一个桶的首次拒绝 streak = %d, want 1", streak)
		}
	})

	t.Run("成功一次就清零:连撞计数复原、冷却标记清掉、下次被拒重新从 base 起算", func(t *testing.T) {
		reset()
		const u = "https://music.163.com/api/search/get/web?type=1&s=a"
		neteaseReportRejected(u)
		neteaseReportRejected(u)
		neteaseReportRejected(u)
		if err := neteaseThrottle(context.Background(), u); !errors.Is(err, errNeteaseBucketCooling) {
			t.Fatalf("连撞三次之后应该还在退避期,got %v", err)
		}
		neteaseReportSuccess(u)
		if err := neteaseThrottle(context.Background(), u); err != nil {
			t.Fatalf("成功之后冷却标记该被清掉,got %v", err)
		}
		if d, streak := neteaseReportRejected(u); streak != 1 || d != neteaseBlockCooldownBase {
			t.Errorf("清零后再次被拒 = (%v, %d), want (%v, 1)", d, streak, neteaseBlockCooldownBase)
		}
	})

	// 这一条守的是"限流别张冠李戴":吃过 405 ≠ 这个源没给出候选。实测对照见
	// netease.go 的 neteaseSawSuccessNow 头注(同一分钟两次搜索,都吃了 405,其中一次
	// 照样给出 4 条候选)。
	t.Run("成功过一次之后 SawSuccess 为真", func(t *testing.T) {
		reset()
		if neteaseSawSuccessNow() {
			t.Fatal("刚重置就报成功过")
		}
		neteaseReportRejected("https://music.163.com/api/search/get/web?type=1&s=a")
		if neteaseSawSuccessNow() {
			t.Error("只被拒过、没成功过,不该报成功")
		}
		neteaseReportSuccess("https://music.163.com/api/search/get?type=1&s=a")
		if !neteaseSawSuccessNow() {
			t.Error("成功过一次之后应该为真")
		}
	})
}

// 2026-09-03:主备端点对调之后,钉住"首选是那个从没被拒过的桶"。
// 依据(同一份 25 小时日志):/api/search/get/web 打了 10029 次被拒 171 次,
// /api/search/get 打了 8537 次**零拒绝** —— 量级相当而结果差一个数量级。
// ⚠️ 这条断言存在的意义是防"顺手改回去":两个常量必须是不同的桶(否则兜底形同虚设),
// 而且首选必须是 /api/search/get。
func TestNeteaseSearchEndpointOrder(t *testing.T) {
	if neteaseSearchEndpointPrimary != "https://music.163.com/api/search/get" {
		t.Errorf("首选端点 = %q,应当是 /api/search/get(实测零拒绝的那个桶)", neteaseSearchEndpointPrimary)
	}
	if neteaseSearchEndpointFallback != "https://music.163.com/api/search/get/web" {
		t.Errorf("兜底端点 = %q,应当保留 /api/search/get/web", neteaseSearchEndpointFallback)
	}
	if neteaseEndpointBucket(neteaseSearchEndpointPrimary) == neteaseEndpointBucket(neteaseSearchEndpointFallback) {
		t.Error("主备两个端点必须落在不同的限流桶,否则兜底那一跳形同虚设")
	}
}
