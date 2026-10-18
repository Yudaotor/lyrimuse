package main

import (
	"context"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

func TestAlbumIsPlaceholder(t *testing.T) {
	for album, want := range map[string]bool{"单曲发行": true, " 单曲发行 ": true, "单曲": false, "3121": false, "": false} {
		if got := albumIsPlaceholder(album); got != want {
			t.Errorf("albumIsPlaceholder(%q) = %v", album, got)
		}
	}
	if coverAlbumOrNone("单曲发行") != "" || coverAlbumOrNone("3121") != "3121" {
		t.Error("coverAlbumOrNone:占位名算没有,别的原样")
	}
}

// 两侧名单必须相同:App 按它不用洛雪给占位专辑的图,引擎按它不把那张图记成封面;只改一边,另一边还会把歌手照片当封面。
func TestPlaceholderAlbumNamesMatchSwift(t *testing.T) {
	src, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Models/PlaceholderAlbum.swift")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`names: Set<String> = \[([^\]]*)\]`).FindStringSubmatch(string(src))
	if m == nil {
		t.Fatal("读不到 PlaceholderAlbum.names")
	}
	var swift, goSide []string
	for _, q := range regexp.MustCompile(`"([^"]+)"`).FindAllStringSubmatch(m[1], -1) {
		swift = append(swift, q[1])
	}
	for name := range placeholderAlbumNames {
		goSide = append(goSide, name)
	}
	sort.Strings(swift)
	sort.Strings(goSide)
	if len(swift) == 0 || strings.Join(swift, ",") != strings.Join(goSide, ",") {
		t.Fatalf("两侧占位专辑名单不一致:\n Swift %v\n Go    %v", swift, goSide)
	}
}

// 占位专辑名在封面这几步算没报专辑:不按它把几首归成一张专辑,别的专辑的封面不算「另一张专辑的」,候选报什么专辑都对得上。
func TestPlaceholderAlbumCountsAsNoAlbumForCovers(t *testing.T) {
	if got := entryListedAlbum(enrichKey("Prince", "Love", "单曲发行"), enrichEntry{}); got != "" {
		t.Errorf("entryListedAlbum = %q, 占位名算没有专辑", got)
	}
	if got := entryListedAlbum(enrichKey("Prince", "Love", "3121"), enrichEntry{}); got != "3121" {
		t.Errorf("entryListedAlbum = %q, 真专辑照旧", got)
	}
	qq := enrichEntry{CoverURL: "https://y.qq.com/music/photo_new/T002R800x800M0000046Ho1e25qLHQ.jpg", CoverSource: "qq",
		CoverAlbum: "3121"}
	if coverOfAnotherAlbum(qq, "单曲发行") {
		t.Error("占位专辑名下的歌,《3121》的封面不算另一张专辑的")
	}
	if !coverOfAnotherAlbum(qq, "Musicology") {
		t.Error("真专辑对不上照旧算另一张专辑的")
	}
	if !candidateCoverAlbumFits("3121", "单曲发行") || candidateCoverAlbumFits("3121", "Musicology") {
		t.Error("candidateCoverAlbumFits:占位名什么专辑都对得上,真专辑照旧比")
	}
}

// 选封面用的专辑名:占位名按没报,走 Apple 目录回填;真专辑原样。
func TestCoverAlbumForTrackPlaceholder(t *testing.T) {
	_, restore := seedPrinceHintCache(t)
	defer restore()
	const title = "Why You Wanna Treat Me So Bad?"
	enrichCache = map[string]enrichEntry{
		"王子|" + title + "|单曲发行": {LyricsDecisionApplied: &lyricsDecision{Winner: "kugou",
			Candidates: []lyricsDecisionCandidate{{Source: "kugou", Artist: "Prince"}}}},
	}
	ctx := context.Background()
	if got := coverAlbumForTrack(ctx, "王子", title, "单曲发行", 230.121); got != "Prince" {
		t.Fatalf("占位专辑名:回填 Apple 目录的专辑,got %q", got)
	}
	if got := coverAlbumForTrack(ctx, "王子", title, "3121", 230.121); got != "3121" {
		t.Fatalf("真专辑原样返回,got %q", got)
	}
}

// 洛雪列表里记在占位专辑名下的那首,它给的图不当播放器自带封面;同一首按真专辑问照常给。
func TestPlayerCoverURLForPlaceholderAlbum(t *testing.T) {
	withLXMusicData(t, []lxTestTrack{{"temp", "mg_1", "Placeholder Love", "Prince", "05:45", "单曲发行"}}, nil, "temp", 0, "listLoop")
	lxTestSQL(t, `UPDATE my_list_music_info SET meta = json_set(meta, '$.picUrl', '/data/oss/resource/00/45/cq/a.webp') WHERE id = 'mg_1';`)
	if got := playerCoverURLFor(lxMusicBundleID, "Prince", "Placeholder Love", "单曲发行", 345, kkboxPlayingInfo{}); got != "" {
		t.Fatalf("占位专辑名下给的是歌手照片,不当封面: %q", got)
	}
	if got := playerCoverURLFor(lxMusicBundleID, "Prince", "Placeholder Love", "3121", 345, kkboxPlayingInfo{}); got == "" {
		t.Fatal("同一首按真专辑问照常给")
	}
}

func TestWinnerCandidateCoverSkipping(t *testing.T) {
	photo := "https://d.musicapp.migu.cn/data/oss/resource/00/45/cq/a.webp"
	album := "https://p1.music.126.net/3121.jpg"
	d := &lyricsDecision{Winner: "migu", Candidates: []lyricsDecisionCandidate{
		{Source: "migu", Score: 1056, CoverURL: photo},
		{Source: "netease", Score: 1091, Album: "3121", CoverURL: album},
	}}
	if cover, _, _ := winnerCandidateCover(d, ""); cover != photo {
		t.Fatalf("不跳过时先给胜出那个源的: %q", cover)
	}
	if cover, source, coverAlbum := winnerCandidateCoverSkipping(d, "", map[string]bool{photo: true}); cover != album ||
		source != "netease" || coverAlbum != "3121" {
		t.Fatalf("跳过歌手照片之后给下一个: %q %q %q", cover, source, coverAlbum)
	}
}

// 启动清理:占位专辑名下记的播放器图清掉;封面就是那张图的换成歌词判决里头一个自带封面、不是那张图的候选,没有就清空;
// 封面不是播放器给的不动;别的专辑的条目不动;清完落盘。
func TestMigratePlaceholderAlbumCovers(t *testing.T) {
	photo := "https://d.musicapp.migu.cn/data/oss/resource/00/45/cq/a.webp"
	album := "https://p1.music.126.net/3121.jpg"
	device := "file:///tmp/artwork/0123456789abcdef.jpg"
	decision := &lyricsDecision{Winner: "lxmusic", Candidates: []lyricsDecisionCandidate{
		{Source: "lxmusic", Score: 1456, Album: "单曲发行"},
		{Source: "migu", Score: 1091, CoverURL: photo},
		{Source: "netease", Score: 1091, Album: "3121", CoverURL: album},
	}}
	love := enrichKey("Prince", "Love", "单曲发行")
	bare := enrichKey("Prince", "3121", "单曲发行")
	dev := enrichKey("Prince", "Satisfied", "单曲发行")
	real := enrichKey("Prince", "Love", "3121")
	lx := map[string]string{lxMusicBundleID: photo}
	setUpEnrichEditTest(t, map[string]enrichEntry{
		love: {CoverURL: photo, CoverSource: "player", CoverAlbum: "单曲发行", AccentColor: "#112233", PlayerCovers: lx,
			LyricsDecision: decision, Lyrics: "[00:01.00]词"},
		bare: {CoverURL: photo, CoverSource: "player", CoverAlbum: "单曲发行", PlayerCovers: lx},
		dev:  {CoverURL: device, CoverSource: "device", CoverAlbum: "单曲发行", PlayerCovers: lx},
		real: {CoverURL: photo, CoverSource: "player", CoverAlbum: "3121", PlayerCovers: lx},
	})
	migratePlaceholderAlbumCovers()
	if e, _ := cacheEntry(t, love); e.CoverURL != album || e.CoverSource != "netease" || e.CoverAlbum != "3121" ||
		e.AccentColor != "" || e.PlayerCovers != nil || e.Lyrics != "[00:01.00]词" {
		t.Fatalf("换成判决里头一个不是歌手照片的候选封面: %+v", e)
	}
	if e, _ := cacheEntry(t, bare); e.CoverURL != "" || e.CoverSource != "" || e.PlayerCovers != nil {
		t.Fatalf("判决里没有能用的候选:封面清空: %+v", e)
	}
	if e, _ := cacheEntry(t, dev); e.CoverURL != device || e.CoverSource != "device" || e.PlayerCovers != nil {
		t.Fatalf("封面不是播放器给的不动,只清记下的播放器图: %+v", e)
	}
	if e, _ := cacheEntry(t, real); e.CoverURL != photo || e.PlayerCovers[lxMusicBundleID] != photo {
		t.Fatalf("真专辑的条目不动: %+v", e)
	}
	disk, err := os.ReadFile(enrichPath)
	if err != nil || !strings.Contains(string(disk), album) {
		t.Fatalf("清完要落盘 err=%v", err)
	}
}

// 封面是播放器给的、但播放器那张表已经空了的条目:照样认得出那张照片,不会从判决里把同一张图再挑回来。
func TestMigratePlaceholderAlbumCoversWithoutPlayerCovers(t *testing.T) {
	photo := "https://d.musicapp.migu.cn/data/oss/resource/00/45/cq/a.webp"
	album := "https://p1.music.126.net/3121.jpg"
	key := enrichKey("Prince", "Get On The Boat", "单曲发行")
	setUpEnrichEditTest(t, map[string]enrichEntry{key: {CoverURL: photo, CoverSource: "player", LyricsDecision: &lyricsDecision{
		Winner: "migu", Candidates: []lyricsDecisionCandidate{
			{Source: "migu", Score: 1091, CoverURL: photo},
			{Source: "qq", Score: 1056, Album: "3121", CoverURL: album},
		}}}})
	migratePlaceholderAlbumCovers()
	if e, _ := cacheEntry(t, key); e.CoverURL != album || e.CoverSource != "qq" {
		t.Fatalf("跳过跟现在封面同一个地址的候选: %+v", e)
	}
}

// 没法单独跑的几处接线(扫源码):外围补全把整组动态封面结论换上;换上设备封面后、播到结论作废的歌时、后台补封面那一遍都重核;
// 首次解析选封面按占位专辑名算没报;启动时清掉占位专辑名下的播放器图。
func TestMotionVerdictAndPlaceholderWiring(t *testing.T) {
	enrich := string(mustRead(t, "enrich.go"))
	body := func(sig string) string {
		start := strings.Index(enrich, sig)
		if start < 0 {
			t.Fatalf("找不到 %s", sig)
		}
		b := enrich[start:]
		if end := strings.Index(b, "\n}\n"); end >= 0 {
			b = b[:end]
		}
		return b
	}
	backfill := body("func backfillPeripheralFields(ctx context.Context,")
	if !containsCode(backfill, "takeFreshMotion := motionCheckMatchesRetainedCover && fresh.MotionCoverChecked &&\n\t\t(fresh.MotionCoverURL != \"\" || e.MotionCoverURL == \"\")") ||
		!strings.Contains(backfill, "e.MotionCoverFor = fresh.MotionCoverFor") ||
		!containsCode(backfill, "motionCoverNeedsRecheckAgainstOwnCover(\n\t\ttakeFreshMotion || (motionCheckMatchesRetainedCover && !fresh.MotionCoverChecked), e)") {
		t.Error("外围补全:fresh 对着留用的封面核出了结论就整组换上(连对照封面),说没有而手上挂着一段时不换、交给重核")
	}
	upgrade := body("func deviceCoverUpgradePass(")
	if !containsCode(upgrade, "requestEnrichSaveFor(key)\n\t// 封面刚换了,动态封面原来的结论是对着旧封面核的:按这张重核。\n\trecheckMotionCoverAgainstCurrentCover(ctx, key, title, album)") {
		t.Error("换上设备封面之后照新封面重核动态封面")
	}
	track := body("func trackEnrichment(")
	if !strings.Contains(track, "} else if motionVerdictStale(e) && !motionRecheckTried[key] && !enrichInflight[key] {") ||
		!strings.Contains(track, "go recheckPlayingMotionCover(key, title, album)") {
		t.Error("播到结论作废的歌时重核一次")
	}
	if !strings.Contains(body("func finishTrackEnrichment("), "coverAlbum := coverAlbumOrNone(album)") {
		t.Error("首次解析选封面:占位专辑名按没报")
	}
	sweep := string(mustRead(t, "coversweep.go"))
	if !strings.Contains(sweep, "offline = coverSweepRecheckStaleMotion(ctx).offline") {
		t.Error("后台补封面一遍跑完重核动态封面结论作废的条目")
	}
	if !strings.Contains(string(mustRead(t, "main.go")), `startupStep("migratePlaceholderAlbumCovers", migratePlaceholderAlbumCovers)`) {
		t.Error("启动时清掉占位专辑名下记成封面的播放器图")
	}
}
