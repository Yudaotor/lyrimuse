package main

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 播放采集主循环与周边的加固:视频标题按竖线分段、浏览器族「判不了」的重试、署名纠正写盘失败的节流、
// 停播判定的最短持续时间、退出时在飞的提交与镜像、Last.fm now-playing 的节流、已镜像集合的修剪、
// scutil 的嵌套字典、-config 的目录口径。

// 标记跟歌名同在一段时歌名就在这一段:整段丢掉的话频道名、「4K」会被当成歌名。
func TestParseVideoTitlePipeKeepsTitleSegment(t *testing.T) {
	for _, c := range []struct {
		artist, title, wantArtist, wantSong string
	}{
		{"Taylor Swift", "Anti-Hero (Official Music Video) | Taylor Swift", "Taylor Swift", "Anti-Hero"},
		{"Tame Impala", "Tame Impala - The Less I Know The Better (Official Video) | 4K", "Tame Impala", "The Less I Know The Better"},
		{"1theK", "IU 'Blueming' MV | 1theK", "IU", "Blueming"},
		{"Artist", "Song Title | Official Music Video | Artist", "Artist", "Song Title"},
		{"Arcade", "Utopia | Official Audio", "Arcade", "Utopia"},
	} {
		v := parseVideoTitle(c.artist, c.title)
		if v.Kind != videoTitleMusicVideo || v.Artist != c.wantArtist || v.Song != c.wantSong {
			t.Errorf("parseVideoTitle(%q, %q) = %+v, want %s / %s", c.artist, c.title, v, c.wantArtist, c.wantSong)
		}
	}
}

// 配置目录写不了时:同一份纠正每拍都会再来,失败后隔一阵才再试,不每 5 秒一条警告;换了一份照常试。
func TestPlayerArtistFixWriteFailureIsThrottled(t *testing.T) {
	var buf bytes.Buffer
	savedLogger := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(savedLogger) })
	setPlayerArtistFixPath(filepath.Join(t.TempDir(), "no-such-dir", "fix.json"))
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	for i := 0; i < 3; i++ {
		publishPlayerArtistFix("com.kugou.mac.Music", "歌", "歌手", false)
	}
	if n := strings.Count(buf.String(), "state write failed"); n != 1 {
		t.Fatalf("同一份连着失败只该试一次,试了 %d 次", n)
	}
	if strings.Contains(buf.String(), "published") {
		t.Error("没写成不该记「已发布」")
	}
	publishPlayerArtistFix("com.kugou.mac.Music", "另一首", "歌手", false)
	if n := strings.Count(buf.String(), "state write failed"); n != 2 {
		t.Fatalf("换了一份应当照常试,累计 %d 次", n)
	}
	playerArtistFixMu.Lock()
	playerArtistFixFailedAt = time.Now().Add(-playerArtistFixRetryAfter - time.Second)
	playerArtistFixMu.Unlock()
	publishPlayerArtistFix("com.kugou.mac.Music", "另一首", "歌手", false)
	if n := strings.Count(buf.String(), "state write failed"); n != 3 {
		t.Fatalf("过了重试间隔应当再试,累计 %d 次", n)
	}
}

// 三次读空要持续够一段时间才当停播:预取完成触发的 poll 能把三次挤在一两秒里。
func TestNullStreakMeansStopped(t *testing.T) {
	t0 := time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)
	if nullStreakMeansStopped(3, t0, t0.Add(1500*time.Millisecond)) {
		t.Error("三次读空挤在 1.5 秒里,不该当停播")
	}
	if !nullStreakMeansStopped(3, t0, t0.Add(10*time.Second)) {
		t.Error("正常节奏下第三拍(约 10 秒)应当当停播")
	}
	if !nullStreakMeansStopped(3, t0, t0.Add(9900*time.Millisecond)) {
		t.Error("定时器的毫秒级抖动不该把判定推到第四拍")
	}
	if nullStreakMeansStopped(2, t0, t0.Add(time.Minute)) {
		t.Error("不到三拍不当停播")
	}
}

