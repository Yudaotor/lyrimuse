package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Cog 的播放列表:脚本接口只给当前那一条,列表存在它沙盒容器里的 CoreData 库(DataModel.sqlite,WAL 模式)。
// ZPLAYLISTENTRY 每行一条:ZPLAYLIST 属于哪个列表、ZINDEX 列表顺序、ZSHUFFLEINDEX 随机顺序、ZCURRENT 在放的那条(换歌当场
// 存盘)、ZQUEUED / ZQUEUEPOSITION 插队列表(跨列表共一份)、ZSTOPAFTER 放完这条停、ZDELETED 已从列表移除;歌名歌手专辑在
// ZMETADATABLOB 里,是 NSKeyedArchiver 归档的字典,每个键对应一组字符串,Cog 报给系统时用「, 」连起来,没有歌名标签时报
// 文件名。下一首按它 PlaybackOrder 的顺序推:放完停 → 单曲循环 → 插队列表 → 随机顺序 → 列表顺序(专辑循环在专辑末尾回到
// 专辑开头、列表循环在列表末尾回到开头)。随机、循环两档先读它偏好里的 repeat / shuffle,读不到再请 App 读菜单上打勾的那项
// (playerPlaybackMode,读不出专辑循环)。只由引擎读,理由同 voxqueue.go。见 02 章决策 275。

// cogUpcomingOverride / cogPrefsOverride:测试用,非空时代替真实的库、偏好路径。
var (
	cogUpcomingOverride string
	cogPrefsOverride    string
)

const cogQueryTimeout = 4 * time.Second

// cogDecodeLimit:一次最多解几条元数据归档(每条起一个 plutil)。专辑循环往回找专辑开头时用得上,防长列表里一路解下去。
const cogDecodeLimit = 64

// Cog 偏好里 repeat、shuffle 两个整数的取值(CogPlaylist 的 PlaylistRepeatMode、PlaylistShuffleMode)。没写过时用它注册的
// 默认值:列表循环、不随机。
const (
	cogRepeatNone  = 0
	cogRepeatOne   = 1
	cogRepeatAlbum = 2
	cogRepeatAll   = 3
	cogShuffleOff  = 0
)

// cogEntriesSQL:还在列表里、有文件地址的全部条目。列名是 CoreData 按属性生成的,Cog 换了数据模型会对不上,
// 那时 sqlite3 报 no such column,按解析器漂移记下。
const cogEntriesSQL = `SELECT Z_PK AS pk, ZPLAYLIST AS playlist, ZINDEX AS idx, ZSHUFFLEINDEX AS shuffle, ZCURRENT AS cur,
ZQUEUED AS queued, ZQUEUEPOSITION AS qpos, ZSTOPAFTER AS stop, ZURLSTRING AS url, ZTOTALFRAMES AS frames, ZSAMPLERATE AS rate
FROM ZPLAYLISTENTRY WHERE (ZDELETED IS NULL OR ZDELETED = 0) AND ZURLSTRING IS NOT NULL AND ZURLSTRING != ''`

type cogEntry struct {
	PK       int64   `json:"pk"`
	Playlist int64   `json:"playlist"`
	Index    int64   `json:"idx"`
	Shuffle  int64   `json:"shuffle"`
	Current  int     `json:"cur"`
	Queued   int     `json:"queued"`
	QueuePos int64   `json:"qpos"`
	Stop     int     `json:"stop"`
	URL      string  `json:"url"`
	Frames   float64 `json:"frames"`
	Rate     float64 `json:"rate"`
}

// cogTags:一条的歌名、歌手、专辑,写法跟 Cog 报给系统的一致。titleTagged = 歌名来自标签(不是文件名)。
type cogTags struct {
	title, artist, album string
	titleTagged          bool
}

// cogModes:随机、循环两档。shuffle 非零就是随机(整张专辑随机也一样按存下的随机顺序放)。
type cogModes struct {
	repeat, shuffle int
	stopAfterAll    bool
}

func cogDataPath(rel string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return otherAppContainer(filepath.Join(home, "Library/Containers/org.cogx.cog/Data/Library", rel))
}

func cogUpcomingPath() string {
	if cogUpcomingOverride != "" {
		return cogUpcomingOverride
	}
	return cogDataPath("Application Support/Cog/DataModel.sqlite")
}

func cogPrefsPath() string {
	if cogPrefsOverride != "" {
		return cogPrefsOverride
	}
	return cogDataPath("Preferences/org.cogx.cog.plist")
}

