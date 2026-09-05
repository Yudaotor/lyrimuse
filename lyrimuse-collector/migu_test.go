package main

import (
	"encoding/json"
	"testing"
)

func miguItemFromJSON(t *testing.T, raw string) miguSearchItem {
	t.Helper()
	var it miguSearchItem
	if err := json.Unmarshal([]byte(raw), &it); err != nil {
		t.Fatalf("解析测试用的搜索结果失败: %v", err)
	}
	return it
}

// 咪咕 LRC 顶部四行元数据(2026-09-04 实测形状):前两行没有冒号,只有这里能剥;作词/作曲
// 两行跟别的源一样留给下游署名处理。CRLF 归一化、空正文行剥掉、正文不受影响。
func TestMiguStripMetaLines(t *testing.T) {
	in := "[00:01.00]歌曲名 稻香\r\n[00:02.00]歌手名 周杰伦\r\n[00:03.00]作词：周杰伦\r\n[00:04.00]作曲：周杰伦\r\n" +
		"[00:31.17]对这个世界如果你有太多的抱怨\r\n[00:34.46]   \r\n[00:37.46]为什么人要这么的脆弱堕落\r\n"
	want := "[00:03.00]作词：周杰伦\n[00:04.00]作曲：周杰伦\n[00:31.17]对这个世界如果你有太多的抱怨\n[00:37.46]为什么人要这么的脆弱堕落\n"
	if got := miguStripMetaLines(in); got != want {
		t.Fatalf("剥头结果不对:\n got=%q\nwant=%q", got, want)
	}
	if !isTimedLRC(miguStripMetaLines(in)) {
		t.Fatal("剥完头之后应该仍然是同步 LRC")
	}
	// 带冒号的写法也要剥;「歌曲名」出现在正文行首以外的位置不受影响。
	in2 := "[00:00.00]歌曲名：少年\n[00:00.00]歌手名: 梦然\n[00:10.00]这首歌曲名字很长\n[00:12.00]我还是从前那个少年\n"
	want2 := "[00:10.00]这首歌曲名字很长\n[00:12.00]我还是从前那个少年\n"
	if got := miguStripMetaLines(in2); got != want2 {
		t.Fatalf("带冒号的元数据行没剥干净:\n got=%q\nwant=%q", got, want2)
	}
}

// 身份闸:原版通过;歌手对不上(用户上传的翻唱把歌手名写成别人)、Live 版本限定词对不上、
// 没有 lyricUrl 的条目都淘汰。用的是跟别的源完全一致的判定函数,这里只钉"接上了"。
func TestMiguCandidateScoreIdentityGate(t *testing.T) {
	original := miguItemFromJSON(t, `{"name":"稻香","lyricUrl":"https://d.musicapp.migu.cn/x","singers":[{"name":"周杰伦"}]}`)
	if got := miguCandidateScore(original, "周杰伦", "稻香", "魔杰座"); got < 0 {
		t.Fatalf("原版录音室版本应该通过身份闸,得到 %d", got)
	}
	cover := miguItemFromJSON(t, `{"name":"周杰伦 - 稻香","lyricUrl":"https://d.musicapp.migu.cn/y","singers":[{"name":"稳重的牧牛铃"}],"albums":[{"name":"单曲发行"}]}`)
	if got := miguCandidateScore(cover, "周杰伦", "稻香", "魔杰座"); got >= 0 {
		t.Fatalf("歌手是别人的翻唱应该被淘汰,得到 %d", got)
	}
	live := miguItemFromJSON(t, `{"name":"稻香 (Live)","lyricUrl":"https://d.musicapp.migu.cn/z","singers":[{"name":"周杰伦"}]}`)
	if got := miguCandidateScore(live, "周杰伦", "稻香", "魔杰座"); got >= 0 {
		t.Fatalf("本地是录音室版、候选是 Live 版,版本限定词对不上应该淘汰,得到 %d", got)
	}
	noLyric := miguItemFromJSON(t, `{"name":"稻香","lyricUrl":"","singers":[{"name":"周杰伦"}]}`)
	if got := miguCandidateScore(noLyric, "周杰伦", "稻香", "魔杰座"); got >= 0 {
		t.Fatalf("没有 lyricUrl 的条目应该淘汰,得到 %d", got)
	}
}

func TestMiguCoverURLPrefersLargest(t *testing.T) {
	it := miguItemFromJSON(t, `{"imgItems":[{"imgSizeType":"01","img":"https://d/1"},{"imgSizeType":"03","img":"https://d/3"},{"imgSizeType":"02","img":"https://d/2"}]}`)
	if got := miguCoverURL(it); got != "https://d/3" {
		t.Fatalf("应挑 03 那一档,得到 %q", got)
	}
	noBig := miguItemFromJSON(t, `{"imgItems":[{"imgSizeType":"01","img":"https://d/1"},{"imgSizeType":"02","img":""}]}`)
	if got := miguCoverURL(noBig); got != "https://d/1" {
		t.Fatalf("没有 03 时退到最后一条非空的,得到 %q", got)
	}
	if got := miguCoverURL(miguSearchItem{}); got != "" {
		t.Fatalf("没有封面字段应返回空串,得到 %q", got)
	}
}

func TestMiguArtistNameJoinsSingers(t *testing.T) {
	it := miguItemFromJSON(t, `{"singers":[{"name":"周杰伦"},{"name":" 杨瑞代 "},{"name":""}]}`)
	if got := it.artistName(); got != "周杰伦/杨瑞代" {
		t.Fatalf("多歌手应以 / 拼接并去空白,得到 %q", got)
	}
}
