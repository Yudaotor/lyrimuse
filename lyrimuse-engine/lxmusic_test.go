package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type lxTestTrack struct {
	list, id, name, singer, interval, album string
}

type lxTestLyric struct {
	id, source, kind, text string
}

// withLXMusicData 在临时目录里造一份洛雪的 LxDatas:列表曲目(按给的顺序)、歌词、playInfo、播放顺序。
func withLXMusicData(t *testing.T, tracks []lxTestTrack, lyrics []lxTestLyric, listID string, index int, method string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "LxDatas")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var sb strings.Builder
	sb.WriteString(`CREATE TABLE "my_list_music_info" ("id" TEXT NOT NULL, "listId" TEXT NOT NULL, "name" TEXT NOT NULL, ` +
		`"singer" TEXT NOT NULL, "source" TEXT NOT NULL, "interval" TEXT, "meta" TEXT NOT NULL, UNIQUE("id","listId"));` + "\n")
	sb.WriteString(`CREATE TABLE "my_list_music_info_order" ("listId" TEXT NOT NULL, "musicInfoId" TEXT NOT NULL, "order" INTEGER NOT NULL);` + "\n")
	sb.WriteString(`CREATE TABLE "lyric" ("id" TEXT NOT NULL, "source" TEXT NOT NULL, "type" TEXT NOT NULL, "text" TEXT NOT NULL);` + "\n")
	sb.WriteString(`CREATE TABLE "music_url" ("id" TEXT NOT NULL, "url" TEXT NOT NULL);` + "\n")
	sb.WriteString(`CREATE TABLE "dislike_list" ("type" TEXT NOT NULL, "content" TEXT NOT NULL, "meta" TEXT);` + "\n")
	order := map[string]int{}
	for _, tr := range tracks {
		meta := fmt.Sprintf(`{"songId":"%s","albumName":%q}`, tr.id, tr.album)
		sb.WriteString(fmt.Sprintf("INSERT INTO my_list_music_info VALUES (%s,%s,%s,%s,'kw',%s,%s);\n", sqlQuote(tr.id),
			sqlQuote(tr.list), sqlQuote(tr.name), sqlQuote(tr.singer), sqlQuote(tr.interval), sqlQuote(meta)))
		sb.WriteString(fmt.Sprintf(`INSERT INTO my_list_music_info_order VALUES (%s,%s,%d);`+"\n", sqlQuote(tr.list), sqlQuote(tr.id), order[tr.list]))
		order[tr.list]++
	}
	for _, l := range lyrics {
		sb.WriteString(fmt.Sprintf("INSERT INTO lyric VALUES (%s,%s,%s,%s);\n", sqlQuote(l.id), sqlQuote(l.source), sqlQuote(l.kind),
			sqlQuote(base64.StdEncoding.EncodeToString([]byte(l.text)))))
	}
	cmd := exec.Command("/usr/bin/sqlite3", filepath.Join(dir, "lx.data.db"))
	cmd.Stdin = strings.NewReader(sqliteBatch(sb.String()))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("建测试库失败(没有 /usr/bin/sqlite3?): %v %s", err, out)
	}
	state := fmt.Sprintf(`{"playInfo":{"time":0,"maxTime":200,"listId":%q,"index":%d}}`, listID, index)
	if err := os.WriteFile(filepath.Join(dir, "data.json"), []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	if method != "" {
		config := fmt.Sprintf(`{"version":"2","setting":{"player.togglePlayMethod":%q}}`, method)
		if err := os.WriteFile(filepath.Join(dir, "config_v2.json"), []byte(config), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	saved, savedPlayLater := lxMusicDataDirOverride, lxMusicPlayLaterPathOverride
	lxMusicDataDirOverride = dir
	lxMusicPlayLaterPathOverride = filepath.Join(dir, "no-play-later.json")
	lxMusicLyricsAvailMu.Lock()
	lxMusicLyricsAvailMemo = map[string]lxMusicLyricsAvail{}
	lxMusicLyricsAvailMu.Unlock()
	lxMusicPreloadMu.Lock()
	lxMusicPreloadKey, lxMusicPreloadBaseline, lxMusicPreloadLogged = "", 0, 0
	lxMusicPreloadMu.Unlock()
	t.Cleanup(func() { lxMusicDataDirOverride, lxMusicPlayLaterPathOverride = saved, savedPlayLater })
}

// lxTestSQL 往测试库里执行一句。
func lxTestSQL(t *testing.T, q string) {
	t.Helper()
	if out, err := exec.Command("/usr/bin/sqlite3", lxMusicDBPath(), q).CombinedOutput(); err != nil {
		t.Fatalf("%s: %v %s", q, err, out)
	}
}

// lxTestSaveURL 照洛雪存播放地址的写法(先删再插)往测试库的 music_url 写一行。
func lxTestSaveURL(t *testing.T, urlID string) {
	t.Helper()
	q := fmt.Sprintf("DELETE FROM music_url WHERE id = %s; INSERT INTO music_url VALUES (%s, 'https://x');", sqlQuote(urlID), sqlQuote(urlID))
	if out, err := exec.Command("/usr/bin/sqlite3", lxMusicDBPath(), q).CombinedOutput(); err != nil {
		t.Fatalf("写 music_url: %v %s", err, out)
	}
}

var lxTestList = []lxTestTrack{
	{"temp", "kw_1", "小半", "陈粒", "04:57", "小梦大半"},
	{"temp", "kw_2", "晴天", "周杰伦", "04:29", "叶惠美"},
	{"temp", "kw_3", "一样的月光", "徐佳莹", "04:00", "LaLa首张创作专辑"},
	{"temp", "kw_4", "演员", "薛之谦", "04:21", "绅士"},
	{"default", "kw_9", "晴天", "周杰伦", "04:30", "叶惠美(Live)"},
}

func TestLXMusicWordsToYRC(t *testing.T) {
	for _, c := range []struct{ name, in, want string }{
		{"字的偏移相对行首,转成绝对毫秒", "[00:03.770]<0,945>词<945,945>:<1890,945>C",
			"[3770,2835](3770,945,0)词(4715,945,0):(5660,945,0)C"},
		{"两位小数", "[01:02.50]<0,100>a<100,200>b", "[62500,300](62500,100,0)a(62600,200,0)b"},
		{"后一个字早于前一个字的终点时截短前一个", "[00:01.000]<0,500>a<300,200>b", "[1000,500](1000,300,0)a(1300,200,0)b"},
		{"没有逐字标记、没有文字的行丢掉", "[ti:听]\n[00:00.000]听\n[00:01.000]<0,100> \n[00:02.000]<0,100>x",
			"[2000,100](2000,100,0)x"},
		{"一行都没有", "[ti:听]", ""},
	} {
		if got := lxMusicWordsToYRC(c.in); got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, c.want)
		}
	}
}

