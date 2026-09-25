package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// 下面所有序列都是在装了酷狗 3.3.2 的机器上连续采 media-control 得到的
// 真实读数,不是构造的。

// kugouNowPlayingPlist 造一份跟实机同构的 plist:userPlayList 是
// `[ [队列...], {当前曲目}, "0" ]` —— 当前曲目是直接挂在数组上的那个 dict,
// 队列那一项是**数组**。解析必须跳过数组、认准 dict,这份结构就是为了守住这一点。
//
// 写 XML plist 而不是 bplist:读取路径内部要 exec `plutil -convert xml1`,而 plutil 对
// XML 输入是恒等转换 —— 不必在测试里造二进制,走的仍是完整那条路(同 qqupcoming_test.go)。
func kugouNowPlayingPlist(t *testing.T, queueName, musicName, singerName string) string {
	t.Helper()
	singer := ""
	if singerName != "" {
		singer = "<key>singerName</key><string>" + singerName + "</string>"
	}
	body := `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>kPlayListSaveFromPage</key><string>酷狗首页\听首页\导航栏\推荐</string>
  <key>userPlayList</key>
  <array>
    <array>
      <dict>
        <key>musicName</key><string>` + queueName + `</string>
        <key>musicTime</key><integer>210</integer>
      </dict>
    </array>
    <dict>
      <key>classname</key><string>SongInfo</string>
      <key>musicName</key><string>` + musicName + `</string>
      ` + singer + `
      <key>musicTime</key><integer>195</integer>
      <key>currentProgress</key><real>56.165</real>
    </dict>
    <string>0</string>
  </array>
</dict>
</plist>`
	path := filepath.Join(t.TempDir(), "userCurrentPlayList.plist")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("写测试 plist 失败: %v", err)
	}
	return path
}

func useKugouNowPlaying(t *testing.T, path string) {
	t.Helper()
	old := kugouNowPlayingOverride
	kugouNowPlayingOverride = path
	t.Cleanup(func() { kugouNowPlayingOverride = old })
}

// resetKugouLyricArtist 清掉包级状态,免得用例之间互相串。
func resetKugouLyricArtist(t *testing.T) {
	t.Helper()
	kugouLyricArtistMu.Lock()
	kugouLyricArtistValue, kugouArtistPoisonConfirmed = kugouLyricArtistState{}, false
	kugouLyricArtistMu.Unlock()
	t.Cleanup(func() {
		kugouLyricArtistMu.Lock()
		kugouLyricArtistValue, kugouArtistPoisonConfirmed = kugouLyricArtistState{}, false
		kugouLyricArtistMu.Unlock()
	})
}

// 一首歌里 artist 换了个值 = 污染。真换歌 title 必变,所以这个组合在正常播放下不会出现。
func TestAdvanceKugouLyricArtistDetectsLyricRotation(t *testing.T) {
	// 「李佳薇 - 甲乙丙丁 (你我怎么两清)」播放中的连续读数。
	lyrics := []string{
		"假装你还在身旁",
		"墙上的合照剩一半",
		"你晾的衣服还没干",
		"桌上的晚餐 还来不及吃完",
		"我的心你还没还",
	}
	var st kugouLyricArtistState
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "甲乙丙丁 (你我怎么两清)", lyrics[0], 210, false)
	if st.poisoned {
		t.Fatal("只见过一个署名就判定了,那是把所有酷狗曲目都当成被污染")
	}
	if st.first != lyrics[0] {
		t.Errorf("first = %q,应记下第一次见到的署名 %q", st.first, lyrics[0])
	}
	for _, l := range lyrics[1:] {
		st = advanceKugouLyricArtist(st, kugouMusicBundleID, "甲乙丙丁 (你我怎么两清)", l, 210, false)
	}
	if !st.poisoned {
		t.Error("同一首歌里署名换了四次仍未判定")
	}
}

