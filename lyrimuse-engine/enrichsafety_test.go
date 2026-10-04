package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 缓存这次没读进来时的几个全局开关,测试结束还原。
func saveEnrichLoadFlags(t *testing.T) {
	t.Helper()
	enrichMu.Lock()
	failed, all, keys := enrichLoadFailed, lyricsImportRestoreAll, lyricsImportRestoreKeys
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichLoadFailed, lyricsImportRestoreAll, lyricsImportRestoreKeys = failed, all, keys
		enrichMu.Unlock()
	})
}

// 主缓存读出错(不是不存在):这个进程不写它,原文件原样留着;改动一律存不下、如实报错。
func TestLoadEnrichCacheReadErrorRefusesSaves(t *testing.T) {
	dir := withTempIndexCache(t)
	saveEnrichLoadFlags(t)
	path := filepath.Join(dir, "cache-is-a-dir.json")
	if err := os.Mkdir(path, 0o755); err != nil { // 读目录必然出错,又不是「不存在」
		t.Fatal(err)
	}
	loadEnrichCache(path)
	if enrichPath != "" || !enrichLoadFailed || !lyricsImportRestoreAll {
		t.Fatalf("读出错后应当不落盘并让导入全赢: enrichPath=%q failed=%v restoreAll=%v", enrichPath, enrichLoadFailed, lyricsImportRestoreAll)
	}
	putEntriesForTest(map[string]enrichEntry{"a|t|b": {Lyrics: "[00:01.00]hi"}})
	if err := saveEnrichCacheChecked(); err != errEnrichCacheNotLoaded {
		t.Fatalf("save err = %v, want errEnrichCacheNotLoaded", err)
	}
	if info, err := os.Stat(path); err != nil || !info.IsDir() {
		t.Fatalf("原路径被动过: %v", err)
	}
	if res := applyEnrichEdit(enrichEditRequest{ID: "1", Op: "delete", Key: "a|t|b"}); res.OK || res.Error == "" {
		t.Fatalf("缓存没读进来时编辑应当被拒: %+v", res)
	}
}

// 主缓存解析不动:挪到带时间的 .corrupt 名下,正文小文件目录、判决旁路目录一起挪走,导入全赢。
func TestLoadEnrichCacheCorruptMovesSideDirsAside(t *testing.T) {
	dir := withTempIndexCache(t)
	saveEnrichLoadFlags(t)
	path := enrichPath
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	bodies := enrichBodiesDirFor(path)
	decisions := filepath.Join(dir, clientName+"-decisions")
	for _, d := range []string{bodies, decisions} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "x.json"), []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	loadEnrichCache(path)
	if enrichPath != path || enrichLoadFailed || !lyricsImportRestoreAll {
		t.Fatalf("挪走成功后应照常落盘、导入全赢: enrichPath=%q failed=%v restoreAll=%v", enrichPath, enrichLoadFailed, lyricsImportRestoreAll)
	}
	for _, p := range []string{path, bodies, decisions} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s 应当已挪走: %v", filepath.Base(p), err)
		}
		matches, _ := filepath.Glob(p + ".corrupt-*")
		if len(matches) != 1 {
			t.Errorf("%s 的旁路副本 = %v, want 1 个", filepath.Base(p), matches)
		}
	}
}

// 写盘失败:脏标记还原,退出前那次保存还会再写。
func TestSaveEnrichCacheFailureKeepsDirty(t *testing.T) {
	withTempLeanCache(t)
	ro := t.TempDir()
	if err := os.Chmod(ro, 0o500); err != nil { // 只读目录:临时文件建不出来
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(ro, 0o700) })
	enrichMu.Lock()
	enrichPath = filepath.Join(ro, "cache.json")
	enrichMu.Unlock()
	putEntriesForTest(map[string]enrichEntry{"a|t|b": {Lyrics: "[00:01.00]hi"}})
	if err := saveEnrichCacheChecked(); err == nil {
		t.Fatal("目录只读时保存应当失败")
	}
	enrichMu.Lock()
	dirty := enrichDirty
	enrichMu.Unlock()
	if !dirty {
		t.Fatal("保存失败后脏标记应当还原")
	}
}