func TestLXMusicCurrentTrack(t *testing.T) {
	ctx := context.Background()
	t.Run("playInfo 指的那一条对得上", func(t *testing.T) {
		withLXMusicData(t, lxTestList, nil, "temp", 2, "")
		tr, list, pos, ok := lxMusicCurrentTrack(ctx, "徐佳莹", "一样的月光", 240.39)
		if !ok || tr.ID != "kw_3" || pos != 2 || len(list) != 4 || tr.album() != "LaLa首张创作专辑" || tr.durationSecs() != 240 {
			t.Fatalf("got %+v pos=%d len=%d ok=%v", tr, pos, len(list), ok)
		}
	})
	t.Run("playInfo 还没写盘,在同一个列表里按名字找", func(t *testing.T) {
		withLXMusicData(t, lxTestList, nil, "temp", 2, "")
		tr, _, pos, ok := lxMusicCurrentTrack(ctx, "薛之谦", "演员", 261)
		if !ok || tr.ID != "kw_4" || pos != 3 {
			t.Fatalf("got %+v pos=%d ok=%v", tr, pos, ok)
		}
	})
	t.Run("playInfo 那个列表里没有,在所有列表里找,取时长最接近的", func(t *testing.T) {
		withLXMusicData(t, lxTestList, nil, "userlist_gone", 0, "")
		tr, list, pos, ok := lxMusicCurrentTrack(ctx, "周杰伦", "晴天", 269.2)
		if !ok || tr.ID != "kw_2" {
			t.Fatalf("got %+v ok=%v", tr, ok)
		}
		if tr, _, _, _ := lxMusicCurrentTrack(ctx, "周杰伦", "晴天", 270.2); tr.ID != "kw_9" {
			t.Errorf("时长 270.2 该认成登记 4:30 的那条: %s", tr.ID)
		}
		if list != nil || pos != -1 {
			t.Errorf("不在 playInfo 那个列表里时没有列表和下标: len=%d pos=%d", len(list), pos)
		}
	})
	t.Run("playInfo 那个列表里有同名的,先认它", func(t *testing.T) {
		withLXMusicData(t, lxTestList, nil, "default", 5, "")
		if tr, _, pos, ok := lxMusicCurrentTrack(ctx, "周杰伦", "晴天", 269.6); !ok || tr.ID != "kw_9" || pos != 0 {
			t.Fatalf("got %+v pos=%d ok=%v", tr, pos, ok)
		}
	})
	t.Run("歌手对不上不认", func(t *testing.T) {
		withLXMusicData(t, lxTestList, nil, "temp", 1, "")
		if _, _, _, ok := lxMusicCurrentTrack(ctx, "五月天", "晴天", 0); ok {
			t.Fatal("歌手不同的同名歌不该认")
		}
	})
	t.Run("没装洛雪", func(t *testing.T) {
		saved := lxMusicDataDirOverride
		lxMusicDataDirOverride = filepath.Join(t.TempDir(), "nope")
		defer func() { lxMusicDataDirOverride = saved }()
		if _, _, _, ok := lxMusicCurrentTrack(ctx, "徐佳莹", "一样的月光", 0); ok {
			t.Fatal("没有数据时不该认出来")
		}
	})
}

