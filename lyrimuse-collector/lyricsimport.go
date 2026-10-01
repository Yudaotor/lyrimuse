package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var (
	lyricsHeaderArtistRe = regexp.MustCompile(`^\[ar:(.*)\]$`)
	lyricsHeaderTitleRe  = regexp.MustCompile(`^\[ti:(.*)\]$`)
	lyricsHeaderAlbumRe  = regexp.MustCompile(`^\[al:(.*)\]$`)
	lyricsHeaderSourceRe = regexp.MustCompile(`^\[source:(.*)\]$`)
	lyricsHeaderManualRe = regexp.MustCompile(`^\[manual:1\]$`)
)

// parsedLyricsFile 是解析一个 .lrc/.yrc 文件后拆出的头部+正文。
type parsedLyricsFile struct {
	artist, title, album string
	source               string
	manual               bool
	body                 string
	ok                   bool // 头部按固定行号完整读到 ar/ti/al 三行、且 artist/title 内容都非空才算 true(album 内容允许是空字符串)
}

// parseLyricsFile 读一个 .lrc/.yrc 文件,拆出 lyricsFileHeader(见 lyricsexport.go)写的
// [ar:]/[ti:]/[al:]/[source:]/[manual:1] 头部标签。
//
// 按"固定行号"读头部,不能按"这行长得像不像标签"来扫描:有些歌词源原文第一行就是
// "[ti:xxx]" 这类它自己的 ID 标签(不是我们写的头),扫描式判断会把这种内容行误吞成
// 头部,导致正文缺行且每次重启都被悄悄裁掉。头部结构固定为 [ar:]/[ti:]/[al:] 三行、
// 可选 [source:]/[manual:1]、之后必须紧跟一个空行分隔符,因此只按行号消费,不做"像不像
// 标签"的判断。老版本(改动前导出、完全没有头)文件第 1 行就匹配不上 [ar:],直接判
// ok=false,调用方(importLyricsFromFiles)据此跳过整组、沿用 JSON 里的旧值。
func parseLyricsFile(path string) parsedLyricsFile {
	data, err := os.ReadFile(path)
	if err != nil {
		return parsedLyricsFile{}
	}
	return parseLyricsBytes(data)
}

// parseLyricsBytes 是 parseLyricsFile 的解析部分(文件内容已经读进来了),规则见 parseLyricsFile。
func parseLyricsBytes(data []byte) parsedLyricsFile {
	var p parsedLyricsFile
	// 有的编辑器存盘时给文件开头加 UTF-8 BOM:不去掉的话第一行认不出歌手头,整份文件被当成坏的。
	lines := strings.Split(strings.TrimPrefix(string(data), "\ufeff"), "\n")
	get := func(i int) (string, bool) {
		if i < 0 || i >= len(lines) {
			return "", false
		}
		return strings.TrimRight(lines[i], "\r"), true
	}

	i := 0
	line, ok := get(i)
	m := lyricsHeaderArtistRe.FindStringSubmatch(line)
	if !ok || m == nil {
		return p
	}
	p.artist = m[1]
	i++

	line, ok = get(i)
	m = lyricsHeaderTitleRe.FindStringSubmatch(line)
	if !ok || m == nil {
		return p
	}
	p.title = m[1]
	i++

	line, ok = get(i)
	m = lyricsHeaderAlbumRe.FindStringSubmatch(line)
	if !ok || m == nil {
		return p
	}
	p.album = m[1]
	i++

	if line, ok = get(i); ok {
		if m := lyricsHeaderSourceRe.FindStringSubmatch(line); m != nil {
			p.source = m[1]
			i++
		}
	}
	if line, ok = get(i); ok {
		if lyricsHeaderManualRe.MatchString(line) {
			p.manual = true
			i++
		}
	}

	if line, ok = get(i); !ok || line != "" {
		return p // 头部之后必须紧跟一个空行分隔符,格式不对(比如手改坏了)就当没有有效头处理
	}
	i++

	p.body = strings.Join(lines[i:], "\n")
	// artist/title 必须非空才算真正有效的头——只检查"这一行是否匹配得上 [ar:]/[ti:]
	// 这个标签格式"不够,空内容(比如 "[ar:]")也能匹配上正则,但那不是一个可用的身份。
	// 有些歌词源原文自带的空 ID 标签行(比如酷狗的 "[ti:]\r\n[ar:]\r\n[al:]\r\n")在旧的
	// 扫描式解析下会被误当成头部消费,产出 key 为 "||" 的空身份记录并持续污染"歌词管理"
	// 列表,因此这里必须补上"内容不能是空"这层校验。album 允许是空字符串(有些曲目本来
	// 就没有专辑名),不在这个校验范围内。
	p.ok = p.artist != "" && p.title != ""
	return p
}

