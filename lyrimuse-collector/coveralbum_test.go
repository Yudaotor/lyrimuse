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

	url, source, verified := siblingAlbumCover("方大同", "Once", album)
	if url != "https://qq/right.jpg" || source != "qq" {
		t.Errorf("siblingAlbumCover = (%q, %q), want (https://qq/right.jpg, qq)", url, source)
	}
	// 2026-09-07:借到的 qq 图**不认领专辑归属** —— QQ 从不回传专辑名,这一档的
	// cover_album 本来就是空的,借用不该把它升级成"已核实"。见 siblingAlbumCover 头注。
	if verified {
		t.Error("借来的 qq 封面不该报 albumVerified —— 那会让调用方盖上 cover_album,凭空造出一条归属证据")
	}

	// 专辑里一个 qq 定案的邻居都没有:原样返回空,不该瞎凑。
	enrichCache = map[string]enrichEntry{
		"方大同|放不过自己|" + album: {CoverURL: "https://netease/loose.jpg", CoverSource: "netease", CoverAlbum: "JTW 西游记 (Gold)"},
	}
	if url, _, _ := siblingAlbumCover("方大同", "Once", album); url != "" {
		t.Errorf("没有 qq 定案的邻居时不该借到东西,got %q", url)
	}
}

// 2026-09-07 用户报《Michael》/「Hold My Hand (with Akon)」封面不对:显示的是 QQ 的
// 《The Ultimate Collection》,而同一张专辑另外三首在本机播过、拿到的是设备直送的正确
// 封面。第一档就是为这种形态加的 —— 归属由播放时刻本身保证的那张图,可以连归属一起借走。
func TestSiblingAlbumCoverPrefersDeviceSibling(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	const album = "Michael"
	deviceCover := "file:///Users/x/.config/lyrimuse/artwork/abc.jpg"
	enrichCache = map[string]enrichEntry{
		// 本机播过、cover_album 已经逐字对上这张专辑 → 归属可外借。
		"Michael Jackson|Hollywood Tonight|" + album: {CoverURL: deviceCover, CoverSource: "device", CoverAlbum: album},
		// QQ 那张精选集图也在,但排在第二档。
		"Michael Jackson|Much Too Soon|" + album: {CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"},
	}
	url, source, verified := siblingAlbumCover("Michael Jackson", "Hold My Hand", album)
	if url != deviceCover || source != "device" || !verified {
		t.Errorf("siblingAlbumCover = (%q, %q, %v), want (%q, device, true) —— device 邻居该赢过 qq 邻居",
			url, source, verified, deviceCover)
	}

	// device 邻居自己的 cover_album 对不上(或为空)时**不够格**:这个函数不替它推断归属,
	// 退回第二档的 qq 图。
	enrichCache = map[string]enrichEntry{
		"Michael Jackson|Hollywood Tonight|" + album: {CoverURL: deviceCover, CoverSource: "device"},
		"Michael Jackson|Much Too Soon|" + album:     {CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"},
	}
	url, source, verified = siblingAlbumCover("Michael Jackson", "Hold My Hand", album)
	if url != "https://qq/ultimate.jpg" || source != "qq" || verified {
		t.Errorf("siblingAlbumCover = (%q, %q, %v), want (https://qq/ultimate.jpg, qq, false)", url, source, verified)
	}

	// netease/apple 的戳是**源自己报的专辑名**(同名不同版照样逐字对上),这两档仍然不借 ——
	// 跟原有那条"不借网易云/Apple"是同一条理由。
	enrichCache = map[string]enrichEntry{
		"Michael Jackson|Hollywood Tonight|" + album: {CoverURL: "https://netease/exact.jpg", CoverSource: "netease", CoverAlbum: album},
		"Michael Jackson|Best of Joy|" + album:       {CoverURL: "https://apple/exact.jpg", CoverSource: "apple", CoverAlbum: album},
	}
	if url, _, _ := siblingAlbumCover("Michael Jackson", "Hold My Hand", album); url != "" {
		t.Errorf("netease/apple 的已核实邻居不该被借用,got %q", url)
	}
}

// 同专辑有多条可借邻居时,借到哪一张必须是**确定的**:Go 的 map 迭代顺序随机,不定序的话
// 每次启动可能借到不同的图,表现是"封面偶尔自己变了"且复现不出来。
func TestSiblingAlbumCoverIsDeterministic(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	const album = "同一张专辑"
	enrichCache = map[string]enrichEntry{
		"某歌手|甲|" + album: {CoverURL: "https://qq/a.jpg", CoverSource: "qq"},
		"某歌手|乙|" + album: {CoverURL: "https://qq/b.jpg", CoverSource: "qq"},
		"某歌手|丙|" + album: {CoverURL: "https://qq/c.jpg", CoverSource: "qq"},
	}
	first, _, _ := siblingAlbumCover("某歌手", "丁", album)
	if first == "" {
		t.Fatal("该借到一张 qq 邻居的图")
	}
	for i := 0; i < 30; i++ {
		if got, _, _ := siblingAlbumCover("某歌手", "丁", album); got != first {
			t.Fatalf("第 %d 次借到的是 %q,跟第一次的 %q 不一样 —— 借用结果必须跟 map 迭代顺序无关", i+1, got, first)
		}
	}
}

// 自愈触发判据(2026-09-07)。刻意收得很窄:只有"同专辑真有一张归属可外借的邻居"才算缺,
// 否则 QQ 正常给对图的那一大类(cover_album 恒空、补不上)会每条白重试满 5 次。
func TestCoverCanUpgradeToVerifiedSibling(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	const album = "Michael"
	deviceSibling := map[string]enrichEntry{
		"Michael Jackson|Hollywood Tonight|" + album: {
			CoverURL: "file:///Users/x/.config/lyrimuse/artwork/abc.jpg", CoverSource: "device", CoverAlbum: album,
		},
	}
	qqStamped := enrichEntry{CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"}

	enrichCache = deviceSibling
	if !coverCanUpgradeToVerifiedSiblingLocked(qqStamped, "Michael Jackson", album) {
		t.Error("qq 档 + 同专辑有 device 已核实邻居 → 该补一次重解析")
	}
	// 自己就是已核实的那一档:没什么可升的。
	if coverCanUpgradeToVerifiedSiblingLocked(
		enrichEntry{CoverURL: "u", CoverSource: "apple", CoverAlbum: album}, "Michael Jackson", album) {
		t.Error("cover_album 已经逐字对上的条目不该被判成缺")
	}
	// device 档身份最硬,不参与升级。
	if coverCanUpgradeToVerifiedSiblingLocked(
		enrichEntry{CoverURL: "u", CoverSource: "device"}, "Michael Jackson", album) {
		t.Error("device 档不该被判成缺")
	}
	if coverCanUpgradeToVerifiedSiblingLocked(qqStamped, "Michael Jackson", "") {
		t.Error("本地没有专辑标签时判不出来,不该补查")
	}
	// 没有可借邻居:不制造白重试。
	enrichCache = map[string]enrichEntry{
		"Michael Jackson|Much Too Soon|" + album: {CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"},
	}
	if coverCanUpgradeToVerifiedSiblingLocked(qqStamped, "Michael Jackson", album) {
		t.Error("同专辑没有归属可外借的邻居时不该补查 —— 重解析拿不到更好的答案,只会白重试满 5 次")
	}
}

// 借来的 device 封面要过得了外围自愈那道换封面闸(2026-09-07)。这条路径上 fresh 只可能靠
// 借拿到 device 来源,而它的归属是实测证据,不该再被"网易云这一轮应答过没有"那条代理证据拦住。
func TestCoverSwapAllowedAcceptsBorrowedDeviceCover(t *testing.T) {
	const album = "Michael"
	old := enrichEntry{CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"}
	fresh := enrichEntry{
		CoverURL: "file:///Users/x/.config/lyrimuse/artwork/abc.jpg", CoverSource: "device", CoverAlbum: album,
	}
	if !coverSwapAllowed(old, fresh, album) {
		t.Error("借来的 device 封面该被接受 —— 它不带 NeteaseURL,旧判据会把它永远拦在缓存外")
	}
	// old 本身是 device 时仍然只走"是不是同一张图的高清版"那条判据,新档不许绕过它
	// (2026-08-31《Immortal》那次真实 bug 就是被这条守住的)。
	saved := deviceCoverUpgradable
	defer func() { deviceCoverUpgradable = saved }()
	deviceCoverUpgradable = func(string, string) bool { return false }
	oldDevice := enrichEntry{CoverURL: "file:///Users/x/.config/lyrimuse/artwork/old.jpg", CoverSource: "device", CoverAlbum: album}
	if coverSwapAllowed(oldDevice, fresh, album) {
		t.Error("old 是 device 时必须先过 deviceCoverUpgradable,不该被新加的 fresh-device 档绕过")
	}
}

// 存量清洗:擦掉借用时盖上的假归属戳(2026-09-07,本机实测 386 条)。
func TestMigrateBorrowedCoverAlbums(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	enrichCache = map[string]enrichEntry{
		// 被盖过章的:擦掉。
		"Michael Jackson|Hold My Hand|Michael": {CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq", CoverAlbum: "Michael"},
		// qq 档本来就没戳:不动(也证明这个迁移是幂等的)。
		"某歌手|甲|某专辑": {CoverURL: "https://qq/a.jpg", CoverSource: "qq"},
		// 另外三档的戳都是真的,一个字节都不许动。
		"某歌手|乙|某专辑": {CoverURL: "file:///x/artwork/b.jpg", CoverSource: "device", CoverAlbum: "某专辑"},
		"某歌手|丙|某专辑": {CoverURL: "https://netease/c.jpg", CoverSource: "netease", CoverAlbum: "某专辑"},
		"某歌手|丁|某专辑": {CoverURL: "https://apple/d.jpg", CoverSource: "apple", CoverAlbum: "某专辑"},
	}
	migrateBorrowedCoverAlbums()
	if got := enrichCache["Michael Jackson|Hold My Hand|Michael"].CoverAlbum; got != "" {
		t.Errorf("被盖过章的 qq 条目该被擦掉 cover_album, got %q", got)
	}
	// 封面本身不动:换封面交给自愈路径(理由见 coverstampmigrate.go 头注)。
	if got := enrichCache["Michael Jackson|Hold My Hand|Michael"].CoverURL; got != "https://qq/ultimate.jpg" {
		t.Errorf("迁移不该动 cover_url, got %q", got)
	}
	for _, k := range []string{"某歌手|乙|某专辑", "某歌手|丙|某专辑", "某歌手|丁|某专辑"} {
		if enrichCache[k].CoverAlbum != "某专辑" {
			t.Errorf("%s 的 cover_album 是真的,不该被擦", k)
		}
	}
	// 幂等:再跑一遍什么都不变。enrichEntry 带切片字段、不能直接比,挑这次迁移唯一
	// 会碰的三个字段比。
	before := enrichCache["某歌手|甲|某专辑"]
	migrateBorrowedCoverAlbums()
	after := enrichCache["某歌手|甲|某专辑"]
	if after.CoverURL != before.CoverURL || after.CoverSource != before.CoverSource ||
		after.CoverAlbum != before.CoverAlbum {
		t.Error("第二遍迁移不该改动任何条目")
	}
}
