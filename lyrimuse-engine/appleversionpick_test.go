package main

import "testing"

// Frank Ocean《Solo》:同一张《Blonde》里还有 78.7 秒的「Solo (Reprise)」,iTunes 把它排在前面。专辑分一样,
// 原先按先出现的挑,链接指到了 Reprise。
var (
	frankOceanSoloReprise = itunesResult{TrackName: "Solo (Reprise)", CollectionName: "Blonde", ArtistName: "Frank Ocean",
		TrackViewURL: "https://music.apple.com/us/album/solo-reprise/1146195596?i=1146195721&uo=4", TrackTimeMillis: 78743}
	frankOceanSolo = itunesResult{TrackName: "Solo", CollectionName: "Blonde", ArtistName: "Frank Ocean",
		TrackViewURL: "https://music.apple.com/us/album/solo/1146195596?i=1146195604&uo=4", TrackTimeMillis: 257380}
)

func TestPickAppleMusicMatchSkipsOtherVersionOnSameAlbum(t *testing.T) {
	m, albumMatched := pickAppleMusicMatch([]itunesResult{frankOceanSoloReprise, frankOceanSolo}, "Frank Ocean", "Solo", "Blonde", 257)
	if !albumMatched || m.url != frankOceanSolo.TrackViewURL {
		t.Errorf("应挑正曲「Solo」,实得 %q (%q)", m.title, m.url)
	}
	// 时长未知时也不认 Reprise:版本词对不上就不是这一首。
	if m, _ := pickAppleMusicMatch([]itunesResult{frankOceanSoloReprise}, "Frank Ocean", "Solo", "Blonde", 0); m.url != "" {
		t.Errorf("只有 Reprise 时应不给链接,实得 %q", m.title)
	}
	// 本地放的就是 Reprise:照常认。
	if m, _ := pickAppleMusicMatch([]itunesResult{frankOceanSolo, frankOceanSoloReprise}, "Frank Ocean", "Solo (Reprise)", "Blonde", 78.7); m.url != frankOceanSoloReprise.TrackViewURL {
		t.Errorf("本地是 Reprise 时应挑 Reprise,实得 %q", m.title)
	}
}

func TestPickAppleMusicMatchSkipsKaraokeAndRemixFallbacks(t *testing.T) {
	karaoke := itunesResult{TrackName: "Cherry (Karaoke Version)", CollectionName: "Spitz Karaoke Collection", ArtistName: "スピッツ",
		TrackViewURL: "https://music.apple.com/jp/album/x/1?i=2", TrackTimeMillis: 260000}
	original := itunesResult{TrackName: "Cherry", CollectionName: "インディゴ地平線", ArtistName: "スピッツ",
		TrackViewURL: "https://music.apple.com/jp/album/x/3?i=4", TrackTimeMillis: 254000}
	if m, _ := pickAppleMusicMatch([]itunesResult{karaoke, original}, "スピッツ", "Cherry", "", 0); m.url != original.TrackViewURL {
		t.Errorf("没有专辑证据时也不该拿卡拉OK版兜底,实得 %q", m.title)
	}
	clubMix := itunesResult{TrackName: "Bad (Afrojack Remix)", CollectionName: "Bad 25th Anniversary", ArtistName: "Michael Jackson",
		TrackViewURL: "https://music.apple.com/us/album/x/5?i=6", TrackTimeMillis: 380000}
	if m, _ := pickAppleMusicMatch([]itunesResult{clubMix}, "Michael Jackson", "Bad", "Bad", 247); m.url != "" {
		t.Errorf("混音版不该当成本曲,实得 %q", m.title)
	}
}

// 演唱会专辑上的曲目,Apple 曲名写「(Live)」、本地只写歌名:专辑名里的现场标记一起算,不算版本不符。
func TestAppleTitleResultOKCountsAlbumVersionTags(t *testing.T) {
	live := itunesResult{TrackName: "呼吸 (Live)", CollectionName: "My Space 演唱會紀念盤", ArtistName: "蔡健雅",
		TrackViewURL: "https://music.apple.com/cn/album/x/7?i=8", TrackTimeMillis: 300000}
	if !appleTitleResultOK(live, "蔡健雅", "呼吸", "My Space 演唱會紀念盤", 300) {
		t.Error("本地专辑本身是演唱会专辑,应认 Live 那一轨")
	}
	if appleTitleResultOK(live, "蔡健雅", "呼吸", "呼吸", 300) {
		t.Error("本地是录音室版,不该认 Live 那一轨")
	}
}

