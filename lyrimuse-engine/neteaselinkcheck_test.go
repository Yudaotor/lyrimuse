package main

import (
	"os"
	"slices"
	"strings"
	"testing"
)

// 网易云链接重核的判据:对得上的、两边文字不同的译名不动;另一个版本、同 id 另一条录音、同一种文字毫不相干、拼音读不上的判错。
func TestNeteaseLinkMismatch(t *testing.T) {
	restore := hanTitleReading
	t.Cleanup(func() { hanTitleReading = restore })
	hanTitleReading = func(han string) []string {
		return map[string][]string{
			"你伤了我的心": {"ni", "shang", "le", "wo", "de", "xin"},
			"爱的就是你":  {"ai", "de", "jiu", "shi", "ni"},
		}[han]
	}
	rec := func(name string, secs float64, aliases ...string) neteaseCatalogName {
		return neteaseCatalogName{Name: name, Artists: []string{"歌手"}, Aliases: aliases, DurationSecs: secs}
	}
	owner := func(title string, isrcs ...string) []neteaseLinkOwner {
		return []neteaseLinkOwner{{key: "米津玄師|" + title + "|BOOTLEG", title: title, isrcs: isrcs}}
	}
	cases := []struct {
		why          string
		title, album string
		secs         float64
		isrcs, names []string
		rec          neteaseCatalogName
		owners       []neteaseLinkOwner
		wrong        bool
	}{
		{"歌名对得上(繁简)", "愛在", "", 244, nil, nil, rec("爱在", 243.7), nil, false},
		{"别名对得上", "Close to You", "", 246, nil, nil, rec("千纸鹤", 246.2, "Close to You"), nil, false},
		{"别名对得上(同一种文字)", "Kindness", "", 240, nil, nil, rec("Yasashisa", 240, "Kindness"), nil, false},
		{"版本词不同但时长对得上,不判", "Song", "", 240, nil, nil, rec("Song (Live)", 240.5), nil, false},
		{"同 id 另一条写法也对不上登记名,不判", "Uchiagehanabi", "", 289.3, []string{"JPU901700712"}, nil,
			rec("春雷", 288.9), owner("别的歌", "JPU901703001"), false},
		{"拉丁对拉丁只跟别名有相同的词,不判", "Lonely Trouble", "", 200, nil, nil, rec("Starlight", 200, "Big Trouble"), nil, false},
		{"平假名对片假名不逐字比", "はなたば", "", 286, nil, nil, rec("ハナタバ", 286), nil, false},
		{"Apple 别的区的名字对得上", "Twenty Three", "", 224.5, nil, []string{"才二十三"}, rec("才二十三", 224.5), nil, false},
		{"康熙部首折成标准字", "⽩", "王", 288.9, nil, nil, rec("白", 288.9), nil, false},
		{"英文名对原文名,不判", "Park", "未来", 241.3, nil, nil, rec("公园", 241.3), nil, false},
		{"罗马字对原文名、别名是英文译名,不判", "YASASHISA", "", 240.1, nil, nil, rec("優しさ", 240.1, "Kindness"), nil, false},
		{"另一个版本", "Lady Sue", "This Love", 217, nil, nil, rec("苏丽珍 (Live)", 131.9), nil, true},
		{"时长差得远、版本词一样,不判", "Airport in 10:30", "乐之路", 280.8, nil, nil, rec("飞机场的10:30", 295), nil, false},
		{"同一种文字也认版本(包含算对得上之前先看版本)", "偷笑", "This Love", 227, nil, nil, rec("偷笑 (Live)", 235.1), nil, true},
		{"版本词不带括号、字面相同,不判", "阿拉斯加海湾 伴奏", "", 230, nil, nil, rec("阿拉斯加海湾 (伴奏)", 236), nil, false},
		{"汉字对汉字有相同的字,不判", "我的情歌", "", 240, nil, nil, rec("情歌王", 240), nil, false},
		{"同 id 另一条写法是这首、ISRC 没有相同的", "Uchiagehanabi", "", 289.3, []string{"JPU901700712"}, nil,
			rec("春雷", 288.9), owner("春雷", "JPU901703001"), true},
		{"同 id 另一条写法 ISRC 相同,不判", "Uchiagehanabi", "", 289.3, []string{"JPU901700712"}, nil,
			rec("春雷", 288.9), owner("春雷", "JPU-901-700712"), false},
		{"同 id 另一条写法没有 ISRC,不判", "Uchiagehanabi", "", 289.3, []string{"JPU901700712"}, nil,
			rec("春雷", 288.9), owner("春雷"), false},
		{"拉丁对拉丁一个词都不同", "I Knew You Were Trouble. - Karaoke Version", "Red", 220.9, nil, nil, rec("Starlight", 220.6), nil, true},
		{"拉丁对拉丁有相同的词,不判", "Bang Chan Eternity", "", 192, nil, nil, rec("ESCAPE (Bang Chan & Hyunjin)", 191.1), nil, false},
		{"汉字对汉字一个字都不同", "Twenty Three", "", 224.5, nil, []string{"才二十三"}, rec("爱无人签收", 226.4), nil, true},
		{"带假名的不逐字比", "花束", "", 286, nil, nil, rec("はなたば", 286), nil, false},
		{"拼音读不上", "Wo De Qing Ge", "Revolution", 243, nil, nil, rec("你伤了我的心", 244), nil, true},
		{"拼音读得上", "Ai De Jiu Shi Ni", "", 289, nil, nil, rec("爱的就是你", 295.1), nil, false},
		{"登记信息里没有这首", "Song", "", 200, nil, nil, neteaseCatalogName{}, nil, false},
	}
	for _, c := range cases {
		if got := neteaseLinkMismatch(c.title, c.album, c.secs, c.isrcs, c.names, c.rec, c.owners) != ""; got != c.wrong {
			t.Errorf("%s: %q → %q 判错 = %v, want %v", c.why, c.title, c.rec.Name, got, c.wrong)
		}
	}
}

