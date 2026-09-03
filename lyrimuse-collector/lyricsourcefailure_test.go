package main

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// 两侧同步的**源码级**守卫(2026-09-03 加)。
//
// lyricsourcefailure.go 和 LyricSourceFailureReason.swift 的头注都在喊「两侧必须同步维护,
// 漏了的后果是界面显示一串谁都看不懂的代码本身」—— 可这件事此前**一条自动检查都没有**,
// 全靠改的人自己记得。加第四个代码(musixmatch_direct_blocked)时正好把这个洞补上:一边
// 加了、另一边忘了,在这里当场红,而不是等用户在设置页看到 `musixmatch_direct_blocked`
// 这么一串东西才发现。
//
// 用源码扫描而不是"跨语言共享一份枚举":Swift 侧那个 switch 本来就是手写的翻译表,没有
// 可导出的运行时结构;而这两份清单都是纯字面量常量,正则抓得准、也不会因为重构漂掉
// (真漂了就是 0 个匹配,下面的空集断言会红)。同款做法见 safariproxy_test.go 的源码级守卫。
const swiftFailureReasonPath = "../lyrimuse/Sources/lyrimuse/LyricSourceFailureReason.swift"

func TestLyricSourceFailureCodesMatchSwiftSide(t *testing.T) {
	goSrc, err := os.ReadFile("lyricsourcefailure.go")
	if err != nil {
		t.Fatal(err)
	}
	swiftSrc, err := os.ReadFile(swiftFailureReasonPath)
	if err != nil {
		t.Fatalf("读不到 Swift 侧(%s): %v —— 文件挪了就把这里的路径一起改掉,别把守卫删掉", swiftFailureReasonPath, err)
	}

	// Go 侧:lyricFailureReasonXxx / lyricTestReasonXxx = "code"
	goCodes := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?m)^\s*lyric(?:Failure|Test)Reason\w+\s*=\s*"([a-z0-9_]+)"`).
		FindAllStringSubmatch(string(goSrc), -1) {
		goCodes[m[1]] = true
	}
	// Swift 侧:switch 里的 case "code":
	swiftCodes := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?m)^\s*case "([a-z0-9_]+)":`).
		FindAllStringSubmatch(string(swiftSrc), -1) {
		swiftCodes[m[1]] = true
	}

	if len(goCodes) == 0 || len(swiftCodes) == 0 {
		t.Fatalf("正则一个都没抓到(go=%d swift=%d)—— 常量/switch 的写法变了,先修这个测试,别当没事", len(goCodes), len(swiftCodes))
	}
	if missing := diffCodes(goCodes, swiftCodes); len(missing) > 0 {
		t.Errorf("collector 有、Swift 侧 switch 没有:%v\n界面会原样显示这串代码本身。补 %s 的 case。",
			missing, swiftFailureReasonPath)
	}
	if extra := diffCodes(swiftCodes, goCodes); len(extra) > 0 {
		t.Errorf("Swift 侧有、collector 已经不再产出:%v\n要么是 collector 那边删漏了,要么是死代码。", extra)
	}
}

// 这次新加的那个必须在两边都在 —— 上面的集合比较对"两边一起漏了"是无感的。
func TestMusixmatchDirectBlockedCodeIsWiredOnBothSides(t *testing.T) {
	if lyricFailureReasonMusixmatchDirectBlocked != "musixmatch_direct_blocked" {
		t.Fatalf("代码串变了:%q", lyricFailureReasonMusixmatchDirectBlocked)
	}
	swiftSrc, err := os.ReadFile(swiftFailureReasonPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(swiftSrc), `case "musixmatch_direct_blocked":`) {
		t.Error("Swift 侧没有 musixmatch_direct_blocked 的 case")
	}
	// 它必须真的接在 musixmatch 的 HTTP client 上,否则永远不会被设置 —— 光有常量和翻译
	// 是"看起来做了"。
	mm, err := os.ReadFile("musixmatch.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(mm), "lyricFailureReasonMusixmatchDirectBlocked") {
		t.Error("musixmatch.go 没有把这个代码接到 dohHTTPClient 的 onBlocked 上")
	}
}

// 光有 case 不算数 —— case 里真的 return 了一句 L10n.t(...) 才算。
//
// 为什么这条也放在 Go 侧:lyrimuse-selftest 只依赖 LyrimuseCore,而 LyricSourceFailureReason
// 在 app target 里,那边**拿不到这个类型**、做不了运行时断言。所以两侧同步这件事的全部
// 自动检查都集中在这个文件,别指望 Swift selftest 那边还有一层。
func TestSwiftFailureReasonCasesActuallyTranslate(t *testing.T) {
	raw, err := os.ReadFile(swiftFailureReasonPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(raw), "\n")
	caseRe := regexp.MustCompile(`^\s*case "([a-z0-9_]+)":`)
	checked := 0
	for i, line := range lines {
		m := caseRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		checked++
		// 允许 case 和 return 之间夹注释(现有的两条都夹了)。
		found := false
		for j := i + 1; j < len(lines) && j <= i+12; j++ {
			next := strings.TrimSpace(lines[j])
			if next == "" || strings.HasPrefix(next, "//") {
				continue
			}
			found = strings.HasPrefix(next, "return L10n.t(")
			break
		}
		if !found {
			t.Errorf("case %q 后面没有紧跟 return L10n.t(...) —— 要么忘了翻译,要么绕开了 L10n(英文界面会显示中文)", m[1])
		}
	}
	if checked == 0 {
		t.Fatal("一个 case 都没扫到 —— 正则失效,这个守卫已经形同虚设")
	}
}

func diffCodes(a, b map[string]bool) []string {
	var out []string
	for k := range a {
		if !b[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}
