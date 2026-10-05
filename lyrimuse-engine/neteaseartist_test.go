package main

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
)

// 网易云认身份时,「中文名 英文名」连写的署名跟汉字那段是同一个人,两个方向都认;别的人、截短的名字、仿冒写法、
// 只剩一个英文词的、只有一个汉字的仍然对不上。通用的 artistMatches / lyricSourceArtistMatches 不认这种写法,
// 见 09 章决策 180。
func TestNeteaseArtistMatchesBilingualLabel(t *testing.T) {
	cases := []struct {
		name, artist string
		want         bool
	}{
		{"田馥甄", "田馥甄 Hebe Tien", true},
		{"田馥甄 Hebe Tien", "田馥甄", true},
		{"卢瀚霆", "Anson Lo 盧瀚霆", true},
		{"胡鸿钧", "Hubert Wu 胡鴻鈞", true},
		{"八三夭", "八三夭 831", true},
		{"田馥甄", "田馥甄", true},
		{"田馥甄-", "田馥甄 Hebe Tien", false},
		{"田馥", "田馥甄 Hebe Tien", false},
		{"林宥嘉", "田馥甄 Hebe Tien", false},
		{"Ian", "Ian 陳卓賢", false},
		{"Hebe Tien", "田馥甄 Hebe Tien", false},
		{"鹤", "鹤 The Crane", false},
	}
	for _, c := range cases {
		if got := neteaseArtistMatches(c.name, c.artist); got != c.want {
			t.Errorf("neteaseArtistMatches(%q, %q) = %v, 要 %v", c.name, c.artist, got, c.want)
		}
	}
	if artistMatches("田馥甄", "田馥甄 Hebe Tien") || lyricSourceArtistMatches("田馥甄", "田馥甄 Hebe Tien") {
		t.Error("通用的歌手比对和歌词闸不该认「中文名 英文名」:别的源首轮按双语署名搜出来的常是单曲版、精选集")
	}
}

// 本地署名是「中文名 英文名」、网易云署中文名时,挑歌(封面、链接、专辑 id 跟着这一条走)选得出正主,仿冒写法不选。
func TestNeteasePickSongBilingualLabel(t *testing.T) {
	var songs []neSearchSong
	raw := `[{"id":11,"name":"坍塌","artists":[{"name":"田馥甄-"}],"album":{"name":"要去什么地方","id":2,"picId":3},"duration":213828},
		{"id":12,"name":"坍塌","artists":[{"name":"田馥甄"}],"album":{"name":"要去什么地方","id":2,"picId":3},"duration":213828}]`
	if err := json.Unmarshal([]byte(raw), &songs); err != nil {
		t.Fatal(err)
	}
	got := neteasePickSong(songs, "田馥甄 Hebe Tien", "坍塌", "要去什么地方", 213.828)
	if got == nil || got.ID != 12 {
		t.Fatalf("neteasePickSong 选了 %+v,要 id=12", got)
	}
}

// 「满屏仿冒号」名单按汉字那段查:本地写成「周杰倫 Jay Chou」也要扣掉网易云的身份。
func TestNeteaseImpersonatorRiddenBilingualLabel(t *testing.T) {
	for artist, want := range map[string]bool{
		"周杰伦":           true,
		"周杰倫 Jay Chou":  true,
		"Jay Chou 周杰伦":  true,
		"田馥甄 Hebe Tien": false,
		"Jay Chou":      false,
	} {
		if got := isNeteaseImpersonatorRidden(artist); got != want {
			t.Errorf("isNeteaseImpersonatorRidden(%q) = %v, 要 %v", artist, got, want)
		}
	}
}

// netease.go 里认身份的地方一律走 neteaseArtistMatches;直接调 artistMatches 的只有它自己。
func TestNeteaseIdentityUsesNeteaseArtistMatches(t *testing.T) {
	data, err := os.ReadFile("netease.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	start := strings.Index(src, "func neteaseArtistMatches(")
	if start < 0 {
		t.Fatal("netease.go 里找不到 neteaseArtistMatches")
	}
	end := strings.Index(src[start:], "\n}\n")
	if end < 0 {
		t.Fatal("neteaseArtistMatches 的函数体没找到结尾")
	}
	rest := src[:start] + src[start+end:]
	if loc := regexp.MustCompile(`(^|[^A-Za-z])artistMatches\(`).FindStringIndex(rest); loc != nil {
		line := strings.Count(rest[:loc[0]], "\n") + 1
		t.Errorf("netease.go 有一处直接调 artistMatches(大约第 %d 行):认身份的地方要用 neteaseArtistMatches", line)
	}
	if n := strings.Count(src, "neteaseArtistMatches(a.Name, artist)"); n < 4 {
		t.Errorf("neteaseArtistMatches(a.Name, artist) 只剩 %d 处,挑歌 / 只给歌词的兜底 / 规范署名 / 按歌手搜反查曲名四处都要用", n)
	}
}
