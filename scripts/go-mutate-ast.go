//go:build ignore

// go-mutate.py 的语法助手:把一批变异编进同一份源码(mutant schemata)。
//
// 标准输入读一个 JSON:
//
//	{"dir": 包目录, "out": 生成文件放哪, "switch_var": 开关变量名, "env": 环境变量名,
//	 "mutants": [{"id", "file", "old", "new"}], "classic": [强制单独编译的 id]}
//
// 每个变异找到包住它的最内层函数体,在函数体开头插一段
//
//	if <开关变量> == "<id>" { <改过的函数体副本>; return 或 panic }
//
// 开关变量由另生成的一个文件按环境变量取值,所以一份测试二进制能按环境变量切到任意一个变异。
// 副本里属于这个函数自己的标签加 __m<id> 后缀,不然跟原函数体里的同名标签冲突。
// 不在任何函数体里的变异(包级变量、类型、签名)整份文件替换,标成 classic,由调用方单独编译。
//
// 标准输出写 {"overlay": {原路径: 生成路径}, "guards": [...], "classic": [...], "errors": [...]}。
package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type mutant struct {
	ID   string `json:"id"`
	File string `json:"file"`
	Old  string `json:"old"`
	New  string `json:"new"`
}

type input struct {
	Dir       string   `json:"dir"`
	Out       string   `json:"out"`
	SwitchVar string   `json:"switch_var"`
	Env       string   `json:"env"`
	Mutants   []mutant `json:"mutants"`
	Classic   []string `json:"classic"`
}

type guard struct {
	ID        string `json:"id"`
	File      string `json:"file"`
	StartLine int    `json:"start_line"`
	EndLine   int    `json:"end_line"`
	Func      string `json:"func"`
}

type classic struct {
	ID          string `json:"id"`
	File        string `json:"file"`
	OverlayFile string `json:"overlay_file"`
	Reason      string `json:"reason"`
}

type failure struct {
	ID  string `json:"id"`
	Msg string `json:"msg"`
}

type output struct {
	Overlay map[string]string `json:"overlay"`
	Guards  []guard           `json:"guards"`
	Classic []classic         `json:"classic"`
	Errors  []failure         `json:"errors"`
	Notes   []failure         `json:"notes"`
}

// host 是包住变异的那个函数:函数体花括号的位置、有没有返回值、它自己作用域里的标签。
type host struct {
	name       string
	lbrace     int
	rbrace     int
	hasResults bool
	labels     []labelUse
}

type labelUse struct {
	name   string
	offset int
}

type insertion struct {
	offset int
	id     string
	text   string
	fn     string
}