// cogUpcoming:Cog 接下来会放的几首。当前这条按 App 报的当前文件认,没有当前文件时认库里标着在放的那条、歌名歌手要对得上;
// 认不出、读不到库时 ok=false,退回同专辑预取。单曲循环、放完这条就停时没有要预取的(nil, true)。
func cogUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	modes, ok := cogReadModes()
	if ok && (modes.repeat == cogRepeatOne || modes.stopAfterAll) {
		return nil, true
	}
	rows, rowsOK := cogEntries()
	if !rowsOK {
		return nil, false
	}
	path := cogUpcomingPath()
	tags := func(pks []int64) map[int64]cogTags { return cogEntryTags(path, pks) }
	cur := cogCurrentIndex(rows, localFileCurrentPath(artist, title), artist, title, tags)
	if cur < 0 {
		return nil, false
	}
	if rows[cur].Stop != 0 {
		return nil, true
	}
	if !ok {
		modes = cogModes{repeat: cogRepeatNone, shuffle: cogShuffleOff}
	}
	plan, unknownShuffle := cogNextEntries(rows, cur, modes, n, tags)
	if unknownShuffle && len(plan) == 0 {
		at := cogPlaylistRows(rows, rows[cur].Playlist, false)
		pos := cogPosition(at, rows[cur].PK)
		decoded := tags(cogPKs(at, cogDecodeLimit))
		return shuffleCandidates(len(at), pos, func(i int) (upcomingTrack, bool) { return cogTrack(at[i], decoded) }), true
	}
	decoded := tags(cogPKs(plan, len(plan)))
	res := make([]upcomingTrack, 0, len(plan))
	for _, r := range plan {
		if t, ok := cogTrack(r, decoded); ok {
			res = append(res, t)
		}
	}
	if len(res) == 0 {
		return nil, len(plan) == 0
	}
	return res, true
}

// cogNextEntries 按 Cog 的顺序推当前这条之后的至多 n 条:先插队列表,再从最后一条插队的(没有就是当前这条)所在列表接着走,
// 随机按存下的随机顺序、放到最后停(列表循环时它会现洗一份新顺序,猜不到);列表顺序在末尾按循环档回到开头或专辑开头。
// 随机顺序还没存过(ZSHUFFLEINDEX 有重复,Cog 当场现洗)时 unknownShuffle=true。tags 只在专辑循环时用来认专辑。纯函数。
func cogNextEntries(rows []cogEntry, cur int, modes cogModes, n int, tags func([]int64) map[int64]cogTags) (plan []cogEntry, unknownShuffle bool) {
	var queue []cogEntry
	for _, r := range rows {
		if r.Queued != 0 && r.PK != rows[cur].PK {
			queue = append(queue, r)
		}
	}
	sort.SliceStable(queue, func(i, j int) bool { return queue[i].QueuePos < queue[j].QueuePos })
	from := rows[cur]
	for _, r := range queue {
		if len(plan) >= n {
			return plan, false
		}
		plan = append(plan, r)
		from = r
	}
	if len(plan) >= n {
		return plan, false
	}
	list := cogPlaylistRows(rows, from.Playlist, modes.shuffle != cogShuffleOff)
	pos := cogPosition(list, from.PK)
	if pos < 0 {
		return plan, false
	}
	if modes.shuffle != cogShuffleOff {
		seen := map[int64]bool{}
		for _, r := range list {
			if seen[r.Shuffle] {
				return plan, true
			}
			seen[r.Shuffle] = true
		}
		// Cog 按 shuffleIndex + 1 当随机顺序里的位置取下一条,不按这条在排好的顺序里排第几。
		for i := int(from.Shuffle) + 1; i >= 0 && i < len(list) && len(plan) < n; i++ {
			plan = append(plan, list[i])
		}
		return plan, false
	}
	if modes.repeat == cogRepeatAlbum {
		return append(plan, cogAlbumRepeatNext(list, pos, n-len(plan), tags)...), false
	}
	for k := 1; k < len(list) && len(plan) < n; k++ {
		i := pos + k
		if i >= len(list) {
			if modes.repeat != cogRepeatAll {
				break
			}
			i -= len(list)
		}
		plan = append(plan, list[i])
	}
	return plan, false
}

