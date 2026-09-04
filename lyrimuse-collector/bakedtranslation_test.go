package main

import (
	"strings"
	"testing"
)

// 合成一份"外文原文 + 逐行中文译文烘在一起"的正文(占位文本,不是任何真实歌词),形态照
// QQ《Diamonds and Pearls (2023 Remaster)》那条(见 bakedtranslation.go 头注):译文行时间戳落在原文
// 行后 ~2s,QRC 逐字轨同样含译文行(每字 66ms 假计时)。
func bakedSample(pairs int, withTr bool) (lrc, yrc string) {
	var l, y []string
	l = append(l, "[ti:占位标题]", "[00:00.00]Placeholder Song - Someone", "[00:17.07]Lyrics by：Someone")
	y = append(y, "[ti:占位标题]")
	for i := 0; i < pairs; i++ {
		start := 36000 + i*6000
		en := "placeholder english line number " + string(rune('a'+i%26))
		zh := "占位中文译文第" + string(rune('一'+i%9)) + "行"
		l = append(l, formatLRCStamp(start)+en)
		y = append(y, "["+itoa(start)+",2260]("+itoa(start)+",270,0)placeholder("+itoa(start+270)+",300,0) english("+itoa(start+570)+",300,0) line")
		if withTr {
			l = append(l, formatLRCStamp(start+2260)+zh)
			y = append(y, "["+itoa(start+2260)+",660]("+itoa(start+2260)+",66,0)占("+itoa(start+2326)+",66,0)位("+itoa(start+2392)+",66,0)中")
		}
	}
	return strings.Join(l, "\n"), strings.Join(y, "\n")
}

func TestSplitBakedTranslationSplits(t *testing.T) {
	lrc, yrc := bakedSample(12, true)
	clean, tr, cleanYRC, n := splitBakedTranslation(lrc, yrc, true)
	if n != 12 {
		t.Fatalf("应摘掉 12 行译文,实际 %d", n)
	}
	for _, line := range splitLyricLines(clean) {
		if strings.Contains(line, "占位中文译文") {
			t.Errorf("正文里还残留译文行: %q", line)
		}
	}
	if !strings.Contains(clean, "[00:00.00]Placeholder Song - Someone") || !strings.Contains(clean, "[00:17.07]Lyrics by：Someone") || !strings.Contains(clean, "[ti:占位标题]") {
		t.Errorf("标题行/署名行/元数据行不该被动到:\n%s", clean)
	}
	trLines := splitLyricLines(tr)
	if len(trLines) != 12 {
		t.Fatalf("译文应有 12 行,实际 %d:\n%s", len(trLines), tr)
	}
	// 译文必须挂回**原文行**的时间戳(App 侧按最近邻贴行),不是上传者那个偏 2 秒的戳。
	if !strings.HasPrefix(trLines[0], "[00:36.00]占位中文译文第一行") {
		t.Errorf("第一行译文应挂在原文行的 [00:36.00] 上,实际 %q", trLines[0])
	}
	for _, line := range strings.Split(cleanYRC, "\n") {
		if yrcLineTimeRegex.MatchString(line) && strings.Contains(line, "占") {
			t.Errorf("逐字轨里的译文行没摘干净: %q", line)
		}
	}
	if !strings.Contains(cleanYRC, "[36000,2260]") || !strings.Contains(cleanYRC, "[ti:占位标题]") {
		t.Errorf("逐字轨的原文行/元数据行不该被动到:\n%s", cleanYRC)
	}
	if usableTr, _ := usableValueAdd(clean, tr, "zh", "", "zh"); !usableTr {
		t.Errorf("摘出来的译文应当能过 usableValueAdd(目标语言中文)")
	}
}

