package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// withFeaturesFile 建一份临时 features.json 并把它登记给热读器,跑完还原包级状态
// (features / lyricSourcesPath 都是包级的,不还原会串到同一个包里的其它测试)。
func withFeaturesFile(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "lyrimuse-features.json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("写临时 features.json: %v", err)
	}
	startup := features()
	t.Cleanup(func() {
		setFeatures(startup)
		setLyricSourcesPath("")
	})
	setLyricSourcesPath(path)
	return path
}

// rewrite 覆盖同一个路径,并把 mtime 往前推一秒 —— 判据是 mtime 或大小任一变化,长度相同
// 又写得够快时两次 Stat 会拿到同一个 mtime,那不是被测逻辑的问题,是测试自己的时间分辨率。
func rewrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("重写 features.json: %v", err)
	}
	future := time.Now().Add(time.Second)
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatalf("推进 mtime: %v", err)
	}
}

func TestLyricSourcesReloadWithoutRestart(t *testing.T) {
	path := withFeaturesFile(t, `{"lyrics_sources":["netease","qq"]}`)

	if !lyricSourceEnabled("netease") || !lyricSourceEnabled("qq") {
		t.Fatalf("列表里的源该是开着的")
	}
	if lyricSourceEnabled("kugou") {
		t.Fatalf("没列出的源该是关着的")
	}

	// 用户在设置里勾上酷狗、取消 QQ —— 没有任何重启,下一次判定就该看到新集合。
	rewrite(t, path, `{"lyrics_sources":["netease","kugou"]}`)

	if !lyricSourceEnabled("kugou") {
		t.Errorf("新勾上的源没生效:热重读没发生(这正是它存在的理由)")
	}
	if lyricSourceEnabled("qq") {
		t.Errorf("取消勾选的源还开着:热重读没发生")
	}
}

func TestLyricSourcesFallBackToStartupSet(t *testing.T) {
	// 三种读不到的情况都必须退回启动时那份,而不是"空集合 = 全开"——后者会让用户
	// 刻意关掉的源悄悄复活。
	cases := []struct {
		name  string
		setup func(t *testing.T, path string)
	}{
		{"文件被删", func(t *testing.T, path string) {
			if err := os.Remove(path); err != nil {
				t.Fatalf("删文件: %v", err)
			}
		}},
		{"文件坏了", func(t *testing.T, path string) {
			rewrite(t, path, `{这不是 json`)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := withFeaturesFile(t, `{"lyrics_sources":["netease"]}`)
			featuresRef().LyricsSources = map[string]bool{"lrclib": true}
			if lyricSourceEnabled("lrclib") {
				t.Fatalf("前置条件:文件读得到时该按文件来")
			}
			tc.setup(t, path)
			if !lyricSourceEnabled("lrclib") {
				t.Errorf("读不到文件时该退回启动时那份,而不是别的")
			}
			if lyricSourceEnabled("kugou") {
				t.Errorf("读不到文件时退成了「全开」——用户关掉的源会悄悄复活")
			}
		})
	}

	t.Run("路径没登记", func(t *testing.T) {
		startup := features()
		t.Cleanup(func() { setFeatures(startup); setLyricSourcesPath("") })
		setLyricSourcesPath("")
		featuresRef().LyricsSources = map[string]bool{"lrclib": true}
		if !lyricSourceEnabled("lrclib") || lyricSourceEnabled("kugou") {
			t.Errorf("一次性 CLI 子命令(没登记路径)该直接用它自己加载的那份")
		}
	})
}

func TestLyricSourcesHotReadIgnoresMigrationFlags(t *testing.T) {
	// 只认 lyrics_sources:迁移标记缺失(老配置)也不补源 —— 补源是 App 加载设置时的事,补完写进列表。
	withFeaturesFile(t, `{"lyrics_sources":["netease"]}`)
	for _, s := range []string{"amll", "lyricfind", "kuwo", "migu", "deezer", "applemusic", "soda"} {
		if lyricSourceEnabled(s) {
			t.Errorf("%s 没列在 lyrics_sources 里就是关的,不按迁移标记补", s)
		}
	}
	if !lyricSourceEnabled("netease") {
		t.Errorf("列出的源该是开着的")
	}
}
