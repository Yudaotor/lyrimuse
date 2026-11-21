package main

import "testing"

// 存量里 qrcToYRC 旧实现漏转的词条要能原地修回来。
func TestRepairQRCLeftoverTokens(t *testing.T) {
	// Adele《River Lea》署名行在缓存里的真实形态。
	const broken = "[0,6030](0,926,0)River (926,926,0)Lea (1852,926,0)- (2778,463,0)Adele(3241,463,0) ((3704,463)(4167,463,0)阿(4630,463,0)黛(5093,463,0)尔)(5556,463)"
	const want = "[0,6030](0,926,0)River (926,926,0)Lea (1852,926,0)- (2778,463,0)Adele(3241,463,0) (3704,463,0)((4167,463,0)阿(4630,463,0)黛(5093,463,0)尔(5556,463,0))"
	got, changed := repairQRCLeftoverTokens(broken)
	if !changed {
		t.Fatal("该判为改过")
	}
	if got != want {
		t.Errorf("修复结果不对\n实际: %s\n期望: %s", got, want)
	}
	// 幂等:修好的再跑一遍不该再动 —— 水位闸的前提之一。
	if again, changed2 := repairQRCLeftoverTokens(got); changed2 || again != got {
		t.Errorf("不幂等:第二轮 changed=%v", changed2)
	}
}

// `[kana:…]` 假名标注行里的 `(起始,时长)` **本来就是两数字**,那是它的正常写法。
// 误修会把假名标注打烂;本机缓存里有 52 条酷狗条目带这种行,别把它们统计成「残缺」。
// 这条用例就是那道防线。
func TestRepairQRCLeftoverTokensLeavesKanaLine(t *testing.T) {
	const kana = "[kana:1せん1き(1119,196)ゃ(1315,196)く(1512,415)1ばん1ら(2311,432)い(2743,204)]"
	if got, changed := repairQRCLeftoverTokens(kana); changed || got != kana {
		t.Errorf("kana 行不能动\n实际: %s", got)
	}
	// 跟计时行混在一份 YRC 里时,只修计时行那部分。
	const mixed = kana + "\n[0,500](0,500,0)a((100,200)b"
	const want = kana + "\n[0,500](0,500,0)a(100,200,0)(b"
	got, changed := repairQRCLeftoverTokens(mixed)
	if !changed || got != want {
		t.Errorf("混合内容修错了\n实际: %s\n期望: %s", got, want)
	}
}

// 没有残缺词条的正常 YRC 一个字节都不该动。
func TestRepairQRCLeftoverTokensLeavesCleanYRC(t *testing.T) {
	const clean = "[0,500](0,250,0)hello (250,250,0)world"
	if got, changed := repairQRCLeftoverTokens(clean); changed || got != clean {
		t.Errorf("干净的 YRC 被动了\n实际: %s", got)
	}
	// 词文本以括号结尾、后面跟正常三数字词条 —— 不能被误判成残缺。
	const withParen = "[0,500](0,250,0)abc)(250,250,0)def"
	if got, changed := repairQRCLeftoverTokens(withParen); changed || got != withParen {
		t.Errorf("三数字词条前的括号被误修\n实际: %s", got)
	}
}

// 连着两个空文本的两数字标记:第一个标记的右括号是它自己的收口,不是括号词,不能挪走。
func TestRepairQRCLeftoverTokensKeepsMarkerClose(t *testing.T) {
	const empties = "[0,500](0,100,0)a(100,100)(200,100)(300,100,0)b"
	if got, changed := repairQRCLeftoverTokens(empties); changed || got != empties {
		t.Errorf("标记的右括号被当成括号词挪走\n实际: %s", got)
	}
	// 三数字标记后面紧跟括号词:右括号还是标记的,后一个才是词。
	const afterThree = "[0,500](0,100,0))(100,100)"
	if got, _ := repairQRCLeftoverTokens(afterThree); got != "[0,500](0,100,0)(100,100,0))" {
		t.Errorf("三数字标记后的括号词修错了\n实际: %s", got)
	}
}

// 没收口的两数字标记(旧修复留下的残片)算修不动;正常逐字、假名标注行不算。
func TestYRCHasTwoNumberTokensUnclosed(t *testing.T) {
	for _, s := range []string{
		"[210447,10171](215322,3874,0)心 (219196,204(219400,223,0(219623,995,0)))",
		"[0,420](52,26,0)幕(78,26,0)由(104,26(130,26,0))(156,26,0)A",
		"[0,500](0,100,0)a(100,100)",
	} {
		if !yrcHasTwoNumberTokens(s) {
			t.Errorf("该判为有残片: %s", s)
		}
	}
	for _, s := range []string{"[0,500](0,250,0)hello (250,250,0)world", "[0,500](0,100,0)((100,100,0)Live(200,100,0))", "[kana:1せ(1119,196)ん]"} {
		if yrcHasTwoNumberTokens(s) {
			t.Errorf("不该判为有残片: %s", s)
		}
	}
}
