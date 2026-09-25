package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// featuresRef 只给测试用:直接拿当前配置快照的指针,改完立刻对 features() 生效。
//
// 生产代码里**没有**这个函数 —— 它定义在 _test.go 里,只编进测试二进制。生产侧必须走
// setFeatures 整体替换:直接改快照内部是数据竞争(183 个读点分布在 poller / 解析 goroutine 里)。
// 测试是单 goroutine,没有这个问题,于是九十多处「只改一个字段」的写法可以原样保留、不用套一层闭包。
func featuresRef() *featureFlags {
	if p := featuresSnapshot.Load(); p != nil {
		return p
	}
	var f featureFlags
	featuresSnapshot.Store(&f)
	return featuresSnapshot.Load()
}

// resetFeaturesForTest 把配置状态恢复干净 —— 路径不登记(=不热重读),快照置空。
func resetFeaturesForTest(t *testing.T) {
	t.Helper()
	savedPath := featuresPath.Load()
	saved := featuresSnapshot.Load()
	t.Cleanup(func() {
		featuresPath.Store(savedPath)
		featuresSnapshot.Store(saved)
		featuresCheckedAt.Store(0)
		featuresMTime.Store(0)
		featuresSize.Store(0)
	})
	featuresPath.Store(nil)
	featuresCheckedAt.Store(0)
	featuresMTime.Store(0)
	featuresSize.Store(0)
}

// 没登记路径 = 各 CLI 子命令的形态:一次盘都不探,行为与热重读上线之前逐字节一致。
func TestFeaturesNoReloadWithoutPath(t *testing.T) {
	resetFeaturesForTest(t)
	setFeatures(featureFlags{LyricsSourceMode: lyricsModePriority})
	if got := features().LyricsSourceMode; got != lyricsModePriority {
		t.Fatalf("快照该原样读回,got %q", got)
	}
	// 即便磁盘上有一份完全不同的配置,没登记路径就不该看见它。
	dir := t.TempDir()
	path := filepath.Join(dir, "f.json")
	if err := os.WriteFile(path, []byte(`{"lyrics_source_mode":"smart"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := features().LyricsSourceMode; got != lyricsModePriority {
		t.Errorf("没登记路径却重读了配置,got %q", got)
	}
}

// 登记路径之后,文件一改,features() 就该读到新值 —— 这是整件事的目的。
func TestFeaturesHotReload(t *testing.T) {
	resetFeaturesForTest(t)
	path := filepath.Join(t.TempDir(), "f.json")
	if err := os.WriteFile(path, []byte(`{"lyrics_source_mode":"smart"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setFeatures(loadFeatureFlags(path))
	setFeaturesPath(path)
	if got := features().LyricsSourceMode; got != lyricsModeSmart {
		t.Fatalf("起始值不对,got %q", got)
	}

	if err := os.WriteFile(path, []byte(`{"lyrics_source_mode":"priority"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	// 节流窗口内不该探盘(这正是 183 个读点不会每次进内核的原因)。
	if got := features().LyricsSourceMode; got != lyricsModeSmart {
		t.Errorf("节流窗口内不该重读,got %q", got)
	}
	// 把上次探盘时间推回去,模拟窗口已过。
	featuresCheckedAt.Store(time.Now().Add(-2 * featuresReloadInterval).UnixNano())
	// priority 不是默认值 —— 读到它就排除了"其实是回落到默认"这种假阳性。
	if got := features().LyricsSourceMode; got != lyricsModePriority {
		t.Errorf("窗口过后该读到新值,got %q", got)
	}
}

// 坏文件绝不能覆盖正在生效的配置 —— 否则"文件坏了一下"就等于把用户所有设置重置成出厂值。
// 这是热重读与启动加载**必须不同**的地方(启动那次只能退回默认,它手上没有别的东西)。
func TestFeaturesCorruptFileKeepsCurrentSettings(t *testing.T) {
	resetFeaturesForTest(t)
	path := filepath.Join(t.TempDir(), "f.json")
	if err := os.WriteFile(path, []byte(`{"lyrics_source_mode":"priority","scrobble_short_tracks":true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setFeatures(loadFeatureFlags(path))
	setFeaturesPath(path)
	if !features().ScrobbleShortTracks {
		t.Fatal("起始值不对")
	}

	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	featuresCheckedAt.Store(time.Now().Add(-2 * featuresReloadInterval).UnixNano())
	if got := features(); !got.ScrobbleShortTracks || got.LyricsSourceMode != lyricsModePriority {
		t.Errorf("坏文件把生效中的设置冲掉了:ScrobbleShortTracks=%v mode=%q",
			got.ScrobbleShortTracks, got.LyricsSourceMode)
	}
}

// lyrics_dir 也跟着热更新:快照里是新值,真正搬家由 switchLyricsDir 在后台做(见 lyricsdirswitch_test.go)。
func TestFeaturesHotReloadUpdatesLyricsDir(t *testing.T) {
	resetFeaturesForTest(t)
	path := filepath.Join(t.TempDir(), "f.json")
	if err := os.WriteFile(path, []byte(`{"lyrics_dir":"/old/place"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setFeatures(loadFeatureFlags(path))
	setFeaturesPath(path)

	if err := os.WriteFile(path, []byte(`{"lyrics_dir":"/new/place","scrobble_short_tracks":true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	featuresCheckedAt.Store(time.Now().Add(-2 * featuresReloadInterval).UnixNano())
	got := features()
	if got.LyricsDir != "/new/place" || !got.ScrobbleShortTracks {
		t.Errorf("lyrics_dir 和别的键都该在同一次重读里生效,got dir=%q short=%v", got.LyricsDir, got.ScrobbleShortTracks)
	}
}