func TestLXMusicLyrics(t *testing.T) {
	ctx := context.Background()
	lyrics := []lxTestLyric{
		{"kw_3", "raw", "lyric", "[00:01.00]原版第一句\n[00:02.00]原版第二句"},
		{"kw_3", "raw", "tlyric", "[00:01.00]tr"},
		{"kw_3", "raw", "lxlyric", "[00:01.000]<0,500>原<500,500>版"},
		{"kw_4", "raw", "lyric", "[00:01.00]演员原版"},
		{"kw_4", "edited", "lyric", "[00:01.00]演员改过"},
	}
	withLXMusicData(t, lxTestList, lyrics, "temp", 2, "")
	s, ok := lxMusicLyrics(ctx, "kw_3")
	if !ok || !strings.Contains(s.lrc, "原版第一句") || s.tr != "[00:01.00]tr" || s.word == "" {
		t.Fatalf("got %+v ok=%v", s, ok)
	}
	if s, _ := lxMusicLyrics(ctx, "kw_4"); !strings.Contains(s.lrc, "改过") {
		t.Errorf("用户改过的那份优先: %q", s.lrc)
	}
	if _, ok := lxMusicLyrics(ctx, "kw_1"); ok {
		t.Error("没放过的歌没有词")
	}
}

func TestLXMusicLocalLyricsFor(t *testing.T) {
	ctx := context.Background()
	lyrics := []lxTestLyric{
		{"kw_3", "raw", "lyric", "[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句"},
		{"kw_3", "raw", "lxlyric", "[00:01.000]<0,500>第<500,500>一句"},
	}
	withLXMusicData(t, lxTestList, lyrics, "temp", 2, "")
	setNativeLyricSourcesForPlayer(spotifyBundleID)
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
	if _, ok := lxMusicLocalLyricsFor(ctx, "徐佳莹", "一样的月光", 240); ok {
		t.Fatal("不是在用洛雪放,不读")
	}
	setNativeLyricSourcesForPlayer(lxMusicBundleID)
	r, ok := lxMusicLocalLyricsFor(ctx, "徐佳莹", "一样的月光", 240)
	if !ok || r.source != lxMusicLocalLyricsSource || !r.identityFromLocalClient || r.yrc == "" ||
		r.matchAlbum != "LaLa首张创作专辑" || r.srcDur != 240 || !strings.Contains(r.lyr, "第二句") {
		t.Fatalf("got %+v ok=%v", r, ok)
	}
	if _, ok := lxMusicLocalLyricsFor(ctx, "陈粒", "小半", 297); ok {
		t.Error("洛雪没存这首的词")
	}
}

// 数据目录路径里带 #、?、%、空格:拼成 sqlite 的 URI 时要转义,不然打开的是别的文件(读不出列表)。
func TestLXMusicSQLPathWithURIChars(t *testing.T) {
	withLXMusicData(t, lxTestList, nil, "temp", 2, "")
	odd := filepath.Join(t.TempDir(), "a #1?b%20c")
	if err := os.Rename(lxMusicDataDirOverride, odd); err != nil {
		t.Fatal(err)
	}
	lxMusicDataDirOverride = odd
	tracks, err := lxMusicList(context.Background(), "temp")
	if err != nil || len(tracks) != 4 || tracks[0].Name != "小半" {
		t.Fatalf("路径带 URI 字符时应照常读出列表: %+v err=%v", tracks, err)
	}
}

// 洛雪一直没这首的词:没有的结论接连落空就越记越久(5s、10s、20s…封顶一分钟),有了词照旧记半分钟。
func TestLXMusicLyricsMissingBacksOff(t *testing.T) {
	for misses, want := range map[int]time.Duration{0: 5 * time.Second, 1: 5 * time.Second, 2: 10 * time.Second,
		3: 20 * time.Second, 4: 40 * time.Second, 5: time.Minute, 50: time.Minute} {
		if got := lxMusicLyricsMissingTTLFor(misses); got != want {
			t.Errorf("第 %d 次落空记 %v,want %v", misses, got, want)
		}
	}
	withLXMusicData(t, lxTestList, nil, "temp", 2, "")
	key := "陈粒\x00小半"
	memo := func() lxMusicLyricsAvail {
		lxMusicLyricsAvailMu.Lock()
		defer lxMusicLyricsAvailMu.Unlock()
		return lxMusicLyricsAvailMemo[key]
	}
	expire := func() {
		lxMusicLyricsAvailMu.Lock()
		m := lxMusicLyricsAvailMemo[key]
		m.until = time.Now().Add(-time.Second)
		lxMusicLyricsAvailMemo[key] = m
		lxMusicLyricsAvailMu.Unlock()
	}
	for i := 1; i <= 4; i++ {
		before := time.Now()
		if lxMusicLyricsAvailable(lxMusicBundleID, "陈粒", "小半", 297) {
			t.Fatal("洛雪没存这首的词")
		}
		m := memo()
		if m.misses != i || m.until.Before(before.Add(lxMusicLyricsMissingTTLFor(i))) {
			t.Fatalf("第 %d 次落空: misses=%d until 距今 %v", i, m.misses, time.Until(m.until))
		}
		expire()
	}
}

