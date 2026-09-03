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
			// 2026-08-26 收严:albumScore 的 100 分档("宽松包含"——本地专辑名的基础部分
			// 是候选专辑名的超集,比如带了"(Gold) [Explicit]"这类版本后缀)不等于真的对上
			// 版,得补查。方大同「很不低调」实测坐实:网易云那张《JTW西游记》是本地
			// 《JTW 西游记 (Gold) [Explicit]》的子串、算 100 分,但两版封面完全不同。
			name:  "只是宽松包含(100 分,版本后缀被当成子串忽略):也要补查,不是真的对上版",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u", CoverAlbum: "JTW西游记"},
			album: "JTW 西游记 (Gold) [Explicit]", want: true,
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
		// upgradable 只对 old.CoverSource == "device" 那几档有意义:下面用它给
		// deviceCoverUpgradable 打桩(真判据要取图比指纹,单测不发网络请求)。
		upgradable bool
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
		{
			// 2026-08-26:方大同「很不低调」/「烦」——网易云、Apple 都只收录了旧版
			// 《JTW西游记》,新版《JTW 西游记 (Gold) [Explicit]》只有 QQ 音乐有。QQ 那档
			// 从不回传 CoverAlbum,不能套"网易云应答过 + albumScore > 0"那条正面证据,
			// 得单独放行,否则永远换不进去。
			name:  "跨源到 QQ:即使没有 NeteaseURL/CoverAlbum 也换(qqCoverFallback 自己已经把关)",
			old:   enrichEntry{CoverURL: "old", CoverSource: "netease", CoverAlbum: "JTW西游记"},
			fresh: enrichEntry{CoverURL: "new", CoverSource: "qq"},
			album: "JTW 西游记 (Gold) [Explicit]", want: true,
		},
		{
			// 2026-08-31 真实bug(Michael Jackson《Workin' Day and Night (Immortal
			// Version)》):device 一旦定案就不该再被 backfillPeripheralFields 的外围自愈
			// 换掉——即使 fresh 命中的是上面那条"QQ 无条件放行"。这类不需要中文别名的
			// 外国歌手,canonical_artist 永远解不出来,needsPeripheralBackfill 因此每隔
			// enrichPeripheralRetryInterval 就重新判"缺",反复触发这条外围自愈,每次都会把
			// 刚定案的正确设备封面换成网易云/Apple/QQ 这次又猜错的某个结果——原封面来源
			// 一直换,表现为封面在几次重试之间来回变。
			// ⚠️ 2026-09-02 起这两条的语义变了:device 分支改成"问一次能不能升级"
			// (见 coverquality.go)。它们现在验的是**判据说不能升级时,一律不换** ——
			// 上面那段《Immortal》的保护正是靠这一档(那张 QQ 高清图不是同一张图,
			// 判据会拒绝升级)。下面用桩把判据固定成"不能升级",不发真实网络请求。
			name:  "旧封面来自device且不可升级:哪怕新结果来自QQ也不换",
			old:   enrichEntry{CoverURL: "device.jpg", CoverSource: "device", CoverAlbum: "Immortal"},
			fresh: enrichEntry{CoverURL: "wrong.jpg", CoverSource: "qq"},
			album: "Immortal", want: false,
		},
		{
			name:  "旧封面来自device且不可升级:哪怕新结果对得上专辑也不换",
			old:   enrichEntry{CoverURL: "device.jpg", CoverSource: "device", CoverAlbum: "Immortal"},
			fresh: enrichEntry{CoverURL: "new.jpg", CoverSource: "apple", CoverAlbum: "Immortal", NeteaseURL: "n"},
			album: "Immortal", want: false,
		},
		{
			// 2026-09-02 新增:判据说"可以升级"(低分辨率设备封面 + 同一张图的高清远程版,
			// 《24K Magic》那一档)时必须放行 —— 否则那 21 条存量低分辨率封面永远糊着。
			name:  "旧封面来自device但可升级:换",
			old:   enrichEntry{CoverURL: "device.jpg", CoverSource: "device", CoverAlbum: "24K Magic"},
			fresh: enrichEntry{CoverURL: "big.jpg", CoverSource: "netease", CoverAlbum: "24K Magic", NeteaseURL: "n"},
			album: "24K Magic", upgradable: true, want: true,
		},
	}
	for _, c := range cases {
		// 把"能不能升级"的判据换成桩:真判据要取图比指纹,单测不该发网络请求
		// (它自己的用例在 coverquality_test.go 里)。
		saved := deviceCoverUpgradable
		upgradable := c.upgradable
		deviceCoverUpgradable = func(string, string) bool { return upgradable }
		got := coverSwapAllowed(c.old, c.fresh, c.album)
		deviceCoverUpgradable = saved
		if got != c.want {
			t.Errorf("%s: coverSwapAllowed = %v, want %v", c.name, got, c.want)
		}
	}
}

// 2026-08-27:方大同「Once」——QQ 搜索对这首歌唯一收录的记录专辑名文本上对得上,挂的
// 封面却是另一款合集版,跟同专辑其它曲目实际的单张封面是两张图。siblingAlbumCover 是
// 兜底的最后一道:同专辑邻居里已经有 qq 定案的封面就借来用。
func TestSiblingAlbumCover(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	const album = "JTW 西游记 (Gold) [Explicit]"
	enrichCache = map[string]enrichEntry{
		"方大同|很不低调|" + album: {CoverURL: "https://qq/right.jpg", CoverSource: "qq"},
		// 网易云那档即使 CoverAlbum 打了分也不该被借用——它自己都信不过。
		"方大同|放不过自己|" + album: {CoverURL: "https://netease/loose.jpg", CoverSource: "netease", CoverAlbum: "JTW 西游记 (Gold)"},
		// 别的歌手同名专辑不该被借用。
		"某歌手|同名曲|" + album: {CoverURL: "https://qq/wrong-artist.jpg", CoverSource: "qq"},
		// 不同专辑不该被借用。
		"方大同|烦|JTW西游记": {CoverURL: "https://qq/wrong-album.jpg", CoverSource: "qq"},
	}

	url, source := siblingAlbumCover("方大同", "Once", album)
	if url != "https://qq/right.jpg" || source != "qq" {
		t.Errorf("siblingAlbumCover = (%q, %q), want (https://qq/right.jpg, qq)", url, source)
	}

	// 专辑里一个 qq 定案的邻居都没有:原样返回空,不该瞎凑。
	enrichCache = map[string]enrichEntry{
		"方大同|放不过自己|" + album: {CoverURL: "https://netease/loose.jpg", CoverSource: "netease", CoverAlbum: "JTW 西游记 (Gold)"},
	}
	if url, _ := siblingAlbumCover("方大同", "Once", album); url != "" {
		t.Errorf("没有 qq 定案的邻居时不该借到东西,got %q", url)
	}
}
