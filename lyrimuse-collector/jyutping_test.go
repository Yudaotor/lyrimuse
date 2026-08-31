package main

import "testing"

// 2026-08-30 review 坐实的真实 bug:jyut6ping3.words.dict.yaml 里混了 696 条带逗号/
// 顿号/句号的完整谚语("笑左，笑埋右"这类),toJyutpingLine 按 rune 窗口整段命中、整段
// 输出读音,标点没有对应音节,会被读音字符串顶替、从输出里凭空消失(修前
// toJyutpingLine("笑左，笑埋右") 吐出 "siu3 zo2 siu3 maai4 jau6",逗号没了)。
// isAllHan 是挡这类条目的闸门,直接测这个纯函数,不依赖具体挑哪个真实词条(词典内容
// 以后可能变)。
func TestIsAllHan(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"重要", true},
		{"這個", true},
		{"笑左，笑埋右", false},
		{"hee hee hur hur", false},
		{"重要3", false},
		{"", true}, // 空串没有反例字符,视为"全部满足"，跟 loadJyutpingWordDict 的
		// len<2 判断在它之前拦掉这种情况配合，isAllHan 自己不需要另外处理空串。
	}
	for _, c := range cases {
		if got := isAllHan(c.in); got != c.want {
			t.Errorf("isAllHan(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

// 数据完整性断言,不是逻辑断言:真实内嵌的 jyutpingWordMap(101000+ 词条)里不应该有
// 任何一个键带非汉字字符——不管是这次预处理脚本本身把关住了,还是 isAllHan 在加载时
// 兜住了,只要以后重新拉取上游数据换了这份 txt、又不小心把带标点的谚语条目带回来,
// 这条测试就会炸,而不是安安静静地在某首歌的歌词里吞掉一个逗号才被用户发现。
func TestJyutpingWordMapHasNoPunctuationKeys(t *testing.T) {
	for word := range jyutpingWordMap {
		if !isAllHan(word) {
			t.Fatalf("jyutpingWordMap contains a non-Han key %q — toJyutpingLine would silently drop its non-Han characters when this word matches", word)
		}
	}
}

// 2026-08-27 粤语歌兼容支持③:粤拼罗马音生成。断言用的读音都是从真实字典
// (dictionary/JyutpingChars.txt,来自 rime-cantonese)反查出来的已知值,而不是编造的——
// 这里测的是"代码有没有正确应用词典+间距规则",词典本身的语言学准确性由上游项目负责。
func TestToJyutpingLine(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"单字", "我", "ngo5"},
		{"多字连读", "我哋", "ngo5 dei6"},
		{"粤语虚词(HanVariants 里明确保留的那几个)", "唔該你", "m4 goi1 nei5"},
		{"拉丁词不该被拆开", "Baby 我爱你", "Baby ngo5 oi3 nei5"},
		{"标点前后都要有分隔", "你好，世界", "nei5 hou2 ， sai3 gaai3"},
		// 2026-08-30 加:"這個"在 JyutpingWords.txt 里单独收了 ze3 go3,跟"這"单字表的
		// ze2、以及"這般/這兒/這樣/這裏/這麼/這些"这些其它"這X"复合词的 ze2 都不一样——
		// 这正是词级消歧要解决的问题,不是巧合或者笔误。
		{"简体字走 s2t 兜底 + 命中词级消歧(這個≠這单字)", "这个世界", "ze3 go3 sai3 gaai3"},
		{"查不到读音的字符原样穿透", "我😀你", "ngo5 😀 nei5"},
		{"空串", "", ""},
		// 2026-08-30 加:词级多音字消歧(JyutpingWords.txt,同一个 rime-cantonese 项目)。
		// "重"单字表只给得出一个固定读音,"重要"该读 zung6 jiu3、"重量"该读
		// cung5 loeng6——这是这次改动要修的真实案例,以前两个词会被拼成同一个错的。
		{"多音字消歧: 重要", "重要", "zung6 jiu3"},
		{"多音字消歧: 重量(同一个字,不同词,不同读音)", "重量", "cung5 loeng6"},
		{"多音字消歧在整句里也生效", "呢件事好重要", "nei1 gin6 si6 hou2 zung6 jiu3"},
		// 2026-08-30 加:碰撞覆盖表(JyutpingCollisionOverrides.txt)。"离"这个简体字
		// 本身在字表里还有一个独立的生僻字身份(读 ci1),不覆盖的话单独一个"离"字永远
		// 查到那个无关读音、轮不到"当簡體用時該讀 lei4"这层——即便词表命中"离开"这类
		// 词没问题,单独一个字仍会读错,这条专门测"单独一个字"这个词表管不到的场景。
		{"字表碰撞覆盖: 单独一个离字(不构成任何词)", "离", "lei4"},
		{"字表碰撞覆盖: 在句子里单独出现", "我要离", "ngo5 jiu3 lei4"},
		{"字表碰撞覆盖: 词表命中的离开不受影响(双重验证同一个字两条路径都对)", "离开", "lei4 hoi1"},
		// "唔該"(2 字,m4 goi1)和"唔該晒"(3 字,m4 goi1 saai3)都在词典里——贪心要选
		// 最长的那个,不能因为先找到 2 字的"唔該"就提前停手、把"晒"漏成单字。
		{"最长匹配优先: 唔該晒不能被短词唔該截断", "唔該晒", "m4 goi1 saai3"},
		// 2026-08-31 修的真 bug:拉丁/数字**紧接**汉字(中间没有空格)时,读音会被粘在
		// 拉丁串尾巴上。上面那条 "Baby 我爱你" 因为输入自带空格,恰好绕开了这个洞。
		// 真实缓存里的原样输出:《从何唱起》"Do re mi当中找我道理" → "Do re midong1 …"。
		{"拉丁紧接汉字要分隔(修前粘成 babyngo5)", "baby我爱你", "baby ngo5 oi3 nei5"},
		{"大写同理(修前粘成 OKlaa1)", "OK啦", "OK laa1"},
		{"汉字—拉丁—汉字两侧都要分隔(修前粘成 lovenei5)", "我love你", "ngo5 love nei5"},
		{"拉丁串内部仍然不拆", "Do re mi当中", "Do re mi dong1 zung1"},
		{"数字紧接汉字", "3个", "3 go3"},
		// unicode.IsLetter 对汉字也返回 true,所以"查不到读音的汉字"以前会被当成拉丁串
		// 的一部分、吞掉后面音节前的空格。这里用一个字表里没有的生僻字钉住。
		{"查不到读音的汉字后面也要分隔", "𠮷我", "𠮷 ngo5"},
		// 不该回归:纯拉丁内容原样穿透,撇号不能把词劈开。
		{"纯英文原样穿透、撇号不劈词", "that’s all", "that’s all"},
	}
	for _, c := range cases {
		if got := toJyutpingLine(c.in); got != c.want {
			t.Errorf("%s: toJyutpingLine(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func TestJyutpingLRC(t *testing.T) {
	lrc := "[00:01.00]我愛你\n[00:03.50]我哋今日好開心"
	got := jyutpingLRC(lrc)
	want := "[00:01.00]ngo5 oi3 nei5\n[00:03.50]ngo5 dei6 gam1 jat6 hou2 hoi1 sam1"
	if got != want {
		t.Errorf("jyutpingLRC(%q) = %q, want %q", lrc, got, want)
	}
}

func TestJyutpingLRCEmpty(t *testing.T) {
	if got := jyutpingLRC(""); got != "" {
		t.Errorf("jyutpingLRC(\"\") = %q, want empty", got)
	}
	// 一整份都是查不到读音的内容(这里用没有时间戳的纯文本模拟"parseLRCLines 一行都
	// 解析不出来"的情况)时,同样应该返回空,不是拼出一份内容全部原样穿透的"伪粤拼"。
	if got := jyutpingLRC("没有时间戳的纯文本"); got != "" {
		t.Errorf("jyutpingLRC(no timestamps) = %q, want empty", got)
	}
}

// maybeGenerateJyutpingRoma 是 enrichEntry 的方法,只在语种是粤语、且这一轮没有任何源
// 给出罗马音时才补;已有值/非粤语/没歌词都不该被覆盖或触发。
func TestMaybeGenerateJyutpingRoma(t *testing.T) {
	cases := []struct {
		name     string
		entry    enrichEntry
		wantRoma string
	}{
		{
			name:     "粤语且罗马音为空 → 应该补上",
			entry:    enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: "[00:01.00]我愛你"},
			wantRoma: "[00:01.00]ngo5 oi3 nei5",
		},
		{
			name:     "已有罗马音 → 不覆盖",
			entry:    enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: "[00:01.00]我愛你", LyricsRoma: "[00:01.00]existing"},
			wantRoma: "[00:01.00]existing",
		},
		{
			name:     "国语歌不该生成粤拼",
			entry:    enrichEntry{SongLanguage: songLanguageMandarin, Lyrics: "[00:01.00]我愛你"},
			wantRoma: "",
		},
		{
			name:     "语种未知不该生成粤拼",
			entry:    enrichEntry{SongLanguage: "", Lyrics: "[00:01.00]我愛你"},
			wantRoma: "",
		},
		{
			name:     "没有歌词正文不该生成",
			entry:    enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: ""},
			wantRoma: "",
		},
	}
	for _, c := range cases {
		e := c.entry
		e.maybeGenerateJyutpingRoma()
		if e.LyricsRoma != c.wantRoma {
			t.Errorf("%s: LyricsRoma = %q, want %q", c.name, e.LyricsRoma, c.wantRoma)
		}
	}
}