func TestLXMusicLyricsAvailableAndRecheck(t *testing.T) {
	lyrics := []lxTestLyric{{"kw_3", "raw", "lyric", "[00:01.00]第一句"}}
	withLXMusicData(t, lxTestList, lyrics, "temp", 2, "")
	if !lxMusicLyricsAvailable(lxMusicBundleID, "徐佳莹", "一样的月光", 240) {
		t.Fatal("洛雪存着这首的词")
	}
	if lxMusicLyricsAvailable(amazonMusicBundleID, "徐佳莹", "一样的月光", 240) {
		t.Fatal("不是洛雪在放,不算")
	}
	if lxMusicLyricsAvailable(lxMusicBundleID, "陈粒", "小半", 297) {
		t.Fatal("没存词的不算")
	}
	e := enrichEntry{Lyrics: bt("[00:01.00]x"), LyricsSource: "kuwo"}
	if !lxMusicLyricsWorthRecheck(e, lxMusicBundleID, false, true, true) {
		t.Error("没见过洛雪那份、现在有词,值得重来一次")
	}
	for name, c := range map[string]struct {
		e                                   enrichEntry
		bundle                              string
		pinned, auto, available, wantWorthy bool
	}{
		"别的播放器":    {e, kkboxBundleID, false, true, true, false},
		"关了自动升级":   {e, lxMusicBundleID, false, false, true, false},
		"用户选定了源":   {e, lxMusicBundleID, true, true, true, false},
		"洛雪没词":     {e, lxMusicBundleID, false, true, false, false},
		"已经见过那份候选": {enrichEntry{LyricsSourcesSeen: []string{lxMusicLocalLyricsSource}}, lxMusicBundleID, false, true, true, false},
		"手改过":      {enrichEntry{ManualLyrics: true}, lxMusicBundleID, false, true, true, false},
	} {
		if got := lxMusicLyricsWorthRecheck(c.e, c.bundle, c.pinned, c.auto, c.available); got != c.wantWorthy {
			t.Errorf("%s: got %v", name, got)
		}
	}
}

func TestLXMusicUpcoming(t *testing.T) {
	names := func(ts []upcomingTrack) string {
		var out []string
		for _, x := range ts {
			out = append(out, x.title)
		}
		return strings.Join(out, ",")
	}
	for _, c := range []struct {
		method, want string
		index        int
		ok           bool
	}{
		{"listLoop", "演员,小半", 2, true},
		{"", "演员,小半", 2, true},
		{"list", "演员", 2, true},
		{"singleLoop", "", 2, true},
		{"none", "", 2, true},
		{"random", "演员,小半,晴天", 2, true},
	} {
		withLXMusicData(t, lxTestList, nil, "temp", c.index, c.method)
		got, ok := lxMusicUpcoming("徐佳莹", "一样的月光", 2)
		if ok != c.ok || names(got) != c.want {
			t.Errorf("%q: got %q ok=%v, want %q", c.method, names(got), ok, c.want)
		}
	}
	withLXMusicData(t, lxTestList, nil, "temp", 2, "listLoop")
	if got, _ := lxMusicUpcoming("徐佳莹", "一样的月光", 1); len(got) != 1 || got[0].album != "绅士" || got[0].duration != 261 ||
		got[0].artist != "薛之谦" {
		t.Errorf("曲目身份带上专辑和登记时长: %+v", got)
	}
	if got, ok := lxMusicUpcoming("五月天", "倔强", 2); !ok || names(got) != "演员,小半" {
		t.Errorf("当前这首哪个列表里都没有(「稍后播放」)时从 data.json 记的那首往后取: %q ok=%v", names(got), ok)
	}
	withLXMusicData(t, lxTestList, nil, "temp", 9, "listLoop")
	if _, ok := lxMusicUpcoming("五月天", "倔强", 2); ok {
		t.Error("data.json 记的位置也对不上时交回 ok=false,退回同专辑预取")
	}
	other := append(lxTestList[:len(lxTestList):len(lxTestList)], lxTestTrack{"default", "kw_8", "倔强", "五月天", "04:20", "神的孩子都在跳舞"})
	withLXMusicData(t, other, nil, "temp", 2, "listLoop")
	if _, ok := lxMusicUpcoming("五月天", "倔强", 2); ok {
		t.Error("在别的列表里找得到、位置不明时不按 data.json 那首猜")
	}
}

