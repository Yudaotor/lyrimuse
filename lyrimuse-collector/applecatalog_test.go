package main

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
)

// 真实数据(2026-08-22 实测 iTunes lookup):
//
//	id=1485220321 → 「枫+退后+搁浅 (Live)」/ artistName=「南拳妈妈弹头」/
//	                collectionArtistName=「周杰伦」/ 专辑「周杰伦地表最强世界巡回演唱会 (Live)」/ 119.213s
//	id=1485220325 → 「印地安老斑鸠 (Live)」/ artistName=「周杰伦」/ collectionArtistName 缺省 / 208.293s
const (
	anchorMedleyID = int64(1485220321)
	anchorNextID   = int64(1485220325)
	anchorAlbum    = "周杰伦地表最强世界巡回演唱会 (Live)"
)

func seedAnchorCache(t *testing.T) {
	t.Helper()
	appleCatalogMu.Lock()
	defer appleCatalogMu.Unlock()
	appleCatalogPath = "" // 确保测试永不落盘
	appleCatalogCache = map[string]appleCatalogTrack{
		fmt.Sprint(anchorMedleyID): {
			TrackName: "枫+退后+搁浅 (Live)", ArtistName: "南拳妈妈弹头",
			AlbumArtist: "周杰伦", AlbumName: "周杰伦地表最强世界巡回演唱会 (Live)",
			AlbumID: 1485220306, DurationSecs: 119.213,
		},
		fmt.Sprint(anchorNextID): {
			TrackName: "印地安老斑鸠 (Live)", ArtistName: "周杰伦",
			AlbumName: "周杰伦地表最强世界巡回演唱会 (Live)",
			AlbumID:   1485220306, DurationSecs: 208.293,
		},
	}
	appleCatalogByTrack = map[string]appleCatalogTrack{}
	appleCatalogInflight = map[int64]bool{}
	appleCatalogMisses = map[int64]int{}
}

// TestAppleCatalogPlausibleID 钉住"什么样的 uniqueIdentifier 才值得拿去 lookup"。
// 用的是实测值:本地导入曲目拿到的是负数(直接 lookup 是 HTTP 400),取绝对值是 0 results。
func TestAppleCatalogPlausibleID(t *testing.T) {
	cases := []struct {
		id   int64
		want bool
		why  string
	}{
		{1485220321, true, "真实目录 ID"},
		{1485220325, true, "真实目录 ID"},
		{-3446272063698972557, false, "本地导入曲目的持久 ID(实测负数,lookup 直接 400)"},
		{3446272063698972557, false, "上面那个取绝对值——防'顺手 abs 一下'的错误实现"},
		{0, false, "字段缺省"},
		{-1, false, "负数"},
	}
	for _, c := range cases {
		if got := appleCatalogPlausibleID(c.id); got != c.want {
			t.Errorf("appleCatalogPlausibleID(%d) = %v, want %v —— %s", c.id, got, c.want, c.why)
		}
	}
}

func TestAppleCatalogAnchorGuards(t *testing.T) {
	seedAnchorCache(t)
	// 基准:bundle/ID/标题/专辑全对 → 拿到锚点,且时长是权威值
	got, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", anchorAlbum)
	if !ok {
		t.Fatalf("基准情形应拿到锚点")
	}
	if got.DurationSecs != 119.213 {
		t.Errorf("权威时长 = %v, want 119.213", got.DurationSecs)
	}
	if got.AlbumArtist != "周杰伦" {
		t.Errorf("专辑署名 = %q, want 周杰伦", got.AlbumArtist)
	}

	// 别的播放器:即便 ID 恰好是个真实目录 ID 也不认
	for _, b := range []string{qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID, ""} {
		if _, ok := appleCatalogAnchor(b, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", anchorAlbum); ok {
			t.Errorf("bundleID=%q 不该拿到 Apple 目录锚点", b)
		}
	}

	// ⚠️ 最重要的一条:media-control 的"脏快照"——标题是当前曲目、别的字段来自下一首。
	// 拿下一首的 ID 配当前曲目的标题,自校验必须挡住,不然会用错的时长去打分。
	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorNextID, 0, "枫+退后+搁浅 (Live)", anchorAlbum); ok {
		t.Errorf("曲目名对不上时不该拿到锚点(这正是脏快照的形态)")
	}

	// 专辑对不上
	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", "叶惠美"); ok {
		t.Errorf("专辑名对不上时不该拿到锚点")
	}
	// 本地没有专辑标签 → 只校曲目名,照样成立
	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", ""); !ok {
		t.Errorf("本地专辑标签为空时应只校曲目名并通过")
	}
	// 标题为空 / ID 不合理
	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "", anchorAlbum); ok {
		t.Errorf("本地标题为空时不该拿到锚点")
	}
	if _, ok := appleCatalogAnchor(appleMusicBundleID, -3446272063698972557, 0, "枫+退后+搁浅 (Live)", anchorAlbum); ok {
		t.Errorf("本地持久 ID(负数)不该拿到锚点")
	}
}