func TestClearWrongNeteaseLink(t *testing.T) {
	link := "https://music.163.com/song?id=512359198"
	e := clearWrongNeteaseLink(enrichEntry{NeteaseURL: link, PeripheralRetryCount: 5, CoverURL: "c", CoverSource: "netease",
		CoverAlbum: "BOOTLEG", AccentColor: "#fff", MotionCoverURL: "m", MotionCoverChecked: true}, "Uchiagehanabi - Single")
	if e.NeteaseURL != "" || e.NeteaseRejected != "512359198" || e.PeripheralRetryCount != 0 {
		t.Errorf("清链接、记下 id、补全计数归零: %+v", e)
	}
	if e.CoverURL != "" || e.CoverSource != "" || e.CoverAlbum != "" || e.AccentColor != "" || e.MotionCoverURL != "" || e.MotionCoverChecked {
		t.Errorf("封面专辑跟本地专辑对不上的网易云封面一族一起清: %+v", e)
	}
	for _, c := range []struct {
		why, coverAlbum, album string
		kept                   bool
	}{
		{"专辑逐字相同,留着", "Red", "Red", true},
		{"一个包含另一个、版本词一样,留着", "神經志 The Journal", "神经志", true},
		{"一个包含另一个、版本词不同,清", "半生雪 (DJ版)", "半生雪", false},
		{"只有一个词相同,清", "Grandes Exitos", "30 Exitos Inolvidables", false},
		{"本地没报专辑,清", "Red", "", false},
	} {
		e := clearWrongNeteaseLink(enrichEntry{NeteaseURL: link, CoverURL: "c", CoverSource: "netease", CoverAlbum: c.coverAlbum}, c.album)
		if kept := e.CoverURL == "c"; kept != c.kept {
			t.Errorf("%s: 封面专辑 %q、本地专辑 %q,封面留着 = %v", c.why, c.coverAlbum, c.album, kept)
		}
	}
	if e := clearWrongNeteaseLink(enrichEntry{NeteaseURL: link, CoverURL: "c", CoverSource: "device", CoverAlbum: "X"}, "Y"); e.CoverURL != "c" {
		t.Errorf("别的来源的封面不动: %+v", e)
	}
	if staleRejectedNeteaseCover(enrichEntry{NeteaseURL: link, NeteaseRejected: "1", CoverSource: "netease", CoverAlbum: "X"}, "Y") {
		t.Error("还挂着网易云链接的归链接重核,不算判错留下的封面")
	}
}