// cogAlbumRepeatNext:专辑循环时 pos 之后的至多 n 条(不含绕回来的 pos 自己)。下一条专辑名(不分大小写)跟当前这条不同、
// 或到了列表末尾,就回到这张专辑在列表里第一次出现的那条;当前这条没有专辑名时一直放它,没有要预取的(同 Cog)。
// 只解 pos 前后 cogDecodeLimit 条,窗口外的当作专辑边界。纯函数。
func cogAlbumRepeatNext(list []cogEntry, pos, n int, tags func([]int64) map[int64]cogTags) []cogEntry {
	if n <= 0 {
		return nil
	}
	lo := max(0, pos-cogDecodeLimit/2)
	hi := min(len(list), lo+cogDecodeLimit)
	decoded := tags(cogPKs(list[lo:hi], hi-lo))
	album := func(i int) string {
		if i < lo || i >= hi {
			return ""
		}
		return strings.ToLower(decoded[list[i].PK].album)
	}
	want := album(pos)
	if want == "" {
		return nil
	}
	start := pos
	for i := lo; i < pos; i++ {
		if album(i) == want {
			start = i
			break
		}
	}
	var res []cogEntry
	for c := pos; len(res) < n; {
		if c+1 < hi && album(c+1) == want {
			c++
		} else {
			c = start
		}
		if c == pos {
			break
		}
		res = append(res, list[c])
	}
	return res
}

// cogPlaylistRows:某个列表的全部条目,按列表顺序或随机顺序排。
func cogPlaylistRows(rows []cogEntry, playlist int64, byShuffle bool) []cogEntry {
	var list []cogEntry
	for _, r := range rows {
		if r.Playlist == playlist {
			list = append(list, r)
		}
	}
	sort.SliceStable(list, func(i, j int) bool {
		if byShuffle {
			return list[i].Shuffle < list[j].Shuffle
		}
		return list[i].Index < list[j].Index
	})
	return list
}

// cogCurrentIndex:在放的那条。有当前文件时按文件地址认(同一个文件进了几次列表,取标着在放的那条);没有时认标着在放的
// 唯一一条,它的歌名歌手要对得上 App 报的(库里那一位是异步存的,换歌那一拍可能还是上一首)。认不出为 -1。
func cogCurrentIndex(rows []cogEntry, currentPath, artist, title string, tags func([]int64) map[int64]cogTags) int {
	if currentPath != "" {
		hit := -1
		for i, r := range rows {
			if voxRowPath(r.URL) != currentPath {
				continue
			}
			if hit < 0 || (r.Current != 0 && rows[hit].Current == 0) {
				hit = i
			}
		}
		return hit
	}
	hit := -1
	for i, r := range rows {
		if r.Current != 0 {
			if hit >= 0 {
				return -1
			}
			hit = i
		}
	}
	if hit < 0 {
		return -1
	}
	t, ok := tags([]int64{rows[hit].PK})[rows[hit].PK]
	if !ok || newQueueCurrentMatcher(artist, title).match(t.artist, t.title) == queueNoMatch {
		return -1
	}
	return hit
}

// cogTrack:一条换成预取的曲目。歌名不是来自标签的(App 按文件名拆,这里不猜)、没有歌手的、像乱码的跳过,理由同 voxRowTrack。
func cogTrack(r cogEntry, decoded map[int64]cogTags) (upcomingTrack, bool) {
	t, ok := decoded[r.PK]
	path := voxRowPath(r.URL)
	if !ok || path == "" || !t.titleTagged || t.artist == "" || looksLatin1Mojibake(t.title+t.artist+t.album) {
		return upcomingTrack{}, false
	}
	var dur float64
	if r.Rate > 0 && r.Frames > 0 {
		dur = r.Frames / r.Rate
	}
	return upcomingTrack{artist: t.artist, title: t.title, album: t.album, duration: dur, path: path}, true
}

func cogPosition(list []cogEntry, pk int64) int {
	for i, r := range list {
		if r.PK == pk {
			return i
		}
	}
	return -1
}

func cogPKs(rows []cogEntry, limit int) []int64 {
	pks := make([]int64, 0, min(limit, len(rows)))
	for _, r := range rows {
		if len(pks) >= limit {
			break
		}
		pks = append(pks, r.PK)
	}
	return pks
}

func cogEntries() ([]cogEntry, bool) {
	path := cogUpcomingPath()
	if path == "" {
		return nil, false
	}
	if _, err := os.Stat(path); err != nil {
		noteLocalCacheDenied("cog", path, err)
		return nil, false
	}
	out, err := cogQuery(path, cogEntriesSQL)
	if err != nil {
		noteLocalCacheReadFailure("cog", path)
		if sqliteSchemaMismatch(err) {
			noteParserUnrecognized("cog-local-queue", sqliteErrorDetail(err))
		}
		return nil, false
	}
	noteLocalCacheReadable("cog")
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return nil, false
	}
	var rows []cogEntry
	if err := json.Unmarshal(trimmed, &rows); err != nil {
		noteParserUnrecognized("cog-local-queue", err.Error())
		return nil, false
	}
	return rows, true
}