func TestSplitBakedTranslationLeavesGenuineLyricsAlone(t *testing.T) {
	// 1. 没有译文行的外文歌:原样。
	lrc, yrc := bakedSample(12, false)
	if _, _, _, n := splitBakedTranslation(lrc, yrc, true); n != 0 {
		t.Errorf("纯外文正文不该被摘: n=%d", n)
	}
	// 2. 中文歌(标签含汉字)里夹几行英文:标签不是外文歌、原文行也没有假名/谚文 → 不动。
	lrc, yrc = bakedSample(12, true)
	if _, _, _, n := splitBakedTranslation(lrc, yrc, false); n != 0 {
		t.Errorf("本地标签含汉字、原文又不是日韩文时不该摘: n=%d", n)
	}
	// 3. 行数不够(只有 5 对):证据不足,不动。
	lrc, yrc = bakedSample(5, true)
	if _, _, _, n := splitBakedTranslation(lrc, yrc, true); n != 0 {
		t.Errorf("不到 8 对时不该摘: n=%d", n)
	}
	// 4. 中文行只零星出现(12 行英文 + 3 行中文):比例不到,不动。
	var l []string
	for i := 0; i < 12; i++ {
		l = append(l, formatLRCStamp(36000+i*6000)+"placeholder english line "+string(rune('a'+i)))
		if i%4 == 0 {
			l = append(l, formatLRCStamp(36000+i*6000+2000)+"占位中文歌词一句")
		}
	}
	if _, _, _, n := splitBakedTranslation(strings.Join(l, "\n"), "", true); n != 0 {
		t.Errorf("中英比例悬殊时不该摘: n=%d", n)
	}
	// 5. 真双语歌形态:段落级交错(先 8 行英文再 8 行中文),不是逐句一比一 → 紧跟比例不够,不动。
	l = nil
	for i := 0; i < 8; i++ {
		l = append(l, formatLRCStamp(36000+i*3000)+"placeholder english line "+string(rune('a'+i)))
	}
	for i := 0; i < 8; i++ {
		l = append(l, formatLRCStamp(70000+i*3000)+"占位中文歌词第"+string(rune('一'+i))+"句")
	}
	if _, _, _, n := splitBakedTranslation(strings.Join(l, "\n"), "", true); n != 0 {
		t.Errorf("段落级中英交错(真双语歌)不该摘: n=%d", n)
	}
}

func TestSplitBakedTranslationJapaneseByKana(t *testing.T) {
	// 日文歌用汉字标歌名,标签判不出是外文歌;原文行带假名就够了。
	var l []string
	for i := 0; i < 10; i++ {
		l = append(l, formatLRCStamp(30000+i*5000)+"占位のひらがな歌词行"+string(rune('a'+i)))
		l = append(l, formatLRCStamp(30000+i*5000+1500)+"占位中文译文第"+string(rune('一'+i%9))+"行")
	}
	_, tr, _, n := splitBakedTranslation(strings.Join(l, "\n"), "", false)
	if n != 10 || len(splitLyricLines(tr)) != 10 {
		t.Errorf("带假名的日文原文 + 中文译文应被拆开: n=%d tr=%d 行", n, len(splitLyricLines(tr)))
	}
}

func TestAdoptBakedTranslationKeepsSourceTranslation(t *testing.T) {
	lrc, yrc := bakedSample(10, true)
	// 源自己有译文轨时不覆盖;没有时接上摘出来的;acceptTr=false 只摘不接。
	if _, tr, _, n := adoptBakedTranslation(lrc, "[00:36.00]源自带译文", yrc, true, true); n != 10 || tr != "[00:36.00]源自带译文" {
		t.Errorf("源自带译文不该被覆盖: n=%d tr=%q", n, tr)
	}
	if _, tr, _, n := adoptBakedTranslation(lrc, "", yrc, true, true); n != 10 || tr == "" {
		t.Errorf("源没有译文时应接上摘出来的: n=%d tr=%q", n, tr)
	}
	if clean, tr, _, n := adoptBakedTranslation(lrc, "", yrc, true, false); n != 10 || tr != "" || strings.Contains(clean, "占位中文译文") {
		t.Errorf("acceptTr=false 应只摘不接: n=%d tr=%q", n, tr)
	}
}
