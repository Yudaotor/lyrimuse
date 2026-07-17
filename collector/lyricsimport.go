// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"os"
	"path/filepath"
	"regexp"
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
// ⚠️ 按"固定行号"读头部,不能按"这行长得像不像标签"来扫描——这是手改测试时才发现的
// 真实坑:有些歌词源自己抓下来的原文第一行就是 "[ti:xxx]" 这种它自己的 ID 标签(不是
// 我们写的头),如果解析器靠"匹配上已知标签正则就当头部、不匹配才算正文开始"这种扫描式
// 判断,会把这类真实歌词内容里的第一行也误吞成头部,导致重新导入时正文少了这一行、
// 且每次重启都会把这行从 JSON 里悄悄裁掉。头部格式是我们自己完全定义、完全可控的——
// 固定是"[ar:]、[ti:]、[al:] 三行必有,后面可能有 [source:]、可能有
// [manual:1]，然后必须紧跟一个空行分隔符"，所以直接按这个固定结构从第 1 行开始逐行
// 消费,消费完头部该有的这几行(不管内容是什么，只看行号和是否匹配得上对应位置该有的
// 标签)之后，空行分隔符之后的所有内容,不管长什么样,都原样当正文,不再做任何"像不像
// 标签"的判断。老版本(这次改动之前导出的、完全没有头)文件在第 1 行就匹配不上 [ar:],
// 直接判定 ok=false,调用方(importLyricsFromFiles)据此跳过整组、沿用 JSON 缓存里的
// 旧值,不会因为升级过程本身丢数据。
func parseLyricsFile(path string) parsedLyricsFile {
	var p parsedLyricsFile
	data, err := os.ReadFile(path)
	if err != nil {
		return p
	}
	lines := strings.Split(string(data), "\n")
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
	// 2026-07-15 真机实测坐实过一次由这个漏洞造成的真实数据损坏:酷狗抓下来的歌词原文
	// 自己就带 "[ti:]\r\n[ar:]\r\n[al:]\r\n" 这三行(它自己的、留空的 ID 标签,不是我们
	// 写的头),当时还在用"扫描式"解析(见上面关于固定行号解析的说明)的那一版代码,把这
	// 几行也误当成头部消费掉,把一条本来正常的 "PRINCE|Shhh|The Gold Experience" 记录
	// 覆盖坏成了 key 为 "||" 的空身份记录,还带着少了这三行的正文,一直靠这条校验通过
	// 才能在后续每次重启里持续存活、污染"歌词管理"列表(显示成空白的"-")。换成固定行号
	// 解析已经堵住了"被歌词原文自己的标签行覆盖"这条路,但这里必须补上"内容不能是空的"
	// 这层校验,否则哪怕未来因为别的原因真出现一个头部标签格式对、内容却是空的文件,
	// 也会被当成合法数据继续导入。album 允许是空字符串(有些曲目本来就没有专辑名),
	// 不在这个校验范围内。
	p.ok = p.artist != "" && p.title != ""
	return p
}

// readVariantBody 读一个歌词变体文件、拆出去掉头部之后的正文——path 为空(这组里根本
// 没有这个变体对应的文件)时返回空字符串。
func readVariantBody(path string) string {
	if path == "" {
		return ""
	}
	return parseLyricsFile(path).body
}

