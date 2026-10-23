package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// VOX 的播放列表:脚本接口不给,存在它沙盒容器里的 CoreData 库(voxdb.storedata)。免费版只有一个默认列表
// (VXCustomPlaylist,ZISDEFAULT = 1),列表和曲目的对应在 Z_7TRACKS,Z_FOK_10TRACKS 是列表里的先后;
// 随机是个开关,开着时另按一份打乱的顺序放(二进制里有 `shuffled_playlist_array_indexes`),库里的列表顺序不变、开没开读不出,
// 跟 QQ、Pine 一样从换歌行为推断(queueorder.go);循环档由 App 代问(voxRepeating)。只由引擎读:App 读别的 App 的容器会弹
// 「访问其他 App 的数据」,引擎是后台进程,没有完全磁盘访问时只是读不到(02 章决策 151)。见 02 章决策 166。

// voxUpcomingOverride:测试用,非空时代替真实的库路径。
var voxUpcomingOverride string

const voxUpcomingQueryTimeout = 4 * time.Second

// voxUpcomingSQL:默认列表按列表顺序排的全部曲目。表名、列名是 CoreData 按实体编号生成的,VOX 换了数据模型会对不上,
// 那时 sqlite3 报 no such table / column,按解析器漂移记下(noteParserUnrecognized)。
const voxUpcomingSQL = `SELECT t.ZURL AS url, t.ZNAME AS name, t.ZARTISTNAME AS artist, t.ZALBUMNAME AS album, t.ZVX_DURATION AS dur
FROM Z_7TRACKS j
JOIN ZVXLOCALOBJECT t ON t.Z_PK = j.Z_10TRACKS
JOIN ZVXLOCALOBJECT p ON p.Z_PK = j.Z_7PLAYLISTS
WHERE p.ZISDEFAULT = 1
ORDER BY j.Z_FOK_10TRACKS`

type voxUpcomingRow struct {
	URL    string  `json:"url"`
	Name   string  `json:"name"`
	Artist string  `json:"artist"`
	Album  string  `json:"album"`
	Dur    float64 `json:"dur"`
}

func voxUpcomingPath() string {
	if voxUpcomingOverride != "" {
		return voxUpcomingOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.coppertino.Vox/Data/Library/Application Support/Vox/voxdb.storedata")
}

// voxRepeating 问 VOX 此刻的循环档,由 App 代跑(askApp,脚本在 App 侧 PlayerQueryServer,交回
// {"repeating":"off"|"one"|"all"},App 侧 PlayerQueryRepeat)。单测替换它。
var voxRepeating = func() (mode string, ok bool) {
	out, ok := askApp(appQueryRequest{Kind: appQueryVoxRepeat}, appQueryShuffleTimeout)
	if !ok {
		return "", false
	}
	var r struct {
		Repeating string `json:"repeating"`
	}
	if json.Unmarshal([]byte(out), &r) != nil {
		return "", false
	}
	switch r.Repeating {
	case "off", "one", "all":
		return r.Repeating, true
	}
	return "", false
}

// voxUpcoming:VOX 列表里当前这首后面的几首。当前这首按 App 报的当前文件(local_file)在列表里找,找不到再按歌名歌手;
// 读不到库、列表里没有当前这首时 ok=false,退回同专辑预取。单曲循环时下一首还是这首,没有要预取的;列表循环时放到
// 最后接回开头;问不到循环档时按不循环取(02 章决策 167)。
func voxUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	mode, _ := voxRepeating()
	if mode == "one" {
		return nil, true
	}
	rows, ok := voxPlaylistRows()
	if !ok {
		return nil, false
	}
	currentPath := localFileCurrentPath(artist, title)
	if pos := voxCurrentIndex(rows, currentPath, artist, title); pos >= 0 && voxObservePosition(voxListID(rows), pos, len(rows)) {
		return shuffleCandidates(len(rows), pos, func(i int) (upcomingTrack, bool) { return voxRowTrack(rows[i]) }), true
	}
	return voxPickUpcoming(rows, currentPath, artist, title, n, mode == "all")
}

var (
	voxPlayOrderMu   sync.Mutex
	voxPlayOrderLast queueOrder
)

// voxObservePosition 记下这一次的位置,返回此刻是否按随机处理。
func voxObservePosition(list string, pos, size int) (shuffled bool) {
	voxPlayOrderMu.Lock()
	defer voxPlayOrderMu.Unlock()
	prevPos := voxPlayOrderLast.pos
	shuffled, flipped := voxPlayOrderLast.observeWrapping(list, pos, size)
	if flipped {
		log.Printf("vox upcoming: moved from position %d to %d in the playlist, treating playback as shuffled and prefetching from the whole list", prevPos, pos)
	}
	return shuffled
}

