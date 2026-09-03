package main

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

// 2026-09-02 歌词源级熔断(sourcebreaker.go)。假时钟驱动,不碰真实时间。

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newTestBreaker() (*lyricSourceBreaker, *fakeClock) {
	clk := &fakeClock{t: time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)}
	return newLyricSourceBreaker(clk.now), clk
}

var errProbeDial = &net.OpError{Op: "dial", Err: errors.New("no such host")}

func TestLyricSourceForHost(t *testing.T) {
	cases := map[string]string{
		"music.163.com":                 "netease",
		"c.y.qq.com":                    "qq",
		"u.y.qq.com:443":                "qq",
		"KRCS.KUGOU.COM":                "kugou",
		"lyrics.kugou.com":              "kugou",
		"lrclib.net":                    "lrclib",
		"apic-appmobile.musixmatch.com": "musixmatch",
		"raw.githubusercontent.com":     "amll",
		"music.youtube.com":             "lyricfind",
		"search.kuwo.cn":                "kuwo",
		"ws.audioscrobbler.com":         "",
		"api.listenbrainz.org":          "",
		"musicbrainz.org":               "",
		"itunes.apple.com":              "",
		"1.1.1.1":                       "",
		"notqq.com":                     "",
		"evil-163.com":                  "",
	}
	for host, want := range cases {
		if got := lyricSourceForHost(host); got != want {
			t.Errorf("lyricSourceForHost(%q) = %q, want %q", host, got, want)
		}
	}
}

// 连续两次网络失败才开;之后每次再失败按 15/30/60/120/300 秒升档;一次成功整体清零。
func TestLyricSourceBreakerTripsAfterTwoFailuresAndEscalates(t *testing.T) {
	b, clk := newTestBreaker()
	b.observe("music.163.com", errProbeDial, 0, "")
	if _, cooling := b.coolingDown("netease"); cooling {
		t.Fatal("一次失败就熔断了——一次网络抖动不该让下一首歌少一个源")
	}
	b.observe("music.163.com", errProbeDial, 0, "")
	if d, cooling := b.coolingDown("netease"); !cooling || d != 15*time.Second {
		t.Fatalf("两次失败后应冷却 15s,实际 cooling=%v d=%s", cooling, d)
	}
	clk.advance(15 * time.Second)
	if _, cooling := b.coolingDown("netease"); cooling {
		t.Fatal("15s 到期后应放行")
	}
	// 第三次失败(退避期刚过、再试仍失败)升到 30s;5xx 与网络错误同一条阶梯
	b.observe("music.163.com", nil, 502, "")
	if d, _ := b.coolingDown("netease"); d != 30*time.Second {
		t.Fatalf("第三次失败应升到 30s,实际 %s", d)
	}
	for i := 0; i < 10; i++ {
		b.observe("music.163.com", errProbeDial, 0, "")
	}
	if d, _ := b.coolingDown("netease"); d != 5*time.Minute {
		t.Fatalf("阶梯应封顶 5 分钟,实际 %s", d)
	}
	// 同源另一个主机的一次成功即清
	b.observe("music.163.com", nil, 200, "")
	if _, cooling := b.coolingDown("netease"); cooling {
		t.Fatal("成功后应立即清除冷却")
	}
	// 清零后又要重新数两次
	b.observe("music.163.com", errProbeDial, 0, "")
	if _, cooling := b.coolingDown("netease"); cooling {
		t.Fatal("成功清零后单次失败不应熔断")
	}
}

// 用户取消不算失败;4xx(非 429)一律不算,还会把之前的失败计数清掉;别的源的主机不影响本源。
func TestLyricSourceBreakerIgnoresCanceledAnd4xx(t *testing.T) {
	b, _ := newTestBreaker()
	for i := 0; i < 5; i++ {
		b.observe("c.y.qq.com", context.Canceled, 0, "")
	}
	if _, cooling := b.coolingDown("qq"); cooling {
		t.Fatal("context.Canceled 不该计入失败")
	}
	b.observe("c.y.qq.com", errProbeDial, 0, "")
	b.observe("c.y.qq.com", nil, 403, "") // 反爬 403:拿到了响应,网络是通的
	b.observe("c.y.qq.com", errProbeDial, 0, "")
	if _, cooling := b.coolingDown("qq"); cooling {
		t.Fatal("403 之后计数应已清零,再一次失败不该熔断——403 不做粘性冷却")
	}
	b.observe("krcs.kugou.com", errProbeDial, 0, "")
	b.observe("krcs.kugou.com", errProbeDial, 0, "")
	if _, cooling := b.coolingDown("qq"); cooling {
		t.Fatal("酷狗的失败不该连累 QQ")
	}
	if _, cooling := b.coolingDown("kugou"); !cooling {
		t.Fatal("酷狗自己两次失败应熔断")
	}
	b.observe("ws.audioscrobbler.com", errProbeDial, 0, "")
	b.observe("ws.audioscrobbler.com", errProbeDial, 0, "")
	for _, s := range lyricSourceNames {
		if s == "kugou" {
			continue
		}
		if _, cooling := b.coolingDown(s); cooling {
			t.Fatalf("Last.fm 的失败不该影响任何歌词源,%s 却在冷却", s)
		}
	}
}

