package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestMergeMissingFromDisk(t *testing.T) {
	path := filepath.Join(t.TempDir(), "c.json")
	os.WriteFile(path, []byte(`{"a":"disk-a","b":"disk-b","empty":""}`), 0o600)
	keep := map[string]string{"a": "mine-a", "c": "mine-c"}
	mergeMissingFromDisk(path, keep, func(v string) bool { return v != "" })
	want := map[string]string{"a": "mine-a", "b": "disk-b", "c": "mine-c"}
	if len(keep) != len(want) {
		t.Fatalf("got %v", keep)
	}
	for k, v := range want {
		if keep[k] != v {
			t.Fatalf("got %v, want %v", keep, want)
		}
	}
	os.WriteFile(path, []byte("{not json"), 0o600)
	keep2 := map[string]string{"x": "y"}
	mergeMissingFromDisk(path, keep2, func(v string) bool { return v != "" })
	mergeMissingFromDisk(filepath.Join(t.TempDir(), "missing.json"), keep2, func(v string) bool { return v != "" })
	if len(keep2) != 1 {
		t.Fatalf("盘上读不出 / 解不开时不动: %v", keep2)
	}
}

// 两个写入方各自学到的条目,存盘之后都在(QQ 歌手名、MusicBrainz 别名 / 主名三份同一个口径)。
func TestArtistNameCachesKeepOtherWritersEntries(t *testing.T) {
	dir := t.TempDir()
	artistAliasMu.Lock()
	savedAP, savedAC, savedAD := artistAliasPath, artistAliasCache, artistAliasDirty
	artistAliasPath, artistAliasCache, artistAliasDirty = filepath.Join(dir, "alias.json"), map[string]string{"mine": "我的"}, true
	artistAliasMu.Unlock()
	qqArtistNameMu.Lock()
	savedQP, savedQC, savedQD := qqArtistNamePath, qqArtistNameCache, qqArtistNameDirty
	qqArtistNamePath, qqArtistNameCache, qqArtistNameDirty = filepath.Join(dir, "qq.json"), map[string]string{"mine": "我的"}, true
	qqArtistNameMu.Unlock()
	mbPrimaryNameMu.Lock()
	savedMP, savedMC, savedMD := mbPrimaryNamePath, mbPrimaryNameCache, mbPrimaryNameDirty
	mbPrimaryNamePath, mbPrimaryNameCache, mbPrimaryNameDirty = filepath.Join(dir, "mb.json"), map[string][]string{"mine": {"我的"}}, true
	mbPrimaryNameMu.Unlock()
	t.Cleanup(func() {
		artistAliasMu.Lock()
		artistAliasPath, artistAliasCache, artistAliasDirty = savedAP, savedAC, savedAD
		artistAliasMu.Unlock()
		qqArtistNameMu.Lock()
		qqArtistNamePath, qqArtistNameCache, qqArtistNameDirty = savedQP, savedQC, savedQD
		qqArtistNameMu.Unlock()
		mbPrimaryNameMu.Lock()
		mbPrimaryNamePath, mbPrimaryNameCache, mbPrimaryNameDirty = savedMP, savedMC, savedMD
		mbPrimaryNameMu.Unlock()
	})
	os.WriteFile(filepath.Join(dir, "alias.json"), []byte(`{"other":"别人的"}`), 0o600)
	os.WriteFile(filepath.Join(dir, "qq.json"), []byte(`{"other":"别人的"}`), 0o600)
	os.WriteFile(filepath.Join(dir, "mb.json"), []byte(`{"other":["别人的"]}`), 0o600)
	saveArtistAliasCache()
	saveQQArtistNameCache()
	saveMBPrimaryNameCache()
	for _, name := range []string{"alias.json", "qq.json", "mb.json"} {
		var got map[string]any
		b, _ := os.ReadFile(filepath.Join(dir, name))
		if json.Unmarshal(b, &got) != nil || got["mine"] == nil || got["other"] == nil {
			t.Errorf("%s 两边的条目都该在: %s", name, b)
		}
	}
}