// 洛雪快放完时预加载下一首,往 music_url 写一行「曲目 id_音质」:这一首第一次问时记下基线,之后新写的、不是这一首、
// 在某个列表里的那一首排最前面;写库让改写标记变。
func TestLXMusicPreloadedNext(t *testing.T) {
	names := func(ts []upcomingTrack) string {
		var out []string
		for _, x := range ts {
			out = append(out, x.title+"/"+x.album)
		}
		return strings.Join(out, ",")
	}
	list := append(lxTestList[:len(lxTestList):len(lxTestList)], lxTestTrack{"default", "kw_8", "倔强", "五月天", "04:20", "神的孩子都在跳舞"})
	withLXMusicData(t, list, nil, "temp", 2, "random")
	lxTestSaveURL(t, "kw_8_128k")
	base := "演员/绅士,小半/小梦大半,晴天/叶惠美"
	if got, ok := lxMusicUpcoming("徐佳莹", "一样的月光", 3); !ok || names(got) != base {
		t.Fatalf("这一首第一次问:记基线,开播前就有的那行不算: %q ok=%v", names(got), ok)
	}
	if got, _ := lxMusicUpcoming("徐佳莹", "一样的月光", 3); names(got) != base {
		t.Errorf("再问一次、没有新写的:开播前就有的那行照旧不算: %q", names(got))
	}
	stamp := lxMusicQueueStamp()
	lxTestSaveURL(t, "kw_3_128k")
	if got, _ := lxMusicUpcoming("徐佳莹", "一样的月光", 3); names(got) != base {
		t.Errorf("新写的是这一首自己的地址,不算: %q", names(got))
	}
	if lxMusicQueueStamp() == stamp {
		t.Error("写了 music_url,改写标记要变")
	}
	lxTestSaveURL(t, "kw_8_128k")
	if got, _ := lxMusicUpcoming("徐佳莹", "一样的月光", 3); names(got) != "倔强/神的孩子都在跳舞,"+base[:strings.LastIndex(base, ",")] {
		t.Errorf("预加载的下一首(别的列表里的)排最前面,凑满 3 首: %q", names(got))
	}
	lxTestSaveURL(t, "kw_9_128k")
	if got, _ := lxMusicUpcoming("徐佳莹", "一样的月光", 4); names(got) != "晴天/叶惠美(Live),演员/绅士,小半/小梦大半" {
		t.Errorf("预加载的跟猜的同名同歌手时只留一条: %q", names(got))
	}
	lxTestSaveURL(t, "kw_77_128k")
	if got, _ := lxMusicUpcoming("徐佳莹", "一样的月光", 3); names(got) != base {
		t.Errorf("预加载的不在任何列表里(搜索结果),查不到歌名,照猜的给: %q", names(got))
	}
	// 「稍后播放」:这一首哪个列表里都没有,单曲循环那条也按预加载的给。
	withLXMusicData(t, list, nil, "temp", 2, "singleLoop")
	if _, ok := lxMusicUpcoming("林忆莲", "至少还有你", 3); !ok {
		t.Fatal("不在列表里时照旧按 data.json 那首往后取")
	}
	lxTestSaveURL(t, "kw_4_128k")
	if got, ok := lxMusicUpcoming("林忆莲", "至少还有你", 3); !ok || names(got) != "演员/绅士" {
		t.Errorf("单曲循环本来没有下一首,预加载了就给那一首: %q ok=%v", names(got), ok)
	}
	for in, want := range map[string]string{"kw_168143592_128k": "kw_168143592", "tx_003cSLOO35W3yP_flac24bit": "tx_003cSLOO35W3yP", "kw_1": "", "x": ""} {
		if got := lxMusicURLSongID(in); got != want {
			t.Errorf("lxMusicURLSongID(%q) = %q, want %q", in, got, want)
		}
	}
	if upcomingQueueStamp(lxMusicBundleID) == "" {
		t.Error("洛雪要按本地库的改写标记重读接下来那几首")
	}
}

// 洛雪列表里这一首记着的封面(放过才有)换成 https 记进 player_covers;没核过 https 的图床不给。
func TestLXMusicCover(t *testing.T) {
	for in, want := range map[string]string{
		"http://img3.kuwo.cn/pic_music/300/s4s83/1/415965568.jpg":               "https://img3.kuwo.cn/pic_music/300/s4s83/1/415965568.jpg",
		"http://img1.kwcdn.kuwo.cn/star/albumcover/500/18/85/361816981.jpg":     "https://img1.kuwo.cn/star/albumcover/500/18/85/361816981.jpg",
		"http://imge.kugou.com/stdmusic/480/20210901/1.jpg":                     "https://imge.kugou.com/stdmusic/480/20210901/1.jpg",
		"https://y.gtimg.cn/music/photo_new/T002R500x500M000000GvdTR0qcKh8.jpg": "https://y.gtimg.cn/music/photo_new/T002R500x500M000000GvdTR0qcKh8.jpg",
		"http://p2.music.126.net/3Y0A55OzEnqKNiH5ODA54A==/1.jpg":                "https://p2.music.126.net/3Y0A55OzEnqKNiH5ODA54A==/1.jpg",
		"http://d.musicapp.migu.cn/data/oss/resource/00/5w/94/a.webp":           "https://d.musicapp.migu.cn/data/oss/resource/00/5w/94/a.webp",
		"/data/oss/resource/00/5t/1k/a.webp":                                    "https://d.musicapp.migu.cn/data/oss/resource/00/5t/1k/a.webp",
		" /data/oss/resource/00/5t/1k/a.webp ":                                  "https://d.musicapp.migu.cn/data/oss/resource/00/5t/1k/a.webp",
		"/other/a.jpg":                                                          "",
		"http://img2.kwcdn.kuwo.cn/a.jpg":                                       "",
		"http://example.com/a.jpg":                                              "",
		"file:///Users/x/a.jpg":                                                 "",
		"":                                                                      "",
	} {
		if got := lxMusicHTTPSCover(in); got != want {
			t.Errorf("lxMusicHTTPSCover(%q) = %q, want %q", in, got, want)
		}
	}
	withLXMusicData(t, lxTestList, nil, "temp", 2, "listLoop")
	if got := lxMusicCoverURL("徐佳莹", "一样的月光", 240); got != "" {
		t.Errorf("没放过(meta 里没有 picUrl)不给: %q", got)
	}
	q := `UPDATE my_list_music_info SET meta = json_set(meta, '$.picUrl', 'http://img1.kwcdn.kuwo.cn/star/albumcover/500/1.jpg') WHERE id = 'kw_3';`
	if out, err := exec.Command("/usr/bin/sqlite3", lxMusicDBPath(), q).CombinedOutput(); err != nil {
		t.Fatalf("改 meta: %v %s", err, out)
	}
	if got := lxMusicCoverURL("徐佳莹", "一样的月光", 240); got != "https://img1.kuwo.cn/star/albumcover/500/1.jpg" {
		t.Errorf("放过的歌给列表里记的封面: %q", got)
	}
	if got := playerCoverURLFor(lxMusicBundleID, "徐佳莹", "一样的月光", "LaLa首张创作专辑", 240, kkboxPlayingInfo{}); got == "" {
		t.Error("洛雪在放时 playerCoverURLFor 要问它")
	}
}

