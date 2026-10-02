package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func resetBodyHealStateForTest(t *testing.T) {
	t.Helper()
	takeEnrichBodiesToRewrite()
	savedSanitized, savedRestore := enrichBodySanitizedCRCs, lyricsImportRestoreKeys
	enrichBodySanitizedCRCs = nil
	t.Cleanup(func() {
		takeEnrichBodiesToRewrite()
		enrichBodySanitizedCRCs, lyricsImportRestoreKeys = savedSanitized, savedRestore
	})
}

// 正文里混进非法 UTF-8 字节:写出去的正文小文件要自洽(校验值按换成 U+FFFD 之后的内容算),主缓存记的校验值
// 跟它一致,重新加载能原样补回,不被判成损坏。
func TestLeanSaveWritesSelfConsistentBodyForInvalidUTF8(t *testing.T) {
	withTempLeanCache(t)
	resetBodyHealStateForTest(t)
	key := "Justin Bieber|Trust|Purpose (Deluxe)"
	entry := enrichEntry{Lyrics: "[00:01.00]Trust", LyricsTr: "[00:01.00]\xb8\xe8\xc7\xfa"}
	putEntriesForTest(map[string]enrichEntry{key: entry})
	saveEnrichCache()

	body := parseEnrichBody(mustRead(t, filepath.Join(enrichBodiesDir(), decisionSidecarName(key))))
	if body == nil {
		t.Fatal("正文小文件要自洽")
	}
	var disk map[string]struct {
		BodyCRC uint32 `json:"body_crc"`
	}
	if err := json.Unmarshal(mustRead(t, enrichPath), &disk); err != nil {
		t.Fatal(err)
	}
	if disk[key].BodyCRC != body.CRC {
		t.Errorf("主缓存记的校验值 %d 跟正文小文件的 %d 对不上", disk[key].BodyCRC, body.CRC)
	}

	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	loadEnrichCache(enrichPath)
	enrichMu.Lock()
	got := enrichCache[key]
	enrichMu.Unlock()
	if got.LyricsTr != jsonSafeString(entry.LyricsTr) {
		t.Errorf("重新加载后译文 = %q", got.LyricsTr)
	}
	if takeEnrichBodiesToRewrite()[key] {
		t.Error("自洽的正文小文件不该被判成损坏")
	}
}

// 换过非法字节的那一首,内存里那份没变就不再重写:删掉文件再存一次,文件不该被重新写出来。
func TestLeanSaveDoesNotRewriteSanitizedBodyEverySave(t *testing.T) {
	withTempLeanCache(t)
	resetBodyHealStateForTest(t)
	key := "Justin Bieber|Trust|Purpose (Deluxe)"
	entry := enrichEntry{Lyrics: "[00:01.00]Trust", LyricsTr: "[00:01.00]\xb8\xe8\xc7\xfa"}
	putEntriesForTest(map[string]enrichEntry{key: entry})
	saveEnrichCache()
	side := filepath.Join(enrichBodiesDir(), decisionSidecarName(key))
	if err := os.Remove(side); err != nil {
		t.Fatal(err)
	}
	putEntriesForTest(map[string]enrichEntry{key: entry})
	saveEnrichCache()
	if _, err := os.Stat(side); err == nil {
		t.Error("内存里那份没变,不该每次保存都重写")
	}
}

// 正文小文件里的校验值字段是对的、内容却坏了:加载时判成损坏。正文从 lyrics/ 补回来跟原来一模一样时,下一次保存
// 也要重写它,不然种回来的校验值说「写过了」,坏文件永远等不到重写,每次启动都报一遍。
func TestDamagedSideFileIsRewrittenEvenIfBodyUnchanged(t *testing.T) {
	withTempLeanCache(t)
	resetBodyHealStateForTest(t)
	full := testFullEnrichEntries()
	putEntriesForTest(full)
	saveEnrichCache()

	key := "Coldplay|Yellow|Parachutes"
	side := filepath.Join(enrichBodiesDir(), decisionSidecarName(key))
	writeTestBody(t, enrichBodiesDir(), key, enrichBody{CRC: enrichBodyCRC(full[key]), Lyrics: "被截断的"})

	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	enrichSaveMu.Lock()
	enrichBodyCRCs = nil
	enrichSaveMu.Unlock()
	loadEnrichCache(enrichPath)
	putEntriesForTest(map[string]enrichEntry{key: full[key]})
	saveEnrichCache()

	if parseEnrichBody(mustRead(t, side)) == nil {
		t.Error("损坏的正文小文件在正文没变时也要重写")
	}
}
