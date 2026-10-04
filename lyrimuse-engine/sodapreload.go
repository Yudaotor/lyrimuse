package main

import (
	"bytes"
	"errors"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// 汽水的第二条队列信号:客户端给「接下来要播的歌」预载的音频缓存。
//
// QueueCache(sodalocal.go)只存推荐流和各个听歌模式的队列;从歌单、专辑、「我喜欢」点播时,
// 那条队列只在内存里,本地任何文件都不写(Local Storage / Session Storage / IndexedDB 都解开核对过)。
// 但播放器会**预载**:开始播一条队列时一次缓存后面 5 首的开头,之后每换一首,再缓存往后第 5 首。
// 开着随机也一样,预载的就是打乱后真实要播的那几首 —— 实测一轮 17 次换歌,凡是新建了缓存的都
// 在 5 首之后如期播到,没有一首落空。
//
// 缓存在 `LunaCacheV2/entries.db`:lmdb-js 的库,值是 msgpackr 编码(带「记录结构」扩展)。
// 每条记录是一段音频缓存,形如 {resourceId, info, headers, chunkId, previousAccessTime, size},
// info.trackId 是曲目 id,info.mediaDetail.playable 是完整的曲目对象(歌名 / 歌手 / 专辑 / 时长,
// 跟 QueueCache 里的 playable 同一个结构)。previousAccessTime 是这段缓存建立的时刻(秒),
// 之后真播到它、再次预载它都不会改。
//
// 所以「最近建立的几段缓存」就是接下来要播的那几首。两个缺口:以前就缓存过的歌不会重新建立,
// 预载时不留痕迹(那样的歌多半以前播过、歌词早解析好了);最近几段里也可能混着刚播过的歌。
// 后者无害:预取对已经解析过的歌什么也不做。
//
// 不走 LMDB 的页结构:每条值都以第一个记录结构的定义(`d4 72 40`)开头,直接在文件里找这个
// 起点、逐条解码,解不动的跳过。LMDB 写时复制留下的旧页会解出同一首的旧副本,按曲目 id 去重。

// sodaPreloadOverride 让单测把缓存库指到临时路径。空 = 用真实路径。
var sodaPreloadOverride string

const (
	// sodaPreloadWindow:只看这么久以内建立的缓存。往后第 1 首是 4 次换歌之前预载的,
	// 按一首 4~6 分钟算要留到半小时左右;再往前的只会是早就播过的。
	sodaPreloadWindow = 45 * time.Minute
	// sodaPreloadMaxBytes 防着库文件异常膨胀。实测 8MB 左右。
	sodaPreloadMaxBytes = 64 << 20
)

func sodaPreloadPath() string {
	if sodaPreloadOverride != "" {
		return sodaPreloadOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Application Support/SodaMusic/LunaCacheV2/entries.db")
}

// sodaPreloadedTrack 是一段预载缓存对应的曲目。
type sodaPreloadedTrack struct {
	id       string
	at       int64 // 缓存建立的时刻(秒)
	upcoming upcomingTrack
	albumID  string // 给同专辑兜底找专辑用(sodaalbum.go)
	// 试听段(毫秒),给非会员试听的时长换算用(sodaPreloadPreview);没有就是 0。
	previewStartMs, previewDurMs, fullMs int64
}

var sodaPreloadLogOnce sync.Once

// sodaUpcomingFromPreload 取汽水预载了的、接下来要播的几首(不含正在播的这首),按预载先后排。
func sodaUpcomingFromPreload(artist, title string, n int, now time.Time) ([]upcomingTrack, bool) {
	path := sodaPreloadPath()
	if path == "" {
		return nil, false
	}
	st, err := os.Stat(path)
	if err != nil || st.Size() > sodaPreloadMaxBytes {
		return nil, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	res, ok := pickSodaPreloaded(parseSodaPreloads(raw), artist, title, n, now)
	if ok {
		sodaPreloadLogOnce.Do(func() {
			log.Printf("soda upcoming: the queue is not in QueueCache, reading what the client preloaded instead")
		})
	}
	return res, ok
}

// pickSodaPreloaded 从全部缓存记录里挑出最近建立的 n 首(去掉正在播的这首),再按建立先后排 ——
// 越早预载的越先播。
func pickSodaPreloaded(all []sodaPreloadedTrack, artist, title string, n int, now time.Time) ([]upcomingTrack, bool) {
	cur := loosenEnrichKey(artist + "|" + title)
	since := now.Add(-sodaPreloadWindow).Unix()
	latest := map[string]sodaPreloadedTrack{}
	for _, t := range all {
		if t.at < since || t.at > now.Unix()+60 {
			continue
		}
		if loosenEnrichKey(t.upcoming.artist+"|"+t.upcoming.title) == cur {
			continue
		}
		// 同一首有几段(试听段 / 完整版 / 不同音质),以最早那段为准:那才是它被预载的时刻。
		if old, ok := latest[t.id]; !ok || t.at < old.at {
			latest[t.id] = t
		}
	}
	picked := make([]sodaPreloadedTrack, 0, len(latest))
	for _, t := range latest {
		picked = append(picked, t)
	}
	sort.Slice(picked, func(i, j int) bool {
		if picked[i].at != picked[j].at {
			return picked[i].at > picked[j].at
		}
		return picked[i].id < picked[j].id
	})
	if len(picked) > n {
		picked = picked[:n]
	}
	sort.SliceStable(picked, func(i, j int) bool { return picked[i].at < picked[j].at })
	out := make([]upcomingTrack, 0, len(picked))
	for _, t := range picked {
		out = append(out, t.upcoming)
	}
	return out, len(out) > 0
}

// parseSodaPreloads 从库文件里解出全部音频缓存记录。认不出的记录直接跳过。
func parseSodaPreloads(raw []byte) []sodaPreloadedTrack {
	start := []byte{0xd4, 0x72, 0x40}
	var out []sodaPreloadedTrack
	for off := 0; ; {
		i := bytes.Index(raw[off:], start)
		if i < 0 {
			break
		}
		pos := off + i
		off = pos + 1
		d := msgpackrDecoder{buf: raw, pos: pos}
		v, err := d.value(0)
		if err != nil {
			continue
		}
		if t, ok := sodaPreloadFromRecord(v); ok {
			out = append(out, t)
		}
	}
	return out
}

// sodaPreloadFromRecord 从一条缓存记录里取曲目。曲目对象的 id 必须等于 info.trackId,
// 否则不认(防着结构变了、拿到别的对象)。
func sodaPreloadFromRecord(v any) (sodaPreloadedTrack, bool) {
	rec, _ := v.(map[string]any)
	info, _ := rec["info"].(map[string]any)
	detail, _ := info["mediaDetail"].(map[string]any)
	p, _ := detail["playable"].(map[string]any)
	id, _ := info["trackId"].(string)
	at, okAt := msgpackrInt(rec["previousAccessTime"])
	if id == "" || !okAt || p == nil {
		return sodaPreloadedTrack{}, false
	}
	if pid, _ := p["id"].(string); pid != id {
		return sodaPreloadedTrack{}, false
	}
	name, _ := p["name"].(string)
	name = strings.TrimSpace(name)
	var artists []string
	arr, _ := p["artists"].([]any)
	for _, a := range arr {
		m, _ := a.(map[string]any)
		if s, _ := m["name"].(string); strings.TrimSpace(s) != "" {
			artists = append(artists, strings.TrimSpace(s))
		}
	}
	if name == "" || len(artists) == 0 {
		return sodaPreloadedTrack{}, false
	}
	album, albumID := "", ""
	if m, ok := p["album"].(map[string]any); ok {
		album, _ = m["name"].(string)
		albumID, _ = m["id"].(string)
	}
	ms, _ := msgpackrInt(p["duration"])
	var pvStart, pvDur int64
	if pv, ok := p["preview"].(map[string]any); ok {
		pvStart, _ = msgpackrInt(pv["start"])
		pvDur, _ = msgpackrInt(pv["duration"])
	}
	// 歌手用 "/" 连起来,跟 sodaUpcomingArtist 同一个理由:要跟播放器报的完整串对得上。
	return sodaPreloadedTrack{id: id, at: at, albumID: albumID, previewStartMs: pvStart, previewDurMs: pvDur, fullMs: ms, upcoming: upcomingTrack{
		artist: strings.Join(artists, "/"), title: name, album: strings.TrimSpace(album), duration: float64(ms) / 1000,
	}}, true
}

func msgpackrInt(v any) (int64, bool) {
	switch x := v.(type) {
	case int64:
		return x, true
	case uint64:
		if x > math.MaxInt64 {
			return 0, false
		}
		return int64(x), true
	case float64:
		return int64(x), true
	}
	return 0, false
}

// ---- 试听段 ----

var (
	sodaPreloadIndexMu    sync.Mutex
	sodaPreloadIndexMod   time.Time
	sodaPreloadIndexSize  int64
	sodaPreloadIndexTrack []sodaPreloadedTrack
)

// sodaPreloadPreview 在音频缓存库里找这首的试听段(sodapreview.go 的 sodaPreviewFor 在本地队列没命中、
// 发起搜索之前调它)。正在播的歌一定已经缓存(开播那一刻、或更早被预载时建立),所以换歌那一拍就能
// 同步拿到,不用等搜索。只收 preview 与播放器报的时长对得上的那条(sodaPreviewMatches)。
// 按库文件的修改时间与大小缓存解析结果:库只在换歌时变,每拍都来问也只是一次 stat。
func sodaPreloadPreview(artist, title string, mrDuration float64) (sodaPreview, bool) {
	want := loosenEnrichKey(artist + "|" + title)
	if want == "|" {
		return sodaPreview{}, false
	}
	for _, t := range sodaPreloadIndex() {
		if t.previewDurMs <= 0 || loosenEnrichKey(t.upcoming.artist+"|"+t.upcoming.title) != want {
			continue
		}
		if p, ok := sodaPreviewFromMillis(t.previewStartMs, t.previewDurMs, t.fullMs); ok && sodaPreviewMatches(mrDuration, p) {
			return p, true
		}
	}
	return sodaPreview{}, false
}

func sodaPreloadIndex() []sodaPreloadedTrack {
	path := sodaPreloadPath()
	if path == "" {
		return nil
	}
	st, err := os.Stat(path)
	if err != nil || st.Size() > sodaPreloadMaxBytes {
		return nil
	}
	sodaPreloadIndexMu.Lock()
	defer sodaPreloadIndexMu.Unlock()
	if st.ModTime().Equal(sodaPreloadIndexMod) && st.Size() == sodaPreloadIndexSize {
		return sodaPreloadIndexTrack
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	sodaPreloadIndexMod, sodaPreloadIndexSize = st.ModTime(), st.Size()
	sodaPreloadIndexTrack = parseSodaPreloads(raw)
	return sodaPreloadIndexTrack
}

// ---- msgpackr ----

// msgpackrDecoder 解 msgpackr 编码的一条值:标准 msgpack,外加它的「记录结构」扩展 ——
// fixext1 类型 0x72 定义一个结构(扩展字节是结构编号,后面跟字段名数组,再跟这条记录的各字段值),
// 之后单字节 0x40~0x7f 引用已定义的结构、只跟字段值。开了记录结构时 0x40~0x7f 不再是正整数。
// 只做解码、只认这里用得到的类型,其余一律报错。
type msgpackrDecoder struct {
	buf     []byte
	pos     int
	structs map[byte][]string
}

var errMsgpackr = errors.New("msgpackr: malformed")

const msgpackrMaxDepth = 64

func (d *msgpackrDecoder) take(n int) ([]byte, error) {
	if n < 0 || d.pos+n > len(d.buf) {
		return nil, errMsgpackr
	}
	b := d.buf[d.pos : d.pos+n]
	d.pos += n
	return b, nil
}

func (d *msgpackrDecoder) uint(n int) (uint64, error) {
	b, err := d.take(n)
	if err != nil {
		return 0, err
	}
	var v uint64
	for _, c := range b {
		v = v<<8 | uint64(c)
	}
	return v, nil
}

func (d *msgpackrDecoder) value(depth int) (any, error) {
	if depth > msgpackrMaxDepth {
		return nil, errMsgpackr
	}
	b, err := d.take(1)
	if err != nil {
		return nil, err
	}
	c := b[0]
	switch {
	case c <= 0x3f:
		return int64(c), nil
	case c <= 0x7f:
		keys, ok := d.structs[c]
		if !ok {
			return nil, errMsgpackr
		}
		return d.record(keys, depth)
	case c <= 0x8f:
		return d.mapN(int(c&0x0f), depth)
	case c <= 0x9f:
		return d.arrayN(int(c&0x0f), depth)
	case c <= 0xbf:
		return d.str(int(c & 0x1f))
	case c >= 0xe0:
		return int64(int8(c)), nil
	}
	switch c {
	case 0xc0:
		return nil, nil
	case 0xc2:
		return false, nil
	case 0xc3:
		return true, nil
	case 0xc4, 0xc5, 0xc6:
		n, err := d.uint(1 << (c - 0xc4))
		if err != nil {
			return nil, err
		}
		return d.take(int(n))
	case 0xca:
		v, err := d.uint(4)
		return float64(math.Float32frombits(uint32(v))), err
	case 0xcb:
		v, err := d.uint(8)
		return math.Float64frombits(v), err
	case 0xcc, 0xcd, 0xce, 0xcf:
		return d.uint(1 << (c - 0xcc))
	case 0xd0, 0xd1, 0xd2, 0xd3:
		n := 1 << (c - 0xd0)
		v, err := d.uint(n)
		if err != nil {
			return nil, err
		}
		shift := 64 - 8*n
		return int64(v<<shift) >> shift, nil
	case 0xd9, 0xda, 0xdb:
		n, err := d.uint(1 << (c - 0xd9))
		if err != nil {
			return nil, err
		}
		return d.str(int(n))
	case 0xdc, 0xdd:
		n, err := d.uint(2 << (c - 0xdc))
		if err != nil {
			return nil, err
		}
		return d.arrayN(int(n), depth)
	case 0xde, 0xdf:
		n, err := d.uint(2 << (c - 0xde))
		if err != nil {
			return nil, err
		}
		return d.mapN(int(n), depth)
	case 0xd4:
		ext, err := d.take(2)
		if err != nil || ext[0] != 0x72 || ext[1] < 0x40 || ext[1] > 0x7f {
			return nil, errMsgpackr
		}
		kv, err := d.value(depth + 1)
		arr, ok := kv.([]any)
		if err != nil || !ok {
			return nil, errMsgpackr
		}
		keys := make([]string, 0, len(arr))
		for _, k := range arr {
			s, ok := k.(string)
			if !ok {
				return nil, errMsgpackr
			}
			keys = append(keys, s)
		}
		if d.structs == nil {
			d.structs = map[byte][]string{}
		}
		d.structs[ext[1]] = keys
		return d.record(keys, depth)
	}
	return nil, errMsgpackr
}

func (d *msgpackrDecoder) str(n int) (any, error) {
	b, err := d.take(n)
	if err != nil {
		return nil, err
	}
	return string(b), nil
}

func (d *msgpackrDecoder) record(keys []string, depth int) (any, error) {
	m := make(map[string]any, len(keys))
	for _, k := range keys {
		v, err := d.value(depth + 1)
		if err != nil {
			return nil, err
		}
		m[k] = v
	}
	return m, nil
}

func (d *msgpackrDecoder) arrayN(n, depth int) (any, error) {
	if n > len(d.buf)-d.pos {
		return nil, errMsgpackr
	}
	out := make([]any, 0, n)
	for i := 0; i < n; i++ {
		v, err := d.value(depth + 1)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

func (d *msgpackrDecoder) mapN(n, depth int) (any, error) {
	if n > len(d.buf)-d.pos {
		return nil, errMsgpackr
	}
	m := make(map[string]any, n)
	for i := 0; i < n; i++ {
		k, err := d.value(depth + 1)
		if err != nil {
			return nil, err
		}
		v, err := d.value(depth + 1)
		if err != nil {
			return nil, err
		}
		ks, ok := k.(string)
		if !ok {
			continue
		}
		m[ks] = v
	}
	return m, nil
}
