package main

import (
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
)

// players.json 的 needsFullDiskAccess 是界面决定「要不要摆出完全磁盘访问那一行」的依据,
// 必须跟 collector 真实读的路径一致:有任何一份客户端文件在私有容器里就要授权,反之不要。
func TestPlayersNeedFullDiskAccessMatchesClientPaths(t *testing.T) {
	overrides := []*string{
		&kugouLocalDirOverride, &kugouUpcomingOverride, &kugouQueuePlistOverride,
		&kugouConfigPlistOverride, &kugouLibraryDBOverride, &kugouNowPlayingOverride,
		&qqLocalDBOverride, &qqUpcomingOverride, &neteaseLocalDBOverride, &neteaseUpcomingOverride,
		&sodaLocalQueueOverride, &sodaPreloadOverride, &applemusicLocalDirOverride, &spotifyISRCUsersDirOverride,
		&kkboxLocalStorageOverride, &kkboxCacheDirOverride,
	}
	saved := make([]string, len(overrides))
	for i, o := range overrides {
		saved[i], *o = *o, ""
	}
	defer func() {
		for i, o := range overrides {
			*o = saved[i]
		}
	}()

	// 播放器 → localCacheClientPaths 里的来源名。
	sourceOf := map[string]string{
		playerAppleMusic: "applemusic",
		playerQQMusic:    "qq",
		playerNetease:    "netease",
		playerKugou:      "kugou",
		playerSoda:       "soda",
		playerSpotify:    "spotify",
		playerKKBOX:      "kkbox",
	}
	paths := localCacheClientPaths()
	for _, player := range allPlayerIDs {
		if player == playerAuto {
			continue
		}
		source, ok := sourceOf[player]
		if !ok {
			t.Errorf("%s 没登记读哪些客户端文件 —— 在 sourceOf 和 localCacheClientPaths 里补上", player)
			continue
		}
		list := paths[source]
		if len(list) == 0 {
			t.Errorf("%s(%s)在 localCacheClientPaths 里没有路径", player, source)
			continue
		}
		inContainer := false
		for _, p := range list {
			if p == "" {
				t.Errorf("%s 的某条路径是空的(home 取不到?)", source)
			}
			if containerDataRoot(p) != "" {
				inContainer = true
			}
		}
		if got := playerNeedsFullDiskAccess[player]; got != inContainer {
			t.Errorf("%s: players.json needsFullDiskAccess=%v,但它的客户端文件在私有容器里=%v", player, got, inContainer)
		}
	}
}

func TestContainerDataRoot(t *testing.T) {
	for in, want := range map[string]string{
		"/Users/x/Library/Containers/com.kugou.mac.Music/Data/Library/Preferences/a.plist": "/Users/x/Library/Containers/com.kugou.mac.Music/Data",
		"/Users/x/Library/Containers/com.netease.163music/Data":                            "/Users/x/Library/Containers/com.netease.163music/Data",
		"/Users/x/Library/Application Support/SodaMusic/LunaStorage/QueueCache":            "",
		"/Users/x/Library/Containers/":                                                     "",
		"":                                                                                 "",
	} {
		if got := containerDataRoot(in); got != want {
			t.Errorf("containerDataRoot(%q) = %q, 期望 %q", in, got, want)
		}
	}
	targets := localCacheProbeTargets(map[string][]string{
		"kugou": {"/h/Library/Containers/k/Data/a", "/h/Library/Containers/k/Data/b/c"},
		"soda":  {"/h/Library/Application Support/SodaMusic/x"},
	})
	if len(targets) != 1 || len(targets["kugou"]) != 1 || targets["kugou"][0] != "/h/Library/Containers/k/Data" {
		t.Errorf("同一容器只探一次、不在容器里的来源不探,got %v", targets)
	}
}

// 启动探测:读得到进 readable,被拒进 denied,容器不存在的来源什么都不发布。
func TestProbeLocalCacheTargetsPublishesBothSides(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 不受目录权限限制,造不出被拒")
	}
	prevOut := log.Writer()
	log.SetOutput(io.Discard)
	defer log.SetOutput(prevOut)

	statePath := filepath.Join(t.TempDir(), "access.json")
	setLocalCacheAccessPath(statePath)
	defer setLocalCacheAccessPath("")
	localCacheDeniedMu.Lock()
	localCacheDeniedReported = map[string]string{}
	localCacheDeniedNow = map[string]bool{}
	localCacheReadableNow = map[string]bool{}
	localCacheDeniedMu.Unlock()

	root := filepath.Join(t.TempDir(), "Library", "Containers")
	open := filepath.Join(root, "open.app", "Data")
	locked := filepath.Join(root, "locked.app", "Data")
	for _, d := range []string{open, locked} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(locked, 0o755)

	probeLocalCacheTargets(map[string][]string{
		"qq":      {open},
		"kugou":   {locked},
		"netease": {filepath.Join(root, "missing.app", "Data")},
	})
	raw, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("探测后该有状态文件: %v", err)
	}
	var st localCacheAccessState
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatal(err)
	}
	if len(st.Readable) != 1 || st.Readable[0] != "qq" {
		t.Errorf("readable = %v,期望 [qq]", st.Readable)
	}
	if len(st.Denied) != 1 || st.Denied[0] != "kugou" {
		t.Errorf("denied = %v,期望 [kugou]", st.Denied)
	}

	// 授权之后(重启后再探)从 denied 挪到 readable。
	os.Chmod(locked, 0o755)
	probeLocalCacheTargets(map[string][]string{"kugou": {locked}})
	raw, _ = os.ReadFile(statePath)
	_ = json.Unmarshal(raw, &st)
	if len(st.Denied) != 0 || len(st.Readable) != 2 {
		t.Errorf("授权后 kugou 该挪进 readable,got denied=%v readable=%v", st.Denied, st.Readable)
	}
}
