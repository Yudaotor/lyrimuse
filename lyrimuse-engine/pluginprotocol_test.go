package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 插件协议一致性用例的自证:现在协议的两头都还没有真实现,这里守的是用例和夹具本身。
//   - 每个用例「假对假」演得通(两头都照脚本演、互相核对);
//   - 每个用例的脚本合协议(参考模型 ppCheckCase);
//   - 偏离脚本、违反协议的改动确实会红;
//   - 方法表、错误码表跟用例、跟协议文档互相对得上。

func TestPluginProtocolCasesPlayOutFakeAgainstFake(t *testing.T) {
	for _, c := range ppLoadCases(t) {
		t.Run(c.ID, func(t *testing.T) {
			t.Parallel()
			engineErr, hostErr, _ := ppRun(c, ppScripted{}, ppScripted{})
			if err := ppFirstCause(engineErr, hostErr); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPluginProtocolCasesFollowTheProtocol(t *testing.T) {
	cat := ppLoadCatalog(t)
	for _, c := range ppLoadCases(t) {
		for _, problem := range ppCheckCase(cat, c).problems {
			t.Errorf("%s: %s", c.ID, problem)
		}
	}
}

// ppUncoveredOnPurpose:没有用例的错误码和理由。
var ppUncoveredOnPurpose = map[string]string{
	"-32603": "内部错误没有能稳定触发的办法",
}

// 方法表里的每个方法都有用例在测收它的那一头;错误码表、插件错误码表里的每一项都有用例用到;用例里没有表外的东西。
func TestPluginProtocolCatalogIsCoveredByCases(t *testing.T) {
	cat := ppLoadCatalog(t)
	cases := ppLoadCases(t)
	receiverTested := map[string]bool{}
	codes := map[string]bool{}
	perCategory := map[string]int{}
	for _, c := range cases {
		perCategory[c.Category]++
		report := ppCheckCase(cat, c)
		for key := range report.methods {
			fields := strings.Fields(key)
			if len(fields) == 2 && c.subjectIncludes(ppPeer(fields[0])) {
				receiverTested[key] = true
			}
		}
		for code := range report.codes {
			codes[code] = true
		}
	}
	for _, m := range cat.Methods {
		senders := []string{m.From}
		if m.From == "both" {
			senders = []string{ppEngine, ppHost}
		}
		for _, from := range senders {
			if !receiverTested[from+" "+m.Name] {
				t.Errorf("方法 %s(%s 发)没有用例在测收它的那一头", m.Name, from)
			}
		}
	}
	want := map[string]bool{}
	for _, e := range cat.Errors {
		want[strconv.Itoa(e.Code)] = true
		for _, v := range e.Values {
			want[strconv.Itoa(e.Code)+"/"+v] = true
		}
	}
	for _, code := range append(slices.Clone(cat.PluginErrors.Load), cat.PluginErrors.Call...) {
		want["-32000/"+code] = true
	}
	for code := range want {
		if !codes[code] && ppUncoveredOnPurpose[code] == "" {
			t.Errorf("错误码 %s 没有任何用例用到", code)
		}
	}
	for code, why := range ppUncoveredOnPurpose {
		if codes[code] {
			t.Errorf("错误码 %s 已经有用例了,从 ppUncoveredOnPurpose 里去掉(原来的理由:%s)", code, why)
		}
	}
	for _, category := range ppCategories {
		if perCategory[category] == 0 {
			t.Errorf("分类 %s 一个用例都没有", category)
		}
	}
	t.Logf("用例 %d 个,按分类:%v", len(cases), perCategory)
}

// 片段、清单、夹具脚本没有闲置的:目录里的每个文件都被某个用例用到。
func TestPluginProtocolFixtureFilesAreAllUsed(t *testing.T) {
	used := map[string]bool{}
	titles := map[string]string{}
	for _, c := range ppLoadCases(t) {
		used[c.Fixture.Manifest] = true
		used[c.Fixture.Plugin] = true
		for _, name := range c.includes {
			used[name] = true
		}
		if other := titles[c.Title]; other != "" {
			t.Errorf("%s 和 %s 的 title 一样", c.ID, other)
		}
		titles[c.Title] = c.ID
	}
	for _, dir := range []string{"fragments", "manifests", "plugins"} {
		entries, err := os.ReadDir(filepath.Join(ppDir, dir))
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range entries {
			if name := dir + "/" + e.Name(); !used[name] {
				t.Errorf("%s 没有任何用例用到", name)
			}
		}
	}
}

func TestPluginProtocolPatterns(t *testing.T) {
	fx := &ppFixtureValues{manifest: map[string]any{"id": "org.example.x", "hosts": []any{"a.example"}}, source: "module.exports = {};"}
	obj := func(kv ...any) map[string]any {
		m := map[string]any{}
		for i := 0; i < len(kv); i += 2 {
			m[kv[i].(string)] = kv[i+1]
		}
		return m
	}
	op := func(name string, arg any) map[string]any { return obj(name, arg) }
	cases := []struct {
		name    string
		pattern any
		value   any
		absent  bool
		want    string // 空 = 匹配;否则是报错里要有的片段
	}{
		{"字面量相等", "a", "a", false, ""},
		{"字面量不等", "a", "b", false, "要 \"a\""},
		{"数字和同形的字符串不相等", 7.0, "7", false, "要 7"},
		{"null 只配 null", nil, nil, false, ""},
		{"null 不配缺字段", nil, nil, true, "缺这个字段"},
		{"对象允许多出字段", obj("a", 1.0), obj("a", 1.0, "b", 2.0), false, ""},
		{"对象里层也允许多出字段", obj("a", obj("x", true)), obj("a", obj("x", true, "y", 1.0)), false, ""},
		{"对象缺字段", obj("a", 1.0, "b", 2.0), obj("a", 1.0), false, "$.b: 缺这个字段"},
		{"数组要等长", []any{1.0}, []any{1.0, 2.0}, false, "要 1 个元素"},
		{"数组逐项比", []any{1.0, 2.0}, []any{2.0, 1.0}, false, "$[0]"},
		{"$any 类型对", obj("$any", "integer", "sample", 1.0), 42.0, false, ""},
		{"$any 整数不收小数", obj("$any", "integer", "sample", 1.0), 1.5, false, "要 integer"},
		{"$any 不收缺字段", obj("$any", "any", "sample", 1.0), nil, true, "缺这个字段"},
		{"$optional 可以没有", op("$optional", "GET"), nil, true, ""},
		{"$optional 有就要对", op("$optional", "GET"), "POST", false, "要 \"GET\""},
		{"$absent 没有才行", op("$absent", true), nil, true, ""},
		{"$absent 有就不行", op("$absent", true), "x", false, "不该有这个字段"},
		{"$exact 不许多出字段", op("$exact", obj("a", 1.0)), obj("a", 1.0, "b", 2.0), false, "多出字段 \"b\""},
		{"$exact 刚好", op("$exact", obj("a", 1.0)), obj("a", 1.0), false, ""},
		{"$unordered 顺序无关", op("$unordered", []any{"a", "b", "c"}), []any{"c", "a", "b"}, false, ""},
		{"$unordered 不许多", op("$unordered", []any{"a"}), []any{"a", "b"}, false, "要 1 个元素"},
		{"$unordered 一个元素不能配两个模式", op("$unordered", []any{"a", "a"}), []any{"a", "b"}, false, "没法各配上"},
		{"$unordered 要回溯才配得上", op("$unordered", []any{obj("$any", "any", "sample", 1.0), "a"}), []any{"a", "b"}, false, ""},
		{"$contains 允许多出元素", op("$contains", []any{"b"}), []any{"a", "b", "c"}, false, ""},
		{"$contains 少了不行", op("$contains", []any{"z"}), []any{"a", "b"}, false, "没法各配上"},
		{"$oneOf 配第二个", op("$oneOf", []any{-32800.0, -32801.0}), -32801.0, false, ""},
		{"$oneOf 都不配", op("$oneOf", []any{-32800.0, -32801.0}), -32603.0, false, "几个备选都不匹配"},
		{"$fixture manifest 按对象比、允许多出字段", op("$fixture", "manifest"), obj("id", "org.example.x", "hosts", []any{"a.example"}, "extra", 1.0), false, ""},
		{"$fixture manifest 不一样", op("$fixture", "manifest"), obj("id", "org.example.y", "hosts", []any{"a.example"}), false, "$.id"},
		{"$fixture source 只要是字符串", op("$fixture", "source"), "anything", false, ""},
		{"$fixture source 不是字符串", op("$fixture", "source"), 1.0, false, "要脚本全文"},
	}
	for _, c := range cases {
		if err := ppValidatePattern(c.pattern); err != nil {
			t.Errorf("%s: 模式本身不合规: %v", c.name, err)
			continue
		}
		err := ppMatch(c.pattern, c.value, !c.absent, ppVars{}, fx, "$")
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s: 该匹配,却报 %v", c.name, err)
		case c.want != "" && err == nil:
			t.Errorf("%s: 该不匹配,却过了", c.name)
		case c.want != "" && !strings.Contains(err.Error(), c.want):
			t.Errorf("%s: 报错 %q 里没有 %q", c.name, err, c.want)
		}
	}

	// 变量:第一次出现绑定,之后必须相等;匹配失败时不留下半截绑定。
	vars := ppVars{}
	idVar := obj("$var", "id", "sample", 1.0)
	if err := ppMatch(obj("id", idVar, "method", "a"), obj("id", "x9", "method", "b"), true, vars, fx, "$"); err == nil || len(vars) != 0 {
		t.Errorf("匹配失败不该绑定变量: err=%v vars=%v", err, vars)
	}
	if err := ppMatch(obj("id", idVar), obj("id", "x9"), true, vars, fx, "$"); err != nil || vars["id"] != "x9" {
		t.Errorf("变量没绑上: err=%v vars=%v", err, vars)
	}
	if err := ppMatch(obj("id", idVar), obj("id", 9.0), true, vars, fx, "$"); err == nil {
		t.Error("变量已绑成 \"x9\",收到 9 该不匹配")
	}
	if v, _, err := ppInstantiate(obj("id", idVar), vars, fx); err != nil || v.(map[string]any)["id"] != "x9" {
		t.Errorf("实例化要用绑定的值: %v %v", v, err)
	}
	if v, _, err := ppInstantiate(obj("id", idVar), ppVars{}, fx); err != nil || v.(map[string]any)["id"] != 1.0 {
		t.Errorf("没绑定时实例化用 sample: %v %v", v, err)
	}
	if _, _, err := ppInstantiate(obj("id", op("$var", "never")), ppVars{}, fx); err == nil {
		t.Error("没绑定又没有 sample 的变量该实例化不了")
	}

	// 实例化:$optional / $absent 不发,$oneOf 发第一个,$fixture 换成清单和脚本。
	sent, _, err := ppInstantiate(obj(
		"a", op("$optional", "x"), "b", op("$absent", true), "c", op("$oneOf", []any{"first", "second"}),
		"d", op("$exact", obj("k", obj("$any", "string", "sample", "s"))), "m", op("$fixture", "manifest"), "s", op("$fixture", "source"),
	), ppVars{}, fx)
	if err != nil {
		t.Fatal(err)
	}
	got := sent.(map[string]any)
	_, hasA := got["a"]
	_, hasB := got["b"]
	if hasA || hasB || got["c"] != "first" || got["d"].(map[string]any)["k"] != "s" || got["s"] != fx.source || got["m"].(map[string]any)["id"] != "org.example.x" {
		t.Errorf("实例化结果不对: %v", got)
	}

	// 写错的模式在加载时就报。
	for name, bad := range map[string]any{
		"不认识的运算符":          op("$regex", "x"),
		"两个运算符":            obj("$any", "string", "$optional", "x"),
		"运算符旁边多了键":         obj("$optional", "x", "sample", 1.0),
		"$any 没有 sample":   op("$any", "string"),
		"$any 的 sample 类型": obj("$any", "string", "sample", 1.0),
		"$any 不认识的类型":      obj("$any", "date", "sample", 1.0),
		"$var 没名字":         op("$var", ""),
		"$absent 写了 false": op("$absent", false),
		"$exact 里不是对象":     op("$exact", "x"),
		"$oneOf 是空的":       op("$oneOf", []any{}),
		"$fixture 不认识":     op("$fixture", "http"),
		"嵌在里层的也查":          obj("a", []any{op("$nope", 1.0)}),
	} {
		if ppValidatePattern(bad) == nil {
			t.Errorf("%s: 该报不合规", name)
		}
	}
}

// ppReloadCase 另读一份用例,给要改它的测试用(不动 ppLoadCases 读出来的那一份)。
func ppReloadCase(t *testing.T, id string) *ppCase {
	t.Helper()
	c, err := ppLoadCase(filepath.Join(ppDir, "cases", id+".json"))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// ppStepWhere 找出第 n 个(从 0 起)满足条件的步骤的下标。
func ppStepWhere(t *testing.T, c *ppCase, n int, cond func(*ppStep) bool) int {
	t.Helper()
	for i := range c.Steps {
		if cond(&c.Steps[i]) {
			if n == 0 {
				return i
			}
			n--
		}
	}
	t.Fatalf("%s 里没找到要改的那一步", c.ID)
	return -1
}

func ppIsResponseFrom(role string) func(*ppStep) bool {
	return func(s *ppStep) bool {
		msg, _ := s.pattern.(map[string]any)
		_, isCall := msg["method"]
		return s.From == role && msg != nil && !isCall
	}
}

func ppIsCallFrom(role, method string) func(*ppStep) bool {
	return func(s *ppStep) bool {
		msg, _ := s.pattern.(map[string]any)
		return s.From == role && msg != nil && msg["method"] == method
	}
}

// 一头偏离脚本,另一头照原脚本核对:该红的红,脚本允许的出入不红。
func TestPluginProtocolDeviationsAreCaught(t *testing.T) {
	deviations := []struct {
		name   string
		caseID string
		role   string // 偏离脚本的是哪一头
		mutate func(t *testing.T, c *ppCase)
		want   string // 另一头的报错里要有的片段;空 = 这种出入是允许的,不该红
	}{
		{"错误码不对", "cancel-in-flight-with-pending-fetch", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 2, ppIsResponseFrom(ppHost))
			c.Steps[i].pattern.(map[string]any)["error"].(map[string]any)["code"] = -32603.0
		}, "$.error.code"},
		{"应答少了必须有的字段", "lifecycle-handshake-ok", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, ppIsResponseFrom(ppHost))
			delete(c.Steps[i].pattern.(map[string]any)["result"].(map[string]any), "apiVersions")
		}, "$.result.apiVersions: 缺这个字段"},
		{"应答多了字段", "lifecycle-handshake-ok", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, ppIsResponseFrom(ppHost))
			c.Steps[i].pattern.(map[string]any)["result"].(map[string]any)["somethingNew"] = map[string]any{"x": 1.0}
		}, ""},
		{"应答的 id 换了类型", "concurrency-string-ids", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 1, ppIsResponseFrom(ppHost))
			c.Steps[i].pattern.(map[string]any)["id"] = 7.0
		}, "$.id"},
		{"对通知作了应答", "malformed-unknown-notification-host", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, func(s *ppStep) bool { return s.Raw != nil })
			reply := `{"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"no such method"}}`
			c.Steps = slices.Insert(c.Steps, i+1, ppStep{From: ppHost, Raw: &reply})
		}, "$.id"},
		{"两条通知的先后反了", "hostapi-heartbeat", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, ppIsCallFrom(ppHost, "$/heartbeat"))
			c.Steps[i], c.Steps[i+1] = c.Steps[i+1], c.Steps[i]
		}, "$.params.calls"},
		{"unordered 里换了先后", "concurrency-getlyrics-top3-out-of-order", ppHost, func(t *testing.T, c *ppCase) {
			for i := range c.Steps {
				if c.Steps[i].From == ppHost && c.Steps[i].Unordered != nil {
					slices.Reverse(c.Steps[i].Unordered)
				}
			}
		}, ""},
		{"该退出却接着发", "lifecycle-exit-without-shutdown", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, func(s *ppStep) bool { return s.Close })
			line := `{"jsonrpc":"2.0","method":"host/extra"}`
			c.Steps[i] = ppStep{From: ppHost, Raw: &line}
		}, "对端该关掉输出"},
		{"没应答就断开", "lyrics-inline-lines", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 2, ppIsResponseFrom(ppHost))
			c.Steps = append(c.Steps[:i:i], ppStep{From: ppHost, Close: true})
		}, "对端关了输出"},
		{"$exact 的结果里多了命名空间", "load-ok-search-only", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 1, ppIsResponseFrom(ppHost))
			exports := c.Steps[i].pattern.(map[string]any)["result"].(map[string]any)["exports"].(map[string]any)
			exports["$exact"].(map[string]any)["covers"] = []any{"get"}
		}, "多出字段 \"covers\""},
		{"没声明却给了 externalIds", "requery-external-ids-not-declared", ppEngine, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, ppIsCallFrom(ppEngine, "lyrics/search"))
			query := c.Steps[i].pattern.(map[string]any)["params"].(map[string]any)["query"].(map[string]any)
			query["externalIds"] = map[string]any{"appleMusic": "1440000001"}
		}, "$.params.query.externalIds: 不该有这个字段"},
		{"取消的是别的 id", "cancel-late-result", ppEngine, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, ppIsCallFrom(ppEngine, "$/cancelRequest"))
			c.Steps[i].pattern.(map[string]any)["params"].(map[string]any)["id"] = 4242.0
		}, "变量 s1"},
		{"超长行短了一个字节", "malformed-line-too-long-host", ppEngine, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, func(s *ppStep) bool { return s.RawFill != nil })
			fill := *c.Steps[i].RawFill
			fill.TotalBytes--
			c.Steps[i].RawFill = &fill
		}, "要原样的一行"},
		{"随时可以出现的通知不算偏离", "lyrics-inline-lines", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 2, ppIsResponseFrom(ppHost))
			beat := `{"jsonrpc":"2.0","method":"$/heartbeat","params":{"heapBytes":1,"calls":[]}}`
			c.Steps = slices.Insert(c.Steps, i, ppStep{From: ppHost, Raw: &beat})
		}, ""},
		{"用例说了不许有的通知就算偏离", "hostapi-heartbeat", ppHost, func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 2, ppIsResponseFrom(ppHost))
			note := `{"jsonrpc":"2.0","method":"host/log","params":{"level":"info","message":"x"}}`
			c.Steps = slices.Insert(c.Steps, i, ppStep{From: ppHost, Raw: &note})
		}, "$.id"},
	}
	for _, d := range deviations {
		t.Run(d.name, func(t *testing.T) {
			t.Parallel()
			original := ppReloadCase(t, d.caseID)
			deviant := ppReloadCase(t, d.caseID)
			d.mutate(t, deviant)
			actors := map[string]ppActor{ppEngine: ppScripted{}, ppHost: ppScripted{}}
			actors[d.role] = ppScripted{Steps: deviant.Steps}
			engineErr, hostErr, _ := ppRun(original, actors[ppEngine], actors[ppHost])
			verifierErr := engineErr
			if d.role == ppEngine {
				verifierErr = hostErr
			}
			switch {
			case d.want == "" && (engineErr != nil || hostErr != nil):
				t.Fatalf("这种出入是允许的,却红了: engine=%v host=%v", engineErr, hostErr)
			case d.want != "" && verifierErr == nil:
				t.Fatalf("核对的一头没发现偏离(engine=%v host=%v)", engineErr, hostErr)
			case d.want != "" && !strings.Contains(verifierErr.Error(), d.want):
				t.Fatalf("报错 %q 里没有 %q", verifierErr, d.want)
			}
		})
	}
}

