package main

import "testing"

// TestQQAlbumIdentityQuery 钉死专辑维度查询词的剥词规则(实测 smartbox 对多余的词零容忍:
// "周杰伦 The One 周杰伦演唱会" 0 条、"周杰伦 The One" 命中,见 qqAlbumIdentityQuery 注释)。
func TestQQAlbumIdentityQuery(t *testing.T) {
	cases := []struct {
		artist, album, want string
	}{
		// 本案:歌手名+演唱会后缀都要剥掉
		{"周杰伦", "The One 周杰伦演唱会", "the one"},
		// 陈奕迅 Easy Ride 形态:括号段(Live)先剥,再剥演唱会
		{"陈奕迅", "The Easy Ride 演唱会 (Live)", "the easy ride"},
		// 繁体折简体后再剥
		{"蔡健雅", "My Space 演唱會紀念盤", "my space 纪念盘"},
		// 拉丁 live 类通用词按整词剥
		{"Eason Chan", "Get A Life Concert", "get a life"},
		// 没有可剥成分时原样(小写)保留
		{"周杰伦", "八度空间", "八度空间"},
	}
	for _, c := range cases {
		if got := qqAlbumIdentityQuery(c.artist, c.album); got != c.want {
			t.Errorf("qqAlbumIdentityQuery(%q, %q) = %q, want %q", c.artist, c.album, got, c.want)
		}
	}
}
