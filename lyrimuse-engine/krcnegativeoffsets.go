package main

import (
	"fmt"
	"log"
	"regexp"
	"strconv"
	"strings"
)

// 存量修复:krcToYRC 旧实现漏转的负偏移逐字标记。
//
// 酷狗 KRC 的词始偏移可能是负数(`<-11,116,0>`,这个字比行首早一点开始)。旧的 krcWordRegex 只认非负数字,这种
// 标记原样留在逐字数据里(`[60864,3000]<-11,116,0>就话(60980,873,0)886…`):YRCParser 认不出那一段,词的文字里
// 带着这串标记。
//
// 计时行的行始就在行首,原地换算成绝对时间(行始 + 偏移,不到 0 按 0),写成三数字词条。源头 krcToYRC 已经认负号,
// 新解析的不会再有,所以是一次性的(水位见 startupmigration.go)。见 09 章决策 148。
var krcNegativeOffsetTokenRe = regexp.MustCompile(`<(-\d+),(\d+),(\d+)>`)

// repairKRCNegativeOffsets 返回修好的 YRC 与"是否真的改过"。只认 [行始,行长] 开头的计时行。
func repairKRCNegativeOffsets(yrc string) (string, bool) {
	if !strings.Contains(yrc, "<-") {
		return yrc, false
	}
	lines := strings.Split(yrc, "\n")
	changed := false
	for i, line := range lines {
		m := qrcLineHeadRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		start, _ := strconv.Atoi(m[1])
		body := line[len(m[0]):]
		fixed := krcNegativeOffsetTokenRe.ReplaceAllStringFunc(body, func(tok string) string {
			t := krcNegativeOffsetTokenRe.FindStringSubmatch(tok)
			off, _ := strconv.Atoi(t[1])
			return fmt.Sprintf("(%d,%s,%s)", max(start+off, 0), t[2], t[3])
		})
		if fixed != body {
			lines[i] = m[0] + fixed
			changed = true
		}
	}
	if !changed {
		return yrc, false
	}
	return strings.Join(lines, "\n"), true
}

// migrateKRCNegativeOffsets 对整个 enrich 缓存跑一遍 repairKRCNegativeOffsets。
//
// 位置(main.go):排在 migrateYRCWhitespaceTokens **之前**,理由同 migrateQRCLeftoverTokens —— 标记修成三数字词条
// 之后,被它粘住的空白词条才切得出来。
func migrateKRCNegativeOffsets() {
	scope := migrationScopeOf(migrationKRCNegativeOffsets, migrationKRCNegativeOffsetsVersion)
	if scope.skip() {
		return
	}
	enrichMu.Lock()
	fixed := 0
	for k, e := range scope.entries() {
		repaired, ok := repairKRCNegativeOffsets(e.LyricsYRC)
		if !ok {
			continue
		}
		e.LyricsYRC = repaired
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		enrichDirty = true // 同 migrateQRCLeftoverTokens:不置脏 saveEnrichCache 不写盘
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("krc negative-offset repair: fixed %d entries", fixed)
		saveEnrichCache()
	}
	markMigrationDone(migrationKRCNegativeOffsets, migrationKRCNegativeOffsetsVersion)
}
