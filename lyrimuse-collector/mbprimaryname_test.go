package main

import "testing"

// mbPrimaryNameForRetry 的判据(2026-08-20)。
//
// 起因是真实反馈:《Hurry Up Tomorrow》里的「Cry For Me」搜不到歌词。实测原因是 Apple
// Music 把歌手标成 Abel Tesfaye(本名),而五个歌词源全按 The Weeknd 索引 —— 原样查
// 0 条候选,换成 The Weeknd 五个源全有。MB 搜 "Abel Tesfaye" 的首条就是 score=100 /
// name="The Weeknd",数据一直在手上,只是没被用。
//
// 下面这份别名列表是 2026-08-20 从 MusicBrainz 真实抓下来的(artist
// c8b03190-306c-4120-bb0b-6f2ebfc06ea9),不是编的。
func TestMBPrimaryNameForRetry(t *testing.T) {
	weeknd := []mbAlias{
		{Name: "Abel Makkonen Tesfaye", Type: "Legal name", Locale: "en"},
		{Name: "Abel Tesfaye", Type: "Artist name", Locale: "en"},
		{Name: "The Weekend", Type: "Search hint"},
		{Name: "The Weeknd", Type: "Artist name", Locale: "en"},
		{Name: "The Weeknd feat. Playboi Carti"},
		{Name: "አቤል መኮንን ተስፋዬ", Type: "Artist name", Locale: "am"},
		{Name: "ザ・ウィークエンド", Type: "Artist name", Locale: "ja"},
	}
	cases := []struct {
		name    string
		primary string
		aliases []mbAlias
		raw     string
		want    string
	}{
		{
			name:    "本名标签 → 换成艺名主名(真实案例)",
			primary: "The Weeknd", aliases: weeknd, raw: "Abel Tesfaye", want: "The Weeknd",
		},
		{
			name:    "大小写/空格差异照样算命中(normLoose 口径)",
			primary: "The Weeknd", aliases: weeknd, raw: "abel  TESFAYE", want: "The Weeknd",
		},
		{
			name:    "法定名也算证据 —— 这里只问「MB 认不认识这个写法」,不是挑展示名",
			primary: "The Weeknd", aliases: weeknd, raw: "Abel Makkonen Tesfaye", want: "The Weeknd",
		},
		{
			name:    "拼错的搜索提示别名同样算(它正是为这种写法登记的)",
			primary: "The Weeknd", aliases: weeknd, raw: "The Weekend", want: "The Weeknd",
		},
		{
			name:    "本地标签已经是主名:不换,免得白跑一轮全源抓取",
			primary: "The Weeknd", aliases: weeknd, raw: "The Weeknd", want: "",
		},
		{
			name:    "只是姓氏之类的部分命中:不认 —— 模糊搜到的人不能拿来当身份",
			primary: "The Weeknd", aliases: weeknd, raw: "Tesfaye", want: "",
		},
		{
			name:    "本地标签压根不在这位艺人名下:不认",
			primary: "The Weeknd", aliases: weeknd, raw: "Drake", want: "",
		},
		{
			name:    "主名为空:不认",
			primary: "", aliases: weeknd, raw: "Abel Tesfaye", want: "",
		},
		{
			name:    "本地标签为空:不认",
			primary: "The Weeknd", aliases: weeknd, raw: "", want: "",
		},
		{
			name:    "一条别名都没有:不认(等于没有任何证据)",
			primary: "The Weeknd", aliases: nil, raw: "Abel Tesfaye", want: "",
		},
	}
	for _, c := range cases {
		if got := mbPrimaryNameForRetry(c.primary, c.aliases, c.raw); got != c.want {
			t.Errorf("%s: mbPrimaryNameForRetry(%q, …, %q) = %q, want %q",
				c.name, c.primary, c.raw, got, c.want)
		}
	}
}

// 查空**不落盘**、查到才落盘(2026-08-20)。
//
// 这条不是洁癖:MusicBrainz 限速按 IP、1 req/s,而 musicbrainzThrottle 是进程内节流 ——
// 常驻 collector、手动搜索那个一次性 CLI、跑测试的进程各自计时,互相不知道。撞上 503
// 就返回空;要是把空也永久写进文件(artistAliasCache 正是那么做的),一次偶发限速会把
// 这位歌手永久钉死在"没有别名"上,而这条兜底恰恰是"五个源一条候选都没有"时最后的救命绳。
func TestMBPrimaryNameCachePersistsOnlyHits(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/primary.json"

	savedCache, savedPath, savedDirty := mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty
	defer func() {
		mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty = savedCache, savedPath, savedDirty
	}()

	mbPrimaryNamePath = path
	mbPrimaryNameCache = map[string]string{
		"Abel Tesfaye": "The Weeknd", // 查到了
		"Nobody Here":  "",           // 查空(可能只是被限速)
	}
	mbPrimaryNameDirty = true
	saveMBPrimaryNameCache()

	mbPrimaryNameCache = map[string]string{}
	loadMBPrimaryNameCache(path)
	if got := mbPrimaryNameCache["Abel Tesfaye"]; got != "The Weeknd" {
		t.Errorf("查到的那条没被持久化:got %q", got)
	}
	if _, ok := mbPrimaryNameCache["Nobody Here"]; ok {
		t.Error("查空的那条落盘了 —— 一次偶发限速会被永久钉死")
	}

	// 没有路径时(单测/一次性子命令)不写任何文件,也不该 panic。
	mbPrimaryNamePath = ""
	mbPrimaryNameDirty = true
	saveMBPrimaryNameCache()
}
