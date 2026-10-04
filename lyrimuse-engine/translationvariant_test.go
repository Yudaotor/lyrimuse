package main

import (
	"strings"
	"testing"
)

// 繁体原文 + 只是简体转写的「译文」:整份都该去掉。
func TestDropScriptVariantLinesTraditionalToSimplified(t *testing.T) {
	orig := "[00:10.00]我在 這裡見怪更怪\n[00:14.00]見過電影裡面人家的海\n[00:18.00]你走了 只留下我雙眼的紅"
	tr := "[00:10.00]我在 这里见怪更怪\n[00:14.00]见过电影里面人家的海\n[00:18.00]你走了，只留下我双眼的红"
	if got := dropScriptVariantLines(orig, tr); got != "" {
		t.Errorf("繁简转写应整份去掉,实际剩下:\n%s", got)
	}
}

// 中文歌带英文副歌:中文行是照抄、英文行是真翻译。只能去掉照抄行,英文行的译文必须留下。
func TestDropScriptVariantLinesKeepsRealTranslationsInMixedSong(t *testing.T) {
	orig := "[00:10.00]我們的時光\n[00:14.00]It represent my heart\n[00:18.00]一起走過\n[00:22.00]Love love love"
	tr := "[00:10.00]我们的时光\n[00:14.00]它代表我的心\n[00:18.00]一起走过\n[00:22.00]爱 爱 爱"
	got := dropScriptVariantLines(orig, tr)
	want := "[00:14.00]它代表我的心\n[00:22.00]爱 爱 爱\n"
	if got != want {
		t.Errorf("混排歌只该去掉照抄行:\n got %q\nwant %q", got, want)
	}
}

// 正常的外语译文一行都不动。
func TestDropScriptVariantLinesLeavesRealTranslationAlone(t *testing.T) {
	orig := "[00:10.00]Hello from the other side\n[00:14.00]I must have called a thousand times"
	tr := "[00:10.00]来自另一边的问候\n[00:14.00]我一定打了上千次电话"
	got := dropScriptVariantLines(orig, tr)
	if strings.Count(got, "\n") != 2 || !strings.Contains(got, "来自另一边的问候") {
		t.Errorf("正常译文不该被改动,实际:\n%s", got)
	}
}

// 时间戳对不上的译文行不判(没有可比的原文行),原样保留。
func TestDropScriptVariantLinesKeepsUnalignedLines(t *testing.T) {
	orig := "[00:10.00]這裡"
	tr := "[00:11.00]这里"
	if got := dropScriptVariantLines(orig, tr); got != "[00:11.00]这里\n" {
		t.Errorf("对不上时间戳的行应保留,实际 %q", got)
	}
}

// 繁简同形字(「著」OpenCC 不单独转)与译者错字:两边都是汉字、只差一个字,也算换了写法。
func TestDropScriptVariantLinesNearHanVariants(t *testing.T) {
	orig := "[00:10.00]逼著自己早點睡\n[00:14.00]是不是我正好說中你的心?"
	tr := "[00:10.00]逼着自己早点睡\n[00:14.00]是不是我真好说中你的心？"
	if got := dropScriptVariantLines(orig, tr); got != "" {
		t.Errorf("只差一个字的中文行应去掉,实际剩下:\n%s", got)
	}
}

// 真正的中文改写(粤语改国语)用词差得远,不能当成换写法;4 个字以下只认完全相等。
func TestDropScriptVariantLinesKeepsCantoneseToMandarin(t *testing.T) {
	orig := "[00:10.00]佢哋唔知我幾咁鍾意你\n[00:14.00]我哋"
	tr := "[00:10.00]他们不知道我有多喜欢你\n[00:14.00]我们"
	got := dropScriptVariantLines(orig, tr)
	if strings.Count(got, "\n") != 2 {
		t.Errorf("粤语改国语的译文应全部保留,实际:\n%s", got)
	}
}
