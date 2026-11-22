package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strconv"
	"strings"
)

// 插件协议的参考模型:不跑任何实现,只把一个用例的脚本从头到尾实例化出来,拿协议文档里的规则核对它本身——
// 报文形状、方法的方向和必填字段、id 的配对、plugin-host 的状态机、调用和 host/* 请求的归属、错误码和附带数据、
// 结果的形状,以及引擎对一个任务的结论(含宿主纠正)。照脚本演的两头只能证明脚本前后对得上,
// 脚本合不合协议由这里守。故意不守协议的步骤(invalid)本身不核对,只核对对方的反应。

// ppReport 是核对一个用例的结果。
type ppReport struct {
	problems []string
	// methods:出现过的方法,键是「发的一头 + 空格 + 方法名」。
	methods map[string]bool
	// codes:出现过的错误码,键是 "-32802" 和 "-32802/jsTime" 两种;插件错误是 "-32000/NOT_FOUND"。
	codes map[string]bool
}

type ppPending struct {
	method    string
	invalid   string
	wantState string // 非空:状态机说这个请求必须被 -32806 拒绝,data.state 是它
	wantError bool   // 这次调用已经被取消,新发的 host/* 请求必须回错误
	call      *ppCallRec
	fetch     *ppFetchRec
}

// ppCallRec 是一次 lyrics/* 调用。
type ppCallRec struct {
	id, task, method string
	done             bool
	cancelled        bool // 引擎发过 $/cancelRequest
	deadline         bool // 那次取消的 reason 是 deadline
	lost             bool // 没等到应答连接就断了
	malformed        bool // 应答本身不合规(result 和 error 都有)
	errCode          int
	pluginCode       string
	retryAfter       int
	result           map[string]any
}

// ppFetchRec 是一次 host/fetch。status 为 0 表示没有拿到上游的应答。
type ppFetchRec struct {
	method, url string
	status      int
	retryAfter  int
	redirected  bool
	errCode     int
	errReason   string
	answered    bool
}

type ppTaskRec struct {
	calls   []*ppCallRec
	fetches []*ppFetchRec
}

type ppChecker struct {
	cat    *ppCatalog
	c      *ppCase
	report *ppReport
	where  string

	state       string
	inflight    map[string]map[string]*ppPending // 发起的一头 → id → 在途请求
	duplicates  map[string]map[string]bool       // 故意重复的在途 id,等着被 -32600 拒掉
	calls       map[string]*ppCallRec
	tasks       map[string]*ppTaskRec
	closed      map[string]bool
	exitSent    bool
	invalidFrom string // 上一个事件是故意不守协议的:发它的那一头
	fetches     []*ppFetchRec
}

func ppPeer(role string) string {
	if role == ppEngine {
		return ppHost
	}
	return ppEngine
}

func ppIDKey(id any) string { return fmt.Sprintf("%T:%v", id, id) }

// ppCheckCase 拿协议规则核对一个用例。
func ppCheckCase(cat *ppCatalog, c *ppCase) *ppReport {
	k := &ppChecker{
		cat: cat, c: c,
		report:     &ppReport{methods: map[string]bool{}, codes: map[string]bool{}},
		state:      "uninitialized",
		inflight:   map[string]map[string]*ppPending{ppEngine: {}, ppHost: {}},
		duplicates: map[string]map[string]bool{ppEngine: {}, ppHost: {}},
		calls:      map[string]*ppCallRec{},
		tasks:      map[string]*ppTaskRec{},
		closed:     map[string]bool{},
	}
	vars := ppVars{}
	for i := range c.Steps {
		s := &c.Steps[i]
		k.where = fmt.Sprintf("第 %d 步", i+1)
		kind := s.kind()
		if kind != "clock" && kind != "observe" {
			if k.closed[s.From] && kind != "close" {
				k.problem("%s 已经关了输出,不能再发", s.From)
			}
			if s.From == ppHost && k.exitSent && kind != "close" {
				k.problem("exit 之后 plugin-host 只能退出")
			}
		}
		switch kind {
		case "message":
			k.instantiated(s.From, s.pattern, s.Invalid, vars)
		case "unordered":
			if s.Invalid != "" {
				k.problem("unordered 不能整组标 invalid")
			}
			for _, p := range s.Unordered {
				k.instantiated(s.From, p, "", vars)
			}
		case "raw":
			if s.Invalid == "" {
				k.problem("原样字节的步骤要标 invalid(说明它哪里不守协议)")
			}
			k.rawLine(s)
		case "close":
			k.close(s.From)
		case "observe":
			k.observe(s.Observe)
		}
		if kind != "clock" && kind != "observe" {
			if s.Invalid != "" {
				k.invalidFrom = s.From
			} else {
				k.invalidFrom = ""
			}
		}
	}
	k.where = "收尾"
	if !k.closed[ppEngine] && !k.closed[ppHost] {
		k.problem("用例要以一头关掉输出收尾")
	}
	for role, pending := range k.inflight {
		for id, p := range pending {
			k.problem("%s 的请求 %s(%s)到最后没有应答、连接也没断", role, id, p.method)
		}
	}
	k.checkStubs()
	k.checkDrive()
	k.checkCovers()
	return k.report
}