// 两种要靠「等不到」「演完了还有」才看得出的偏离:少发一条(等到时限)、脚本演完之后又多发一行。
func TestPluginProtocolMissingAndTrailingLinesAreCaught(t *testing.T) {
	original := ppReloadCase(t, "concurrency-getlyrics-top3-out-of-order")
	deviant := ppReloadCase(t, original.ID)
	i := ppStepWhere(t, deviant, 1, func(s *ppStep) bool { return s.From == ppHost && s.Unordered != nil })
	deviant.Steps[i].Unordered = deviant.Steps[i].Unordered[:2]
	engineErr, _, _ := ppRunWithin(100*time.Millisecond, original, ppScripted{}, ppScripted{Steps: deviant.Steps}, &ppClock{})
	if engineErr == nil || !strings.Contains(engineErr.Error(), "等对端") {
		t.Errorf("unordered 里少发一条:引擎那一头该等到时限报不符,得到 %v", engineErr)
	}

	original = ppReloadCase(t, "lifecycle-handshake-ok")
	deviant = ppReloadCase(t, original.ID)
	last := len(original.Steps) - 1
	if !original.Steps[last].Close || original.Steps[last].From != ppHost {
		t.Fatal("这条测试假设用例的最后一步是 plugin-host 关掉输出")
	}
	original.Steps = original.Steps[:last]
	line := `{"jsonrpc":"2.0","method":"host/extra"}`
	deviant.Steps = slices.Insert(deviant.Steps, last, ppStep{From: ppHost, Raw: &line})
	engineErr, _, _ = ppRun(original, ppScripted{}, ppScripted{Steps: deviant.Steps})
	if engineErr == nil || !strings.Contains(engineErr.Error(), "脚本演完之后对端又发来一行") {
		t.Errorf("演完之后又多发一行:引擎那一头该报不符,得到 %v", engineErr)
	}
}

