package main

import (
	"encoding/hex"
	"fmt"
	"html"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// cogFixture 是库里的一条。tags 按 Cog 的写法给:每个键一组字符串;nil = 没有元数据。
type cogFixture struct {
	pk, playlist, idx, shuffle int
	cur, queued, stop, deleted bool
	qpos                       int
	file                       string
	tags                       map[string][]string
}

// cogArchiveXML 造一份跟 Cog 同形状的 NSKeyedArchiver 归档(根是字典,值是字符串数组),XML 格式;plutil 转 xml1 时原样读得进。
func cogArchiveXML(tags map[string][]string) string {
	var objs []string
	uid := func(i int) string { return fmt.Sprintf("<dict><key>CF$UID</key><integer>%d</integer></dict>", i) }
	add := func(s string) int { objs = append(objs, s); return len(objs) - 1 }
	add("<string>$null</string>")
	root := add("")
	arrayClass := add("<dict><key>$classes</key><array><string>NSArray</string><string>NSObject</string></array><key>$classname</key><string>NSArray</string></dict>")
	dictClass := add("<dict><key>$classes</key><array><string>NSDictionary</string><string>NSObject</string></array><key>$classname</key><string>NSDictionary</string></dict>")
	var keys, vals []string
	for _, k := range cogSortedKeys(tags) {
		keys = append(keys, uid(add("<string>"+html.EscapeString(k)+"</string>")))
		var items []string
		for _, v := range tags[k] {
			items = append(items, uid(add("<string>"+html.EscapeString(v)+"</string>")))
		}
		vals = append(vals, uid(add(fmt.Sprintf("<dict><key>$class</key>%s<key>NS.objects</key><array>%s</array></dict>", uid(arrayClass), strings.Join(items, "")))))
	}
	objs[root] = fmt.Sprintf("<dict><key>$class</key>%s<key>NS.keys</key><array>%s</array><key>NS.objects</key><array>%s</array></dict>",
		uid(dictClass), strings.Join(keys, ""), strings.Join(vals, ""))
	return `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>$archiver</key><string>NSKeyedArchiver</string>` +
		`<key>$objects</key><array>` + strings.Join(objs, "") + `</array><key>$top</key><dict><key>root</key>` + uid(root) +
		`</dict><key>$version</key><integer>100000</integer></dict></plist>`
}

func cogSortedKeys(m map[string][]string) []string {
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func cogFileURL(file string) string {
	return "file://" + strings.ReplaceAll("/Music/"+file, " ", "%20")
}

// withCogDB 造一份跟 Cog 同结构的库(只建用到的列),路径指给 cogUpcomingOverride。
func withCogDB(t *testing.T, entries []cogFixture) string {
	t.Helper()
	b := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
	var sql strings.Builder
	sql.WriteString("CREATE TABLE ZPLAYLISTENTRY (Z_PK INTEGER PRIMARY KEY, ZCURRENT INTEGER, ZDELETED INTEGER, ZINDEX INTEGER, ZQUEUEPOSITION INTEGER, ZQUEUED INTEGER, ZSHUFFLEINDEX INTEGER, ZSTOPAFTER INTEGER, ZTOTALFRAMES INTEGER, ZPLAYLIST INTEGER, ZSAMPLERATE FLOAT, ZURLSTRING VARCHAR, ZMETADATABLOB BLOB);\n")
	for _, e := range entries {
		blob := "NULL"
		if e.tags != nil {
			blob = "X'" + hex.EncodeToString([]byte(cogArchiveXML(e.tags))) + "'"
		}
		qpos := e.qpos
		if !e.queued {
			qpos = -1
		}
		fmt.Fprintf(&sql, "INSERT INTO ZPLAYLISTENTRY VALUES (%d, %d, %d, %d, %d, %d, %d, %d, 4410000, %d, 44100.0, '%s', %s);\n",
			e.pk, b(e.cur), b(e.deleted), e.idx, qpos, b(e.queued), e.shuffle, b(e.stop), e.playlist, cogFileURL(e.file), blob)
	}
	path := filepath.Join(t.TempDir(), "DataModel.sqlite")
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sqliteBatch(sql.String()))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("建库失败: %v\n%s", err, out)
	}
	saved := cogUpcomingOverride
	cogUpcomingOverride = path
	t.Cleanup(func() { cogUpcomingOverride = saved })
	return path
}

