package main

import "testing"

// 真实故障(汽水音乐播放时「搜索歌词中…」永远转圈):getAutoDetectedState 的准入判断
// 曾经是一份**手抄**的 bundle id 列表(QQ / 网易云 / Spotify / 酷狗),players.json 后来
// 加进来的汽水音乐没人记得同步过去,于是汽水的播放落进 default 分支、又不在信任列表
// (内置播放器本来就不该出现在那儿),被当成"不相关 App"整条丢掉 —— collector 认为什么
// 都没在放、永远不去解析,而 App 侧照常显示曲目并挂着「搜索歌词中…」占位。
//
// 这组测试钉的不是"汽水能被认出来"这一条,而是**准入判断与 players.json 不许脱节**:
// 逐个遍历生成的 playerBundleIDs,任何一个内置播放器被 classifyAutoDetected 判成
// autoDetectReject 都失败。谁再手抄一份列表,下一个新增的播放器会立刻把它打回来。
func TestAutoDetectAdmitsEveryBuiltinPlayer(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	features.TrustedPlayers = map[string]string{} // 确保命中的是"内置"那一档,不是信任列表

	if len(playerBundleIDs) == 0 {
		t.Fatal("playerBundleIDs 是空的,generate 那步没跑?")
	}
	for player, bundleID := range playerBundleIDs {
		got := classifyAutoDetected(bundleID)
		if got == autoDetectReject {
			t.Errorf("内置播放器 %q(%s)被自动识别拒了 —— 准入判断又跟 players.json 脱节了",
				player, bundleID)
		}
		if player == playerAppleMusic {
			if got != autoDetectAppleMusic {
				t.Errorf("Apple Music 该走 refine 那一档,得到 %v", got)
			}
		} else if got != autoDetectBuiltin {
			t.Errorf("内置播放器 %q(%s)该判成 autoDetectBuiltin,得到 %v", player, bundleID, got)
		}
	}
}

// 汽水音乐单独点名 —— 它是这次故障的当事人,值得一条不依赖表遍历的直接断言。
func TestAutoDetectAdmitsSodaMusic(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	features.TrustedPlayers = map[string]string{}

	if got := classifyAutoDetected(sodaMusicBundleID); got != autoDetectBuiltin {
		t.Fatalf("汽水音乐(%s)该被自动识别当成内置播放器采纳,得到 %v", sodaMusicBundleID, got)
	}
}

// 信任列表那一档要判成 autoDetectTrusted(还得过"是不是一首歌"的守卫),不能跟内置混。
func TestAutoDetectClassifiesTrustedSeparately(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	features.TrustedPlayers = map[string]string{"com.google.Chrome": "Chrome"}

	if got := classifyAutoDetected("com.google.Chrome"); got != autoDetectTrusted {
		t.Errorf("被信任的浏览器该判成 autoDetectTrusted,得到 %v", got)
	}
}

// 反面:不在名单里、也没被信任过的 App 仍要被挡住 —— 准入放宽之后,这条保证它没有宽到
// "谁报 Now Playing 就认谁"。
func TestAutoDetectStillRejectsUnrelatedApps(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	features.TrustedPlayers = map[string]string{}

	for _, bundleID := range []string{"com.apple.QuickTimePlayerX", "com.google.Chrome", ""} {
		if got := classifyAutoDetected(bundleID); got != autoDetectReject {
			t.Errorf("%q 既不是内置播放器也没被信任过,该被拒,得到 %v", bundleID, got)
		}
	}
}
