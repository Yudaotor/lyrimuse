package main

import (
	"bytes"
	"encoding/json"
	"hash/crc32"
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 给 App 读的**精简索引** + **按 key 的歌词正文小文件**。
//
// ## 为什么(App 常驻 290–380 MB)
//
// App 的 `EnrichCacheReader` 播放时靠主缓存的 mtime 发现新歌词,mtime 一变就在后台把整份
// `lyrimuse-enrich-cache.json`(107 MB)重新 JSONDecoder 一遍 —— 每次 0.5 秒以上的 CPU、外加一份整缓存
// 大小的临时内存;而换歌、预取后面几首、补译文、换封面都会写盘。可 App 真正要正文的只有一处:
// `lookup()` 取**当前这首**的歌词;其余几十处只用封面 / 链接 / 时长 / 解析标记这类元数据。本机歌名
// 别名推断(E2)要全库的主歌词正文做比对,所以 `lyrics` 留在索引里。
//
// ## 两份文件
//
//   - `lyrimuse-enrich-index.json`:主缓存的每一条去掉 `lyrics_yrc` / `lyrics_roma` / `lyrics_tr` /
//     `plain_lyrics`(约 74 MB),加 `body_crc`。App 播放时解析这份(约 33 MB)。
//   - `lyrimuse-lyrics-bodies/<sha256(key) 前 32 位十六进制>.json`:`{"crc", "lyrics", "lyrics_tr",
//     "lyrics_roma", "lyrics_yrc", "plain_lyrics"}`,一首一个。App 取当前这首时读它,`crc` 跟索引那条的
//     `body_crc` 对不上就不用(退回整份主缓存),绝不拼出一份错的歌词。只在正文变了时重写(上次写出的
//     校验值记在 `enrichBodyCRCs`,启动时从磁盘上的旧索引种回来)。
//
// ## 顺序与新鲜度
//
// 每次保存:判决旁路 → 正文小文件 → 主缓存 → 索引(索引**最后**落盘)。App 只在「索引存在、且不比主缓存
// 旧(容 5 秒)」时读索引,否则照旧读主缓存。App 自己改主缓存(「歌词管理」保存 / 删除)时会删掉索引,
// 立刻退回主缓存那条路;collector 被重启之后 `refreshEnrichIndexAtStartup` 发现索引缺失或比主缓存旧,
// 重新生成。命令行子命令的保存同样会写这两份(它们也设了 enrichPath)。

// enrichBodyCRCs:上次写出的正文校验值(key → crc,0 = 没有正文、不写文件)。enrichSaveMu 保护;
// nil = 还没从磁盘上的索引种过。
var enrichBodyCRCs map[string]uint32

func enrichIndexPath() string {
	if enrichPath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(enrichPath), clientName+"-enrich-index.json")
}

func enrichBodiesDir() string {
	if enrichPath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(enrichPath), clientName+"-lyrics-bodies")
}

// enrichBodyCRC 五个正文字段的校验值;全空为 0(没有正文就不写文件)。字段之间用 0x00 隔开,
// 免得「a|bc」和「ab|c」撞成同一个值。
func enrichBodyCRC(e enrichEntry) uint32 {
	if e.Lyrics == "" && e.LyricsTr == "" && e.LyricsRoma == "" && e.LyricsYRC == "" && e.PlainLyrics == "" {
		return 0
	}
	h := crc32.NewIEEE()
	for _, s := range []string{e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics} {
		h.Write([]byte(s))
		h.Write([]byte{0})
	}
	if c := h.Sum32(); c != 0 {
		return c
	}
	return 1 // 极小概率算出 0,跟「没有正文」区分开
}

// enrichBody 是正文小文件的形状(App 侧 `EnrichCacheReader` 按同样的键读)。
type enrichBody struct {
	CRC         uint32 `json:"crc"`
	Lyrics      string `json:"lyrics,omitempty"`
	LyricsTr    string `json:"lyrics_tr,omitempty"`
	LyricsRoma  string `json:"lyrics_roma,omitempty"`
	LyricsYRC   string `json:"lyrics_yrc,omitempty"`
	PlainLyrics string `json:"plain_lyrics,omitempty"`
}

// enrichBodyFields 索引里去掉的四块正文各有没有:1 逐字 / 2 译文 / 4 罗马音 / 8 纯文本,128 恒置位 ——
// App(`EnrichCacheSlim.Fields`)靠「有 body_crc 却没有 body_fields」认出这个字段出现之前写的老索引。
func enrichBodyFields(e enrichEntry) uint8 {
	f := uint8(128)
	if e.LyricsYRC != "" {
		f |= 1
	}
	if e.LyricsTr != "" {
		f |= 2
	}
	if e.LyricsRoma != "" {
		f |= 4
	}
	if e.PlainLyrics != "" {
		f |= 8
	}
	return f
}

// leanForIndex 索引里的那一条:去掉四块大正文,记上校验值和位图。主歌词 `lyrics` 留着(本机别名推断、
// 「歌词管理」的批量锁定和时间轴偏移指纹都要)。没有正文(crc 0)的不记位图。
func leanForIndex(e enrichEntry, crc uint32) enrichEntry {
	if crc != 0 {
		e.BodyFields = enrichBodyFields(e)
	}
	e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics = "", "", "", ""
	e.BodyCRC = crc
	return e
}