func (k *ppChecker) problem(format string, args ...any) {
	k.report.problems = append(k.report.problems, k.where+": "+fmt.Sprintf(format, args...))
}

func (k *ppChecker) instantiated(from string, pattern any, invalid string, vars ppVars) {
	v, _, err := ppInstantiate(pattern, vars, &k.c.values)
	if err != nil {
		k.problem("实例化不了: %v", err)
		return
	}
	// 过一遍编码再解码:跟线上收到的形状一致(整数成 float64)。
	raw, _ := json.Marshal(v)
	var decoded any
	_ = json.Unmarshal(raw, &decoded)
	msg, ok := decoded.(map[string]any)
	if !ok {
		k.problem("消息不是对象")
		return
	}
	k.message(from, msg, invalid)
}

// rawLine:原样字节那一步本身不核对,只把里面看得出的方法名记进覆盖表。
func (k *ppChecker) rawLine(s *ppStep) {
	line, err := s.rawLine()
	if err != nil {
		k.problem("%v", err)
		return
	}
	var msg map[string]any
	if json.Unmarshal(line, &msg) == nil {
		if method, ok := msg["method"].(string); ok {
			k.report.methods[s.From+" "+method+" (invalid)"] = true
		}
	}
}

func (k *ppChecker) message(from string, msg map[string]any, invalid string) {
	if invalid == "" && msg["jsonrpc"] != "2.0" {
		k.problem("缺 jsonrpc: \"2.0\"")
	}
	id, hasID := msg["id"]
	if _, isCall := msg["method"]; !isCall {
		k.response(from, msg, id, hasID, invalid)
		return
	}
	method, _ := msg["method"].(string)
	params, _ := msg["params"].(map[string]any)
	spec := k.cat.method(method)
	if invalid == "" {
		k.report.methods[from+" "+method] = true
		switch {
		case spec == nil:
			k.problem("方法 %q 不在方法表里(故意的话标 invalid)", method)
			return
		case spec.From != "both" && spec.From != from:
			k.problem("方法 %s 不该由 %s 发", method, from)
		case (spec.Kind == "request") != hasID:
			k.problem("方法 %s 是 %s,id 的有无对不上", method, spec.Kind)
		}
		for _, name := range spec.Params {
			if _, has := params[name]; !has {
				k.problem("%s 的 params 缺必填的 %s", method, name)
			}
		}
	} else {
		k.report.methods[from+" "+method+" (invalid)"] = true
	}
	if !hasID {
		k.notification(from, method, params, invalid)
		return
	}
	key := ppIDKey(id)
	if invalid == "duplicateId" {
		if k.inflight[from][key] == nil {
			k.problem("标了 duplicateId,但 id %v 并不在途", id)
		}
		k.duplicates[from][key] = true
		return
	}
	if k.inflight[from][key] != nil {
		k.problem("id %v 还在途就又用了一次", id)
		return
	}
	p := &ppPending{method: method, invalid: invalid}
	k.inflight[from][key] = p
	if invalid != "" || spec == nil {
		return
	}
	if from == ppEngine {
		p.wantState = k.rejectedInState(method)
		if p.wantState == "" && strings.HasPrefix(method, "lyrics/") {
			p.call = k.newCall(method, params)
		}
		return
	}
	callID, _ := params["call"].(string)
	call := k.calls[callID]
	switch {
	case call == nil || call.done:
		k.problem("%s 的 call %q 不是在途的调用(故意的话标 invalid: unknownCall)", method, callID)
	case call.cancelled:
		p.wantError = true
	}
	if method == "host/fetch" && call != nil {
		request, _ := params["request"].(map[string]any)
		rec := &ppFetchRec{method: "GET"}
		rec.url, _ = request["url"].(string)
		if m, ok := request["method"].(string); ok {
			rec.method = m
		}
		p.fetch = rec
		k.fetches = append(k.fetches, rec)
		k.tasks[call.task].fetches = append(k.tasks[call.task].fetches, rec)
	}
}