// cogQuery 只读查 Cog 的库。WAL 模式:先按 mode=ro 打开,读得到还没并回主库的改动;Cog 退出时并完、删了 -wal 的话只读
// 连接建不了它、打不开,这时改用 immutable=1。别退回读写连接,那会在 Cog 的容器里建文件。理由同 qqRRCacheRows。
func cogQuery(path, sql string) ([]byte, error) {
	run := func(query string) ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.Background(), cogQueryTimeout)
		defer cancel()
		uri := (&neturl.URL{Scheme: "file", Path: path, RawQuery: query}).String()
		return exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, sql).Output()
	}
	out, err := run("mode=ro")
	if err == nil {
		return out, nil
	}
	if _, walErr := os.Stat(path + "-wal"); walErr == nil {
		return nil, err
	}
	return run("immutable=1")
}

// cogEntryTags 解这几条的元数据归档。解不开的不在结果里。
func cogEntryTags(path string, pks []int64) map[int64]cogTags {
	res := map[int64]cogTags{}
	if path == "" || len(pks) == 0 {
		return res
	}
	ids := make([]string, len(pks))
	for i, pk := range pks {
		ids[i] = strconv.FormatInt(pk, 10)
	}
	sql := "SELECT Z_PK AS pk, ZURLSTRING AS url, hex(ZMETADATABLOB) AS blob FROM ZPLAYLISTENTRY WHERE Z_PK IN (" + strings.Join(ids, ",") + ")"
	out, err := cogQuery(path, sql)
	if err != nil {
		return res
	}
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return res
	}
	var parsed []struct {
		PK   int64  `json:"pk"`
		URL  string `json:"url"`
		Blob string `json:"blob"`
	}
	if json.Unmarshal(trimmed, &parsed) != nil {
		return res
	}
	for _, p := range parsed {
		blob, err := hex.DecodeString(p.Blob)
		if err != nil {
			continue
		}
		values, ok := cogArchivedDict(blob)
		if !ok {
			continue
		}
		res[p.PK] = cogTagsFrom(values, voxRowPath(p.URL))
	}
	return res
}

// cogTagsFrom:按 Cog 的 readAllValuesAsString 拼歌名、歌手、专辑;没有歌名时用文件名(带扩展名)。纯函数。
func cogTagsFrom(values map[string][]string, path string) cogTags {
	join := func(key string) string { return strings.Join(values[key], ", ") }
	t := cogTags{title: join("title"), artist: join("artist"), album: join("album")}
	t.titleTagged = t.title != ""
	if !t.titleTagged && path != "" {
		t.title = filepath.Base(path)
	}
	return t
}