// importLyricsFromFiles 在启动时把 lyrics/ 文件夹里的内容,采纳进 enrichCache 对应
// 条目的歌词家族字段(Lyrics/LyricsTr/LyricsRoma/LyricsYRC/LyricsSource/ManualLyrics)。
// 是"歌词部分以 lyrics/ 文件夹为权威源"的导入/调和步骤,main.go 里排在 loadEnrichCache
// 之后、exportLyricsFiles 之前。
//
// 只增不删:文件不存在不代表用户想删——专辑名大小写不一致会让同一首歌长出两条缓存
// 条目,二者 sanitizeLyricsFilename 出的文件名在大小写不敏感的文件系统上其实是同一个
// 文件,先写的会被后写的悄悄覆盖(exportLyricsFiles 已用确定性哈希后缀堵住这个碰撞本身,
// 见其注释),但"文件因为这个 bug 意外丢失"和"用户真的想删除"这两种情况,从"文件不
// 存在"这一个信号上根本区分不出来。所以文件存在且内容有变化才采纳,不存在时什么都不做、
// 保留 JSON 里已有的值。真正的删除只走 desktop-lyrics"歌词管理"窗口的删除按钮
// (EnrichCacheStore.delete/removeWordTiming),同一次调用里显式同时删掉 JSON 字段和
// 对应文件,不依赖这里的推断。代价:手动在 Finder 里删掉一份 .lrc/.yrc 文件不会清空对应
// 缓存字段,下次 export 还会把它重新写回来——这是刻意的取舍,不是遗漏。
//
// 算法:
//  1. 扫 lyricsDir(),按去掉后缀的文件名前缀分组(同一首歌的 .lrc/.tr.lrc/.roma.lrc/.yrc)。
//  2. 组内挑一个能解析出头部的文件还原 (artist,title,album)——文件名本身不可信
//     (sanitizeLyricsFilename 是单向有损转换,见 lyricsexport.go),头部标签才是权威
//     身份信息。整组都缺头(老版本文件)就跳过,沿用 JSON 里的旧值。
//  3. 对每个能还原出 key 的分组:只处理组里实际存在的变体文件,存在就用其内容覆盖对应
//     字段(内容不同才算变化),不存在就不碰。新建条目时 TS 留 enrichEntry 零值(不设
//     time.Now()),这样 needsPeripheralBackfill 会在这首歌真正被播放时才补封面/链接,
//     不会被 10 分钟节流误伤。
//
// 必须挑**最长**的匹配后缀,不能"首次命中就 break"。
//
// lyricsFileSuffixes 是 [".lrc", ".tr.lrc", ".roma.lrc", ".yrc"],而 ".lrc" 是
// ".tr.lrc"/".roma.lrc" 的真后缀 —— 按数组顺序首次命中,"X.tr.lrc" 会被判成主歌词、
// base 被截成 "X.tr",生成一个幻影分组。而分组的缓存 key 是按**文件头标签**
// ([ar:]/[ti:]/[al:])重建的(见本文件算法说明第 2 步),幻影组的标签跟本尊一模一样,
// 于是译文被当成主歌词写回 lyrics 字段,把原文永久覆盖。
//
// 实测确认这不是理论风险:用户磁盘上 5 个 .tr.lrc 里已有 2 条被这样毁掉
// (lyrics 与 lyrics_tr 字节数完全相同,导出的主 .lrc 也变成了译文),其中一条能跟
// 几小时前的缓存备份对上——原文 3608 字节被 1723 字节的译文顶掉。
//
// 修法只改这里的选择规则,**不动数组顺序**:按下标对齐这份列表的是**导出侧** ——
// lyricsexport.go 里的 entryJob.variants 是按 {Lyrics, LyricsTr, LyricsRoma, LyricsYRC}
// 的顺序填进去、再按同样下标取后缀的,重排这个数组会把导出的四个变体静默错位。导入侧
// 自己是按后缀取的(group.files 以后缀为键),不吃顺序,所以坏掉的只会是导出、而且无声。
// 抽成独立的纯函数是为了能被单测覆盖 —— importLyricsFromFiles 本身要读目录、没法直接测,
// 而这条规则一旦回退就会**静默毁数据**(不报错、不崩,只是原文被译文替换),必须有测试兜住。
func lyricsFileSuffixOf(name string) string {
	var suffix string
	for _, s := range lyricsFileSuffixes {
		if strings.HasSuffix(name, s) && len(s) > len(suffix) {
			suffix = s
		}
	}
	return suffix
}