func main() {
	var in input
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fail("读输入: %v", err)
	}
	out := output{Overlay: map[string]string{}, Guards: []guard{}, Classic: []classic{}, Errors: []failure{}, Notes: []failure{}}
	forced := map[string]bool{}
	for _, id := range in.Classic {
		forced[id] = true
	}
	byFile := map[string][]mutant{}
	var files []string
	for _, m := range in.Mutants {
		if _, ok := byFile[m.File]; !ok {
			files = append(files, m.File)
		}
		byFile[m.File] = append(byFile[m.File], m)
	}
	pkgName := ""
	for _, file := range files {
		path := filepath.Join(in.Dir, file)
		raw, err := os.ReadFile(path)
		if err != nil {
			for _, m := range byFile[file] {
				out.Errors = append(out.Errors, failure{m.ID, err.Error()})
			}
			continue
		}
		src := string(raw)
		if strings.Contains(src, in.SwitchVar) {
			fail("%s 里已经有标识符 %s,换一个开关变量名", file, in.SwitchVar)
		}
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, path, raw, parser.SkipObjectResolution)
		if err != nil {
			fail("解析 %s: %v", file, err)
		}
		if pkgName == "" {
			pkgName = f.Name.Name
		}
		var ins []insertion
		for _, m := range byFile[file] {
			if n := strings.Count(src, m.Old); n != 1 {
				out.Errors = append(out.Errors, failure{m.ID, fmt.Sprintf("原文在 %s 里出现 %d 次,要恰好 1 次", file, n)})
				continue
			}
			start := strings.Index(src, m.Old)
			end := start + len(m.Old)
			if names := orphanedImports(f, src[:start]+m.New+src[end:]); len(names) > 0 {
				out.Notes = append(out.Notes, failure{m.ID, "删掉了 " + strings.Join(names, "、") + " 在这个文件里的唯一用法,单独编译会因 import 没用上编不过,这里按行为判"})
			}
			h := innermostHost(fset, f, start, end)
			if forced[m.ID] || h == nil {
				reason := "不在任何函数体里"
				if forced[m.ID] {
					reason = "指定单独编译"
				}
				dst := filepath.Join(in.Out, "classic-"+m.ID, file)
				write(dst, src[:start]+m.New+src[end:])
				out.Classic = append(out.Classic, classic{m.ID, path, dst, reason})
				continue
			}
			ins = append(ins, insertion{h.lbrace + 1, m.ID, guardText(src, h, start, end, m, in.SwitchVar), h.name})
		}
		if len(ins) == 0 {
			continue
		}
		// 同一个位置的几段按 id 原序排,不同位置按偏移从前往后拼,顺带记下每段落在生成文件的第几行。
		sort.SliceStable(ins, func(i, j int) bool { return ins[i].offset < ins[j].offset })
		var b strings.Builder
		prev := 0
		for _, x := range ins {
			b.WriteString(src[prev:x.offset])
			prev = x.offset
			startLine := strings.Count(b.String(), "\n") + 1
			b.WriteString(x.text)
			endLine := strings.Count(b.String(), "\n") + 1
			out.Guards = append(out.Guards, guard{x.id, path, startLine, endLine, x.fn})
		}
		b.WriteString(src[prev:])
		dst := filepath.Join(in.Out, "schemata", file)
		write(dst, b.String())
		out.Overlay[path] = dst
	}
	if len(out.Overlay) > 0 {
		sw := filepath.Join(in.Out, "schemata", "zz_go_mutate_switch.go")
		write(sw, fmt.Sprintf("package %s\n\nimport \"os\"\n\nvar %s = os.Getenv(%q)\n", pkgName, in.SwitchVar, in.Env))
		out.Overlay[filepath.Join(in.Dir, "zz_go_mutate_switch.go")] = sw
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", " ")
	if err := enc.Encode(out); err != nil {
		fail("写输出: %v", err)
	}
}

// innermostHost 找函数体完整包住 [start, end) 的最内层函数(具名函数或函数字面量)。
func innermostHost(fset *token.FileSet, f *ast.File, start, end int) *host {
	var best *host
	off := func(p token.Pos) int { return fset.Position(p).Offset }
	consider := func(name string, typ *ast.FuncType, body *ast.BlockStmt) {
		if body == nil {
			return
		}
		lb, rb := off(body.Lbrace), off(body.Rbrace)
		if !(lb < start && end <= rb) {
			return
		}
		if best != nil && rb-lb >= best.rbrace-best.lbrace {
			return
		}
		best = &host{name: name, lbrace: lb, rbrace: rb, hasResults: typ.Results != nil && typ.Results.NumFields() > 0}
		ast.Inspect(body, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.FuncLit:
				return false
			case *ast.LabeledStmt:
				best.labels = append(best.labels, labelUse{x.Label.Name, off(x.Label.Pos())})
			case *ast.BranchStmt:
				if x.Label != nil {
					best.labels = append(best.labels, labelUse{x.Label.Name, off(x.Label.Pos())})
				}
			}
			return true
		})
	}
	enclosing := ""
	ast.Inspect(f, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.FuncDecl:
			enclosing = x.Name.Name
			consider(x.Name.Name, x.Type, x.Body)
		case *ast.FuncLit:
			consider(enclosing+" 里的函数字面量", x.Type, x.Body)
		}
		return true
	})
	return best
}

