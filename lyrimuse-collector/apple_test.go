package main

import "testing"

// TestAppleResultIdentityOK 锁住 apple.go 那道身份闸的分档。数据取自 2026-09-14 的实测:
// jolle《danke für nichts》只在德区商店上架,CN/US 搜到的是另一个歌手 Pie Kei 的同名单曲。
func TestAppleResultIdentityOK(t *testing.T) {
	cases := []struct {
		name                                           string
		candArtist, candAlbum, localArtist, localAlbum string
		want                                           bool
	}{
		{
			name:       "同名不同人:德区独占曲在 CN/US 搜到别人的同名单曲(本案)",
			candArtist: "Pie Kei", candAlbum: "Danke für Nichts - Single",
			localArtist: "jolle", localAlbum: "sunny side up/:down",
			want: false,
		},
		{
			name:       "同一歌手同一专辑",
			candArtist: "jolle", candAlbum: "sunny side up/:down",
			localArtist: "jolle", localAlbum: "sunny side up/:down",
			want: true,
		},
		{
			name:       "同一歌手,专辑对不上(别的发行版)仍放行——身份靠署名定",
			candArtist: "jolle", candAlbum: "danke für nichts",
			localArtist: "jolle", localAlbum: "sunny side up/:down",
			want: true,
		},
		{
			name:       "合作署名换分隔符:段集交集档(lyricSourceArtistMatches 已有能力)",
			candArtist: "VIZE & Tokio Hotel", candAlbum: "某合辑",
			localArtist: "VIZE, Tokio Hotel", localAlbum: "另一张专辑",
			want: true,
		},
		{
			name:       "署名跨商店改写、专辑名逐字相等:走专辑旁路放行",
			candArtist: "Khalil Fong", candAlbum: "橙月",
			localArtist: "方大同", localAlbum: "橙月",
			want: true,
		},
		{
			name:       "署名对不上、专辑只是宽松包含(albumScore=100):不给免检",
			candArtist: "别的歌手", candAlbum: "周杰伦地表最强世界巡回演唱会live",
			localArtist: "周杰伦", localAlbum: "周杰伦",
			want: false,
		},
		{
			name:       "本地署名为空:无从判定,放行",
			candArtist: "Pie Kei", candAlbum: "Danke für Nichts - Single",
			localArtist: "", localAlbum: "sunny side up/:down",
			want: true,
		},
		{
			name:       "候选署名为空:无从判定,放行",
			candArtist: "", candAlbum: "Danke für Nichts - Single",
			localArtist: "jolle", localAlbum: "sunny side up/:down",
			want: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := appleResultIdentityOK(c.candArtist, c.candAlbum, c.localArtist, c.localAlbum); got != c.want {
				t.Errorf("appleResultIdentityOK(%q, %q, %q, %q) = %v, want %v",
					c.candArtist, c.candAlbum, c.localArtist, c.localAlbum, got, c.want)
			}
		})
	}
}

// pieKeiResult / jolleResult 是 2026-09-14 从 iTunes Search 实测 dump 出来的两条真实结果
// (前者 country=US,后者 country=DE),不是构造的。
var pieKeiResult = itunesResult{
	TrackName: "Danke für Nichts", ArtistName: "Pie Kei",
	CollectionName: "Danke für Nichts - Single", CollectionID: 1,
	TrackViewURL: "https://music.apple.com/us/album/piekei/1", ArtworkURL100: "https://x/100x100bb.jpg",
	TrackTimeMillis: 158480,
}

var jolleResult = itunesResult{
	TrackName: "danke für nichts", ArtistName: "jolle",
	CollectionName: "sunny side up/:down", CollectionID: 6783298906,
	TrackViewURL: "https://music.apple.com/de/album/jolle/6783298906", ArtworkURL100: "https://y/100x100bb.jpg",
	TrackTimeMillis: 137730,
}

// TestPickAppleMusicMatchRejectsSameTitleDifferentArtist 是本案的回归测试。
//
// 修复前 pickAppleMusicMatch 只看曲名,会把 Pie Kei 那条当成 titleFallback 返回,连带
// 把 158.478s 交给 searchcli.go 当"本曲时长"兜底 —— 那个错时长再喂进标题反查轮,就把
// 曲名"纠正"成同专辑里时长相近的《fingergun》,最后返回的是**另一首歌的歌词**。
// 所以这里除了断言没选中,还要断言 durationSecs 没被带出来。
func TestPickAppleMusicMatchRejectsSameTitleDifferentArtist(t *testing.T) {
	got, hasAlbumEvidence := pickAppleMusicMatch(
		[]itunesResult{pieKeiResult}, "jolle", "danke für nichts", "sunny side up/:down")
	if got.url != "" {
		t.Errorf("不该选中同名不同人的结果，却返回了 url=%q title=%q album=%q", got.url, got.title, got.album)
	}
	if hasAlbumEvidence {
		t.Error("没有任何可用结果时不该声称有专辑证据")
	}
	if got.durationSecs != 0 {
		t.Errorf("durationSecs 必须为 0（否则会被 searchcli 当作本曲时长兜底），实得 %v", got.durationSecs)
	}
}