// rejectedInState:plugin-host 的状态机。返回非空表示这个请求在当前状态下必须被 -32806 拒绝。
func (k *ppChecker) rejectedInState(method string) string {
	switch {
	case k.state == "uninitialized" && method != "initialize",
		method == "initialize" && k.state != "uninitialized",
		method == "plugin/load" && k.state != "ready",
		strings.HasPrefix(method, "lyrics/") && k.state != "loaded",
		method == "shutdown" && k.state == "shuttingDown":
		return k.state
	}
	return ""
}

func (k *ppChecker) newCall(method string, params map[string]any) *ppCallRec {
	callParam, _ := params["call"].(map[string]any)
	rec := &ppCallRec{method: method}
	rec.id, _ = callParam["id"].(string)
	rec.task, _ = callParam["task"].(string)
	if timeout, ok := callParam["timeoutMs"].(float64); !ok || timeout <= 0 {
		k.problem("call.timeoutMs 要是正整数")
	}
	if rec.id == "" || rec.task == "" {
		k.problem("call.id 和 call.task 要是非空字符串")
		return nil
	}
	if k.calls[rec.id] != nil {
		k.problem("call.id %q 用了两次", rec.id)
		return nil
	}
	k.calls[rec.id] = rec
	if k.tasks[rec.task] == nil {
		k.tasks[rec.task] = &ppTaskRec{}
	}
	k.tasks[rec.task].calls = append(k.tasks[rec.task].calls, rec)
	return rec
}

func (k *ppChecker) notification(from, method string, params map[string]any, invalid string) {
	if invalid != "" {
		return
	}
	switch method {
	case "exit":
		k.exitSent = true
	case "$/cancelRequest":
		p := k.inflight[from][ppIDKey(params["id"])]
		if p == nil {
			return
		}
		if p.method == "initialize" || p.method == "shutdown" {
			k.problem("%s 不能取消", p.method)
		}
		if p.call != nil {
			p.call.cancelled = true
			p.call.deadline = params["reason"] == "deadline"
		}
	}
}