// voxListID:列表身份,按每行的文件地址算。加删了歌就重新攒顺序 / 随机的证据。
func voxListID(rows []voxUpcomingRow) string {
	h := sha256.New()
	for _, r := range rows {
		h.Write([]byte(r.URL))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

func voxPlaylistRows() ([]voxUpcomingRow, bool) {
	path := voxUpcomingPath()
	if path == "" {
		return nil, false
	}
	if _, err := os.Stat(path); err != nil {
		noteLocalCacheDenied("vox", path, err)
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), voxUpcomingQueryTimeout)
	defer cancel()
	// mode=ro 的理由同 kugouUpcomingFromSQLite:只读,撞上它写库就直接失败、退回。
	uri := (&neturl.URL{Scheme: "file", Path: path, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, voxUpcomingSQL).Output()
	if err != nil {
		noteLocalCacheReadFailure("vox", path)
		if sqliteSchemaMismatch(err) {
			noteParserUnrecognized("vox-local-queue", sqliteErrorDetail(err))
		}
		return nil, false
	}
	noteLocalCacheReadable("vox")
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return nil, false
	}
	var rows []voxUpcomingRow
	if err := json.Unmarshal(trimmed, &rows); err != nil {
		return nil, false
	}
	return rows, true
}

// voxPickUpcoming:列表里当前这首(`currentPath` 对上文件地址的那一行;没有文件或对不上时按歌名歌手)后面的 n 首。
// 不是本地文件的(网络地址)、歌手一栏空的(没写标签,App 按文件名拆,这里不猜)、像乱码的(GBK 标签被当 Latin-1 读,
// App 会还原、这里不会)跳过:预取一首不会以这个名字播到的歌只是白占解析带宽。放到最后一首时 wrap(列表循环)接回开头,
// 否则到此为止;后面一首都取不到时 ok=false,退回同专辑预取。纯函数。
func voxPickUpcoming(rows []voxUpcomingRow, currentPath, artist, title string, n int, wrap bool) ([]upcomingTrack, bool) {
	pos := voxCurrentIndex(rows, currentPath, artist, title)
	if pos < 0 {
		return nil, false
	}
	res := make([]upcomingTrack, 0, n)
	for k := 1; k < len(rows) && len(res) < n; k++ {
		i := pos + k
		if i >= len(rows) {
			if !wrap {
				break
			}
			i -= len(rows)
		}
		if t, ok := voxRowTrack(rows[i]); ok {
			res = append(res, t)
		}
	}
	return res, len(res) > 0
}

// voxCurrentIndex:当前这首在列表里的位置,先按文件地址,对不上按歌名歌手;找不到为 -1。纯函数。
func voxCurrentIndex(rows []voxUpcomingRow, currentPath, artist, title string) int {
	if currentPath != "" {
		for i, r := range rows {
			if voxRowPath(r.URL) == currentPath {
				return i
			}
		}
	}
	m := newQueueCurrentMatcher(artist, title)
	return queueCurrentIndex(len(rows), -1, func(i int) queueMatch { return m.match(rows[i].Artist, rows[i].Name) })
}

// voxRowTrack:一行换成预取的曲目;猜不准的(见 voxPickUpcoming 头注)ok=false。
func voxRowTrack(r voxUpcomingRow) (upcomingTrack, bool) {
	if voxRowPath(r.URL) == "" || r.Name == "" || r.Artist == "" || looksLatin1Mojibake(r.Name+r.Artist+r.Album) {
		return upcomingTrack{}, false
	}
	return upcomingTrack{artist: r.Artist, title: r.Name, album: r.Album, duration: r.Dur}, true
}

// voxRowPath:库里的文件地址(`file:///…`,百分号编码)换成路径;不是本地文件为 ""。
func voxRowPath(raw string) string {
	u, err := neturl.Parse(raw)
	if err != nil || u.Scheme != "file" {
		return ""
	}
	return u.Path
}

// looksLatin1Mojibake:连着两个 U+0080~U+00FF 的字。GBK / Big5 的汉字被当 Latin-1 读出来就是这样成对出现;
// 带重音的西文名(Cúbicos、Beyoncé)一般不会连着两个。
func looksLatin1Mojibake(s string) bool {
	prev := false
	for _, r := range s {
		cur := r >= 0x80 && r <= 0xFF
		if cur && prev {
			return true
		}
		prev = cur
	}
	return false
}
