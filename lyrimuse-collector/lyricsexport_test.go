package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"
)

// 歌词文件族改原子写(writeLyricsFileAtomic)。
// 靶的是一条性质:磁盘上的文件要么是旧的完整内容、要么是新的完整内容,写入过程里没有
// 第三种状态;临时文件不能泄漏、不能被导入/扫描误认。

func TestWriteLyricsFileAtomicReplacesWholeFileAndLeavesNoTemp(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "A - B - C.lrc")
	if err := writeLyricsFileAtomic(path, []byte("[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]one")); err != nil {
		t.Fatal(err)
	}
	if err := writeLyricsFileAtomic(path, []byte("[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]two")); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil || !strings.HasSuffix(string(got), "two") {
		t.Fatalf("第二次写入应整体替换,实际 %q err=%v", got, err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 || entries[0].Name() != "A - B - C.lrc" {
		names := []string{}
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("目录里只该剩目标文件,实际 %v", names)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("权限应补成 0644(跟以前 os.WriteFile 导出的一致),实际 %o", info.Mode().Perm())
	}
}

// 目录不存在时写入失败,但不能在别处留下任何东西;失败要报出来而不是吞掉。
func TestWriteLyricsFileAtomicFailsCleanly(t *testing.T) {
	dir := t.TempDir()
	if err := writeLyricsFileAtomic(filepath.Join(dir, "missing", "x.lrc"), []byte("x")); err == nil {
		t.Fatal("目标目录不存在应报错")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatalf("失败后不该留任何文件,实际 %d 个", len(entries))
	}
}

// 临时文件名不以四个歌词后缀收尾——导入分组、Swift 侧扫描与备份归档都按后缀过滤,会自动
// 忽略它;反过来用户自己命名成 "xx.tmp.lrc" 的正常文件绝不能被当垃圾。
func TestIsLyricsTempFile(t *testing.T) {
	cases := map[string]bool{
		"A - B - C.lrc.tmp.123456": true,
		"A - B - C.tr.lrc.tmp.9":   true,
		"A - B - C.yrc.tmp.abc":    true,
		"A - B - C.lrc":            false,
		"A - B - C.tr.lrc":         false,
		"weird.tmp.lrc":            false, // 以 .lrc 收尾,是正常歌词文件
		"weird.tmp.yrc":            false,
		".DS_Store":                false,
	}
	for name, want := range cases {
		if got := isLyricsTempFile(name); got != want {
			t.Errorf("isLyricsTempFile(%q) = %v, want %v", name, got, want)
		}
	}
	for _, name := range []string{"A - B - C.lrc.tmp.123456", "A - B - C.tr.lrc.tmp.9"} {
		if lyricsFileSuffixOf(name) != "" {
			t.Errorf("临时文件 %q 不该被导入分组认成歌词变体", name)
		}
	}
}

// 启动导入会清掉崩溃残留的临时文件,且只清临时文件——四个后缀的正常文件、别的文件都不碰。
func TestImportLyricsFromFilesSweepsTempFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	full := "[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]one\n[00:02.00]two\n[00:03.00]three"
	write("A - B - C.lrc", full)
	write("A - B - C.lrc.tmp.111111", "[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]half")
	write("A - B - C.yrc.tmp.222222", "garbage")
	write(".DS_Store", "x")

	savedDir, savedCache := lyricsDir, enrichCache
	t.Cleanup(func() {
		enrichMu.Lock()
		lyricsDir, enrichCache = savedDir, savedCache
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	lyricsDir = dir
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()

	importLyricsFromFiles()

	entries, _ := os.ReadDir(dir)
	names := map[string]bool{}
	for _, e := range entries {
		names[e.Name()] = true
	}
	if names["A - B - C.lrc.tmp.111111"] || names["A - B - C.yrc.tmp.222222"] {
		t.Fatalf("临时文件应被清扫,实际剩下 %v", names)
	}
	if !names["A - B - C.lrc"] || !names[".DS_Store"] {
		t.Fatalf("正常文件不该被动,实际 %v", names)
	}
	enrichMu.Lock()
	e := enrichCache[enrichKey("A", "B", "C")]
	enrichMu.Unlock()
	if !strings.HasSuffix(e.Lyrics, "three") {
		t.Fatalf("导入应采纳完整的 .lrc 正文而不是临时文件里的半截,实际 %q", e.Lyrics)
	}
}

// 八个调用点没有锁,两轮导出可能同时写同一个文件——各写各的临时文件再改名,最后落盘的
// 必须是一份完整、头部能解析、正文等于缓存的文件,不能出现 WriteFile 那种互相截断交错。
func TestExportLyricsFilesConcurrentWritesStayWhole(t *testing.T) {
	dir := t.TempDir()
	savedDir, savedCache := lyricsDir, enrichCache
	t.Cleanup(func() {
		enrichMu.Lock()
		lyricsDir, enrichCache = savedDir, savedCache
		enrichMu.Unlock()
	})
	body := strings.Repeat("[00:01.00]一行歌词正文用来把文件撑长一点,交错截断才看得出来\n", 200)
	enrichMu.Lock()
	lyricsDir = dir
	enrichCache = map[string]enrichEntry{"歌手|歌名|专辑": {Lyrics: body, LyricsSource: "qq"}}
	enrichMu.Unlock()

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			exportLyricsFiles()
		}()
	}
	wg.Wait()

	path := filepath.Join(dir, "歌手 - 歌名 - 专辑.lrc")
	p := parseLyricsFile(path)
	if !p.ok {
		t.Fatalf("并发导出后头部应仍可解析,文件 %s", path)
	}
	if p.body != body {
		t.Fatalf("并发导出后正文应与缓存逐字节相同,实际长度 %d 期望 %d", len(p.body), len(body))
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if isLyricsTempFile(e.Name()) {
			t.Fatalf("并发导出不该留下临时文件: %s", e.Name())
		}
	}
}

