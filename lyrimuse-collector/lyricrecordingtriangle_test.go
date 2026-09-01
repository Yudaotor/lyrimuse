package main

import (
	"os"
	"strings"
	"testing"
)

// 本案例的本地(Apple Music)标签,来自 iTunes lookup id=1485220321:
// artistName="南拳妈妈弹头"(乐队名+成员名直接粘在一起,中间没有任何 isArtistCreditSep
// 认得的分隔符)、trackName="枫+退后+搁浅 (Live)"、trackTimeMillis=119213。
const (
	triLocalArtist   = "南拳妈妈弹头"
	triLocalTitle    = "枫+退后+搁浅 (Live)"
	triLocalAlbum    = "周杰伦地表最强世界巡回演唱会 (Live)"
	triLocalDuration = 119.213
)

// TestLyricRecordingTriangleOnRealKugouRows 用**酷狗搜索接口的真实返回行**锁住
// "只放行正主那一条"。这 6 行是 2026-08-22 实测 keyword="南拳妈妈弹头 枫+退后+搁浅"
// (searchTitleVariants 的第二条变体,酷狗一定会跑到它——kugouLookup 只在 chosen!=nil
// 时才 break)返回的前 6 条,逐字抄下来。
//
// 判据表达式跟 resolveKugouLyric 里那道闸完全同构:
//
//	lyricTitleAccepted && (lyricSourceArtistMatches || lyricRecordingTriangleMatches)
func TestLyricRecordingTriangleOnRealKugouRows(t *testing.T) {
	rows := []struct {
		songName, singer, album string
		duration                float64
		want                    bool
		why                     string
	}{
		{"枫+退后+搁浅 (Live)", "宋健彰", "周杰伦地表最强世界巡回演唱会", 119, true,
			"正主:标题逐字同名 + 专辑宽松包含且长度可比 + 时长 119 对 119.213(0.18%)"},
		{"枫+退后+搁浅", "炸小肉丸", "周杰伦", 62, false,
			"标题少了 (Live) 就过不了逐字同名;即便过了,专辑名是短通用串、时长也差 48%"},
		{"枫+退后+搁浅", "kingwen", "", 119, false,
			"标题对不上;且专辑名为空,三角验证一律不给"},
		{"枫+退后+搁浅", "Jork_FC", "", 119, false, "同上"},
		{"枫 + 退后 + 搁浅", "Lolo, ❁❁", "", 119, false,
			"归一后标题是 枫退后搁浅、少 live;歌手串虽能切出 2 段但与本地无交集"},
		{"枫 + 退后 + 搁浅", "Tsang", "", 119, false, "同上"},
	}
	for _, r := range rows {
		titleOK := lyricTitleAccepted(r.songName, triLocalTitle)
		artistOK := lyricSourceArtistMatches(r.singer, triLocalArtist)
		triOK := lyricRecordingTriangleMatches(r.songName, r.album, r.duration,
			triLocalTitle, triLocalAlbum, triLocalDuration)
		got := titleOK && (artistOK || triOK)
		if got != r.want {
			t.Errorf("闸门对 %q/%q/%q/%gs 判 %v,应为 %v(title=%v artist=%v triangle=%v)——%s",
				r.songName, r.singer, r.album, r.duration, got, r.want, titleOK, artistOK, triOK, r.why)
		}
		// 顺带钉住:歌手闸对**每一行**都不过(这是这首歌零候选的直接原因),
		// 所以正主完全靠三角档救回来。
		if artistOK {
			t.Errorf("lyricSourceArtistMatches(%q, %q) 意外为 true——本案例的前提是它全拒",
				r.singer, triLocalArtist)
		}
	}
}

