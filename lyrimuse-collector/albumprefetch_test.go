package main

import "testing"

// 同专辑预取用 albumScore >= 200(normLoose 完全相等)当闸门。这个测试钉住的是那个阈值
// 的**理由**:网易云同一张专辑有多个实体,而 100 分那一档("宽松包含")会把它们混为一谈,
// 选错就会多解析十几首根本没在放的曲目。
func TestAlbumPrefetchGateRejectsNearMisses(t *testing.T) {
	const gate = 200

	same := []struct{ candidate, local string }{
		{"黑色柳丁", "黑色柳丁"},
		{"Bad", "Bad"},
	}
	for _, c := range same {
		if got := albumScore(c.candidate, c.local); got < gate {
			t.Errorf("同一张专辑应当放行: albumScore(%q, %q) = %d, 需要 >= %d",
				c.candidate, c.local, got, gate)
		}
	}

	// 这几个是实测在网易云上跟 "Bad" 并存的其它实体 —— 曲目数各不相同(11/24/5),
	// 放行任何一个都会预取到没在播的曲目。
	nearMiss := []struct{ candidate, local string }{
		{"Bad 25th Anniversary", "Bad"},
		{"Bad (Remix EP)", "Bad"},
		{"King of Pop [Box set]", "Bad"},
		{"The Collection", "Bad"},
		{"Ultrasound 乐之路 1997-2003", "黑色柳丁"},
	}
	for _, c := range nearMiss {
		if got := albumScore(c.candidate, c.local); got >= gate {
			t.Errorf("不是同一张专辑却被放行: albumScore(%q, %q) = %d, 应当 < %d",
				c.candidate, c.local, got, gate)
		}
	}
}
