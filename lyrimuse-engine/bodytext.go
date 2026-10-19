package main

import (
	"encoding/json"
	"hash/maphash"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"weak"
)

// 歌词正文(主歌词 / 译文 / 罗马音 / 逐字 / 纯文本 / 背景人声)在内存里的形态,见 15 章决策 65。
//
// 正文小文件(lyrimuse-lyrics-bodies/)里本来就有一模一样的一份。常驻引擎把一块正文确认跟小文件里那一块逐字节相同之后,
// 就只留摘要和位置(退回),用到时再读那个文件。
//
// 规矩:
//   - 零值是空。bodyText 不可比较(== 编不过):比内容用 Equal,取内容用 String(),后者可能读一次小文件。
//   - 内容相同的正文共用一个 bodyBlob(bt 按摘要去重):reflect.DeepEqual 比条目时碰到同一个指针直接判等,
//     别改成每次新建 —— 那样内容相同的两份正文在 DeepEqual 里永远不等。
//   - 只有常驻引擎启动收尾之后才真的退回(enableBodyEviction);一次性命令里的正文一直常驻。
//   - 任何改写 / 挪走 / 删除某一首正文小文件的地方,动手前先 pinBodiesAt(那个路径, 新内容):把退回到这份文件、
//     新内容里又没有同样一块的正文先读回内存。拷在别处的旧条目(改之前留的快照)因此永远读得回原来的内容。
type bodyText struct {
	b *bodyBlob
	_ [0]func()
}

// bodyField 正文在小文件(enrichBody)里是哪一块。
type bodyField uint8

const (
	bodyFieldLyrics bodyField = iota
	bodyFieldTr
	bodyFieldRoma
	bodyFieldYRC
	bodyFieldPlain
	bodyFieldBG
	bodyFieldCount
)

type bodyBlob struct {
	sum  [2]uint64 // 两个种子的 maphash:只在本进程里比较,不落盘
	n    int
	text atomic.Pointer[string] // nil = 已退回,内容在 loc 指的小文件里
	loc  atomic.Pointer[bodyLoc]
}

// bodyLoc 一块退回的正文在哪:path 那份小文件的 field 块。
type bodyLoc struct {
	path  string
	field bodyField
}

var bodySeeds = [2]maphash.Seed{maphash.MakeSeed(), maphash.MakeSeed()}

func bodySum(s string) [2]uint64 {
	return [2]uint64{maphash.String(bodySeeds[0], s), maphash.String(bodySeeds[1], s)}
}

// bodyBlobKey 去重表的键。
type bodyBlobKey struct {
	sum [2]uint64
	n   int
}

var (
	bodyInternMu sync.Mutex
	bodyIntern   = map[bodyBlobKey]weak.Pointer[bodyBlob]{}
)

// bt 一块正文。空串是零值;内容相同的共用一个 bodyBlob,已经退回的那份读得回来就不再常驻一份。
func bt(s string) bodyText {
	if s == "" {
		return bodyText{}
	}
	k := bodyBlobKey{sum: bodySum(s), n: len(s)}
	bodyInternMu.Lock()
	defer bodyInternMu.Unlock()
	if w, ok := bodyIntern[k]; ok {
		if b := w.Value(); b != nil {
			return bodyText{b: b}
		}
	}
	b := &bodyBlob{sum: k.sum, n: k.n}
	b.text.Store(&s)
	bodyIntern[k] = weak.Make(b)
	runtime.AddCleanup(b, func(k bodyBlobKey) {
		bodyInternMu.Lock()
		if w, ok := bodyIntern[k]; ok && w.Value() == nil {
			delete(bodyIntern, k)
		}
		bodyInternMu.Unlock()
	}, k)
	return bodyText{b: b}
}

func (t bodyText) IsZero() bool { return t.b == nil }

// Len 字节数,不读文件。
func (t bodyText) Len() int {
	if t.b == nil {
		return 0
	}
	return t.b.n
}