// TestPickAppleMusicMatchKeepsCorrectArtist 是反向守卫:这道闸不能把正主也拦掉。
func TestPickAppleMusicMatchKeepsCorrectArtist(t *testing.T) {
	got, hasAlbumEvidence := pickAppleMusicMatch(
		[]itunesResult{pieKeiResult, jolleResult}, "jolle", "danke für nichts", "sunny side up/:down")
	if got.url != jolleResult.TrackViewURL {
		t.Errorf("应选中 jolle 那条，实得 url=%q artist 来源 album=%q", got.url, got.album)
	}
	if !hasAlbumEvidence {
		t.Error("专辑名逐字相等，应报告有专辑证据")
	}
	if got.durationSecs != 137.73 {
		t.Errorf("durationSecs = %v, want 137.73", got.durationSecs)
	}
}

// TestAppleResultIdentityOKKnownBoundary 钉住这道闸的**已知边界**(2026-09-14 实测),
// 别让后人以为它能认出所有同一个人。
//
// 合作署名不用担心:lyricSourceArtistMatches 的段集交集档只要有一段对上就放行,所以
// 顺序颠倒、少写一位合作者、其中一位换语言写法,统统能过(下面前三条)。
//
// 真正过不去的是**单人署名换了写法**——跨语言(宇多田ヒカル / Utada Hikaru、
// スピッツ / Spitz)、艺名与本名(The Weeknd / Abel Tesfaye、方大同 / Khalil Fong),
// 以及用 "featuring" 这种 isArtistCreditSep 不认的连接词写的合作署名。这类只能靠
// **专辑名逐字相等**那条旁路救回来;连专辑名也被商店本地化时就会被拦下,后果是这首歌
// 少一个 Apple 跳转链接/封面/时长兜底 —— 这是**刻意选的**降级方向,沿用 apple.go 原有的
// "better no link than a wrong-song link":拿到别人的歌会顺着时长兜底一路污染到歌词
// (见 appleResultIdentityOK 头注的 fingergun 案),少一张封面不会。
func TestAppleResultIdentityOKKnownBoundary(t *testing.T) {
	const sameAlbum = "My Dear Melancholy,"
	cases := []struct {
		name                                           string
		candArtist, candAlbum, localArtist, localAlbum string
		want                                           bool
	}{
		{"合作署名顺序颠倒", "Rufus & Chaka Khan", "Rags to Rufus", "Chaka Khan & Rufus", "别的专辑", true},
		{"合作署名只写团名", "Silk Sonic", "An Evening", "Bruno Mars, Anderson .Paak & Silk Sonic", "别的专辑", true},
		{"合作署名其中一位换语言写法", "Utada Hikaru & Skrillex", "A", "宇多田ヒカル & Skrillex", "B", true},

		{"边界:单人署名跨语言,专辑也对不上 → 拦", "Utada Hikaru", "First Love", "宇多田ヒカル", "初恋", false},
		{"边界:单人署名跨语言,专辑逐字相等 → 旁路救回", "Utada Hikaru", sameAlbum, "宇多田ヒカル", sameAlbum, true},
		{"边界:艺名vs本名,专辑对不上 → 拦", "The Weeknd", "Starboy", "Abel Tesfaye", sameAlbum, false},
		{"边界:艺名vs本名,专辑逐字相等 → 旁路救回", "The Weeknd", sameAlbum, "Abel Tesfaye", sameAlbum, true},
		{"边界:featuring 不是 isArtistCreditSep 认的分隔符 → 拦", "Rufus featuring Chaka Khan", "X", "Chaka Khan & Rufus", "Y", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := appleResultIdentityOK(c.candArtist, c.candAlbum, c.localArtist, c.localAlbum); got != c.want {
				t.Errorf("appleResultIdentityOK(%q, %q, %q, %q) = %v, want %v",
					c.candArtist, c.candAlbum, c.localArtist, c.localAlbum, got, c.want)
			}
		})
	}
}

// TestPickAppleMusicMatchRejectsKaraokeImpersonator 是 2026-09-14 那轮 43 首真实样本
// 回归对比里**实际被这道闸拦掉**的三条之一(另两条同型):日文歌在 CN/US 商店搜不到原版时,
// iTunes 回的常常是卡拉OK伴奏带 —— 它的曲名里带「(オリジナルアーティスト:back number)」
// (原唱:back number),署名却是伴奏带厂商,时长 319.33s 也跟原曲对不上。修复前这条会被
// 当成本曲匹配返回。
func TestPickAppleMusicMatchRejectsKaraokeImpersonator(t *testing.T) {
	karaoke := itunesResult{
		TrackName:       "ハッピーエンド(オリジナルアーティスト:back number)",
		ArtistName:      "カラオケ歌っちゃ王",
		CollectionName:  "ハッピーエンド(オリジナルアーティスト:back number) - Single",
		TrackViewURL:    "https://music.apple.com/us/album/x/1534525712?i=1534525713",
		TrackTimeMillis: 319330,
	}
	got, _ := pickAppleMusicMatch([]itunesResult{karaoke}, "back number", "ハッピーエンド", "ハッピーエンド")
	if got.url != "" {
		t.Errorf("卡拉OK伴奏带不该被当成本曲匹配，却返回了 title=%q album=%q dur=%v", got.title, got.album, got.durationSecs)
	}
}