// LRC 头部的制作信息行同样会被推成 artist,判据不看内容所以照样认得出来。
func TestAdvanceKugouLyricArtistDetectsCreditHeaderRotation(t *testing.T) {
	// 「阿图表妹 - 你有没有真的爱过我」开播头十几秒的连续读数:第一拍是真署名。
	seq := []string{"阿图表妹", "原唱：谈柒柒", "作曲：廖伟志", "艺人统筹：小帅", "发行：华声时代"}
	var st kugouLyricArtistState
	for _, a := range seq {
		st = advanceKugouLyricArtist(st, kugouMusicBundleID, "你有没有真的爱过我", a, 243, false)
	}
	if !st.poisoned {
		t.Fatal("制作信息行轮换没被认出来")
	}
	if st.first != "阿图表妹" {
		t.Errorf("first = %q,应是开播第一拍那个真署名「阿图表妹」", st.first)
	}
}

// 只对酷狗生效。别的播放器换署名有正当理由(换歌、补全),这套判定不该碰它们。
func TestAdvanceKugouLyricArtistIgnoresOtherPlayers(t *testing.T) {
	for _, bundle := range []string{qqMusicBundleID, neteaseMusicBundleID, sodaMusicBundleID, appleMusicBundleID, spotifyBundleID} {
		var st kugouLyricArtistState
		st = advanceKugouLyricArtist(st, bundle, "某首歌", "歌手甲", 200, false)
		st = advanceKugouLyricArtist(st, bundle, "某首歌", "歌手乙", 200, false)
		if st.poisoned {
			t.Errorf("%s 被判成污染了,这套判定只该管酷狗", bundle)
		}
	}
}

// 换歌重新起判:上一首的判定结论不能带到下一首。
func TestAdvanceKugouLyricArtistResetsOnTrackChange(t *testing.T) {
	var st kugouLyricArtistState
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "甲乙丙丁 (你我怎么两清)", "假装你还在身旁", 210, false)
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "甲乙丙丁 (你我怎么两清)", "墙上的合照剩一半", 210, false)
	if !st.poisoned {
		t.Fatal("前置条件没成立")
	}
	// 实机切歌那一拍:曲名已经是新的,载荷里还没有 duration。
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "我不难过", "孙燕姿", 0, false)
	if st.poisoned {
		t.Error("换歌之后还挂着上一首的判定")
	}
	if st.first != "孙燕姿" {
		t.Errorf("first = %q,换歌后应重记成 %q", st.first, "孙燕姿")
	}
	// 几拍之后 duration 补上,这同样是一次重新起判 —— 那几拍的署名还是干净的。
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "我不难过", "孙燕姿", 320, false)
	if st.poisoned {
		t.Error("duration 从缺失补齐被当成了污染")
	}
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "我不难过", "我真的懂 你不是喜新厌旧", 320, false)
	if !st.poisoned {
		t.Error("新曲目自己的歌词轮换没被认出来")
	}
}

// 先报曲名后补署名是补全,不是污染 —— 空串不参与判定。
func TestAdvanceKugouLyricArtistTreatsLateArtistAsBackfill(t *testing.T) {
	var st kugouLyricArtistState
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "泪海", "", 298, false)
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "泪海", "许茹芸", 298, false)
	if st.poisoned {
		t.Fatal("空串到非空被当成污染了")
	}
	if st.first != "许茹芸" {
		t.Errorf("first = %q,应是补上来的那个署名", st.first)
	}
	// 载荷偶尔漏一拍署名,也不该翻案。
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "泪海", "", 298, false)
	if st.poisoned {
		t.Error("署名漏了一拍被当成污染")
	}
}

// 判定成立之后本曲一直成立:歌词绕回第一句时 artist 会跟 first 重合,那不是"恢复正常"。
func TestAdvanceKugouLyricArtistKeepsVerdictWithinTrack(t *testing.T) {
	var st kugouLyricArtistState
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "泪海", "爱已不能动", 298, false)
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "泪海", "还有什么值得我心痛", 298, false)
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "泪海", "爱已不能动", 298, false)
	if !st.poisoned {
		t.Error("署名转回第一次见到的那个,判定就被撤销了")
	}
}

