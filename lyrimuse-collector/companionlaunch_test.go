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
