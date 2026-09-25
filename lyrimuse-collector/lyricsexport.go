// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"fmt"
	"hash/crc32"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"unicode/utf8"
)

// lyricsDirValue 是歌词文件夹的当前位置,读写都经 lyricsDir() / setLyricsDir()。空 = 不导出
// (还没初始化、或路径解析失败)。常驻进程里它会被热切换(见 lyricsdirswitch.go),读取方在一次
// 操作里要用同一个目录时先取一份局部变量,别在循环里反复调 lyricsDir()。
var lyricsDirValue atomic.Pointer[string]

func lyricsDir() string {
	if p := lyricsDirValue.Load(); p != nil {
		return *p
	}
	return ""
}

func setLyricsDir(dir string) { lyricsDirValue.Store(&dir) }

// splitEnrichKey 拆 "artist|title|album" cache key,只按前两个 "|" 分(专辑名里偶尔
// 出现的 "|" 不会把切分打乱),跟 Swift 侧 EnrichCacheStore.splitKey(desktop-lyrics)
// 逐字对应。
func splitEnrichKey(key string) (artist, title, album string) {
	parts := strings.SplitN(key, "|", 3)
	if len(parts) < 3 {
		return "", "", ""
	}
	return parts[0], parts[1], parts[2]
}

// lyricsFileHeader 拼出 .lrc/.yrc 文件顶部统一的头部标签块。
//
// sanitizeLyricsFilename 是单向有损转换,不能从文件名反推出原始的 artist|title|album,
// 所以文件对应哪首歌必须能从文件内容本身准确还原。这里用真实(未转义)的歌手/歌名/专辑
// 名写标准 LRC 的 [ar:]/[ti:]/[al:] 标签,顺带也是任何 .lrc 工具都认识的写法。
// source/manual 是非标准但无害的自定义标签,Swift 的 LRCParser/YRCParser 只认时间戳
// 格式的行,匹配不上会直接跳过,不需要改任何解析器。
func lyricsFileHeader(artist, title, album, source string, manual bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[ar:%s]\n[ti:%s]\n[al:%s]\n", artist, title, album)
	if source != "" {
		fmt.Fprintf(&b, "[source:%s]\n", source)
	}
	if manual {
		b.WriteString("[manual:1]\n")
	}
	b.WriteString("\n")
	return b.String()
}

// lyricsFileSuffixes 是这个 key 可能对应的最多 4 个文件后缀,顺序跟 enrichEntry 里
// 歌词家族字段的语义一一对应。
var lyricsFileSuffixes = [4]string{".lrc", ".tr.lrc", ".roma.lrc", ".yrc"}

// exportLyricsFiles writes/updates the standalone lyrics-family file group
// (<base>.lrc/.tr.lrc/.roma.lrc/.yrc,只在对应字段非空时才写)per entry that
// currently has lyrics, one level outside enrichCache. Full sweep over
// enrichCache every call.
//
// 是"歌词部分以 lyrics/ 文件夹为权威源"里 Go 侧的主写入路径(配合 importLyricsFromFiles
// 做启动时的调和)。对每个 key 的 4 个可能后缀都显式做"该有就写、不该有就删"——比如某
// 条目的逐字时间轴被 removeWordTiming 清空了,这里要把之前导出的 .yrc 文件一并删掉,
// 否则下次启动 importLyricsFromFiles 会把这个残留文件当成"文件夹里有数据"重新读回来,
// 悄悄撤销刚做的"移除逐字时间轴"操作。
//
// 整条目删除的清理走 Swift 侧(desktop-lyrics 的"歌词管理"窗口删除时会同时删文件),
// 这里的 Go-side sweep 无法区分"这个 key 刚被显式删除"和"这个 key 从未存在过",所以
// 只负责清理仍存在条目的*过期变体文件*(如上)。
//
// 全量导出要对每个条目逐个读比 4 个文件,条目上千时是秒级的磁盘 IO;运行期只改了个别条目的
// 路径用 exportLyricsFilesFor。启动与 CLI 仍用这个全量版本。
func exportLyricsFiles() {
	exportLyricsFilesMatching(nil)
}