// 当前曲目是挂在数组上的那个 dict,不在队列数组里面。
func TestKugouNowPlayingTrackSkipsQueueArray(t *testing.T) {
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "李佳薇 - 甲乙丙丁 (你我怎么两清)", "Stake、TwoP - 爱情慢慢来", "Stake"))
	local, ok := kugouReadNowPlaying(kugouNowPlayingPath())
	if !ok {
		t.Fatal("读不到当前曲目")
	}
	if local.title != "爱情慢慢来" {
		t.Errorf("title = %q,应是当前曲目而不是队列里那首", local.title)
	}
	if local.artist != "Stake" {
		t.Errorf("artist = %q,应优先取 singerName", local.artist)
	}
	if local.credit != "Stake、TwoP" {
		t.Errorf("credit = %q,应是 musicName 里的全署名(只用来比对,不拿它换上去)", local.credit)
	}
}

// singerName 是主歌手,跟这个播放器没被污染时报的 artist 逐字一致;拿 musicName 里的
// 全署名换上去会造出一个与历史缓存 key 对不上的写法。
func TestKugouNowPlayingTrackPrefersSingerNameOverFullCredit(t *testing.T) {
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))
	local, ok := kugouReadNowPlaying(kugouNowPlayingPath())
	if !ok {
		t.Fatal("读不到当前曲目")
	}
	if local.artist != "Stake" {
		t.Errorf("artist = %q,应是 singerName 而不是全署名", local.artist)
	}
}

// singerName 缺了就拆 musicName 的 "歌手 - 歌名"。
func TestKugouNowPlayingTrackFallsBackToMusicNamePrefix(t *testing.T) {
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "孙燕姿 - 我不难过", ""))
	local, ok := kugouReadNowPlaying(kugouNowPlayingPath())
	if !ok {
		t.Fatal("读不到当前曲目")
	}
	if local.artist != "孙燕姿" || local.title != "我不难过" {
		t.Errorf("拆出来是 (%q, %q),应为 (\"孙燕姿\", \"我不难过\")", local.artist, local.title)
	}
}

func TestKugouNowPlayingTrackRejectsGarbage(t *testing.T) {
	for _, root := range []any{
		nil,
		map[string]any{},                        // 没有 userPlayList
		map[string]any{"userPlayList": []any{}}, // 空队列
		map[string]any{"userPlayList": []any{"0"}},                             // 只有那个尾巴
		map[string]any{"userPlayList": []any{map[string]any{"musicName": ""}}}, // 曲名为空
	} {
		if _, ok := kugouNowPlayingTrack(root); ok {
			t.Errorf("%#v 被当成了有效的当前曲目", root)
		}
	}
}

// 这个播放器一旦被坐实会拿歌词冒充署名,后面每首歌开头那十来秒也一起救回来 ——
// 否则每换一首都要重新等它换第二次署名,而那段脏署名照样会推出去。
func TestAdvanceKugouLyricArtistStartsPoisonedOncePlayerConfirmed(t *testing.T) {
	var st kugouLyricArtistState
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "泪海", "爱已不能动", 298, true)
	if !st.poisoned {
		t.Error("已经坐实过的播放器,新曲目第一拍就该按被污染处理")
	}
	if st.first != "爱已不能动" {
		t.Errorf("first = %q,仍应记下第一次见到的署名", st.first)
	}
}

// 没坐实过就老老实实等证据 —— 别把原生版的正常署名也当成污染。
func TestAdvanceKugouLyricArtistNeedsEvidenceBeforeConfirmed(t *testing.T) {
	var st kugouLyricArtistState
	st = advanceKugouLyricArtist(st, kugouMusicBundleID, "泪海", "许茹芸", 298, false)
	if st.poisoned {
		t.Error("一个署名都还没换过就判定了")
	}
}

func TestPublishPlayerArtistFixDedupes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fix.json")
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	publishPlayerArtistFix(kugouMusicBundleID, "爱情慢慢来", "Stake", true)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("没写出状态文件: %v", err)
	}
	var got playerArtistFixState
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("状态文件解析失败: %v", err)
	}
	if got.Bundle != kugouMusicBundleID || got.Title != "爱情慢慢来" || got.Artist != "Stake" {
		t.Errorf("写出来的是 %+v", got)
	}
	if got.UpdatedAt == 0 {
		t.Error("没有时间戳")
	}

	// 同一条不重写:这个函数每首歌每一拍都会被调到。
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	publishPlayerArtistFix(kugouMusicBundleID, "爱情慢慢来", "Stake", true)
	if _, err := os.Stat(path); err == nil {
		t.Error("同一条纠正被重复写盘了")
	}

	// 换一首就该写。
	publishPlayerArtistFix(kugouMusicBundleID, "我不难过", "孙燕姿", true)
	if _, err := os.Stat(path); err != nil {
		t.Errorf("换歌之后没写: %v", err)
	}
}