func (k *ppChecker) response(from string, msg map[string]any, id any, hasID bool, invalid string) {
	requester := ppPeer(from)
	result, hasResult := msg["result"]
	errObj, hasError := msg["error"].(map[string]any)
	code, data := 0, map[string]any{}
	if hasError {
		if f, ok := errObj["code"].(float64); ok {
			code = int(f)
		}
		if _, ok := errObj["message"].(string); !ok && invalid == "" {
			k.problem("error.message 要是字符串")
		}
		if d, ok := errObj["data"].(map[string]any); ok {
			data = d
		}
		if invalid == "" {
			k.noteCode(code, data)
		}
	}
	if !hasID {
		k.problem("应答没有 id")
		return
	}
	key := ppIDKey(id)
	if id != nil && k.duplicates[requester][key] && code == -32600 {
		delete(k.duplicates[requester], key)
		k.checkError(code, data, "", invalid)
		return
	}
	p := k.inflight[requester][key]
	if p == nil {
		if invalid != "" {
			return
		}
		if k.invalidFrom != requester {
			k.problem("应答的 id %v 对不上 %s 的任何在途请求", id, requester)
			return
		}
		if !hasError {
			k.problem("对不守协议的报文只能回错误")
			return
		}
		k.checkError(code, data, "", invalid)
		return
	}
	delete(k.inflight[requester], key)
	if p.call != nil {
		p.call.done = true
	}
	if invalid == "badResponse" {
		if p.call != nil {
			p.call.malformed = true
		}
		if p.fetch != nil {
			p.fetch.errCode = -32603
		}
		return
	}
	if hasResult == hasError {
		k.problem("应答里 result 和 error 要恰好有一个")
		return
	}
	if hasError {
		k.checkError(code, data, p.method, invalid)
	}
	switch {
	case p.invalid != "":
		if !hasError {
			k.problem("不合规的请求 %s 应该得到错误应答", p.method)
		}
		return
	case p.wantState != "":
		if code != -32806 || data["state"] != p.wantState {
			k.problem("%s 在 %s 状态下应该被 -32806(state: %s)拒绝", p.method, p.wantState, p.wantState)
		}
		return
	case code == -32806:
		k.problem("%s 在当前状态下是合法的,不该回 -32806", p.method)
	case p.wantError && !hasError:
		k.problem("调用已被取消,%s 应该得到错误应答", p.method)
	}
	if hasError {
		if p.call != nil {
			p.call.errCode = code
			p.call.pluginCode, _ = data["code"].(string)
			if f, ok := data["retryAfter"].(float64); ok {
				p.call.retryAfter = int(f)
			}
		}
		if p.fetch != nil {
			p.fetch.errCode = code
			p.fetch.errReason, _ = data["reason"].(string)
			if reason, _ := data["limit"].(string); reason != "" {
				p.fetch.errReason = reason
			}
		}
		return
	}
	k.success(p, result, invalid)
}

func (k *ppChecker) success(p *ppPending, result any, invalid string) {
	spec := k.cat.method(p.method)
	obj, isObj := result.(map[string]any)
	if invalid == "" {
		switch {
		case spec.Result == nil && result != nil:
			k.problem("%s 的 result 要是 null", p.method)
		case spec.Result != nil && !isObj:
			k.problem("%s 的 result 要是对象", p.method)
		case spec.Result != nil:
			for _, name := range *spec.Result {
				if _, has := obj[name]; !has {
					k.problem("%s 的 result 缺必填的 %s", p.method, name)
				}
			}
		}
	}
	switch p.method {
	case "initialize":
		if obj["protocolVersion"] == k.cat.ProtocolVersion {
			k.state = "ready"
		}
	case "plugin/load":
		k.state = "loaded"
	case "shutdown":
		k.state = "shuttingDown"
		if len(k.inflight[ppEngine])+len(k.inflight[ppHost]) > 0 {
			k.problem("shutdown 应答之前要先把在途的请求都结掉")
		}
	case "host/fetch":
		if p.fetch == nil {
			return
		}
		if status, ok := obj["status"].(float64); ok {
			p.fetch.status = int(status)
		}
		p.fetch.answered = true
		p.fetch.redirected, _ = obj["redirected"].(bool)
		headers, _ := obj["headers"].([]any)
		for _, h := range headers {
			pair, _ := h.([]any)
			if len(pair) == 2 && pair[0] == "retry-after" {
				p.fetch.retryAfter, _ = strconv.Atoi(fmt.Sprint(pair[1]))
			}
		}
	case "lyrics/search", "lyrics/getLyrics":
		if p.call == nil {
			return
		}
		p.call.result = obj
		if invalid != "" {
			return
		}
		var problems []string
		if p.method == "lyrics/search" {
			items, _ := obj["items"].([]any)
			for i, item := range items {
				_, _, itemProblems := ppJudgeItem(item)
				for _, pr := range itemProblems {
					problems = append(problems, fmt.Sprintf("items[%d]: %s", i, pr))
				}
			}
		} else {
			problems = ppJudgeLyrics(obj["lyrics"]).problems
		}
		for _, pr := range problems {
			k.problem("%s 的结果不合规(故意的话标 invalid: badPayload): %s", p.method, pr)
		}
	}
}

func (k *ppChecker) noteCode(code int, data map[string]any) {
	k.report.codes[strconv.Itoa(code)] = true
	for _, key := range []string{"reason", "limit", "state", "code"} {
		if v, ok := data[key].(string); ok {
			k.report.codes[strconv.Itoa(code)+"/"+v] = true
		}
	}
}