// 这次启动的缓存没能完整读进来时,导入不能按「文件没动过就跳过」:跳过的前提是缓存里还是导出时那一份。
// lyricsImportRestoreAll:主缓存读不出 / 解析不动,从空库起;lyricsImportRestoreKeys:主缓存读进来了,但这几条
// 的正文小文件缺失或损坏,只剩主歌词。这些条目这一轮让 lyrics/ 里的文件赢,把译文 / 罗马音 / 逐字补回来 ——
// 不然导出看到字段是空的,会把正好存着它们的那几个文件删掉。只对下一次导入有效,用完即清。受 enrichMu 保护。
var (
	lyricsImportRestoreAll  bool
	lyricsImportRestoreKeys map[string]bool
)

// 返回值 = 这一轮真正被文件改写的条目数。调用方(main.go)据此决定要不要作废启动期迁移
// 水位:用户手改 lyrics/ 里的文件是**外来数据**入口,改过就得让后面那些存量迁移照常跑一遍
// (见 startupmigration.go)。老调用点忽略返回值即可,行为不变。
func importLyricsFromFiles() int { return importLyricsFromDir(lyricsDir()) }

// importLyricsFromFilesReadOnly 同 importLyricsFromFiles,给常驻进程可能正在跑时的一次性命令预演用:只改内存,
// 不落盘,也不清歌词临时文件(可能是常驻进程写到一半的)。
func importLyricsFromFilesReadOnly() int { return importLyricsFrom(lyricsDir(), false) }

// importLyricsFromDir 同 importLyricsFromFiles,只是扫的是指定目录。热切换歌词文件夹时先导入
// 新目录、再把 lyricsDir 指过去(见 lyricsdirswitch.go)。
func importLyricsFromDir(dir string) int { return importLyricsFrom(dir, true) }

// importLyricsFrom:persist=false 时不清临时文件、不保存缓存,其余与 importLyricsFromDir 相同。
func importLyricsFrom(dir string, persist bool) int {
	return importLyricsFromOpts(dir, persist, persist)
}