// 判错过的那首:外围补全这一轮再配到它时不收,去重合并时链接、封面不从另一条并回来,判错的 id 跟着并过来。
func TestNeteaseRejectionSticks(t *testing.T) {
	link := func(id string) string { return "https://music.163.com/song?id=" + id }
	if !neteaseResultRejected(enrichEntry{NeteaseRejected: "1"}, enrichEntry{NeteaseURL: link("1")}) {
		t.Error("这一轮配到判错过的那首,不收")
	}
	if neteaseResultRejected(enrichEntry{NeteaseRejected: "1"}, enrichEntry{NeteaseURL: link("2")}) ||
		neteaseResultRejected(enrichEntry{}, enrichEntry{NeteaseURL: link("1")}) {
		t.Error("别的 id、没判错过的照收")
	}
	if w := mergePeripheralInto(enrichEntry{NeteaseRejected: "1"}, enrichEntry{NeteaseURL: link("1")}); w.NeteaseURL != "" {
		t.Errorf("判错过的 id 不从另一条并回来: %+v", w)
	}
	if w := mergePeripheralInto(enrichEntry{NeteaseRejected: "1"}, enrichEntry{NeteaseURL: link("2")}); w.NeteaseURL != link("2") {
		t.Errorf("别的 id 照并: %+v", w)
	}
	if w := mergePeripheralInto(enrichEntry{}, enrichEntry{NeteaseRejected: "1"}); w.NeteaseRejected != "1" {
		t.Errorf("判错的 id 跟着并过来: %+v", w)
	}
	if w := mergePeripheralInto(enrichEntry{NeteaseRejected: "1"},
		enrichEntry{NeteaseURL: link("1"), CoverURL: "c", CoverSource: "netease", AccentColor: "#fff"}); w.CoverURL != "" || w.AccentColor != "" {
		t.Errorf("判错过那首的网易云封面、主色不从另一条并回来: %+v", w)
	}
	if w := mergePeripheralInto(enrichEntry{NeteaseRejected: "1"}, enrichEntry{NeteaseURL: link("2"), CoverURL: "c", CoverSource: "netease"}); w.CoverURL != "c" {
		t.Errorf("别的 id 的网易云封面照并: %+v", w)
	}
	if w := mergePeripheralInto(enrichEntry{NeteaseRejected: "1"}, enrichEntry{NeteaseURL: link("1"), CoverURL: "c", CoverSource: "qq"}); w.CoverURL != "c" {
		t.Errorf("别的来源的封面照并: %+v", w)
	}
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`if fresh.NeteaseURL != "" && !neteaseResultRejected(e, fresh) {`,
		`rejectedNeteaseCover := fresh.CoverSource == "netease" && neteaseResultRejected(e, fresh)`,
		`if !rejectedNeteaseCover && coverSwapAllowedWith(`} {
		if !strings.Contains(string(src), want) {
			t.Errorf("外围补全收网易云结果时没挡判错过的那首: %s", want)
		}
	}
	names, err := os.ReadFile("songentityneteasenames.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(names), "recheckNeteaseLinks(readNeteaseNames(neteaseNamesPath()), readAppleNames(appleNamesPath()))") {
		t.Error("网易云名字补扫之后没跑链接重核")
	}
}

