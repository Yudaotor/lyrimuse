package main

import (
	"encoding/json"
	"fmt"
	"maps"
	"reflect"
	"slices"
	"sort"
	"strings"
)

// 插件协议一致性用例里的「模式」。用例里的一条消息有两个用途:照脚本演的那一头把它变成具体的一行发出去
// (ppInstantiate),另一头收到一行时拿它核对(ppMatch)。格式的成文规格在协议文档「一致性用例的格式」一节。
//
// 普通 JSON 值按相等比:对象允许对方多出字段(逐层如此),数组要求等长、逐项比,数字按数值比。
// 只带一个以 $ 开头的键的对象是运算符,见 ppOperators。

// ppVars 是一头在一个用例里记下的变量($var):第一次出现时绑定,之后出现必须等于绑定的值。
type ppVars map[string]any

// ppFixtureValues 是 $fixture 取值的来源:这个用例的清单对象和拼好的脚本全文。
type ppFixtureValues struct {
	manifest any
	source   string
}

// ppOperators:运算符 → 它旁边还允许出现的键。
var ppOperators = map[string][]string{
	"$var":       {"sample"}, // 变量。发:已绑定用绑定值,否则用 sample 并绑定;收:已绑定必须相等,否则绑定收到的值
	"$any":       {"sample"}, // 必须存在、类型对得上(string / number / integer / boolean / object / array / any)。发:sample
	"$optional":  nil,        // 可以没有;有的话要匹配里面的模式。发:不带这个字段
	"$absent":    nil,        // 必须没有这个字段。发:不带
	"$exact":     nil,        // 里面是对象模式,对方不许多出字段
	"$unordered": nil,        // 数组,元素一一对应、顺序无关。发:按写的顺序
	"$contains":  nil,        // 数组,列出的每个模式各有一个不同的元素匹配,允许多出元素。发:只发列出的
	"$oneOf":     nil,        // 几个模式里匹配一个就行。发:第一个
	"$fixture":   nil,        // "manifest":这个用例的清单对象;"source":脚本全文(收的时候只要求是字符串)
}

// ppOperator 认出运算符对象。带 $ 键却不合规的对象(不认识的运算符、多出别的键)返回 error。
func ppOperator(p any) (op string, arg any, obj map[string]any, err error) {
	m, isObj := p.(map[string]any)
	if !isObj {
		return "", nil, nil, nil
	}
	for k := range m {
		if strings.HasPrefix(k, "$") {
			if op != "" {
				return "", nil, nil, fmt.Errorf("一个对象里有两个运算符:%s 和 %s", op, k)
			}
			op = k
		}
	}
	if op == "" {
		return "", nil, nil, nil
	}
	allowed, known := ppOperators[op]
	if !known {
		return "", nil, nil, fmt.Errorf("不认识的运算符 %s", op)
	}
	for k := range m {
		if k != op && !slices.Contains(allowed, k) {
			return "", nil, nil, fmt.Errorf("运算符 %s 旁边不该有 %q", op, k)
		}
	}
	return op, m[op], m, nil
}

// ppValidatePattern 在加载用例时把整棵模式过一遍:运算符都认识、参数形状对。
func ppValidatePattern(p any) error {
	op, arg, obj, err := ppOperator(p)
	if err != nil {
		return err
	}
	switch op {
	case "":
		switch v := p.(type) {
		case map[string]any:
			for k, child := range v {
				if err := ppValidatePattern(child); err != nil {
					return fmt.Errorf("%s: %w", k, err)
				}
			}
		case []any:
			for i, child := range v {
				if err := ppValidatePattern(child); err != nil {
					return fmt.Errorf("[%d]: %w", i, err)
				}
			}
		}
		return nil
	case "$var":
		if name, ok := arg.(string); !ok || name == "" {
			return fmt.Errorf("$var 要一个非空的名字")
		}
		return nil
	case "$any":
		kind, _ := arg.(string)
		if !slices.Contains([]string{"string", "number", "integer", "boolean", "object", "array", "any"}, kind) {
			return fmt.Errorf("$any 不认识的类型 %v", arg)
		}
		sample, has := obj["sample"]
		if !has {
			return fmt.Errorf("$any 要带 sample")
		}
		if !ppIsKind(sample, kind) {
			return fmt.Errorf("$any 的 sample 不是 %s", kind)
		}
		return nil
	case "$absent":
		if arg != true {
			return fmt.Errorf("$absent 只写 true")
		}
		return nil
	case "$optional":
		return ppValidatePattern(arg)
	case "$exact":
		if _, ok := arg.(map[string]any); !ok {
			return fmt.Errorf("$exact 里面要是对象")
		}
		return ppValidatePattern(arg)
	case "$unordered", "$contains", "$oneOf":
		list, ok := arg.([]any)
		if !ok || (op == "$oneOf" && len(list) == 0) {
			return fmt.Errorf("%s 要一个数组", op)
		}
		return ppValidatePattern(list)
	case "$fixture":
		if arg != "manifest" && arg != "source" {
			return fmt.Errorf("$fixture 只有 manifest 和 source")
		}
		return nil
	}
	return fmt.Errorf("运算符 %s 没有校验规则", op)
}

