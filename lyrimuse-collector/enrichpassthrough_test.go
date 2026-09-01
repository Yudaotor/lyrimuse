package main

import (
	"encoding/json"
	"testing"
)

// enrichCache 的往返是**有损**的:loadEnrichCache 把整个文件解进 map[string]enrichEntry
// (强类型 struct),saveEnrichCache 再把它整个 marshal 回去 —— Go 的 encoding/json 在
// unmarshal 时**直接丢弃未声明字段**。也就是说:App 侧写进缓存的任何字段,只要 enrichEntry
// 里没有对应的成员,就会在 collector 下一次存盘时被**静默抹掉**。而 collector 存盘极其
// 频繁(每解析一首歌都可能触发),抹除窗口基本是"几分钟内"。
//
// 这道闸 2026-09-01 加,起因是「手动选定歌词后锁定」开关需要一个 App 侧的留痕字段
// (manual_pick_sha,记"这份内容是用户手动采纳的",collector 完全不读它)。第一版忘了在
// enrichEntry 里声明,本测试当场逮住:注入的值在一次往返后变成空串。表现会是"开关打开时
// 什么都没锁上",而且查不出原因 —— 缓存文件里那个字段就是不见了,像从没写过。
//
// 所以:**App 侧新增任何写进 enrich 缓存的字段,都必须在 enrichEntry 里声明一个成员**,
// 哪怕 collector 一行代码都不读它。往下加字段时把它也加进这个测试的清单。
func TestEnrichEntryPreservesAppOwnedFields(t *testing.T) {
	// key 是字段名,value 是注入的探针值。都是 collector 自己从不写、只由 App 侧写的字段。
	probes := map[string]string{
		"manual_pick_sha":      "deadbeef1234",
		"lyrics_source_choice": "netease",
	}
	entry := map[string]any{"lyrics": "[00:01.00]x\n"}
	for k, v := range probes {
		entry[k] = v
	}
	raw, err := json.Marshal(map[string]any{"a|b|c": entry})
	if err != nil {
		t.Fatalf("marshal fixture: %v", err)
	}

	// 走 collector 真实的往返:解进强类型 map,再原样 marshal 回去。
	var m map[string]enrichEntry
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	var back map[string]map[string]any
	if err := json.Unmarshal(out, &back); err != nil {
		t.Fatalf("unmarshal round-tripped: %v", err)
	}

	for field, want := range probes {
		got, ok := back["a|b|c"][field]
		if !ok {
			t.Errorf("字段 %q 在一次 collector 往返后消失了 —— enrichEntry 里没有声明它，"+
				"App 侧写进去的值会被下一次存盘静默抹掉", field)
			continue
		}
		if got != want {
			t.Errorf("字段 %q 往返后变了: got %v, want %v", field, got, want)
		}
	}
}