func TestRecheckNeteaseLinks(t *testing.T) {
	cachePath := withDeferredEnrichSaves(t)
	link := func(id string) string { return "https://music.163.com/song?id=" + id }
	withEnrichCache(t, map[string]enrichEntry{
		"DAOKO×米津玄師|Uchiagehanabi|Uchiagehanabi - Single": {NeteaseURL: link("512359198"), DurationSecs: 289.3,
			ISRCs: []string{"JPU901700712"}, CoverURL: "c1", CoverSource: "device", CoverAlbum: "Uchiagehanabi - Single"},
		"米津玄師|春雷|BOOTLEG": {NeteaseURL: link("512359198"), DurationSecs: 288.9, ISRCs: []string{"JPU901703001"}},
		"KOBUKURO|桜 - Sakura|": {NeteaseURL: link("2"), DurationSecs: 389, CoverURL: "c2", CoverSource: "netease",
			CoverAlbum: "カフェで聴きたい Sakura Jazz Piano", PeripheralRetryCount: 5},
		"方大同|爱在|": {NeteaseURL: link("3"), DurationSecs: 244},
		"没登记|歌|":  {NeteaseURL: link("4"), DurationSecs: 200},
		"没链接|歌|":  {DurationSecs: 200},
		"Fito Olivares y La Pura Sabrosura|La Negra Catalina|30 Exitos Inolvidables": {NeteaseRejected: "5", CoverURL: "c3",
			CoverSource: "netease", CoverAlbum: "Grandes Exitos", AccentColor: "#000", PeripheralRetryCount: 5},
		"判错过|本地没报专辑|":   {NeteaseRejected: "6", CoverURL: "c4", CoverSource: "netease", CoverAlbum: "X"},
		"判错过|专辑对得上|Red": {NeteaseRejected: "7", CoverURL: "c5", CoverSource: "netease", CoverAlbum: "Red"},
		"判错过|别的来源|Y":    {NeteaseRejected: "8", CoverURL: "c6", CoverSource: "qq", CoverAlbum: "X"},
		"没判错过|歌|Y":      {CoverURL: "c7", CoverSource: "netease", CoverAlbum: "X"},
	})
	registry := map[string]neteaseCatalogName{
		"512359198": {Name: "春雷", Artists: []string{"米津玄師"}, DurationSecs: 288.9},
		"2":         {Name: "桜 (Instrumental)", Artists: []string{"Kaoru Sakuma"}, DurationSecs: 327.8},
		"3":         {Name: "爱在", Artists: []string{"方大同"}, DurationSecs: 243.7},
	}
	if n := recheckNeteaseLinks(registry, nil); n != 2 {
		t.Fatalf("清掉 %d 条,want 2", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["DAOKO×米津玄師|Uchiagehanabi|Uchiagehanabi - Single"]; e.NeteaseURL != "" || e.NeteaseRejected != "512359198" || e.CoverURL != "c1" {
		t.Errorf("同 id 另一条录音:清链接、记下 id,设备封面不动: %+v", e)
	}
	if e := enrichCache["米津玄師|春雷|BOOTLEG"]; e.NeteaseURL != link("512359198") {
		t.Errorf("对得上的那条不动: %+v", e)
	}
	if e := enrichCache["KOBUKURO|桜 - Sakura|"]; e.NeteaseURL != "" || e.CoverURL != "" || e.PeripheralRetryCount != 0 {
		t.Errorf("另一个版本:链接和网易云封面一起清,补全计数归零: %+v", e)
	}
	if e := enrichCache["方大同|爱在|"]; e.NeteaseURL != link("3") {
		t.Errorf("对得上的不动: %+v", e)
	}
	if e := enrichCache["没登记|歌|"]; e.NeteaseURL != link("4") {
		t.Errorf("登记信息里没有的不动: %+v", e)
	}
	if e := enrichCache["Fito Olivares y La Pura Sabrosura|La Negra Catalina|30 Exitos Inolvidables"]; e.CoverURL != "" || e.AccentColor != "" ||
		e.NeteaseRejected != "5" || e.PeripheralRetryCount != 5 {
		t.Errorf("判错过的条目留下的网易云封面对不上本地专辑:清封面,判错的 id、补全计数不动: %+v", e)
	}
	for _, k := range []string{"判错过|本地没报专辑|", "判错过|专辑对得上|Red", "判错过|别的来源|Y", "没判错过|歌|Y"} {
		if enrichCache[k].CoverURL == "" {
			t.Errorf("%s: 封面不该清", k)
		}
	}
	if got := songSortedKeys(enrichPendingKeys); !slices.Equal(got, []string{"DAOKO×米津玄師|Uchiagehanabi|Uchiagehanabi - Single",
		"Fito Olivares y La Pura Sabrosura|La Negra Catalina|30 Exitos Inolvidables", "KOBUKURO|桜 - Sakura|"}) {
		t.Errorf("清掉的条目记进待落盘: %q", got)
	}
	if err := enrichSavesDeferred(cachePath); err != nil {
		t.Error(err)
	}
}

// 这一轮只清了判错留下的封面:同样置脏(整份落盘只在脏时才写)、走小文件延后落盘。
func TestRecheckNeteaseLinksLeftoverCoverSaves(t *testing.T) {
	cachePath := withDeferredEnrichSaves(t)
	withEnrichCache(t, map[string]enrichEntry{"歌手|歌|Y": {NeteaseRejected: "1", CoverURL: "c", CoverSource: "netease", CoverAlbum: "X"}})
	enrichMu.Lock()
	enrichDirty = false
	enrichMu.Unlock()
	if n := recheckNeteaseLinks(nil, nil); n != 0 {
		t.Fatalf("清掉 %d 条链接,want 0", n)
	}
	enrichMu.Lock()
	dirty, cover := enrichDirty, enrichCache["歌手|歌|Y"].CoverURL
	enrichMu.Unlock()
	if !dirty || cover != "" {
		t.Errorf("清了留下的封面:置脏 = %v、封面 = %q", dirty, cover)
	}
	if err := enrichSavesDeferred(cachePath); err != nil {
		t.Error(err)
	}
}
