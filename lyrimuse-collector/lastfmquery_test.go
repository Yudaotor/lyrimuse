package main

import (
	neturl "net/url"
	"testing"
)

// 期望串跟 Swift 侧 lyrimuse-selftest 里 LastfmQuery 那一组断言**逐字节相同** ——
// 两侧打的是同一个端点,规则分家就会出现"App 查得到、collector 却判成影子条目"这种
// 自相矛盾的行为。改动任一侧都要同步改另一侧和这两组断言。
func TestLastfmEscape(t *testing.T) {
	cases := []struct{ in, want string }{
		// 实测:只有 %252B 这一串能命中《夜曲+窃爱 (Live)》(userplaycount=2),
		// 标准编码的 %2B 返回 error 6 Track not found。
		{"夜曲+窃爱 (Live)", "%E5%A4%9C%E6%9B%B2%252B%E7%AA%83%E7%88%B1%20%28Live%29"},
		{"+44", "%252B44"},   // 真实乐队,端点级行为的独立验证样本
		{"100%", "100%2525"}, // 百分号同理多编一层
		{"a+b%c", "a%252Bb%2525c"},
		// 不含 +/% 的 value 必须跟标准编码逐字节相同 —— "对既有请求零影响"的依据
		{"开不了口 (live)", "%E5%BC%80%E4%B8%8D%E4%BA%86%E5%8F%A3%20%28live%29"},
		{"Beyond", "Beyond"},
		{"a b", "a%20b"}, // 空格用 %20,不用 QueryEscape 默认的 +
	}
	for _, c := range cases {
		if got := lastfmEscape(c.in); got != c.want {
			t.Errorf("lastfmEscape(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLastfmGetQuerySortsAndEscapes(t *testing.T) {
	q := neturl.Values{}
	q.Set("track", "夜曲+窃爱 (Live)")
	q.Set("method", "track.getInfo")
	q.Set("artist", "周杰伦")
	// 按 key 排序:artist < method < track
	want := "artist=%E5%91%A8%E6%9D%B0%E4%BC%A6" +
		"&method=track.getInfo" +
		"&track=%E5%A4%9C%E6%9B%B2%252B%E7%AA%83%E7%88%B1%20%28Live%29"
	if got := lastfmGetQuery(q); got != want {
		t.Errorf("lastfmGetQuery = %q, want %q", got, want)
	}
}