// TestAppleCatalogAnchorCacheMissDoesNotBlock:缓存没命中时当轮必须返回 false
// (poll 主循环不能等一次对外 HTTP)。把 miss 计数先顶满,避免这个测试真发请求。
func TestAppleCatalogAnchorCacheMissDoesNotBlock(t *testing.T) {
	seedAnchorCache(t)
	const unknown = int64(999999999)
	appleCatalogMu.Lock()
	appleCatalogMisses[unknown] = appleCatalogMaxMisses
	appleCatalogMu.Unlock()
	if _, ok := appleCatalogAnchor(appleMusicBundleID, unknown, 0, "某首歌", "某专辑"); ok {
		t.Errorf("缓存没命中时不该返回锚点")
	}
}

func TestAppleCatalogSearchIdentities(t *testing.T) {
	seedAnchorCache(t)
	// 索引由 appleCatalogAnchor 校验通过时填,所以先走一遍锚点
	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", anchorAlbum); !ok {
		t.Fatalf("准备阶段:锚点应成立")
	}
	// 本地署名是「南拳妈妈弹头」→ 专辑署名「周杰伦」是新身份;曲目署名跟本地一样,去掉
	got := appleCatalogSearchIdentities("南拳妈妈弹头", "枫+退后+搁浅 (Live)", anchorAlbum)
	if !reflect.DeepEqual(got, []string{"周杰伦"}) {
		t.Errorf("appleCatalogSearchIdentities = %#v, want [周杰伦]", got)
	}
	// 没有锚点的曲目 → 空
	if got := appleCatalogSearchIdentities("周杰伦", "根本没播过的歌", "某专辑"); got != nil {
		t.Errorf("没有锚点时应返回 nil,得到 %#v", got)
	}
	// 专辑署名缺省(曲目署名==专辑主人)的那条:本地署名一致 → 没有新身份可试
	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorNextID, 0, "印地安老斑鸠 (Live)", anchorAlbum); !ok {
		t.Fatalf("准备阶段:第二条锚点应成立")
	}
	if got := appleCatalogSearchIdentities("周杰伦", "印地安老斑鸠 (Live)", anchorAlbum); got != nil {
		t.Errorf("署名与本地一致时应返回 nil,得到 %#v", got)
	}
}

// TestAppleStorefrontArtistIdentitiesLive 是真实网络集成测试(2026-08-30 加,方大同
// 《Lovers Policy》案,见 appleStorefrontArtistIdentities 头注)——直接打真实 iTunes
// Search API,不 mock。跟同包内 TestRetryArtistIdentitiesGenericMusicBrainzReverseDirection
// 同一个前提:这类"通用查询是否真的通用"的验证,意义就在于打真实的第三方服务,mock 掉
// 就只是在验证自己写的 mock 数据,证明不了任何事。可能偶发因为该服务限速/网络抖动失败,
// 跟同包其它真实网络测试(TestRetryArtistIdentitiesUsesMusicBrainzName 等)接受的是
// 同一类风险。
func TestAppleStorefrontArtistIdentitiesLive(t *testing.T) {
	got := appleStorefrontArtistIdentities(context.Background(), "方大同", "Lovers Policy", "15")
	found := false
	for _, s := range got {
		if normLoose(s) == normLoose("Khalil Fong") {
			found = true
		}
	}
	if !found {
		t.Fatalf("应该能从 US 商店拿到 Khalil Fong 这个身份, got %v", got)
	}
	if album := ""; appleStorefrontArtistIdentities(context.Background(), "方大同", "Lovers Policy", album) != nil {
		t.Errorf("没有专辑名时应返回 nil(这条技巧靠专辑名精确定位)")
	}
}

