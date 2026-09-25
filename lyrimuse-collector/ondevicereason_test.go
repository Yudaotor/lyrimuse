package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// 端上翻译 helper 的 reason 字符串是**跨进程、跨语言**的契约:Swift 侧
// (lyrimuse/Sources/lyrics-translate/main.swift)用 `emit(Output(reason: "..."))` 产出,
// Go 侧 onDeviceTranslate 用一个 switch 按字面量分派。两边各写各的字符串,编译器一个都
// 管不着。
//
// 对不上的后果不是崩溃,是**静默降级成噪音**:一个本该被认成"这台机器走不了端上翻译"
// (errOnDeviceUnavailable,安静退回网络)的 reason 掉进 default,就会变成 error、每首歌
// 刷一行日志。macOS 14 用户会一直看到它,而开发机上永远复现不了 —— 本机跑的是另一条分支。
//
// 这道守卫只钉一个方向:**Go 侧认的每个字面量,Swift 侧必须真的会产出**。反方向不钉 ——
// Swift 侧新增的 reason 掉进 default 是合理的(timeout / count-mismatch 那类确实是错误,
// 就该记一笔)。
func TestOnDeviceReasonContractMatchesHelperSource(t *testing.T) {
	const helperPath = "../lyrimuse/Sources/lyrics-translate/main.swift"

	helper, err := os.ReadFile(helperPath)
	if err != nil {
		// 只 checkout 了 collector 的场景不该红,但要说清楚这道守卫没跑。
		t.Skipf("读不到 helper 源码(%s),跳过契约核对: %v", helperPath, err)
	}
	helperSrc := string(helper)

	goSrc, err := os.ReadFile("translate.go")
	if err != nil {
		t.Fatalf("读 translate.go 失败: %v", err)
	}

	// 抽 onDeviceTranslate 里那两个 case 行上的字面量。
	caseRe := regexp.MustCompile(`(?m)^\s*case (\"[^\n]*?)\:\s*$`)
	litRe := regexp.MustCompile(`"([a-zA-Z0-9\-]+)"`)

	// 只看 onDeviceTranslate 函数体,别把整份文件里别的 switch 也扫进来。
	start := strings.Index(string(goSrc), "func onDeviceTranslate(")
	if start < 0 {
		t.Fatal("translate.go 里找不到 onDeviceTranslate —— 函数改名了就把这道守卫一起更新")
	}
	body := string(goSrc)[start:]
	if end := strings.Index(body, "\n// appleLangCode"); end > 0 {
		body = body[:end]
	}

	var reasons []string
	for _, m := range caseRe.FindAllStringSubmatch(body, -1) {
		for _, lit := range litRe.FindAllStringSubmatch(m[1], -1) {
			reasons = append(reasons, lit[1])
		}
	}
	if len(reasons) == 0 {
		t.Fatal("没从 onDeviceTranslate 里抽到任何 reason 字面量 —— 抽取正则该更新了")
	}

	// helper 用 `status` 直接插值出来的那几个(supported/notSupported/unsupported)是
	// LanguageAvailability.Status 的取值,不是源码里的字面量,单独放行。
	fromStatusEnum := map[string]bool{
		"supported": true, "notSupported": true, "unsupported": true, "installed": true,
	}

	for _, reason := range reasons {
		if fromStatusEnum[reason] {
			continue
		}
		if !strings.Contains(helperSrc, `"`+reason+`"`) {
			t.Errorf("Go 侧认的 reason %q 在 helper 源码里找不到 —— "+
				"两边对不上会让这个分支永远走不到,对应的失败被当成 error 每首歌刷日志。"+
				"改了 %s 里的字面量就要同步改 translate.go 的 switch", reason, helperPath)
		}
	}
}