func TestPublishPlayerArtistFixSkipsIncomplete(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fix.json")
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	for _, c := range [][3]string{
		{"", "爱情慢慢来", "Stake"},
		{kugouMusicBundleID, "", "Stake"},
		{kugouMusicBundleID, "爱情慢慢来", ""},
	} {
		publishPlayerArtistFix(c[0], c[1], c[2], true)
		if _, err := os.Stat(path); err == nil {
			t.Errorf("%v 这种残缺的纠正也发布了", c)
			_ = os.Remove(path)
		}
	}
}

// 上一个进程的结论作不得数:App 只按 bundle + 曲名比对,陈旧记录正好能撞上同一首歌。
func TestSetPlayerArtistFixPathClearsStaleFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fix.json")
	if err := os.WriteFile(path, []byte(`{"bundle":"x","title":"y","artist":"z"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })
	if _, err := os.Stat(path); err == nil {
		t.Error("上一次运行留下的状态文件没被清掉")
	}
}

// 判定成立之后,给出的是本地读到的真署名。
func TestKugouFixedArtistRestoresTrueArtist(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))

	// 本地那份对得上歌名、署名却跟它的两种写法都对不上 —— 第一拍就够判了,
	// 不必等它唱到第二句。
	got, ok := kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195)
	if !ok || got != "Stake" {
		t.Errorf("= (%q, %v),本地那份已经能分辨,第一拍就该纠正", got, ok)
	}
	got, ok = kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "被窝里面心酸", 195)
	if !ok || got != "Stake" {
		t.Errorf("= (%q, %v),应换成本地读到的真署名 Stake", got, ok)
	}
	got, ok = kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "像个士兵原地待命", 195)
	if !ok || got != "Stake" {
		t.Errorf("= (%q, %v),判定成立后每一拍都该给出真署名", got, ok)
	}
}

// 本地那份读不到(没授权 / 没装)时退回这首歌第一次见到的署名 —— 它未必对,但能让曲目
// 身份稳定下来,不再每唱一句就当成换了一首歌。这条稳定性就是整个改动的全部收益。
func TestKugouFixedArtistKeepsTrackIdentityStable(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, filepath.Join(t.TempDir(), "不存在.plist"))

	keys := map[string]bool{}
	for _, lyric := range []string{
		"阿图表妹", "原唱：谈柒柒", "作曲：廖伟志", "艺人统筹：小帅", "【版权所有 未经许可 不得翻",
	} {
		s := snapshot{Bundle: kugouMusicBundleID, Title: "你有没有真的爱过我", Artist: lyric, Duration: 243}
		if fixed, ok := kugouFixedArtist(s.Bundle, s.Title, s.Artist, s.Duration); ok {
			s.Artist = fixed
		}
		keys[s.key()] = true
	}
	if len(keys) != 1 {
		t.Errorf("曲目身份出现了 %d 个不同的值,应当自始至终是同一个:%v", len(keys), keys)
	}
	if !keys["你有没有真的爱过我|阿图表妹|"] {
		t.Errorf("稳定下来的身份不对: %v", keys)
	}
}

// 本地那份比 media-control 晚一步:换曲时曲名已经是新的、文件还停在上一首。
// 歌名对不上就退回第一次见到的署名,别把上一首的按到这一首身上。
func TestKugouFixedArtistIgnoresStaleLocalTrack(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))

	kugouFixedArtist(kugouMusicBundleID, "我不难过", "孙燕姿", 320)
	got, ok := kugouFixedArtist(kugouMusicBundleID, "我不难过", "我真的懂 你不是喜新厌旧", 320)
	if !ok || got != "孙燕姿" {
		t.Errorf("= (%q, %v),本地那份还停在上一首时应退回第一次见到的署名,而不是按上 Stake", got, ok)
	}
}

func TestKugouFixedArtistLeavesOtherPlayersAlone(t *testing.T) {
	resetKugouLyricArtist(t)
	for _, bundle := range []string{qqMusicBundleID, neteaseMusicBundleID, appleMusicBundleID} {
		kugouFixedArtist(bundle, "某首歌", "歌手甲", 200)
		if _, ok := kugouFixedArtist(bundle, "某首歌", "歌手乙", 200); ok {
			t.Errorf("%s 的署名被改了,这套判定只该管酷狗", bundle)
		}
	}
}

// 纠正生效的同一刻就要发布出去,App 侧靠它才能用同一个署名查到歌词。
func TestKugouFixedArtistPublishesForTheApp(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))
	path := filepath.Join(t.TempDir(), "fix.json")
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	fixed, _ := kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("判定成立却没发布: %v", err)
	}
	var got playerArtistFixState
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got.Artist != fixed {
		t.Errorf("发布的署名 %q 跟这一拍用的 %q 不是同一个,App 据此查缓存就会落空", got.Artist, fixed)
	}
	if got.Title != "爱情慢慢来" || got.Bundle != kugouMusicBundleID {
		t.Errorf("发布的适用范围不对: %+v", got)
	}
}

// 封面走的是**另一次**独立的 media-control 调用,载荷里是播放器原样报的署名。那道
// 「这份封面属于哪首歌」的核对必须跟主路径用同一把尺子 —— 否则恒不相等,系统直送封面
// 被无声无息地全部丢掉、悄悄退回网络检索,日志里一个字都没有。
func TestKugouKnownArtistFixAlignsTheArtworkCheck(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))

	if _, ok := kugouKnownArtistFix(kugouMusicBundleID, "爱情慢慢来"); ok {
		t.Error("还没判定就给出了纠正 —— 那会把没被污染的播放器的封面核对也改坏")
	}
	kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195)

	got, ok := kugouKnownArtistFix(kugouMusicBundleID, "爱情慢慢来")
	if !ok || got != "Stake" {
		t.Errorf("= (%q, %v),应给出主路径此刻用的那个署名", got, ok)
	}
	// 查询自己不判定:连查几次都不该把状态机推向别处(它一首歌只被调一次,看不到署名在变)。
	for i := 0; i < 3; i++ {
		if a, _ := kugouKnownArtistFix(kugouMusicBundleID, "爱情慢慢来"); a != "Stake" {
			t.Fatalf("第 %d 次查询给出了 %q", i+1, a)
		}
	}
	if _, ok := kugouKnownArtistFix(kugouMusicBundleID, "别的歌"); ok {
		t.Error("曲名对不上也给出了纠正")
	}
	if _, ok := kugouKnownArtistFix(qqMusicBundleID, "爱情慢慢来"); ok {
		t.Error("别的播放器也给出了纠正")
	}
}

// 本地那份说署名就长这样时,一个字都不许动 —— 原生 macOS 版走的正是这条路,
// 判错的代价是把一个正确的多人署名换成主歌手、悄悄丢掉合唱者。
func TestKugouFixedArtistTrustsMatchingLocalCredit(t *testing.T) {
	for _, reported := range []string{
		"Stake",      // 主歌手,跟 singerName 逐字一致
		"Stake、TwoP", // 全署名,跟 musicName 的前缀一致
		"stake",      // 只差大小写,loosenEnrichKey 折得平
	} {
		resetKugouLyricArtist(t)
		useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))
		if got, ok := kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", reported, 195); ok {
			t.Errorf("播放器报 %q 被判成了污染,换成了 %q", reported, got)
		}
	}
}

// 本地那份读不到(没授权 / 没装 / 还停在上一首)时,照旧退回结构判据 —— 等它换第二个署名。
func TestKugouFixedArtistFallsBackToStructuralEvidence(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, filepath.Join(t.TempDir(), "不存在.plist"))

	if _, ok := kugouFixedArtist(kugouMusicBundleID, "泪海", "爱已不能动", 298); ok {
		t.Error("本地那份读不到,只见过一个署名就判定了")
	}
	got, ok := kugouFixedArtist(kugouMusicBundleID, "泪海", "还有什么值得我心痛", 298)
	if !ok || got != "爱已不能动" {
		t.Errorf("= (%q, %v),换了第二个署名之后应判定成立并退回第一次见到的那个", got, ok)
	}
}

// 交叉验证是弱证据:它依赖本地那份和播放器报的写法能对上,折不平的写法差异会让它误判。
// 所以它只管当前这一首,**不**升级成"这个播放器一直这样" —— 否则一次误判会扩散到之后
// 每一首歌的第一拍。
func TestKugouFixedArtistKeepsLocalEvidenceScopedToOneTrack(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))

	got, ok := kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195)
	if !ok || got != "Stake" {
		t.Fatalf("前置条件没成立: (%q, %v)", got, ok)
	}
	if kugouArtistPoisonConfirmed {
		t.Error("只凭本地那份就把整个播放器坐实了 —— 一次写法误判会扩散到之后每一首歌")
	}
	// 换下一首:本地那份的歌名对不上(它还记着上一首),没有播放器级结论兜底,
	// 就该什么都不做、等证据。
	if a, ok := kugouFixedArtist(kugouMusicBundleID, "另一首歌", "某位歌手", 200); ok {
		t.Errorf("换歌后凭空纠正成了 %q", a)
	}
}

// 结构证据是强证据:亲眼看到同一首歌里署名换了个值,正常播放器做不出来,值得升级成
// 播放器级结论 —— 后面每首歌开头那十来秒才救得回来。
func TestKugouFixedArtistConfirmsPlayerOnStructuralEvidence(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, filepath.Join(t.TempDir(), "不存在.plist"))

	kugouFixedArtist(kugouMusicBundleID, "泪海", "爱已不能动", 298)
	if kugouArtistPoisonConfirmed {
		t.Fatal("只见过一个署名就坐实了")
	}
	kugouFixedArtist(kugouMusicBundleID, "泪海", "还有什么值得我心痛", 298)
	if !kugouArtistPoisonConfirmed {
		t.Error("署名在同一首歌里变过了,仍然没升级成播放器级结论")
	}
	// 坐实之后,下一首第一拍就按被污染处理。
	got, ok := kugouFixedArtist(kugouMusicBundleID, "另一首歌", "开场就是歌词", 200)
	if !ok || got != "开场就是歌词" {
		t.Errorf("= (%q, %v),坐实之后新曲目第一拍就该判定(本地读不到时退回第一次见到的署名)", got, ok)
	}
}

// 播放器报的多人署名是对的,不该被本地那份的主歌手削掉合唱者。
// 实测:media-control 报 `少司命、新乐尘符`,而 plist 的 singerName 只有 `少司命`。
func TestKugouFixedArtistKeepsFullCreditFromPlayer(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "少司命、新乐尘符 - 不归人", "少司命"))

	// 开播第一拍报的是全署名(正确),跟本地那份的 musicName 前缀对得上 —— 不判定。
	if _, ok := kugouFixedArtist(kugouMusicBundleID, "不归人", "少司命、新乐尘符", 200); ok {
		t.Fatal("跟本地那份对得上的署名被判成了污染")
	}
	// 第二拍被歌词顶掉,判定成立 —— 这时该换回**第一拍那个全署名**,不是 singerName。
	got, ok := kugouFixedArtist(kugouMusicBundleID, "不归人", "你说任由它弱水三千", 200)
	if !ok || got != "少司命、新乐尘符" {
		t.Errorf("= (%q, %v),应保住播放器报的全署名,而不是削成主歌手「少司命」", got, ok)
	}
}

// 第一拍就已经是歌词时没得保,退回本地那份的主歌手。
func TestKugouFixedArtistFallsBackToSingerNameWhenFirstIsDirty(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))

	got, ok := kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195)
	if !ok || got != "Stake" {
		t.Errorf("= (%q, %v),第一拍就是歌词时应退回 singerName", got, ok)
	}
}

// collector 重启时:上一个进程记的**曲目**要清掉(陈旧记录正好能撞上同一首歌),但
// "哪个播放器不可信"要留下 —— 否则重启后的第一首歌里 App 又不知道该把署名剔出曲目身份,
// 身份抖几次、封面照样被丢(见 MediaControlSnapshot.identityKey)。
func TestSetPlayerArtistFixPathKeepsPlayerVerdictAcrossRestart(t *testing.T) {
	resetKugouLyricArtist(t)
	path := filepath.Join(t.TempDir(), "fix.json")
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })
	publishPlayerArtistFix(kugouMusicBundleID, "爱情慢慢来", "Stake", true)

	setPlayerArtistFixPath(path) // 相当于进程重启
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("重启后状态文件整个没了: %v", err)
	}
	var got playerArtistFixState
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if !got.Unreliable || got.Bundle != kugouMusicBundleID {
		t.Errorf("播放器级结论没留住: %+v", got)
	}
	if got.Title != "" || got.Artist != "" {
		t.Errorf("上一个进程的曲目记录没清掉: %+v", got)
	}
}

// 没有播放器级结论的陈旧文件照旧整个删掉,别留个空壳。
func TestSetPlayerArtistFixPathDropsFileWithoutVerdict(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fix.json")
	if err := os.WriteFile(path, []byte(`{"bundle":"x","title":"y","artist":"z"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })
	if _, err := os.Stat(path); err == nil {
		t.Error("没有 unreliable 标记的陈旧文件应当直接删掉")
	}
}

