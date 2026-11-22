package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
)

// 插件协议一致性用例的数据模型和加载。用例是数据(testdata/pluginprotocol/),格式的成文规格在协议文档
// 「一致性用例的格式」一节;这里只是 Go 这一侧的读法。

const ppDir = "testdata/pluginprotocol"

const (
	ppEngine = "engine"
	ppHost   = "host"
)

// ppCategories:用例分类,也是文件名的前缀。
var ppCategories = []string{
	"lifecycle", "load", "lyrics", "errors", "badresult", "fetch", "hostapi",
	"cancel", "concurrency", "malformed", "requery", "correction", "compat",
}

// ppCatalog 是 protocol.json:方法表、错误码、插件错误码、任务结论、各项上限,机器可读的那一份。
type ppCatalog struct {
	ProtocolVersion string        `json:"protocolVersion"`
	Methods         []ppMethod    `json:"methods"`
	Errors          []ppErrorCode `json:"errors"`
	PluginErrors    struct {
		Load []string `json:"load"`
		Call []string `json:"call"`
	} `json:"pluginErrors"`
	Outcomes []string       `json:"outcomes"`
	Limits   map[string]int `json:"limits"`
}

// ppMethod:From 是谁能发(engine / host / both),Kind 是 request / notification;Params / Result 是必填字段名。
// 请求的 Result 为 nil 表示成功应答的 result 是 null。
type ppMethod struct {
	Name   string    `json:"name"`
	From   string    `json:"from"`
	Kind   string    `json:"kind"`
	Params []string  `json:"params"`
	Result *[]string `json:"result"`
}

// ppErrorCode:Data 非空时 error.data 里必须有这个键;Values 非空时那个键(Data 为空时是 reason)只能取这些值。
type ppErrorCode struct {
	Code   int      `json:"code"`
	Name   string   `json:"name"`
	Data   string   `json:"data"`
	Values []string `json:"values"`
}

func (c *ppCatalog) method(name string) *ppMethod {
	for i := range c.Methods {
		if c.Methods[i].Name == name {
			return &c.Methods[i]
		}
	}
	return nil
}

func (c *ppCatalog) errorCode(code int) *ppErrorCode {
	for i := range c.Errors {
		if c.Errors[i].Code == code {
			return &c.Errors[i]
		}
	}
	return nil
}

// ppCase 是一个用例。Steps 是把 include 展开之后的。
type ppCase struct {
	ID       string           `json:"id"`
	Category string           `json:"category"`
	Title    string           `json:"title"`
	Subject  string           `json:"subject"` // 被测的是哪一头:engine / host / both
	Covers   []string         `json:"covers"`
	Notes    string           `json:"notes"`
	Fixture  ppFixture        `json:"fixture"`
	Drive    []map[string]any `json:"drive"`   // 给被测引擎适配器的提示:走到哪一步之前让引擎做什么
	Ambient  *[]string        `json:"ambient"` // 随时可能出现、没写进脚本也不算错的通知;不写是 host/log 和 $/heartbeat
	Steps    []ppStep         `json:"steps"`

	values   ppFixtureValues
	includes []string // 用到的片段(include 的路径)
}

// ppFixture:被测的一头要的布置。Manifest 加 ManifestPatch(浅合并)是清单,Plugin 是脚本正文,
// HTTP 是被测引擎的假上游,Config 是握手时要报的非默认上限。
type ppFixture struct {
	Manifest      string                    `json:"manifest"`
	ManifestPatch map[string]any            `json:"manifestPatch"`
	Plugin        string                    `json:"plugin"`
	HTTP          []ppHTTPStub              `json:"http"`
	Config        map[string]map[string]int `json:"config"`
}

// ppHTTPStub:假上游的一条应答。同一个方法加地址有几条时按先后各用一次,最后一条可以反复用。
// Fail 是 "network"(连不上)或 "hang"(一直不答,直到被取消或超时);Gate 非空时这条应答扣着,等 drive 里的 releaseHttp 放行。
type ppHTTPStub struct {
	Request struct {
		Method string `json:"method"`
		URL    string `json:"url"`
	} `json:"request"`
	Response *struct {
		Status     int        `json:"status"`
		Headers    [][]string `json:"headers"`
		Body       string     `json:"body"`
		BodyBase64 string     `json:"bodyBase64"`
		BodyRepeat *struct {
			Text  string `json:"text"`
			Count int    `json:"count"`
		} `json:"bodyRepeat"`
	} `json:"response"`
	Fail       string `json:"fail"`
	Gate       string `json:"gate"`
	ResolvesTo string `json:"resolvesTo"`
}