// 洛雪列表里这一首来自 QQ / 网易云时,拼出那家的歌曲页;别的平台、id 形状不对的不给。只在条目的链接空着时补。
func TestLXMusicSongPages(t *testing.T) {
	for _, c := range []struct {
		source, meta, qq, netease string
	}{
		{"tx", `{"songId":"003cSLOO35W3yP","albumName":"危险世界"}`, "https://y.qq.com/n/ryqq/songDetail/003cSLOO35W3yP", ""},
		{"wy", `{"songId":28403111}`, "", "https://music.163.com/song?id=28403111"},
		{"wy", `{"songId":"28403111"}`, "", "https://music.163.com/song?id=28403111"},
		{"kw", `{"songId":"4100778"}`, "", ""},
		{"tx", `{"songId":"abc/../x"}`, "", ""},
		{"wy", `{"songId":"x1"}`, "", ""},
	} {
		qq, ne := lxMusicTrack{Source: c.source, Meta: c.meta}.songPages()
		if qq != c.qq || ne != c.netease {
			t.Errorf("%s %s: got %q %q", c.source, c.meta, qq, ne)
		}
	}
	e := enrichEntry{QQURL: "https://y.qq.com/n/ryqq/songDetail/searched"}
	ids := playerCatalogIDs{songID: "tx_003cSLOO35W3yP", qqSong: "https://y.qq.com/n/ryqq/songDetail/003cSLOO35W3yP",
		neteaseSong: "https://music.163.com/song?id=1"}
	if !applyPlayerCatalogIDsLocked(&e, lxMusicBundleID, ids) {
		t.Fatal("记下了曲目 id、补了网易云链接,该算改了")
	}
	if e.QQURL != "https://y.qq.com/n/ryqq/songDetail/searched" || e.NeteaseURL != "https://music.163.com/song?id=1" ||
		e.PlayerSongIDs[lxMusicBundleID] != "tx_003cSLOO35W3yP" {
		t.Errorf("已有的 QQ 链接不盖,空着的网易云链接补上,曲目 id 记下: %+v", e)
	}
	if applyPlayerCatalogIDsLocked(&e, lxMusicBundleID, ids) {
		t.Error("同样的再来一次不算改")
	}
	if !playerSongIDOK(lxMusicBundleID, "2554596_0F7A79ADAAEEB6EA1DA3E19DD637FD73") || playerSongIDOK(lxMusicBundleID, "kw 1") {
		t.Error("洛雪的曲目 id 是字母数字加下划线")
	}
	if playingSongIDFor(lxMusicBundleID, "", ids) != "tx_003cSLOO35W3yP" {
		t.Error("洛雪报的这一首的曲目 id 用来认同一段录音")
	}
}

