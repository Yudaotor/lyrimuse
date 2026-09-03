package main

import (
	"embed"
	"strings"
)

// 异体字规范化——繁简转换**之外**的那一层。
//
// 病根(2026-09-03 用户报「为什么这首歌只能搜出一个来」,周杰伦《妳聽得到》):大陆
// 《第一批异体字整理表》淘汰、港台仍在用的那批字(「妳」「祂」「牠」…)不是某个简体字的
// 繁体,所以 OpenCC 的繁简词库压根没有它们的条目,`toSimplifiedT2S` 原样放过去。于是发给
// 网易云/QQ/酷狗的搜索词是「妳听得到」,而它们曲库里这首叫「你听得到」,三家一条都匹配
// 不上。实测 A/B(同一时刻、同一 duration,只改标题写法):
//
//	妳聽得到 / 周杰倫 / 葉惠美  → 只有 LRCLIB 给出候选
//	你听得到 / 周杰伦 / 叶惠美  → 酷狗 + 网易云 + QQ + LRCLIB
//	妳听得到 / 周杰伦 / 叶惠美  → 只有 LRCLIB   ← 单字隔离:艺人专辑全简体也没用
//
// ⚠️ 表是**推出来的,不是手工维护的**(用户要求:「做成通用逻辑,后续遇到这种字的问题都要
// 可以解决,不要通过手动维护一个表的方式」)。数据来自 Unicode Unihan 的区域集/变体关系
// 字段 + OpenCC 词库,推导规则和"为什么不手工列字"写在 scripts/gen-han-variants.py 的头注
// 里;产出的 dictionary/HanVariants.txt 同时也被 App 侧编译进去(见
// LyrimuseCore/Lyrics/HanVariantsTable.swift),**两侧是同一份数据**。
//
// ⚠️ 只做"异体 → 大陆规范"这一个方向。反向(简 → 繁/异体)绝不做:简体只有「你」,转过去
// 时无从判断该写「你」还是「妳」——那要猜被称呼者的性别,猜错就是改写歌词。
//
// ⚠️ 这一层挂在 `toSimplifiedT2S` 的**单字兜底分支**上(见那边),也就是只处理"OpenCC 词组
// 表和单字表都没管的字"。所以它永远不会覆盖 OpenCC 的判断,只填它留下的空。

//go:embed dictionary/HanVariants.txt
var hanVariantsFS embed.FS

// hanVariantMap:变体字 → 大陆规范字。空表是可接受的降级(等于这一层不存在),不 panic。
var hanVariantMap = loadHanVariants()

func loadHanVariants() map[rune]rune {
	out := map[rune]rune{}
	data, err := hanVariantsFS.ReadFile("dictionary/HanVariants.txt")
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// 列:变体字 \t 规范字 \t 数据依据 \t 缺口。后两列只是给人看的出处记录,这里不用。
		cols := strings.Split(line, "\t")
		if len(cols) < 2 {
			continue
		}
		src, dst := []rune(cols[0]), []rune(cols[1])
		if len(src) != 1 || len(dst) != 1 {
			continue // 这一层是逐字替换,多字条目一律跳过(生成器不该产出,防手改)
		}
		out[src[0]] = dst[0]
	}
	return out
}
