package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// 描边剪影必须跟被描边的内容吃同一道 padding —— 源码守卫。
//
// 2026-08-23 的真 bug:`OptionalTextStroke` 把 content 先 `.padding(width*2)` 再用
// Canvas 画剪影,而 Canvas 是**居中**绘制剪影的,只有"剪影与 content 在 canvas 里占同一块
// 矩形"时才逐点对齐。原来 symbols 里的剪影没有那道 padding:
//
//   - 普通 Text 按自然宽度收缩,剪影比 canvas 窄一圈 padding,居中绘制正好补回来 → 对齐;
//   - 逐字行是 WrapLayout,它**撑满被提议的宽度** —— content 撑满的是 padding 内的宽度、
//     剪影撑满的是 canvas 整宽,两者差正好一圈 padding。
//
// 居中排版(非对唱歌)时两边各差一半、抵消掉,完全看不出来;一旦按 leading/trailing 靠边
// (对唱歌的左右声部),文字各自贴在自己矩形的边上,偏移 width*2 = 2.4pt —— 而描边本身才
// 1.2pt,整圈描边甩到一侧。实测探针:修前 canvas=323 symbol=323(内部差 2.4)、普通行差 5.0;
// 修后全部同框(差 0.2,取整误差)。
//
// 这个 bug 用 selftest 覆盖不了(纯 SwiftUI 布局行为,没有可抽出的几何函数),只能钉源码:
// 两处 padding 必须成对出现,删掉任何一处都会让对唱歌的描边重新偏。
func TestStrokeMaskSharesContentPadding(t *testing.T) {
	const p = "../lyrimuse/Sources/lyrimuse/UI/LyricsOverlayView.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}
	body := string(raw)

	i := strings.Index(body, "private struct OptionalTextStroke")
	if i < 0 {
		t.Fatal("找不到 OptionalTextStroke(被改名了?同步更新这个测试)")
	}
	seg := body[i:]
	if j := strings.Index(seg, "\n}\n"); j > 0 {
		seg = seg[:j]
	}

	// content 那一道
	if !regexp.MustCompile(`content\s*\n\s*(//[^\n]*\n\s*)*\.padding\(width \* 2\)`).MatchString(seg) &&
		!strings.Contains(seg, ".padding(width * 2)") {
		t.Fatal("OptionalTextStroke 里找不到 content 的 .padding(width * 2)")
	}
	// symbols 那一道 —— 必须存在,且跟 content 用同一个表达式
	k := strings.Index(seg, "} symbols: {")
	if k < 0 {
		t.Fatal("找不到 Canvas 的 symbols 块")
	}
	sym := seg[k:]
	if !strings.Contains(sym, ".padding(width * 2)") {
		t.Error("描边剪影(symbols 块)缺少 .padding(width * 2) —— " +
			"剪影与 content 不同框,对唱歌(leading/trailing 排版)的描边会整圈偏 2.4pt。" +
			"见本测试顶部注释。")
	}
	// 两道 padding 必须用同一个量;写死数字就说明有人改过一边
	if n := strings.Count(seg, ".padding(width * 2)"); n != 2 {
		t.Errorf("期望 content 和 symbols 各一道 .padding(width * 2),实际出现 %d 次 —— "+
			"两道必须成对且同量,否则剪影与内容错位", n)
	}
}
