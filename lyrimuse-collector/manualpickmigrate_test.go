package main

import (
	"encoding/json"
	"testing"
)

// 金标准值把 Go 侧和 Swift 侧(LyrimuseCore/ManualPickLock.fingerprint)钉在一起。
//
// ⚠️ Swift selftest 里有**同样输入、同样期望值**的一条断言。改动任何一边的算法都会让其中
// 一边红——这正是要的:两边漂开的后果是**静默**的,老用户打开开关一首都锁不上,而缓存里
// 的指纹看上去还完全正常,没有任何迹象指向"两种语言算出来不一样"。
//
// 值本身由独立的第三方实现(Python hashlib)算出,不是从任何一边的实现里抄的。
const (
	// A / B 是**同一份词的两种排版**:B 换了全部时间戳、改成 CRLF、加了元数据标签和行尾
	// 空白、把两句挂成多时间戳、插了空行。指纹必须相同。
	goldenPickA   = "[ti:测试]\n[00:01.00]第一句\n[00:05.00]第二句\n"
	goldenPickB   = "[ar:某人]\r\n[offset:120]\r\n[00:02.34]第一句  \r\n\r\n[00:09.99][01:20.00]第二句\t\r\n"
	goldenPickSHA = "13ec24ce7207"
	// C 换了词 —— 这才是"被自动换掉了",指纹必须不同。
	goldenPickC = "[00:01.00]第一句\n[00:05.00]完全不同的第二句\n"
)

func TestManualPickFingerprintMatchesSwift(t *testing.T) {
	if got := manualPickFingerprint(goldenPickA); got != goldenPickSHA {
		t.Errorf("A: got %q, want %q —— 跟 Swift 侧的口径漂开了", got, goldenPickSHA)
	}
	// 这一条是这次改版的**核心不变量**:2026-09-01 第一版对原始字节取指纹,collector 启动
	// 时的规范化(YRC 空白词条合并、行时间轴重挂)在采纳后几秒内就把它打失配,开关一首都
	// 锁不上且完全静默。规范化不是替换 —— 词没动就该算"还是他选的那份"。
	if got := manualPickFingerprint(goldenPickB); got != goldenPickSHA {
		t.Errorf("B(同一份词、排版全变): got %q, want %q —— 规范化不该改变指纹,"+
			"否则 collector 启动时的重排会让开关静默失效", got, goldenPickSHA)
	}
	if manualPickFingerprint(goldenPickC) == goldenPickSHA {
		t.Error("C 换了词却算出同一个指纹 —— 真正的『被换掉』判不出来了")
	}
	if got := manualPickFingerprint("[ti:只有元数据]\n\n"); got != "" {
		t.Errorf("归一化后没有词该给空串(= 没有留痕), got %q", got)
	}
	if got := manualPickFingerprint(""); got != "" {
		t.Errorf("空正文该给空串, got %q", got)
	}
}

func TestMigrateManualPickMarks(t *testing.T) {
	lyrics := "[00:01.00]x\n"
	want := manualPickFingerprint(lyrics)

	cases := []struct {
		name    string
		entry   enrichEntry
		wantSHA string
	}{{
		name:    "正常转换:当前内容仍来自他选的源",
		entry:   enrichEntry{Lyrics: lyrics, LyricsSource: "netease", LyricsSourceChoice: "netease"},
		wantSHA: want,
	}, {
		// 当前这份已经不是他选的那个源给的了,按新语义不算"他选的那份"。
		name:    "来源已经换掉:只清字段,不写标记",
		entry:   enrichEntry{Lyrics: lyrics, LyricsSource: "kugou", LyricsSourceChoice: "netease"},
		wantSHA: "",
	}, {
		// manual_lyrics 分不出"采纳候选锁的"和"手改正文锁的";补上留痕会让后者变得可被
		// 批量解锁,而那份内容删了找不回来。少做一件事 < 不可逆的损失。
		name:    "已经锁着的:不补留痕(否则手改过的歌会变得可被批量解锁)",
		entry:   enrichEntry{Lyrics: lyrics, LyricsSource: "netease", LyricsSourceChoice: "netease", ManualLyrics: true},
		wantSHA: "",
	}, {
		name:    "没有正文:没东西可指纹",
		entry:   enrichEntry{LyricsSource: "netease", LyricsSourceChoice: "netease"},
		wantSHA: "",
	}, {
		// App 侧新写的比这里从旧字段推断的权威,不许覆盖。
		name:    "已有留痕:不覆盖",
		entry:   enrichEntry{Lyrics: lyrics, LyricsSource: "netease", LyricsSourceChoice: "netease", ManualPickSHA: "keepme"},
		wantSHA: "keepme",
	}}

	enrichCache = map[string]enrichEntry{}
	for _, c := range cases {
		enrichCache[c.name] = c.entry
	}
	// 没有旧字段的条目一律不该被碰。
	enrichCache["无关条目"] = enrichEntry{Lyrics: lyrics, LyricsSource: "qq"}
	enrichPath = t.TempDir() + "/cache.json"

	migrateManualPickMarks()

	for _, c := range cases {
		got := enrichCache[c.name]
		if got.ManualPickSHA != c.wantSHA {
			t.Errorf("%s: ManualPickSHA = %q, want %q", c.name, got.ManualPickSHA, c.wantSHA)
		}
		if got.LyricsSourceChoice != "" {
			t.Errorf("%s: lyrics_source_choice 没清掉(%q) —— 这个中间态已被推翻,留着仍是一道隐形源约束",
				c.name, got.LyricsSourceChoice)
		}
	}
	if e := enrichCache["无关条目"]; e.ManualPickSHA != "" {
		t.Errorf("没有旧字段的条目被误改了: %q", e.ManualPickSHA)
	}

	// 幂等:再跑一遍是空操作(源字段已经空了,不会再命中)。enrichEntry 含切片不可直接比较,
	// 用 JSON 序列化对账 —— 这里要盯的正是"落盘内容有没有变"。
	before, err := json.Marshal(enrichCache)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	migrateManualPickMarks()
	after, err := json.Marshal(enrichCache)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(before) != string(after) {
		t.Error("不幂等:第二遍还在改动缓存")
	}
}