func ppIsKind(v any, kind string) bool {
	switch kind {
	case "any":
		return true
	case "string":
		_, ok := v.(string)
		return ok
	case "number":
		_, ok := v.(float64)
		return ok
	case "integer":
		f, ok := v.(float64)
		return ok && f == float64(int64(f))
	case "boolean":
		_, ok := v.(bool)
		return ok
	case "object":
		_, ok := v.(map[string]any)
		return ok
	case "array":
		_, ok := v.([]any)
		return ok
	}
	return false
}

// ppInstantiate 把模式变成要发出去的具体值。present 为 false 表示这个字段不发($optional / $absent)。
func ppInstantiate(p any, vars ppVars, fx *ppFixtureValues) (v any, present bool, err error) {
	op, arg, obj, err := ppOperator(p)
	if err != nil {
		return nil, false, err
	}
	switch op {
	case "":
		switch pv := p.(type) {
		case map[string]any:
			out := make(map[string]any, len(pv))
			for k, child := range pv {
				cv, has, err := ppInstantiate(child, vars, fx)
				if err != nil {
					return nil, false, fmt.Errorf("%s: %w", k, err)
				}
				if has {
					out[k] = cv
				}
			}
			return out, true, nil
		case []any:
			out := make([]any, 0, len(pv))
			for i, child := range pv {
				cv, has, err := ppInstantiate(child, vars, fx)
				if err != nil {
					return nil, false, fmt.Errorf("[%d]: %w", i, err)
				}
				if !has {
					return nil, false, fmt.Errorf("[%d]: 数组元素不能是 $optional / $absent", i)
				}
				out = append(out, cv)
			}
			return out, true, nil
		}
		return p, true, nil
	case "$var":
		name := arg.(string)
		if bound, ok := vars[name]; ok {
			return bound, true, nil
		}
		sample, has := obj["sample"]
		if !has {
			return nil, false, fmt.Errorf("变量 %s 还没绑定、这里又没有 sample", name)
		}
		vars[name] = sample
		return sample, true, nil
	case "$any":
		return obj["sample"], true, nil
	case "$optional", "$absent":
		return nil, false, nil
	case "$exact":
		return ppInstantiate(arg, vars, fx)
	case "$unordered", "$contains":
		return ppInstantiate(arg, vars, fx)
	case "$oneOf":
		return ppInstantiate(arg.([]any)[0], vars, fx)
	case "$fixture":
		if arg == "manifest" {
			return fx.manifest, true, nil
		}
		return fx.source, true, nil
	}
	return nil, false, fmt.Errorf("运算符 %s 不会实例化", op)
}

// ppMatch 拿模式核对收到的值。has 为 false 表示对方没带这个字段。不匹配时返回带路径的 error;
// 匹配成功才把新绑定的变量写进 vars。
func ppMatch(p, v any, has bool, vars ppVars, fx *ppFixtureValues, path string) error {
	trial := maps.Clone(vars)
	if err := ppMatchInto(p, v, has, trial, fx, path); err != nil {
		return err
	}
	maps.Copy(vars, trial)
	return nil
}

