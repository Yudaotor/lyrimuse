package main

import (
	"os"
	"strings"
	"testing"
)

// 用例全部来自真实播放(09-19 ~ 09-26 YouTube Music,以及 Last.fm 全部曲目里筛出来的形状)。
// 「不是视频」那一组同样重要:它们是本机曲库里真实存在、形状像视频标题的正式曲目,拆错一条
// 就会往 Last.fm 候选里塞进一个不存在的写法。
func TestParseVideoTitle(t *testing.T) {
	cases := []struct {
		artist, title string
		kind          videoTitleKind
		wantArtist    string
		wantSong      string
	}{
		// MV:四种拆法
		{"防弹少年团", "BTS (방탄소년단) ‘Merry Go Round’ Official MV", videoTitleMusicVideo, "BTS", "Merry Go Round"},
		{"音樂頑童", "Musiq Soulchild - Buddy (Official Video)", videoTitleMusicVideo, "Musiq Soulchild", "Buddy"},
		{"The Rose", "The Rose (더로즈) - Utopia | Official Audio", videoTitleMusicVideo, "The Rose", "Utopia"},
		{"The Kid LAROI", "Stay (Official Video)", videoTitleMusicVideo, "The Kid LAROI", "Stay"},
		{"The Kid LAROI和Justin Bieber", "STAY (Official Video)", videoTitleMusicVideo, "The Kid LAROI和Justin Bieber", "STAY"},
		{"Michael Jackson", "Michael Jackson x Mark Ronson: Diamonds are Invincible (Audio)", videoTitleMusicVideo, "Michael Jackson x Mark Ronson", "Diamonds are Invincible"},
		{"Prince", "Prince - 1999 (Official Music Video)", videoTitleMusicVideo, "Prince", "1999"},
		{"IU", "IU(아이유) _ 'Blueming' MV", videoTitleMusicVideo, "IU", "Blueming"},
		{"Artist", "Song [MV]", videoTitleMusicVideo, "Artist", "Song"},
		{"Artist", "Song (Lyric Video)", videoTitleMusicVideo, "Artist", "Song"},
		{"Artist", "Song 【Official MV】", videoTitleMusicVideo, "Artist", "Song"},
		// 冒号前不含播放器报的歌手:冒号是歌名的一部分,不拆
		{"Adele", "Hometown Glory: Live (Official Video)", videoTitleMusicVideo, "Adele", "Hometown Glory: Live"},
		// 翻唱:不拆
		{"IVE", "To.X Covered by IVE GAEUL&LIZ", videoTitleCover, "", ""},
		{"MAMAMOO", "[Special] Watermelon Sugar (Cover by 화사)", videoTitleCover, "", ""},
		{"ITZY", "[COVER] B-DAY TRACK #65 “CHAERYEONG” | Blueming by 아이유(IU)", videoTitleCover, "", ""},
		// 节目特辑:不拆
		{"MAMAMOO", "[Special] I'm bad too (Feat. DPR LIVE) LIVE", videoTitleSpecial, "", ""},
		{"Seventeen", "[SPECIAL VIDEO] 부석순 (SEVENTEEN) - 7시에 들어줘 (feat. Peder Elias)", videoTitleSpecial, "", ""},
		// 不是视频
		{"陶喆", "飛機場的10:30 - Live", videoTitleNone, "", ""},
		{"陶喆", "Overture (找自己) [Live]", videoTitleNone, "", ""},
		{"Prince", "NPG Operator #1", videoTitleNone, "", ""},
		{"Taylor Swift", "Don’t Blame Me", videoTitleNone, "", ""},
		{"MAMAMOO", "I'm bad too", videoTitleNone, "", ""},
		{"孙燕姿", "天黑黑 - Remastered", videoTitleNone, "", ""},
		{"BTS", "Interlude: Shadow", videoTitleNone, "", ""},
		{"BTS", "Dynamite", videoTitleNone, "", ""},
		{"Tank Lu", "To dear you at tomorrow (\"the Love’s Outlet\" Promotion Song)", videoTitleNone, "", ""},
		{"Drake", "MVP", videoTitleNone, "", ""},
		{"", "", videoTitleNone, "", ""},
	}
	for _, c := range cases {
		got := parseVideoTitle(c.artist, c.title)
		if got.Kind != c.kind || got.Artist != c.wantArtist || got.Song != c.wantSong {
			t.Errorf("parseVideoTitle(%q, %q) = %+v, want kind=%d %q / %q", c.artist, c.title, got, c.kind, c.wantArtist, c.wantSong)
		}
	}
}