// checkError 核对错误码和它附带的数据。method 是被应答的请求的方法,对不上请求的错误应答传空串。
func (k *ppChecker) checkError(code int, data map[string]any, method, invalid string) {
	spec := k.cat.errorCode(code)
	if spec == nil {
		k.problem("错误码 %d 不在错误码表里", code)
		return
	}
	if code == -32000 {
		allowed := k.cat.PluginErrors.Call
		switch {
		case method == "plugin/load":
			allowed = k.cat.PluginErrors.Load
		case !strings.HasPrefix(method, "lyrics/"):
			k.problem("-32000 只用来应答 plugin/load 和 lyrics/*")
			return
		}
		pluginCode, _ := data["code"].(string)
		if !slices.Contains(allowed, pluginCode) && invalid != "unknownPluginCode" {
			k.problem("-32000 的 data.code %q 不在插件错误码表里", pluginCode)
		}
		return
	}
	key := spec.Data
	if key == "" {
		key = "reason"
	}
	value, has := data[key].(string)
	if spec.Data != "" && !has {
		k.problem("错误码 %d 要带 data.%s", code, spec.Data)
		return
	}
	if has && len(spec.Values) > 0 && !slices.Contains(spec.Values, value) {
		k.problem("错误码 %d 的 data.%s 不认识 %q", code, key, value)
	}
}

func (k *ppChecker) close(role string) {
	k.closed[role] = true
	for _, pending := range k.inflight {
		for id, p := range pending {
			if p.call != nil && !p.call.done {
				p.call.lost = true
			}
			delete(pending, id)
		}
	}
}

// ---- 结果的形状 ----

// ppLyricsVerdict 是引擎对一份 LyricsResult 校验之后还剩什么。
type ppLyricsVerdict struct {
	hasLyrics    bool // words / lines / plain 里至少一样可用
	instrumental bool
	noLyrics     bool
	badTimeline  bool // 交了 timeline,但一行都用不了
	problems     []string
}

// ppJudgeLyrics 按协议文档「LyricsResult」的规则校验:类型不对的栏不要,别的栏照用。
func ppJudgeLyrics(v any) ppLyricsVerdict {
	var out ppLyricsVerdict
	obj, ok := v.(map[string]any)
	if !ok {
		out.problems = append(out.problems, "lyrics 不是对象")
		return out
	}
	bad := func(format string, args ...any) { out.problems = append(out.problems, fmt.Sprintf(format, args...)) }
	text := func(name string) bool {
		raw, has := obj[name]
		if !has || raw == nil {
			return false
		}
		s, ok := raw.(string)
		if !ok {
			bad("%s 不是字符串", name)
		}
		return ok && s != ""
	}
	if raw, has := obj["words"]; has && raw != nil {
		words, _ := raw.(map[string]any)
		switch words["format"] {
		case "ttml", "lrc-a2":
			if s, _ := words["text"].(string); s != "" {
				out.hasLyrics = true
			} else {
				bad("words.text 要是非空字符串")
			}
		case "timeline":
			usable, problems := ppJudgeTimeline(words["lines"])
			out.problems = append(out.problems, problems...)
			out.hasLyrics = out.hasLyrics || usable
			out.badTimeline = !usable
		default:
			bad("words.format 不认识 %v", words["format"])
		}
	}
	out.hasLyrics = text("lines") || out.hasLyrics
	out.hasLyrics = text("plain") || out.hasLyrics
	for _, name := range []string{"instrumental", "noLyrics"} {
		raw, has := obj[name]
		if !has || raw == nil {
			continue
		}
		flag, ok := raw.(bool)
		if !ok {
			bad("%s 不是布尔值", name)
		}
		if name == "instrumental" {
			out.instrumental = flag
		} else {
			out.noLyrics = flag
		}
	}
	if raw, has := obj["translation"]; has && raw != nil {
		tr, _ := raw.(map[string]any)
		if _, ok := tr["lang"].(string); !ok {
			bad("translation.lang 不是字符串")
		}
		if _, ok := tr["lrc"].(string); !ok {
			bad("translation.lrc 不是字符串")
		}
	}
	if raw, has := obj["romanization"]; has && raw != nil {
		roma, _ := raw.(map[string]any)
		if _, ok := roma["lrc"].(string); !ok {
			bad("romanization.lrc 不是字符串")
		}
	}
	if raw, has := obj["songwriters"]; has && raw != nil {
		list, ok := raw.([]any)
		for _, name := range list {
			if _, isString := name.(string); !isString {
				ok = false
			}
		}
		if !ok {
			bad("songwriters 不是字符串数组")
		}
	}
	if raw, has := obj["pageURL"]; has && raw != nil {
		if _, ok := raw.(string); !ok {
			bad("pageURL 不是字符串")
		}
	}
	return out
}