// seedEnrichBodyCRCs 第一次保存前从磁盘上的旧索引种回「上次写出的校验值」,并去掉文件已经不在的那些
// (免得认为写过、其实没有)。调用方持 enrichSaveMu。
func seedEnrichBodyCRCs() {
	enrichBodyCRCs = map[string]uint32{}
	path, dir := enrichIndexPath(), enrichBodiesDir()
	if path == "" || dir == "" {
		return
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var idx map[string]struct {
		BodyCRC uint32 `json:"body_crc"`
	}
	if json.Unmarshal(b, &idx) != nil {
		return
	}
	for k, v := range idx {
		if v.BodyCRC == 0 {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, decisionSidecarName(k))); err == nil {
			enrichBodyCRCs[k] = v.BodyCRC
		}
	}
}

// writeEnrichBodies 写正文有变化的那几首的小文件,返回全部 key 的校验值(给索引用)。调用方持 enrichSaveMu。
func writeEnrichBodies(snapshot map[string]enrichEntry) map[string]uint32 {
	crcs := make(map[string]uint32, len(snapshot))
	for k, e := range snapshot {
		crcs[k] = enrichBodyCRC(e)
	}
	dir := enrichBodiesDir()
	if dir == "" {
		return crcs
	}
	if enrichBodyCRCs == nil {
		seedEnrichBodyCRCs()
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		slog.Error("lyrics bodies: mkdir", "err", err)
		return crcs
	}
	written, failed := 0, 0
	for k, crc := range crcs {
		if crc == 0 || enrichBodyCRCs[k] == crc {
			continue
		}
		e := snapshot[k]
		b, err := json.Marshal(enrichBody{CRC: crc, Lyrics: e.Lyrics, LyricsTr: e.LyricsTr,
			LyricsRoma: e.LyricsRoma, LyricsYRC: e.LyricsYRC, PlainLyrics: e.PlainLyrics})
		if err == nil {
			err = writeFileAtomic(filepath.Join(dir, decisionSidecarName(k)), b)
		}
		if err != nil {
			failed++
			if failed == 1 {
				slog.Error("lyrics bodies: write", "key", k, "err", err)
			}
			continue
		}
		enrichBodyCRCs[k] = crc
		written++
	}
	if written > 50 {
		log.Printf("lyrics bodies: wrote %d file(s)", written)
	}
	return crcs
}

// writeEnrichIndex 写精简索引(流式,同 writeEnrichSnapshot 的格式)。调用方持 enrichSaveMu。
func writeEnrichIndex(snapshot map[string]enrichEntry, crcs map[string]uint32) {
	path := enrichIndexPath()
	if path == "" {
		return
	}
	lean := make(map[string]enrichEntry, len(snapshot))
	for k, e := range snapshot {
		lean[k] = leanForIndex(e, crcs[k])
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		slog.Error("enrich index: create temp", "err", err)
		return
	}
	if err := writeEnrichSnapshot(tmp, lean); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		slog.Error("enrich index: write", "err", err)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		slog.Error("enrich index: close", "err", err)
		return
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		slog.Error("enrich index: rename", "err", err)
	}
}

func writeFileAtomic(path string, b []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}

// enrichIndexOutdated 索引是 body_fields 出现之前写的(有校验值、没有位图):App 不拿它当精简快照,得重写。
func enrichIndexOutdated(path string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return true
	}
	return bytes.Contains(b, []byte(`"body_crc"`)) && !bytes.Contains(b, []byte(`"body_fields"`))
}

// refreshEnrichIndexAtStartup:索引缺失、比主缓存旧(App 改过主缓存会删掉它;老版本从没写过)或是老格式
// 就整份重写一遍(连带正文小文件),然后清掉没有对应条目的正文文件。常驻进程启动时调一次。
func refreshEnrichIndexAtStartup() {
	idx := enrichIndexPath()
	if idx == "" {
		return
	}
	mainInfo, err := os.Stat(enrichPath)
	if err != nil {
		return
	}
	if idxInfo, err := os.Stat(idx); err != nil || idxInfo.ModTime().Before(mainInfo.ModTime().Add(-time.Second)) ||
		enrichIndexOutdated(idx) {
		enrichMu.Lock()
		enrichDirty = true
		enrichMu.Unlock()
		saveEnrichCache()
		log.Printf("enrich index: regenerated for the app")
	}
	sweepKeyedDir(enrichBodiesDir(), "lyrics bodies")
}

// sweepKeyedDir 删掉按 key 命名(decisionSidecarName)的目录里没有对应条目的文件,以及写到一半留下的
// 临时文件。只在常驻进程启动时跑。
func sweepKeyedDir(dir, label string) {
	if dir == "" {
		return
	}
	names, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	enrichMu.Lock()
	live := make(map[string]bool, len(enrichCache))
	for k := range enrichCache {
		live[decisionSidecarName(k)] = true
	}
	enrichMu.Unlock()
	removed := 0
	for _, n := range names {
		name := n.Name()
		stale := strings.Contains(name, ".json.tmp.")
		if n.IsDir() || (!stale && (!strings.HasSuffix(name, ".json") || live[name])) {
			continue
		}
		if os.Remove(filepath.Join(dir, name)) == nil {
			removed++
		}
	}
	if removed > 0 {
		log.Printf("%s: removed %d orphaned file(s)", label, removed)
	}
}
