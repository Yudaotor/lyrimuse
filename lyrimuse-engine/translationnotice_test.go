package main

import "testing"

func TestStripTranslationNotices(t *testing.T) {
	tr := "[00:00.000]TME享有本翻译作品的著作权\n[00:11.780]我想今天是完美的日子\n[00:14.268]我要为自己寻找美好的生活\n[00:16.892]因为昨日不堪回首"
	got, ok := stripTranslationNotices(tr)
	want := "[00:11.780]我想今天是完美的日子\n[00:14.268]我要为自己寻找美好的生活\n[00:16.892]因为昨日不堪回首"
	if !ok || got != want {
		t.Fatalf("got (%q, %v)", got, ok)
	}
	if again, ok := stripTranslationNotices(got); ok || again != got {
		t.Fatalf("应幂等,实际 (%q, %v)", again, ok)
	}
	// 正文里提到著作权但不是声明句的,不动。
	keep := "[00:01.00]著作权\n[00:02.00]b\n[00:03.00]c"
	if got, ok := stripTranslationNotices(keep); ok || got != keep {
		t.Fatalf("不该改,实际 (%q, %v)", got, ok)
	}
	// 译者声明跟在 [offset:] 后面也要删,[offset:] 留着。
	withOffset := "[offset:0]\n[00:00.00]以下歌词翻译由文曲大模型提供\n[00:01.00]a\n[00:02.00]b\n[00:03.00]c"
	if got, ok := stripTranslationNotices(withOffset); !ok || got != "[offset:0]\n[00:01.00]a\n[00:02.00]b\n[00:03.00]c" {
		t.Fatalf("got (%q, %v)", got, ok)
	}
	// 删完不够 3 行带戳就当没有译文。
	if got, ok := stripTranslationNotices("[00:00.00]腾讯享有本翻译作品的著作权\n[00:01.00]a\n[00:02.00]b"); !ok || got != "" {
		t.Fatalf("应清空,实际 (%q, %v)", got, ok)
	}
}

// 酷狗 KRC 译文轨第一项是版权声明时,出口要把它剔掉。
func TestKRCLanguageTrackDropsCopyrightNotice(t *testing.T) {
	content := [][]string{{"TME享有本翻译作品的著作权"}, {"一"}, {"二"}, {"三"}}
	got := krcLanguageTrackToLRC(content, []int{0, 1000, 2000, 3000})
	want := "[00:01.000]一\n[00:02.000]二\n[00:03.000]三"
	if got != want {
		t.Fatalf("got %q", got)
	}
}
