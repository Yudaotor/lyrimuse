package main

import "testing"

func TestCoverThumbURL(t *testing.T) {
	const apple = "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/25/f2/54/25f254a4-fb47-4149-0410-75ed463a77d1/ticket.qbamtedn.jpg/"
	cases := []struct{ in, want string }{
		// Apple 原图档(几 MB)换成 64 档。
		{apple + "10000x10000bb.jpg", apple + "64x64bb.jpg"},
		{apple + "1200x1200bb.jpg", apple + "64x64bb.jpg"},
		{"https://p1.music.126.net/a/1.jpg?param=800y800", "https://p1.music.126.net/a/1.jpg?param=64y64"},
		{"https://i.kfs.io/album/global/1,0v1/fit/500x500.jpg", "https://i.kfs.io/album/global/1,0v1/fit/64x64.jpg"},
		{"https://d.musicapp.migu.cn/a/b.webp", "https://d.musicapp.migu.cn/a/b.jpg"},
		// 认不出尺寸段的 Apple 地址、别家的地址原样。
		{"https://is1-ssl.mzstatic.com/image/thumb/x/source.png", "https://is1-ssl.mzstatic.com/image/thumb/x/source.png"},
		{"https://s.mxmcdn.net/images-storage/albums2/1/41606678_500_500.jpg", "https://s.mxmcdn.net/images-storage/albums2/1/41606678_500_500.jpg"},
	}
	for _, c := range cases {
		if got := coverThumbURL(c.in); got != c.want {
			t.Errorf("coverThumbURL(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