// withCogPrefs 写一份偏好(plist 字典的内层),路径指给 cogPrefsOverride;body 为 "-" 时指到不存在的文件。
func withCogPrefs(t *testing.T, body string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "org.cogx.cog.plist")
	if body != "-" {
		xml := `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>` + body + `</dict></plist>`
		if err := os.WriteFile(path, []byte(xml), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	saved := cogPrefsOverride
	cogPrefsOverride = path
	t.Cleanup(func() { cogPrefsOverride = saved })
}

func withCogAppMode(t *testing.T, mode string, ok bool) *int {
	t.Helper()
	calls := 0
	saved := playerPlaybackMode
	playerPlaybackMode = func(bundle string) (string, bool) {
		calls++
		if bundle != cogBundleID {
			t.Errorf("问的是 %s 的播放模式", bundle)
		}
		return mode, ok
	}
	t.Cleanup(func() { playerPlaybackMode = saved })
	return &calls
}

func song(title, artist, album string) map[string][]string {
	return map[string][]string{"title": {title}, "artist": {artist}, "album": {album}}
}

// 四首一张专辑 + 一首别的专辑;第二首在放。
func cogBasicList() []cogFixture {
	return []cogFixture{
		{pk: 1, playlist: 1, idx: 0, shuffle: 3, file: "a.flac", tags: song("A", "Band", "One")},
		{pk: 2, playlist: 1, idx: 1, shuffle: 0, file: "b.flac", tags: song("B", "Band", "One"), cur: true},
		{pk: 3, playlist: 1, idx: 2, shuffle: 4, file: "c.flac", tags: song("C", "Band", "One")},
		{pk: 4, playlist: 1, idx: 3, shuffle: 1, file: "d.flac", tags: song("D", "Band", "one")},
		{pk: 5, playlist: 1, idx: 4, shuffle: 2, file: "e.flac", tags: song("E", "Other", "Two")},
	}
}

func cogTitles(res []upcomingTrack) string {
	var s []string
	for _, r := range res {
		s = append(s, r.title)
	}
	return strings.Join(s, ",")
}

func TestCogUpcomingFollowsPrefsModes(t *testing.T) {
	cases := []struct {
		name, prefs string
		n           int
		want        string
		ok          bool
	}{
		// 偏好里没写过:Cog 的默认是列表循环、不随机,放到最后接回开头。
		{"默认列表循环", "", 6, "C,D,E,A", true},
		{"不循环到末尾停", "<key>repeat</key><integer>0</integer>", 6, "C,D,E", true},
		{"单曲循环不预取", "<key>repeat</key><integer>1</integer>", 6, "", true},
		// 专辑名不分大小写;D 之后 E 是别的专辑,回到这张专辑开头 A,再往下就是 B 自己,到此为止。
		{"专辑循环回到专辑开头", "<key>repeat</key><integer>2</integer>", 6, "C,D,A", true},
		// 随机按存下的 ZSHUFFLEINDEX:B 是 0,接着 1(D)、2(E)、3(A)、4(C),放完不接(列表循环会现洗一份新顺序)。
		{"随机按存下的顺序", "<key>shuffle</key><integer>2</integer><key>repeat</key><integer>3</integer>", 6, "D,E,A,C", true},
		{"整张专辑随机同样按存下的顺序", "<key>shuffle</key><integer>1</integer>", 2, "D,E", true},
		{"放完这首就停的开关", "<key>alwaysStopAfterCurrent</key><true/>", 6, "", true},
		{"只要两首", "", 2, "C,D", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withCogDB(t, cogBasicList())
			withCogPrefs(t, c.prefs)
			calls := withCogAppMode(t, playerModeList, true)
			res, ok := cogUpcoming("Band", "B", c.n)
			if ok != c.ok || cogTitles(res) != c.want {
				t.Errorf("得到 %q ok=%v,期望 %q ok=%v", cogTitles(res), ok, c.want, c.ok)
			}
			if *calls != 0 {
				t.Errorf("偏好读得到时不该再请 App 读菜单(问了 %d 次)", *calls)
			}
		})
	}
}

