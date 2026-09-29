package main

import (
	"os"
	"strings"
	"testing"
)

// 查询词:日文歌(任一栏带假名)三栏原样,不把「夢」转成「梦」;中文照旧繁转简;中文人名的间隔号「・」不算假名。
func TestSearchQueryFields(t *testing.T) {
	cases := []struct {
		in, want [3]string
	}{
		{[3]string{"宇多田ヒカル", "君に夢中", "BADモード"}, [3]string{"宇多田ヒカル", "君に夢中", "BADモード"}},
		{[3]string{"宇多田ヒカル", "夢", ""}, [3]string{"宇多田ヒカル", "夢", ""}},
		{[3]string{"周杰倫", "晴天", "葉惠美"}, [3]string{"周杰伦", "晴天", "叶惠美"}},
		{[3]string{"麥可・傑克森", "顫慄", ""}, [3]string{"麦可・杰克森", "颤栗", ""}},
		{[3]string{"Utada", "First Love", ""}, [3]string{"Utada", "First Love", ""}},
	}
	for _, c := range cases {
		a, ti, al := searchQueryFields(c.in[0], c.in[1], c.in[2])
		if got := [3]string{a, ti, al}; got != c.want {
			t.Errorf("searchQueryFields(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// 接线守卫:发查询的几处都走 searchQueryFields,别再直接 toSimplified 三栏。
func TestSearchQueryFieldsIsWired(t *testing.T) {
	for file, needle := range map[string]string{
		"enrich.go":              "artist, title, album = searchQueryFields(artist, title, album)",
		"searchcli.go":           "sArtist, sTitle, sAlbum := searchQueryFields(*artist, *title, *album)",
		"resynclyricscli.go":     "artist, title, album = searchQueryFields(artist, title, album)",
		"testlyricsourcescli.go": "searchQueryFields(artist, title, album)",
		"healthcheckcli.go":      "searchQueryFields(p.artist, p.title, p.album)",
	} {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(b), needle) {
			t.Errorf("%s 发查询没走 searchQueryFields", file)
		}
		if strings.Contains(string(b), "toSimplified(title), toSimplified(album)") {
			t.Errorf("%s 还在直接把三栏 toSimplified 了再发查询", file)
		}
	}
}
