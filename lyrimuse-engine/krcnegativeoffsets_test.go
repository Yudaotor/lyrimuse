package main

import (
	"strings"
	"testing"
)

// 源头:负的词始偏移照样换算成绝对时间(不到 0 按 0),整行里也不留标记。
func TestKRCNegativeWordOffsets(t *testing.T) {
	const krc = "[60864,3000]<-11,116,0>就话<116,873,0>886\n[0,500]<-30,30,0>早<0,500,0>到\n[1000,500]<0,500,0>第三句"
	yrc := krcToYRC(krc)
	if !strings.Contains(yrc, "[60864,3000](60853,116,0)就话(60980,873,0)886") || !strings.Contains(yrc, "[0,500](0,30,0)早(0,500,0)到") || strings.Contains(yrc, "<") {
		t.Errorf("逐字换算不对: %q", yrc)
	}
	if lrc := krcToLRC(krc); !strings.Contains(lrc, "[01:00.86]就话886") || strings.Contains(lrc, "<") {
		t.Errorf("整行里不该留标记: %q", lrc)
	}
}

// 存量:旧实现留下的负偏移标记按所在行的行始原地换算;幂等;干净的、不是计时行的不动。
func TestRepairKRCNegativeOffsets(t *testing.T) {
	// 薛凯琪《886 (Live)》在 lyrics/ 里的真实形态(截取一行)。
	const broken = "[60864,3000]<-11,116,0>就话(60980,873,0)886(61853,0,0) \n[21713,1023]<-1719,0,0>踏<-1286,0,0>上(21713,0,0)"
	const want = "[60864,3000](60853,116,0)就话(60980,873,0)886(61853,0,0) \n[21713,1023](19994,0,0)踏(20427,0,0)上(21713,0,0)"
	got, changed := repairKRCNegativeOffsets(broken)
	if !changed || got != want {
		t.Fatalf("修复结果不对\n实际: %s\n期望: %s", got, want)
	}
	if again, changed2 := repairKRCNegativeOffsets(got); changed2 || again != got {
		t.Errorf("不幂等:第二轮 changed=%v", changed2)
	}
	if got, _ := repairKRCNegativeOffsets("[10,500]<-30,30,0>早"); got != "[10,500](0,30,0)早" {
		t.Errorf("不到 0 按 0: %q", got)
	}
	if got, _ := repairKRCNegativeOffsets("[100,500]<-30,30,0>早<5,6,7>"); got != "[100,500](70,30,0)早<5,6,7>" {
		t.Errorf("只换算负偏移的标记: %q", got)
	}
	for _, clean := range []string{"[0,500](0,250,0)hello (250,250,0)world", "[ti:<-1,2,3>]\n[0,500](0,500,0)a"} {
		if got, changed := repairKRCNegativeOffsets(clean); changed || got != clean {
			t.Errorf("不该动: %q → %q", clean, got)
		}
	}
}