// 记账保存:不是正在播的这首时攒着,到点只补写一次;正在播的这首照常当场写;flush 把排着的那次取消并当场写。
func TestRequestEnrichBookkeepingSaveCoalesces(t *testing.T) {
	var saves atomic.Int32
	origNow, origInterval, origDelay := enrichSaveNow, enrichSaveMinInterval, enrichBookkeepingSaveDelay
	enrichSaveThrottleMu.Lock()
	origThrottled, origLast := enrichSaveThrottled, enrichLastSaveAt
	enrichSaveThrottleMu.Unlock()
	origPlaying := enrichPlayingKey.Load()
	t.Cleanup(func() {
		enrichSaveThrottleMu.Lock()
		for _, tm := range []**time.Timer{&enrichSaveTimer, &enrichBookkeepingTimer} {
			if *tm != nil {
				(*tm).Stop()
				*tm = nil
			}
		}
		enrichSaveThrottled, enrichLastSaveAt = origThrottled, origLast
		enrichSaveThrottleMu.Unlock()
		enrichSaveNow, enrichSaveMinInterval, enrichBookkeepingSaveDelay = origNow, origInterval, origDelay
		enrichPlayingKey.Store(origPlaying)
	})
	enrichSaveNow = func() { saves.Add(1) }
	enrichSaveMinInterval = 10 * time.Millisecond
	enrichBookkeepingSaveDelay = 80 * time.Millisecond
	enrichSaveThrottleMu.Lock()
	enrichSaveThrottled, enrichLastSaveAt = true, time.Time{}
	enrichSaveThrottleMu.Unlock()
	noteEnrichPlayingKey("playing|now|x")

	for range 5 {
		requestEnrichBookkeepingSave("other|song|y")
	}
	if n := saves.Load(); n != 0 {
		t.Fatalf("记账改动不该当场写: saves = %d", n)
	}
	time.Sleep(200 * time.Millisecond)
	if n := saves.Load(); n != 1 {
		t.Fatalf("到点应当只补写一次: saves = %d", n)
	}

	saves.Store(0)
	time.Sleep(20 * time.Millisecond)
	requestEnrichBookkeepingSave("playing|now|x")
	if n := saves.Load(); n != 1 {
		t.Fatalf("正在播的这首应当当场写: saves = %d", n)
	}

	saves.Store(0)
	requestEnrichBookkeepingSave("other|song|y")
	flushEnrichSave()
	time.Sleep(150 * time.Millisecond)
	if n := saves.Load(); n != 1 {
		t.Fatalf("flush 应当取消排着的记账补写并当场写一次: saves = %d", n)
	}
}

