package main

import (
	"reflect"
	"testing"
)

// 判专辑的三条(见 kasetalbum.go 头注),问法换成假的。
func TestKasetAlbumVerdict(t *testing.T) {
	credits := map[string]ytmusicCredit{
		"ATVALBUM001": {album: "Westside Whimsy", videoType: "MUSIC_VIDEO_TYPE_ATV", durationSecs: 196},
		"OMVLONG0001": {videoType: ytmusicVideoTypeOMV, durationSecs: 393},
		"OMVSAME0001": {videoType: ytmusicVideoTypeOMV, durationSecs: 197},
		"UGCLONG0001": {videoType: "MUSIC_VIDEO_TYPE_UGC", durationSecs: 393},
		"OMVALONE001": {videoType: ytmusicVideoTypeOMV, durationSecs: 239},
		"UGCALONE001": {videoType: "MUSIC_VIDEO_TYPE_UGC", durationSecs: 240},
		"CATALOGATV1": {album: "Colour by Numbers", videoType: "MUSIC_VIDEO_TYPE_ATV", durationSecs: 240},
		"OMVAUDIO001": {videoType: ytmusicVideoTypeOMV, durationSecs: 179},
		"ATVLULLABY1": {album: "Westside Whimsy", videoType: "MUSIC_VIDEO_TYPE_ATV", durationSecs: 179},
	}
	pairs := map[string]string{"OMVLONG0001": "ATVALBUM001", "OMVSAME0001": "ATVALBUM001", "UGCLONG0001": "ATVALBUM001"}
	catalog := map[string]string{"Culture Club|Karma Chameleon|240": "CATALOGATV1", "Jhené Aiko|Lullaby|179": "ATVLULLABY1"}
	pending := map[string]bool{}
	l := kasetAlbumLookups{
		listed: func(id string) (ytmusicCredit, bool) {
			if pending[id] {
				return ytmusicCredit{}, false
			}
			return credits[id], true
		},
		catalog: func(artist, title string, secs float64) (string, bool) {
			key := kasetCatalogKey(artist, title, secs)
			if pending[key] {
				return "", false
			}
			return catalog[key], true
		},
		audioOf: func(id string) string {
			if a := pairs[id]; a != "" {
				return a
			}
			return id
		},
	}
	cases := []struct {
		name    string
		id      string
		artist  string
		title   string
		want    kasetAlbumVerdict
		settled bool
	}{
		{"音轨版本自己登记了专辑", "ATVALBUM001", "Jhené Aiko", "Break", kasetAlbumVerdict{album: "Westside Whimsy"}, true},
		{"配了音轨版本、两版一样长:同一段录音", "OMVSAME0001", "Jhené Aiko", "I Don't Mind", kasetAlbumVerdict{album: "Westside Whimsy"}, true},
		{"配了音轨版本、官方 MV 长得多:MV 版本", "OMVLONG0001", "Jhené Aiko", "Break", kasetAlbumVerdict{mv: true}, true},
		{"配了音轨版本、别的视频长得多:没有专辑", "UGCLONG0001", "Jhené Aiko", "Break", kasetAlbumVerdict{}, true},
		{"没配音轨版本、曲库里一样长的那首有专辑", "UGCALONE001", "Culture Club", "Karma Chameleon (Official Music Video)",
			kasetAlbumVerdict{album: "Colour by Numbers"}, true},
		{"没配音轨版本、曲库里没有一样长的、官方 MV:MV 版本", "OMVALONE001", "Culture Club", "Karma Chameleon",
			kasetAlbumVerdict{mv: true}, true},
		{"歌名换成了视频标题:去掉开头的「歌手 - 」再找", "OMVAUDIO001", "Jhené Aiko", "Jhené Aiko - Lullaby",
			kasetAlbumVerdict{album: "Westside Whimsy"}, true},
		{"没有 videoId", "", "A", "B", kasetAlbumVerdict{}, false},
	}
	for _, c := range cases {
		got, settled := kasetAlbumVerdictWith(l, c.id, 0, c.artist, c.title)
		if got != c.want || settled != c.settled {
			t.Errorf("%s: got %+v settled=%v, want %+v settled=%v", c.name, got, settled, c.want, c.settled)
		}
	}
	pending["ATVALBUM001"] = true
	if _, settled := kasetAlbumVerdictWith(l, "OMVSAME0001", 0, "Jhené Aiko", "I Don't Mind"); settled {
		t.Error("音轨版本还没问到时不下结论")
	}
	pending["Culture Club|Karma Chameleon|239"] = true
	if _, settled := kasetAlbumVerdictWith(l, "OMVALONE001", 0, "Culture Club", "Karma Chameleon"); settled {
		t.Error("曲库还没找完时不下结论")
	}
}