// guardText 生成插在函数体开头的那一段:函数体副本里换掉变异那一处、标签改名,末尾补一个出口,
// 保证开关命中时不会落回原函数体。
func guardText(src string, h *host, start, end int, m mutant, switchVar string) string {
	type edit struct {
		at, n int
		text  string
	}
	// 换成的那段里如果也写了这个函数的标签(比如 continue L 改成 break L),同样改名。
	repl := m.New
	seen := map[string]bool{}
	for _, l := range h.labels {
		if seen[l.name] {
			continue
		}
		seen[l.name] = true
		name := regexp.QuoteMeta(l.name)
		renamed := l.name + "__m" + m.ID
		repl = regexp.MustCompile(`\b(break|continue|goto)(\s+)`+name+`\b`).ReplaceAllString(repl, "${1}${2}"+renamed)
		repl = regexp.MustCompile(`(?m)^(\s*)`+name+`:([^=]|$)`).ReplaceAllString(repl, "${1}"+renamed+":${2}")
	}
	edits := []edit{{start, end - start, repl}}
	for _, l := range h.labels {
		if l.offset+len(l.name) <= start || l.offset >= end {
			edits = append(edits, edit{l.offset, len(l.name), l.name + "__m" + m.ID})
		}
	}
	sort.Slice(edits, func(i, j int) bool { return edits[i].at > edits[j].at })
	body := src[h.lbrace+1 : h.rbrace]
	for _, e := range edits {
		at := e.at - (h.lbrace + 1)
		body = body[:at] + e.text + body[at+e.n:]
	}
	exit := "return"
	if h.hasResults {
		exit = `panic("go-mutate: 变异副本走到了末尾")`
	}
	return "\nif " + switchVar + " == " + strconv.Quote(m.ID) + " {" + body + "\n" + exit + "\n}\n"
}

// orphanedImports 返回变异删掉了唯一用法的导入包。原函数体还留在开关后面,这些包照样算用上了,
// 所以开关做法编得过;同一个变异单独编译会报 imported and not used。
func orphanedImports(f *ast.File, mutated string) []string {
	g, err := parser.ParseFile(token.NewFileSet(), "", mutated, parser.SkipObjectResolution)
	if err != nil {
		return nil
	}
	before, after := importUse(f), importUse(g)
	var names []string
	for name, used := range before {
		if used && !after[name] {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

// importUse 记下文件里每个导入包有没有以 name.X 的形式用到。只认得出名字的:带别名的和标准库
// (标准库的包名是路径最后一段,math/rand/v2 这种取 v2 前面那段)。
func importUse(f *ast.File) map[string]bool {
	use := map[string]bool{}
	for _, imp := range f.Imports {
		path, err := strconv.Unquote(imp.Path.Value)
		if err != nil {
			continue
		}
		name := ""
		parts := strings.Split(path, "/")
		switch {
		case imp.Name != nil:
			name = imp.Name.Name
		case !strings.Contains(parts[0], "."):
			name = parts[len(parts)-1]
			if len(parts) > 1 && regexp.MustCompile(`^v[0-9]+$`).MatchString(name) {
				name = parts[len(parts)-2]
			}
		}
		if name != "" && name != "_" && name != "." {
			use[name] = false
		}
	}
	ast.Inspect(f, func(n ast.Node) bool {
		if sel, ok := n.(*ast.SelectorExpr); ok {
			if id, ok := sel.X.(*ast.Ident); ok {
				if _, known := use[id.Name]; known {
					use[id.Name] = true
				}
			}
		}
		return true
	})
	return use
}

func write(path, content string) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		fail("建目录: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		fail("写文件: %v", err)
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "go-mutate-ast: "+format+"\n", args...)
	os.Exit(2)
}
