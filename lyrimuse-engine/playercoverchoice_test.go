package main

import (
	"context"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPlayerCoverDisplayURL(t *testing.T) {
	const kkbox600 = "https://i.kfs.io/album/global/298971151,0v3/fit/600x600.jpg"
	cases := []struct{ in, want string }{
		{kkbox600, "https://i.kfs.io/album/global/298971151,0v3/fit/1000x1000.jpg"},
		{"https://i.kfs.io/album/global/298971151,0v3/original.jpg", "https://i.kfs.io/album/global/298971151,0v3/original.jpg"},
		{"https://y.qq.com/music/photo_new/T002R800x800M000002Cy8kL400ft2.jpg", "https://y.qq.com/music/photo_new/T002R800x800M000002Cy8kL400ft2.jpg"},
		{"https://example.com/fit/600x600.jpg", "https://example.com/fit/600x600.jpg"},
		{"", ""},
	}
	for _, c := range cases {
		if got := playerCoverDisplayURL(c.in); got != c.want {
			t.Errorf("playerCoverDisplayURL(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	if got := coverURLIntendedEdge(playerCoverDisplayURL(kkbox600)); got != 1000 {
		t.Errorf("1000 档的尺寸要读得出来: %d", got)
	}
	if got := kkboxCoverAtEdge(kkbox600, "64"); got != "https://i.kfs.io/album/global/298971151,0v3/fit/64x64.jpg" {
		t.Errorf("取指纹用的小图: %q", got)
	}
	if got := playerCoverFor(withPlayerCover(context.Background(), kkbox600)); got != playerCoverDisplayURL(kkbox600) {
		t.Errorf("ctx 上取回来的是当封面用的那一档: %q", got)
	}
	if got := playerCoverFor(withPlayerCover(context.Background(), "")); got != "" {
		t.Errorf("没有就是空: %q", got)
	}
}

func TestPlayerCoverOverDeviceWith(t *testing.T) {
	never := func(string, string) bool { return false }
	always := func(string, string) bool { return true }
	if got := playerCoverOverDeviceWith("", "dev", "", never); got != "" {
		t.Errorf("没有播放器封面: %q", got)
	}
	if got := playerCoverOverDeviceWith("p", "dev", "p", never); got != "" {
		t.Errorf("现有的就是它:不再拿它跟设备封面比第二次 %q", got)
	}
	if got := playerCoverOverDeviceWith("p", "dev", "", always); got != "" {
		t.Errorf("设备封面顶得掉它(不是同一张或设备封面够清晰):用设备封面 %q", got)
	}
	if got := playerCoverOverDeviceWith("p", "dev", "remote", never); got != "p" {
		t.Errorf("同一张图更清晰:用播放器的 %q", got)
	}
}

func TestCoverSwapAllowedPlayerCover(t *testing.T) {
	cases := []struct {
		name       string
		old, fresh enrichEntry
		upgradable bool
		want       bool
	}{
		{"播放器自带的不被 QQ 换掉", enrichEntry{CoverURL: "p", CoverSource: "player"}, enrichEntry{CoverURL: "q", CoverSource: "qq"}, false, false},
		{"播放器自带的不被对得上专辑的网易云换掉", enrichEntry{CoverURL: "p", CoverSource: "player", CoverAlbum: "A"},
			enrichEntry{CoverURL: "n", CoverSource: "netease", CoverAlbum: "A", NeteaseURL: "u"}, false, false},
		{"空着的补上播放器自带的", enrichEntry{}, enrichEntry{CoverURL: "p", CoverSource: "player", CoverAlbum: "A"}, false, true},
		{"按文字匹配出来的不被播放器自带的换掉", enrichEntry{CoverURL: "n", CoverSource: "netease", CoverAlbum: "A"},
			enrichEntry{CoverURL: "p", CoverSource: "player", CoverAlbum: "A", NeteaseURL: "u"}, false, false},
		{"小设备封面升级成同一张图的播放器封面", enrichEntry{CoverURL: "d", CoverSource: "device"}, enrichEntry{CoverURL: "p", CoverSource: "player"}, true, true},
		{"设备封面跟播放器封面不是同一张:不换", enrichEntry{CoverURL: "d", CoverSource: "device"}, enrichEntry{CoverURL: "p", CoverSource: "player"}, false, false},
	}
	for _, c := range cases {
		saved := deviceCoverUpgradable
		upgradable := c.upgradable
		deviceCoverUpgradable = func(string, string) bool { return upgradable }
		got := coverSwapAllowed(c.old, c.fresh, "A")
		deviceCoverUpgradable = saved
		if got != c.want {
			t.Errorf("%s: coverSwapAllowed = %v, want %v", c.name, got, c.want)
		}
	}
}

// writeCoverFile 把合成封面存成 JPEG,返回 file:// 地址(设备封面就是这个形状)。rel 里带「NxN」时 coverURLIntendedEdge 读得出尺寸。
func writeCoverFile(t *testing.T, dir, rel string, img image.Image) string {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(f, img, &jpeg.Options{Quality: 92}); err != nil {
		t.Fatal(err)
	}
	f.Close()
	return deviceArtworkURLPrefix + p
}

func TestApplyDeviceOrPlayerCover(t *testing.T) {
	dir := t.TempDir()
	device := writeCoverFile(t, dir, "device.jpg", synthCover(150, 1))
	bigDevice := writeCoverFile(t, dir, "bigdevice.jpg", synthCover(400, 1))
	same := writeCoverFile(t, dir, "kk/fit/1000x1000.jpg", synthCover(1000, 1))
	other := writeCoverFile(t, dir, "kk2/fit/1000x1000.jpg", synthCover(1000, 2))
	remoteOther := writeCoverFile(t, dir, "ne/800x800.jpg", synthCover(800, 2))
	if coverURLIntendedEdge(same) != 1000 || coverURLIntendedEdge(remoteOther) != 800 {
		t.Skipf("临时目录路径里带着别的 NxN 片段,读不出尺寸: %q", dir)
	}
	with := func(cover string) context.Context { return withPlayerCover(context.Background(), cover) }
	cases := []struct {
		name             string
		ctx              context.Context
		device           string
		start            enrichEntry
		wantURL, wantSrc string
	}{
		{"没有设备封面、那一串也空着:用播放器自带的", with(same), "", enrichEntry{}, same, "player"},
		{"没有设备封面、那一串给了:不动", with(same), "", enrichEntry{CoverURL: remoteOther, CoverSource: "netease"}, remoteOther, "netease"},
		{"什么都没有:空着", context.Background(), "", enrichEntry{}, "", ""},
		{"小设备封面、那一串是另一张、播放器自带的是同一张:用播放器的", with(same), device,
			enrichEntry{CoverURL: remoteOther, CoverSource: "netease"}, same, "player"},
		{"小设备封面、那一串空着、播放器自带的是同一张:用播放器的", with(same), device, enrichEntry{}, same, "player"},
		{"小设备封面、播放器自带的是另一张:身份优先,留设备封面", with(other), device, enrichEntry{}, device, "device"},
		{"小设备封面、没有播放器封面:设备封面", context.Background(), device, enrichEntry{}, device, "device"},
		{"设备封面够清晰:不换成播放器的", with(same), bigDevice, enrichEntry{}, bigDevice, "device"},
	}
	for _, c := range cases {
		e := c.start
		applyDeviceOrPlayerCover(c.ctx, &e, c.device, "专辑")
		if e.CoverURL != c.wantURL || e.CoverSource != c.wantSrc {
			t.Errorf("%s: 得到 %q / %q, want %q / %q", c.name, e.CoverURL, e.CoverSource, c.wantURL, c.wantSrc)
		}
		if c.wantSrc == "player" && e.CoverAlbum != "专辑" {
			t.Errorf("%s: cover_album 写本地专辑: %q", c.name, e.CoverAlbum)
		}
	}
}

func TestUpgradeDeviceCoverToPlayerCover(t *testing.T) {
	isolateEnrichCache(t)
	savedNow := enrichSaveNow
	enrichSaveNow = func() {}
	t.Cleanup(func() { enrichSaveNow = savedNow })
	dir := t.TempDir()
	device := writeCoverFile(t, dir, "device.jpg", synthCover(150, 1))
	same := writeCoverFile(t, dir, "kk/fit/1000x1000.jpg", synthCover(1000, 1))
	other := writeCoverFile(t, dir, "kk2/fit/1000x1000.jpg", synthCover(1000, 2))
	if coverURLIntendedEdge(same) != 1000 {
		t.Skipf("临时目录路径里带着别的 NxN 片段,读不出尺寸: %q", dir)
	}
	const key = "甲|乙|丙"
	var local []string
	savedLocal := localPlayerCovers
	t.Cleanup(func() { localPlayerCovers = savedLocal })
	localPlayerCovers = func(artist, title, album string, _ float64) []string {
		if artist != "甲" || title != "乙" || album != "丙" {
			t.Errorf("按这首的歌手、歌名、专辑查本机数据,得到 %q %q %q", artist, title, album)
		}
		return local
	}
	run := func(player string, locals ...string) (enrichEntry, bool) {
		local = locals
		enrichMu.Lock()
		enrichCache[key] = enrichEntry{CoverURL: device, CoverSource: "device", CoverAlbum: "丙", Lyrics: "[00:01.00]x"}
		enrichInflight[key] = true
		enrichMu.Unlock()
		changed := upgradeSmallDeviceCover(withPlayerCover(context.Background(), player), key, device, "甲", "乙", "丙", 0)
		enrichMu.Lock()
		defer enrichMu.Unlock()
		if enrichInflight[key] {
			t.Error("收工要放掉 enrichInflight")
		}
		return enrichCache[key], changed
	}
	if e, ok := run(same); !ok || e.CoverURL != same || e.CoverSource != "player" || e.CoverAlbum != "丙" {
		t.Errorf("同一张图更清晰:换成播放器的,得到 %+v", e)
	}
	if e, ok := run(other); ok || e.CoverURL != device || e.CoverSource != "device" {
		t.Errorf("不是同一张图:留设备封面,得到 %+v", e)
	}
	if e, ok := run("", same); !ok || e.CoverURL != same || e.CoverSource != "player" {
		t.Errorf("这一拍没有播放器给的、本机数据里按歌名记着同一张:换上,得到 %+v", e)
	}
	if e, ok := run(other, same); !ok || e.CoverURL != same {
		t.Errorf("播放器给的不是同一张、本机数据里那张是:换成本机那张,得到 %+v", e)
	}
	if e, ok := run("", other); ok || e.CoverSource != "device" {
		t.Errorf("本机那张也不是同一张:留设备封面,得到 %+v", e)
	}
	// 比对期间封面已经换过了:不覆盖。
	local = nil
	enrichMu.Lock()
	enrichCache[key] = enrichEntry{CoverURL: "https://p1.music.126.net/x.jpg?param=800y800", CoverSource: "netease"}
	enrichMu.Unlock()
	if upgradeSmallDeviceCover(withPlayerCover(context.Background(), same), key, device, "甲", "乙", "丙", 0) {
		t.Error("条目已经不是那张设备封面了,不该算换上")
	}
	enrichMu.Lock()
	got := enrichCache[key]
	enrichMu.Unlock()
	if got.CoverSource != "netease" {
		t.Errorf("条目已经不是那张设备封面了,不该再写: %+v", got)
	}
}

// 播放器自带的封面跟设备封面一样不参与「换成同专辑已核实邻居的封面」。
func TestPlayerCoverSkipsSiblingUpgrade(t *testing.T) {
	isolateEnrichCache(t)
	const album = "Michael"
	enrichMu.Lock()
	defer enrichMu.Unlock()
	enrichCache["Michael Jackson|Hollywood Tonight|"+album] = enrichEntry{
		CoverURL: "file:///Users/x/.config/lyrimuse/artwork/abc.jpg", CoverSource: "device", CoverAlbum: album,
	}
	if !coverCanUpgradeToVerifiedSiblingLocked(enrichEntry{CoverURL: "https://qq/x.jpg", CoverSource: "qq"}, "Michael Jackson", album) {
		t.Fatal("对照:qq 档 + 同专辑有已核实邻居该补查")
	}
	if coverCanUpgradeToVerifiedSiblingLocked(
		enrichEntry{CoverURL: "https://i.kfs.io/album/x/fit/1000x1000.jpg", CoverSource: "player"}, "Michael Jackson", album) {
		t.Error("player 档不该被判成缺")
	}
}

// 播放器自带的封面要接到首次解析、设备封面、外围补全三条后台任务上,收尾和设备封面那一趟都要经过取舍。
func TestPlayerCoverIsWired(t *testing.T) {
	enrich := string(mustRead(t, "enrich.go"))
	for _, n := range []string{
		"cancelCtx = withPlayerCover(cancelCtx, playerCover)",
		"if isNewTrack && e.CoverSource != \"device\" && e.CoverSource != \"player\" && !enrichInflight[key] {",
		"go applyDeviceCoverUpgrade(withPlayerCover(context.Background(), playerCover), key,",
		"} else if isNewTrack && e.CoverSource == \"device\" && !deviceCoverUpgradeTried[key] && !enrichInflight[key] &&\n\t\t\tdeviceCoverSmall(e.CoverURL) {",
		"deviceCoverUpgradeTried[key] = true\n\t\t\tenrichInflight[key] = true\n\t\t\tgo upgradeSmallDeviceCover(withPlayerCover(context.Background(), playerCover), key, e.CoverURL,\n\t\t\t\tartist, title, album, durationSecs)",
		"coverCanUpgradeToVerifiedSiblingLocked(e, artist, album) ||\n\t\t(e.CoverSource == \"device\" && deviceCoverSmall(e.CoverURL))",
		"go backfillPeripheralFields(withPlayerCover(withLyricSearchTitle(context.Background(), searchTitle), playerCover), key,",
		"applyDeviceOrPlayerCover(ctx, &e, deviceCoverURL, album)\n\t// 上面都没给出封面:歌词胜出的那个源自带的、专辑逐字对上的那张兜底(见 winnerCandidateCover)。\n\tif e.CoverURL == \"\" {\n\t\tif cover, source, coverAlbum := winnerCandidateCover(e.LyricsDecision, album); cover != \"\" {",
		"winnerCover, winnerSource, winnerAlbum = winnerCandidateCover(withDecisionDetails(key, pre.LyricsDecision), album)",
		"if e.CoverURL == \"\" && winnerCover != \"\" {\n\t\te.CoverURL, e.CoverSource, e.CoverAlbum = winnerCover, winnerSource, winnerAlbum",
		"if pc := playerCoverOverDevice(ctx, deviceCoverURL, existing.CoverURL); pc != \"\" {\n\t\tcover, source = pc, \"player\"",
	} {
		if !strings.Contains(enrich, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}