func TestPickAppleMusicMatchPrefersDurationFit(t *testing.T) {
	first := itunesResult{TrackName: "Hymn for the Weekend", CollectionName: "Hits 2016", ArtistName: "Coldplay",
		TrackViewURL: "https://music.apple.com/cn/album/x/1?i=1", TrackTimeMillis: 230000}
	second := itunesResult{TrackName: "Hymn for the Weekend", CollectionName: "Summer Hits", ArtistName: "Coldplay",
		TrackViewURL: "https://music.apple.com/us/album/x/2?i=2", TrackTimeMillis: 258800}
	m, albumMatched := pickAppleMusicMatch([]itunesResult{first, second}, "Coldplay", "Hymn for the Weekend", "A Head Full of Dreams", 258.9)
	if albumMatched || m.url != second.TrackViewURL {
		t.Errorf("没有专辑证据时应取头一条时长对得上的,实得 %q", m.url)
	}
	if m, _ := pickAppleMusicMatch([]itunesResult{first, second}, "Coldplay", "Hymn for the Weekend", "A Head Full of Dreams", 0); m.url != first.TrackViewURL {
		t.Errorf("时长未知时照旧取头一条,实得 %q", m.url)
	}
	if m, _ := pickAppleMusicMatch([]itunesResult{first, second}, "Coldplay", "Hymn for the Weekend", "A Head Full of Dreams", 300); m.url != first.TrackViewURL {
		t.Errorf("都对不上时照旧取头一条(时长不拦),实得 %q", m.url)
	}
	a := itunesResult{TrackName: "Song", CollectionName: "Album", ArtistName: "X", TrackViewURL: "a", TrackTimeMillis: 200000}
	b := itunesResult{TrackName: "Song", CollectionName: "Album", ArtistName: "X", TrackViewURL: "b", TrackTimeMillis: 240000}
	if m, _ := pickAppleMusicMatch([]itunesResult{a, b}, "X", "Song", "Album", 240); m.url != "b" {
		t.Errorf("专辑分一样时取时长近的,实得 %q", m.url)
	}
}

func TestAppleOtherVersion(t *testing.T) {
	cases := []struct {
		name                            string
		title, album, track, collection string
		want                            bool
	}{
		{"同专辑的 Reprise", "Solo", "Blonde", "Solo (Reprise)", "Blonde", true},
		{"伴奏带", "Cherry", "インディゴ地平線", "Cherry (Karaoke Version)", "Spitz Karaoke", true},
		{"本地是 Live、Apple 是录音室版", "Livin' On A Prayer (Live)", "Slippery When Wet", "Livin' On a Prayer", "Slippery When Wet", true},
		{"同一首", "Solo", "Blonde", "Solo", "Blonde", false},
		{"演唱会专辑上曲名写了 Live", "呼吸", "My Space 演唱會紀念盤", "呼吸 (Live)", "My Space 演唱會紀念盤", false},
		{"演唱会专辑上曲名没写 Live", "Beat It", "Live at Wembley July 16, 1988", "Beat It", "Live at Wembley July 16, 1988", false},
		{"Acoustic 单曲碟里的原版", "Be Alright", "Be Alright - Single", "Be Alright", "Be Alright (Acoustic) - Single", false},
		{"版本词不带括号", "阿拉斯加海湾 伴奏", "阿拉斯加海湾", "阿拉斯加海湾 (伴奏)", "阿拉斯加海湾", false},
	}
	for _, c := range cases {
		if got := appleOtherVersion(c.title, c.album, c.track, c.collection); got != c.want {
			t.Errorf("%s: appleOtherVersion = %v, want %v", c.name, got, c.want)
		}
	}
}