// Equal 内容是否相同,不读文件。
func (t bodyText) Equal(u bodyText) bool {
	if t.b == u.b {
		return true
	}
	if t.b == nil || u.b == nil {
		return false
	}
	return t.b.n == u.b.n && t.b.sum == u.b.sum
}

// EqualString 跟一段明文比,不读文件。
func (t bodyText) EqualString(s string) bool {
	if t.b == nil {
		return s == ""
	}
	return t.b.n == len(s) && t.b.sum == bodySum(s)
}

func (t bodyText) String() string {
	b := t.b
	if b == nil {
		return ""
	}
	if p := b.text.Load(); p != nil {
		return *p
	}
	if s, ok := readLocatedBody(b); ok {
		return s
	}
	// 改写小文件之前会先把内容钉回内存(pinBodiesAt),读到新文件对不上时这里一定已经有了。
	if p := b.text.Load(); p != nil {
		return *p
	}
	l := b.loc.Load()
	slog.Error("lyrics bodies: evicted body no longer matches its side file", "path", l.path, "field", l.field)
	return ""
}

func (t bodyText) MarshalJSON() ([]byte, error) { return json.Marshal(t.String()) }

func (t *bodyText) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	*t = bt(s)
	return nil
}

// resident 这块正文此刻是否常驻(测试和统计用)。
func (t bodyText) resident() bool { return t.b != nil && t.b.text.Load() != nil }

// ---- 定位 / 退回 / 钉住 ----

var (
	bodyRegMu sync.Mutex
	// bodyLocated 按小文件路径登记定位到它的正文;弱引用,条目和快照都不再拿着时自然消失。
	bodyLocated = map[string][]weak.Pointer[bodyBlob]{}
	// bodyEvictionOn 常驻引擎启动收尾后打开:定位的同时就退回。
	bodyEvictionOn atomic.Bool
)

// locateBody 记下 t 的内容就在 path 的 field 块(调用方已确认逐字节相同)。退回打开时同时丢掉常驻的内容。
func locateBody(t bodyText, path string, field bodyField) {
	b := t.b
	if b == nil {
		return
	}
	if l := b.loc.Load(); l == nil || l.path != path || l.field != field {
		b.loc.Store(&bodyLoc{path: path, field: field})
		bodyRegMu.Lock()
		bodyLocated[path] = append(bodyLocated[path], weak.Make(b))
		bodyRegMu.Unlock()
	}
	if bodyEvictionOn.Load() {
		b.text.Store(nil)
	}
}

// enableBodyEviction 打开退回,把已经定位过的正文全部退回。常驻引擎启动收尾时调一次。
func enableBodyEviction() {
	bodyEvictionOn.Store(true)
	bodyRegMu.Lock()
	defer bodyRegMu.Unlock()
	for path, ws := range bodyLocated {
		live := ws[:0]
		for _, w := range ws {
			b := w.Value()
			if b == nil {
				continue
			}
			if l := b.loc.Load(); l != nil && l.path == path {
				b.text.Store(nil)
				live = append(live, w)
			}
		}
		if len(live) == 0 {
			delete(bodyLocated, path)
		} else {
			bodyLocated[path] = live
		}
	}
}

// pinBodiesAt 在改写 / 挪走 / 删除 path 之前调:定位在这份文件里的正文,next(新内容,nil = 文件要没了)里同一块
// 不是同样内容的,从现在的文件读回内存。同样内容的照旧定位在这里。
func pinBodiesAt(path string, next *enrichBody) {
	bodyRegMu.Lock()
	ws := bodyLocated[path]
	delete(bodyLocated, path)
	bodyRegMu.Unlock()
	dropBodyFileCache(path)
	if len(ws) == 0 {
		return
	}
	var cur *enrichBody
	var keep []weak.Pointer[bodyBlob]
	for _, w := range ws {
		b := w.Value()
		if b == nil {
			continue
		}
		l := b.loc.Load()
		if l == nil || l.path != path {
			continue
		}
		if next != nil && (bodyText{b: b}).EqualString(next.field(l.field)) {
			keep = append(keep, w)
			continue
		}
		// 不再定位在这里:以后同一路径重新定位时要重新登记,覆盖前才钉得到。
		if b.text.Load() != nil {
			b.loc.Store(nil)
			continue
		}
		if cur == nil {
			data, err := os.ReadFile(path)
			if err == nil {
				cur = parseEnrichBody(data)
			} else {
				noteFileErr("read", path, err)
			}
			if cur == nil {
				slog.Error("lyrics bodies: could not pin bodies before rewriting their side file", "path", path, "err", err)
				return
			}
		}
		s := cur.field(l.field)
		if len(s) != b.n || bodySum(s) != b.sum {
			slog.Error("lyrics bodies: side file changed under an evicted body", "path", path, "field", l.field)
			continue
		}
		b.text.Store(&s)
		b.loc.Store(nil)
	}
	if len(keep) > 0 {
		bodyRegMu.Lock()
		bodyLocated[path] = append(bodyLocated[path], keep...)
		bodyRegMu.Unlock()
	}
}