// 退出时还在飞的提交:已经回来的照常处理;没回来、会话已结束的交给 LB 待重发队列;当前会话留给同步兜底。
func TestDrainSubmitsOnExit(t *testing.T) {
	savedRetry := lbRetryPath
	lbRetryPath = filepath.Join(t.TempDir(), "lb-retry.json")
	t.Cleanup(func() { lbRetryPath = savedRetry })

	p := &poller{ctx: context.Background(), cfg: &config{}, submitDoneCh: make(chan submitOutcome, 8)}
	mk := func(title string, ended bool) (*playSession, snapshot) {
		meta := snapshot{Artist: "歌手", Title: title}
		s := &playSession{key: title, meta: meta, submitting: true, ended: ended, lastfmExcluded: true}
		return s, meta
	}
	cur, curMeta := mk("当前", false)
	gone, goneMeta := mk("上一首", true)
	back, backMeta := mk("回来了的", true)
	p.sess = cur
	p.submitsInflight = map[*playSession]submitOutcome{
		cur:  {sess: cur, meta: curMeta, artistName: "歌手", startedAt: 100},
		gone: {sess: gone, meta: goneMeta, artistName: "歌手", startedAt: 200},
		back: {sess: back, meta: backMeta, artistName: "歌手", startedAt: 300},
	}
	p.submitDoneCh <- submitOutcome{sess: back, meta: backMeta, artistName: "歌手", startedAt: 300}

	p.drainSubmitsOnExit()

	if len(p.submitsInflight) != 0 {
		t.Fatalf("处理完应当清空: %d 条", len(p.submitsInflight))
	}
	if !back.listenSent {
		t.Error("已经回来的成功结果应当照常记成已提交")
	}
	lbRetryMu.Lock()
	items := loadLBRetryLocked()
	lbRetryMu.Unlock()
	if len(items) != 1 || items[0].ListenedAt != 200 {
		t.Fatalf("只有没回来、会话已结束的那条进待重发队列: %+v", items)
	}
	if cur.listenSent {
		t.Error("当前会话不在这里处理")
	}
}

// 退出前等活路径上发出去的 Last.fm 写入发完,最多等到 flush 的时限。
func TestWaitMirrorsInflight(t *testing.T) {
	mirrorsInflight.Add(1)
	go func() {
		time.Sleep(60 * time.Millisecond)
		mirrorsInflight.Add(-1)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if n := waitMirrorsInflight(ctx); n != 0 {
		t.Fatalf("写入结束后应当返回 0,得到 %d", n)
	}
	mirrorsInflight.Add(1)
	defer mirrorsInflight.Add(-1)
	short, cancelShort := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancelShort()
	if n := waitMirrorsInflight(short); n != 1 {
		t.Fatalf("时限到了还有 1 条在飞,得到 %d", n)
	}
}

// suppressEnrichResolveForTest 把这几个 key 标成「后台解析在飞」:trackEnrichment 看到在飞就不再起一个(见 enrich.go
// looseInflightKey),测试里只查缓存、不留下联网的后台任务。收尾时撤掉标记。
func suppressEnrichResolveForTest(t *testing.T, keys ...string) {
	t.Helper()
	enrichMu.Lock()
	for _, k := range keys {
		enrichInflight[k] = true
	}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		for _, k := range keys {
			delete(enrichInflight, k)
		}
		enrichMu.Unlock()
	})
}

// LB 挂着时每一拍都会再 announce 一次:Last.fm now-playing 自己节流,播放 / 暂停切换当场发,其余最多每分钟一次。
func TestAnnounceThrottlesLastfmNowPlaying(t *testing.T) {
	p := &poller{ctx: context.Background(), lb: &lbClient{dryRun: true}, announceDoneCh: make(chan announceOutcome, 8)}
	p.cur = snapshot{Artist: "歌手", Title: "歌", Playing: true}
	// announce 组装载荷时会查这首的歌词(lbMeta → trackEnrichment),缓存里没有就起一个真去联网的后台解析,
	// 测试结束了它还在跑,撞上后面换网络钩子、改开关的用例。标成「解析在飞」,这里只查不起。
	suppressEnrichResolveForTest(t, enrichKey(p.cur.Artist, p.cur.Title, p.cur.Album))
	p.sess = &playSession{key: p.cur.key(), meta: p.cur}
	t0 := time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)
	step := func(at time.Time, why string) {
		t.Helper()
		p.announce(at, why)
		r := <-p.announceDoneCh
		r.ok = false // 模拟 LB 失败:lastPN 不推进,下一拍照样会再 announce
		p.applyAnnounceOutcome(r)
	}
	step(t0, "first")
	if !p.sess.lastfmNPAt.Equal(t0) {
		t.Fatalf("第一次应当发: %v", p.sess.lastfmNPAt)
	}
	step(t0.Add(5*time.Second), "refresh")
	if !p.sess.lastfmNPAt.Equal(t0) {
		t.Fatalf("LB 失败后的下一拍不该再发: %v", p.sess.lastfmNPAt)
	}
	step(t0.Add(10*time.Second), "state change")
	if !p.sess.lastfmNPAt.Equal(t0.Add(10 * time.Second)) {
		t.Fatalf("播放 / 暂停切换要当场发: %v", p.sess.lastfmNPAt)
	}
	step(t0.Add(10*time.Second+playingNowRefresh), "refresh")
	if !p.sess.lastfmNPAt.Equal(t0.Add(10*time.Second + playingNowRefresh)) {
		t.Fatalf("过了刷新间隔照常发: %v", p.sess.lastfmNPAt)
	}
	p.cur.Playing = false
	step(t0.Add(time.Hour), "state change")
	if !p.sess.lastfmNPAt.Equal(t0.Add(10*time.Second + playingNowRefresh)) {
		t.Fatalf("暂停时不发 Last.fm now-playing: %v", p.sess.lastfmNPAt)
	}
}

