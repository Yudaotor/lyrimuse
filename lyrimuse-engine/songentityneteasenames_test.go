package main

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestNeteaseNamesDue(t *testing.T) {
	now := time.Unix(2_000_000_000, 0)
	link := func(id string) enrichEntry { return enrichEntry{NeteaseURL: "https://music.163.com/song?id=" + id} }
	entries := map[string]enrichEntry{"a": link("30"), "b": link("10"), "c": link("10"), "d": link("20"), "e": {}}
	have := map[string]neteaseCatalogName{
		"20": {Checked: now.Add(-time.Hour).Unix()},
		"30": {Checked: now.Add(-neteaseNamesRecheck - time.Hour).Unix()},
	}
	if got := neteaseNamesDue(entries, have, now); !slices.Equal(got, []string{"10", "30"}) {
		t.Errorf("没问过的、过期的要问,刚问过的不问,同一个 id 只问一次: %v", got)
	}
}

func TestFetchNeteaseNames(t *testing.T) {
	var ids []string
	for i := range 450 {
		ids = append(ids, time.Duration(i+1).String())
	}
	var sizes []int
	fetch := func(_ context.Context, batch []string) (map[string]neteaseCatalogName, bool) {
		sizes = append(sizes, len(batch))
		if len(sizes) == 2 {
			return nil, false
		}
		out := map[string]neteaseCatalogName{}
		for _, id := range batch[:len(batch)-1] {
			out[id] = neteaseCatalogName{Name: "n-" + id, Artists: []string{"A"}, DurationSecs: 100}
		}
		return out, true
	}
	have := map[string]neteaseCatalogName{}
	now := time.Unix(2_000_000_000, 0)
	requests, complete := fetchNeteaseNames(context.Background(), ids, have, now, 0, 0, fetch, func() {})
	if requests != 4 || !slices.Equal(sizes, []int{200, 200, 200, 50}) || !complete {
		t.Errorf("一次最多 %d 个 id,没问成的那一批等一下重问: requests=%d sizes=%v complete=%v", neteaseNamesBatch, requests, sizes, complete)
	}
	if _, ok := have[ids[200]]; !ok {
		t.Error("重问成了的那一批记下")
	}
	calls := 0
	failing := func(_ context.Context, batch []string) (map[string]neteaseCatalogName, bool) {
		calls++
		return nil, false
	}
	if requests, complete := fetchNeteaseNames(context.Background(), ids, map[string]neteaseCatalogName{}, now, 0, 0, failing, func() {}); complete ||
		requests != catalogSweepMaxFailures || calls != catalogSweepMaxFailures {
		t.Errorf("一直没问成就停: requests=%d calls=%d complete=%v", requests, calls, complete)
	}
	if rec := have[ids[0]]; rec.Name != "n-"+ids[0] || rec.Checked != now.Unix() {
		t.Errorf("记下登记名和问的时刻: %+v", rec)
	}
	if rec, ok := have[ids[199]]; !ok || rec.Name != "" {
		t.Errorf("网易云没有的也记成问过,登记名为空: %+v %v", rec, ok)
	}
}

