package main

import (
	"log"
	"regexp"
	"strings"
)

// 存量修复:qrcToYRC 旧实现在 YRC 里留下的**残缺两数字词条**。
//
// # 坏在哪
//
// 旧的 qrcToYRC 用一条正则 `([^\[\]()\n]+)\((\d+),(\d+)\)` 整份替换,词文本的字符类把
// `(` `)` 排除在外 —— 于是歌词里本身带括号的那个词匹配不上,该词条原样留着 QRC 的两数字写法
// 漏进 YRC。Adele《River Lea》署名行的真实产物:
//
//	(2778,463,0)Adele(3241,463,0) ((3704,463)(4167,463,0)阿…
//	                              上一行:词「(」没转,留下两数字的 (3704,463)
//
// 两层后果:① YRCParser 认不出那一段,逐字填色在该位置就是坏的;② 它把前一个**空白词条**
// 粘住 —— yrcMergeWhitespaceTokens 按三数字词条切分,切不出来就判「不用改」,那些空格于是
// 永远归并不掉。本机缓存实测 842 条 QQ 条目中招。
//
// # 怎么修
//
// 信息没丢,原地就能还原:被漏掉的词**只可能是连续的圆括号**(字符类里被排除的就是它们),
// 而它紧贴在两数字标记前面。所以「一段括号 + 两数字标记」重排成「三数字标记 + 那段括号」,
// 正是旧正则该做却没做的事。
//
// 只处理**真正的计时行**(`[行始,行长]` 开头)。`[kana:…]` 假名标注行里的 `(起始,时长)`
// 本来就是两数字格式、那是它的正常写法,误修会把假名标注打烂 —— 本机缓存里有 52 条酷狗条目
// 带这种行(排查时我一度把它们误统计成"残缺",别再踩)。
//
// # 为什么这是一次性的
//
// 源头(qrcToYRC)已经改成按标记位置切分、不再匹配词文本,新解析出来的 YRC 不会再有这种残缺。
// 所以它满足水位闸的两个前提 —— 幂等、且运行期不再产生,跑一遍就够(见 startupmigration.go)。
var qrcLeftoverTokenRe = regexp.MustCompile(`([()]+)\((\d+),(\d+)\)`)

// repairQRCLeftoverTokens 返回修好的 YRC 与"是否真的改过"。
func repairQRCLeftoverTokens(yrc string) (string, bool) {
	if yrc == "" || !strings.Contains(yrc, ")") {
		return yrc, false
	}
	lines := strings.Split(yrc, "\n")
	changed := false
	for i, line := range lines {
		// 只认 [行始,行长] 开头的计时行,把 [kana:…] / [ti:] 这些挡在外面。
		head := qrcLineHeadRegex.FindString(line)
		if head == "" {
			continue
		}
		body := line[len(head):]
		fixed := qrcLeftoverTokenRe.ReplaceAllString(body, "($2,$3,0)$1")
		if fixed == body {
			continue
		}
		lines[i] = head + fixed
		changed = true
	}
	if !changed {
		return yrc, false
	}
	return strings.Join(lines, "\n"), true
}

// migrateQRCLeftoverTokens 对整个 enrich 缓存跑一遍 repairQRCLeftoverTokens。
//
// 位置(main.go):必须排在 migrateYRCWhitespaceTokens **之前** —— 残缺词条修好之后,原先被它
// 粘住的空白词条才切得出来、才轮得到归并。
func migrateQRCLeftoverTokens() {
	if migrationDone(migrationQRCLeftoverTokens, migrationQRCLeftoverTokensVersion) {
		return
	}
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		repaired, ok := repairQRCLeftoverTokens(e.LyricsYRC)
		if !ok {
			continue
		}
		e.LyricsYRC = repaired
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		// 显式置脏,理由同 migrateYRCWhitespaceTokens:saveEnrichCache 只在 enrichDirty 时才真写盘,
		// 漏了这一步就会"每次开机都报修了 N 条、磁盘上纹丝不动"。
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("qrc leftover-token repair: fixed %d entries", fixed)
		saveEnrichCache()
	}
	markMigrationDone(migrationQRCLeftoverTokens, migrationQRCLeftoverTokensVersion)
}