// TestLyricRecordingTriangleGuards 逐条验证四道判据各自真的在拦东西。
func TestLyricRecordingTriangleGuards(t *testing.T) {
	cases := []struct {
		name                   string
		candTitle, candAlbum   string
		candDur                float64
		localTitle, localAlbum string
		localDur               float64
		want                   bool
	}{
		{"基准:正主通过", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, true},
		{"专辑逐字相等(albumScore=200)也通过", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, true},

		// ① 标题:只认逐字同名
		{"标题剥括号才相等 → 拒", "枫+退后+搁浅", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"标题双语档 → 拒", "枫+退后+搁浅 (Live) Maple", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"标题空 → 拒", "", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},

		// ② 时长:1% 容差,两边都必须有
		{"时长差 0.9% → 通过", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119.213 * 1.009,
			triLocalTitle, triLocalAlbum, triLocalDuration, true},
		{"时长差 1.1% → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119.213 * 1.011,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"时长差 -1.1% → 拒(对称)", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119.213 * 0.989,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"候选时长缺失 → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 0,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"本地时长缺失 → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, 0, false},

		// ③ 专辑:必须都非空、且 albumScore>=100 并长度可比
		{"本地专辑为空 → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, "", triLocalDuration, false},
		{"候选专辑为空 → 拒", "枫+退后+搁浅 (Live)", "", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"候选专辑是短通用串(包含档但长度不可比) → 拒", "枫+退后+搁浅 (Live)", "周杰伦", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"候选专辑只是 token 重叠(albumScore<100) → 拒", "枫+退后+搁浅 (Live)", "地表最强 精选集", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},

		// ④ 版本限定词冲突
		{"候选是 Demo 版 → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会 (Demo)", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
	}
	for _, c := range cases {
		got := lyricRecordingTriangleMatches(c.candTitle, c.candAlbum, c.candDur,
			c.localTitle, c.localAlbum, c.localDur)
		if got != c.want {
			t.Errorf("%s:lyricRecordingTriangleMatches(%q,%q,%g, %q,%q,%g) = %v,want %v",
				c.name, c.candTitle, c.candAlbum, c.candDur, c.localTitle, c.localAlbum, c.localDur, got, c.want)
		}
	}
}

// TestLyricRecordingTriangleAlbumWidthBoundary 把长度可比性那道闸的边界钉死。
//
// 本地专辑刻意选一个**不含版本限定词、也不含中文现场标记**的串:否则 versionTagsMismatch
// 会先一步否决(v9 起"演唱会/现场/音乐会"字样的专辑名视同声明了 live——原夹具
// "周杰伦地表最强世界巡回演唱会"被截短的候选丢掉"演唱会"后两边 tag 集合不等 → mismatch),
// 测不到长度这一闸。这个交互是版本闸的既有职责:候选专辑名被截短到丢掉版本声明时,拦住它
// 的是版本闸而不是长度闸 —— 两道闸叠着,不是替代。
func TestLyricRecordingTriangleAlbumWidthBoundary(t *testing.T) {
	const local = "周杰伦地表最强世界巡回纪念集" // normLoose → 14 rune,无版本限定词/现场标记
	// 9 字 / 14 = 0.643 >= 0.6 → 通过
	if !lyricRecordingTriangleMatches("X", "周杰伦地表最强世界", 100, "X", local, 100) {
		t.Errorf("9/14=0.643 应通过长度可比性")
	}
	// 8 字 / 14 = 0.571 < 0.6 → 拒
	if lyricRecordingTriangleMatches("X", "周杰伦地表最强世", 100, "X", local, 100) {
		t.Errorf("8/14=0.571 应被长度可比性拒掉")
	}
}

// TestLyricRecordingTriangleNotUsedForIdentity 锁住这条档位的适用范围:它**只能**出现在
// 歌词候选的采纳闸上,绝不能被用到判**身份**的地方(netease 的 pick()/nameOnlyMatch 决定
// 封面和 canonical_artist、qq.go 的 qqCoverFallback 决定封面)。在那三处放宽等于直接采信
// 仿冒号的署名 —— 正是 netease.go 里当年删掉 byAlbum 兜底要防的东西。
//
// 这个测试用扫源码的方式守它:比起注释里的一句 ⚠️,它能真的在 CI 里拦住。
func TestLyricRecordingTriangleNotUsedForIdentity(t *testing.T) {
	for _, f := range []string{"netease.go", "qq.go"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("读 %s: %v", f, err)
		}
		if strings.Contains(string(b), "lyricRecordingTriangleMatches") {
			t.Errorf("%s 里出现了 lyricRecordingTriangleMatches —— 这条档位只放行歌词候选,"+
				"不得用于封面/canonical_artist/链接指向这类身份判定,见该函数注释", f)
		}
	}
}