func TestApplyKasetAlbumVerdict(t *testing.T) {
	e := enrichEntry{YouTubeMusicAlbum: "Wonderland"}
	if !applyKasetAlbumVerdict(&e, kasetAlbumVerdict{album: "未来"}, "zh-Hans") || e.YouTubeMusicAlbum != "未来" || e.YouTubeMusicAlbumLang != "zh-Hans" ||
		e.YouTubeMusicAlbumRev != kasetAlbumVerdictRev {
		t.Errorf("按界面语言改写: %+v", e)
	}
	if applyKasetAlbumVerdict(&e, kasetAlbumVerdict{album: "未来"}, "zh-Hans") {
		t.Error("没变不算改动")
	}
	if !applyKasetAlbumVerdict(&e, kasetAlbumVerdict{mv: true}, "zh-Hans") || e.YouTubeMusicAlbum != "" || !e.YouTubeMusicMV {
		t.Errorf("MV 版本清掉专辑: %+v", e)
	}
	e.YouTubeMusicAlbumRev = 0
	if !applyKasetAlbumVerdict(&e, kasetAlbumVerdict{mv: true}, "zh-Hans") || e.YouTubeMusicAlbumRev != kasetAlbumVerdictRev {
		t.Errorf("旧判法判的,结论一样也要记上新版本: %+v", e)
	}
}

// 补判扫描只挑用 Kaset 放过、键里没专辑、还没按这种界面语言和当前判法判过的。
func TestKasetAlbumSweepCandidates(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"方大同|Love Song|":           {YouTubeMusicURL: "https://music.youtube.com/watch?v=qUUBDOL-09k", YouTubeMusicAlbum: "Wonderland"},
		"Jhené Aiko|Break|":        {YouTubeMusicURL: "https://music.youtube.com/watch?v=AJ--JpOmlog"},
		"Jhené Aiko|Ghost~dur2|":   {YouTubeMusicURL: "https://music.youtube.com/watch?v=m4t6YeTJFfY"},
		"方大同|才二十三|":                {YouTubeMusicURL: "https://music.youtube.com/watch?v=Cr1VjUDSp_0", YouTubeMusicAlbumLang: "zh-Hans", YouTubeMusicAlbumRev: kasetAlbumVerdictRev},
		"方大同|红豆|":                  {YouTubeMusicURL: "https://music.youtube.com/watch?v=57VMfkViG7c", YouTubeMusicAlbumLang: "zh-Hans"},
		"方大同|才二十三|梦想家 The Dreamer": {YouTubeMusicURL: "https://music.youtube.com/watch?v=Cr1VjUDSp_0"},
		"Someone|Song|":            {},
	})
	enrichMu.Lock()
	got := kasetAlbumSweepCandidatesLocked("zh-Hans")
	enrichMu.Unlock()
	want := []string{"Jhené Aiko|Break|", "Jhené Aiko|Ghost~dur2|", "方大同|Love Song|", "方大同|红豆|"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestKasetSameLength(t *testing.T) {
	for _, c := range []struct {
		a, b float64
		want bool
	}{{196, 196, true}, {190.09, 191, true}, {393, 196, false}, {0, 196, false}, {196, 0, false}} {
		if got := kasetSameLength(c.a, c.b); got != c.want {
			t.Errorf("kasetSameLength(%v, %v) = %v", c.a, c.b, got)
		}
	}
}
