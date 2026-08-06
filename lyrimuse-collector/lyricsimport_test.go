package main

import "testing"

// 回归测试:2026-08-06 之前这里是"按 lyricsFileSuffixes 顺序首次命中就 break",而 ".lrc"
// 是 ".tr.lrc"/".roma.lrc" 的真后缀 —— "X.tr.lrc" 被判成主歌词、base 截成 "X.tr",
// 生成一个幻影分组;分组的缓存 key 又是按文件头标签重建的,幻影组的标签跟本尊一样,
// 于是译文覆盖了原文。实测在用户磁盘上真的毁掉过条目,所以这条规则必须钉死。
func TestLyricsFileSuffixOfPicksLongestMatch(t *testing.T) {
	cases := []struct{ name, want string }{
		{"Artist - Title - Album.lrc", ".lrc"},
		{"Artist - Title - Album.tr.lrc", ".tr.lrc"},
		{"Artist - Title - Album.roma.lrc", ".roma.lrc"},
		{"Artist - Title - Album.yrc", ".yrc"},
		// 带消歧哈希的文件名(见 lyricsexport.go 的 base~%06x)同样要认对
		{"Artist - Title - Album~1a2b3c.tr.lrc", ".tr.lrc"},
		// 不认识的文件必须返回空串,让调用方跳过
		{".DS_Store", ""},
		{"cover.jpg", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := lyricsFileSuffixOf(c.name); got != c.want {
			t.Errorf("lyricsFileSuffixOf(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

// 分组键是"去掉后缀之后的部分",三个变体必须落进同一个组。
func TestLyricsFileVariantsShareOneGroup(t *testing.T) {
	const base = "Michael Jackson - Blue Gangsta - XSCAPE (Deluxe)"
	for _, suffix := range lyricsFileSuffixes {
		name := base + suffix
		got := lyricsFileSuffixOf(name)
		if got != suffix {
			t.Fatalf("lyricsFileSuffixOf(%q) = %q, want %q", name, got, suffix)
		}
		if trimmed := name[:len(name)-len(got)]; trimmed != base {
			t.Errorf("%q 去掉后缀后是 %q, want %q", name, trimmed, base)
		}
	}
}