// ppStep 是脚本里的一步,下面几种恰好占一种:
//   - Message:From 发一条消息(模式);
//   - Raw / RawBase64 / RawFill:From 发一行原样的字节(畸形报文用);
//   - Unordered:From 发这几条消息,对方收到的先后不限;
//   - Close:From 关掉自己的输出(进程退出、被杀或断开);
//   - Clock:时钟拨快这么多毫秒(同步点);
//   - Observe:被测引擎此刻对某个任务的结论;
//   - Include:插进一个片段(加载时展开)。
type ppStep struct {
	Label     string          `json:"label"`
	From      string          `json:"from"`
	Message   json.RawMessage `json:"message"`
	Raw       *string         `json:"raw"`
	RawBase64 string          `json:"rawBase64"`
	RawFill   *ppRawFill      `json:"rawFill"`
	Unordered []any           `json:"unordered"`
	Close     bool            `json:"close"`
	ExitCode  *int            `json:"exitCode"` // 只在 Close 上:被测 plugin-host 的进程退出码
	Kill      bool            `json:"kill"`     // 只在 Close 上:引擎是杀进程,不是正常收尾
	Clock     *ppClockStep    `json:"clock"`
	Observe   *ppObserve      `json:"observe"`
	Include   string          `json:"include"`
	// Invalid 非空:这一步是故意不守协议的,值说明是哪一种。参考模型不拿协议规则核对它本身。
	Invalid string `json:"invalid"`

	pattern any // Message 解出来的模式
}

// ppRawFill:Prefix + Fill 重复若干次 + Suffix,总长恰好 TotalBytes 字节(不含行尾换行)。
type ppRawFill struct {
	Prefix     string `json:"prefix"`
	Fill       string `json:"fill"`
	Suffix     string `json:"suffix"`
	TotalBytes int    `json:"totalBytes"`
}

type ppClockStep struct {
	AdvanceMs int `json:"advanceMs"`
}

type ppObserve struct {
	Task    string `json:"task"`
	Outcome struct {
		Status     string `json:"status"`
		RetryAfter *int   `json:"retryAfter"`
		Corrected  *bool  `json:"corrected"`
	} `json:"outcome"`
}

func (s *ppStep) kind() string {
	var kinds []string
	if s.Message != nil {
		kinds = append(kinds, "message")
	}
	if s.Raw != nil || s.RawBase64 != "" || s.RawFill != nil {
		kinds = append(kinds, "raw")
	}
	if s.Unordered != nil {
		kinds = append(kinds, "unordered")
	}
	if s.Close {
		kinds = append(kinds, "close")
	}
	if s.Clock != nil {
		kinds = append(kinds, "clock")
	}
	if s.Observe != nil {
		kinds = append(kinds, "observe")
	}
	if s.Include != "" {
		kinds = append(kinds, "include")
	}
	if len(kinds) != 1 {
		return ""
	}
	return kinds[0]
}

// rawLine 是原样字节那一步要发的一行(不含行尾换行)。
func (s *ppStep) rawLine() ([]byte, error) {
	switch {
	case s.Raw != nil:
		return []byte(*s.Raw), nil
	case s.RawBase64 != "":
		return base64.StdEncoding.DecodeString(s.RawBase64)
	case s.RawFill != nil:
		f := s.RawFill
		pad := f.TotalBytes - len(f.Prefix) - len(f.Suffix)
		if pad < 0 || f.Fill == "" || pad%len(f.Fill) != 0 {
			return nil, fmt.Errorf("rawFill 拼不出恰好 %d 字节", f.TotalBytes)
		}
		return []byte(f.Prefix + strings.Repeat(f.Fill, pad/len(f.Fill)) + f.Suffix), nil
	}
	return nil, fmt.Errorf("这一步不是原样字节")
}

func (c *ppCase) ambient() []string {
	if c.Ambient != nil {
		return *c.Ambient
	}
	return []string{"host/log", "$/heartbeat"}
}

// subjectIncludes:这个用例能不能拿来测 role 那一头的真实现。
func (c *ppCase) subjectIncludes(role string) bool {
	return c.Subject == "both" || c.Subject == role
}

func ppReadStrict(path string, into any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(into); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}

