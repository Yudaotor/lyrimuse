// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"strings"
)

// lyricsDir is set once in main.go alongside enrichPath. Empty means exports
// are disabled (e.g. flag not initialized yet, or path resolution failed).
var lyricsDir string

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
// 2026-07-15: 这个头部是"歌词部分以 lyrics/ 文件夹为权威源"改造的核心——
// sanitizeLyricsFilename 是单向有损转换(替换掉 "|" 和文件系统非法字符),不能从文件名
// 反推出原始的 artist|title|album,所以"这个文件对应哪首歌"必须能从文件内容本身准确
// 还原,而不是依赖文件名。这里用真实(未经 sanitizeLyricsFilename 转义)的歌手/歌名/
// 专辑名写标准 LRC 的 [ar:]/[ti:]/[al:] 标签——顺带这也是任何 .lrc 播放器/工具都认识
// 的写法,文件本身看起来就"像样"。source/manual 是非标准但无害的自定义标签,Swift 的
// LRCParser/YRCParser(以及任何其它 LRC 解析器)只认时间戳格式的行,这几行匹配不上会被
// 直接跳过,不需要改任何解析器。
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
// 2026-07-15: 这个函数现在是"歌词部分以 lyrics/ 文件夹为权威源"改造里 Go 这一侧的主
// 写入路径(配合 importLyricsFromFiles 做启动时的调和),不再只是一个"顺手导出存档"的
// 次要功能——因此这次把之前只导出纯 Lyrics 一个字段的范围,扩成歌词家族全部 6 个字段
// (含 LyricsTr/LyricsRoma/LyricsYRC/LyricsSource/ManualLyrics,后两者进头部标签)。
// 对每个 key 的 4 个可能后缀都显式做"该有就写、不该有就删"——比如某条目原来有逐字
// 时间轴、后来通过 removeWordTiming 清空了,这里要把之前导出的 .yrc 文件一并删掉,
// 否则下次启动 importLyricsFromFiles 会把这个残留文件当成"文件夹里有数据"重新读回来,
// 悄悄撤销用户刚做的"移除逐字时间轴"操作。
//
// 2026-07-14 之前的注释(仍然成立,只是范围从"只有 .lrc"扩到"整个文件族"):deleting an
// entry via desktop-lyrics's 歌词管理 window removes the corresponding files itself
// right after removing the cache entry — this Go-side sweep has no concept of "this
// key was just explicitly deleted" vs. "this key never existed", so the
// deletion-cleanup responsibility for a still-existing entry's *stale variant files*
// (see above) lives here, while whole-entry deletion cleanup lives in Swift (and, for
// hand-deleted files, in importLyricsFromFiles's own "second pass").
func exportLyricsFiles() {
	if lyricsDir == "" {
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
			// 防御性跳过:真机实测坐实过一次(见 lyricsimport.go 的 parseLyricsFile
			// 注释)"artist/title 是空的"这种残缺 key 混进 enrichCache、被这里毫无
			// 保留地导出成头部同样残缺的文件,再被导入逻辑当成合法数据循环放大的事故。
			// 正常情况下 trackEnrichment 的 title=="" 早退+key 本身的构造方式,不会
			// 产生这种记录;这里只是多一层保险,不指望这个分支真的常被命中。
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
	if err := os.MkdirAll(lyricsDir, 0o755); err != nil {
		return
	}

	// 2026-07-15 真机实测坐实(不是假设的边界情况):macOS 默认文件系统(APFS)大小写
	// 不敏感、只保留显示大小写——这个项目本来就有一个已知的、会反复复现的数据问题
	// (media-control 偶尔读到的专辑名大小写跟 Music.app 真实库 tag 不一致,同一首歌
	// 因此长出两条大小写不同的缓存条目,例如 "History Continues" 和 "HIStory
	// Continues")。这类 key 各自 sanitizeLyricsFilename 出来的文件名只有大小写不同,
	// 在这台文件系统上其实是同一个文件——先写的那条会被后写的那条悄悄覆盖,是真实的
	// 数据丢失,不只是"文件名不好看"。所以按"文件系统实际会认成同一份文件"的键
	// (sanitizeLyricsFilename 结果统一转小写)分组,组内 ≥2 个不同 key 撞车的,给
	// 组里全部 key(不只是从第二个开始)都加一个确定性哈希后缀——用哈希而不是遇到
	// 顺序决定谁加后缀,不受 Go map 遍历顺序(每次进程重启都随机)影响,同一个 key
	// 每次都落在同一个文件名上,不会一会儿叫这个名字一会儿叫那个名字。
	byFold := make(map[string][]int, len(jobs))
	for i, j := range jobs {
		fold := strings.ToLower(sanitizeLyricsFilename(j.key))
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
		base, ok := disambiguated[i]
		if !ok {
			base = sanitizeLyricsFilename(j.key)
		} else {
			// 这个 key 这次被判定需要消歧——顺手清掉它在"未加哈希后缀的原始文件名"下
			// 可能残留的旧文件。那个文件名现在同时"属于"碰撞组里好几个 key,内容早晚
			// 会被其中某一个的写入弄乱,留着只会制造一份意义不明的孤儿文件(而且下次
			// importLyricsFromFiles 扫描时会把它当成第三个可以解析出 key 的分组,虽然
			// 无害——导入是只增不改的,内容碰巧一致时不会有副作用——但没有理由留着这份
			// 混淆视听的文件)。
			plainBase := sanitizeLyricsFilename(j.key)
			for _, suffix := range lyricsFileSuffixes {
				_ = os.Remove(filepath.Join(lyricsDir, plainBase+suffix))
			}
		}
		header := lyricsFileHeader(j.artist, j.title, j.album, j.source, j.manual)
		for k, suffix := range lyricsFileSuffixes {
			path := filepath.Join(lyricsDir, base+suffix)
			content := j.variants[k]
			if content == "" {
				_ = os.Remove(path) // 忽略"文件本来就不存在"的错误,这是预期情况
				continue
			}
			full := header + content
			if existing, err := os.ReadFile(path); err == nil && string(existing) == full {
				continue
			}
			_ = os.WriteFile(path, []byte(full), 0o644)
		}
	}
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
	name := strings.ReplaceAll(key, "|", " - ")
	for _, c := range []string{"/", ":", "*", "?", "\"", "<", ">", "\\"} {
		name = strings.ReplaceAll(name, c, "_")
	}
	return strings.TrimSpace(name)
}