func TestCogUpcomingFallsBackToAppMode(t *testing.T) {
	cases := []struct {
		mode string
		ok   bool
		want string
	}{
		{playerModeRepeatAll, true, "C,D,E,A"},
		{playerModeList, true, "C,D,E"},
		{playerModeRepeatOne, true, ""},
		{playerModeShuffle, true, "D,E,A,C"},
		// App 也读不到:按不循环取。
		{"", false, "C,D,E"},
	}
	for _, c := range cases {
		withCogDB(t, cogBasicList())
		withCogPrefs(t, "-")
		calls := withCogAppMode(t, c.mode, c.ok)
		res, ok := cogUpcoming("Band", "B", 6)
		if !ok || cogTitles(res) != c.want {
			t.Errorf("App 读到 %q(%v):得到 %q ok=%v,期望 %q", c.mode, c.ok, cogTitles(res), ok, c.want)
		}
		if *calls != 1 {
			t.Errorf("偏好读不到时该请 App 读一次菜单,问了 %d 次", *calls)
		}
	}
}

func TestCogUpcomingQueueComesFirst(t *testing.T) {
	list := cogBasicList()
	// 插队:先 E 再另一个列表里的 X,放完插队从 X 所在列表接着走(X 后面是 Y)。
	list[4].queued, list[4].qpos = true, 1
	list = append(list,
		cogFixture{pk: 6, playlist: 2, idx: 0, shuffle: 0, file: "x.flac", tags: song("X", "Solo", "Three"), queued: true, qpos: 0},
		cogFixture{pk: 7, playlist: 2, idx: 1, shuffle: 1, file: "y.flac", tags: song("Y", "Solo", "Three")})
	list[0], list[5] = list[5], list[0]
	withCogDB(t, list)
	withCogPrefs(t, "<key>repeat</key><integer>0</integer>")
	withCogAppMode(t, "", false)
	res, ok := cogUpcoming("Band", "B", 4)
	if !ok || cogTitles(res) != "X,E" {
		// E 在第二个插队位置,E 是列表 1 的最后一首、不循环,插队放完就停。
		t.Errorf("插队:得到 %q ok=%v,期望 X,E", cogTitles(res), ok)
	}
	list[4].queued = false
	withCogDB(t, list)
	if res, ok := cogUpcoming("Band", "B", 3); !ok || cogTitles(res) != "X,Y" {
		t.Errorf("插队放完从最后一条插队的列表接着走:得到 %q ok=%v,期望 X,Y", cogTitles(res), ok)
	}
	// 正在放的这条自己还带着插队标记:不算进插队列表。
	list[1].queued, list[1].qpos = true, -1
	withCogDB(t, list)
	if res, ok := cogUpcoming("Band", "B", 3); !ok || cogTitles(res) != "X,Y" {
		t.Errorf("当前条带插队标记:得到 %q ok=%v,期望 X,Y", cogTitles(res), ok)
	}
}

func TestCogUpcomingShuffleIndexWithGap(t *testing.T) {
	// 随机顺序有空号(删过一条):Cog 拿 shuffleIndex + 1 当排好的随机顺序里的下标,A(3)排第三,下标 4 越界,放完就停。
	list := cogBasicList()
	list = list[:4]
	list[1].cur, list[0].cur = false, true
	withCogDB(t, list)
	withCogPrefs(t, "<key>shuffle</key><integer>2</integer><key>repeat</key><integer>0</integer>")
	withCogAppMode(t, "", false)
	if res, ok := cogUpcoming("Band", "A", 3); !ok || len(res) != 0 {
		t.Errorf("随机顺序有空号:得到 %q ok=%v,期望空且不退回", cogTitles(res), ok)
	}
}