// exportLyricsFilesFor 只导出 keys 以及跟它们落在同一个文件名(大小写折叠后)的条目,对这些
// 条目写出的文件与全量导出逐字节相同。碰撞组必须整组导出:新条目让组从 1 个变成 2 个时,
// 原来那个条目要改用带哈希后缀的文件名、并删掉它原先的无后缀文件。
func exportLyricsFilesFor(keys ...string) {
	if len(keys) == 0 {
		return
	}
	folds := make(map[string]bool, len(keys))
	for _, k := range keys {
		folds[lyricsFileFold(k)] = true
	}
	exportLyricsFilesMatching(folds)
}

// lyricsFileFold 是"文件系统会认成同一份文件"的分组键,见下面碰撞消歧那段。
func lyricsFileFold(key string) string {
	return strings.ToLower(sanitizeLyricsFilename(key))
}

// exportLyricsFilesMatching:onlyFolds 为 nil 时导出全部条目,否则只对分组键在其中的条目读写文件。
// 碰撞分组始终按全部条目计算。
func exportLyricsFilesMatching(onlyFolds map[string]bool) {
	dir := lyricsDir()
	if dir == "" {
		return
	}
	type entryJob struct {
		key                  string
		artist, title, album string
		source               string
		manual               bool
		variants             [4]string // 对应 lyricsFileSuffixes,空串表示这个变体没有内容
	}
	enrichMu.Lock()
	jobs := make([]entryJob, 0, len(enrichCache))
	for key, e := range enrichCache {
		if e.Lyrics == "" {
			continue
		}
		artist, title, album := splitEnrichKey(key)
		if artist == "" || title == "" {
			// 防御性跳过:避免"artist/title 是空的"这种残缺 key 混进 enrichCache 时,
			// 被这里导出成头部同样残缺的文件,再被导入逻辑当成合法数据循环放大(见
			// lyricsimport.go 的 parseLyricsFile 注释)。正常情况下 trackEnrichment 的
			// title=="" 早退+key 本身的构造方式,不会产生这种记录,这里只是多一层保险。
			continue
		}
		jobs = append(jobs, entryJob{
			key: key, artist: artist, title: title, album: album,
			source: e.LyricsSource, manual: e.ManualLyrics,
			variants: [4]string{e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC},
		})
	}
	enrichMu.Unlock()
	if len(jobs) == 0 {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}

	// macOS 默认文件系统(APFS)大小写不敏感、只保留显示大小写——而这个项目本来就有个
	// 已知问题:media-control 偶尔读到的专辑名大小写跟 Music.app 真实库 tag 不一致,
	// 同一首歌因此长出两条大小写不同的缓存条目。这类 key 各自 sanitizeLyricsFilename
	// 出来的文件名只有大小写不同,在这台文件系统上其实是同一个文件,先写的会被后写的
	// 悄悄覆盖,是真实的数据丢失。所以按"文件系统实际会认成同一份文件"的键
	// (sanitizeLyricsFilename 结果统一转小写)分组,组内 ≥2 个不同 key 撞车的,给
	// 全部 key(不只是从第二个开始)都加一个确定性哈希后缀——用哈希而非遇到顺序决定,
	// 不受 Go map 遍历顺序(每次进程重启都随机)影响,同一个 key 每次都落在同一个文件名。
	byFold := make(map[string][]int, len(jobs))
	folds := make([]string, len(jobs))
	for i, j := range jobs {
		fold := lyricsFileFold(j.key)
		folds[i] = fold
		byFold[fold] = append(byFold[fold], i)
	}
	disambiguated := make(map[int]string, len(jobs)) // job 下标 -> 加了哈希后缀的 base
	for _, idxs := range byFold {
		if len(idxs) < 2 {
			continue
		}
		for _, idx := range idxs {
			sum := crc32.ChecksumIEEE([]byte(jobs[idx].key))
			disambiguated[idx] = fmt.Sprintf("%s~%06x", sanitizeLyricsFilename(jobs[idx].key), sum&0xFFFFFF)
		}
	}

	for i, j := range jobs {
		if onlyFolds != nil && !onlyFolds[folds[i]] {
			continue
		}
		base, ok := disambiguated[i]
		if !ok {
			base = sanitizeLyricsFilename(j.key)
		} else {
			// 这个 key 被判定需要消歧——顺手清掉它在"未加哈希后缀的原始文件名"下可能
			// 残留的旧文件:那个文件名现在同时"属于"碰撞组里好几个 key,内容早晚会被
			// 其中某一个的写入弄乱,留着只是一份意义不明的孤儿文件。
			plainBase := sanitizeLyricsFilename(j.key)
			for _, suffix := range lyricsFileSuffixes {
				_ = os.Remove(filepath.Join(dir, plainBase+suffix))
			}
		}
		// 同理清掉"加长度上限之前那个更长的文件名"下的残留。这类文件是存量:长度上限
		// 是后加的,而在它之前、原子写(writeLyricsFileAtomic)之前,os.WriteFile 能把
		// 255 字节以内的长文件名直接写成功。留着它们不只是占地方——importLyricsFromFiles
		// 是按**文件头部标签**重建 key 的、不看文件名,所以这份旧内容下次启动会被当成
		// 用户文件读回来,把新写的那份顶掉。
		if untruncated := sanitizeLyricsFilenameUntruncated(j.key); untruncated != sanitizeLyricsFilename(j.key) {
			for _, suffix := range lyricsFileSuffixes {
				// 名字本身超过 255 字节时 Remove 会返回 ENAMETOOLONG,那正说明它不可能
				// 存在过,和"文件不存在"一样忽略掉。
				_ = os.Remove(filepath.Join(dir, untruncated+suffix))
			}
		}
		header := lyricsFileHeader(j.artist, j.title, j.album, j.source, j.manual)
		for k, suffix := range lyricsFileSuffixes {
			path := filepath.Join(dir, base+suffix)
			content := j.variants[k]
			if content == "" {
				_ = os.Remove(path) // 忽略"文件本来就不存在"的错误,这是预期情况
				continue
			}
			full := header + content
			if existing, err := os.ReadFile(path); err == nil && string(existing) == full {
				continue
			}
			if err := writeLyricsFileAtomic(path, []byte(full)); err != nil {
				slog.Error("lyrics export: write failed", "file", filepath.Base(path), "err", err)
			}
		}
	}
}

