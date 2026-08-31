package main

import "testing"

// 2026-08-28 真实bug复现:Khalil Fong《Revisited》= 网易云《回留》,同一张专辑
// 《梦想家 The Dreamer》,时长精确到毫秒吻合(236.344s vs 236.343s),标题文字层面毫无
// 关联,是这套"标题反查"兜底唯一的判据来源。断言用的时长数字都是从真实接口核对过的。
func TestBestAlbumTrackByDuration(t *testing.T) {
	dreamer := []albumTrack{
		{title: "XZMHXDXH", artist: "方大同", duration: 180},
		{title: "才二十三", artist: "方大同", duration: 224.498},
		{title: "回留", artist: "方大同", duration: 236.343},
		{title: "没啥好说", artist: "方大同", duration: 200},
	}
	cases := []struct {
		name     string
		tracks   []albumTrack
		duration float64
		want     string
	}{
		{"精确命中(真实案例)", dreamer, 236.344, "回留"},
		{"容差内的小误差也认", dreamer, 235.0, "回留"},
		{"超出容差不认,宁可不给", dreamer, 233.0, ""},
		{"没有任何曲目在容差内", dreamer, 999, ""},
		{"两首歌时长同样接近,拒绝猜", []albumTrack{
			{title: "A", duration: 200},
			{title: "B", duration: 200.5},
		}, 200.25, ""},
		{"同一首歌被两个专辑重复收录,时长分毫不差,不算歧义(2026-08-30 真实案例:方大同" +
			"《爱爱爱》同时收录在专辑《爱爱爱》和合辑《The Soulboy Collection》,时长都是" +
			"213.266s)", []albumTrack{
			{title: "爱爱爱", artist: "方大同", duration: 213.266},
			{title: "爱爱爱", artist: "方大同", duration: 213.266},
		}, 213, "爱爱爱"},
		{"空标题的曲目跳过", []albumTrack{
			{title: "", duration: 236.343},
			{title: "回留", duration: 236.343},
		}, 236.344, "回留"},
		{"空专辑", nil, 236.344, ""},
	}
	for _, c := range cases {
		if got := bestAlbumTrackByDuration(c.tracks, c.duration); got != c.want {
			t.Errorf("%s: bestAlbumTrackByDuration(...) = %q, want %q", c.name, got, c.want)
		}
	}
}
