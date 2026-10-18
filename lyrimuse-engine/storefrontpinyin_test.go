package main

import "testing"

// 区服遍历凭时长挑出来的原产地曲名:本地是一字一词的拼音、读音对不上时不用;连写的、英文意译名不判。
func TestStorefrontTraversalTitleUsable(t *testing.T) {
	withHanTitleReading(t, map[string]string{
		"愛的就是你": "ai de jiu shi ni",
		"拖男帶女":  "tuo nan dai nu",
		"怪獣":    "guai shou",
	})
	for _, c := range []struct {
		title, album, found string
		want                bool
	}{
		{"Jie Bu Liao Ni (Album Version)", "The One and Only", "愛的就是你", false},
		{"Ai De Jiu Shi Ni (Romantic Version)", "The One and Only", "愛的就是你", true},
		{"Tou Nan Dai Nu", "This Love", "拖男帶女", true},
		{"Kaiju", "Kaiju - Single", "怪獣", true},
		{"Red Bean", "Timeless", "紅豆", true},
		{"Jie Bu Liao Ni", "The One and Only", "Jie Bu Liao Ni (Live)", false},
	} {
		if got := storefrontTraversalTitleUsable(c.title, c.album, c.found); got != c.want {
			t.Errorf("%q -> %q: %v,期望 %v", c.title, c.found, got, c.want)
		}
	}
}

// 两个消费方都过这一关:标题反查的原产地曲名、原产地曲名轮读的缓存结论。
func TestStorefrontPinyinGateAppliesToBothConsumers(t *testing.T) {
	withTestDevToken(t)
	resetOriginTitleState(t)
	withISRCCatalogFake(t, map[string][]applemusicSong{})
	withHanTitleReading(t, map[string]string{"愛的就是你": "ai de jiu shi ni"})
	appleStorefrontArtistMu.Lock()
	savedNames := appleStorefrontArtistCache
	appleStorefrontArtistCache = map[string][]string{}
	appleStorefrontArtistMu.Unlock()
	t.Cleanup(func() {
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache = savedNames
		appleStorefrontArtistMu.Unlock()
	})
	seed := func(title string) {
		key := normLoose("Leehom Wang") + "|" + normLoose("The One and Only")
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache[key] = nil
		appleStorefrontArtistMu.Unlock()
		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleCache[key+"|"+normLoose(title)] = "愛的就是你"
		appleStorefrontTitleMu.Unlock()
	}
	seed("Jie Bu Liao Ni (Album Version)")
	seed("Ai De Jiu Shi Ni")
	samples := []string{originSimplifiedLRC}
	for _, c := range []struct {
		title string
		want  string
	}{{"Jie Bu Liao Ni (Album Version)", ""}, {"Ai De Jiu Shi Ni", "愛的就是你"}} {
		if got := titleReverseOriginTitle(qqRoundCtx(), "Leehom Wang", c.title, "The One and Only", 295, samples, ""); got != c.want {
			t.Errorf("标题反查 %q: %q,期望 %q", c.title, got, c.want)
		}
		if got := lyricOriginRecording(qqRoundCtx(), "Leehom Wang", c.title, "The One and Only", 295, samples, ""); got.title != c.want {
			t.Errorf("原产地曲名轮 %q: %q,期望 %q", c.title, got.title, c.want)
		}
	}
}
