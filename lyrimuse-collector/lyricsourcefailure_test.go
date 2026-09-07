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

// 2026-09-06 的三个传输层代码同理:常量、分类函数、searchcli 的消费点三处都得在,少一处就是
// "看起来做了"——分类函数没人调,弹窗永远不会看到 dns_failed。
func TestTransportFailureCodesAreWired(t *testing.T) {
	for _, c := range []struct{ got, want string }{
		{lyricFailureReasonDNSFailed, "dns_failed"},
		{lyricFailureReasonConnectFailed, "connect_failed"},
		{lyricFailureReasonServerError, "server_error"},
		{lyricFailureReasonUpstreamUnreachable, "upstream_unreachable"},
	} {
		if c.got != c.want {
			t.Errorf("代码串变了:%q(应为 %q)", c.got, c.want)
		}
	}
	cli, err := os.ReadFile("searchcli.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cli), "lyricSourceBreakerShared.transportFailureCodes()") {
		t.Error("searchcli.go 的 lyricSourceFailureReasons 没有消费 transportFailureCodes —— 三个代码永远报不出去")
	}
	// 分类必须挂在 observe 上(doHTTPTracked 唯一的失败观察入口),不能是另开的旁路。
	br, err := os.ReadFile("sourcebreaker.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(br), "b.noteTransport(source, err, status, tr)") {
		t.Error("sourcebreaker.go 的 observeWith 没有调 noteTransport")
	}
	// DNS 轨迹必须真的从 doHTTPTracked 挂上并送进 observeTraced,否则"Client.Timeout 掐断的 DNS 挂住"
	// 这一类永远归成 connect_failed(见 sourcebreaker.go 最后一节 ⚠️ 段)。
	obs, err := os.ReadFile("networkobs.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, needle := range []string{"httptrace.WithClientTrace(", "DNSStart:", "DNSDone:", ".observeTraced("} {
		if !strings.Contains(string(obs), needle) {
			t.Errorf("networkobs.go 缺 %q —— DNS 轨迹没接上", needle)
		}
	}
	// amll 的缺 ID 标记必须真的在 amllLyric 里置位。
	am, err := os.ReadFile("amllttml.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(am), "amllSkippedForMissingIDs.Store(true)") {
		t.Error("amllttml.go 没有在两个 ID 都为空时置位 amllSkippedForMissingIDs")
	}
}

// lyricSourceFailureReasonsWith 的合成规则(2026-09-06 评审补的行为测试,之前只有字符串 grep):
// 给过候选的不报;未启用的不报;具体代码优先、传输层只填空;amll 只在"缺 ID 跳过 + 网易云和 QQ
// 都带传输层代码"时派生 upstream_unreachable。lyricfind 的具体代码走进程级旁路
// (ytmusicSetLastFailureReason),测试里设一次、结束时清掉。
func TestLyricSourceFailureReasonsWith(t *testing.T) {
	// 三个源特有旁路都是进程级变量,同一个测试二进制里别的测试可能已经设过(实测:全套跑时
	// musixmatch 那份带着 musixmatch_direct_blocked 进来)。进来先存、清,出去还原。
	savedYT, savedMM, savedNE := ytmusicLastFailureReasonNow(), musixmatchLastFailureReasonNow(), neteaseLastFailureReasonNow()
	t.Cleanup(func() {
		ytmusicSetLastFailureReason(savedYT)
		musixmatchSetLastFailureReason(savedMM)
		neteaseSetLastFailureReason(savedNE)
	})
	musixmatchSetLastFailureReason("")
	neteaseSetLastFailureReason("")
	ytmusicSetLastFailureReason(lyricFailureReasonLyricFindRegionRestricted)
	results := []scoredLyricCandidateResult{
		{Source: "musixmatch", Score: 300},
		{Source: "kuwo", Score: -1}, // 给过候选(哪怕被判废)就算应答
	}
	transport := map[string]string{
		"netease":   lyricFailureReasonDNSFailed,
		"qq":        lyricFailureReasonDNSFailed,
		"kugou":     lyricFailureReasonConnectFailed,
		"lrclib":    lyricFailureReasonServerError,
		"kuwo":      lyricFailureReasonDNSFailed,     // 但它给过候选 → 不报
		"migu":      lyricFailureReasonDNSFailed,     // 但用户关了 → 不报
		"lyricfind": lyricFailureReasonConnectFailed, // 有具体代码(地区限制)→ 传输层不覆盖
	}
	enabled := func(s string) bool { return s != "migu" }
	got := lyricSourceFailureReasonsWith(results, transport, enabled, true)
	want := map[string]string{
		"netease":   lyricFailureReasonDNSFailed,
		"qq":        lyricFailureReasonDNSFailed,
		"kugou":     lyricFailureReasonConnectFailed,
		"lrclib":    lyricFailureReasonServerError,
		"lyricfind": lyricFailureReasonLyricFindRegionRestricted,
		"amll":      lyricFailureReasonUpstreamUnreachable,
	}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for s, code := range want {
		if got[s] != code {
			t.Errorf("%s: got %q want %q", s, got[s], code)
		}
	}

	// amll 的三个否定分支:只有一边死 / 没有缺 ID 标记 / amll 自己给过候选 → 都不派生。
	oneSide := map[string]string{"netease": lyricFailureReasonDNSFailed}
	if r := lyricSourceFailureReasonsWith(nil, oneSide, enabled, true); r["amll"] != "" {
		t.Errorf("只有网易云死、QQ 正常:amll 缺 ID 是上游没这首,不该报 upstream_unreachable,得到 %q", r["amll"])
	}
	both := map[string]string{"netease": lyricFailureReasonDNSFailed, "qq": lyricFailureReasonConnectFailed}
	if r := lyricSourceFailureReasonsWith(nil, both, enabled, false); r["amll"] != "" {
		t.Errorf("amll 没有缺 ID 跳过(比如它自己发了请求)时不该派生,得到 %q", r["amll"])
	}
	amllAnswered := []scoredLyricCandidateResult{{Source: "amll", Score: 900}}
	if r := lyricSourceFailureReasonsWith(amllAnswered, both, enabled, true); r["amll"] != "" {
		t.Errorf("amll 给过候选就不该报任何代码,得到 %q", r["amll"])
	}
	// amll 被关掉 → 不报;网易云 / QQ 的启用状态本身不进判据 —— 只看它们有没有传输层记录
	// (关掉的源不发请求、通常没有记录,那时自然不派生;这里给了记录就得派生)。
	amllOff := func(s string) bool { return s != "amll" }
	if r := lyricSourceFailureReasonsWith(nil, both, amllOff, true); r["amll"] != "" {
		t.Errorf("amll 关掉了不该报,得到 %q", r["amll"])
	}
	upstreamOff := func(s string) bool { return s != "netease" && s != "qq" }
	if r := lyricSourceFailureReasonsWith(nil, both, upstreamOff, true); r["amll"] != lyricFailureReasonUpstreamUnreachable {
		t.Errorf("网易云 / QQ 关掉但都连不上,amll 仍该报 upstream_unreachable,得到 %q", r["amll"])
	}
	if r := lyricSourceFailureReasonsWith(nil, both, upstreamOff, true); r["netease"] != "" || r["qq"] != "" {
		t.Errorf("关掉的源不该出现:%v", r)
	}
	ytmusicSetLastFailureReason("")
	if r := lyricSourceFailureReasonsWith(nil, nil, enabled, false); r != nil {
		t.Errorf("什么都没有时应返回 nil,得到 %v", r)
	}
}

// Swift 侧空状态的分组表(LyricsSearchSheet.transportFailureCodes)是这四个代码的第二份手抄 ——
// 评审指出 TestLyricSourceFailureCodesMatchSwiftSide 只扫 LyricSourceFailureReason.swift,漏了它。
// 少一个的后果是:那个代码的源不进「没连上」分组、被算进「其余 N 个源」,又是一次"连不上报成没收录"。
const swiftSearchSheetPath = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsSearchSheet.swift"

func TestSwiftSearchSheetTransportCodesMatchGo(t *testing.T) {
	src, err := os.ReadFile(swiftSearchSheetPath)
	if err != nil {
		t.Fatalf("读不到 %s: %v —— 文件挪了就改路径,别删守卫", swiftSearchSheetPath, err)
	}
	m := regexp.MustCompile(`transportFailureCodes\s*=\s*\[([^\]]*)\]`).FindStringSubmatch(string(src))
	if m == nil {
		t.Fatal("LyricsSearchSheet.swift 里没找到 `transportFailureCodes = [...]` 字面量 —— 写法变了先修这个测试")
	}
	swift := map[string]bool{}
	for _, q := range regexp.MustCompile(`"([a-z0-9_]+)"`).FindAllStringSubmatch(m[1], -1) {
		swift[q[1]] = true
	}
	goCodes := map[string]bool{}
	for _, c := range lyricSourceTransportFailureOrder {
		goCodes[c] = true
	}
	goCodes[lyricFailureReasonUpstreamUnreachable] = true // searchcli 派生的那一个,不在 breaker 的顺序表里
	if missing := diffCodes(goCodes, swift); len(missing) > 0 {
		t.Errorf("Go 有、Swift 空状态分组表没有:%v", missing)
	}
	if extra := diffCodes(swift, goCodes); len(extra) > 0 {
		t.Errorf("Swift 空状态分组表有、Go 不产出:%v", extra)
	}
	// 分组表里的每个代码在 transportFailureLine 的 switch 里都要有 case,否则落到 default 直接显示代码本身。
	for code := range swift {
		if !strings.Contains(string(src), `case "`+code+`":`) {
			t.Errorf("transportFailureLine 没有 case %q", code)
		}
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
