package main

import (
	"os"
	"path/filepath"
	"testing"
)

// 数据目录的选法跟 App 的 StorageLayout.activeDataDir 一致:环境变量 > 旧目录是软链接 > 新目录存在或旧目录不是目录 > 旧目录。
func TestConfigDirFollowsStorageLayout(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("LYRIMUSE_CONFIG_DIR", "")
	legacy := filepath.Join(home, ".config", clientName)
	data := filepath.Join(home, "Library", "Application Support", appBundleID())

	if got := configDir(); got != data {
		t.Fatalf("全新安装: got %s, want %s", got, data)
	}
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != legacy {
		t.Fatalf("还没搬: got %s, want %s", got, legacy)
	}
	if err := os.MkdirAll(data, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != data {
		t.Fatalf("新旧都在: got %s, want %s", got, data)
	}
	if err := os.RemoveAll(legacy); err != nil {
		t.Fatal(err)
	}
	custom := filepath.Join(home, "elsewhere")
	if err := os.MkdirAll(custom, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(custom, legacy); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != legacy {
		t.Fatalf("旧目录是软链接: got %s, want %s", got, legacy)
	}
	t.Setenv("LYRIMUSE_CONFIG_DIR", custom)
	if got := configDir(); got != custom {
		t.Fatalf("环境变量: got %s, want %s", got, custom)
	}
}

func TestCacheDirRules(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("LYRIMUSE_CONFIG_DIR", "")
	t.Setenv("LYRIMUSE_CACHE_DIR", "")
	if got, want := cacheDir(), filepath.Join(home, "Library", "Caches", appBundleID()); got != want {
		t.Fatalf("默认: got %s, want %s", got, want)
	}
	custom := filepath.Join(home, "custom-data")
	t.Setenv("LYRIMUSE_CONFIG_DIR", custom)
	if got := cacheDir(); got != custom {
		t.Fatalf("只给了数据目录时跟数据目录放一起: got %s, want %s", got, custom)
	}
	caches := filepath.Join(home, "custom-caches")
	t.Setenv("LYRIMUSE_CACHE_DIR", caches)
	if got := cacheDir(); got != caches {
		t.Fatalf("缓存目录环境变量优先: got %s, want %s", got, caches)
	}
	if got, want := cacheFilePath("x.json"), filepath.Join(caches, "x.json"); got != want {
		t.Fatalf("cacheFilePath: got %s, want %s", got, want)
	}
	t.Setenv("LYRIMUSE_CACHE_DIR", "relative/path")
	if got := cacheDir(); got != custom {
		t.Fatalf("相对路径的缓存目录不认: got %s, want %s", got, custom)
	}
}

// 默认位置(新的或还没搬的旧的)用同一个钥匙串账号,搬目录不用迁钥匙串;另起的数据目录按自己的路径隔开。
func TestCredentialVaultAccountStaysOnLegacyPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	legacy := filepath.Join(home, ".config", clientName)
	data := filepath.Join(home, "Library", "Application Support", appBundleID())
	cases := map[string]string{
		data:                         legacy,
		data + "/":                   legacy,
		legacy:                       legacy,
		filepath.Join(home, "other"): filepath.Join(home, "other"),
	}
	for dir, want := range cases {
		if got := credentialVaultAccount(dir); got != want {
			t.Errorf("credentialVaultAccount(%s) = %s, want %s", dir, got, want)
		}
	}
}

// 恢复别处(旧数据目录、别的机器)导出的备份时,设备封面地址按文件名换成本机 artwork/ 里的那张;本机没有的原样留着。
func TestLocalDeviceArtworkURL(t *testing.T) {
	dir := t.TempDir()
	saved := deviceArtworkDir
	deviceArtworkDir = dir
	t.Cleanup(func() { deviceArtworkDir = saved })
	if err := os.WriteFile(filepath.Join(dir, "0123456789abcdef.jpg"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"file:///Users/x/.config/lyrimuse/artwork/0123456789abcdef.jpg": "file://" + filepath.Join(dir, "0123456789abcdef.jpg"),
		"file:///Users/x/.config/lyrimuse/artwork/fedcba9876543210.jpg": "file:///Users/x/.config/lyrimuse/artwork/fedcba9876543210.jpg",
		"https://example.com/a.jpg":                                     "https://example.com/a.jpg",
		"file://" + filepath.Join(dir, "0123456789abcdef.jpg"):          "file://" + filepath.Join(dir, "0123456789abcdef.jpg"),
		"": "",
	}
	for in, want := range cases {
		if got := localDeviceArtworkURL(in); got != want {
			t.Errorf("localDeviceArtworkURL(%q) = %q, want %q", in, got, want)
		}
	}
}
