package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// 2026-09-02 真实bug(用户在另一台机器装了 1.5.0 的 dmg,设置页报「App 1.5.0 ·
// 采集服务 1.4.0」):collector 的版本号长期是 main.go 里一个手写字面量,而 App 侧版本
// 一直从 git tag 自动派生——两个本该同源的值,一个自动一个手动,靠人在发版时记得改那
// 一行来同步。实测记录:v1.1.0 补同步、v1.2.0 补同步、**v1.3.0 漏**、v1.4.0 补上、
// **v1.5.0 又漏**。改成构建时 -ldflags 注入之后,这组测试负责守住注入链路不被悄悄
// 拆掉——注入失效是**静默**的,没有这些断言就只能等发版之后用户来报。
func TestClientVersionInjectionWiring(t *testing.T) {
	mainSrc, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("读 main.go: %v", err)
	}
	src := string(mainSrc)

	t.Run("clientVersion 必须是 var,不能是 const", func(t *testing.T) {
		// 这条是整组里最要紧的:Go 的 `-ldflags -X` 只能写 var,对 const **静默失败**
		// ——构建照样 exit 0、不报错不警告,而值原封不动(2026-09-02 实测坐实)。
		// 谁要是哪天顺手把它改回 const,两个 build.sh 里的注入会无声无息地失效,
		// 直接回到这次事故本身。
		if !regexp.MustCompile(`(?m)^var clientVersion\s*=`).MatchString(src) {
			t.Error("main.go 里找不到 `var clientVersion =` —— " +
				"-ldflags -X 只能注入 var,对 const 静默失效,注入链路会整条报废")
		}
		// const block 里不能再有它(改成 var 时如果漏删,编译期就会撞名,但万一
		// 有人把 var 挪进别的文件、const 留着,这里能兜住)。
		for _, line := range strings.Split(src, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "//") {
				continue
			}
			if regexp.MustCompile(`^clientVersion\s*=`).MatchString(trimmed) {
				t.Errorf("clientVersion 出现在 const block 里(%q)——必须是包级 var", trimmed)
			}
		}
	})

	t.Run("默认值必须是一眼假值,不能是具体版本号", func(t *testing.T) {
		// 默认值是给裸 `go build`/`go test` 用的兜底。刻意不写成某个具体版本号——
		// 那正是这次事故最坏的形态:一个看起来完全正常、实际早就过时的版本号,
		// 没有任何人会起疑。"dev" 一眼看出这不是发布构建。
		m := regexp.MustCompile(`(?m)^var clientVersion\s*=\s*"([^"]*)"`).FindStringSubmatch(src)
		if m == nil {
			t.Fatal("解析不出 clientVersion 的默认值")
		}
		if regexp.MustCompile(`^\d+\.\d+`).MatchString(m[1]) {
			t.Errorf("clientVersion 默认值是 %q,像个真版本号 —— "+
				"发布构建靠 -ldflags 注入,默认值该是 dev 这种一眼假的值,"+
				"否则注入一旦失效就会谎报一个看着正常的过时版本(v1.3.0/v1.5.0 两次事故都是这个形态)", m[1])
		}
	})

	// 每一条构建 collector 的路径都必须带注入。新增构建路径时忘了加注入,是这个
	// 机制最可能的下一个破绽——产物会静默退回默认值。
	for _, script := range []struct{ path, name string }{
		{"../lyrimuse/build.sh", "App 打包(CI 发版也走它)"},
		{"build.sh", "本地只重建 collector"},
	} {
		t.Run("构建脚本带注入: "+script.name, func(t *testing.T) {
			b, err := os.ReadFile(script.path)
			if err != nil {
				t.Fatalf("读 %s: %v", script.path, err)
			}
			if !strings.Contains(string(b), "-X main.clientVersion=") {
				t.Errorf("%s 里没有 `-X main.clientVersion=` —— "+
					"这条路径构建出的 collector 会自报默认值,跟 App 版本对不上", script.path)
			}
		})
	}

	t.Run("App 构建脚本有产物级版本一致性闸", func(t *testing.T) {
		// 注入本身不会在失败时报错(见上面 const 那条),所以必须有一道**验产物**的闸:
		// 跑一次打好的 collector 问它 version,跟 Info.plist 的版本比。
		b, err := os.ReadFile("../lyrimuse/build.sh")
		if err != nil {
			t.Fatalf("读 build.sh: %v", err)
		}
		if !strings.Contains(string(b), "版本一致性") {
			t.Error("lyrimuse/build.sh 里找不到版本一致性校验 —— " +
				"光有 -ldflags 注入不够,注入失效是静默的,必须有一道跑产物问版本的闸")
		}
	})
}
