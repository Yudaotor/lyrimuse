package main

import "testing"

// 2026-09-01 真实bug:陈奕迅《爱是怀疑 (Live)》和 Michael Jackson《Can't Let Her Get
// Away》这两首网易云缓存的歌词里,英文撇号前带着字面反斜杠(`It\'s`、`Can\'t`)直接显示
// 在悬浮歌词/歌词窗口里。核实过是网易云 lyric/tlyric/romalrc/yrc 接口自己数据库里的脏
// 数据(json.Unmarshal 已经正常解码,不是我们转义链路的 bug——本地缓存全量按来源分组
// 核实过,1669 条网易云缓存只有这 2 条命中,QQ/酷狗/musixmatch/lrclib/amll 零命中),
// 所以固定清一种组合(反斜杠+撇号)就够,见 stripNeteaseEscapedApostrophes 头注。
func TestStripNeteaseEscapedApostrophes(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"无反斜杠原样返回", "普通歌词，没有转义", "普通歌词，没有转义"},
		{"清掉撇号前的反斜杠", `Can\'t see what\'s the point`, "Can't see what's the point"},
		{"多行都清", "[00:04.04]CAN\\'T LET HER GET AWAY\n[01:11.09]I\\'ll play the fool", "[00:04.04]CAN'T LET HER GET AWAY\n[01:11.09]I'll play the fool"},
		{"空串", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := stripNeteaseEscapedApostrophes(c.in); got != c.want {
				t.Errorf("stripNeteaseEscapedApostrophes(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