func TestCogUpcomingFindsCurrentEntry(t *testing.T) {
	withCogPrefs(t, "<key>repeat</key><integer>0</integer>")
	withCogAppMode(t, "", false)

	// 库里标着在放的那条是异步存的,换歌那一拍可能还是上一首:歌名歌手对不上就退回。
	withCogDB(t, cogBasicList())
	if res, ok := cogUpcoming("Band", "C", 3); ok {
		t.Errorf("在放的那条对不上 App 报的歌,该退回同专辑预取,得到 %q", cogTitles(res))
	}

	// App 报了当前文件:按文件认,不看库里标着哪条。同一个文件进了两次列表,取标着在放的那条。
	list := cogBasicList()
	list = append(list, cogFixture{pk: 8, playlist: 1, idx: 5, shuffle: 5, file: "c.flac", tags: song("C", "Band", "One")})
	list[1].cur, list[2].cur = false, true
	withCogDB(t, list)
	t.Cleanup(func() { noteLocalFileCurrentTrack("", "", "", "") })
	noteLocalFileCurrentTrack(cogBundleID, "Band", "C", "/Music/c.flac")
	if res, ok := cogUpcoming("Band", "C", 2); !ok || cogTitles(res) != "D,E" {
		t.Errorf("按文件认:得到 %q ok=%v,期望 D,E", cogTitles(res), ok)
	}
	list[2].cur = false
	list[5].cur = true
	withCogDB(t, list)
	if res, ok := cogUpcoming("Band", "C", 2); !ok || cogTitles(res) != "" {
		t.Errorf("同一文件两条、标着在放的是最后那条:得到 %q ok=%v,期望没有后续", cogTitles(res), ok)
	}
	noteLocalFileCurrentTrack(cogBundleID, "Band", "C", "/Music/zzz.flac")
	if _, ok := cogUpcoming("Band", "C", 2); ok {
		t.Errorf("当前文件不在列表里,该退回")
	}

	// 两条都标着在放(库写坏了):不猜。
	noteLocalFileCurrentTrack("", "", "", "")
	list = cogBasicList()
	list[0].cur = true
	withCogDB(t, list)
	if _, ok := cogUpcoming("Band", "B", 2); ok {
		t.Errorf("两条标着在放时该退回")
	}
}

func TestCogUpcomingSkipsWhatItCannotName(t *testing.T) {
	withCogPrefs(t, "<key>repeat</key><integer>0</integer>")
	withCogAppMode(t, "", false)
	list := []cogFixture{
		{pk: 1, playlist: 1, idx: 0, file: "now.flac", tags: song("Now", "Band", "One"), cur: true},
		// 没写标签:Cog 报文件名,App 按文件名拆,这里不猜。
		{pk: 2, playlist: 1, idx: 1, file: "Untagged Song.wav", tags: map[string][]string{"encoder": {"Lavf"}}},
		{pk: 3, playlist: 1, idx: 2, file: "noartist.flac", tags: map[string][]string{"title": {"Lonely"}}},
		{pk: 4, playlist: 1, idx: 3, file: "deleted.flac", tags: song("Gone", "Band", "One"), deleted: true},
		{pk: 5, playlist: 1, idx: 4, file: "multi.flac", tags: map[string][]string{"title": {"Duet"}, "artist": {"A", "B"}}},
		{pk: 6, playlist: 1, idx: 5, file: "nometa.flac"},
		{pk: 7, playlist: 1, idx: 6, file: "Band - Titled By Name.flac", tags: map[string][]string{"artist": {"Band"}}},
		// Big5 标签被当成 Latin-1 读出来的样子(真机 Cog 报给系统的就是这串)。
		{pk: 8, playlist: 1, idx: 7, file: "big5.mp3", tags: song("ÁcÅéºq¦W´ú¸Õ", "´ú¸Õºq¤â", "")},
	}
	withCogDB(t, list)
	res, ok := cogUpcoming("Band", "Now", 10)
	if !ok || cogTitles(res) != "Duet" {
		t.Fatalf("得到 %q ok=%v,期望只剩 Duet", cogTitles(res), ok)
	}
	// 多位歌手按 Cog 的 readAllValuesAsString 用「, 」连起来,跟它报给系统的一致。
	if res[0].artist != "A, B" || res[0].path != "/Music/multi.flac" || res[0].duration != 100 {
		t.Errorf("Duet 解出 %+v", res[0])
	}

	// 放完这一条停(ZSTOPAFTER):没有要预取的,也不退回。
	list[0].stop = true
	withCogDB(t, list)
	if res, ok := cogUpcoming("Band", "Now", 5); !ok || len(res) != 0 {
		t.Errorf("放完这条就停:得到 %q ok=%v,期望空且不退回", cogTitles(res), ok)
	}
}

