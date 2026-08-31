package main

import (
	"os"
	"reflect"
	"testing"
)

// mbAliasCandidatesForRetry 的判据(2026-08-20 加,当时叫 mbPrimaryNameForRetry、只给
// 一个"主名"字符串;2026-08-30 改成给全部已登记写法,见其声明处头注)。
//
// 起因是真实反馈:《Hurry Up Tomorrow》里的「Cry For Me」搜不到歌词。实测原因是 Apple
// Music 把歌手标成 Abel Tesfaye(本名),而五个歌词源全按 The Weeknd 索引 —— 原样查
// 0 条候选,换成 The Weeknd 五个源全有。MB 搜 "Abel Tesfaye" 的首条就是 score=100 /
// name="The Weeknd",数据一直在手上,只是没被用。
//
// 下面这份别名列表是从 MusicBrainz 真实抓下来的(artist c8b03190-306c-4120-bb0b-
// 6f2ebfc06ea9,2026-08-30 重新核对过 primary 字段的真实值——"The Weeknd"这条本身
// primary=false,反而是从没用过的日文别名 primary=true,这正是 2026-08-30 那次改动
// 不能按 alias.Primary 过滤的实测依据),不是编的。
func TestMBAliasCandidatesForRetry(t *testing.T) {
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
		want    []string
	}{
		{
			name:    "本名标签 → 换成艺名主名+其它同类型别名(真实案例)",
			primary: "The Weeknd", aliases: weeknd, raw: "Abel Tesfaye",
			want: []string{"The Weeknd", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{
			name:    "大小写/空格差异照样算命中(normLoose 口径)",
			primary: "The Weeknd", aliases: weeknd, raw: "abel  TESFAYE",
			want: []string{"The Weeknd", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{
			// 命中判据认法定名(这里只问「MB 认不认识这个写法」,不是挑展示名),但
			// 候选列表本身跟"用哪个写法命中"无关——排除的只是 raw 自己,"Abel Tesfaye"
			// 这条 Artist name 跟 raw("Abel Makkonen Tesfaye")不是同一个字符串,照样在。
			name:    "法定名也算证据 —— 这里只问「MB 认不认识这个写法」,不是挑展示名",
			primary: "The Weeknd", aliases: weeknd, raw: "Abel Makkonen Tesfaye",
			want: []string{"The Weeknd", "Abel Tesfaye", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{
			// 同理:命中判据认这条拼错的搜索提示别名(它正是为这种写法登记的),候选
			// 列表不受影响——raw 是 "The Weekend"(Search hint),不等于任何 Artist
			// name 候选,四条都在。
			name:    "拼错的搜索提示别名同样算命中(候选不受影响)",
			primary: "The Weeknd", aliases: weeknd, raw: "The Weekend",
			want: []string{"The Weeknd", "Abel Tesfaye", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{
			name:    "本地标签已经是主名:主名本身被排除,只剩其它候选(不再整体返回空)",
			primary: "The Weeknd", aliases: weeknd, raw: "The Weeknd",
			want: []string{"Abel Tesfaye", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{
			name:    "只是姓氏之类的部分命中:不认 —— 模糊搜到的人不能拿来当身份",
			primary: "The Weeknd", aliases: weeknd, raw: "Tesfaye", want: nil,
		},
		{
			name:    "本地标签压根不在这位艺人名下:不认",
			primary: "The Weeknd", aliases: weeknd, raw: "Drake", want: nil,
		},
		{
			name:    "主名为空:不认",
			primary: "", aliases: weeknd, raw: "Abel Tesfaye", want: nil,
		},
		{
			name:    "本地标签为空:不认",
			primary: "The Weeknd", aliases: weeknd, raw: "", want: nil,
		},
		{
			name:    "一条别名都没有、且主名跟本地标签不同:没有任何证据证明 raw 是这个人,不认",
			primary: "The Weeknd", aliases: nil, raw: "Abel Tesfaye", want: nil,
		},
	}
	for _, c := range cases {
		got := mbAliasCandidatesForRetry(c.primary, c.aliases, c.raw)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: mbAliasCandidatesForRetry(%q, …, %q) = %v, want %v",
				c.name, c.primary, c.raw, got, c.want)
		}
	}
}

// 方大同这个真实案例(见 musicBrainzArtistAliases 头注):MusicBrainz 上这位歌手的
// 主名登记的就是"方大同"本身,本地标签恰好也是"方大同"时,旧版本一看"主名==本地标签"
// 就地返回空——这个测试锁定"主名等于本地标签也不该整体放弃"这条判据,防止回归。
func TestMBAliasCandidatesForRetryPrimaryEqualsRawStillReturnsOtherAliases(t *testing.T) {
	aliases := []mbAlias{
		{Name: "方大同", Type: "Artist name", Locale: "zh"},
		{Name: "Khalil Fong Tai Tung", Type: "Legal name", Locale: "en"},
		{Name: "Khalil Fong", Type: "Artist name", Locale: "en"},
	}
	got := mbAliasCandidatesForRetry("方大同", aliases, "方大同")
	want := []string{"Khalil Fong"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// 查空**不落盘**、查到才落盘(2026-08-20)。
//
// 这条不是洁癖:MusicBrainz 限速按 IP、1 req/s,而 musicbrainzThrottle 是进程内节流 ——
// 常驻 collector、手动搜索那个一次性 CLI、跑测试的进程各自计时,互相不知道。撞上 503
// 就返回空;要是把空也永久写进文件,一次偶发限速会把这位歌手永久钉死在"没有别名"上,
// 而这条兜底恰恰是"五个源一条候选都没有"时最后的救命绳。⚠️ artistAliasCache 当初就是
// 这么做的(空值永久落盘),2026-08-30 那英《微笑着离去》真撞上了(MusicBrainz 503 →
// 语言闸误杀真候选),已改成跟这里一致的"只存非空"规则,见 musicbrainz.go 里
// saveArtistAliasCache 的注释。
func TestMBPrimaryNameCachePersistsOnlyHits(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/primary.json"

	savedCache, savedPath, savedDirty := mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty
	defer func() {
		mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty = savedCache, savedPath, savedDirty
	}()

	mbPrimaryNamePath = path
	mbPrimaryNameCache = map[string][]string{
		"Abel Tesfaye": {"The Weeknd"}, // 查到了
		"Nobody Here":  nil,            // 查空(可能只是被限速)
	}
	mbPrimaryNameDirty = true
	saveMBPrimaryNameCache()

	mbPrimaryNameCache = map[string][]string{}
	loadMBPrimaryNameCache(path)
	if got := mbPrimaryNameCache["Abel Tesfaye"]; !reflect.DeepEqual(got, []string{"The Weeknd"}) {
		t.Errorf("查到的那条没被持久化:got %v", got)
	}
	if _, ok := mbPrimaryNameCache["Nobody Here"]; ok {
		t.Error("查空的那条落盘了 —— 一次偶发限速会被永久钉死")
	}

	// 没有路径时(单测/一次性子命令)不写任何文件,也不该 panic。
	mbPrimaryNamePath = ""
	mbPrimaryNameDirty = true
	saveMBPrimaryNameCache()
}

// 磁盘上已有的旧格式缓存(值是裸字符串,2026-08-30 之前的产物)不能因为这次格式升级就
// 整份作废——见 loadMBPrimaryNameCache 头注。
func TestMBPrimaryNameCacheLoadsLegacyFormat(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/primary.json"
	legacy := `{"Abel Tesfaye":"The Weeknd","Khalil Fong":"方大同"}`
	if err := os.WriteFile(path, []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}

	savedCache, savedPath, savedDirty := mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty
	defer func() {
		mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty = savedCache, savedPath, savedDirty
	}()

	mbPrimaryNameCache = map[string][]string{}
	loadMBPrimaryNameCache(path)
	if got := mbPrimaryNameCache["Abel Tesfaye"]; !reflect.DeepEqual(got, []string{"The Weeknd"}) {
		t.Errorf("旧格式没有被正确迁移:got %v", got)
	}
	if got := mbPrimaryNameCache["Khalil Fong"]; !reflect.DeepEqual(got, []string{"方大同"}) {
		t.Errorf("旧格式没有被正确迁移:got %v", got)
	}
}
