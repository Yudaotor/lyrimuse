package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func withTempLeanCache(t *testing.T) {
	t.Helper()
	withTempIndexCache(t)
	saved := enrichDiskFullFormat
	t.Cleanup(func() { enrichDiskFullFormat = saved })
	enrichDiskFullFormat = false
}

func putEntriesForTest(entries map[string]enrichEntry) {
	enrichMu.Lock()
	for k, e := range entries {
		enrichCache[k] = e
	}
	enrichDirty = true
	enrichMu.Unlock()
}

// 保存写精简格式、再加载回来,内存里的条目跟保存前一模一样。
func TestLeanSaveRoundTrip(t *testing.T) {
	withTempLeanCache(t)
	full := testFullEnrichEntries()
	putEntriesForTest(full)
	saveEnrichCache()

	raw := mustRead(t, enrichPath)
	for _, big := range []string{"lyrics_yrc", "lyrics_tr", "lyrics_roma", "plain_lyrics"} {
		if strings.Contains(string(raw), big) {
			t.Fatalf("主缓存不该再带 %s", big)
		}
	}
	if !strings.Contains(string(raw), "故事的小黄花") {
		t.Fatal("主歌词留在主缓存里")
	}

	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	loadEnrichCache(enrichPath)
	enrichMu.Lock()
	got := enrichCache
	enrichMu.Unlock()
	if !reflect.DeepEqual(got, full) {
		t.Errorf("读回来跟保存前不一致:\n got %#v\nwant %#v", got, full)
	}
	if enrichDiskFullFormat {
		t.Error("精简格式读进来不该再要求备份")
	}
}

// 正文小文件没写成(目录建不了)的条目,主缓存里照旧整块写 —— 正文不能只落在一个没写成的地方。
func TestLeanSaveKeepsBodiesInlineWhenSideFileFails(t *testing.T) {
	withTempLeanCache(t)
	if err := os.WriteFile(enrichBodiesDir(), []byte("not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}
	putEntriesForTest(testFullEnrichEntries())
	saveEnrichCache()
	raw := mustRead(t, enrichPath)
	if !strings.Contains(string(raw), "lyrics_yrc") || strings.Contains(string(raw), "body_crc") {
		t.Fatalf("小文件没写成时主缓存必须带完整正文: %s", raw)
	}
}

// 老格式的主缓存第一次被改写成精简格式之前,原样留一份 .full-format.bak;之后不再覆盖它。
func TestLeanSaveBacksUpFullFormatOnce(t *testing.T) {
	withTempLeanCache(t)
	full := testFullEnrichEntries()
	old, err := json.Marshal(full)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(enrichPath, old, 0o644); err != nil {
		t.Fatal(err)
	}
	loadEnrichCache(enrichPath)
	if !enrichDiskFullFormat {
		t.Fatal("老格式读进来要记下需要备份")
	}
	enrichMu.Lock()
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	backup := enrichPath + ".full-format.bak"
	if b := mustRead(t, backup); !bytes.Equal(b, old) {
		t.Fatal("备份必须是改写前的原样")
	}
	if strings.Contains(string(mustRead(t, enrichPath)), "lyrics_yrc") {
		t.Fatal("备份之后主缓存改写成精简格式")
	}

	putEntriesForTest(map[string]enrichEntry{"新|歌|": {Lyrics: "[00:01.00]new", LyricsTr: "[00:01.00]新"}})
	saveEnrichCache()
	if b := mustRead(t, backup); !bytes.Equal(b, old) {
		t.Fatal("备份只写一次,之后的保存不能覆盖它")
	}
	if matches, _ := filepath.Glob(backup + ".tmp.*"); len(matches) != 0 {
		t.Fatalf("备份不能留临时文件: %v", matches)
	}
}

// 正文记录是另一个目录的(换了配置目录):不能拿它当「新目录里已经写好了」,否则主缓存写成精简条目、正文却没落盘。
func TestLeanSaveReseedsBodyRecordForNewDir(t *testing.T) {
	withTempLeanCache(t)
	full := testFullEnrichEntries()
	putEntriesForTest(full)
	saveEnrichCache()

	withTempDecisionCache(t) // 换一个目录,enrichBodyCRCs 还是上一个目录的记录
	putEntriesForTest(full)
	saveEnrichCache()
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	loadEnrichCache(enrichPath)
	enrichMu.Lock()
	got := enrichCache
	enrichMu.Unlock()
	if !reflect.DeepEqual(got, full) {
		t.Errorf("换目录之后读回来丢了正文:\n got %#v", got)
	}
}
