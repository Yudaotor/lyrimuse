package main

import (
	"testing"
	"time"
)

// 封面选源的专辑感知(2026-08-20)。
//
// 起因是一次真实反馈:"最近记录"里蔡徐坤《KUN》连播 11 首,其中 Deadman / Jasmine /
// What a Day 三首的封面跟其它 8 首不是同一张。查下来是**网易云上没有 KUN 这张专辑、
// 只有这三首先行单曲**:pick() 那条"唯一精确同名候选、专辑名对不上也认"的规则命中了
// 单曲版,而网易云在封面选源里排在 Apple 前面(为了国内加载得出来),于是这三首拿到
// 单曲封面;其余 8 首网易云一条候选都没有、退到 Apple 拿到 KUN 专辑封面。
func TestPreferAppleCoverOverNetease(t *testing.T) {
	const cover = "https://is1-ssl.mzstatic.com/…/600x600bb.jpg"
	cases := []struct {
		name                        string
		neAlbum, appAlbum, appCover string
		local                       string
		want                        bool
	}{
		{
			name:    "网易云给的是单曲版、Apple 给的是这张专辑:换成 Apple(真实案例)",
			neAlbum: "Deadman", appAlbum: "KUN", appCover: cover, local: "KUN", want: true,
		},
		{
			name:    "网易云本来就对得上这张专辑:不动",
			neAlbum: "KUN", appAlbum: "KUN", appCover: cover, local: "KUN", want: false,
		},
		{
			name:    "Apple 那张也是单曲版:不换 —— 换了不解决问题,还丢掉国内可加载的图源",
			neAlbum: "Deadman", appAlbum: "Deadman - Single", appCover: cover, local: "KUN", want: false,
		},
		{
			name:    "Apple 压根没给封面:不换",
			neAlbum: "Deadman", appAlbum: "KUN", appCover: "", local: "KUN", want: false,
		},
		{
			name:    "本地没有专辑标签:不换 —— 对不对版无从判断,不能拿判不出来的条件掀掉已有封面",
			neAlbum: "Deadman", appAlbum: "KUN", appCover: cover, local: "", want: false,
		},
		{
			name:    "只是写法宽松不同(繁简/带副标题):算对得上,不换",
			neAlbum: "神经志", appAlbum: "神經志 The Journal", appCover: cover,
			local: "神經志 The Journal", want: false,
		},
	}
	for _, c := range cases {
		if got := preferAppleCoverOverNetease(c.neAlbum, c.appAlbum, c.appCover, c.local); got != c.want {
			t.Errorf("%s: preferAppleCoverOverNetease = %v, want %v", c.name, got, c.want)
		}
	}
}

// 存量条目怎么被重新解析一次:cover_album 是 2026-08-20 才加的字段,老条目一律为空,
// 只能靠补一次重解析来判定 + 写上。
func TestCoverNeedsAlbumCheck(t *testing.T) {
	cases := []struct {
		name  string
		e     enrichEntry
		album string
		want  bool
	}{
		{
			name:  "老条目(网易云封面、cover_album 不详):补查一次",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u"},
			album: "KUN", want: true,
		},
		{
			name:  "明确对不上这张专辑:补查",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u", CoverAlbum: "Deadman"},
			album: "KUN", want: true,
		},
		{
			name:  "对得上:不查",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u", CoverAlbum: "KUN"},
			album: "KUN", want: false,
		},
		{
			name:  "Apple 那档不查(本来就是按 albumScore 择优选的)",
			e:     enrichEntry{CoverSource: "apple", CoverURL: "u"},
			album: "KUN", want: false,
		},
		{
			name:  "QQ 那档不查(qqCoverFallback 内部已避开精选集)",
			e:     enrichEntry{CoverSource: "qq", CoverURL: "u"},
			album: "KUN", want: false,
		},
		{
			name:  "本地没有专辑标签:不查",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u"},
			album: "", want: false,
		},
	}
	for _, c := range cases {
		if got := coverNeedsAlbumCheck(c.e, c.album); got != c.want {
			t.Errorf("%s: coverNeedsAlbumCheck = %v, want %v", c.name, got, c.want)
		}
	}
}

