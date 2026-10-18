package main

import "testing"

// 按 hash 查回的候选:挑第一条歌名跟挑中那首对得上的;用户上传的「歌手 - 歌名」写法、别的歌都跳过;候选没报歌名照收。
func TestKugouHashCandidate(t *testing.T) {
	upload := kugouLyricCandidate{ID: "1", AccessKey: "k", Song: "周杰伦 - 晴天", Singer: "hjt"}
	other := kugouLyricCandidate{ID: "2", AccessKey: "k", Song: "十年", Singer: "陈奕迅"}
	right := kugouLyricCandidate{ID: "3", AccessKey: "k", Song: "晴天", Singer: "周杰伦"}
	noKey := kugouLyricCandidate{ID: "4", Song: "晴天"}
	if c, ok := kugouHashCandidate([]kugouLyricCandidate{noKey, other, right}, "晴天"); !ok || c.ID != "3" {
		t.Errorf("跳过缺 accesskey 的和别的歌,挑对得上的: %+v %v", c, ok)
	}
	if _, ok := kugouHashCandidate([]kugouLyricCandidate{other}, "晴天"); ok {
		t.Error("一条都对不上:交给不带 hash 的那次")
	}
	if c, ok := kugouHashCandidate([]kugouLyricCandidate{{ID: "5", AccessKey: "k"}}, "晴天"); !ok || c.ID != "5" {
		t.Errorf("候选没报歌名照收: %+v %v", c, ok)
	}
	if c, ok := kugouHashCandidate([]kugouLyricCandidate{upload, right}, "晴天"); !ok || c.ID != "3" {
		t.Errorf("上传版排在前面也跳过,挑真那条: %+v %v", c, ok)
	}
}