// collector 重启后,文件里留下的播放器级结论要一并恢复进判定:App 读到 unreliable 就会等这一首
// 的纠正、没到之前清空歌手位,署名本来就干净的歌也必须拿到一条纠正。
func TestSetPlayerArtistFixPathRestoresKugouVerdict(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "石岩 - 蜉蝣志", "石岩"))
	path := filepath.Join(t.TempDir(), "fix.json")
	if err := os.WriteFile(path, []byte(`{"bundle":"`+kugouMusicBundleID+`","unreliable":true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setPlayerArtistFixPath(path) // 相当于进程重启
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	kugouLyricArtistMu.Lock()
	confirmed := kugouArtistPoisonConfirmed
	kugouLyricArtistMu.Unlock()
	if !confirmed {
		t.Fatal("文件里的播放器级结论没恢复进判定")
	}
	got, ok := kugouFixedArtist(kugouMusicBundleID, "蜉蝣志", "石岩", 341)
	if !ok || got != "石岩" {
		t.Fatalf("= (%q, %v),干净的歌也该给出纠正", got, ok)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var st playerArtistFixState
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatal(err)
	}
	if st.Title != "蜉蝣志" || st.Artist != "石岩" || !st.Unreliable {
		t.Errorf("没发布这一首的纠正,App 会一直清空歌手位: %+v", st)
	}
}

// 别的播放器留下的结论不该把酷狗的判定置上。
func TestSetPlayerArtistFixPathRestoresOnlyKugou(t *testing.T) {
	resetKugouLyricArtist(t)
	path := filepath.Join(t.TempDir(), "fix.json")
	if err := os.WriteFile(path, []byte(`{"bundle":"com.example.other","unreliable":true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })
	kugouLyricArtistMu.Lock()
	defer kugouLyricArtistMu.Unlock()
	if kugouArtistPoisonConfirmed {
		t.Error("别的播放器的结论不该恢复成酷狗的判定")
	}
}

// 只凭本地那份交叉验证(弱证据)判定的这一首:发布纠正,但不写播放器级结论。
func TestKugouFixedArtistWeakEvidenceIsNotPlayerLevel(t *testing.T) {
	resetKugouLyricArtist(t)
	useKugouNowPlaying(t, kugouNowPlayingPlist(t, "队列里的歌", "Stake、TwoP - 爱情慢慢来", "Stake"))
	path := filepath.Join(t.TempDir(), "fix.json")
	setPlayerArtistFixPath(path)
	t.Cleanup(func() { setPlayerArtistFixPath("") })

	if _, ok := kugouFixedArtist(kugouMusicBundleID, "爱情慢慢来", "真的并不是我太过见外", 195); !ok {
		t.Fatal("前提:本地那份对不上时第一拍就该纠正")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var st playerArtistFixState
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatal(err)
	}
	if st.Artist != "Stake" || st.Unreliable {
		t.Errorf("弱证据只该管这一首: %+v", st)
	}
}