// 429 按 Retry-After 秒数冷却:没给用 60s,给了封顶 5 分钟,HTTP-date 写法回默认。
func TestLyricSourceBreakerRetryAfter(t *testing.T) {
	cases := map[string]time.Duration{
		"":                              time.Minute,
		"120":                           2 * time.Minute,
		" 30 ":                          30 * time.Second,
		"99999":                         5 * time.Minute,
		"0":                             time.Minute,
		"Wed, 21 Oct 2026 07:28:00 GMT": time.Minute,
	}
	for header, want := range cases {
		b, _ := newTestBreaker()
		b.observe("lrclib.net", nil, 429, header)
		if d, cooling := b.coolingDown("lrclib"); !cooling || d != want {
			t.Errorf("Retry-After %q: cooling=%v d=%s, want %s", header, cooling, d, want)
		}
	}
}

// 启用的源全在冷却中时谁也不跳过;只有部分在冷却时跳过那些;未启用的源在不在冷却里无所谓。
func TestLyricSourceBreakerPlanRoundNeverSkipsAllEnabled(t *testing.T) {
	b, _ := newTestBreaker()
	trip := func(host string) {
		b.observe(host, errProbeDial, 0, "")
		b.observe(host, errProbeDial, 0, "")
	}
	trip("music.163.com")
	trip("c.y.qq.com")
	onlyTwo := func(s string) bool { return s == "netease" || s == "qq" }
	if plan := b.planRound(lyricSourceNames, onlyTwo); plan != nil {
		t.Fatalf("启用的两个源都在冷却时应谁也不跳过,实际 %v", plan)
	}
	allOn := func(string) bool { return true }
	plan := b.planRound(lyricSourceNames, allOn)
	if len(plan) != 2 || plan["netease"] == 0 || plan["qq"] == 0 {
		t.Fatalf("八源全开时应只跳过冷却中的两个,实际 %v", plan)
	}
	if _, ok := plan["kugou"]; ok {
		t.Fatal("没冷却的源不该在跳过名单里")
	}
	// 只启用 kugou:netease/qq 冷却中但未启用,照样进名单(少发几个白费的请求),kugou 不进
	onlyKugou := func(s string) bool { return s == "kugou" }
	plan = b.planRound(lyricSourceNames, onlyKugou)
	if len(plan) != 2 {
		t.Fatalf("未启用的冷却源也应跳过,实际 %v", plan)
	}
	// 什么都没冷却 → nil
	b2, _ := newTestBreaker()
	if plan := b2.planRound(lyricSourceNames, allOn); plan != nil {
		t.Fatalf("无冷却时应返回 nil,实际 %v", plan)
	}
}

// 跳过名单经 ctx 传给写缓存的那几层;CLI 路径没挂 round 时全部是安全的空操作。
func TestLyricSourceRoundViaContext(t *testing.T) {
	ctx, round := withLyricSourceRound(context.Background())
	got := lyricSourceRoundFrom(ctx)
	if got != round {
		t.Fatal("ctx 里取不回同一个 round")
	}
	got.markSkipped("qq")
	got.markSkipped("netease")
	got.markSkipped("qq")
	if s := round.skippedSources(); len(s) != 2 || s[0] != "netease" || s[1] != "qq" {
		t.Fatalf("skippedSources 应去重且排序,实际 %v", s)
	}
	var nilRound *lyricSourceRound
	nilRound.markSkipped("kugou")
	if nilRound.skippedSources() != nil {
		t.Fatal("nil round 应返回 nil")
	}
	if lyricSourceRoundFrom(context.Background()) != nil {
		t.Fatal("没挂 round 的 ctx 应返回 nil")
	}
	if withoutSkips, _ := withLyricSourceRound(context.Background()); lyricSourceRoundFrom(withoutSkips).skippedSources() != nil {
		t.Fatal("没跳过任何源时应返回 nil,而不是空切片(写进 JSON 会变成 [])")
	}
}

// 这一轮有源被跳过而落成"没歌词"的条目,10 分钟后就该补搜;没跳过的照旧 24 小时;
// 补过一次之后回到正常退避。
func TestNeedsLyricsFirstFillShortIntervalWhenSourcesSkipped(t *testing.T) {
	now := time.Now().Unix()
	skipped := enrichEntry{TS: now - 11*60, LyricsSourcesSkipped: []string{"netease"}}
	if !needsLyricsFirstFill(skipped) {
		t.Fatal("有源被跳过、11 分钟后应重试")
	}
	tooSoon := enrichEntry{TS: now - 5*60, LyricsSourcesSkipped: []string{"netease"}}
	if needsLyricsFirstFill(tooSoon) {
		t.Fatal("5 分钟还不到 10 分钟的间隔")
	}
	plain := enrichEntry{TS: now - 11*60}
	if needsLyricsFirstFill(plain) {
		t.Fatal("没有源被跳过时仍是 24 小时起步")
	}
	retried := enrichEntry{TS: now - 11*60, LyricsFillTS: now - 11*60, LyricsFillCount: 1, LyricsSourcesSkipped: []string{"netease"}}
	if needsLyricsFirstFill(retried) {
		t.Fatal("补过一次之后应回到正常退避")
	}
}