// 网易云登记名:链接核对过之后,别名把外文写法并进来;歌手放宽到这首歌登记过的任一歌手(Apple 美区的英文名)。
func TestSongEntityNeteaseNameEdges(t *testing.T) {
	netease := "https://music.163.com/song?id=186016"
	apple := "https://music.apple.com/cn/album/x/1?i=535"
	ne := map[string]neteaseCatalogName{"186016": {Name: "晴天", Artists: []string{"周杰伦"}, Aliases: []string{"Sunny Day"}, DurationSecs: 269}}
	ap := map[string]appleCatalogNames{"535": {DurationSecs: 269.1, Names: map[string]appleCatalogName{
		"cn": {Name: "晴天", Artist: "周杰伦"}, "us": {Name: "Qing Tian", Artist: "Jay Chou"}}}}
	build := func(withApple bool, xSecs float64) map[string]string {
		zh := songTestVariant("周杰伦|晴天|叶惠美", enrichEntry{DurationSecs: 269.2, NeteaseURL: netease}, nil)
		if withApple {
			zh = songTestVariant("周杰伦|晴天|叶惠美", enrichEntry{DurationSecs: 269.2, NeteaseURL: netease, AppleURL: apple}, nil)
		}
		vs := []songVariant{zh, songTestVariant("Jay Chou|Sunny Day|Yeh Hui-Mei", enrichEntry{DurationSecs: xSecs}, nil)}
		attachAppleNames(vs, ap)
		attachNeteaseNames(vs, ne)
		_, of := songTestBuild(t, vs, nil)
		return of
	}
	if !songTestSame(build(true, 269.4), "周杰伦|晴天|叶惠美", "Jay Chou|Sunny Day|Yeh Hui-Mei") {
		t.Error("网易云别名 + Apple 美区歌手,英文写法应当并进来")
	}
	if songTestSame(build(false, 269.4), "周杰伦|晴天|叶惠美", "Jay Chou|Sunny Day|Yeh Hui-Mei") {
		t.Error("只有网易云登记的歌手(周杰伦)时对不上英文署名,不该并")
	}
	if songTestSame(build(true, 280), "周杰伦|晴天|叶惠美", "Jay Chou|Sunny Day|Yeh Hui-Mei") {
		t.Error("时长差过闸的不该并")
	}
}

// 挂网易云名字之前核对链接:时长对不上、登记名和别名都不是这条写法的写法族、歌手对不上的,都不挂。
func TestAttachNeteaseNamesVerifiesLink(t *testing.T) {
	netease := "https://music.163.com/song?id=150560"
	rec := func(name string, aliases []string, artist string, secs float64) map[string]neteaseCatalogName {
		return map[string]neteaseCatalogName{"150560": {Name: name, Aliases: aliases, Artists: []string{artist}, DurationSecs: secs}}
	}
	cases := []struct {
		name  string
		key   string
		names map[string]neteaseCatalogName
		want  bool
	}{
		{"登记名对得上", "陶喆|讨厌红楼梦|黑色柳丁", rec("讨厌红楼梦", []string{"Let's Fall In Love"}, "陶喆", 242.37), true},
		{"别名对得上", "陶喆|Let's Fall in Love|黑色柳丁", rec("讨厌红楼梦", []string{"Let's Fall In Love"}, "陶喆", 242.37), true},
		{"时长对不上", "陶喆|讨厌红楼梦|黑色柳丁", rec("讨厌红楼梦", nil, "陶喆", 260), false},
		{"链接配到别的歌", "陶喆|讨厌红楼梦|黑色柳丁", rec("黑色柳丁", nil, "陶喆", 242.37), false},
		{"歌手对不上", "陶喆|讨厌红楼梦|黑色柳丁", rec("讨厌红楼梦", nil, "别人", 242.37), false},
	}
	for _, c := range cases {
		vs := []songVariant{songTestVariant(c.key, enrichEntry{DurationSecs: 242, NeteaseURL: netease}, nil)}
		attachNeteaseNames(vs, c.names)
		if got := len(vs[0].catalogNames) > 0; got != c.want {
			t.Errorf("%s: 挂上=%v,应为 %v", c.name, got, c.want)
		}
	}
}

// 联网补扫的请求都标成后台(只用主机限速里富余的额度,不跟正在播的那首排队)。
func TestCatalogSweepsUseBackgroundOutbound(t *testing.T) {
	for file, want := range map[string]string{
		"songentitynames.go":        "fetchAppleNames(withBackgroundOutbound(ctx),",
		"songentityneteasenames.go": "fetchNeteaseNames(withBackgroundOutbound(ctx),",
		"songentitymb.go":           "fetchMBRecordings(withBackgroundOutbound(ctx),",
		"applecreditlinks.go":       "recheckAppleCreditLinks(withBackgroundOutbound(ctx),",
		"recordingisrc.go":          "appleCatalogSongsByID(withBackgroundOutbound(ctx), sf, ids)",
	} {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(src), want) {
			t.Errorf("%s 的补扫请求要标成后台: %s", file, want)
		}
	}
}