// writeLyricsFileAtomic 用「同目录临时文件 + 改名」写一份歌词文件——文件要么是旧的完整
// 内容,要么是新的完整内容,不会出现半截。
//
// 为什么这里必须原子、而且比别的缓存文件更要紧:lyrics/ 是歌词六字段的**权威源**
// (01 章),importLyricsFromFiles 启动时只校验头部三行、**正文不校验**、内容不同就覆盖
// 缓存——之前的 os.WriteFile 是"先截断再写",崩溃/断电/磁盘满留下的空文件或半截文件,
// 下次启动就会以「用户文件」的身份把缓存里完整的歌词顶掉,手改过的 manual_lyrics 也在这条
// 路上。同仓 saveEnrichCache 与 Swift 侧 saveEdit(`atomically: true`)早就是这个写法,只有
// 这里没跟上。顺带消掉一个并发坑:exportLyricsFiles 有 8 个调用点、文件写入那段没有锁,两轮
// 导出同时写同一个文件时 WriteFile 会互相截断交错;各写各的临时文件再改名,最后改名的赢、
// 内容完整。
//
// 临时文件名 `<base>.lrc.tmp.随机`:不以四个歌词后缀收尾,所以导入分组(lyricsFileSuffixOf)、
// Swift 侧目录扫描与备份归档(都按 EnrichCacheKeys.lyricsFileSuffixes 过滤)都会自动忽略它;
// 崩溃残留由 importLyricsFromFiles 启动时清扫(isLyricsTempFile)。权限显式补成 0644——
// os.CreateTemp 默认 0600,不补的话用户在 Finder / 编辑器里打开自己的歌词文件会比以前多一层
// 限制(同一用户其实能读,但跟之前导出的 0644 不一致)。不 fsync,跟 saveEnrichCache 一致。
//
// 11 章的「mtime 当最近更新信号」不受影响:调用方仍然先比对全文、逐字节相同就不写,改名
// 后文件的 mtime 就是这次真正写入的时刻,跟 WriteFile 的语义一样。
func writeLyricsFileAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}