// 脚本本身违反协议时参考模型要报出来。
func TestPluginProtocolModelCatchesBrokenScripts(t *testing.T) {
	cat := ppLoadCatalog(t)
	setCode := func(n int, role string, code float64) func(t *testing.T, c *ppCase) {
		return func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, n, func(s *ppStep) bool {
				msg, _ := s.pattern.(map[string]any)
				_, isErr := msg["error"]
				return s.From == role && isErr
			})
			c.Steps[i].pattern.(map[string]any)["error"].(map[string]any)["code"] = code
		}
	}
	clearInvalid := func(t *testing.T, c *ppCase) {
		i := ppStepWhere(t, c, 0, func(s *ppStep) bool { return s.Invalid != "" })
		c.Steps[i].Invalid = ""
	}
	broken := []struct {
		name   string
		caseID string
		mutate func(t *testing.T, c *ppCase)
		want   string
	}{
		{"结论写错", "correction-empty-after-429", func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, func(s *ppStep) bool { return s.Observe != nil })
			o := *c.Steps[i].Observe
			o.Outcome.Status = "NOT_FOUND"
			c.Steps[i].Observe = &o
		}, "结论按协议是 RATE_LIMITED"},
		{"retryAfter 写错", "correction-empty-after-429", func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, func(s *ppStep) bool { return s.Observe != nil })
			o := *c.Steps[i].Observe
			seconds := 5
			o.Outcome.RetryAfter = &seconds
			c.Steps[i].Observe = &o
		}, "retryAfter 按协议是 30"},
		{"没被纠正却写成纠正过", "correction-empty-after-404", func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, func(s *ppStep) bool { return s.Observe != nil })
			o := *c.Steps[i].Observe
			yes := true
			o.Outcome.Corrected = &yes
			c.Steps[i].Observe = &o
		}, "有没有被宿主纠正"},
		{"调用没应答就应答了 shutdown", "lyrics-inline-lines", func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 2, ppIsResponseFrom(ppHost))
			c.Steps = slices.Delete(c.Steps, i, i+2)
		}, "shutdown 应答之前"},
		{"方法发反了方向", "lifecycle-handshake-ok", func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, ppIsCallFrom(ppEngine, "plugin/load"))
			c.Steps[i].pattern.(map[string]any)["method"] = "host/storage.keys"
		}, "不该由 engine 发"},
		{"通知带了 id", "cancel-unknown-id", func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, ppIsCallFrom(ppEngine, "$/cancelRequest"))
			c.Steps[i].pattern.(map[string]any)["id"] = 77.0
		}, "id 的有无对不上"},
		{"缺必填参数", "lyrics-inline-lines", func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, ppIsCallFrom(ppEngine, "lyrics/search"))
			delete(c.Steps[i].pattern.(map[string]any)["params"].(map[string]any), "query")
		}, "params 缺必填的 query"},
		{"状态不对却没被 -32806 拒绝", "lifecycle-call-before-load", setCode(0, ppHost, -32601), "应该被 -32806"},
		{"合法的请求被 -32806 拒绝", "errors-not-found", setCode(0, ppHost, -32806), "不该回 -32806"},
		{"表外的错误码", "errors-not-found", setCode(0, ppHost, -32099), "不在错误码表里"},
		{"-32000 用在 host/fetch 上", "fetch-denied-host", setCode(0, ppEngine, -32000), "-32000 只用来应答"},
		{"不合规的结果没标 invalid", "badresult-items-missing-engine", clearInvalid, "result 缺必填的 items"},
		{"不合规的歌词没标 invalid", "badresult-timeline-end-before-start-engine", clearInvalid, "结果不合规"},
		{"重复的在途 id 没标 invalid", "concurrency-duplicate-in-flight-id", clearInvalid, "还在途就又用了一次"},
		{"用已经结束的调用发请求没标 invalid", "fetch-after-call-finished", clearInvalid, "不是在途的调用"},
		{"表外的方法没标 invalid", "hostapi-unknown-host-method", clearInvalid, "不在方法表里"},
		{"假上游跟脚本对不上", "lyrics-search-404-empty", func(t *testing.T, c *ppCase) {
			c.Fixture.HTTP[0].Response.Status = 200
		}, "假上游"},
		{"假上游多了一条用不到的", "lyrics-inline-lines", func(t *testing.T, c *ppCase) {
			extra := c.Fixture.HTTP[0]
			extra.Request.URL = "https://lyrics.example/unused"
			c.Fixture.HTTP = append(c.Fixture.HTTP, extra)
		}, "没有任何 host/fetch 用到"},
		{"引擎答了上游才答得出的应答却没有假上游", "lyrics-inline-lines", func(t *testing.T, c *ppCase) {
			c.Fixture.HTTP = nil
		}, "fixture.http 里却没有这一条"},
		{"covers 写了用例里没有的方法", "lifecycle-handshake-ok", func(t *testing.T, c *ppCase) {
			c.Covers = append(c.Covers, "host/match")
		}, "covers 写了 host/match"},
		{"任务没有 drive", "lyrics-inline-lines", func(t *testing.T, c *ppCase) {
			c.Drive = slices.DeleteFunc(c.Drive, func(d map[string]any) bool { return d["do"] == "resolve" })
		}, "没有对应的 drive resolve"},
		{"只测 plugin-host 的用例写了 drive", "load-twice", func(t *testing.T, c *ppCase) {
			c.Drive = []map[string]any{{"before": "initialize", "do": "start"}}
		}, "不写 drive"},
		{"exit 之后还在发", "lifecycle-exit-without-shutdown", func(t *testing.T, c *ppCase) {
			i := ppStepWhere(t, c, 0, func(s *ppStep) bool { return s.Close })
			c.Steps = slices.Insert(c.Steps, i, c.Steps[ppStepWhere(t, c, 0, ppIsResponseFrom(ppHost))])
		}, "exit 之后 plugin-host 只能退出"},
		{"没有收尾", "lifecycle-handshake-ok", func(t *testing.T, c *ppCase) {
			c.Steps = c.Steps[:len(c.Steps)-2]
		}, "以一头关掉输出收尾"},
		{"取消了握手", "lifecycle-handshake-ok", func(t *testing.T, c *ppCase) {
			cancel := ppReloadCase(t, "cancel-unknown-id")
			note := cancel.Steps[ppStepWhere(t, cancel, 0, ppIsCallFrom(ppEngine, "$/cancelRequest"))]
			note.pattern.(map[string]any)["params"].(map[string]any)["id"] = map[string]any{"$var": "initId"}
			c.Steps = slices.Insert(c.Steps, 1, note)
		}, "initialize 不能取消"},
	}
	for _, b := range broken {
		c := ppReloadCase(t, b.caseID)
		if problems := ppCheckCase(cat, c).problems; len(problems) != 0 {
			t.Errorf("%s: 没改之前就有问题: %v", b.name, problems)
			continue
		}
		b.mutate(t, c)
		problems := ppCheckCase(cat, c).problems
		if !slices.ContainsFunc(problems, func(p string) bool { return strings.Contains(p, b.want) }) {
			t.Errorf("%s: 参考模型没报出 %q,报的是 %v", b.name, b.want, problems)
		}
	}
}

