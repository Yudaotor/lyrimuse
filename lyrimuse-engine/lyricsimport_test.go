package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 回归测试:之前这里是"按 lyricsFileSuffixes 顺序首次命中就 break",而 ".lrc"
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

// 老文件头部写的是播放器原样的歌名(带结尾说明括号),条目是按旧规则(去掉括号)建的:导入落到旧规则那条上,
// 不另建一条。旧规则那条已经是另一种带括号写法的,不借,照旧按完整歌名建。
func TestImportFallsBackToLegacyKeyForBracketedHeader(t *testing.T) {
	legacy := "陈奕迅|不散的筵席|专辑"
	full := "陈奕迅|不散的筵席（I Miss You）|专辑"
	for _, c := range []struct {
		name     string
		reported map[string]reportedName
		wantKey  string
	}{
		{"旧规则那条没被占", nil, legacy},
		{"旧规则那条是另一种写法的", map[string]reportedName{"x": {Title: "不散的筵席（Other）"}}, full},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := withExportFixture(t, map[string]enrichEntry{legacy: {Lyrics: "[00:01.00]原文", LyricsSource: "netease", Reported: c.reported}})
			exportLyricsFiles()
			path := filepath.Join(dir, sanitizeLyricsFilename(legacy)+".lrc")
			orig, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			old := strings.Replace(string(orig), "不散的筵席]", "不散的筵席（I Miss You）]", 1)
			old = strings.Replace(old, "原文", "改过", 1)
			if old == string(orig) || !strings.Contains(old, "（I Miss You）") {
				t.Fatalf("前提:头部里的歌名没换掉: %q", orig)
			}
			if err := os.WriteFile(path, []byte(old), 0o644); err != nil {
				t.Fatal(err)
			}
			importLyricsFrom(dir, false)
			enrichMu.Lock()
			got, ok := enrichCache[c.wantKey]
			_, fullExists := enrichCache[full]
			enrichMu.Unlock()
			if !ok || got.Lyrics != "[00:01.00]改过" {
				t.Fatalf("手改应落在 %q 上: ok=%v %q", c.wantKey, ok, got.Lyrics)
			}
			if c.wantKey == legacy && fullExists {
				t.Error("不该按完整歌名另建一条")
			}
		})
	}
}
