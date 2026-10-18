package main

import "testing"

// 候选歌名括号外带合作署名、本地不带:署名里的每一位都在本地署名里才认;本地是单人署名、客串者不在本地署名里、去掉之后仍不同的不认。
func TestTitleFeatGuestCovered(t *testing.T) {
	for _, c := range []struct {
		cand, local, artist string
		want                bool
	}{
		{"在家里 feat.方大同", "在家里", "家家/方大同", true},
		{"在家里 ft. 方大同", "在家里", "家家、方大同", true},
		{"在家里 feat. 方大同 & 周国贤", "在家里", "家家/方大同", false},
		{"在家里 feat.方大同", "在家里", "家家", false},
		{"在家里 feat.方大同", "在家里", "方大同", false},
		{"在家里 feat.林俊杰", "在家里", "家家/方大同", false},
		{"在家里2 feat.方大同", "在家里", "家家/方大同", false},
		{"在家里 feat.方大同", "在家里 feat. 方大同", "家家/方大同", false},
		{"Feather", "Feather", "A/B", false},
	} {
		if got := titleFeatGuestCovered(c.cand, c.local, c.artist); got != c.want {
			t.Errorf("titleFeatGuestCovered(%q, %q, %q) = %v,期望 %v", c.cand, c.local, c.artist, got, c.want)
		}
	}
	// 接在酷我挑候选上:整条打分照样过版本闸、时长闸。
	item := kuwoSearchItem{SongName: "在家里 feat.方大同", Artist: "家家", Album: "我想要的", Duration: "249"}
	if kuwoCandidateScore(item, "家家/方大同", "在家里", "我想要的", 249) < 0 {
		t.Error("酷我这条应当收下")
	}
	item.Artist = "家家"
	if kuwoCandidateScore(item, "家家", "在家里", "我想要的", 249) >= 0 {
		t.Error("本地署名里没有方大同,不该收")
	}
}
