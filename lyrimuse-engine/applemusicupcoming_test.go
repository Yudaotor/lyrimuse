package main

import "testing"

// App 交来的 Music.app 队列(PlayerQueryTracks 整理好的):当前这首跟 poller 手上的对上了,取后面的。
func TestPickAppleMusicUpcoming(t *testing.T) {
	r := appQueryTracks{
		Current: &appQueryTrack{Title: "Earth Song", Artist: "Michael Jackson"},
		Tracks: []appQueryTrack{
			{Title: "You Are Not Alone", Artist: "Michael Jackson", Album: "HIStory Continues", Duration: 344.825988769531},
			{Title: "The Lost Children", Artist: "Michael Jackson", Album: "Invincible", Duration: 240.533004760742},
		},
	}
	got, ok := pickAppleMusicUpcoming(r, "Michael Jackson", "Earth Song", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("该取到 2 首,得到 ok=%v got=%+v", ok, got)
	}
	if got[0].title != "You Are Not Alone" || got[0].artist != "Michael Jackson" {
		t.Errorf("第 1 首不对: %+v", got[0])
	}
	// 跨专辑是正常的 —— 从本地歌单播时队列里每首的专辑各不相同。
	if got[0].album != "HIStory Continues" || got[1].album != "Invincible" {
		t.Errorf("专辑名不对: %q / %q", got[0].album, got[1].album)
	}
	if got[0].duration != 344.825988769531 {
		t.Errorf("时长 %v —— Music.app 的 duration 本来就是秒,别再除一遍", got[0].duration)
	}
}

// 队列报的当前这首跟 poller 手上的对不上:两边看的不是同一个播放器,照着它预取等于拿一批无关的歌去占解析带宽。
func TestPickAppleMusicUpcomingRejectsMismatchedCurrent(t *testing.T) {
	r := appQueryTracks{
		Current: &appQueryTrack{Title: "别的歌", Artist: "别的歌手"},
		Tracks:  []appQueryTrack{{Title: "A", Artist: "甲", Album: "专辑", Duration: 100}},
	}
	if got, ok := pickAppleMusicUpcoming(r, "Michael Jackson", "Earth Song", 5); ok {
		t.Errorf("当前这首对不上时该返回 false,却返回了 %+v", got)
	}
}

// 守卫拦下(停着、开着随机、云端内容)时 App 交来的是空的;只有当前这首、后面没有能取的,也不算。
func TestPickAppleMusicUpcomingNothingToTake(t *testing.T) {
	current := &appQueryTrack{Title: "乙", Artist: "甲"}
	for name, r := range map[string]appQueryTracks{
		"空的":        {},
		"只有当前这首":    {Current: current},
		"后面都缺歌名或歌手": {Current: current, Tracks: []appQueryTrack{{Title: "", Artist: "丙"}, {Title: "丁"}}},
	} {
		if got, ok := pickAppleMusicUpcoming(r, "甲", "乙", 5); ok {
			t.Errorf("%s: 不该取到,得到 %+v", name, got)
		}
	}
}

func TestPickAppleMusicUpcomingHonorsLimit(t *testing.T) {
	r := appQueryTracks{Current: &appQueryTrack{Title: "当前", Artist: "甲"}}
	for _, n := range []string{"一", "二", "三", "四", "五", "六", "七"} {
		r.Tracks = append(r.Tracks, appQueryTrack{Title: n, Artist: "歌手", Album: "专辑", Duration: 100})
	}
	got, ok := pickAppleMusicUpcoming(r, "甲", "当前", 3)
	if !ok || len(got) != 3 {
		t.Fatalf("该截到 3 首,得到 ok=%v len=%d", ok, len(got))
	}
}