// Clock 那一步两头各走到一次,时钟只拨一次。
func TestPluginProtocolClockStepsAdvanceOnce(t *testing.T) {
	c := ppReloadCase(t, "cancel-grace-then-interrupt")
	engineErr, hostErr, clock := ppRun(c, ppScripted{}, ppScripted{})
	if err := ppFirstCause(engineErr, hostErr); err != nil {
		t.Fatal(err)
	}
	limit := time.Duration(ppLoadCatalog(t).Limits["cancelGraceMs"]) * time.Millisecond
	if clock.total() != limit {
		t.Fatalf("时钟走了 %v,用例里拨的是宽限 %v", clock.total(), limit)
	}
}

// ---- 拿用例测一个外部的 plugin-host ----

// ppProcessHost 把一个外部进程当 plugin-host 接到连接上:conn.in 是它的 stdin,conn.out 是它的 stdout。
// 用例要它握手时报的非默认上限(fixture.config.host)经环境变量 LYRIMUSE_PLUGIN_HOST_CONFIG(JSON 对象)交给它。
type ppProcessHost struct {
	argv []string
}

func (p ppProcessHost) Play(ctx context.Context, c *ppCase, role string, conn *ppConn, clock *ppClock) error {
	if role != ppHost {
		return fmt.Errorf("外部进程只能演 plugin-host")
	}
	config, err := json.Marshal(c.Fixture.Config[ppHost])
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, p.argv[0], p.argv[1:]...)
	cmd.Env = append(os.Environ(), "LYRIMUSE_PLUGIN_HOST_CONFIG="+string(config))
	cmd.Stdout = conn.out
	cmd.Stderr = os.Stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() {
		_, _ = io.Copy(stdin, conn.in)
		stdin.Close()
	}()
	err = cmd.Wait()
	conn.closeWrite()
	wantExit := -1
	for _, s := range c.Steps {
		if s.Close && s.From == ppHost && s.ExitCode != nil {
			wantExit = *s.ExitCode
		}
	}
	if got := cmd.ProcessState.ExitCode(); wantExit >= 0 && got != wantExit && ctx.Err() == nil {
		return fmt.Errorf("plugin-host 的退出码是 %d,用例要 %d(%v)", got, wantExit, err)
	}
	return nil
}

