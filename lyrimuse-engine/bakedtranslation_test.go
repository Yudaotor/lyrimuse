package main

import (
	"fmt"
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

// 译文行紧挨着下一句原文(相差 60ms,落在 ±80ms 窗口里):逐字轨只能删译文行,原文行必须留着。
func TestStripBakedYRCKeepsOriginalRightAfterTranslation(t *testing.T) {
	var lrc, yrc strings.Builder
	en := make([]string, 10)
	zh := make([]string, 10)
	for i := range en {
		en[i] = fmt.Sprintf("placeholder original line number %d", i)
		zh[i] = fmt.Sprintf("占位译文第%d行", i)
	}
	ms := 15000
	for i := range en {
		trMs := ms + 1940
		fmt.Fprintf(&lrc, "%s%s\n%s%s\n", formatLRCStamp(ms), en[i], formatLRCStamp(trMs), zh[i])
		fmt.Fprintf(&yrc, "[%d,1900](%d,1900,0)%s\n[%d,60](%d,60,0)%s\n", ms, ms, en[i], trMs, trMs, zh[i])
		ms = trMs + 60
	}
	cleanLRC, _, cleanYRC, n := splitBakedTranslation(lrc.String(), yrc.String(), true)
	if n != len(zh) {
		t.Fatalf("baked lines = %d, want %d", n, len(zh))
	}
	heads := yrcLineHeads(cleanYRC)
	if len(heads) != len(en) {
		t.Fatalf("clean yrc has %d lines, want all %d original lines:\n%s", len(heads), len(en), cleanYRC)
	}
	for i, h := range heads {
		if h.text != en[i] {
			t.Fatalf("yrc line %d = %q, want %q", i, h.text, en[i])
		}
	}
	if got := len(yrcLineHeads(cleanLRC)); got != 0 {
		t.Fatalf("clean LRC should not parse as YRC, got %d", got)
	}
	if strings.Contains(cleanLRC, zh[2]) || !strings.Contains(cleanLRC, en[2]) {
		t.Fatalf("clean LRC wrong:\n%s", cleanLRC)
	}
}

// 酷我形态(占位文本):译文行挂在下一句原文的时间戳上,开头夹一行译文轨版权声明。判定成立之后:声明行从正文里丢掉;
// 夹着照搬原文专名的混合译文行照样按译文摘、挂回它那句原文的时间;专名不在上一句原文里的混合行不动。
func TestSplitBakedTranslationTakesMixedTranslationAndDropsNotice(t *testing.T) {
	l := []string{"[00:00.15]Placeholder Song - Someone", "[00:01.42]TME享有本翻译作品的著作权", "[00:01.42]Lyrics by：Someone"}
	for i := 0; i < 10; i++ {
		start, next := 8000+i*4000, 8000+(i+1)*4000
		switch i {
		case 4:
			l = append(l, formatLRCStamp(start)+`"Blue Moon" playing in the hall`, formatLRCStamp(next)+"走廊里回荡着《Blue Moon》的音乐声")
		case 7:
			l = append(l, formatLRCStamp(start)+"placeholder english line seven", formatLRCStamp(next)+"占位的第七行提到了 Tokyo")
		default:
			l = append(l, formatLRCStamp(start)+"placeholder english line "+string(rune('a'+i)), formatLRCStamp(next)+"占位中文译文第"+string(rune('一'+i))+"行")
		}
	}
	clean, tr, _, n := splitBakedTranslation(strings.Join(l, "\n"), "", true)
	if n != 9 {
		t.Fatalf("应摘掉 9 行译文(含夹专名的那行),实际 %d\n%s", n, clean)
	}
	if strings.Contains(clean, "著作权") {
		t.Error("译文轨的版权声明应从正文里丢掉")
	}
	if strings.Contains(clean, "走廊里") || !strings.Contains(tr, formatLRCStamp(8000+4*4000)+"走廊里回荡着《Blue Moon》的音乐声") {
		t.Errorf("夹专名的译文行应挂回它那句原文的时间:\nclean=%s\ntr=%s", clean, tr)
	}
	if !strings.Contains(clean, "提到了 Tokyo") || strings.Contains(tr, "Tokyo") {
		t.Errorf("专名不在上一句原文里的混合行应留在正文:\nclean=%s\ntr=%s", clean, tr)
	}
}

// 判定不成立(不是烘入译文)时,声明行与混合行都原样留着。
func TestSplitBakedTranslationLeavesNoticeWhenNotBaked(t *testing.T) {
	lrc := "[00:01.42]TME享有本翻译作品的著作权\n[00:05.00]only english here\n[00:09.00]走廊里回荡着《only》的音乐声"
	clean, _, _, n := splitBakedTranslation(lrc, "", true)
	if n != 0 || clean != lrc {
		t.Errorf("没判定为烘入译文时不该动正文: n=%d clean=%q", n, clean)
	}
}

// kuwoStampSample 合成酷我形态的一段(占位文本):每句原文后面跟一行译文,译文挂在下一句原文的时间戳上。
// pairs 是 {原文, 译文},译文为空就不带译文行;最后一句的译文挂在 start+len(pairs)*step 上,后面没有行。
func kuwoStampSample(head []string, pairs [][2]string, start, step int) string {
	l := append([]string{}, head...)
	for i, p := range pairs {
		t := start + i*step
		l = append(l, formatLRCStamp(t)+p[0])
		if p[1] != "" {
			l = append(l, formatLRCStamp(t+step)+p[1])
		}
	}
	return strings.Join(l, "\n")
}

func TestSplitSharedStampTranslationChineseSongWithForeignPart(t *testing.T) {
	lrc := strings.Join([]string{
		"[00:00.00]占位歌名 - 占位歌手",
		"[00:05.00]占位中文原词第一句",
		"[00:09.00]placeholder foreign line one",
		"[00:12.00]占位译文一",
		"[00:12.00]placeholder foreign line two",
		"[00:15.00]占位译文二",
		"[00:15.00]placeholder foreign line three",
		"[00:18.00]占位译文三",
		"[00:18.00]placeholder foreign line four",
		"[00:21.00]占位译文四",
		"[00:21.00]占位中文原词第二句",
		"[00:21.00]占位中文原词同时唱的一句",
		"[00:25.00]占位中文原词第三句",
	}, "\n")
	clean, tr, n := splitSharedStampTranslation(lrc, false)
	if n != 4 {
		t.Fatalf("应摘 4 行译文(含跟中文原词同一个时间戳的段尾那句),实际 %d:\n%s", n, clean)
	}
	wantClean := strings.Join([]string{
		"[00:00.00]占位歌名 - 占位歌手",
		"[00:05.00]占位中文原词第一句",
		"[00:09.00]placeholder foreign line one",
		"[00:12.00]placeholder foreign line two",
		"[00:15.00]placeholder foreign line three",
		"[00:18.00]placeholder foreign line four",
		"[00:21.00]占位中文原词第二句",
		"[00:21.00]占位中文原词同时唱的一句",
		"[00:25.00]占位中文原词第三句",
	}, "\n")
	if clean != wantClean {
		t.Errorf("中文原词要全留下(一句外文只认一行译文,后面同时唱的两句不算),只摘译文:\n%s", clean)
	}
	wantTr := "[00:09.00]占位译文一\n[00:12.00]占位译文二\n[00:15.00]占位译文三\n[00:18.00]占位译文四"
	if tr != wantTr {
		t.Errorf("译文要挂回原文行的时间戳:\n%s", tr)
	}
}

func TestSplitSharedStampTranslationTailAndThreshold(t *testing.T) {
	pairs := [][2]string{
		{"placeholder line one", "占位译文一"}, {"placeholder line two", "占位译文二"},
		{"placeholder line three", "占位译文三"}, {"placeholder line four", "占位译文四"},
	}
	// 外文段在全曲最后:最后一句的译文后面没有行,也算,但不计入门槛 —— 这里只有 3 行算数。
	lrc := kuwoStampSample(nil, pairs, 10000, 3000)
	if _, _, n := splitSharedStampTranslation(lrc, false); n != 0 {
		t.Fatalf("还不知道带译文时,不到 4 行(最后一行不算)不摘,实际摘了 %d", n)
	}
	clean, tr, n := splitSharedStampTranslation(lrc, true)
	if n != 4 || strings.Contains(clean, "占位译文") || !strings.Contains(tr, "[00:19.00]占位译文四") {
		t.Fatalf("已知带译文时一行也摘,最后一句挂回 00:19:n=%d\n%s\n---\n%s", n, clean, tr)
	}
	pairs = append(pairs, [2]string{"placeholder line five", "占位译文五"})
	clean, _, n = splitSharedStampTranslation(kuwoStampSample(nil, pairs, 10000, 3000), false)
	if n != 5 || strings.Contains(clean, "占位译文") {
		t.Fatalf("够 4 行就摘,最后一行一起摘:n=%d\n%s", n, clean)
	}
	// 最后那句外文前面是中文原词、不在一串译文里:收尾那行中文是原词,不摘。
	lone := kuwoStampSample(nil, pairs[:4], 10000, 3000) + "\n[00:22.00]占位中文原词\n[00:25.00]placeholder lone line" +
		"\n[00:28.00]占位中文结尾"
	clean, _, n = splitSharedStampTranslation(lone, false)
	if n != 4 || !strings.Contains(clean, "[00:28.00]占位中文结尾") || !strings.Contains(clean, "[00:22.00]占位中文原词") {
		t.Fatalf("不在一串译文里的收尾中文要留着:n=%d\n%s", n, clean)
	}
}

func TestSplitSharedStampTranslationMixedAndVocables(t *testing.T) {
	lrc := strings.Join([]string{
		"[00:10.00]Placeholder Name walks in",
		"[00:13.00]Placeholder Name 走进来了",
		"[00:13.00]Ooh",
		"[00:14.00]噢",
		"[00:14.00]placeholder line about gold",
		"[00:17.00]24K占位译文写满了汉字",
		"[00:17.00]placeholder line four",
		"[00:20.00]占位译文四",
		"[00:20.00]placeholder line five",
		"[00:23.00]占位译文五",
		"[00:23.00]placeholder line six",
		"[00:26.00]Placeholder 第六句的译文",
		"[00:26.00]Hee hee",
		"[00:28.00]placeholder ending line",
	}, "\n")
	clean, tr, n := splitSharedStampTranslation(lrc, false)
	if n != 6 {
		t.Fatalf("夹原文专名的、单字的、夹一个字母的都是译文,应摘 6 行,实际 %d:\n%s", n, clean)
	}
	for _, keep := range []string{"[00:13.00]Ooh", "[00:26.00]Hee hee", "[00:28.00]placeholder ending line"} {
		if !strings.Contains(clean, keep) {
			t.Errorf("没有译文的原文行要留着:%s\n%s", keep, clean)
		}
	}
	for _, want := range []string{"[00:10.00]Placeholder Name 走进来了", "[00:13.00]噢", "[00:14.00]24K占位译文写满了汉字",
		"[00:23.00]Placeholder 第六句的译文"} {
		if !strings.Contains(tr, want) {
			t.Errorf("译文缺 %s:\n%s", want, tr)
		}
	}
	// 只有拟声原文后面跟着中文时不算数:可能是合唱里同时唱的另一句。
	vocal := kuwoStampSample(nil, [][2]string{{"Ooh", "占位一"}, {"Yeah", "占位二"}, {"Oh oh", "占位三"},
		{"Woo", "占位四"}, {"Hey", "占位五"}}, 10000, 3000)
	if _, _, n := splitSharedStampTranslation(vocal, false); n != 0 {
		t.Fatalf("原文全是拟声行时不认,实际摘了 %d", n)
	}
}

func TestSplitSharedStampTranslationKeepsLabelsDropsNotice(t *testing.T) {
	lrc := kuwoStampSample([]string{
		"[00:00.00]Placeholder Song - Someone",
		"[00:01.40]TME享有本翻译作品的著作权",
		"[00:01.40]Lyrics by：Someone",
	}, [][2]string{
		{"placeholder line one", "占位译文一"}, {"placeholder line two", "占位译文二"},
		{"placeholder line three", "占位译文三"}, {"placeholder line four", "占位译文四"},
		{"placeholder call line", ""},
	}, 10000, 3000) + "\n[00:23.00]男：\n[00:23.00]占位中文原词\n[00:23.00]占位同时唱的一句" +
		"\n[00:26.00]placeholder another call\n[00:27.00]合 :\n[00:27.00]占位中文原词二"
	clean, tr, n := splitSharedStampTranslation(lrc, false)
	if n != 5 {
		t.Fatalf("4 行译文 + 1 行声明,实际 %d:\n%s", n, clean)
	}
	if strings.Contains(clean, "TME") || strings.Contains(tr, "TME") {
		t.Errorf("译文声明正文、译文里都不该有:\n%s\n---\n%s", clean, tr)
	}
	for _, keep := range []string{"[00:23.00]男：", "[00:23.00]占位中文原词", "[00:23.00]占位同时唱的一句",
		"[00:27.00]合 :", "[00:27.00]占位中文原词二",
		"[00:01.40]Lyrics by：Someone"} {
		if !strings.Contains(clean, keep) {
			t.Errorf("只有标签的行、中文原词、署名行都要留着:%s\n%s", keep, clean)
		}
	}
}

func TestAdoptKuwoBakedTranslationTakesLeftovers(t *testing.T) {
	var pairs [][2]string
	for i := 0; i < 10; i++ {
		zh := "占位中文译文第" + string(rune('一'+i)) + "行"
		if i == 3 || i == 7 {
			zh = "我"
		}
		pairs = append(pairs, [2]string{"placeholder english line " + string(rune('a'+i)), zh})
	}
	lrc := kuwoStampSample([]string{"[00:00.00]Placeholder Song - Someone"}, pairs, 10000, 3000)
	clean, tr, n := adoptKuwoBakedTranslation(lrc, true)
	if n != 10 {
		t.Fatalf("整首判断摘 8 行、剩下两行单字译文逐行摘,共 10 行,实际 %d:\n%s", n, clean)
	}
	if strings.Contains(clean, "我") || strings.Contains(clean, "占位中文译文") {
		t.Errorf("正文里还留着译文:\n%s", clean)
	}
	trLines := splitLyricLines(tr)
	if len(trLines) != 10 || trLines[3] != "[00:19.00]我" || trLines[7] != "[00:31.00]我" {
		t.Fatalf("两份译文按时间合成一份,单字译文挂回原文时间戳:\n%s", tr)
	}
	// 没有烘入译文的照旧原样。
	plain := kuwoStampSample(nil, [][2]string{{"placeholder line one", ""}, {"placeholder line two", ""}}, 10000, 3000)
	if c, tr, n := adoptKuwoBakedTranslation(plain, true); n != 0 || c != plain || tr != "" {
		t.Fatalf("没有译文行时不该动:n=%d", n)
	}
}

func TestMigrateKuwoSharedStampTranslation(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsTranslationLanguage = "zh"
	pairs := [][2]string{
		{"placeholder line one", "占位译文一"}, {"placeholder line two", "占位译文二"},
		{"placeholder line three", "占位译文三"}, {"placeholder line four", "占位译文四"},
		{"placeholder line five", "占位译文五"},
	}
	baked := kuwoStampSample(nil, pairs, 10000, 3000)
	wantClean, wantTr, _ := splitSharedStampTranslation(baked, false)
	leftover := "[00:05.00]placeholder line one\n[00:08.00]placeholder line two\n[00:11.00]我\n[00:11.00]placeholder line three"
	// 中文歌里只有一段外文、只译了一部分:摘出来的用不上(候选装配处也不会采纳),中文机翻留着。
	zhSong := kuwoStampSample([]string{"[00:01.00]占位中文原词第一句", "[00:03.00]占位中文原词第二句", "[00:05.00]占位中文原词第三句",
		"[00:07.00]占位中文原词第四句", "[00:08.00]占位中文原词第五句"}, pairs, 10000, 3000) + "\n[00:26.00]占位中文原词收尾" +
		"\n[00:28.00]placeholder untranslated one\n[00:31.00]placeholder untranslated two"
	// 中文歌里那段外文被自带译文译全了:用它,不留机翻。
	zhFull := strings.Join([]string{"[00:01.00]占位中文原词第一句", "[00:05.00]占位中文原词第二句",
		"[00:09.00]placeholder foreign line one", "[00:12.00]占位译文一", "[00:12.00]placeholder foreign line two",
		"[00:15.00]占位译文二", "[00:15.00]placeholder foreign line three", "[00:18.00]占位译文三",
		"[00:18.00]placeholder foreign line four", "[00:21.00]占位译文四", "[00:21.00]占位中文原词第三句"}, "\n")
	zhFullClean, zhFullTr, _ := splitSharedStampTranslation(zhFull, false)
	zhMachine := "[00:10.00]机翻一\n[00:13.00]机翻二\n[00:16.00]机翻三\n[00:19.00]机翻四\n[00:22.00]机翻五"
	zhClean, _, _ := splitSharedStampTranslation(zhSong, false)
	enrichMu.Lock()
	enrichPath = ""
	enrichCache["a|machine|b"] = enrichEntry{LyricsSource: "kuwo", Lyrics: baked, LyricsTr: "[00:10.00]机翻占位",
		LyricsTrSource: "machine", LyricsTrLang: "zh-CN", TranslationRetryCount: 1, TranslationTS: 123,
		TranslationLang: "zh-CN", LyricsRoma: "[00:10.00]zhan wei", LyricsYRC: "[10000,1000](10000,1000,0)x"}
	enrichCache["a|own|b"] = enrichEntry{LyricsSource: "kuwo", Lyrics: leftover, LyricsTr: "[00:05.00]已有译文", LyricsTrLang: "zh"}
	enrichCache["a|zhsong|b"] = enrichEntry{LyricsSource: "kuwo", Lyrics: zhSong, LyricsTr: zhMachine, LyricsTrSource: "machine",
		LyricsTrLang: "zh-CN", TranslationRetryCount: 1, LyricsRoma: "[00:05.00]zhan wei"}
	enrichCache["a|zhfull|b"] = enrichEntry{LyricsSource: "kuwo", Lyrics: zhFull, LyricsTr: "[00:09.00]机翻", LyricsTrSource: "machine",
		LyricsTrLang: "zh-CN", TranslationRetryCount: 1}
	enrichCache["a|manual|b"] = enrichEntry{LyricsSource: "kuwo", Lyrics: baked, ManualLyrics: true}
	enrichCache["a|qq|b"] = enrichEntry{LyricsSource: "qq", Lyrics: baked}
	enrichCache["a|pick|b"] = enrichEntry{LyricsSource: "kuwo", Lyrics: baked, ManualPickSHA: manualPickFingerprint(baked)}
	enrichDirty = false
	enrichMu.Unlock()
	migrateKuwoSharedStampTranslation()

	e := enrichCache["a|machine|b"]
	if e.Lyrics != wantClean || e.LyricsTr != wantTr || e.LyricsTrSource != "" || e.LyricsTrLang != "zh" {
		t.Fatalf("机翻换成摘出来的译文,语言记 zh: %+v", e)
	}
	if e.TranslationRetryCount != 0 || e.TranslationTS != 0 || e.TranslationLang != "" || e.LyricsRoma != "" {
		t.Fatalf("机翻重试计数、读音都清掉: %+v", e)
	}
	if e.LyricsYRC != "[10000,1000](10000,1000,0)x" {
		t.Fatal("逐字轨不动")
	}
	own := enrichCache["a|own|b"]
	if strings.Contains(own.Lyrics, "我") || own.LyricsTr != "[00:05.00]已有译文\n[00:08.00]我" || own.LyricsTrLang != "zh" {
		t.Fatalf("已有自带译文的剩一行也摘,按时间并进去: %+v", own)
	}
	zh := enrichCache["a|zhsong|b"]
	if zh.Lyrics != zhClean || zh.LyricsTr != zhMachine || zh.LyricsTrSource != "machine" || zh.TranslationRetryCount != 1 ||
		zh.LyricsRoma != "" {
		t.Fatalf("摘出来的用不上时中文机翻留着、正文照摘、读音清掉: %+v", zh)
	}
	if f := enrichCache["a|zhfull|b"]; f.Lyrics != zhFullClean || f.LyricsTr != zhFullTr || f.LyricsTrSource != "" ||
		f.LyricsTrLang != "zh" || f.TranslationRetryCount != 0 {
		t.Fatalf("中文歌里那段外文被自带译文译全了:换成它: %+v", f)
	}
	if enrichCache["a|manual|b"].Lyrics != baked || enrichCache["a|qq|b"].Lyrics != baked {
		t.Fatal("手动锁定的、别的源的不动")
	}
	if p := enrichCache["a|pick|b"]; p.Lyrics != wantClean || p.ManualPickSHA != manualPickFingerprint(wantClean) {
		t.Fatalf("选定留痕跟着新正文: %+v", p)
	}
	if !enrichDirty {
		t.Fatal("改过就置脏")
	}
	enrichMu.Lock()
	enrichCache["a|later|b"] = enrichEntry{LyricsSource: "kuwo", Lyrics: baked}
	enrichMu.Unlock()
	migrateKuwoSharedStampTranslation()
	if enrichCache["a|later|b"].Lyrics != baked {
		t.Fatal("有水位之后不再跑")
	}
}

func TestMigrateKuwoSharedStampTranslationOtherTarget(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsTranslationLanguage = "ja"
	pairs := [][2]string{
		{"placeholder line one", "占位译文一"}, {"placeholder line two", "占位译文二"},
		{"placeholder line three", "占位译文三"}, {"placeholder line four", "占位译文四"},
		{"placeholder line five", "占位译文五"},
	}
	baked := kuwoStampSample(nil, pairs, 10000, 3000)
	enrichMu.Lock()
	enrichPath = ""
	enrichCache["a|ja|b"] = enrichEntry{LyricsSource: "kuwo", Lyrics: baked, LyricsTr: "[00:10.00]日本語の占位", LyricsTrSource: "machine",
		LyricsTrLang: "ja", TranslationRetryCount: 2, TranslationTS: 9, TranslationLang: "ja"}
	enrichMu.Unlock()
	migrateKuwoSharedStampTranslation()
	e := enrichCache["a|ja|b"]
	if strings.Contains(e.Lyrics, "占位译文") {
		t.Fatalf("正文照摘: %q", e.Lyrics)
	}
	if e.LyricsTr != "" || e.LyricsTrSource != "" || e.LyricsTrLang != "" || e.TranslationRetryCount != 0 || e.TranslationTS != 0 {
		t.Fatalf("目标语言不是中文:按旧正文翻的日文机翻清掉、重试计数归零,交给补翻: %+v", e)
	}
}

func TestKuwoBakedTranslationCovers(t *testing.T) {
	lyrics := strings.Join([]string{"[00:01.00]占位中文原词第一句", "[00:09.00]placeholder foreign line one",
		"[00:12.00]placeholder foreign line two", "[00:15.00]placeholder foreign line three",
		"[00:18.00]placeholder foreign line four", "[00:21.00]占位中文原词第二句"}, "\n")
	full := "[00:09.00]占位译文一\n[00:12.00]占位译文二\n[00:15.00]占位译文三\n[00:18.00]占位译文四"
	part := "[00:09.00]占位译文一\n[00:12.00]占位译文二"
	if !kuwoBakedTranslationCovers(lyrics, full, "zh", "占位歌手", "占位歌名") {
		t.Error("要翻的外文行全有自带译文:用它")
	}
	if kuwoBakedTranslationCovers(lyrics, part, "zh", "占位歌手", "占位歌名") {
		t.Error("只译了一半:交给机翻")
	}
	if kuwoBakedTranslationCovers(lyrics, full, "ja", "占位歌手", "占位歌名") {
		t.Error("目标语言不是中文:中文译文用不上")
	}
	if kuwoBakedTranslationCovers(lyrics, "", "zh", "占位歌手", "占位歌名") ||
		kuwoBakedTranslationCovers("[00:01.00]全是中文的一句", "[00:01.00]x", "zh", "占位歌手", "占位歌名") {
		t.Error("没有译文、或者没有要翻的行:不算")
	}
}