func TestCogUpcomingUnsavedShuffleUsesWholeList(t *testing.T) {
	// 随机顺序还没存过(ZSHUFFLEINDEX 全是 0):Cog 现洗,猜不到顺序,从整份列表里挑。
	list := cogBasicList()
	for i := range list {
		list[i].shuffle = 0
	}
	withCogDB(t, list)
	withCogPrefs(t, "<key>shuffle</key><integer>2</integer>")
	withCogAppMode(t, "", false)
	res, ok := cogUpcoming("Band", "B", 3)
	if !ok || len(res) == 0 {
		t.Fatalf("得到 %q ok=%v", cogTitles(res), ok)
	}
	for _, r := range res {
		if r.title == "B" {
			t.Errorf("候选里不该有在放的这首")
		}
	}
}

func TestCogUpcomingWithoutDB(t *testing.T) {
	withCogPrefs(t, "")
	withCogAppMode(t, "", false)
	saved := cogUpcomingOverride
	cogUpcomingOverride = filepath.Join(t.TempDir(), "nope.sqlite")
	t.Cleanup(func() { cogUpcomingOverride = saved })
	if _, ok := cogUpcoming("Band", "B", 3); ok {
		t.Errorf("读不到库时该退回同专辑预取")
	}
	// 单曲循环不用读库就知道没有要预取的。
	withCogPrefs(t, "<key>repeat</key><integer>1</integer>")
	if res, ok := cogUpcoming("Band", "B", 3); !ok || len(res) != 0 {
		t.Errorf("单曲循环:得到 %q ok=%v", cogTitles(res), ok)
	}
}

func TestCogArchivedDictXML(t *testing.T) {
	got, err := cogArchivedDictXML([]byte(cogArchiveXML(map[string][]string{"title": {"Ti & <tle>"}, "artist": {"A", "B"}, "encoder": {"x"}})))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got["title"], "|") != "Ti & <tle>" || strings.Join(got["artist"], "|") != "A|B" || len(got) != 3 {
		t.Errorf("解出 %v", got)
	}
	if _, err := cogArchivedDictXML([]byte(`<?xml version="1.0"?><plist version="1.0"><dict><key>$objects</key><array><string>$null</string><string>x</string></array><key>$top</key><dict><key>root</key><dict><key>CF$UID</key><integer>1</integer></dict></dict></dict></plist>`)); err == nil {
		t.Errorf("根不是字典时该报错")
	}
	tags := cogTagsFrom(map[string][]string{"encoder": {"x"}}, "/Music/Song Name.wav")
	if tags.title != "Song Name.wav" || tags.titleTagged {
		t.Errorf("没有歌名标签时用带扩展名的文件名:%+v", tags)
	}
}

func TestCogModesFromPrefsXML(t *testing.T) {
	m, ok := cogModesFromPrefsXML([]byte(`<?xml version="1.0"?><plist version="1.0"><dict><key>other</key><string>x</string></dict></plist>`))
	if !ok || m.repeat != cogRepeatAll || m.shuffle != cogShuffleOff || m.stopAfterAll {
		t.Errorf("没写过时按 Cog 的默认值:%+v", m)
	}
	m, _ = cogModesFromPrefsXML([]byte(`<?xml version="1.0"?><plist version="1.0"><dict><key>repeat</key><integer>9</integer><key>shuffle</key><integer>1</integer></dict></plist>`))
	if m.repeat != cogRepeatAll || m.shuffle != 1 {
		t.Errorf("越界的 repeat 不认、按默认:%+v", m)
	}
	if _, ok := cogModesFromPrefsXML([]byte("garbage")); ok {
		t.Errorf("读不成 plist 该 ok=false")
	}
}

func TestCogQueueStampFollowsQueuedRows(t *testing.T) {
	cogQueueStampMemo.Lock()
	cogQueueStampMemo.file, cogQueueStampMemo.stamp = "", ""
	cogQueueStampMemo.Unlock()
	list := cogBasicList()
	withCogDB(t, list)
	empty := cogQueueStamp()
	if empty == "" {
		t.Fatal("读得到库时标记不该是空串")
	}
	list[4].queued, list[4].qpos = true, 0
	withCogDB(t, list)
	queued := cogQueueStamp()
	if queued == empty {
		t.Errorf("插队以后标记该变")
	}
	if again := cogQueueStamp(); again != queued {
		t.Errorf("文件没变时标记不变:%q → %q", queued, again)
	}
}