// ppJudgeTimeline:行按 start 升序、end 不小于 start、有 text 或非空的 words;不合规的行不要。usable 是还剩至少一行。
func ppJudgeTimeline(v any) (usable bool, problems []string) {
	lines, ok := v.([]any)
	if !ok || len(lines) == 0 {
		return false, []string{"timeline.lines 要是非空数组"}
	}
	span := func(obj map[string]any) (start, end float64, ok bool) {
		start, okStart := obj["start"].(float64)
		end, okEnd := obj["end"].(float64)
		return start, end, okStart && okEnd && start >= 0 && end >= start && start == float64(int64(start)) && end == float64(int64(end))
	}
	lastStart := -1.0
	for i, raw := range lines {
		line, _ := raw.(map[string]any)
		start, _, ok := span(line)
		if !ok {
			problems = append(problems, fmt.Sprintf("timeline.lines[%d] 的 start / end 不合规", i))
			continue
		}
		if start < lastStart {
			problems = append(problems, fmt.Sprintf("timeline.lines[%d] 没按 start 升序", i))
			continue
		}
		words, hasWords := line["words"].([]any)
		lineText, _ := line["text"].(string)
		if lineText == "" && !hasWords {
			problems = append(problems, fmt.Sprintf("timeline.lines[%d] 没有 text 也没有 words", i))
			continue
		}
		wordsOK := true
		for _, key := range []string{"words", "background"} {
			segs, _ := line[key].([]any)
			for _, seg := range segs {
				segObj, _ := seg.(map[string]any)
				_, _, spanOK := span(segObj)
				if _, textOK := segObj["text"].(string); !spanOK || !textOK {
					wordsOK = false
				}
			}
		}
		if !wordsOK || (hasWords && len(words) == 0) {
			problems = append(problems, fmt.Sprintf("timeline.lines[%d] 的 words / background 不合规", i))
			if lineText == "" {
				continue
			}
		}
		lastStart = start
		usable = true
	}
	return usable, problems
}

// ppJudgeItem 校验搜索结果里的一条:id、title 要是非空字符串,artist 要是字符串,否则整条不要。
func ppJudgeItem(v any) (ok bool, lyrics *ppLyricsVerdict, problems []string) {
	obj, isObj := v.(map[string]any)
	if !isObj {
		return false, nil, []string{"条目不是对象"}
	}
	id, _ := obj["id"].(string)
	title, _ := obj["title"].(string)
	if _, artistOK := obj["artist"].(string); id == "" || title == "" || !artistOK {
		return false, nil, []string{"条目缺 id / title / artist,或者类型不对"}
	}
	for name, kind := range map[string]string{"album": "string", "durationSecs": "number", "isrc": "string", "language": "string", "hasSynced": "boolean"} {
		if raw, has := obj[name]; has && raw != nil && !ppIsKind(raw, kind) {
			problems = append(problems, fmt.Sprintf("%s 不是 %s", name, kind))
		}
	}
	if raw, has := obj["lyrics"]; has && raw != nil {
		verdict := ppJudgeLyrics(raw)
		lyrics = &verdict
		problems = append(problems, verdict.problems...)
	}
	return true, lyrics, problems
}

// ---- 任务结论 ----