// 只开镜像写入、没配桥接的机器上,已镜像集合也要修剪:写的时候顺手剪掉过期的。
func TestMirrorScrobbleTrimsMirroredSet(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mirrored.json")
	lfm := &lastfmScrobbler{}
	lfm.dead.Store(true) // 不发请求
	now := time.Now().Unix()
	old := now - int64(lfmMirroredTTL/time.Second) - 3600
	p := &poller{lfm: lfm, lfmMirrored: map[int64]bool{old: true}, lfmMirroredSet: persistedTTLSet{path: path, ttl: lfmMirroredTTL}}
	p.mirrorScrobbleTracked("歌手", "歌", "专辑", now, "歌手", 200, false)
	if p.lfmMirrored[old] || !p.lfmMirrored[now] {
		t.Fatalf("过期的应当剪掉、新的留下: %v", p.lfmMirrored)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var saved []int64
	if err := json.Unmarshal(raw, &saved); err != nil || len(saved) != 1 || saved[0] != now {
		t.Fatalf("落盘的也是剪过的那份: %s", raw)
	}
}

// __SCOPED__ 底下按网卡的整套代理不能盖掉顶层真正生效的那份。
func TestParseSCUtilProxyIgnoresScopedDictionaries(t *testing.T) {
	in := "<dictionary> {\n  ExceptionsList : <array> {\n    0 : *.local\n  }\n  HTTPSEnable : 0\n" +
		"  __SCOPED__ : <dictionary> {\n    utun4 : <dictionary> {\n      HTTPSEnable : 1\n      HTTPSPort : 8080\n      HTTPSProxy : 10.1.2.3\n    }\n  }\n}"
	if u := parseSCUtilProxy(in); u != nil {
		t.Fatalf("顶层关着代理,不该拿网卡自己的: %v", u)
	}
	in = "<dictionary> {\n  HTTPSEnable : 1\n  HTTPSPort : 7897\n  HTTPSProxy : 127.0.0.1\n" +
		"  __SCOPED__ : <dictionary> {\n    en0 : <dictionary> {\n      HTTPSEnable : 1\n      HTTPSPort : 3128\n      HTTPSProxy : 10.9.9.9\n    }\n  }\n}"
	if u := parseSCUtilProxy(in); u == nil || u.Host != "127.0.0.1:7897" {
		t.Fatalf("应当是顶层那份 127.0.0.1:7897,得到 %v", u)
	}
	// 没有最外层那一行的裸键值照样认。
	if u := parseSCUtilProxy("HTTPSEnable : 1\nHTTPSPort : 1\nHTTPSProxy : 1.1.1.1\n"); u == nil || u.Host != "1.1.1.1:1" {
		t.Fatalf("裸键值: %v", u)
	}
}

// -config 指到别处时 configDir() 要跟过去;就是默认目录时不动环境。
func TestAlignConfigDirWithFlag(t *testing.T) {
	saved, had := os.LookupEnv("LYRIMUSE_CONFIG_DIR")
	t.Cleanup(func() {
		if had {
			os.Setenv("LYRIMUSE_CONFIG_DIR", saved)
		} else {
			os.Unsetenv("LYRIMUSE_CONFIG_DIR")
		}
	})
	def := t.TempDir()
	os.Setenv("LYRIMUSE_CONFIG_DIR", def)
	alignConfigDirWithFlag(filepath.Join(def, "config.json"), def)
	if configDir() != def {
		t.Fatalf("默认目录时不该改: %q", configDir())
	}
	other := t.TempDir()
	alignConfigDirWithFlag(filepath.Join(other, "config.json"), def)
	if configDir() != other {
		t.Fatalf("-config 在别处时 configDir 应当跟过去: %q", configDir())
	}
}
