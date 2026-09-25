package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 造一份跟真实 PlayingList.archive 同构的 NSKeyedArchiver 归档。
//
// 写的是 **XML plist** 而不是 bplist:qqUpcoming 内部要 exec `plutil -convert xml1`,
// 而 plutil 对 XML 输入是恒等转换 —— 于是不必在测试里造二进制,走的仍是完整那条路
// (exec → 解析 → UID 解引用 → 提取)。
type qqArchive struct{ objects []string }

func (a *qqArchive) add(frag string) int {
	a.objects = append(a.objects, frag)
	return len(a.objects) - 1
}

func (a *qqArchive) str(s string) int {
	return a.add("<string>" + s + "</string>")
}

func qqUID(i int) string {
	return fmt.Sprintf("<dict><key>CF$UID</key><integer>%d</integer></dict>", i)
}

type testQQSong struct {
	title, album string
	singers      []string // 空 = 不写 singerList,只写 singerInfo(覆盖兜底那一支)
	singerInfo   string
	duration     float64
	albumMid     string
}

func writeTestQQArchive(t *testing.T, lastIndex int, songs []testQQSong) string {
	t.Helper()
	a := &qqArchive{}
	a.add("<string>$null</string>") // 0:归档惯例,第一个对象是 $null

	songUIDs := make([]int, 0, len(songs))
	for _, s := range songs {
		var b strings.Builder
		b.WriteString("<dict>")
		fmt.Fprintf(&b, "<key>songName</key>%s", qqUID(a.str(s.title)))
		fmt.Fprintf(&b, "<key>song_Duration</key><real>%v</real>", s.duration)
		// albumInfo 是个被引用的对象,跟真实归档一样。
		albumFields := fmt.Sprintf("<key>name</key>%s", qqUID(a.str(s.album)))
		if s.albumMid != "" {
			albumFields += fmt.Sprintf("<key>albumMid</key>%s", qqUID(a.str(s.albumMid)))
		}
		albumObj := a.add("<dict>" + albumFields + "</dict>")
		fmt.Fprintf(&b, "<key>albumInfo</key>%s", qqUID(albumObj))
		if len(s.singers) > 0 {
			members := make([]string, 0, len(s.singers))
			for _, n := range s.singers {
				members = append(members, qqUID(a.add(fmt.Sprintf("<dict><key>name</key>%s</dict>", qqUID(a.str(n))))))
			}
			listObj := a.add("<dict><key>NS.objects</key><array>" + strings.Join(members, "") + "</array></dict>")
			fmt.Fprintf(&b, "<key>singerList</key>%s", qqUID(listObj))
		}
		if s.singerInfo != "" {
			infoObj := a.add(fmt.Sprintf("<dict><key>name</key>%s</dict>", qqUID(a.str(s.singerInfo))))
			fmt.Fprintf(&b, "<key>singerInfo</key>%s", qqUID(infoObj))
		}
		b.WriteString("</dict>")
		songUIDs = append(songUIDs, a.add(b.String()))
	}

	refs := make([]string, 0, len(songUIDs))
	for _, u := range songUIDs {
		refs = append(refs, qqUID(u))
	}
	listData := a.add("<dict><key>NS.objects</key><array>" + strings.Join(refs, "") + "</array></dict>")
	playingList := a.add(fmt.Sprintf("<dict><key>ListData</key>%s</dict>", qqUID(listData)))

	doc := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>$archiver</key><string>NSKeyedArchiver</string>
<key>$objects</key><array>` + strings.Join(a.objects, "") + `</array>
<key>$top</key><dict>` +
		fmt.Sprintf("<key>LastPlayingIndex</key><integer>%d</integer>", lastIndex) +
		fmt.Sprintf("<key>PlayingList</key>%s", qqUID(playingList)) +
		`</dict>
<key>$version</key><integer>100000</integer>
</dict></plist>`

	path := filepath.Join(t.TempDir(), "PlayingList.archive")
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatalf("写测试归档: %v", err)
	}
	old := qqUpcomingOverride
	qqUpcomingOverride = path
	qqPlayOrderMu.Lock()
	qqPlayOrderLast = queueOrder{}
	qqPlayOrderMu.Unlock()
	t.Cleanup(func() {
		qqUpcomingOverride = old
		qqPlayOrderMu.Lock()
		qqPlayOrderLast = queueOrder{}
		qqPlayOrderMu.Unlock()
	})
	return path
}

func testQQSongs(n int) []testQQSong {
	songs := make([]testQQSong, n)
	for i := range songs {
		songs[i] = testQQSong{title: fmt.Sprintf("第%d首", i), album: "专辑", singers: []string{"甲"}, duration: 100}
	}
	return songs
}

// 归档只在开播时写:换过歌之后 LastPlayingIndex 还停在开播那一首,当前这首要在整份列表里找。
func TestQQUpcomingFindsCurrentWhenIndexIsStale(t *testing.T) {
	writeTestQQArchive(t, 0, testQQSongs(6))
	got, ok := qqUpcoming("甲", "第3首", 2)
	if !ok || len(got) != 2 || got[0].title != "第4首" || got[1].title != "第5首" {
		t.Fatalf("该从第3首之后往后取,得到 ok=%v %+v", ok, got)
	}
}

// 顺序播放:相邻两次换歌正好是下一位,继续按列表往后取;同一首重复触发不算证据。
func TestQQUpcomingKeepsListOrderWhenSequential(t *testing.T) {
	writeTestQQArchive(t, 0, testQQSongs(8))
	for _, cur := range []string{"第0首", "第1首", "第1首", "第2首"} {
		if _, ok := qqUpcoming("甲", cur, 3); !ok {
			t.Fatalf("顺序播放到 %s 时该取得到", cur)
		}
	}
}

// 随机播放(实测 0 → 5 → 2 → 24):位置跳着走就按随机处理,之后同一首重复触发仍按随机;
// 又连续走了一步就重新当顺序。换了一份列表从头攒证据。
func TestQQUpcomingDetectsShuffleFromJumps(t *testing.T) {
	writeTestQQArchive(t, 0, testQQSongs(20))
	sequential := func(cur string) bool {
		t.Helper()
		got, ok := qqUpcoming("甲", cur, 5)
		if !ok {
			t.Fatalf("%s: 该取得到", cur)
		}
		return len(got) == 5 // 顺序播放只取 5 首;随机时交出整份列表(19 首)
	}
	if !sequential("第0首") {
		t.Fatal("开播第一首还没有证据,按顺序取 5 首")
	}
	if sequential("第5首") {
		t.Fatal("从第0首跳到第5首该当随机")
	}
	if sequential("第5首") {
		t.Fatal("同一首重复触发不改结论,仍按随机")
	}
	if sequential("第2首") {
		t.Fatal("继续跳着走,仍按随机")
	}
	if !sequential("第3首") {
		t.Fatal("又连续走了一步(用户切回顺序播放),该重新按列表取 5 首")
	}
	if sequential("第9首") {
		t.Fatal("再跳一次,回到随机")
	}
	qqPlayOrderMu.Lock()
	shuffledState := qqPlayOrderLast
	qqPlayOrderMu.Unlock()
	writeTestQQArchive(t, 0, testQQSongs(20))
	qqPlayOrderMu.Lock()
	qqPlayOrderLast = shuffledState // 带着上一份列表的随机结论
	qqPlayOrderMu.Unlock()
	if !sequential("第7首") {
		t.Fatal("换了一份列表,之前的随机结论不该带过来")
	}
}

// 随机 + 小列表:除了当前这首,整份列表都交出去(从当前往后,到末尾接回开头),不受 n 限制。
func TestQQUpcomingShuffleOffersWholeSmallList(t *testing.T) {
	writeTestQQArchive(t, 0, testQQSongs(14))
	qqUpcoming("甲", "第7首", 5)
	got, ok := qqUpcoming("甲", "第2首", 5) // 7 → 2:随机
	if !ok || len(got) != 13 {
		t.Fatalf("该交出其余 13 首,得到 ok=%v %d 首", ok, len(got))
	}
	if got[0].title != "第3首" || got[len(got)-1].title != "第1首" {
		t.Errorf("顺序该是从当前往后、接回开头,得到首尾 %s … %s", got[0].title, got[len(got)-1].title)
	}
	for _, tr := range got {
		if tr.title == "第2首" {
			t.Error("当前这首不该在里面")
		}
	}
}

// 随机 + 大列表:每换一首只挑 queueShuffleBatch 首还没解析过的;全都解析过了也算处理过(ok=true)。
func TestQQUpcomingShuffleRollsThroughLargeList(t *testing.T) {
	writeTestQQArchive(t, 0, testQQSongs(queueShuffleWholeListMax+10))
	enrichMu.Lock()
	oldCache, oldInflight := enrichCache, enrichInflight
	enrichCache, enrichInflight = map[string]enrichEntry{}, map[string]bool{}
	for _, n := range []int{3, 4} { // 当前位置之后的头两首已经解析过
		enrichCache[enrichKey("甲", fmt.Sprintf("第%d首", n), "专辑")] = enrichEntry{}
	}
	enrichMu.Unlock()
	t.Cleanup(func() { enrichMu.Lock(); enrichCache, enrichInflight = oldCache, oldInflight; enrichMu.Unlock() })

	qqUpcoming("甲", "第30首", 5)
	got, ok := qqUpcoming("甲", "第2首", 5) // 30 → 2:随机
	if !ok || len(got) != queueShuffleBatch {
		t.Fatalf("大列表该只交 %d 首,得到 ok=%v %d 首", queueShuffleBatch, ok, len(got))
	}
	if got[0].title != "第5首" || got[len(got)-1].title != "第9首" {
		t.Errorf("该跳过已解析的第3、4首,从第5首起取,得到 %s … %s", got[0].title, got[len(got)-1].title)
	}

	enrichMu.Lock()
	for i := 0; i < queueShuffleWholeListMax+10; i++ {
		enrichCache[enrichKey("甲", fmt.Sprintf("第%d首", i), "专辑")] = enrichEntry{}
	}
	enrichMu.Unlock()
	got, ok = qqUpcoming("甲", "第11首", 5)
	if !ok || len(got) != 0 {
		t.Errorf("全都解析过:该返回 ok=true、空列表(不再退回同专辑预取),得到 ok=%v %d 首", ok, len(got))
	}
}

func TestQQUpcomingFollowsLastPlayingIndex(t *testing.T) {
	writeTestQQArchive(t, 1, []testQQSong{
		{title: "第一首", album: "甲专辑", singers: []string{"甲"}, duration: 100},
		{title: "第二首", album: "乙专辑", singers: []string{"乙"}, duration: 200},
		{title: "第三首", album: "丙专辑", singers: []string{"丙"}, duration: 300},
		{title: "第四首", album: "丁专辑", singers: []string{"丁"}, duration: 400},
	})
	got, ok := qqUpcoming("乙", "第二首", 5)
	if !ok {
		t.Fatalf("LastPlayingIndex 指的正是当前这首,该取得到")
	}
	if len(got) != 2 || got[0].title != "第三首" || got[1].title != "第四首" {
		t.Fatalf("取到 %+v,期望第三首、第四首(只往后取,不含当前这首)", got)
	}
	if got[0].album != "丙专辑" {
		t.Errorf("专辑名 %q —— 队列里每首的专辑各不相同,不能统一写成当前这首的", got[0].album)
	}
	if got[0].duration != 300 {
		t.Errorf("时长 %v,期望 300 秒 —— song_Duration 本来就是秒,别当毫秒除一遍", got[0].duration)
	}
}

func TestQQUpcomingRejectsStaleArchive(t *testing.T) {
	// 这份文件停在上一次播放 —— 用户切去别的播放器听、或刚启动还没播,都是常态。
	// 光信 LastPlayingIndex 不核对,就会拿一批根本不会播的歌去占解析带宽。
	writeTestQQArchive(t, 0, []testQQSong{
		{title: "旧的", album: "甲", singers: []string{"甲"}, duration: 100},
		{title: "不该取到", album: "乙", singers: []string{"乙"}, duration: 200},
	})
	if got, ok := qqUpcoming("丙", "此刻在播的别的歌", 5); ok {
		t.Errorf("归档停在别的歌上,该退回兜底,却返回了 %+v", got)
	}
}

func TestQQUpcomingJoinsEverySinger(t *testing.T) {
	// 拼全部署名的理由同汽水那条:只取主歌手的话,loosenEnrichKey 折平分隔符之后
	// 仍然跟播放器报的完整串对不上,预取白做。
	writeTestQQArchive(t, 0, []testQQSong{
		{title: "当前", album: "甲", singers: []string{"甲"}, duration: 100},
		{title: "合唱", album: "乙", singers: []string{"乙", "丙", "丁"}, duration: 200},
	})
	got, ok := qqUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 {
		t.Fatalf("该取到 1 首,得到 ok=%v got=%+v", ok, got)
	}
	if loosenEnrichKey(got[0].artist+"|合唱") != loosenEnrichKey("乙 & 丙 & 丁|合唱") {
		t.Errorf("歌手串 %q 跟播放器报的完整串归一后对不上", got[0].artist)
	}
}

func TestQQUpcomingFallsBackToSingerInfo(t *testing.T) {
	// singerList 缺失(旧版客户端写的条目)时退回 singerInfo.name 那个主歌手,
	// 而不是交出一个空歌手 —— 空歌手拼出来的 enrich key 必然搜不到。
	writeTestQQArchive(t, 0, []testQQSong{
		{title: "当前", album: "甲", singers: []string{"甲"}, duration: 100},
		{title: "老条目", album: "乙", singerInfo: "乙歌手", duration: 200},
	})
	got, ok := qqUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 || got[0].artist != "乙歌手" {
		t.Fatalf("该退回 singerInfo.name,得到 ok=%v got=%+v", ok, got)
	}
}

func TestQQUpcomingIndexOutOfRange(t *testing.T) {
	// 归档里的下标越界(文件写到一半、或格式变了):当没读到,别 panic。
	writeTestQQArchive(t, 9, []testQQSong{
		{title: "只有一首", album: "甲", singers: []string{"甲"}, duration: 100},
	})
	if _, ok := qqUpcoming("甲", "只有一首", 5); ok {
		t.Errorf("下标越界时该返回 false")
	}
}

func TestParsePlistXMLFoldsUIDAndTypes(t *testing.T) {
	doc := []byte(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>ref</key><dict><key>CF$UID</key><integer>7</integer></dict>
<key>plain</key><dict><key>CF$UID</key><integer>7</integer><key>other</key><integer>1</integer></dict>
<key>n</key><integer>-3</integer>
<key>f</key><real>1.5</real>
<key>s</key><string>文字</string>
<key>t</key><true/>
<key>arr</key><array><integer>1</integer><string>x</string></array>
</dict></plist>`)
	v, err := parsePlistXML(doc)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	m, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("根节点不是字典: %T", v)
	}
	if u, ok := m["ref"].(plistUID); !ok || u != 7 {
		t.Errorf("单键 CF$UID 该折成 plistUID(7),得到 %#v", m["ref"])
	}
	// 多一个键就不是引用了,别折 —— 折错会把一个普通字典变成指向别处的指针。
	if _, isUID := m["plain"].(plistUID); isUID {
		t.Errorf("带别的键的字典不该被折成 UID")
	}
	if m["n"] != int64(-3) || m["f"] != 1.5 || m["s"] != "文字" || m["t"] != true {
		t.Errorf("标量解错: %#v", m)
	}
	if arr, ok := m["arr"].([]any); !ok || len(arr) != 2 || arr[0] != int64(1) || arr[1] != "x" {
		t.Errorf("数组解错: %#v", m["arr"])
	}
}