// ppOutcome 是引擎对一个任务的结论:协议文档「任务结论与宿主纠正」那张表的参考实现。
func (k *ppChecker) outcome(task *ppTaskRec) (status string, retryAfter int, corrected bool) {
	for _, call := range task.calls {
		if call.cancelled && !call.deadline {
			return "CANCELLED", 0, false
		}
	}
	for _, call := range task.calls {
		if call.deadline || call.errCode == -32801 {
			return "TIMEOUT", 0, false
		}
	}
	var lastSearch int
	for i, call := range task.calls {
		if call.method == "lyrics/search" {
			lastSearch = i
		}
	}
	claim := "EMPTY"
	var verdicts []ppLyricsVerdict
	for i, call := range task.calls[lastSearch:] {
		known := slices.Contains(k.cat.PluginErrors.Call, call.pluginCode)
		switch {
		case call.lost, call.malformed, call.errCode != 0 && call.errCode != -32000,
			call.errCode == -32000 && (!known || call.pluginCode == "SCRIPT_ERROR" || call.pluginCode == "BAD_RESULT"):
			return "PLUGIN_ERROR", 0, false
		case call.errCode == -32000 && call.pluginCode != "NOT_FOUND":
			if i == 0 || claim == "EMPTY" {
				claim, retryAfter = call.pluginCode, call.retryAfter
			}
			if i == 0 {
				return claim, retryAfter, false
			}
		case call.errCode == -32000:
		case call.method == "lyrics/search":
			items, isList := call.result["items"].([]any)
			if !isList {
				return "PLUGIN_ERROR", 0, false
			}
			for _, item := range items {
				if ok, lyrics, _ := ppJudgeItem(item); ok && lyrics != nil {
					verdicts = append(verdicts, *lyrics)
				}
			}
		default:
			raw, has := call.result["lyrics"]
			if !has {
				return "PLUGIN_ERROR", 0, false
			}
			verdicts = append(verdicts, ppJudgeLyrics(raw))
		}
	}
	for _, v := range verdicts {
		if v.hasLyrics {
			return "FOUND", 0, false
		}
	}
	for _, v := range verdicts {
		switch {
		case v.instrumental:
			return "INSTRUMENTAL", 0, false
		case v.badTimeline:
			return "BAD_RESPONSE", 0, false
		case v.noLyrics && claim == "EMPTY":
			claim = "NO_LYRICS"
		}
	}
	if claim != "EMPTY" && claim != "NO_LYRICS" {
		return claim, retryAfter, false
	}
	// 宿主纠正:插件说「没有」,要这个任务里至少有一个请求确实得到了对方的回答才算数。
	limited := -1
	for _, f := range task.fetches {
		if (f.status >= 200 && f.status < 400) || f.status == 404 || f.status == 410 {
			if claim == "EMPTY" {
				return "NOT_FOUND", 0, false
			}
			return "NO_LYRICS", 0, false
		}
		if f.status == 429 && limited < 0 {
			limited = f.retryAfter
		}
	}
	switch {
	case len(task.fetches) == 0:
		return "SKIPPED", 0, true
	case limited >= 0:
		return "RATE_LIMITED", limited, true
	}
	return "UNAVAILABLE", 0, true
}

func (k *ppChecker) observe(o *ppObserve) {
	if !slices.Contains(k.cat.Outcomes, o.Outcome.Status) {
		k.problem("结论 %q 不在结论表里", o.Outcome.Status)
	}
	task := k.tasks[o.Task]
	if task == nil {
		k.problem("observe 的任务 %q 没有任何调用", o.Task)
		return
	}
	status, retryAfter, corrected := k.outcome(task)
	if status != o.Outcome.Status {
		k.problem("任务 %s 的结论按协议是 %s,用例写的是 %s", o.Task, status, o.Outcome.Status)
	}
	if o.Outcome.RetryAfter != nil && *o.Outcome.RetryAfter != retryAfter {
		k.problem("任务 %s 的 retryAfter 按协议是 %d,用例写的是 %d", o.Task, retryAfter, *o.Outcome.RetryAfter)
	}
	if o.Outcome.Corrected != nil && *o.Outcome.Corrected != corrected {
		k.problem("任务 %s 有没有被宿主纠正:按协议是 %v,用例写的是 %v", o.Task, corrected, *o.Outcome.Corrected)
	}
}

// ---- 夹具自己对不对得上 ----