// 触发条件这一层:一条**什么字段都不缺**的老记录,也要因为"封面属于哪张专辑不详"被补一次。
// 这是存量条目唯一的自愈入口 —— 少了它,已经存下来的错封面永远不会变。
func TestNeedsPeripheralBackfillCoversAlbumMismatch(t *testing.T) {
	long := time.Now().Unix() - int64(enrichPeripheralRetryInterval/time.Second) - 1
	full := enrichEntry{
		AccentColor: "#fff", AppleURL: "a", QQURL: "q", NeteaseURL: "n",
		CanonicalArtist: "蔡徐坤", TS: long,
		CoverURL:    "https://p1.music.126.net/…/1.jpg",
		CoverSource: "netease",
	}
	if !needsPeripheralBackfill(full, "蔡徐坤", "KUN") {
		t.Error("字段齐全但封面专辑不详的老条目该补查一次")
	}
	matched := full
	matched.CoverAlbum = "KUN"
	if needsPeripheralBackfill(matched, "蔡徐坤", "KUN") {
		t.Error("封面已经确认对得上这张专辑,不该再补")
	}
	offAlbum := full
	offAlbum.CoverAlbum = "Deadman"
	if !needsPeripheralBackfill(offAlbum, "蔡徐坤", "KUN") {
		t.Error("封面明确属于另一次发行,该补")
	}
	// 上限照旧生效:补查不能变成一条永动机。
	capped := offAlbum
	capped.PeripheralRetryCount = peripheralBackfillMaxAttempts
	if needsPeripheralBackfill(capped, "蔡徐坤", "KUN") {
		t.Error("重试次数用尽后不该再补")
	}
}

// 补全时的替换闸。第三档("跨源要有正面证据")是给网易云限流兜底的:限流时它照样回
// HTTP 200(body code 405),这一轮就没有网易云封面,少了这道闸会把一张本来对版、国内
// 加载得出来的网易云封面换成 mzstatic 的。
func TestCoverSwapAllowed(t *testing.T) {
	oldNetease := enrichEntry{
		CoverURL: "https://p1.music.126.net/…/1.jpg", CoverSource: "netease", CoverAlbum: "KUN",
	}
	cases := []struct {
		name       string
		old, fresh enrichEntry
		album      string
		want       bool
	}{
		{
			name:  "这一轮没拿到封面:不换(防抖动抹空)",
			old:   oldNetease,
			fresh: enrichEntry{},
			album: "KUN", want: false,
		},
		{
			name:  "本来就没有封面:补上",
			old:   enrichEntry{},
			fresh: enrichEntry{CoverURL: "x", CoverSource: "apple", CoverAlbum: "KUN"},
			album: "KUN", want: true,
		},
		{
			name:  "同源刷新:换(顺带把 cover_album 补上)",
			old:   enrichEntry{CoverURL: "old", CoverSource: "netease"},
			fresh: enrichEntry{CoverURL: "new", CoverSource: "netease", CoverAlbum: "KUN", NeteaseURL: "n"},
			album: "KUN", want: true,
		},
		{
			name:  "跨源 + 网易云应答过 + 新封面对得上专辑:换(这正是那三首的修法)",
			old:   enrichEntry{CoverURL: "old", CoverSource: "netease", CoverAlbum: "Deadman"},
			fresh: enrichEntry{CoverURL: "new", CoverSource: "apple", CoverAlbum: "KUN", NeteaseURL: "n"},
			album: "KUN", want: true,
		},
		{
			name:  "跨源但网易云这一轮没应答(疑似限流):不换",
			old:   oldNetease,
			fresh: enrichEntry{CoverURL: "new", CoverSource: "apple", CoverAlbum: "KUN"},
			album: "KUN", want: false,
		},
		{
			name:  "跨源、网易云应答了,但新封面也对不上专辑:不换",
			old:   enrichEntry{CoverURL: "old", CoverSource: "netease", CoverAlbum: "Deadman"},
			fresh: enrichEntry{CoverURL: "new", CoverSource: "apple", CoverAlbum: "Deadman - Single", NeteaseURL: "n"},
			album: "KUN", want: false,
		},
	}
	for _, c := range cases {
		if got := coverSwapAllowed(c.old, c.fresh, c.album); got != c.want {
			t.Errorf("%s: coverSwapAllowed = %v, want %v", c.name, got, c.want)
		}
	}
}