func ppMatchInto(p, v any, has bool, vars ppVars, fx *ppFixtureValues, path string) error {
	op, arg, _, err := ppOperator(p)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	if op == "$absent" {
		if has {
			return fmt.Errorf("%s: 不该有这个字段,收到 %s", path, ppBrief(v))
		}
		return nil
	}
	if op == "$optional" {
		if !has {
			return nil
		}
		return ppMatchInto(arg, v, true, vars, fx, path)
	}
	if !has {
		return fmt.Errorf("%s: 缺这个字段", path)
	}
	switch op {
	case "":
		switch pv := p.(type) {
		case map[string]any:
			obj, ok := v.(map[string]any)
			if !ok {
				return fmt.Errorf("%s: 要对象,收到 %s", path, ppBrief(v))
			}
			for _, k := range ppSortedKeys(pv) {
				child, childHas := obj[k]
				if err := ppMatchInto(pv[k], child, childHas, vars, fx, path+"."+k); err != nil {
					return err
				}
			}
			return nil
		case []any:
			list, ok := v.([]any)
			if !ok {
				return fmt.Errorf("%s: 要数组,收到 %s", path, ppBrief(v))
			}
			if len(list) != len(pv) {
				return fmt.Errorf("%s: 要 %d 个元素,收到 %d 个", path, len(pv), len(list))
			}
			for i := range pv {
				if err := ppMatchInto(pv[i], list[i], true, vars, fx, fmt.Sprintf("%s[%d]", path, i)); err != nil {
					return err
				}
			}
			return nil
		}
		if !reflect.DeepEqual(p, v) {
			return fmt.Errorf("%s: 要 %s,收到 %s", path, ppBrief(p), ppBrief(v))
		}
		return nil
	case "$var":
		name := arg.(string)
		if bound, ok := vars[name]; ok {
			if !reflect.DeepEqual(bound, v) {
				return fmt.Errorf("%s: 变量 %s 是 %s,收到 %s", path, name, ppBrief(bound), ppBrief(v))
			}
			return nil
		}
		vars[name] = v
		return nil
	case "$any":
		if !ppIsKind(v, arg.(string)) {
			return fmt.Errorf("%s: 要 %s,收到 %s", path, arg, ppBrief(v))
		}
		return nil
	case "$exact":
		obj, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("%s: 要对象,收到 %s", path, ppBrief(v))
		}
		want := arg.(map[string]any)
		for k := range obj {
			if _, listed := want[k]; !listed {
				return fmt.Errorf("%s: 多出字段 %q", path, k)
			}
		}
		return ppMatchInto(want, v, true, vars, fx, path)
	case "$unordered", "$contains":
		list, ok := v.([]any)
		if !ok {
			return fmt.Errorf("%s: 要数组,收到 %s", path, ppBrief(v))
		}
		want := arg.([]any)
		if op == "$unordered" && len(list) != len(want) {
			return fmt.Errorf("%s: 要 %d 个元素,收到 %d 个", path, len(want), len(list))
		}
		if !ppAssign(want, list, make([]bool, len(list)), vars, fx) {
			return fmt.Errorf("%s: 列出的 %d 个模式没法各配上一个不同的元素,收到 %s", path, len(want), ppBrief(v))
		}
		return nil
	case "$oneOf":
		var firstErr error
		for _, alt := range arg.([]any) {
			trial := maps.Clone(vars)
			err := ppMatchInto(alt, v, true, trial, fx, path)
			if err == nil {
				maps.Copy(vars, trial)
				return nil
			}
			if firstErr == nil {
				firstErr = err
			}
		}
		return fmt.Errorf("%s: 几个备选都不匹配(第一个:%w)", path, firstErr)
	case "$fixture":
		if arg == "source" {
			if _, ok := v.(string); !ok {
				return fmt.Errorf("%s: 要脚本全文(字符串),收到 %s", path, ppBrief(v))
			}
			return nil
		}
		return ppMatchInto(fx.manifest, v, true, vars, fx, path)
	}
	return fmt.Errorf("%s: 运算符 %s 不会匹配", path, op)
}

// ppAssign 给 want 里的每个模式各找一个还没用过的元素(回溯),找得到才把变量绑定写进 vars。
func ppAssign(want, list []any, used []bool, vars ppVars, fx *ppFixtureValues) bool {
	if len(want) == 0 {
		return true
	}
	for i, v := range list {
		if used[i] {
			continue
		}
		trial := maps.Clone(vars)
		if ppMatchInto(want[0], v, true, trial, fx, "") != nil {
			continue
		}
		used[i] = true
		if ppAssign(want[1:], list, used, trial, fx) {
			maps.Copy(vars, trial)
			return true
		}
		used[i] = false
	}
	return false
}

// ppBrief:报错里用的短写法。
func ppBrief(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	if len(b) > 160 {
		return string(b[:160]) + "…"
	}
	return string(b)
}

func ppSortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