// readLocatedBody 从退回的位置读回内容,摘要对得上才算数。
func readLocatedBody(b *bodyBlob) (string, bool) {
	l := b.loc.Load()
	if l == nil {
		return "", false
	}
	match := func(body *enrichBody) (string, bool) {
		if body == nil {
			return "", false
		}
		s := body.field(l.field)
		return s, len(s) == b.n && bodySum(s) == b.sum
	}
	if s, ok := match(cachedBodyFile(l.path)); ok {
		return s, true
	}
	bodyFileReads.Add(1)
	data, err := os.ReadFile(l.path)
	if err != nil {
		noteFileErr("read", l.path, err)
		return "", false
	}
	body := parseEnrichBody(data)
	rememberBodyFile(l.path, body)
	return match(body)
}

// bodyFileReads 退回的正文从小文件读回的次数(不算命中缓存的),每次整份存盘的日志行带上并清零:
// 一段时间里成千上万次就是有地方在逐条扫全库正文。
var bodyFileReads atomic.Int64

// ---- 最近读过的几份小文件 ----

// bodyFileCacheSize 解析结果留几份:同一首歌的几块正文常常前后脚被读。
const bodyFileCacheSize = 16

var (
	bodyFileMu    sync.Mutex
	bodyFileOrder []string
	bodyFiles     = map[string]*enrichBody{}
)

func cachedBodyFile(path string) *enrichBody {
	bodyFileMu.Lock()
	defer bodyFileMu.Unlock()
	return bodyFiles[path]
}

func rememberBodyFile(path string, body *enrichBody) {
	if body == nil {
		return
	}
	bodyFileMu.Lock()
	defer bodyFileMu.Unlock()
	if _, ok := bodyFiles[path]; !ok {
		bodyFileOrder = append(bodyFileOrder, path)
		if len(bodyFileOrder) > bodyFileCacheSize {
			delete(bodyFiles, bodyFileOrder[0])
			bodyFileOrder = bodyFileOrder[1:]
		}
	}
	bodyFiles[path] = body
}

func dropBodyFileCache(path string) {
	bodyFileMu.Lock()
	defer bodyFileMu.Unlock()
	delete(bodyFiles, path)
}

// field 小文件里的第 f 块。
func (b *enrichBody) field(f bodyField) string {
	switch f {
	case bodyFieldLyrics:
		return b.Lyrics
	case bodyFieldTr:
		return b.LyricsTr
	case bodyFieldRoma:
		return b.LyricsRoma
	case bodyFieldYRC:
		return b.LyricsYRC
	case bodyFieldPlain:
		return b.PlainLyrics
	case bodyFieldBG:
		return b.LyricsBG
	}
	return ""
}

// bodyFieldsOf 条目上六块正文,顺序同 bodyField。
func (e *enrichEntry) bodyFieldsOf() [bodyFieldCount]bodyText {
	return [bodyFieldCount]bodyText{e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics, e.LyricsBG}
}

// bodySidePath dir 里 key 那份小文件的路径。
func bodySidePath(dir, key string) string { return filepath.Join(dir, decisionSidecarName(key)) }