// 洛雪本地歌词那份要在首轮读进来、拼成候选、胜出时把译文和音译一起抄进条目。
func TestLXMusicLocalLyricsIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, wire := range []string{
		"if r, ok := lxMusicLocalLyricsFor(ctx, idArtist, idTitle, durationSecs); ok {\n\t\t\traw[lxMusicLocalLyricsSource] = r",
		"source: lxMusicLocalLyricsSource, lyrics: lxm.lyr,",
		"case lxMusicLocalLyricsSource:\n",
		"lxMusicLyrics: lxMusicLyricsAvail",
		"s != lxMusicLocalLyricsSource",
		"if lxMusicAwaitsDuration(bundleID, durationSecs) {\n\t\tenrichMu.Unlock()\n\t\treturn nil\n\t}\n\t// 从没见过这首歌:首次解析",
	} {
		if !containsCode(string(b), wire) {
			t.Errorf("enrich.go 缺 %q", wire)
		}
	}
	if !lxMusicAwaitsDuration(lxMusicBundleID, 0) || lxMusicAwaitsDuration(lxMusicBundleID, 240.4) || lxMusicAwaitsDuration(kkboxBundleID, 0) {
		t.Error("只有洛雪、而且这一拍时长还是 0 时,首次解析才等下一拍")
	}
	if !isPlayerLocalLyricSource(lxMusicLocalLyricsSource) {
		t.Error("洛雪本地歌词是播放器本地的那一类(整首错开判定不给它同源否决)")
	}
	if playerNativeLyricSource(playerLXMusic) != lxMusicLocalLyricsSource {
		t.Error("players.json 里洛雪的 nativeLyricSource 要填 lxmusic")
	}
}

// 「不喜欢」:三种规则按洛雪的写法归一(@ 换 #、小写、去空白);在放的那一首留着;除了它都滤光时不滤。
func TestLXMusicDislike(t *testing.T) {
	d := lxMusicParseDislike([]string{"晴天@周杰伦", "  Small Half ", "@薛之谦", "", "@", "a#b@C"})
	for _, c := range []struct {
		name, singer string
		want         bool
	}{
		{"晴天", "周杰伦", true}, {"晴天", "五月天", false}, {"small half", "陈粒", true}, {"演员", "薛之谦", true},
		{"a@b", "c", true}, {"小半", "陈粒", false},
	} {
		if got := d.matches(lxMusicTrack{Name: c.name, Singer: c.singer}); got != c.want {
			t.Errorf("%s/%s: got %v", c.name, c.singer, got)
		}
	}
	list := []lxMusicTrack{{Name: "小半", Singer: "陈粒"}, {Name: "晴天", Singer: "周杰伦"}, {Name: "一样的月光", Singer: "徐佳莹"}, {Name: "演员", Singer: "薛之谦"}}
	got, pos := d.filter(list, 1)
	if len(got) != 3 || pos != 1 || got[2].Name != "一样的月光" {
		t.Errorf("在放的那首命中规则也留着、别的命中的去掉: %+v pos=%d", got, pos)
	}
	all := lxMusicParseDislike([]string{"@陈粒", "@徐佳莹", "@薛之谦"})
	if got, pos := all.filter(list, 1); len(got) != 4 || pos != 1 {
		t.Errorf("除了在放的都滤光时不滤: %+v pos=%d", got, pos)
	}
	if got, pos := lxMusicParseDislike(nil).filter(list, 2); len(got) != 4 || pos != 2 {
		t.Errorf("没有规则原样: %+v pos=%d", got, pos)
	}
	withLXMusicData(t, lxTestList, nil, "temp", 1, "listLoop")
	lxTestSQL(t, `INSERT INTO dislike_list VALUES ('music', '一样的月光@徐佳莹', NULL);`)
	names := func(ts []upcomingTrack) string {
		var out []string
		for _, x := range ts {
			out = append(out, x.title)
		}
		return strings.Join(out, ",")
	}
	if got, ok := lxMusicUpcoming("周杰伦", "晴天", 3); !ok || names(got) != "演员,小半" {
		t.Errorf("预取跳过洛雪不会放的: %q ok=%v", names(got), ok)
	}
}

