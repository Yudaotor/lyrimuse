package main

import "testing"

// 宽松版署名行判据(翻译选行 + 曲长端点共用):标签与冒号之间可以有空白,版权方标签是拉丁字母——两种排版都得认出来,
// 否则它们会以"整行拉丁字母比汉字多"的形态被 dominantScript 判成外语行送去机翻:
// 拿职员表去翻,语种识别只能得到随机结果,端上语言包多半没装、于是退到网络翻译把
// 歌词发出去,而翻出来的东西展示端又会当署名行过滤掉。
//
// 样本里的角色名/人名/公司名全是虚构占位,只用来复现排版结构本身。
func TestIsRelaxedCreditLineLabelSpacing(t *testing.T) {
	cases := []struct {
		name string
		text string
		want bool
	}{
		{"汉字标签紧跟半角冒号", "混音师: 甲", true},
		{"汉字标签紧跟全角冒号", "混音师：甲", true},
		{"汉字标签与冒号之间有半角空格", "人声 : 甲", true},
		{"汉字标签与冒号之间有全角空格", "母带　: 乙", true},
		{"单字标签加空格", "鼓 : 丙", true},
		{"版权标签 OP", "OP : 某某音乐版权有限公司", true},
		{"版权标签 SP 全角冒号", "SP：某某音乐版权有限公司", true},
		{"版权标签小写", "op : 某某音乐版权有限公司", true},
		{"真歌词里的英文感叹词不算版权标签", "Oh : you know", false},
		{"真歌词里的单字母不算版权标签", "I : am here", false},
		{"普通歌词行", "今天天气真好", false},
	}
	for _, c := range cases {
		if got := isRelaxedCreditLine(c.text, nil); got != c.want {
			t.Errorf("%s: isRelaxedCreditLine(%q) = %v, want %v", c.name, c.text, got, c.want)
		}
	}
}

// 对唱歌的说话人标签跟署名行长得一模一样("短汉字 + 冒号"),两者只能靠"这一份歌词里
// 这个标签是不是反复出现"分开。标签后面带空格时同样要豁免,否则对唱歌的外语行会被
// 当成职员表整行丢掉、永远拿不到译文。
func TestIsRelaxedCreditLineExemptsSpacedDuetLabels(t *testing.T) {
	lrc := "[00:01.00]男 : 第一句\n" +
		"[00:02.00]女 : 第二句\n" +
		"[00:03.00]男 : 第三句\n" +
		"[00:04.00]女 : 第四句\n" +
		"[00:05.00]合 : 第五句\n" +
		"[00:06.00]混音师 : 甲"
	speakers := lyricSpeakerLabels(lrc)
	for _, label := range []string{"男 : 第一句", "女 : 第二句", "合 : 第五句"} {
		if isRelaxedCreditLine(label, speakers) {
			t.Errorf("说话人标签被当成署名行剔掉了: %q", label)
		}
	}
	if !isRelaxedCreditLine("混音师 : 甲", speakers) {
		t.Error("带空格的署名行没有被识别出来")
	}
}