// isLyricsTempFile 认 writeLyricsFileAtomic 留下的临时文件(`X.lrc.tmp.123456`):名字里带
// `.tmp.` 且不以四个歌词后缀收尾——后一条是为了绝不把用户自己命名成 "xx.tmp.lrc" 的正常
// 歌词文件当垃圾扫掉。
func isLyricsTempFile(name string) bool {
	return strings.Contains(name, ".tmp.") && lyricsFileSuffixOf(name) == ""
}

// sanitizeLyricsFilename turns a "艺人|歌名|专辑" cache key into a safe,
// readable filename: "|" becomes " - ", then filesystem-unsafe characters are
// replaced with "_". 这不是一个完全无碰撞的转换(比如两个不同专辑各自含 "/" 的
// 位置不同,但替换成 "_" 之后可能撞成同一个字符串;更常见的是这个项目本来就有的
// "同一首歌因大小写不同长出两条缓存条目"这个已知问题——两个只有大小写不同的文件名,
// 在 macOS 默认的大小写不敏感文件系统上其实是同一个文件)。真正的防碰撞在
// exportLyricsFiles 里(按转小写后的文件名分组,组内 ≥2 个不同 key 都加确定性哈希
// 后缀),这个函数本身只负责"字符转义",不负责"保证全局唯一"。
func sanitizeLyricsFilename(key string) string {
	return truncateFilenameBase(sanitizeLyricsFilenameUntruncated(key))
}

// sanitizeLyricsFilenameUntruncated 是上面那个函数不加长度上限的版本。只有一个用途:
// 让 exportLyricsFiles 知道这个 key 在**加上长度上限之前**会落到哪个文件名,好把那份
// 残留删掉。别拿它去拼新文件名。
func sanitizeLyricsFilenameUntruncated(key string) string {
	name := strings.ReplaceAll(key, "|", " - ")
	for _, c := range []string{"/", ":", "*", "?", "\"", "<", ">", "\\"} {
		name = strings.ReplaceAll(name, c, "_")
	}
	return strings.TrimSpace(name)
}

// lyricsFilenameMaxBytes 是文件名 base(不含 .lrc 等后缀)的字节上限。
//
// 单个文件名在 APFS / HFS+ 上限是 **255 字节**(不是字符 —— 一个汉字 3 字节,所以中文
// 名义上只有 85 字),超了 open 直接 ENAMETOOLONG。真正吃紧的不是最终文件名,而是
// writeLyricsFileAtomic 的临时文件 `<base><suffix>.tmp.<随机>`:实测 `.tmp.` 加随机数
// 占 14 字节,最长的后缀 .roma.lrc 占 9 字节,所以 base 的硬上限是 255-14-9 = 232;
// 碰撞消歧还要再接 `~xxxxxx` 7 字节,于是 225。取 200 是留余量。
//
// 这个常量在 Swift 侧 EnrichCacheKeys.filenameMaxBytes 有一份对应值,两边必须同时改:
// Swift 按同样的规则算出文件名去删除条目的导出文件,算不一致就会漏删,而 collector 重启
// 时 importLyricsFromFiles 会按**文件头部标签**把残留文件重新导回缓存 —— 表现是"删掉的
// 条目过一会儿自己回来了"。
const lyricsFilenameMaxBytes = 200

// truncateFilenameBase 把文件名 base 截到字节上限,只在 UTF-8 字符边界上切,绝不切出
// 半个字符(那会让文件名带上 U+FFFD,在 Finder 里显示成乱码)。
//
// 截断当然会让两个原本不同的长 key 撞到同一个名字 —— 那正好由 exportLyricsFiles 已有的
// 碰撞消歧接住:它按最终文件名分组,组内 ≥2 个 key 的每一个都接上 crc32(**原始 key**)
// 后缀,所以截断后同名的 key 仍然各写各的文件。
func truncateFilenameBase(name string) string {
	if len(name) <= lyricsFilenameMaxBytes {
		return name
	}
	cut := lyricsFilenameMaxBytes
	for cut > 0 && !utf8.RuneStart(name[cut]) {
		cut--
	}
	// 再 trim 一次:截断点很可能落在空格上,留下尾部空格的文件名在 Finder 里是个坑。
	return strings.TrimSpace(name[:cut])
}