// 「稍后播放」文件:App 记下、引擎读;样例两边各读一遍。顺序:预加载的 → 稍后播放(按加的先后)→ 列表猜的。
func TestLXMusicPlayLater(t *testing.T) {
	names := func(ts []upcomingTrack) string {
		var out []string
		for _, x := range ts {
			out = append(out, x.title)
		}
		return strings.Join(out, ",")
	}
	withLXMusicData(t, lxTestList, nil, "temp", 2, "listLoop")
	sample, err := os.ReadFile("../shared/testdata/lx-play-later.json")
	if err != nil {
		t.Fatal(err)
	}
	now := time.UnixMilli(1792070000000)
	path := filepath.Join(t.TempDir(), "lx-play-later.json")
	lxMusicPlayLaterPathOverride = path
	if err := os.WriteFile(path, sample, 0o644); err != nil {
		t.Fatal(err)
	}
	if got := lxMusicPlayLaterQueued("徐佳莹", "一样的月光", now); names(got) != "夜空中最亮的星,特别的人" || got[0].album != "世界" {
		t.Errorf("样例:六小时内、不是在放的那首,按先后: %q %+v", names(got), got)
	}
	if got := lxMusicPlayLaterQueued("逃跑计划", "夜空中最亮的星", now); names(got) != "特别的人" {
		t.Errorf("在放的那首不算: %q", names(got))
	}
	if got := lxMusicPlayLaterQueued("徐佳莹", "一样的月光", now.Add(7*time.Hour)); len(got) != 0 {
		t.Errorf("超过六小时都不算: %q", names(got))
	}
	stamp := lxMusicQueueStamp()
	recent := fmt.Sprintf(`{"schema":1,"tracks":[{"title":"倔强","artist":"五月天","album":"","added_at_ms":%d}]}`, time.Now().UnixMilli())
	if err := os.WriteFile(path, []byte(recent), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, time.Now().Add(time.Second), time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if lxMusicQueueStamp() == stamp {
		t.Error("App 加了一首,改写标记要变")
	}
	if got, ok := lxMusicUpcoming("徐佳莹", "一样的月光", 3); !ok || names(got) != "倔强,演员,小半" {
		t.Errorf("稍后播放排在列表前面: %q ok=%v", names(got), ok)
	}
	lxTestSaveURL(t, "kw_1_128k")
	lxTestSaveURL(t, "kw_1_320k")
	if got, _ := lxMusicUpcoming("徐佳莹", "一样的月光", 3); names(got) != "小半,倔强,演员" {
		t.Errorf("预加载的在最前,稍后播放其次,列表里同一首不重复: %q", names(got))
	}
	for _, bad := range []string{`{"schema":2,"tracks":[{"title":"倔强","artist":"五月天","added_at_ms":1}]}`, `not json`} {
		if err := os.WriteFile(path, []byte(bad), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := lxMusicPlayLaterQueued("徐佳莹", "一样的月光", now); len(got) != 0 {
			t.Errorf("%s: 认不出的当没有, got %q", bad, names(got))
		}
	}
}

// 本地库里没有这首(从搜索结果点播)时,问开放 API:前后两次 /status 都是这一首才拿 /lyric-all。
func TestLXMusicOpenAPILyrics(t *testing.T) {
	ctx := context.Background()
	withLXMusicData(t, lxTestList, nil, "temp", 2, "")
	setNativeLyricSourcesForPlayer(lxMusicBundleID)
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
	statuses := []string{}
	lyric := `{"lyric":"[00:01.00]夜空中最亮的星","tlyric":"","rlyric":"","lxlyric":"[00:01.000]<0,500>夜<500,500>空"}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/status":
			s := `{"name":"夜空中最亮的星","singer":"逃跑计划","albumName":"世界","duration":252.3}`
			if len(statuses) > 0 {
				s, statuses = statuses[0], statuses[1:]
			}
			fmt.Fprint(w, s)
		case "/lyric-all":
			fmt.Fprint(w, lyric)
		default:
			w.WriteHeader(http.StatusForbidden)
		}
	}))
	defer srv.Close()
	if _, ok := lxMusicLocalLyricsFor(ctx, "逃跑计划", "夜空中最亮的星", 252); ok {
		t.Fatal("开放 API 没开(配置里没有):不问")
	}
	lxMusicOpenAPIBaseOverride = srv.URL
	t.Cleanup(func() { lxMusicOpenAPIBaseOverride = "" })
	r, ok := lxMusicLocalLyricsFor(ctx, "逃跑计划", "夜空中最亮的星", 252)
	if !ok || r.source != lxMusicLocalLyricsSource || !r.identityFromLocalClient || r.matchAlbum != "世界" || r.srcDur != 252.3 ||
		!strings.Contains(r.lyr, "夜空中最亮的星") || r.yrc == "" {
		t.Fatalf("库里没有、开放 API 有: %+v ok=%v", r, ok)
	}
	if !lxMusicLyricsAvailable(lxMusicBundleID, "逃跑计划", "夜空中最亮的星", 252) {
		t.Error("有没有词也算上开放 API 那份")
	}
	if _, ok := lxMusicLocalLyricsFor(ctx, "五月天", "倔强", 252); ok {
		t.Error("它在放的不是这一首,不拿")
	}
	statuses = []string{`{"name":"夜空中最亮的星","singer":"逃跑计划"}`, `{"name":"倔强","singer":"五月天"}`}
	if _, ok := lxMusicLocalLyricsFor(ctx, "逃跑计划", "夜空中最亮的星", 252); ok {
		t.Error("问歌词时换了歌,不拿")
	}
	lyric = `{"lyric":"","tlyric":"","rlyric":"","lxlyric":""}`
	if _, ok := lxMusicLocalLyricsFor(ctx, "逃跑计划", "夜空中最亮的星", 252); ok {
		t.Error("它也没词时不算")
	}
	lxMusicOpenAPIBaseOverride = ""
	for cfg, want := range map[string]int{
		`{"setting":{"openAPI.enable":true,"openAPI.port":"23331"}}`: 23331,
		`{"setting":{"openAPI.enable":true,"openAPI.port":23332}}`:   23332,
		`{"setting":{"openAPI.enable":true,"openAPI.port":"x"}}`:     23330,
		`{"setting":{"openAPI.enable":true}}`:                        23330,
		`{"setting":{"openAPI.enable":false,"openAPI.port":23331}}`:  0,
		`not json`: 0,
	} {
		if err := os.WriteFile(lxMusicConfigPath(), []byte(cfg), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := lxMusicOpenAPIPort(); got != want {
			t.Errorf("%s: port %d, want %d", cfg, got, want)
		}
	}
}
