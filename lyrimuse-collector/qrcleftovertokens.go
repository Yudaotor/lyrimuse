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
// 能原地还原的只有一种:被漏掉的词是**连续的圆括号**、紧贴在两数字标记前面 ——「一段括号 + 两数字标记」
// 重排成「三数字标记 + 那段括号」。旧正则的字符类排除的其实不止圆括号,还有方括号和换行;带文字的括号词
// (`(Ooh)`)重排出来时间也是错位的;空文本的计时标记同样会漏。这些原地还原不了:修完计时行里还剩两数字
// 词条的,这一份逐字就当坏了 —— 清掉(连同挂在它上面的背景人声),让全量扫库 / 重评按「有词、没逐字」
// 重新去取,新的 qrcToYRC 转出来是对的(v2,见 migrateQRCLeftoverTokens)。本机实测还有二十来条是这样。
// 手改过的、校准过时间轴的不动。
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

// yrcTwoNumberTokenRe:计时行里残留的两数字词条(正常的逐字词条是三个数字)。
var yrcTwoNumberTokenRe = regexp.MustCompile(`\(\d+,\d+\)`)

// yrcHasTwoNumberTokens:计时行(`[行始,行长]` 开头)里还有没有两数字词条。`[kana:…]` 这类行的两数字是它的
// 正常写法,不看。
func yrcHasTwoNumberTokens(yrc string) bool {
	for _, line := range strings.Split(yrc, "\n") {
		head := qrcLineHeadRegex.FindString(line)
		if head != "" && yrcTwoNumberTokenRe.MatchString(line[len(head):]) {
			return true
		}
	}
	return false
}

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
	scope := migrationScopeOf(migrationQRCLeftoverTokens, migrationQRCLeftoverTokensVersion)
	if scope.skip() {
		return
	}
	pins := lyricsPinnedKeys() // 读文件,不能压在 enrichMu 里(见 lyricsPinnedKeys 头注)
	enrichMu.Lock()
	fixed, dropped := 0, 0
	for k, e := range scope.entries() {
		repaired, ok := repairQRCLeftoverTokens(e.LyricsYRC)
		if ok {
			e.LyricsYRC = repaired
			fixed++
		}
		drop := yrcHasTwoNumberTokens(e.LyricsYRC) && !e.ManualLyrics && !pins[k]
		if drop {
			e.LyricsYRC, e.LyricsBG = "", ""
			dropped++
		}
		if !ok && !drop {
			continue
		}
		enrichCache[k] = e
	}
	if dropped > 0 {
		log.Printf("qrc leftover-token repair: dropped unrecoverable word timing of %d entries, they will be fetched again", dropped)
	}
	if fixed+dropped > 0 {
		// 显式置脏,理由同 migrateYRCWhitespaceTokens:saveEnrichCache 只在 enrichDirty 时才真写盘,
		// 漏了这一步就会"每次开机都报修了 N 条、磁盘上纹丝不动"。
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed+dropped > 0 {
		log.Printf("qrc leftover-token repair: fixed %d entries", fixed)
		saveEnrichCache()
	}
	markMigrationDone(migrationQRCLeftoverTokens, migrationQRCLeftoverTokensVersion)
}
