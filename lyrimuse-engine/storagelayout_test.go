package main

import (
	"os"
	"path/filepath"
	"testing"
)

// 数据目录的选法跟 App 的 StorageLayout.activeDataDir 一致:环境变量 > 旧目录是软链接(指向新目录的用新目录)> 新目录存在或旧目录不是目录 > 旧目录。
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
	if got := configDir(); got != data {
		t.Fatalf("旧目录是空的: got %s, want %s", got, data)
	}
	if err := os.WriteFile(filepath.Join(legacy, "config.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != legacy {
		t.Fatalf("还没搬: got %s, want %s", got, legacy)
	}
	if err := os.MkdirAll(data, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, "unrelated"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != legacy {
		t.Fatalf("新目录先被别的东西建了出来、没有数据: got %s, want %s", got, legacy)
	}
	if err := os.WriteFile(filepath.Join(data, storageMigrationMarker), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != data {
		t.Fatalf("搬过之后旧目录又冒出来: got %s, want %s", got, data)
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
	if err := os.Remove(legacy); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(data, legacy); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != data {
		t.Fatalf("旧目录是搬迁留下的、指向新目录的软链接: got %s, want %s", got, data)
	}
	if err := os.Remove(legacy); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(data+"/", legacy); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != data {
		t.Fatalf("指向新目录的软链接(带尾斜杠): got %s, want %s", got, data)
	}
	t.Setenv("LYRIMUSE_CONFIG_DIR", custom)
	if got := configDir(); got != custom {
		t.Fatalf("环境变量: got %s, want %s", got, custom)
	}
}

// 数据目录被删了、留给旧版本的软链接还在(悬空):照样认成新目录(用的时候再建),不去用悬空的旧路径。
func TestConfigDirDanglingCompatLink(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("LYRIMUSE_CONFIG_DIR", "")
	legacy := filepath.Join(home, ".config", clientName)
	data := filepath.Join(home, "Library", "Application Support", appBundleID())
	if err := os.MkdirAll(filepath.Dir(legacy), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(data, legacy); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != data {
		t.Fatalf("悬空的软链接: got %s, want %s", got, data)
	}
}

// 日志默认在 ~/Library/Logs/Lyrimuse/ 下(跟 App 的 LogFiles 一致);常驻进程打开日志之前先建这一层目录,
// launchd 的 StandardErrorPath 和轮转打开都不建。
func TestLogFilePathDefaultsToLyrimuseFolder(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("LYRIMUSE_LOG_FILE", "")
	if got, want := logFilePath(), filepath.Join(home, "Library", "Logs", "Lyrimuse", clientName+".log"); got != want {
		t.Fatalf("logFilePath() = %s, want %s", got, want)
	}
	src, err := os.ReadFile("logsink.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "os.MkdirAll(filepath.Dir(path), 0o755)") {
		t.Error("installLogSink 打开日志之前没建日志目录")
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

// 默认位置(新的或还没搬的旧的)的钥匙串账号是新数据目录的路径串,以前的账号是旧目录的;另起的数据目录按自己的路径隔开、没有以前的账号。
func TestCredentialVaultAccountUsesDataPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	legacy := filepath.Join(home, ".config", clientName)
	data := filepath.Join(home, "Library", "Application Support", appBundleID())
	other := filepath.Join(home, "other")
	cases := map[string][2]string{
		data:       {data, legacy},
		data + "/": {data, legacy},
		legacy:     {data, legacy},
		other:      {other, ""},
	}
	for dir, want := range cases {
		if got := credentialVaultAccount(dir); got != want[0] {
			t.Errorf("credentialVaultAccount(%s) = %s, want %s", dir, got, want[0])
		}
		if got := previousCredentialVaultAccount(dir); got != want[1] {
			t.Errorf("previousCredentialVaultAccount(%s) = %q, want %q", dir, got, want[1])
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

// 数据目录搬过家、旧地址没改写到的条目:清理那一轮按文件名换成本机 artwork/ 里的同一张,来源、主色都留着;本机也没有的才清。
func TestClearMissingDeviceArtworkRepairsMovedPaths(t *testing.T) {
	dir := t.TempDir()
	saved := deviceArtworkDir
	deviceArtworkDir = dir
	t.Cleanup(func() { deviceArtworkDir = saved })
	if err := os.WriteFile(filepath.Join(dir, "0123456789abcdef.jpg"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	moved := enrichEntry{CoverURL: "file:///Users/x/.config/lyrimuse/artwork/0123456789abcdef.jpg", CoverSource: "device", AccentColor: "#112233"}
	if !clearMissingDeviceArtwork(&moved) {
		t.Fatal("搬过家的地址要算改动")
	}
	if want := "file://" + filepath.Join(dir, "0123456789abcdef.jpg"); moved.CoverURL != want || moved.CoverSource != "device" || moved.AccentColor != "#112233" {
		t.Errorf("换成本机地址、别的字段留着: %+v", moved)
	}
	gone := enrichEntry{CoverURL: "file:///Users/x/.config/lyrimuse/artwork/fedcba9876543210.jpg", CoverSource: "device"}
	if !clearMissingDeviceArtwork(&gone) || gone.CoverURL != "" || gone.CoverSource != "" {
		t.Errorf("本机也没有的照旧清掉: %+v", gone)
	}
}

// 新装的机器上缓存目录还不存在:进程起来时建好,不然 writeFileAtomic 写不进去。
func TestEnsureCacheDirCreatesMissingFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Library", "Caches", "x")
	t.Setenv("LYRIMUSE_CACHE_DIR", dir)
	ensureCacheDir()
	if err := writeFileAtomic(cacheFilePath("probe.json"), []byte("{}")); err != nil {
		t.Fatalf("缓存目录建好后应能写入: %v", err)
	}
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "installLogSink(isDaemonInvocation(os.Args))\n\tensureCacheDir()") {
		t.Error("main 一开头(子命令分流之前)就要建缓存目录")
	}
}
