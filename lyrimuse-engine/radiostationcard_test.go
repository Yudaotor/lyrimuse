package main

import "testing"

// 台卡判定:电台起播那几十秒系统把台名当一首歌推过来,不能拿去搜歌词。
// 实测形态见 radioStationCard 的注释(`|petal radio|`、`|NCT 127|`、`|YEONJUN|`)。
func TestRadioStationCard(t *testing.T) {
	cases := []struct {
		name   string
		radio  bool
		artist string
		title  string
		want   bool
	}{
		{"实测台卡 petal radio", true, "", "petal radio", true},
		{"实测台卡 NCT 127", true, "", "NCT 127", true},
		{"歌手只有空白也算空", true, "   ", "YEONJUN", true},
		{"真曲目两样俱全", true, "Ariana Grande", "kiss me", false},
		{"不是电台就不判 —— 本地文件缺标签不在这次范围内", false, "", "某个没有标签的本地文件", false},
		{"标题也空 = 加载中的空载荷,不是台卡", true, "", "", false},
		{"两样都空且不是电台", false, "", "", false},
	}
	for _, c := range cases {
		if got := radioStationCard(c.radio, c.artist, c.title); got != c.want {
			t.Errorf("%s: radioStationCard(%v, %q, %q) = %v, 期望 %v",
				c.name, c.radio, c.artist, c.title, got, c.want)
		}
	}
}
