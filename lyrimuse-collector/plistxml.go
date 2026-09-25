package main

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// 最小的 plist XML 解析器,只为读懂 NSKeyedArchiver 归档(目前只有 QQ 音乐的播放队列在用)。
//
// ## 为什么是"转成 XML 再解",不是直接读 bplist
//
// 这个 module **零外部依赖**(见 qqlocal.go 里那段:读 sqlite 都是 exec /usr/bin/sqlite3),
// 而 Go 标准库没有 plist。系统自带的 plutil 能把 bplist 转出来,跟那边 exec sqlite3 是
// 同一个路数。
//
// 只能转 **xml1**,不能转 json:NSKeyedArchiver 里的对象引用(UID)在 JSON 里没有对应
// 表示,`plutil -convert json` 会直接报 "Invalid object in plist for JSON format"。
// XML 里它表示成 `<dict><key>CF$UID</key><integer>N</integer></dict>`,本解析器据此还原
// 成 plistUID。
//
// 支持的类型只覆盖归档里真实出现的那些:dict / array / string / integer / real /
// true / false / data / date。碰上没见过的标签整个跳过,不报错 —— 这份数据是别的 App 写的,
// 为一个用不上的字段让整轮解析失败不划算。

// plistUID 是 NSKeyedArchiver 的对象引用,取值是 $objects 数组的下标。
type plistUID uint64

// plistMaxDepth 防着构造出来的畸形文件把栈递归爆掉。真实归档嵌套个位数层。
const plistMaxDepth = 64

// parsePlistXML 解析 `plutil -convert xml1` 的输出,返回根节点。
func parsePlistXML(data []byte) (any, error) {
	dec := xml.NewDecoder(bytes.NewReader(data))
	// plist 的 DOCTYPE 指向 apple.com 上的 DTD。Strict=false 让解析器不去理会它,
	// 也不会尝试联网取 —— encoding/xml 本来就不解析外部实体,这里只是不为它报错。
	dec.Strict = false
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			return nil, errors.New("plist: 没找到 <plist> 根节点")
		}
		if err != nil {
			return nil, err
		}
		if se, ok := tok.(xml.StartElement); ok && se.Name.Local == "plist" {
			v, _, err := plistNextValue(dec, 0)
			return v, err
		}
	}
}

// plistNextValue 读下一个值。done=true 表示读到的是当前容器的结束标签,没有值。
func plistNextValue(dec *xml.Decoder, depth int) (any, bool, error) {
	if depth > plistMaxDepth {
		return nil, false, errors.New("plist: 嵌套太深")
	}
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			return nil, true, nil
		}
		if err != nil {
			return nil, false, err
		}
		switch t := tok.(type) {
		case xml.EndElement:
			return nil, true, nil
		case xml.StartElement:
			v, err := plistElement(dec, t, depth)
			return v, false, err
		}
		// CharData / Comment / Directive:容器之间的空白和 DOCTYPE,跳过。
	}
}

func plistElement(dec *xml.Decoder, se xml.StartElement, depth int) (any, error) {
	switch se.Name.Local {
	case "dict":
		return plistDict(dec, depth+1)
	case "array":
		return plistArray(dec, depth+1)
	case "string", "date":
		var s string
		err := dec.DecodeElement(&s, &se)
		return s, err
	case "integer":
		var s string
		if err := dec.DecodeElement(&s, &se); err != nil {
			return nil, err
		}
		n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("plist: integer %q: %w", s, err)
		}
		return n, nil
	case "real":
		var s string
		if err := dec.DecodeElement(&s, &se); err != nil {
			return nil, err
		}
		f, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
		if err != nil {
			return nil, fmt.Errorf("plist: real %q: %w", s, err)
		}
		return f, nil
	case "true":
		return true, dec.Skip()
	case "false":
		return false, dec.Skip()
	case "data":
		// 归档里的二进制块(图片、序列化的子对象)。队列这条路一个都用不上,原样跳过 ——
		// 解出来只是白占内存。
		return nil, dec.Skip()
	default:
		return nil, dec.Skip()
	}
}

func plistDict(dec *xml.Decoder, depth int) (any, error) {
	m := map[string]any{}
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			return m, nil
		}
		if err != nil {
			return nil, err
		}
		se, ok := tok.(xml.StartElement)
		if !ok {
			if _, end := tok.(xml.EndElement); end {
				return plistFoldUID(m), nil
			}
			continue
		}
		if se.Name.Local != "key" {
			// 结构不对(没有 key 就来值),跳过这个元素继续 —— 宁可少读一个字段也别整轮失败。
			if err := dec.Skip(); err != nil {
				return nil, err
			}
			continue
		}
		var key string
		if err := dec.DecodeElement(&key, &se); err != nil {
			return nil, err
		}
		v, done, err := plistNextValue(dec, depth)
		if err != nil {
			return nil, err
		}
		if done {
			// key 后面直接是 </dict>:文件坏了,把已读到的还回去。
			return plistFoldUID(m), nil
		}
		m[key] = v
	}
}

func plistArray(dec *xml.Decoder, depth int) (any, error) {
	var out []any
	for {
		v, done, err := plistNextValue(dec, depth)
		if err != nil {
			return nil, err
		}
		if done {
			return out, nil
		}
		out = append(out, v)
	}
}

// plistFoldUID 把 `{"CF$UID": N}` 这种单键字典折成 plistUID。NSKeyedArchiver 的对象引用
// 在 XML 里就是长这样,不折的话每次解引用都要在调用方重复判一遍。
func plistFoldUID(m map[string]any) any {
	if len(m) != 1 {
		return m
	}
	n, ok := m["CF$UID"].(int64)
	if !ok || n < 0 {
		return m
	}
	return plistUID(n)
}