// 拿「被测的是 plugin-host」的那些用例去测一个外部实现:LYRIMUSE_PLUGIN_HOST_CMD 是它的启动命令(按空白拆成参数),
// 不设就跳过。引擎那一头照脚本演;时钟步骤按真实时间等。LYRIMUSE_PLUGIN_HOST_CASES 是只跑哪些用例的 id 前缀(逗号分隔)。
func TestPluginProtocolExternalHost(t *testing.T) {
	argv := strings.Fields(os.Getenv("LYRIMUSE_PLUGIN_HOST_CMD"))
	if len(argv) == 0 {
		t.Skip("没设 LYRIMUSE_PLUGIN_HOST_CMD")
	}
	var only []string
	if raw := os.Getenv("LYRIMUSE_PLUGIN_HOST_CASES"); raw != "" {
		only = strings.Split(raw, ",")
	}
	for _, c := range ppLoadCases(t) {
		selected := only == nil || slices.ContainsFunc(only, func(prefix string) bool { return strings.HasPrefix(c.ID, prefix) })
		if !c.subjectIncludes(ppHost) || !selected {
			continue
		}
		t.Run(c.ID, func(t *testing.T) {
			t.Parallel()
			engineErr, hostErr, _ := ppRunWithin(30*time.Second, c, ppScripted{}, ppProcessHost{argv: argv}, &ppClock{realTime: true})
			if err := ppFirstCause(engineErr, hostErr); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// ---- 协议文档跟 protocol.json、跟用例对得上 ----

// ppDocPaths:协议文档可能在的地方。功能发布前在只留本地的 docs/proposals/ 下,发布那一版搬到 docs/plugins/。
var ppDocPaths = []string{"../docs/plugins/protocol.md", "../docs/proposals/lyric-plugin-protocol.md"}

// ppDocBlock 取文档里 <!-- name:begin --> 和 <!-- name:end --> 之间的表格数据行(不含表头和分隔行),每行拆成单元格。
func ppDocBlock(t *testing.T, doc, name string) [][]string {
	t.Helper()
	begin, end := "<!-- "+name+":begin -->", "<!-- "+name+":end -->"
	i, j := strings.Index(doc, begin), strings.Index(doc, end)
	if i < 0 || j < i {
		t.Fatalf("协议文档里没有 %s 这一段", name)
	}
	var rows [][]string
	for n, line := range strings.Split(strings.TrimSpace(doc[i+len(begin):j]), "\n") {
		line = strings.TrimSpace(line)
		if n < 2 || !strings.HasPrefix(line, "|") {
			continue
		}
		cells := strings.Split(strings.Trim(line, "|"), "|")
		for k := range cells {
			cells[k] = strings.Trim(strings.TrimSpace(cells[k]), "`")
		}
		rows = append(rows, cells)
	}
	return rows
}

func ppFirstCells(rows [][]string, n int) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, strings.Join(r[:min(n, len(r))], " | "))
	}
	sort.Strings(out)
	return out
}

// ppCoverageRows 是文档里「方法和用例的对照」那张表该有的内容:每个方法有几个用例、按分类各几个。
func ppCoverageRows(cat *ppCatalog, cases []*ppCase) []string {
	var rows []string
	for _, m := range cat.Methods {
		perCategory := map[string]int{}
		total := 0
		for _, c := range cases {
			if slices.Contains(c.Covers, m.Name) {
				perCategory[c.Category]++
				total++
			}
		}
		var parts []string
		for _, category := range ppCategories {
			if n := perCategory[category]; n > 0 {
				parts = append(parts, fmt.Sprintf("%s %d", category, n))
			}
		}
		rows = append(rows, fmt.Sprintf("| `%s` | %d | %s |", m.Name, total, strings.Join(parts, "、")))
	}
	return rows
}

// ppCaseRows 是文档里「用例清单」那张表该有的内容。
func ppCaseRows(cases []*ppCase) []string {
	subjects := map[string]string{ppEngine: "引擎", ppHost: "plugin-host", "both": "两头"}
	rows := make([]string, 0, len(cases))
	for _, c := range cases {
		rows = append(rows, fmt.Sprintf("| `%s` | %s | %s |", c.ID, subjects[c.Subject], strings.ReplaceAll(c.Title, "|", "\\|")))
	}
	return rows
}

// ppReplaceDocBlock 把文档里 name 那一段的数据行换成 rows(表头和分隔行留着)。
func ppReplaceDocBlock(doc, name string, rows []string) string {
	begin, end := "<!-- "+name+":begin -->", "<!-- "+name+":end -->"
	i, j := strings.Index(doc, begin), strings.Index(doc, end)
	lines := strings.Split(strings.TrimSpace(doc[i+len(begin):j]), "\n")
	body := append(slices.Clone(lines[:2]), rows...)
	return doc[:i+len(begin)] + "\n" + strings.Join(body, "\n") + "\n" + doc[j:]
}

// 协议文档里的方法表、错误码表、插件错误码表、上限表跟 protocol.json 一致,「方法和用例的对照」「用例清单」跟用例目录一致。
// 文档只留本地时 CI 和提交校验的目录里没有它,整条跳过;LYRIMUSE_WRITE_PLUGIN_PROTOCOL_DOC=1 时把后两张表重写进文档。
func TestPluginProtocolDocMatchesCatalogAndCases(t *testing.T) {
	var path, doc string
	for _, p := range ppDocPaths {
		if raw, err := os.ReadFile(p); err == nil {
			path, doc = p, string(raw)
			break
		}
	}
	if path == "" {
		t.Skip("这棵树里没有协议文档(只留本地的 docs/proposals/ 不在提交校验和 CI 的目录里)")
	}
	cat := ppLoadCatalog(t)
	cases := ppLoadCases(t)

	generated := map[string][]string{"protocol-coverage": ppCoverageRows(cat, cases), "protocol-cases": ppCaseRows(cases)}
	if os.Getenv("LYRIMUSE_WRITE_PLUGIN_PROTOCOL_DOC") == "1" {
		updated := doc
		for name, rows := range generated {
			ppDocBlock(t, updated, name)
			updated = ppReplaceDocBlock(updated, name, rows)
		}
		if updated != doc {
			if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
				t.Fatal(err)
			}
			doc = updated
		}
	}

	directions := map[string]string{ppEngine: "引擎 → plugin-host", ppHost: "plugin-host → 引擎", "both": "两个方向"}
	kinds := map[string]string{"request": "请求", "notification": "通知"}
	var wantMethods, wantErrors, wantPluginErrors, wantLimits []string
	for _, m := range cat.Methods {
		wantMethods = append(wantMethods, m.Name+" | "+directions[m.From]+" | "+kinds[m.Kind])
	}
	for _, e := range cat.Errors {
		wantErrors = append(wantErrors, strconv.Itoa(e.Code)+" | "+e.Name)
	}
	for _, code := range cat.PluginErrors.Load {
		wantPluginErrors = append(wantPluginErrors, code+" | 加载")
	}
	for _, code := range cat.PluginErrors.Call {
		wantPluginErrors = append(wantPluginErrors, code+" | 调用")
	}
	for name, value := range cat.Limits {
		wantLimits = append(wantLimits, name+" | "+strconv.Itoa(value))
	}
	checks := []struct {
		block string
		cells int
		want  []string
	}{
		{"protocol-methods", 3, wantMethods},
		{"protocol-errors", 2, wantErrors},
		{"protocol-plugin-errors", 2, wantPluginErrors},
		{"protocol-limits", 2, wantLimits},
	}
	for _, check := range checks {
		got := ppFirstCells(ppDocBlock(t, doc, check.block), check.cells)
		sort.Strings(check.want)
		if !slices.Equal(got, check.want) {
			t.Errorf("%s 的 %s 跟 protocol.json 对不上:\n文档:%v\n目录:%v", path, check.block, got, check.want)
		}
	}
	for name, rows := range generated {
		var got []string
		for _, cells := range ppDocBlock(t, doc, name) {
			got = append(got, strings.Join(cells, " | "))
		}
		var want []string
		for _, cells := range ppDocBlock(t, ppReplaceDocBlock(doc, name, rows), name) {
			want = append(want, strings.Join(cells, " | "))
		}
		if !slices.Equal(got, want) {
			t.Errorf("%s 的 %s 跟用例目录对不上;在 lyrimuse-engine 下带 LYRIMUSE_WRITE_PLUGIN_PROTOCOL_DOC=1 跑这条测试重写", path, name)
		}
	}
}
