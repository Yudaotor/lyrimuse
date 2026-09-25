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
// 误修会把假名标注打烂 —— 排查这个问题时我一度把这类行统计成"残缺",本机缓存里有 52 条
// 酷狗条目带这种行。这条用例就是那道防线。
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