// TestTruncateFilenameBase 长度上限只在超限时生效,且绝不切出半个 UTF-8 字符。
func TestTruncateFilenameBase(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want func(string) error
	}{
		{"短名原样返回", "陈绮贞 - 灵感 - 还是会寂寞", func(got string) error {
			if got != "陈绮贞 - 灵感 - 还是会寂寞" {
				return fmt.Errorf("被改动了: %q", got)
			}
			return nil
		}},
		{"正好等于上限不截", strings.Repeat("a", lyricsFilenameMaxBytes), func(got string) error {
			if len(got) != lyricsFilenameMaxBytes {
				return fmt.Errorf("长度 %d", len(got))
			}
			return nil
		}},
		{"ASCII 超限截到上限", strings.Repeat("a", lyricsFilenameMaxBytes+50), func(got string) error {
			if len(got) != lyricsFilenameMaxBytes {
				return fmt.Errorf("长度 %d,期望 %d", len(got), lyricsFilenameMaxBytes)
			}
			return nil
		}},
		// 汉字 3 字节:200 不是 3 的倍数,截断点必然落在字符中间,是这个函数最要紧的用例。
		{"汉字不被切成半个", strings.Repeat("歌", 100), func(got string) error {
			if !utf8.ValidString(got) {
				return fmt.Errorf("切出了非法 UTF-8: %q", got)
			}
			if strings.ContainsRune(got, utf8.RuneError) {
				return fmt.Errorf("出现了替换字符: %q", got)
			}
			if len(got) > lyricsFilenameMaxBytes {
				return fmt.Errorf("超限 %d", len(got))
			}
			// 200/3 = 66 个整字 = 198 字节,第 67 个字会越界。
			if n := utf8.RuneCountInString(got); n != 66 {
				return fmt.Errorf("留下 %d 个字,期望 66", n)
			}
			return nil
		}},
		{"emoji(4 字节)不被切开", strings.Repeat("🎵", 60), func(got string) error {
			if strings.ContainsRune(got, utf8.RuneError) {
				return fmt.Errorf("出现了替换字符: %q", got)
			}
			if len(got) > lyricsFilenameMaxBytes {
				return fmt.Errorf("超限 %d", len(got))
			}
			return nil
		}},
		// "abc " 是 4 字节一组,200 % 4 == 0 → 第 200 个字节(下标 199)正好是空格,
		// 截断点必然落在空格上。⚠️ 别改成 3 字节的组:那样切在字母上,这条用例就废了
		// (变异测试实测:改回 "ab " 后"不 trim"的变异能存活)。
		{"截断点落在空格上要 trim 掉", strings.Repeat("abc ", 60), func(got string) error {
			if strings.HasSuffix(got, " ") {
				return fmt.Errorf("留下了尾部空格: %q", got)
			}
			return nil
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := c.want(truncateFilenameBase(c.in)); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// TestSanitizeLyricsFilenameFitsAtomicWrite 这条是整个修复的要害:base 加上最长的后缀、
// 再加上 writeLyricsFileAtomic 的临时文件后缀,必须仍然落在文件系统的 255 字节之内 ——
// 否则导出会一直 ENAMETOOLONG 失败并反复重试,正是这次要修的 bug。
func TestSanitizeLyricsFilenameFitsAtomicWrite(t *testing.T) {
	// 照抄真实数据里那条最长的:20 多位参与者的合唱署名。
	key := strings.Repeat("Michael Jackson & Elmer Bernstein & Jeremy Lubbock & ", 8) +
		"|Earth Song (Radio Edit)|Number Ones"
	base := sanitizeLyricsFilename(key)

	longestSuffix := ""
	for _, s := range lyricsFileSuffixes {
		if len(s) > len(longestSuffix) {
			longestSuffix = s
		}
	}
	// 消歧后缀 `~xxxxxx` 也要能接上去。
	withHash := fmt.Sprintf("%s~%06x", base, uint32(0xFFFFFF))
	const tmpOverhead = 14 // 实测 `.tmp.` + 随机数

	for _, n := range []struct {
		what string
		s    string
	}{
		{"base+后缀", base + longestSuffix},
		{"base+后缀+临时后缀", base + longestSuffix + strings.Repeat("x", tmpOverhead)},
		{"消歧名+后缀+临时后缀", withHash + longestSuffix + strings.Repeat("x", tmpOverhead)},
	} {
		if len(n.s) > 255 {
			t.Errorf("%s 长 %d 字节,超过文件系统 255 上限", n.what, len(n.s))
		}
	}

	// 真的写一遍,确认不再 ENAMETOOLONG。
	dir := t.TempDir()
	if err := writeLyricsFileAtomic(filepath.Join(dir, base+longestSuffix), []byte("x")); err != nil {
		t.Fatalf("按截断后的文件名写入仍然失败: %v", err)
	}
}

// TestExportLyricsFilesRemovesUntruncatedLeftover 长度上限是后加的,之前 os.WriteFile
// 能把 255 字节以内的长文件名写成功。那批存量文件必须删掉 —— importLyricsFromFiles 按
// 文件**头部标签**重建 key、不看文件名,留着它下次启动就会把旧内容导回来顶掉新的。
func TestExportLyricsFilesRemovesUntruncatedLeftover(t *testing.T) {
	dir := t.TempDir()
	oldDir := lyricsDir
	lyricsDir = dir
	t.Cleanup(func() { lyricsDir = oldDir })

	// 构造一个会被截断、但截断前仍在 255 以内的 key。
	// 拼出来 212 字节:超过 200 的上限,但加上 ".lrc" 仍在 255 以内 —— 正是那批
	// "当初写得进去、现在再也更新不了"的存量文件的形状。
	artist := strings.Repeat("A", 140)
	title := strings.Repeat("B", 60)
	key := artist + "|" + title + "|专辑"
	untruncated := sanitizeLyricsFilenameUntruncated(key)
	truncated := sanitizeLyricsFilename(key)
	if untruncated == truncated {
		t.Fatalf("这个 key 没被截断,用例前提不成立(len=%d)", len(untruncated))
	}
	if len(untruncated+".lrc") > 255 {
		t.Fatalf("用例前提不成立:旧名 %d 字节,当初也写不进去", len(untruncated+".lrc"))
	}

	leftover := filepath.Join(dir, untruncated+".lrc")
	if err := os.WriteFile(leftover, []byte("[ar:旧]\n[ti:旧]\n\n[00:01.00]旧内容\n"), 0o644); err != nil {
		t.Fatalf("造存量文件失败: %v", err)
	}

	enrichMu.Lock()
	oldCache := enrichCache
	enrichCache = map[string]enrichEntry{key: {Lyrics: "[00:01.00]新内容\n"}}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichCache = oldCache
		enrichMu.Unlock()
	})

	exportLyricsFiles()

	if _, err := os.Stat(leftover); !os.IsNotExist(err) {
		t.Fatalf("截断前的存量文件没被清掉: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, truncated+".lrc")); err != nil {
		t.Fatalf("截断后的新文件没写出来: %v", err)
	}
}

// TestSanitizeLyricsFilenameTruncationStillDisambiguates 截断会把两个原本不同的长 key
// 压成同一个名字,必须由已有的碰撞消歧接住,各写各的文件。
func TestSanitizeLyricsFilenameTruncationStillDisambiguates(t *testing.T) {
	dir := t.TempDir()
	oldDir := lyricsDir
	lyricsDir = dir
	t.Cleanup(func() { lyricsDir = oldDir })

	prefix := strings.Repeat("同", 80) // 240 字节,远超上限
	k1 := prefix + "甲|歌名|专辑"
	k2 := prefix + "乙|歌名|专辑"
	if sanitizeLyricsFilename(k1) != sanitizeLyricsFilename(k2) {
		t.Fatalf("用例前提不成立:两个 key 截断后没撞名")
	}

	enrichMu.Lock()
	oldCache := enrichCache
	enrichCache = map[string]enrichEntry{
		k1: {Lyrics: "[00:01.00]甲的歌词\n"},
		k2: {Lyrics: "[00:01.00]乙的歌词\n"},
	}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichCache = oldCache
		enrichMu.Unlock()
	})

	exportLyricsFiles()

	found := map[string]bool{}
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		if strings.Contains(string(b), "甲的歌词") {
			found["甲"] = true
		}
		if strings.Contains(string(b), "乙的歌词") {
			found["乙"] = true
		}
	}
	if !found["甲"] || !found["乙"] {
		t.Fatalf("截断撞名后有内容丢失,磁盘上只找到 %v(共 %d 个文件)", found, len(ents))
	}
}