// 导入:带 BOM 的文件照常认;空文件 / 认不出头部的变体不采纳(不清空字段)。
func TestImportSkipsUnreadableVariants(t *testing.T) {
	key := "歌手|歌名|专辑"
	dir := withExportFixture(t, map[string]enrichEntry{key: {Lyrics: "[00:01.00]原文", LyricsTr: "[00:01.00]译文", LyricsSource: "netease"}})
	exportLyricsFiles()
	trPath := filepath.Join(dir, sanitizeLyricsFilename(key)+".tr.lrc")
	orig, err := os.ReadFile(trPath)
	if err != nil {
		t.Fatal(err)
	}
	edited := strings.Replace(string(orig), "译文", "改过的译文", 1)
	if err := os.WriteFile(trPath, []byte("\ufeff"+edited), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFrom(dir, false)
	if got := enrichCache[key].LyricsTr; got != "[00:01.00]改过的译文" {
		t.Fatalf("带 BOM 的手改应当被采纳: %q", got)
	}
	for _, bad := range []string{"", "no header here\n[00:01.00]x"} {
		if err := os.WriteFile(trPath, []byte(bad), 0o644); err != nil {
			t.Fatal(err)
		}
		importLyricsFrom(dir, false)
		if got := enrichCache[key].LyricsTr; got != "[00:01.00]改过的译文" {
			t.Fatalf("认不出的变体 %q 不该清空译文: %q", bad, got)
		}
	}
}

// 缓存里这几条的正文丢了、文件没动过:启动那次导入照样让文件把它们补回来,之后恢复按记录跳过。
func TestImportRestoresKeysWithMissingBodies(t *testing.T) {
	lyrics := withLyricsFileStateEnv(t)
	saveEnrichLoadFlags(t)
	key := "歌手|歌名|专辑"
	withEnrichCache(t, map[string]enrichEntry{key: {Lyrics: "[00:01.00]原文", LyricsTr: "[00:01.00]译文", LyricsSource: "netease"}})
	exportLyricsFiles()
	enrichMu.Lock()
	e := enrichCache[key]
	e.LyricsTr = ""
	enrichCache[key] = e
	enrichMu.Unlock()
	importLyricsFrom(lyrics, false)
	if enrichCache[key].LyricsTr != "" {
		t.Fatal("前提:文件没动过时导入按记录跳过")
	}
	enrichMu.Lock()
	lyricsImportRestoreKeys = map[string]bool{key: true}
	enrichMu.Unlock()
	importLyricsFrom(lyrics, false)
	if got := enrichCache[key].LyricsTr; got != "[00:01.00]译文" {
		t.Fatalf("正文丢了的条目应当从文件补回: %q", got)
	}
	if lyricsImportRestoreKeys != nil {
		t.Fatal("补回名单只用一次")
	}
}

// 导出要删 / 要盖一份认不出头部的文件时,挪进废纸篓而不是直接删掉。
func TestExportTrashesUnrecognizedFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, ".Trash"), 0o755); err != nil {
		t.Fatal(err)
	}
	key := "歌手|歌名|专辑"
	dir := withExportFixture(t, map[string]enrichEntry{key: {Lyrics: "[00:01.00]原文", LyricsSource: "netease"}})
	base := sanitizeLyricsFilename(key)
	for _, suffix := range []string{".lrc", ".tr.lrc"} {
		if err := os.WriteFile(filepath.Join(dir, base+suffix), []byte("user notes "+suffix), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	exportLyricsFiles()
	trashed, _ := os.ReadDir(filepath.Join(home, ".Trash"))
	if len(trashed) != 2 {
		t.Fatalf("两份认不出的文件都该进废纸篓: %d", len(trashed))
	}
	if _, err := os.Stat(filepath.Join(dir, base+".tr.lrc")); !os.IsNotExist(err) {
		t.Fatal("没有译文的条目不该留 .tr.lrc")
	}
	if p := parseLyricsBytes(mustRead(t, filepath.Join(dir, base+".lrc"))); !p.ok || p.body != "[00:01.00]原文" {
		t.Fatalf(".lrc 应当是缓存里的内容: %+v", p)
	}
}

// 外围补全锁里不发 QQ 请求;设备封面复查不跟首次解析的 ctx 走。
func TestEnrichLockAndSettleContracts(t *testing.T) {
	src := string(mustRead(t, "enrich.go"))
	start := strings.Index(src, "func backfillPeripheralFields(")
	end := strings.Index(src[start:], "\n}\n")
	if start < 0 || end < 0 {
		t.Fatal("找不到 backfillPeripheralFields")
	}
	if body := src[start : start+end]; strings.Contains(body, "qqSongCatalogMids(") {
		t.Error("backfillPeripheralFields 里不许直接调 qqSongCatalogMids(会在 enrichMu 里发请求),走 lookupPeripheralQQMids")
	}
	if !strings.Contains(src, "go settleDeviceCover(context.WithoutCancel(ctx),") {
		t.Error("settleDeviceCover 要用 context.WithoutCancel,首次解析一结束 ctx 就被取消")
	}
}
