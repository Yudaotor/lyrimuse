package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"
)

// 往浏览器里正在放 YouTube Music / Spotify 网页版的那个标签页注入一段 JS、拿回它的返回值。预解析读两家网页版的
// 播放队列用它(ytmusicqueue.go / spotifyweb.go)。
//
// JS 的返回值**绝不能含双引号**:`execute … javascript` 把 JS 返回的字符串再包一层 AppleScript 字符串时,会把里面
// 已有的双引号真的转义成反斜杠,整段被二次转义;JS 源码本身也不许有双引号(它要嵌进 AppleScript 的双引号字符串),
// 也不写反斜杠。要分隔字段就用竖线 / 控制字符拼裸文本。

const (
	ytmusicHostMarker = "music.youtube.com"
	// browserTabScriptTimeout:整个 osascript 子进程的硬超时。Arc 在「允许来自 Apple 事件的 JavaScript」关着时是
	// 挂起不返回(Chrome 则立刻抛错),脚本里的 `with timeout` 把挂起变成一个抓得住的错误,这里再兜最后一层。
	browserTabScriptTimeout = 6 * time.Second
	// browserTabScriptEventTimeout 是 AppleScript `with timeout of N seconds` 的 N。
	browserTabScriptEventTimeout = 4
)

// browserScriptFamily 回答"这个 bundle id 该用哪种 AppleScript 方言"。
//
// 写死的清单与 Swift 侧 BrowserAutomationPermission 保持一致(Chromium 系四家 + Safari);信任列表里的
// 其他浏览器现场读脚本定义判(trustedBrowserScriptFamily,口径同 Swift 侧 detectedFamily)。判不了的
// (Firefox 等没有提供脚本命令的)返回空串,调用方静默跳过。
func browserScriptFamily(bundleID string) string {
	switch bundleID {
	case "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser":
		return "chromium"
	case "com.apple.Safari":
		return "safari"
	default:
		// 用户自己加进信任列表的浏览器:现场读它的脚本定义判,见 browserfamily.go。
		return trustedBrowserScriptFamily(bundleID)
	}
}

// buildBrowserTabAppleScript:在 URL 含 host 的标签页里跑 js。
//   - 先看各窗口的当前标签,再遍历全部标签;JS 返回 `PAUSED:` 开头的读数先记下、接着找,找不到在放的才用它
//     (两个标签都开着同一家时认正在放的那个)。
//   - 每次执行都套 `with timeout`(把 Arc 那种挂起不返回变成抓得住的错误)+ 裸 `try…end try`(吞掉错误继续找下一个)。
//   - 一个都没有返回 NOTFOUND。
func buildBrowserTabAppleScript(bundleID, family, host, js string) string {
	var activeTab, executeActive, executeTab string
	switch family {
	case "chromium":
		activeTab = "active tab of window wi"
		executeActive = "execute (active tab of window wi) javascript \"" + js + "\""
		executeTab = "execute (tab ti of window wi) javascript \"" + js + "\""
	case "safari":
		activeTab = "current tab of window wi"
		executeActive = "do JavaScript \"" + js + "\" in current tab of window wi"
		executeTab = "do JavaScript \"" + js + "\" in tab ti of window wi"
	default:
		return ""
	}
	t := strconv.Itoa(browserTabScriptEventTimeout)
	return "tell application id \"" + bundleID + "\"\n" +
		"\tset winCount to count of windows\n" +
		"\tset fallback to \"\"\n" +
		"\trepeat with wi from 1 to winCount\n" +
		"\t\ttry\n" +
		"\t\t\tif (URL of " + activeTab + ") contains \"" + host + "\" then\n" +
		"\t\t\t\twith timeout of " + t + " seconds\n" +
		"\t\t\t\t\tset r to " + executeActive + "\n" +
		"\t\t\t\tend timeout\n" +
		"\t\t\t\tif r does not contain \"NOTFOUND\" then\n" +
		"\t\t\t\t\tif r starts with \"PAUSED:\" then\n" +
		"\t\t\t\t\t\tif fallback is \"\" then set fallback to text 8 thru -1 of r\n" +
		"\t\t\t\t\telse\n" +
		"\t\t\t\t\t\treturn r\n" +
		"\t\t\t\t\tend if\n" +
		"\t\t\t\tend if\n" +
		"\t\t\tend if\n" +
		"\t\tend try\n" +
		"\tend repeat\n" +
		"\trepeat with wi from 1 to winCount\n" +
		"\t\ttry\n" +
		"\t\t\tset tabCount to count of tabs of window wi\n" +
		"\t\ton error\n" +
		"\t\t\tset tabCount to 0\n" +
		"\t\tend try\n" +
		"\t\trepeat with ti from 1 to tabCount\n" +
		"\t\t\ttry\n" +
		"\t\t\t\tif (URL of tab ti of window wi) contains \"" + host + "\" then\n" +
		"\t\t\t\t\twith timeout of " + t + " seconds\n" +
		"\t\t\t\t\t\tset r to " + executeTab + "\n" +
		"\t\t\t\t\tend timeout\n" +
		"\t\t\t\t\tif r does not contain \"NOTFOUND\" then\n" +
		"\t\t\t\t\t\tif r starts with \"PAUSED:\" then\n" +
		"\t\t\t\t\t\t\tif fallback is \"\" then set fallback to text 8 thru -1 of r\n" +
		"\t\t\t\t\t\telse\n" +
		"\t\t\t\t\t\t\treturn r\n" +
		"\t\t\t\t\t\tend if\n" +
		"\t\t\t\t\tend if\n" +
		"\t\t\t\tend if\n" +
		"\t\t\tend try\n" +
		"\t\tend repeat\n" +
		"\tend repeat\n" +
		"\tif fallback is not \"\" then return fallback\n" +
		"\treturn \"NOTFOUND\"\n" +
		"end tell\n"
}

// runBrowserTabScript 在这个浏览器里找到 URL 含 host 的标签页、跑一段 JS,返回 osascript 的原始输出。
// 脚本写进临时文件再执行,不用 `osascript -e`(JS 里有单引号和逗号,再套一层 shell 引号会打坏 payload)。
// 任何失败(脚本拼不出、写不了临时文件、超时、浏览器不回)都是 ok=false。
func runBrowserTabScript(ctx context.Context, bundleID, family, host, js string) (string, bool) {
	script := buildBrowserTabAppleScript(bundleID, family, host, js)
	if script == "" {
		return "", false
	}
	f, err := os.CreateTemp("", "lyrimuse-browser-tab-*.applescript")
	if err != nil {
		return "", false
	}
	path := f.Name()
	defer os.Remove(path)
	if _, err := f.WriteString(script); err != nil {
		f.Close()
		return "", false
	}
	if err := f.Close(); err != nil {
		return "", false
	}

	ctx, cancel := context.WithTimeout(ctx, browserTabScriptTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", filepath.Clean(path)).Output()
	if err != nil {
		return "", false
	}
	return string(out), true
}