func ppLoadCatalog(t testing.TB) *ppCatalog {
	t.Helper()
	var cat ppCatalog
	if err := ppReadStrict(filepath.Join(ppDir, "protocol.json"), &cat); err != nil {
		t.Fatal(err)
	}
	return &cat
}

// ppLoadCases 读出全部用例(按 id 排序),展开片段、备好清单和脚本全文、校验每一步的形状。
func ppLoadCases(t testing.TB) []*ppCase {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(ppDir, "cases", "*.json"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("没找到用例: %v", err)
	}
	sort.Strings(paths)
	cases := make([]*ppCase, 0, len(paths))
	for _, path := range paths {
		c, err := ppLoadCase(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		cases = append(cases, c)
	}
	return cases
}

func ppLoadCase(path string) (*ppCase, error) {
	var c ppCase
	if err := ppReadStrict(path, &c); err != nil {
		return nil, err
	}
	if want := strings.TrimSuffix(filepath.Base(path), ".json"); c.ID != want {
		return nil, fmt.Errorf("id %q 跟文件名对不上", c.ID)
	}
	if !slices.Contains(ppCategories, c.Category) || !strings.HasPrefix(c.ID, c.Category+"-") {
		return nil, fmt.Errorf("分类 %q 不认识,或者 id 不是以它开头", c.Category)
	}
	if !slices.Contains([]string{ppEngine, ppHost, "both"}, c.Subject) {
		return nil, fmt.Errorf("subject %q 不认识", c.Subject)
	}
	if c.Title == "" || len(c.Covers) == 0 {
		return nil, fmt.Errorf("缺 title 或 covers")
	}
	var steps []ppStep
	for _, s := range c.Steps {
		if s.kind() != "include" {
			steps = append(steps, s)
			continue
		}
		var frag struct {
			Steps []ppStep `json:"steps"`
		}
		if err := ppReadStrict(filepath.Join(ppDir, s.Include), &frag); err != nil {
			return nil, err
		}
		c.includes = append(c.includes, s.Include)
		steps = append(steps, frag.Steps...)
	}
	c.Steps = steps
	if err := c.loadFixture(); err != nil {
		return nil, err
	}
	labels := map[string]bool{}
	for i := range c.Steps {
		s := &c.Steps[i]
		if err := s.check(); err != nil {
			return nil, fmt.Errorf("第 %d 步: %w", i+1, err)
		}
		if s.Label != "" {
			if labels[s.Label] {
				return nil, fmt.Errorf("标签 %q 重复", s.Label)
			}
			labels[s.Label] = true
		}
	}
	return &c, nil
}

// check 校验一步的形状,顺带把 Message 解成模式。
func (s *ppStep) check() error {
	kind := s.kind()
	switch kind {
	case "":
		return fmt.Errorf("一步里要恰好有 message / raw* / unordered / close / clock / observe / include 当中的一种")
	case "include":
		return fmt.Errorf("片段里不能再 include")
	case "clock", "observe":
		if s.From != "" {
			return fmt.Errorf("%s 这一步不写 from", kind)
		}
		return nil
	}
	if s.From != ppEngine && s.From != ppHost {
		return fmt.Errorf("from 要是 engine 或 host")
	}
	if (s.ExitCode != nil || s.Kill) && kind != "close" {
		return fmt.Errorf("exitCode / kill 只写在 close 上")
	}
	switch kind {
	case "message":
		if err := json.Unmarshal(s.Message, &s.pattern); err != nil {
			return err
		}
		return ppValidatePattern(s.pattern)
	case "raw":
		_, err := s.rawLine()
		return err
	case "unordered":
		if len(s.Unordered) < 2 {
			return fmt.Errorf("unordered 至少两条")
		}
		return ppValidatePattern(s.Unordered)
	}
	return nil
}

// loadFixture 读清单和脚本,拼出 $fixture 的两个取值。脚本全文 = 清单注释块 + 脚本正文,
// 跟方案 4.2 的插件文件同一个形状。
func (c *ppCase) loadFixture() error {
	var manifest map[string]any
	if err := ppReadStrict(filepath.Join(ppDir, c.Fixture.Manifest), &manifest); err != nil {
		return err
	}
	for k, v := range c.Fixture.ManifestPatch {
		manifest[k] = v
	}
	body, err := os.ReadFile(filepath.Join(ppDir, c.Fixture.Plugin))
	if err != nil {
		return err
	}
	header, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	c.values = ppFixtureValues{manifest: manifest, source: "/* @lyrimuse-plugin\n" + string(header) + "\n*/\n\n" + string(body)}
	return nil
}