// QQ 的同专辑兜底:按归档里当前这首的 albumMid 问 QQ 自己的专辑曲目表,歌手拼全部(跟 QQ 播放器报的一致)。
func TestAlbumTracksQQUsesQQAlbum(t *testing.T) {
	writeTestQQArchive(t, 0, []testQQSong{
		{title: "开播那首", album: "别的专辑", singers: []string{"甲"}, duration: 100, albumMid: "000other"},
		{title: "当前", album: "专辑", singers: []string{"甲"}, duration: 100, albumMid: "000album"},
	})
	qqAlbumSongsMu.Lock()
	old := qqAlbumSongsCache
	qqAlbumSongsCache = map[string][]qqAlbumSong{"000album": {
		{mid: "a", name: "当前", singer: "甲", singers: []string{"甲"}, interval: 100},
		{mid: "b", name: "合唱", singer: "甲", singers: []string{"甲", "乙"}, interval: 200},
	}}
	qqAlbumSongsMu.Unlock()
	t.Cleanup(func() { qqAlbumSongsMu.Lock(); qqAlbumSongsCache = old; qqAlbumSongsMu.Unlock() })

	tracks, ok := albumTracks("甲", "当前", "专辑", qqMusicBundleID)
	if !ok || len(tracks) != 2 {
		t.Fatalf("该取到 QQ 专辑的 2 首,得到 ok=%v %+v", ok, tracks)
	}
	if tracks[1].title != "合唱" || tracks[1].artist != "甲/乙" || tracks[1].duration != 200 {
		t.Errorf("第二首 %+v,期望 合唱 / 甲/乙 / 200 秒", tracks[1])
	}
	// 当前这首不在归档里(归档是上一次播放留下的):本地这条放弃,交给网易云那条。
	if got, ok := qqAlbumTracks("丙", "别的歌", "专辑"); ok {
		t.Errorf("归档里没有当前这首,不该取到: %+v", got)
	}
}