// 查空**不落盘**、查到才落盘——跟 mbPrimaryNameCache 同一条设计取舍(见
// appleStorefrontArtistCache 声明处注释),这里镜像 TestMBPrimaryNameCachePersistsOnlyHits
// 的写法单独锁定一遍。
func TestAppleStorefrontArtistCachePersistsOnlyHits(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/storefront.json"

	savedCache, savedPath, savedDirty := appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty
	defer func() {
		appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty = savedCache, savedPath, savedDirty
	}()

	appleStorefrontArtistPath = path
	appleStorefrontArtistCache = map[string][]string{
		"方大同|15":   {"Khalil Fong"}, // 查到了
		"某个没查到的|专辑": nil,           // 查空(可能只是网络抖动)
	}
	appleStorefrontArtistDirty = true
	saveAppleStorefrontArtistCache()

	appleStorefrontArtistCache = map[string][]string{}
	loadAppleStorefrontArtistCache(path)
	if got := appleStorefrontArtistCache["方大同|15"]; !reflect.DeepEqual(got, []string{"Khalil Fong"}) {
		t.Errorf("查到的那条没被持久化:got %v", got)
	}
	if _, ok := appleStorefrontArtistCache["某个没查到的|专辑"]; ok {
		t.Error("查空的那条落盘了 —— 一次偶发网络抖动会被永久钉死")
	}

	// 没有路径时(单测/一次性子命令)不写任何文件,也不该 panic。
	appleStorefrontArtistPath = ""
	appleStorefrontArtistDirty = true
	saveAppleStorefrontArtistCache()
}

func TestDedupeArtistIdentities(t *testing.T) {
	got := dedupeArtistIdentities(
		[]string{"周杰伦", ""},
		[]string{"Jay Chou", "周杰伦", "  周杰伦  "}, // 后两个 normLoose 后与第一组重复
		nil,
	)
	if !reflect.DeepEqual(got, []string{"周杰伦", "Jay Chou"}) {
		t.Errorf("dedupeArtistIdentities = %#v, want [周杰伦 Jay Chou]", got)
	}
	if got := dedupeArtistIdentities(nil, nil); got != nil {
		t.Errorf("全空应返回 nil,得到 %#v", got)
	}
}

// TestMediaControlRawStateParsesUniqueIdentifier 用**真实的 media-control 输出**
// (2026-08-22 抓的,只去掉了体积巨大的 artworkData/artworkMimeType)钉住这个字段真的解出来了。
//
// 为什么值得有这个测试:JSON tag 拼错是**静默**失败——字段恒为零值,
// appleCatalogPlausibleID(0) 直接 false,整条 Apple 目录锚点会安静地永不生效,
// 而 build/vet/其它测试一个都不会响。
func TestMediaControlRawStateParsesUniqueIdentifier(t *testing.T) {
	// 本地导入曲目:uniqueIdentifier 是任意 64 位持久 ID(这条是正数、但远超目录 ID 量级)
	const localImport = `{"album":"BLOOD ON THE DANCE FLOOR/ HIStory In The Mix",` +
		`"artist":"Michael Jackson","bundleIdentifier":"com.apple.Music",` +
		`"duration":336.1733229166667,"elapsedTime":0.024432084,"playing":true,` +
		`"playbackRate":1,"timestamp":"2026-08-22T09:56:13Z","title":"Is It Scary",` +
		`"trackNumber":5,"uniqueIdentifier":2764576100379992737}`
	var raw mediaControlRawState
	if err := json.Unmarshal([]byte(localImport), &raw); err != nil {
		t.Fatalf("解析真实 media-control 输出失败: %v", err)
	}
	if raw.UniqueIdentifier != 2764576100379992737 {
		t.Errorf("UniqueIdentifier = %d, want 2764576100379992737(JSON tag 是不是拼错了?)", raw.UniqueIdentifier)
	}
	// 这条**必须**被上界守卫挡掉:否则每首本地导入曲目都会白发一次 iTunes 请求
	if appleCatalogPlausibleID(raw.UniqueIdentifier) {
		t.Errorf("本地导入曲目的持久 ID %d 不该被当成目录 ID", raw.UniqueIdentifier)
	}
	if raw.Duration != 336.1733229166667 || raw.Title != "Is It Scary" {
		t.Errorf("同一份 payload 的其它字段也该照常解出来,得到 title=%q duration=%v", raw.Title, raw.Duration)
	}

	// Apple Music 目录曲目:同一个字段位置放的是目录 ID(实测 1485220325 = 演唱会专辑第 18 首)
	const catalog = `{"album":"周杰伦地表最强世界巡回演唱会 (Live)","artist":"周杰伦",` +
		`"bundleIdentifier":"com.apple.Music","duration":208.293,"playing":true,` +
		`"title":"印地安老斑鸠 (Live)","uniqueIdentifier":1485220325}`
	var raw2 mediaControlRawState
	if err := json.Unmarshal([]byte(catalog), &raw2); err != nil {
		t.Fatalf("解析目录曲目 payload 失败: %v", err)
	}
	if raw2.UniqueIdentifier != 1485220325 || !appleCatalogPlausibleID(raw2.UniqueIdentifier) {
		t.Errorf("目录曲目 ID 应解出 1485220325 且通过 plausible 闸,得到 %d", raw2.UniqueIdentifier)
	}
}

