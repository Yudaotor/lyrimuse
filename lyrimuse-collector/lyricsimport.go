// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
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
// ⚠️ 按"固定行号"读头部,不能按"这行长得像不像标签"来扫描:有些歌词源原文第一行就是
// "[ti:xxx]" 这类它自己的 ID 标签(不是我们写的头),扫描式判断会把这种内容行误吞成
// 头部,导致正文缺行且每次重启都被悄悄裁掉。头部结构固定为 [ar:]/[ti:]/[al:] 三行、
// 可选 [source:]/[manual:1]、之后必须紧跟一个空行分隔符,因此只按行号消费,不做"像不像
// 标签"的判断。老版本(改动前导出、完全没有头)文件第 1 行就匹配不上 [ar:],直接判
// ok=false,调用方(importLyricsFromFiles)据此跳过整组、沿用 JSON 里的旧值。
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
	// 有些歌词源原文自带的空 ID 标签行(比如酷狗的 "[ti:]\r\n[ar:]\r\n[al:]\r\n")在旧的
	// 扫描式解析下会被误当成头部消费,产出 key 为 "||" 的空身份记录并持续污染"歌词管理"
	// 列表,因此这里必须补上"内容不能是空"这层校验。album 允许是空字符串(有些曲目本来
	// 就没有专辑名),不在这个校验范围内。
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
// 是"歌词部分以 lyrics/ 文件夹为权威源"的导入/调和步骤,main.go 里排在 loadEnrichCache
// 之后、exportLyricsFiles 之前。
//
// ⚠️ 只增不删:文件不存在不代表用户想删——专辑名大小写不一致会让同一首歌长出两条缓存
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
//  1. 扫 lyricsDir,按去掉后缀的文件名前缀分组(同一首歌的 .lrc/.tr.lrc/.roma.lrc/.yrc)。
//  2. 组内挑一个能解析出头部的文件还原 (artist,title,album)——文件名本身不可信
//     (sanitizeLyricsFilename 是单向有损转换,见 lyricsexport.go),头部标签才是权威
//     身份信息。整组都缺头(老版本文件)就跳过,沿用 JSON 里的旧值。
//  3. 对每个能还原出 key 的分组:只处理组里实际存在的变体文件,存在就用其内容覆盖对应
//     字段(内容不同才算变化),不存在就不碰。新建条目时 TS 留 enrichEntry 零值(不设
//     time.Now()),这样 needsPeripheralBackfill 会在这首歌真正被播放时才补封面/链接,
//     不会被 10 分钟节流误伤。
//
// ⚠️ 必须挑**最长**的匹配后缀,不能"首次命中就 break"。
//
// lyricsFileSuffixes 是 [".lrc", ".tr.lrc", ".roma.lrc", ".yrc"],而 ".lrc" 是
// ".tr.lrc"/".roma.lrc" 的真后缀 —— 按数组顺序首次命中,"X.tr.lrc" 会被判成主歌词、
// base 被截成 "X.tr",生成一个幻影分组。而分组的缓存 key 是按**文件头标签**
// ([ar:]/[ti:]/[al:])重建的(见本文件算法说明第 2 步),幻影组的标签跟本尊一模一样,
// 于是译文被当成主歌词写回 lyrics 字段,把原文永久覆盖。
//
// 2026-08-06 实测确认这不是理论风险:用户磁盘上 5 个 .tr.lrc 里已有 2 条被这样毁掉
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
		suffix := lyricsFileSuffixOf(name)
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
				// 译文被文件里的内容顶替了,原来记的语言不再描述它 —— 清掉,让
				// translationUsable 退回文本判别,别拿旧语言给新内容背书。
				e.LyricsTrLang = ""
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
