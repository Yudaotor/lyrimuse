package main

import "testing"

// 2026-08-27 粤语歌兼容支持①:distinctRecordingVersionTags 补了"粤语/国语"词条前,
// 本地标题显式带"(粵語)"/"(國語)"标签时 versionTagsMismatch 认不出这是两次不同录音,
// 国语版歌词可能被错配给粤语音轨(反之亦然)。这里单独开一个文件而不是加进
// match_test.go 的 TestTitleVersionTags/TestVersionTagsMismatch,避免跟另一个并行
// 会话正在改动的那个文件冲突。
func TestTitleVersionTagsCantoneseMandarin(t *testing.T) {
	cases := []struct {
		title string
		want  []string
	}{
		{"K歌之王 (粵語)", []string{"粤语"}},
		{"K歌之王 (國語)", []string{"国语"}},
		// normLoose 内部先过 toSimplified,繁体标签折成简体后再比对,词表只需列简体。
		{"K歌之王 [粤语]", []string{"粤语"}},
		{"K歌之王 [国语]", []string{"国语"}},
		{"Beyond - Cantonese Version", []string{"cantonese"}},
		{"Beyond - Mandarin Version", []string{"mandarin"}},
		// 假阳性陷阱:限定词只在括号/破折号段里找,裸标题不该被误判。
		{"国语老歌精选", nil},
		{"粤语金曲", nil},
	}
	for _, c := range cases {
		got := titleVersionTags(c.title)
		if len(got) != len(c.want) {
			t.Errorf("titleVersionTags(%q) = %v, want %v", c.title, got, c.want)
			continue
		}
		for _, w := range c.want {
			if !got[w] {
				t.Errorf("titleVersionTags(%q) = %v, 缺 %q", c.title, got, w)
			}
		}
	}
}

func TestVersionTagsMismatchCantoneseMandarin(t *testing.T) {
	cases := []struct {
		label      string
		local      string
		candidate  string
		wantMismat bool
	}{
		{"国语 vs 粤语必须判不匹配", "K歌之王 (國語)", "K歌之王 (粵語)", true},
		{"粤语 vs 国语反向同理", "K歌之王 (粵語)", "K歌之王 (國語)", true},
		{"两边都是粤语", "K歌之王 (粵語)", "K歌之王 [粤语]", false},
		{"两边都干净不该误伤", "K歌之王", "K歌之王", false},
		{"英文标签同理", "Song (Cantonese Version)", "Song (Mandarin Version)", true},
	}
	for _, c := range cases {
		got := versionTagsMismatch(c.local, "", c.candidate, "")
		if got != c.wantMismat {
			t.Errorf("%s: versionTagsMismatch(%q, %q) = %v, want %v", c.label, c.local, c.candidate, got, c.wantMismat)
		}
	}
}

// 2026-08-27 粤语歌兼容支持②:QQ/酷狗接口自带的语种标签折算成
// songLanguageMandarin/songLanguageCantonese,用真实歌曲交叉验证过的取值见
// qqSongMeta.language 与 kugouSong.TransParam 的注释。
func TestQQCanonicalLanguage(t *testing.T) {
	cases := []struct {
		in   int
		want string
	}{
		{0, songLanguageMandarin},  // 陈奕迅《好久不见》、周杰伦《稻香》
		{1, songLanguageCantonese}, // 陈奕迅《浮夸》、Beyond《海阔天空》
		{5, ""},                    // Taylor Swift《Love Story》= 英语,不在本方案范围内
		{-1, ""},
		{99, ""},
	}
	for _, c := range cases {
		if got := qqCanonicalLanguage(c.in); got != c.want {
			t.Errorf("qqCanonicalLanguage(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestKugouCanonicalLanguage(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"国语", songLanguageMandarin},  // 周杰伦《稻香》
		{"粤语", songLanguageCantonese}, // Beyond《海阔天空》
		{"英语", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := kugouCanonicalLanguage(c.in); got != c.want {
			t.Errorf("kugouCanonicalLanguage(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
