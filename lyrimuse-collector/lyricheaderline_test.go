package main

import "testing"

// 抬头行判据。形状与取舍照搬 Swift 侧 LyricsSyncEngine.looksLikeHeaderLine,这里钉的是
// 两边必须一致的那几条:曲名侧等值、歌手侧 contains 且不去括号、两种摆法、切分规则。
func TestLooksLikeLyricHeaderLine(t *testing.T) {
	cases := []struct {
		name   string
		text   string
		title  string
		artist string
		want   bool
	}{
		{"曲名 - 歌手", "无悔这一生 - BEYOND", "无悔这一生", "BEYOND", true},
		{"歌手 - 曲名", "BEYOND - 交织千个心", "交织千个心", "BEYOND", true},
		{"本地标签带括号后缀,抬头是裸曲名", "谁是勇敢 - BEYOND", "谁是勇敢(1989年新版)", "BEYOND", true},
		{"歌手名写在括号里,歌手侧不去括号", "某首歌 - 某歌手 (Some Artist)", "某首歌", "Some Artist", true},
		{"裸连字符", "某歌手-某首歌", "某首歌", "某歌手", true},
		{"曲名自带连字符,靠带空格的那个切", "W-H-Y - 某歌手", "W-H-Y", "某歌手", true},
		{"大小写/空格不影响", "sometitle - some artist", "SomeTitle", "SomeArtist", true},

		// 最要紧的一条:真歌词里曲名和歌手都出现,但不是「两段等值」的形状。
		// 曲名侧写成 contains 的话这句会被整行吞掉(Swift 侧 selftest 抓到过的真实反例)。
		{"真歌词里同时含曲名和歌手", "新的经典 蛋堡 x Jabberloop", "经典", "蛋堡", false},

		{"没有分隔符", "只是一句普通歌词", "某首歌", "某歌手", false},
		{"两个带空格连字符,切不出两段", "a - b - c", "a", "b", false},
		{"曲名对不上", "另一首歌 - BEYOND", "无悔这一生", "BEYOND", false},
		{"歌手对不上", "无悔这一生 - 别的歌手", "无悔这一生", "BEYOND", false},
		{"缺元数据一律不认", "无悔这一生 - BEYOND", "", "BEYOND", false},
	}
	for _, c := range cases {
		if got := looksLikeLyricHeaderLine(c.text, c.title, c.artist); got != c.want {
			t.Errorf("%s: looksLikeLyricHeaderLine(%q, %q, %q) = %v, want %v",
				c.name, c.text, c.title, c.artist, got, c.want)
		}
	}
}

// 抬头只在第一条正文行认:同一句话出现在后面就是真歌词,不能跟着一起丢。
func TestHeaderLineOnlySkippedOnFirstBodyLine(t *testing.T) {
	lrc := "[00:00.00]无悔这一生 - BEYOND\n" +
		"[00:05.00]Hello world\n" +
		"[00:10.00]无悔这一生 - BEYOND\n"
	lines := parseLRCLines(lrc)
	if len(lines) != 3 {
		t.Fatalf("解析出 %d 行,期望 3 行", len(lines))
	}
	first := true
	var sent []string
	for _, l := range lines {
		text := l.text
		if text != "" && first {
			first = false
			if looksLikeLyricHeaderLine(text, "无悔这一生", "BEYOND") {
				continue
			}
		}
		sent = append(sent, text)
	}
	if len(sent) != 2 || sent[0] != "Hello world" || sent[1] != "无悔这一生 - BEYOND" {
		t.Errorf("第一行该被跳过、第三行该保留,实际 %q", sent)
	}
}