// importLyricsFromFiles 在启动时把 lyrics/ 文件夹里的内容,采纳进 enrichCache 对应
// 条目的歌词家族字段(Lyrics/LyricsTr/LyricsRoma/LyricsYRC/LyricsSource/ManualLyrics)。
//
// 2026-07-15: 这是"歌词部分以 lyrics/ 文件夹为权威源"改造的导入/调和步骤,main.go 里
// 排在 loadEnrichCache 之后、exportLyricsFiles 之前。
//
// ⚠️ 只增不删,是真机测试实测坐实的教训,不是理论上的谨慎:第一版实现里还有"文件夹扫描
// 找不到对应文件就整条删除/清空字段"这一步,上线第一次重启就把 200 条里几十条的
// lyrics_tr/lyrics_yrc 悄悄清空了——根因是这个项目已知会复现的专辑名大小写问题(同一首
// 歌因为 media-control 读到的大小写跟真实库 tag 不一致,长出两条缓存条目),这两条
// sanitizeLyricsFilename 出来的文件名在 macOS 默认大小写不敏感的文件系统上其实是
// 同一个文件——先写的那条被后写的悄悄覆盖(exportLyricsFiles 那次改动已经修了这个
// 碰撞本身,见其注释里的确定性哈希后缀),但"文件因为这个 bug 意外丢失"和"用户真的想
// 删除这条歌词"这两种情况,从"文件不存在"这一个信号上根本区分不出来。所以现在的设计是:
// 文件存在且内容有变化 → 采纳(这是安全的,文件内容是明确的正向信号);文件不存在 →
// 什么都不做,保留 JSON 里已有的值(不管这个"不存在"是 bug 造成的、还是用户故意删的,
// 保守地什么都不做都不会丢数据)。真正的"删除这首歌的歌词"只走 desktop-lyrics"歌词
// 管理"窗口的删除按钮(EnrichCacheStore.delete/removeWordTiming)——那两个操作在同一次
// 调用里显式地、同时地删掉 JSON 字段和对应文件,不依赖这里的推断,天然不会有这个问题。
// 代价:直接在 Finder 里手动删掉一份 .lrc/.yrc 文件,不会让对应缓存字段跟着清空(下次
// export 反而会照着 JSON 里还在的旧值把删掉的文件重新写回来)——这是刻意的取舍,不是
// 遗漏:安全地"不许当前设计推断删除",比"支持一种更方便但会在数据质量问题存在期间
// 反复搞丢真实用户数据的推断机制"更重要。
//
// 算法:
//  1. 扫 lyricsDir,按去掉后缀的文件名前缀分组(同一首歌的 .lrc/.tr.lrc/.roma.lrc/.yrc
//     文件,文件名前缀完全一样)。
//  2. 每组内挑一个能解析出头部的文件,还原出 (artist,title,album)——不信任文件名本身
//     (sanitizeLyricsFilename 是单向有损转换,见 lyricsexport.go),头部标签才是权威
//     身份信息。整组都缺头(老版本文件,这次改动之前导出的)就跳过,沿用 JSON 里已有
//     的旧值。
//  3. 对每个能还原出 key 的分组:只处理这个组里**实际存在**的那几个变体文件——每个
//     变体单独判断"文件是否存在",存在就用它的内容覆盖对应字段(内容不同才算变化),
//     不存在就完全不碰那个字段,不清空、不删除。新建条目时 TS 是 enrichEntry 的零值
//     (不主动设成 time.Now()),这样 needsPeripheralBackfill 会在这首歌真正被播放时
//     立刻补上封面/链接,而不是被 10 分钟节流误伤。
func importLyricsFromFiles() {
	if lyricsDir == "" {
		return
	}
	entries, err := os.ReadDir(lyricsDir)
	if err != nil {
		return // 目录还不存在(全新安装,还没导出过任何东西)是正常情况
	}

	type group struct{ files map[string]string } // suffix -> 完整路径
	groups := make(map[string]*group)
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		var suffix string
		for _, s := range lyricsFileSuffixes {
			if strings.HasSuffix(name, s) {
				suffix = s
				break
			}
		}
		if suffix == "" {
			continue // 不认识的文件(比如 .DS_Store),忽略
		}
		base := strings.TrimSuffix(name, suffix)
		g, ok := groups[base]
		if !ok {
			g = &group{files: map[string]string{}}
			groups[base] = g
		}
		g.files[suffix] = filepath.Join(lyricsDir, name)
	}

	enrichMu.Lock()
	for _, g := range groups {
		// 4 个后缀里随便挑一个能解析出头部的文件即可——同一组里的头部理应完全一致
		// (都是同一次 exportLyricsFiles 写出来的)。
		var parsed parsedLyricsFile
		for _, suffix := range lyricsFileSuffixes {
			path, ok := g.files[suffix]
			if !ok {
				continue
			}
			if p := parseLyricsFile(path); p.ok {
				parsed = p
				break
			}
		}
		if !parsed.ok {
			continue // 整组都缺头(老版本文件),跳过,沿用 JSON 里的旧值
		}
		key := parsed.artist + "|" + parsed.title + "|" + parsed.album

		e := enrichCache[key] // 不存在时是 enrichEntry{} 零值,TS 自然留 0
		changed := false
		if path, ok := g.files[".lrc"]; ok {
			if v := readVariantBody(path); e.Lyrics != v {
				e.Lyrics, changed = v, true
			}
		}
		if path, ok := g.files[".tr.lrc"]; ok {
			if v := readVariantBody(path); e.LyricsTr != v {
				e.LyricsTr, changed = v, true
			}
		}
		if path, ok := g.files[".roma.lrc"]; ok {
			if v := readVariantBody(path); e.LyricsRoma != v {
				e.LyricsRoma, changed = v, true
			}
		}
		if path, ok := g.files[".yrc"]; ok {
			if v := readVariantBody(path); e.LyricsYRC != v {
				e.LyricsYRC, changed = v, true
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
		}
	}
	enrichMu.Unlock()
	saveEnrichCache() // 内部会检查 enrichDirty,这一轮什么都没变时是无害的空操作
}