// importLyricsFromOpts:cleanTemps 决定清不清歌词临时文件 —— 只在还没有别的写入方的时候清(启动、刚切过去的新目录)。
// 常驻进程运行中的导入(从快照恢复)要传 false:另一轮导出可能正写到一半。
func importLyricsFromOpts(dir string, persist, cleanTemps bool) int {
	if dir == "" {
		return 0
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0 // 目录还不存在(全新安装,还没导出过任何东西)是正常情况
	}
	adopted := 0
	// 上次之后没人动过的文件不读(见 lyricsfilestate.go);整组都没动过就整组跳过。
	useState := lyricsFileStateEnabled(dir)

	type group struct {
		base      string
		files     map[string]string // suffix -> 完整路径
		infos     map[string]fs.FileInfo
		unchanged int
	}
	groups := make(map[string]*group)
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		// writeLyricsFileAtomic 崩溃/断电时可能留下 `X.lrc.tmp.123456` 这种临时文件,只在
		// 启动时清一次——导出过程中不能扫(会误删另一轮正在写的临时文件)。不在四个后缀里,
		// 下面的分组本来也认不出它,清扫只是别让它永远躺在文件夹里。
		if isLyricsTempFile(name) {
			if cleanTemps {
				_ = os.Remove(filepath.Join(dir, name))
			}
			continue
		}
		suffix := lyricsFileSuffixOf(name)
		if suffix == "" {
			continue // 不认识的文件(比如 .DS_Store),忽略
		}
		base := strings.TrimSuffix(name, suffix)
		g, ok := groups[base]
		if !ok {
			g = &group{base: base, files: map[string]string{}, infos: map[string]fs.FileInfo{}}
			groups[base] = g
		}
		g.files[suffix] = filepath.Join(dir, name)
		if useState {
			if info, err := ent.Info(); err == nil {
				g.infos[suffix] = info
				if _, same := lyricsFileUnchanged(dir, name, info); same {
					g.unchanged++
				}
			}
		}
	}

	// 同一个 key 可能落在两组文件里(大小写碰撞组缩回一个 key 后留下的 `~hash` 旧文件,导出会顺手清掉):
	// 按组里最新的修改时间从旧到新处理,新的那组最后写、赢,不吃 map 的随机顺序。
	groupsOldestFirst := make([]*group, 0, len(groups))
	newest := make(map[*group]int64, len(groups))
	for _, g := range groups {
		groupsOldestFirst = append(groupsOldestFirst, g)
		for suffix, path := range g.files {
			info, ok := g.infos[suffix]
			if !ok {
				if st, err := os.Stat(path); err == nil {
					info, ok = st, true
				}
			}
			if ok {
				newest[g] = max(newest[g], info.ModTime().UnixNano())
			}
		}
	}
	sort.Slice(groupsOldestFirst, func(i, j int) bool {
		a, b := groupsOldestFirst[i], groupsOldestFirst[j]
		if newest[a] != newest[b] {
			return newest[a] < newest[b]
		}
		return a.base < b.base
	})

	enrichMu.Lock()
	restoreAll, restoreKeys := lyricsImportRestoreAll, lyricsImportRestoreKeys
	lyricsImportRestoreAll, lyricsImportRestoreKeys = false, nil
	for _, g := range groupsOldestFirst {
		groupUnchanged := useState && g.unchanged == len(g.files)
		if groupUnchanged && !restoreAll && len(restoreKeys) == 0 {
			continue
		}
		// 组里每个文件只读一次:认身份的头部与各变体的正文都从这一份里取,读的时候顺手记下它的状态。
		bodies := make(map[string]parsedLyricsFile, len(g.files))
		for suffix, path := range g.files {
			data, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			bodies[suffix] = parseLyricsBytes(data)
			if info, ok := g.infos[suffix]; ok {
				recordLyricsFile(dir, filepath.Base(path), info, lyricsCRC(data))
			}
		}
		// 4 个后缀里随便挑一个能解析出头部的文件即可——同一组里的头部理应完全一致
		// (都是同一次 exportLyricsFiles 写出来的)。
		var parsed parsedLyricsFile
		for _, suffix := range lyricsFileSuffixes {
			if p, ok := bodies[suffix]; ok && p.ok {
				parsed = p
				break
			}
		}
		if !parsed.ok {
			continue // 整组都缺头(老版本文件),跳过,沿用 JSON 里的旧值
		}
		// 头部标签是导出时按**当时的** key 写进去的,老文件里可能还带着归一化之前的歌名
		// (`不散的筵席（I Miss You）`)。这里同样走 enrichKey,老文件才不会把一条已经归并
		// 好的记录又拆回两条。
		key := enrichKey(parsed.artist, parsed.title, parsed.album)
		if groupUnchanged && !restoreAll && !restoreKeys[key] {
			continue
		}
		// 一个变体读不出来、头部认不出(空文件、被别的程序改坏),或者头部说的不是这一首时**不采纳**:它的
		// 正文是空串,采纳了等于清空这个字段,紧接着导出看到字段为空就把文件删掉。保留缓存里的原值。
		variantBody := func(suffix string) (string, bool) {
			p, ok := bodies[suffix]
			if !ok || !p.ok || p.artist != parsed.artist || p.title != parsed.title || p.album != parsed.album {
				return "", false
			}
			return p.body, true
		}

		e := enrichCache[key] // 不存在时是 enrichEntry{} 零值,TS 自然留 0
		changed := false
		prevLyrics, prevTr, prevRoma := e.Lyrics, e.LyricsTr, e.LyricsRoma
		if v, ok := variantBody(".lrc"); ok {
			if e.Lyrics != v {
				e.Lyrics, changed = v, true
				// 歌词文件里没有背景人声(导出不写它),正文换了就清掉,别挂在新正文下面。
				e.LyricsBG = ""
			}
		}
		if v, ok := variantBody(".tr.lrc"); ok {
			if e.LyricsTr != v {
				e.LyricsTr, changed = v, true
				// 译文被文件里的内容顶替了,原来记的语言不再描述它 —— 清掉,让
				// translationUsable 退回文本判别,别拿旧语言给新内容背书。
				e.LyricsTrLang = ""
			}
		}
		if v, ok := variantBody(".roma.lrc"); ok {
			if e.LyricsRoma != v {
				e.LyricsRoma, changed = v, true
			}
		}
		if v, ok := variantBody(".yrc"); ok {
			if e.LyricsYRC != v {
				e.LyricsYRC, changed = v, true
				e.LyricsBG = ""
			}
		}
		// 正文被文件换了、译文 / 罗马音那两个文件却没动:它们描述的是旧正文(同歌词管理保存那条规则,见 applySaveEdit)。
		// 机翻清掉、留给机翻重翻;罗马音清掉,导出时同步删掉 .roma.lrc。用户自己的、歌词源自带的译文不动。
		if prevLyrics != "" && e.Lyrics != prevLyrics {
			if e.LyricsTr != "" && e.LyricsTr == prevTr && e.LyricsTrSource == lyricsTrSourceMachine {
				e.LyricsTr, e.LyricsTrLang, e.LyricsTrSource = "", "", ""
				e.TranslationTS, e.TranslationRetryCount = 0, 0
			}
			if e.LyricsRoma != "" && e.LyricsRoma == prevRoma {
				e.LyricsRoma = ""
			}
		}
		if e.LyricsSource != parsed.source {
			e.LyricsSource, changed = parsed.source, true
		}
		if e.ManualLyrics != parsed.manual {
			e.ManualLyrics, changed = parsed.manual, true
		}
		if changed {
			enrichCache[key] = e
			enrichDirty = true
			adopted++
		}
	}
	enrichMu.Unlock()
	if persist {
		saveEnrichCache() // 内部会检查 enrichDirty,这一轮什么都没变时是无害的空操作
	}
	return adopted
}
