package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
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
// ## 主缓存也是精简形态
//
// 主缓存跟索引写的是**同一种**精简条目(正文小文件确认写好了的那些,见 `leanEnrichSnapshot`),四块正文
// 只在正文小文件里,加载时补回(enrichbodyload.go)。于是索引跟主缓存内容一样,不再单独编码、单独写一遍,
// 而是主缓存落盘之后做一个指向它的硬链接(`linkEnrichIndex`)。App 读哪一份都一样。
//
// 第一次把老格式(正文整块在主缓存里)改写成精简格式之前,原样留一份 `.full-format.bak`
// (`backupFullEnrichCacheOnce`)。
//
// ## 顺序与新鲜度
//
// 每次保存:判决旁路 → 正文小文件 → 主缓存 → 索引(索引**最后**落盘)。App 只在「索引存在、且不比主缓存
// 旧(容 5 秒)」时读索引,否则照旧读主缓存。主缓存只有 collector 写(App 的「歌词管理」改动也是交给
// collector 执行,见 enrichedit.go);collector 被重启之后 `refreshEnrichIndexAtStartup` 发现索引缺失或比
// 主缓存旧,重新生成。命令行子命令的保存同样会写这两份(它们也设了 enrichPath)。

// enrichBodyCRCs:上次写出的正文校验值(key → crc,0 = 没有正文、不写文件)。enrichSaveMu 保护;
// nil = 还没从磁盘上的索引种过。
var enrichBodyCRCs map[string]uint32

// enrichBodyCRCsDir:enrichBodyCRCs 记的是哪个目录里的文件。主缓存只在「小文件确认写好了」时才写精简条目
// (leanEnrichSnapshot),而这份记录就是那个「确认」:目录换了(测试 / 换了配置目录)还拿旧目录的记录,
// 新目录里一个文件都没写,主缓存却会写成精简条目,正文就丢了。所以目录一变就重新种。
var enrichBodyCRCsDir string

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
	return enrichBodiesDirFor(enrichPath)
}

// enrichBodiesDirFor 跟主缓存 cachePath 同目录的正文小文件目录。只读加载(没有设 enrichPath)也要用。
func enrichBodiesDirFor(cachePath string) string {
	return filepath.Join(filepath.Dir(cachePath), clientName+"-lyrics-bodies")
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
	if enrichBodyCRCs == nil || enrichBodyCRCsDir != dir {
		seedEnrichBodyCRCs()
		enrichBodyCRCsDir = dir
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

// leanEnrichSnapshot 主缓存落盘的那一份:正文小文件确认写好了的条目(`enrichBodyCRCs` 记的正是这一次的
// 校验值)换成精简条目,其余(没有正文 / 小文件这次没写成)原样整块写 —— 正文绝不能只落在一个没写成的地方。
// 调用方持 enrichSaveMu,在 writeEnrichBodies 之后调。
func leanEnrichSnapshot(snapshot map[string]enrichEntry, crcs map[string]uint32) map[string]enrichEntry {
	out := make(map[string]enrichEntry, len(snapshot))
	for k, e := range snapshot {
		if crc := crcs[k]; crc != 0 && enrichBodyCRCs != nil && enrichBodyCRCs[k] == crc {
			e = leanForIndex(e, crc)
		}
		out[k] = e
	}
	return out
}

// enrichDiskFullFormat:这次加载时盘上的主缓存还有条目把正文整块写在里面(老格式)。enrichSaveMu 保护
// (加载时进程里还没有保存在跑)。
var enrichDiskFullFormat bool

// backupFullEnrichCacheOnce 第一次把老格式改写成精简格式之前,把盘上那份原样复制成 `.full-format.bak`
// (已经有了就不再写,不覆盖最早那一份)。返回 false = 备份没做成,这一次仍写完整格式,下次保存再试。
// 调用方持 enrichSaveMu。
func backupFullEnrichCacheOnce() bool {
	if !enrichDiskFullFormat {
		return true
	}
	backup := enrichPath + ".full-format.bak"
	if _, err := os.Stat(backup); err != nil {
		if !os.IsNotExist(err) {
			slog.Error("enrich cache: cannot check the full-format backup, keeping the full format", "err", err)
			return false
		}
		if err := copyFileAtomic(enrichPath, backup); err != nil {
			slog.Error("enrich cache: full-format backup failed, keeping the full format", "err", err)
			return false
		}
		log.Printf("enrich cache: backed up the full-format cache to %s before switching to lean entries", filepath.Base(backup))
	}
	enrichDiskFullFormat = false
	return true
}

// copyFileAtomic 流式复制到临时文件再改名,中途失败不留半份。
func copyFileAtomic(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp, err := os.CreateTemp(filepath.Dir(dst), filepath.Base(dst)+".tmp.*")
	if err != nil {
		return err
	}
	if _, err := io.Copy(tmp, in); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), dst); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}

// linkEnrichIndex 让索引成为主缓存的硬链接:主缓存已经是精简形态,两份内容一样,不必再编码、再写一遍。
// 同一个 inode,mtime 天然一致,App 照旧按「索引不比主缓存旧」读它。文件系统不支持硬链接(或出了错)就
// 照旧单独写一份(`writeEnrichIndex`)。调用方持 enrichSaveMu,在主缓存改名落盘之后调。
func linkEnrichIndex(snapshot map[string]enrichEntry, crcs map[string]uint32) {
	path := enrichIndexPath()
	if path == "" {
		return
	}
	tmp := fmt.Sprintf("%s.tmp.link-%d-%d", path, os.Getpid(), time.Now().UnixNano())
	if err := os.Link(enrichPath, tmp); err == nil {
		if err := os.Rename(tmp, path); err == nil {
			return
		}
		os.Remove(tmp)
	}
	writeEnrichIndex(snapshot, crcs)
}

// writeEnrichIndex 写精简索引(流式,同 writeEnrichSnapshot 的格式)。调用方持 enrichSaveMu。
// 只在做不了硬链接时用(见 linkEnrichIndex)。
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

// writeFileAtomic 写临时文件再改名。临时文件名是随机的:常驻进程和一次性命令(App 调的 search-lyrics 等)
// 会同时保存同一份缓存,固定的 `.tmp` 名会让一方把另一方写到一半的文件改名上位,读取时解析失败、整份缓存悄悄变空。
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
