package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestLyricsEmptyInCacheFile 钉住「手动重匹配到底该不该放行」那个事实是**读出来的**、
// 不是从 `-current-source == ""` 推断出来的。
//
// 2026-08-22 对抗性复核抓到的反例:EnrichCacheStore.saveEdit 的 source 默认 nil,而
// 「歌词管理」的「保存修改」正是不传 source 的那个重载 —— 它 removeValue("lyrics_source"),
// 导出的 .lrc 也不带 [source:]。于是**每一条用户手改过的条目**都是「有歌词 + 来源为空」。
// 靠空串推断的话,这道闸会对手改条目一律放行,让冠军覆盖掉人工修正过的正文。
func TestLyricsEmptyInCacheFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cache.json")
	// 三种形态:①正常有歌词有来源 ②手改过(有歌词、**没有** lyrics_source)③解析失败留空壳
	body := `{
	  "Michael Jackson|Beat It|Thriller": {"lyrics":"[00:01.00]line","lyrics_source":"qq"},
	  "Michael Jackson|Hand-Edited|Thriller": {"lyrics":"[00:01.00]我手改过的","manual_lyrics":true},
	  "南拳妈妈弹头|枫+退后+搁浅 (Live)|周杰伦地表最强世界巡回演唱会 (Live)": {"duration_secs":119.213}
	}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("写测试缓存: %v", err)
	}

	cases := []struct {
		name                 string
		artist, title, album string
		wantEmpty, wantKnown bool
	}{
		{"正常条目:有歌词 → 不放行", "Michael Jackson", "Beat It", "Thriller", false, true},
		{"手改条目:有歌词但没记来源 → **仍然不放行**(这就是复核抓到的反例)",
			"Michael Jackson", "Hand-Edited", "Thriller", false, true},
		{"解析失败的空壳条目:没有歌词 → 放行",
			"南拳妈妈弹头", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)", true, true},
		{"缓存里压根没有这个 key:还没解析过的新歌 → 放行",
			"Michael Jackson", "Smooth Criminal", "Bad", true, true},
	}
	for _, c := range cases {
		empty, known := lyricsEmptyInCacheFile(path, c.artist, c.title, c.album)
		if empty != c.wantEmpty || known != c.wantKnown {
			t.Errorf("%s: lyricsEmptyInCacheFile(%q,%q,%q) = (empty=%v, known=%v), want (%v, %v)",
				c.name, c.artist, c.title, c.album, empty, known, c.wantEmpty, c.wantKnown)
		}
	}

	// 读不出来 / 解析不动 → known=false,调用方按最保守的那一支走(等同改动之前)
	if _, known := lyricsEmptyInCacheFile(filepath.Join(dir, "nope.json"), "a", "b", "c"); known {
		t.Errorf("文件不存在时 known 必须为 false")
	}
	broken := filepath.Join(dir, "broken.json")
	if err := os.WriteFile(broken, []byte("{ not json"), 0o644); err != nil {
		t.Fatalf("写坏文件: %v", err)
	}
	if _, known := lyricsEmptyInCacheFile(broken, "a", "b", "c"); known {
		t.Errorf("解析不动时 known 必须为 false")
	}
	// ⚠️ 只读:不许把坏文件挪成 .corrupt(loadEnrichCache 会那么做,这条路径绝不能)
	if _, err := os.Stat(broken + ".corrupt"); err == nil {
		t.Errorf("lyricsEmptyInCacheFile 不得有任何副作用,却把文件挪成了 .corrupt")
	}
	if _, err := os.Stat(broken); err != nil {
		t.Errorf("原文件必须原地不动: %v", err)
	}
}
