package main

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// 信任列表里、但不在 browserScriptFamily 写死名单里的浏览器(用户在设置里「从应用程序中选择…」加进来的
// Vivaldi / Opera / Chromium / 各种 Beta 通道等),现场读它 App 包里的脚本定义判引擎族。
//
// 判据与 App 侧 BrowserAutomationPermission.detectedFamily 一致,两边必须同步改:Info.plist 的
// OSAScriptingDefinition 给出 sdef 文件名(只取文件名,不许借 `../` 读到 bundle 外),sdef 里有
// Chromium 的「execute javascript」四字码 CrSuExJa 就是 chromium,有 Safari 的「do JavaScript」
// 四字码 sfridojs 就是 safari,都没有就判不了。认四字码不认命令名:显示名会随本地化变。
//
// 只对信任列表里的 bundle 做:这条路要起子进程读别人的 bundle,不能对任意报上来的 bundle id 都跑一遍。
// 结果(含判不了)按 bundle id 缓存到进程结束,换装同 bundle id 的另一个版本要重启 collector 才认。

const (
	chromiumScriptCommandCode = "CrSuExJa"
	safariScriptCommandCode   = "sfridojs"
	browserFamilyProbeTimeout = 3 * time.Second
)

var bundleIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.\-_]*$`)

var (
	browserFamilyMu    sync.Mutex
	browserFamilyCache = map[string]string{}
)

// detectBrowserScriptFamily 现场判一个已安装 App 的引擎族,判不了返回 ""。单测换成假的(TestMain 默认
// 恒为 ""):测试进程不能去读本机真实的 App。
var detectBrowserScriptFamily = func(bundleID string) string {
	app := appPathForBundleID(bundleID)
	if app == "" {
		return ""
	}
	return scriptFamilyForApp(app)
}

// trustedBrowserScriptFamily 是 browserScriptFamily 写死名单之外的那一步。
func trustedBrowserScriptFamily(bundleID string) string {
	if _, trusted := features().TrustedPlayers[bundleID]; !trusted {
		return ""
	}
	browserFamilyMu.Lock()
	if fam, ok := browserFamilyCache[bundleID]; ok {
		browserFamilyMu.Unlock()
		return fam
	}
	browserFamilyMu.Unlock()
	fam := detectBrowserScriptFamily(bundleID)
	browserFamilyMu.Lock()
	browserFamilyCache[bundleID] = fam
	browserFamilyMu.Unlock()
	if fam != "" {
		log.Printf("browser family: trusted %s drives as %s (from its scripting definition)", bundleID, fam)
	} else {
		log.Printf("browser family: trusted %s has no JavaScript scripting command, web-page probes skip it", bundleID)
	}
	return fam
}

// scriptFamilyForApp 读 appPath(某个 .app)的脚本定义判引擎族。纯文件读取加一次 plutil,可单测。
func scriptFamilyForApp(appPath string) string {
	ctx, cancel := context.WithTimeout(context.Background(), browserFamilyProbeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-extract", "OSAScriptingDefinition", "raw", "-o", "-",
		filepath.Join(appPath, "Contents", "Info.plist")).Output()
	if err != nil {
		return ""
	}
	name := filepath.Base(strings.TrimSpace(string(out)))
	if name == "" || name == "." || name == string(filepath.Separator) {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(appPath, "Contents", "Resources", name))
	if err != nil {
		return ""
	}
	text := string(data)
	switch {
	case strings.Contains(text, chromiumScriptCommandCode):
		return "chromium"
	case strings.Contains(text, safariScriptCommandCode):
		return "safari"
	}
	return ""
}

// appPathForBundleID 找这个 bundle id 装在哪:先问 Spotlight,问不到再扫 /Applications 和
// ~/Applications 顶层。候选都要用 plutil 核对 CFBundleIdentifier 逐字相等才认。
func appPathForBundleID(bundleID string) string {
	if !bundleIDPattern.MatchString(bundleID) {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), browserFamilyProbeTimeout)
	defer cancel()
	var candidates []string
	if out, err := exec.CommandContext(ctx, "/usr/bin/mdfind", "kMDItemCFBundleIdentifier == '"+bundleID+"'").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if p := strings.TrimSpace(line); strings.HasSuffix(p, ".app") {
				candidates = append(candidates, p)
			}
		}
	}
	dirs := []string{"/Applications"}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, "Applications"))
	}
	for _, d := range dirs {
		matches, _ := filepath.Glob(filepath.Join(d, "*.app"))
		candidates = append(candidates, matches...)
	}
	for _, app := range candidates {
		out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-",
			filepath.Join(app, "Contents", "Info.plist")).Output()
		if err == nil && strings.TrimSpace(string(out)) == bundleID {
			return app
		}
	}
	return ""
}
