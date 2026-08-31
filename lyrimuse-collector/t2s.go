// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bufio"
	"bytes"
	"embed"
	"strings"
)

// dictionary/TSCharacters.txt 和 dictionary/TSPhrases.txt 是 OpenCC
// (https://github.com/BYVoid/OpenCC,Apache-2.0 许可)项目的原始繁转简词典数据
// (单字级 + 词组级各一份),原样搬过来,不是这里重新编的。这两份数据文件之前是通过
// github.com/liuzl/gocc 这个 Go 移植版间接引入的(gocc 本身也是 Apache-2.0,只是转述了
// 同一份 OpenCC 数据),但 gocc 底层用来做前缀匹配的 github.com/liuzl/da →
// github.com/liuzl/cedar-go 这条依赖链是 GPL-2.0-only,跟本项目 GPLv3 的许可证不兼容
// (FSF 相容矩阵里两个"-only"版本的 GPL 互不相容)。这里直接内嵌同一份数据、自己实现
// 一个不需要 trie 加速的最长前缀匹配(下面 toSimplifiedT2S),彻底去掉这三个有问题的
// 间接依赖——效果经过逐条数据对拍验证跟原来 gocc 完全一致(见开发时用两份实现批量对比
// 4000+ 条词典数据 + 混合句子的验证过程),不是"看起来差不多"的近似替代。
//
// 2026-08-27 追加 dictionary/STCharacters.txt——同一个 OpenCC 项目、同一份许可证的
// 简→繁单字词典(方向相反),给 jyutping.go 的粤拼查表当兜底用(JyutpingChars.txt 主体
// 是繁体收字,简体歌词逐字查不到读音时先转一次繁体再查一次)。见 s2tCharMap 的注释。
//
//go:embed dictionary/TSCharacters.txt dictionary/TSPhrases.txt dictionary/STCharacters.txt
var t2sDictFS embed.FS

var (
	// t2sCharMap/t2sPhraseMap 只保留每个 key 的第一个候选(某些繁体字/词组可能对应
	// 多个简体候选,用空格分隔,如"乾\t干 乾"),跟 gocc 的 `token = v[0]` 取值规则
	// 完全一致——不是随便挑一个,是复刻原实现"总取第一候选"这个具体行为。
	t2sCharMap      map[string]string
	t2sPhraseMap    map[string]string
	t2sMaxPhraseLen int // TSPhrases.txt 里最长词条的 rune 长度,限定每个位置的搜索窗口
	// s2tCharMap:STCharacters.txt 的简→繁单字映射,同样只取每个键的第一个候选。
	// ⚠️ 简→繁本质是一对多(如"发"对应"發"/"髮"),这里跟 t2sCharMap 一样"只取第一个",
	// 挑的未必是具体这个字在这句里真正想要的那个繁体字——跟 App 侧 HanScript.swift 的
	// PlayCountVariants 处理同一类问题时的取舍一致,唯一消费方 jyutping.go 只拿它当"查不到
	// 读音时的兜底猜测",挑错的代价可接受,好过完全不转写。
	s2tCharMap map[string]string
)

func init() {
	t2sCharMap = loadT2SDict("dictionary/TSCharacters.txt")
	t2sPhraseMap = loadT2SDict("dictionary/TSPhrases.txt")
	s2tCharMap = loadT2SDict("dictionary/STCharacters.txt")
	for k := range t2sPhraseMap {
		if n := len([]rune(k)); n > t2sMaxPhraseLen {
			t2sMaxPhraseLen = n
		}
	}
}

// loadT2SDict 解析 "繁体\t简体候选1 简体候选2..." 格式的词典文件,跟 liuzl/da 的
// Build() 逐行解析规则一致(Tab 分隔取前两列,第二列按空白符切开取第一个)。词典文件本身
// 是编译期内嵌的常量数据,格式损坏(理论上不会发生,除非这两个文件被手动改坏)时静默跳过
// 那一行,不 panic——不影响整个进程启动。
func loadT2SDict(path string) map[string]string {
	m := map[string]string{}
	data, err := t2sDictFS.ReadFile(path)
	if err != nil {
		return m
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		items := strings.SplitN(line, "\t", 2)
		if len(items) < 2 {
			continue
		}
		fields := strings.Fields(items[1])
		if len(fields) == 0 {
			continue
		}
		m[items[0]] = fields[0]
	}
	return m
}

// toSimplifiedT2S 繁体转简体——每个位置优先按 TSPhrases 尝试最长可能的词组匹配(从
// t2sMaxPhraseLen 往下试到 2 个字,命中就跳过对应长度),词组没命中再查 TSCharacters
// 单字表,都没命中原样保留这个字符不动。跟 gocc 的 PrefixMatch+选最长+"当前字典没匹配
// 才试下一个字典"逻辑等价:gocc 里 TSPhrases 优先于 TSCharacters(数组顺序决定),这里
// 用"先试词组、词组完全没命中才退到单字"复刻同一个优先级,不是巧合写对,是照着
// opencc.go 的 Convert() 实现逐行对应写的。
func toSimplifiedT2S(s string) string {
	runes := []rune(s)
	var b strings.Builder
	b.Grow(len(s))
	i := 0
	for i < len(runes) {
		matched := false
		maxLen := t2sMaxPhraseLen
		if remain := len(runes) - i; remain < maxLen {
			maxLen = remain
		}
		for l := maxLen; l >= 2; l-- {
			candidate := string(runes[i : i+l])
			if repl, ok := t2sPhraseMap[candidate]; ok {
				b.WriteString(repl)
				i += l
				matched = true
				break
			}
		}
		if matched {
			continue
		}
		r := runes[i]
		if repl, ok := t2sCharMap[string(r)]; ok {
			b.WriteString(repl)
		} else {
			b.WriteRune(r)
		}
		i++
	}
	return b.String()
}
