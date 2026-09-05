package main

import "testing"

// 2026-08-05 用户反馈坐实的真实 bug 的回归测试:「打开 Music 时顺带启动 Lyrimuse」在
// Lyrimuse 已经在跑的情况下仍然去 `open`,而那不是空操作 —— 会让设置窗口自己弹出来,
// 甚至起出第二个 App 实例。详见 shouldCompanionLaunch 的注释。
func TestShouldCompanionLaunch(t *testing.T) {
	cases := []struct {
		label       string
		justStarted string
		enabled     bool
		running     bool
		want        bool
		wantChecked bool // 是否应该真的去查"Lyrimuse 在不在跑"(短路语义)
	}{
		{"播放器刚启动+开关开+Lyrimuse没跑 → 启动", "Music", true, false, true, true},
		{"Lyrimuse 已在跑 → 跳过(本次修复的核心)", "Music", true, true, false, true},
		{"没有播放器发生启动跳变 → 跳过", "", true, false, false, false},
		{"开关关着 → 跳过", "Music", false, false, false, false},
		{"开关关着且已在跑 → 跳过", "Music", false, true, false, false},
		{"手动选定的其它播放器同样适用", "QQMusic", true, false, true, true},
	}
	for _, c := range cases {
		checked := false
		got := shouldCompanionLaunch(c.justStarted, c.enabled, func() bool {
			checked = true
			return c.running
		})
		if got != c.want {
			t.Errorf("%s: shouldCompanionLaunch(%q, %v, →%v) = %v, want %v",
				c.label, c.justStarted, c.enabled, c.running, got, c.want)
		}
		// 短路很重要:前两个条件绝大多数轮次就否决了,不该每秒白 fork 一次 pgrep
		if checked != c.wantChecked {
			t.Errorf("%s: 是否查询运行状态 = %v, want %v(短路语义)", c.label, checked, c.wantChecked)
		}
	}
}

// 2026-08-22 加的回归测试:酷狗当初接进 collector 时(system.go / features.go 都补了
// playerKugou)漏了 companionLaunch 这一路 —— playerProcessName() 的 switch 没有 kugou
// 分支,落进 `default: return "Music"`,于是**选了酷狗的用户,这个联动实际在盯 Music.app**:
// 打开酷狗不会唤起 Lyrimuse,反倒是打开 Apple Music 会。knownPlayerProcessNames 同样漏了
// 它,连"自动识别"档也盖不住。
//
// 这条测试钉的是"每个受支持的播放器都必须有自己的进程名,而且不能悄悄退化成 Music" ——
// 以后再加播放器时漏接同一处会当场失败。
func TestPlayerProcessNameCoversEveryPlayer(t *testing.T) {
	saved := features.Players
	t.Cleanup(func() { features.Players = saved })

	cases := []struct{ player, want string }{
		{playerAppleMusic, "Music"},
		{playerQQMusic, "QQMusic"},
		{playerNetease, "NeteaseMusic"},
		{playerSpotify, "Spotify"},
		// 可执行文件名是中文:/Applications/酷狗音乐.app 的 CFBundleExecutable 就是这个
		// (PlistBuddy 实测)。UTF-8 下 12 字节,没超过内核 p_comm 的 16 字节上限,
		// `pgrep -x` 能精确匹配(2026-08-22 拿中文名进程实测过)。
		{playerKugou, "酷狗音乐"},
	}
	for _, c := range cases {
		if got := playerProcessNameFor(c.player); got != c.want {
			t.Errorf("playerProcessNameFor(%s) = %q, want %q", c.player, got, c.want)
		}
	}

	// 多选年代同一个道理:选中集合里每个成员各自的进程名都要出现在
	// companionLaunchProcessNames() 的结果里,不能只盯着某一个。
	features.Players = map[string]bool{playerQQMusic: true, playerKugou: true}
	multi := companionLaunchProcessNames()
	for _, want := range []string{"QQMusic", "酷狗音乐"} {
		found := false
		for _, name := range multi {
			if name == want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("多选 {qq, kugou} 时 companionLaunchProcessNames() 缺 %q: %v", want, multi)
		}
	}
	if len(multi) != 2 {
		t.Errorf("多选 {qq, kugou} 时应恰好盯 2 个进程名, got %v", multi)
	}

	// 手动选定的每一个播放器,它的进程名都必须在"自动识别"那份列表里 —— 否则
	// playerAuto 档会盖不住某个明明支持的播放器(酷狗当初就是这么漏的)。
	features.Players = map[string]bool{playerAuto: true}
	auto := companionLaunchProcessNames()
	for _, c := range cases {
		found := false
		for _, name := range auto {
			if name == c.want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("knownPlayerProcessNames 缺 %q(%s),playerAuto 档会漏掉这个播放器", c.want, c.player)
		}
	}

	// 自动识别跟具体播放器一起勾选时,auto 是超集,按 auto 的全量列表处理——不能因为
	// 同时也勾了 QQ 音乐就退化成只盯 QQMusic 一个,那样反而丢了"自动检测本地新的
	// 播放器"这条 auto 本该有的能力。
	features.Players = map[string]bool{playerAuto: true, playerQQMusic: true}
	if got := companionLaunchProcessNames(); len(got) != len(knownPlayerProcessNames) {
		t.Errorf("auto+qq 组合应等同于纯 auto(全量列表), got %v", got)
	}
}

