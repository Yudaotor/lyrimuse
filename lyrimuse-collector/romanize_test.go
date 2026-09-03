package main

import (
	"os"
	"strings"
	"testing"
)

// shouldGenerateHelperRoma 是这条特性唯一会造成破坏的地方(尤其"已有罗马音就不动"),
// 所以判据单独抽成纯函数并在这里穷举。
//
// ⚠️ 刻意**不测** maybeGenerateHelperRoma 本身:它要起 lyrics-romanize 子进程,而测试
// 二进制旁边没有那个 helper,直接测会因为"找不到 → 静默返回"而恒真通过 —— 那是一条
// 证明不了任何东西的测试。
func TestShouldGenerateHelperRoma(t *testing.T) {
	cases := []struct {
		name  string
		entry enrichEntry
		want  bool
	}{
		{"日文且没有罗马音 → 要生成",
			enrichEntry{Lyrics: "[00:01.00]君の名は"}, true},
		{"韩文且没有罗马音 → 要生成",
			enrichEntry{Lyrics: "[00:01.00]세상의 모서리"}, true},
		{"中文且没有罗马音 → 要生成",
			enrichEntry{Lyrics: "[00:01.00]我爱你"}, true},
		// 这一条是整个功能的安全底线:源自带罗马音、或粤拼已经填过,一律不动。
		{"已有罗马音 → 绝不覆盖",
			enrichEntry{Lyrics: "[00:01.00]君の名は", LyricsRoma: "[00:01.00]existing"}, false},
		{"没有歌词正文 → 不生成",
			enrichEntry{Lyrics: ""}, false},
		// 没有这道闸的话,每一首纯英文歌都要白起一次子进程。
		{"纯拉丁歌词 → 不值得起子进程",
			enrichEntry{Lyrics: "[00:01.00]I'll be there"}, false},
	}
	for _, c := range cases {
		e := c.entry
		if got := e.shouldGenerateHelperRoma(); got != c.want {
			t.Errorf("%s: shouldGenerateHelperRoma() = %v, want %v", c.name, got, c.want)
		}
	}
}

// maybeGenerateRoma 的**顺序**:粤拼先手,helper 只捡剩下的。
//
// 顺序反了不会报错,只会让粤语歌拿到一份 ICU 通用音译的普通话拼音 —— 粤语汉字走
// .toLatin 出来的读音完全不对,而且是静默的。这里用"粤拼填完之后 helper 的闸门必须
// 已经关上"来钉这条,不依赖 helper 是否存在。
func TestMaybeGenerateRomaPrefersJyutping(t *testing.T) {
	e := enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: "[00:01.00]我愛你"}
	e.maybeGenerateRoma()
	if e.LyricsRoma == "" {
		t.Fatal("粤语条目走完 maybeGenerateRoma 之后 LyricsRoma 仍为空,粤拼那一步没跑")
	}
	if !strings.Contains(e.LyricsRoma, "ngo5") {
		t.Errorf("粤语条目拿到的不是粤拼: %q", e.LyricsRoma)
	}
	if e.shouldGenerateHelperRoma() {
		t.Error("粤拼已经填好之后,helper 的闸门仍然是开的 —— 顺序或判据错了,粤语歌会被通用音译覆盖")
	}

	// 反面:非粤语的中文歌,粤拼不接手,闸门应该留给 helper。
	mandarin := enrichEntry{SongLanguage: songLanguageMandarin, Lyrics: "[00:01.00]我爱你"}
	mandarin.maybeGenerateJyutpingRoma()
	if mandarin.LyricsRoma != "" {
		t.Errorf("国语歌不该被粤拼填: %q", mandarin.LyricsRoma)
	}
	if !mandarin.shouldGenerateHelperRoma() {
		t.Error("国语歌应该交给 helper 生成拼音,闸门却是关的")
	}
}

// 凡是会改 enrichCache 再调 saveEnrichCache 的 CLI,都必须置 enrichDirty —— 源码级契约闸。
//
// 为什么要机械闸而不是靠人记:saveEnrichCache() 开头是 `if !enrichDirty { return }`,漏置
// 的表现是**静默不落盘**,而同一条路径上的 exportLyricsFiles() 照常把文件写出去,于是
// "文件有、缓存没有"—— 下次启动 importLyricsFromFiles() 又把文件读回缓存,一切看起来正常。
// 也就是说这个 bug 在正常使用下**几乎观测不到**,只有盯着 cache 文件的 mtime 才发现。
//
// 2026-09-03 实测:新写的 backfill-roma 踩了一次,而 regenerate-jyutping **一直**带着这个
// bug(靠上面那条 import 侥幸兜住)。两个都修了,这条闸负责不让第三个出现。
func TestApplyCLIsMarkEnrichDirty(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}
	checked := 0
	for _, ent := range entries {
		name := ent.Name()
		if !strings.HasSuffix(name, "cli.go") {
			continue
		}
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		src := string(raw)
		// 判据:这份文件里有"往 enrichCache 里写"的形状,并且它自己调了 saveEnrichCache。
		if !strings.Contains(src, "enrichCache[") || !strings.Contains(src, "saveEnrichCache()") {
			continue
		}
		checked++
		if !strings.Contains(src, "enrichDirty = true") {
			t.Errorf("%s 改了 enrichCache 又调 saveEnrichCache,却没有置 enrichDirty —— "+
				"saveEnrichCache 会直接 return,表现是静默不落盘", name)
		}
	}
	// 一个都没扫到 = 判据本身失效了(文件改名/挪走),这条测试就成了永远绿的摆设。
	if checked < 2 {
		t.Errorf("只扫到 %d 个符合形状的 CLI,判据可能已经失效", checked)
	}
}
