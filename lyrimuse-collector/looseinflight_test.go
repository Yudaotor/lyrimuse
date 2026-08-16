package main

import "testing"

// 2026-08-16 实测回归:刚把 14 组重复合并干净,当晚 19:57/19:58 又新长出一对
// `方大同|春風吹之吹吹風mix|愛愛愛` / `方大同|春风吹之吹吹风mix|愛愛愛`。
// canonicalEnrichKey 查的是 enrichCache,而那一刻第一条只在 enrichInflight 里、
// 还没写进缓存,于是宽松匹配查不到,两条各自起了一路解析。
func TestLooseInflightKeyCatchesEquivalentInFlight(t *testing.T) {
	old := enrichInflight
	enrichInflight = map[string]bool{}
	t.Cleanup(func() { enrichInflight = old })

	// 繁体那条正在解析中(还没写进 enrichCache)
	enrichInflight["方大同|春風吹之吹吹風mix|愛愛愛"] = true

	// 简体那条这时来问"我能不能起一路解析" —— 必须答"不能"
	if got, busy := looseInflightKey("方大同|春风吹之吹吹风mix|愛愛愛"); !busy {
		t.Errorf("简体写法没被在途的繁体条目挡住,会长出重复(got=%q)", got)
	}
	// 空格变体同理
	if _, busy := looseInflightKey("方大同|春風吹之吹吹風 mix|愛愛愛"); !busy {
		t.Error("空格变体没被挡住")
	}
	// 精确同一个 key 当然也算在途
	if _, busy := looseInflightKey("方大同|春風吹之吹吹風mix|愛愛愛"); !busy {
		t.Error("精确同名没被认成在途")
	}
	// 真的另一首歌不能被误判成在途,否则它永远起不了解析
	if _, busy := looseInflightKey("方大同|三人游|愛愛愛"); busy {
		t.Error("另一首歌被误判成在途,它的歌词将永远解析不出来")
	}
	// 版本不同的也必须放行
	if _, busy := looseInflightKey("方大同|春風吹之吹吹風mix (Live)|愛愛愛"); busy {
		t.Error("Live 版被误判成在途")
	}
}

func TestLooseInflightKeyEmptyQueue(t *testing.T) {
	old := enrichInflight
	enrichInflight = map[string]bool{}
	t.Cleanup(func() { enrichInflight = old })

	if _, busy := looseInflightKey("陶喆|Susan 说|太平盛世"); busy {
		t.Error("空队列不该报在途")
	}
}