// 2026-09-03「跟随播放器启动」逐播放器勾选:勾选集合与候选(选中集合 / auto 全量)取交,键缺失退回旧语义。
func TestCompanionLaunchProcessNamesHonorsChosenPlayers(t *testing.T) {
	defer func() {
		features.Players = map[string]bool{playerAuto: true}
		features.LaunchLyrimuseOnPlayers = nil
	}()

	// 键缺失(老配置):跟布尔年代一样盯整个选中集合。
	features.Players = map[string]bool{playerQQMusic: true, playerKugou: true}
	features.LaunchLyrimuseOnPlayers = nil
	if got := companionLaunchProcessNames(); len(got) != 2 {
		t.Errorf("键缺失时应退回盯整个选中集合(2 个), got %v", got)
	}

	// 只勾了 QQ 音乐:只盯 QQMusic。
	features.LaunchLyrimuseOnPlayers = map[string]bool{playerQQMusic: true}
	if got := companionLaunchProcessNames(); len(got) != 1 || got[0] != "QQMusic" {
		t.Errorf("只勾 qq 时应只盯 QQMusic, got %v", got)
	}

	// 勾了但没选中的播放器不算(勾选记录保留,选回来自动恢复 —— 跟 Swift 侧 PlayerLinkage.effective 同一规则)。
	features.LaunchLyrimuseOnPlayers = map[string]bool{playerSpotify: true}
	if got := companionLaunchProcessNames(); len(got) != 0 {
		t.Errorf("勾了未选中的 spotify 不该盯任何进程, got %v", got)
	}

	// 空列表 = 明确关掉。
	features.LaunchLyrimuseOnPlayers = map[string]bool{}
	if got := companionLaunchProcessNames(); len(got) != 0 {
		t.Errorf("空列表应一个都不盯, got %v", got)
	}

	// 自动识别 + 勾了两个:候选是全量五个,勾的两个都在 → 盯两个。
	features.Players = map[string]bool{playerAuto: true}
	features.LaunchLyrimuseOnPlayers = map[string]bool{playerSpotify: true, playerAppleMusic: true}
	if got := companionLaunchProcessNames(); len(got) != 2 {
		t.Errorf("auto + 勾两个 应盯 2 个, got %v", got)
	}

	// 解析层:auto / 不认识的值被丢掉,nil 原样透传。
	if got := resolveLaunchLyrimuseOnPlayers([]string{playerAuto, "bogus", playerNetease}); len(got) != 1 || !got[playerNetease] {
		t.Errorf("resolveLaunchLyrimuseOnPlayers 应只留 netease, got %v", got)
	}
	if got := resolveLaunchLyrimuseOnPlayers(nil); got != nil {
		t.Errorf("nil 应原样透传(表示键缺失), got %v", got)
	}
}