// cogArchivedDict 解开一份 NSKeyedArchiver 归档的字典(键是字符串,值是一组字符串或单个字符串)。没有元数据(空 blob)
// 算解开了、结果为空;形状不对 ok=false 并记解析器漂移。
func cogArchivedDict(blob []byte) (map[string][]string, bool) {
	if len(blob) == 0 {
		return map[string][]string{}, true
	}
	ctx, cancel := context.WithTimeout(context.Background(), cogQueryTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", "-")
	cmd.Stdin = bytes.NewReader(blob)
	out, err := cmd.Output()
	if err != nil {
		noteParserUnrecognized("cog-metadata", "plutil could not read the entry")
		return nil, false
	}
	values, err := cogArchivedDictXML(out)
	if err != nil {
		noteParserUnrecognized("cog-metadata", err.Error())
		return nil, false
	}
	noteParserRecognized("cog-metadata")
	return values, true
}

// cogArchivedDictXML:cogArchivedDict 的纯函数部分,输入是 plutil 转出来的 XML。
func cogArchivedDictXML(data []byte) (map[string][]string, error) {
	root, err := parsePlistXML(data)
	if err != nil {
		return nil, err
	}
	rootMap, _ := root.(map[string]any)
	objs, _ := rootMap["$objects"].([]any)
	top, _ := rootMap["$top"].(map[string]any)
	dict, ok := qqDeref(objs, top["root"]).(map[string]any)
	if !ok {
		return nil, fmt.Errorf("metadata root is not a dictionary")
	}
	keys, _ := dict["NS.keys"].([]any)
	vals, _ := dict["NS.objects"].([]any)
	if len(keys) != len(vals) {
		return nil, fmt.Errorf("metadata dictionary has %d keys and %d values", len(keys), len(vals))
	}
	res := map[string][]string{}
	for i := range keys {
		key, ok := qqDeref(objs, keys[i]).(string)
		if !ok {
			continue
		}
		switch v := qqDeref(objs, vals[i]).(type) {
		case string:
			res[key] = []string{v}
		case map[string]any:
			items, _ := v["NS.objects"].([]any)
			for _, item := range items {
				if s, ok := qqDeref(objs, item).(string); ok {
					res[key] = append(res[key], s)
				}
			}
		}
	}
	return res, nil
}

// cogReadModes:随机、循环两档。先读 Cog 的偏好(能分出专辑循环、随机时的循环档);读不到再请 App 读菜单。
func cogReadModes() (cogModes, bool) {
	if m, ok := cogModesFromPrefs(cogPrefsPath()); ok {
		return m, true
	}
	mode, ok := playerPlaybackMode(cogBundleID)
	if !ok {
		return cogModes{}, false
	}
	return cogModesFromPlayerMode(mode), true
}

// cogModesFromPlayerMode:App 读到的档换成 Cog 的两档。App 把专辑循环报成列表循环、随机时不报循环档。纯函数。
func cogModesFromPlayerMode(mode string) cogModes {
	switch mode {
	case playerModeShuffle:
		return cogModes{repeat: cogRepeatNone, shuffle: 2}
	case playerModeRepeatOne:
		return cogModes{repeat: cogRepeatOne}
	case playerModeRepeatAll:
		return cogModes{repeat: cogRepeatAll}
	}
	return cogModes{repeat: cogRepeatNone}
}

func cogModesFromPrefs(path string) (cogModes, bool) {
	if path == "" {
		return cogModes{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			noteLocalCacheDenied("cog", path, err)
		}
		return cogModes{}, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), cogQueryTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", "-")
	cmd.Stdin = bytes.NewReader(data)
	out, err := cmd.Output()
	if err != nil {
		return cogModes{}, false
	}
	return cogModesFromPrefsXML(out)
}

// cogModesFromPrefsXML:偏好里的 repeat、shuffle、alwaysStopAfterCurrent;没写过的键用 Cog 注册的默认值。纯函数。
func cogModesFromPrefsXML(data []byte) (cogModes, bool) {
	root, err := parsePlistXML(data)
	if err != nil {
		return cogModes{}, false
	}
	prefs, ok := root.(map[string]any)
	if !ok {
		return cogModes{}, false
	}
	m := cogModes{repeat: cogRepeatAll, shuffle: cogShuffleOff}
	if v, ok := plistInt(prefs["repeat"]); ok && v >= cogRepeatNone && v <= cogRepeatAll {
		m.repeat = v
	}
	if v, ok := plistInt(prefs["shuffle"]); ok && v >= 0 && v <= 2 {
		m.shuffle = v
	}
	if b, ok := prefs["alwaysStopAfterCurrent"].(bool); ok {
		m.stopAfterAll = b
	}
	return m, true
}

func plistInt(v any) (int, bool) {
	switch x := v.(type) {
	case int64:
		return int(x), true
	case int:
		return x, true
	case float64:
		return int(x), x == float64(int(x))
	}
	return 0, false
}

var cogQueueStampMemo struct {
	sync.Mutex
	file, stamp string
}

// cogQueueStamp:插队列表此刻的样子。Cog 放歌时每 10 秒存一次库,按文件改动时刻判会每 10 秒重读一遍;所以文件变了才
// 查一次插队的那几条,拼成标记。读不到为 ""。
func cogQueueStamp() string {
	path := cogUpcomingPath()
	if path == "" {
		return ""
	}
	var file strings.Builder
	for _, p := range []string{path, path + "-wal"} {
		if st, err := os.Stat(p); err == nil {
			fmt.Fprintf(&file, "%d/%d;", st.ModTime().UnixNano(), st.Size())
		}
	}
	cogQueueStampMemo.Lock()
	defer cogQueueStampMemo.Unlock()
	if file.String() == cogQueueStampMemo.file {
		return cogQueueStampMemo.stamp
	}
	out, err := cogQuery(path, `SELECT group_concat(Z_PK || ':' || ZQUEUEPOSITION, ',') AS q FROM (SELECT Z_PK, ZQUEUEPOSITION FROM ZPLAYLISTENTRY
WHERE ZQUEUED = 1 AND (ZDELETED IS NULL OR ZDELETED = 0) ORDER BY ZQUEUEPOSITION)`)
	if err != nil {
		return cogQueueStampMemo.stamp
	}
	stamp := "cog:" + string(bytes.TrimSpace(out))
	if stamp != cogQueueStampMemo.stamp && cogQueueStampMemo.stamp != "" {
		log.Printf("cog upcoming: the queue changed (%s)", strings.TrimPrefix(stamp, "cog:"))
	}
	cogQueueStampMemo.file, cogQueueStampMemo.stamp = file.String(), stamp
	return stamp
}