// TestAppleCatalogAnchorRejectsSiblingTracks 是 2026-08-22 对抗性复核抓到的洞的回归测试。
//
// 原来的自校验用 lyricTitleAccepted,而它的**第二档**是「双方各自 stripParens 之后判相等」——
// 于是同一张专辑上的括号兄弟轨互相判等,专辑名又必然相同,锚点照样"成立",把差 40~47% 的
// 时长当成权威值喂给下游。这直接推翻了原注释里那句「曲目名对不上 → 锚点作废、不会更差」:
// 只要下一首是同专辑的括号兄弟轨,曲目名就是"对得上"的。
//
// 下面三组全部来自用户自己的资料库(AppleScript 读出来的真实曲目 + iTunes lookup 的真实时长)。
func TestAppleCatalogAnchorRejectsSiblingTracks(t *testing.T) {
	const albumXscape = "XSCAPE (Deluxe)"
	appleCatalogMu.Lock()
	appleCatalogPath = ""
	appleCatalogCache = map[string]appleCatalogTrack{
		// #16 括号兄弟轨
		"850697814": {TrackName: "Xscape (Original Version)", AlbumName: albumXscape, TrackNumber: 16, DurationSecs: 344.442},
		// #17 与 #1 **完全同名**(连括号都不用剥)
		"850697815": {TrackName: "Love Never Felt So Good", AlbumName: albumXscape, TrackNumber: 17, DurationSecs: 245.671},
		// #1 本尊
		"850697799": {TrackName: "Love Never Felt So Good", AlbumName: albumXscape, TrackNumber: 1, DurationSecs: 234.911},
	}
	appleCatalogByTrack = map[string]appleCatalogTrack{}
	appleCatalogInflight = map[int64]bool{}
	appleCatalogMisses = map[int64]int{}
	appleCatalogMu.Unlock()

	// ① 括号兄弟轨:本地在放 #8「Xscape」(244.915s),ID 指向 #16「Xscape (Original Version)」
	//    (344.442s)。逐字同名判定必须挡住 —— 否则会用 344.442 去覆盖 244.915(差 99.5s)。
	if _, ok := appleCatalogAnchor(appleMusicBundleID, 850697814, 8, "Xscape", albumXscape); ok {
		t.Errorf("「Xscape」不该被「Xscape (Original Version)」的锚点认领(差 99.5s)")
	}
	// ② 完全同名的兄弟轨:曲目名一模一样、专辑也一样,只有序号不同 → 靠音轨号挡住
	if _, ok := appleCatalogAnchor(appleMusicBundleID, 850697815, 1, "Love Never Felt So Good", albumXscape); ok {
		t.Errorf("本地是 #1、ID 指向 #17,序号对不上就该作废(234.911 vs 245.671)")
	}
	// ③ 正主:序号也对得上 → 成立
	got, ok := appleCatalogAnchor(appleMusicBundleID, 850697799, 1, "Love Never Felt So Good", albumXscape)
	if !ok || got.DurationSecs != 234.911 {
		t.Errorf("序号对得上的正主应成立,得到 ok=%v dur=%v", ok, got.DurationSecs)
	}
	// ④ 本地拿不到序号(0)时不把"缺证据"当"反证据":完全同名那一对退回放行
	//    ——这是刻意保留的残余风险,同名兄弟轨的时长差通常只有几个百分点(实测 4.6%),
	//    远小于括号兄弟轨那 40%+,而收紧成"必须有序号"会让没有序号的曲目整条失效。
	if _, ok := appleCatalogAnchor(appleMusicBundleID, 850697815, 0, "Love Never Felt So Good", albumXscape); !ok {
		t.Errorf("本地没有序号时应退回只校曲目名+专辑名")
	}
}