// 查歌词、补专辑共用的入口:MV 标题走 parseVideoTitle 并标 isMusicVideo(调用方把时长当未知);
// 别的标题跟接入之前一样按第一个破折号拆。
func TestTitleSplitIdentity(t *testing.T) {
	cases := []struct {
		artist, title string
		wantArtist    string
		wantSong      string
		wantMV, ok    bool
	}{
		{"防弹少年团", "BTS (방탄소년단) ‘Merry Go Round’ Official MV", "BTS", "Merry Go Round", true, true},
		{"The Rose", "The Rose (더로즈) - Utopia | Official Audio", "The Rose", "Utopia", true, true},
		{"The Kid LAROI", "Stay (Official Video)", "The Kid LAROI", "Stay", true, true},
		{"音樂頑童", "Musiq Soulchild - Buddy", "Musiq Soulchild", "Buddy", false, true},
		{"陶喆", "Overture-找自己 - Live", "Overture-找自己", "Live", false, true},
		{"BTS", "Dynamite", "", "", false, false},
	}
	for _, c := range cases {
		a, s, mv, ok := titleSplitIdentity(c.artist, c.title)
		if a != c.wantArtist || s != c.wantSong || mv != c.wantMV || ok != c.ok {
			t.Errorf("titleSplitIdentity(%q, %q) = %q / %q mv=%v ok=%v", c.artist, c.title, a, s, mv, ok)
		}
	}
}

// 查歌词补救、补专辑、封面检索三处必须走 MV 解析,MV 按未知时长。源码级守卫(这三处要九个源 / iTunes / QQ
// 一起跑,功能测试搭不起来),跟 lyricqueryreason_test.go 的 TestLyricQueryLogIsWiredIntoEveryRound 同一个形态。
func TestVideoTitleWiredIntoLyricsAlbumAndCover(t *testing.T) {
	for file, needles := range map[string][]string{
		"enrich.go": {
			"if splitArtist, splitTitle, isMV, ok := titleSplitIdentity(artist, title); ok {",
			"splitNe, splitResults := scoredLyricCandidatesStreaming(splitCtx, splitArtist, splitTitle, album, splitDuration, onUpdate)",
			"if v := parseVideoTitle(artist, title); v.Kind == videoTitleMusicVideo {\n\t\tcoverArtist, coverTitle, coverDuration = v.Artist, v.Song, 0",
			"appleMatch := appleMusicMatchCached(ctx, coverArtist, coverTitle, coverAlbum)",
			"qqCover, _ := qqCoverFallback(ctx, coverArtist, coverTitle, coverAlbum)",
		},
		"albumhint.go": {
			"if titleArtist, song, isMV, ok := titleSplitIdentity(artist, title); ok {",
			"cands = albumHintCandidatesFromTitleSplit(alt, titleArtist, song, splitDuration)",
		},
		"poller.go": {
			"lfm.updateNowPlaying(withCatalogDurationUnknown(ctx, notAudio), artist, title, album, durationSecs)",
			"lfm.scrobble(withCatalogDurationUnknown(ctx, notAudio), artist, title, album, timestamp, durationSecs)",
			"p.mirrorScrobbleSync(withCatalogDurationUnknown(ctx, l.meta.NotAudio),",
		},
	} {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, needle := range needles {
			if !strings.Contains(string(data), needle) {
				t.Errorf("%s 缺 %q", file, needle)
			}
		}
	}
}
