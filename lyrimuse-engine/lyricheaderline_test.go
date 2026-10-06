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
		{"两个带空格连字符:每处都切,但单字母歌手不够长", "a - b - c", "a", "b", false},
		{"曲名自带「 - 」,每个分隔处都切", "月を見ていた - Moongazing - 米津玄師 (よねづ けんし)", "月を見ていた - Moongazing", "米津玄師", true},
		{"全角连接号", "夜钟－南拳妈妈", "夜钟", "南拳妈妈", true},
		{"「——」分隔", "北京东路的日子（对唱版）——汪源/张家旺", "北京东路的日子", "汪源", true},
		{"书名号里是曲名", "南钧儿 - 毛不易《给你给我》", "给你给我", "毛不易", true},
		{"括号里才是本地曲名", "가위바위보 (Rock Paper Scissors) - B1A4 (비원에이포)", "Rock Paper Scissors", "B1A4", true},
		{"曲名后缀外文译名", "日出君 Sunrise again - 没有才能", "日出君", "没有才能", true},
		{"只共有一段不算等于曲名", "动力火车 - 再会吧！ 我的心上人", "再会吧!心上人", "动力火车", false},
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

// 歌名 / 歌手也认歌词自己的 [ti:] / [ar:]:播放器报罗马字、抬头写假名时照样认;只有歌名、形状对不上的照旧不认。
// 同 Swift 侧 selftest「抬头标签」那一组。
func TestLyricHeaderLineTagged(t *testing.T) {
	title, artist := lyricHeaderTags("[ti:Overdose]\n[ar:なとり]\n[00:00.00]Overdose - なとり\n")
	if title != "Overdose" || artist != "なとり" {
		t.Fatalf("lyricHeaderTags = %q, %q", title, artist)
	}
	if tt, ta := lyricHeaderTags("[ti:]\n[ar:  ]\n"); tt != "" || ta != "" {
		t.Errorf("空的标签不算: %q, %q", tt, ta)
	}
	cases := []struct {
		name, text, title, artist, tagTitle, tagArtist string
		want                                           bool
	}{
		{"播放器报罗马字、抬头写假名", "Overdose - なとり", "Overdose", "natori", "Overdose", "なとり", true},
		{"不带标签照旧不认", "Overdose - なとり", "Overdose", "natori", "", "", false},
		{"播放器的歌名 + 标签的歌手", "缘分一道桥 (《长城》电影片尾曲) - 王力宏、谭维维", "缘分一道桥", "Wang Leehom", "电影片尾曲", "王力宏、谭维维", true},
		{"只有歌名不算", "First Love", "First Love", "Utada", "First Love", "", false},
		{"真歌词里同时有歌名和歌手", "新的经典 蛋堡 x Jabberloop", "经典", "Soft Lipa", "经典", "蛋堡", false},
	}
	for _, c := range cases {
		if got := looksLikeLyricHeaderLineTagged(c.text, c.title, c.artist, c.tagTitle, c.tagArtist); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
	// 送翻选行读同一份标签:播放器报的歌名、歌手都是另一种语种时,按标签认出抬头、不送翻;去掉标签就认不出,照旧送。
	body := "[00:00.50]Black and White - Khalil Fong\n[00:02.00]I wanna see you\n"
	tagged := selectTranslationWork("[ti:Black and White]\n[ar:Khalil Fong]\n"+body, "zh-CN", "方大同", "黑白").uniqueTexts
	if len(tagged) != 1 || tagged[0] != "I wanna see you" {
		t.Errorf("抬头不该送翻,实际 %q", tagged)
	}
	untagged := selectTranslationWork(body, "zh-CN", "方大同", "黑白").uniqueTexts
	if len(untagged) != 2 || untagged[0] != "Black and White - Khalil Fong" {
		t.Errorf("对照: 不带标签时抬头照旧送翻,实际 %q", untagged)
	}
}
