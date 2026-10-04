package main

import "testing"

// 签名向量跟 lyrimuse-selftest LastfmTests 里 LastfmSignature 那一段是同一组:App 侧授权 / 喜欢
// 和这里的镜像写入各算各的 api_sig,两边任一处的排序或编码跟另一处分叉,对应的这一组就会红。
// 期望值是按「键名字节序拼 key+value、末尾接 secret、取 MD5」独立算出来的。
func TestLastfmSignMatchesSharedVectors(t *testing.T) {
	s := &lastfmScrobbler{secret: "SECRET"}
	cases := []struct {
		name   string
		params map[string]string
		want   string
	}{
		{"auth.getsession", map[string]string{"method": "auth.getsession", "api_key": "KEY", "token": "TOK"},
			"7159147741f8ad64a31b34b8a529be00"},
		{"中文值按 UTF-8 字节拼", map[string]string{"method": "track.love", "artist": "周杰倫", "track": "晴天", "api_key": "KEY", "sk": "SK"},
			"937db1b27d3985a7c3b885731c6f2964"},
		{"批量下标按字节序:artist[10] 排在 artist[2] 前", map[string]string{"artist[0]": "A", "artist[10]": "B", "artist[2]": "C", "method": "track.scrobble", "api_key": "KEY", "sk": "SK"},
			"5659761ac217b49797f2e0103d7866aa"},
	}
	for _, c := range cases {
		if got := s.sign(c.params); got != c.want {
			t.Errorf("%s: sign = %s, want %s", c.name, got, c.want)
		}
	}
}