// checkStubs:脚本里引擎答出来的每个 host/fetch 都有对得上的假上游,假上游没有用不到的。
func (k *ppChecker) checkStubs() {
	stubs := k.c.Fixture.HTTP
	used := make([]bool, len(stubs))
	uses := map[string]int{}
	for _, f := range k.fetches {
		needsUpstream := f.answered || f.errCode == -32804 || f.errReason == "responseBytes" || f.errReason == "lineBytes" ||
			f.errReason == "redirectNotAllowed" || f.errReason == "addressNotAllowed"
		var matching []int
		for i, stub := range stubs {
			if stub.Request.Method == f.method && stub.Request.URL == f.url {
				matching = append(matching, i)
			}
		}
		if len(matching) == 0 {
			if needsUpstream {
				k.problem("host/fetch %s %s 的应答来自上游,fixture.http 里却没有这一条", f.method, f.url)
			}
			continue
		}
		nth := min(uses[f.method+" "+f.url], len(matching)-1)
		uses[f.method+" "+f.url]++
		stub := stubs[matching[nth]]
		used[matching[nth]] = true
		switch {
		case stub.Fail == "network" && (f.errCode != -32804 || f.errReason != "network"):
			k.problem("假上游 %s 连不上,host/fetch 应该得到 -32804 network", f.url)
		case stub.Fail == "hang" && f.answered:
			k.problem("假上游 %s 一直不答,host/fetch 不该拿到应答", f.url)
		case stub.Response != nil && f.answered && !f.redirected && stub.Response.Status != f.status:
			k.problem("假上游 %s 答的是 %d,脚本里引擎交回的是 %d", f.url, stub.Response.Status, f.status)
		}
	}
	for i, stub := range stubs {
		if stub.Response == nil {
			continue
		}
		for _, h := range stub.Response.Headers {
			if len(h) != 2 || !strings.EqualFold(h[0], "location") {
				continue
			}
			base, err1 := url.Parse(stub.Request.URL)
			ref, err2 := url.Parse(h[1])
			if err1 != nil || err2 != nil || !used[i] {
				continue
			}
			target := base.ResolveReference(ref).String()
			for j := range stubs {
				if stubs[j].Request.URL == target {
					used[j] = true
				}
			}
		}
	}
	for i, stub := range stubs {
		if !used[i] {
			k.problem("fixture.http 里 %s %s 没有任何 host/fetch 用到", stub.Request.Method, stub.Request.URL)
		}
	}
}

// checkDrive:被测引擎适配器要的驱动提示齐不齐。只有能拿来测引擎的用例才有 drive。
func (k *ppChecker) checkDrive() {
	c := k.c
	if !c.subjectIncludes(ppEngine) {
		if len(c.Drive) > 0 {
			k.problem("只测 plugin-host 的用例不写 drive")
		}
		return
	}
	labels := map[string]string{}
	for _, s := range c.Steps {
		if s.Label != "" {
			labels[s.Label] = s.From
		}
	}
	resolved := map[string]bool{}
	for i, d := range c.Drive {
		before, _ := d["before"].(string)
		do, _ := d["do"].(string)
		if labels[before] != ppEngine {
			k.problem("drive[%d] 的 before %q 不是引擎发的那一步的标签", i, before)
		}
		switch do {
		case "start", "stop", "cancel", "releaseHttp":
		case "resolve":
			task, _ := d["task"].(string)
			if _, ok := d["track"].(map[string]any); !ok || task == "" {
				k.problem("drive[%d] 的 resolve 要带 task 和 track", i)
			}
			resolved[task] = true
		default:
			k.problem("drive[%d] 的 do %q 不认识", i, do)
		}
		if (i == 0) != (do == "start") {
			k.problem("drive 的第一条、也只有第一条是 start")
		}
	}
	for task := range k.tasks {
		if !resolved[task] {
			k.problem("任务 %s 没有对应的 drive resolve", task)
		}
	}
}

// checkCovers:covers 里写的方法都在方法表里,而且这个用例里确实出现了。
func (k *ppChecker) checkCovers() {
	for _, method := range k.c.Covers {
		if k.cat.method(method) == nil {
			k.problem("covers 里的 %q 不在方法表里", method)
			continue
		}
		seen := false
		for key := range k.report.methods {
			if strings.Fields(key)[1] == method {
				seen = true
			}
		}
		if !seen {
			k.problem("covers 写了 %s,用例里却没有这个方法", method)
		}
	}
}
