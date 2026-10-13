// songentitygolden_test.go — 歌曲实体的回归案例集:本机真实的几组写法,和人判过的「哪几条是同一份录音」。
//
// 案例在 testdata/songentity/*.json,一组一个文件,结构见 songGoldenFixture。每个案例带上它涉及的实体的全部写法
// (全库建表时那几个实体整个搬进来),所以只拿这几条建表,结果跟全库建表时一样;采集器(songentitygolden_capture_test.go)
// 写入前核对这一点。
//
// 两层断言:
//   - 划分(硬断言):建出来的实体划分必须跟 truth(人判的同一份录音分组)一样。改规则让哪个案例并错、拆错就红,
//     UPDATE 也不改 truth;真是 truth 判错了,手改文件。
//   - 快照:共享组、全部证据边(含被否决的)、否决、被闸挡下的边数。改规则时有变化是正常的,
//     SONG_ENTITY_GOLDEN_UPDATE=1 重写 expect,看 git diff 逐个确认。
//
// 写法的条目只存建表读的字段(songGoldenEntryKeys);解析决策两槽换成摘好的登记歌名和当前歌词候选的歌名,MusicBrainz
// 身份只存这几位歌手的。正文跟 lyricsgolden 一样保形置乱(同一个案例里所有写法共用一套双射),所以看起来是乱码。
//
// 另有类别覆盖契约(TestSongEntityGoldenCategoryCoverage):songGoldenCategories 每一类至少一个案例,且案例确实体现
// 它的类别。采集方法见 testdata/songentity/README.md。
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"
)

const songGoldenDir = "testdata/songentity"

type songGoldenFixture struct {
	// ID 是文件名(不含 .json)。
	ID string `json:"id"`
	// Category 必须是 songGoldenCategories 里的一个键。
	Category string `json:"category"`
	// Note:为什么挑这组、人是怎么判的(人写)。
	Note       string `json:"note"`
	CapturedAt string `json:"captured_at"`
	// Identities:歌手名 → MusicBrainz mbid,songArtistMatch 读的那份缓存里这几位歌手的条目。
	Identities map[string]string   `json:"artist_identities,omitempty"`
	Splits     [][2]string         `json:"user_splits,omitempty"`
	Variants   []songGoldenVariant `json:"variants"`
	// Truth:人判的同一份录音分组,每条写法恰好出现一次。
	Truth  [][]string         `json:"truth"`
	Expect songGoldenSnapshot `json:"expect"`
}

type songGoldenVariant struct {
	Key         string            `json:"key"`
	Pinned      bool              `json:"pinned,omitempty"`
	Registered  map[string]string `json:"registered,omitempty"`
	WinnerTitle string            `json:"winner_title,omitempty"`
	Entry       json.RawMessage   `json:"entry"`
}

type songGoldenSnapshot struct {
	ShareGroups [][]string     `json:"share_groups"`
	Edges       []string       `json:"edges"`
	Vetoes      []string       `json:"vetoes,omitempty"`
	GateDrops   map[string]int `json:"gate_drops,omitempty"`
}

// songGoldenEntryKeys:案例里存的条目字段(JSON 键)。songVariantOf / songVariantIDs 读的条目字段都要在这里,
// TestSongEntityGoldenEntryKeys 按源码核对。
var songGoldenEntryKeys = []string{
	"duration_secs", "resolved_duration_secs", "instrumental", "lyrics", "lyrics_yrc", "lyrics_source", "manual_lyrics",
	"isrcs", "isrc_levels", "spotify_track_id", "spotify_album_id", "amazon_url", "amazon_album_asin", "kkbox_url",
	"kkbox_album_id", "soda_url", "soda_album_id", "youtube_music_url", "youtube_music_mv", "apple_music_url",
	"netease_url", "qq_music_url", "qq_album_mid", "player_song_ids", "player_album_ids",
}

// songGoldenEntryFieldsReplaced:建表读、但案例里换成摘好的结果存的条目字段(登记歌名、当前歌词候选的歌名;同步写进来的
// 副本存的是同步之前那份歌词,见 songOwnLyricsEntry)。
var songGoldenEntryFieldsReplaced = map[string]bool{"LyricsDecision": true, "LyricsDecisionApplied": true, "LyricsEntityOrigin": true}

// songGoldenCategories:每一类守什么,和案例体现它的判据。版本、删减版、无人声、歌词用词、歌词时间轴这几种否决
// 本机数据里没有人判得清的案例,由 songentity_test.go、songentityevidence_test.go 的单测守。
var songGoldenCategories = map[string]func(b *songEntityBuild) bool{
	// 靠 ISRC 并起来、署名写法不同(合唱、feat.)。
	"isrc-credit": func(b *songEntityBuild) bool {
		return songGoldenMergedBy(b, func(e songEdge) bool {
			return e.kind == songIDISRC && b.variants[e.a].artist != b.variants[e.b].artist
		})
	},
	// 一个实体里同时有中文 / 日文写法和拉丁字母写法。
	"cross-script": func(b *songEntityBuild) bool {
		return slices.ContainsFunc(b.clusters, func(ms []int) bool {
			return slices.ContainsFunc(ms, func(m int) bool { return b.variants[m].han }) &&
				slices.ContainsFunc(ms, func(m int) bool { return !b.variants[m].han })
		})
	},
	// 只差专辑名带来的版次词(加长版专辑、混音 EP),照并。
	"album-edition": func(b *songEntityBuild) bool {
		return slices.ContainsFunc(b.clusters, func(ms []int) bool {
			for i, x := range ms {
				for _, y := range ms[i+1:] {
					if songOnlyAlbumEditionDiffers(&b.variants[x], &b.variants[y]) {
						return true
					}
				}
			}
			return false
		})
	},
	// 靠两份独立得来、正文对得上的歌词并起来。
	"lyrics-evidence": func(b *songEntityBuild) bool {
		return songGoldenMergedBy(b, func(e songEdge) bool { return e.kind == songEvidenceLyrics })
	},
	// 检索 id 被闸挡下(主歌手、登记歌名、缺时长、一个 id 两种歌名……)。
	"searched-id-gate": func(b *songEntityBuild) bool {
		for k := range b.gateDrops {
			if ns, _, _ := strings.Cut(k, "/"); songEvidenceKinds[ns].searched {
				return true
			}
		}
		return false
	},
	"same-album-veto":    songGoldenVetoed("same_album:"),
	"duration-span-veto": songGoldenVetoed("duration"),
	"overshoot-veto":     songGoldenVetoed("overshoot"),
}

func songGoldenVetoed(reasonPrefix string) func(b *songEntityBuild) bool {
	return func(b *songEntityBuild) bool {
		return slices.ContainsFunc(b.vetoed, func(v songVeto) bool { return strings.HasPrefix(v.reason, reasonPrefix) })
	}
}

// songGoldenMergedBy:促成合并的边里有满足 ok 的。
func songGoldenMergedBy(b *songEntityBuild, ok func(songEdge) bool) bool {
	return slices.ContainsFunc(b.merged, func(i int) bool { return ok(b.edges[i]) })
}

func songGoldenLoadAll(t *testing.T) []*songGoldenFixture {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(songGoldenDir, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(paths)
	var out []*songGoldenFixture
	for _, p := range paths {
		f, err := songGoldenRead(p)
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		if f.ID != strings.TrimSuffix(filepath.Base(p), ".json") {
			t.Errorf("%s: id %q 跟文件名对不上", p, f.ID)
		}
		out = append(out, f)
	}
	return out
}

func songGoldenRead(path string) (*songGoldenFixture, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f songGoldenFixture
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, err
	}
	return &f, nil
}

func songGoldenWrite(path string, f *songGoldenFixture) error {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(f); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

// songGoldenBuild 按案例建表:换上案例记的 MusicBrainz 身份,建完还原。
func songGoldenBuild(f *songGoldenFixture) (*songEntityBuild, error) {
	return songGoldenBuildWith(f, nil, false)
}

// songGoldenBuildWith:同 songGoldenBuild,条目换成 entries 里的(写法键 → 条目;nil 时用案例存的);own 为 true 时证据看写法
// 自己得来的那份歌词(songUseOwnLyrics)。
func songGoldenBuildWith(f *songGoldenFixture, entries map[string]enrichEntry, own bool) (*songEntityBuild, error) {
	vs := make([]songVariant, 0, len(f.Variants))
	for _, fv := range f.Variants {
		e, ok := entries[fv.Key]
		if !ok {
			if err := json.Unmarshal(fv.Entry, &e); err != nil {
				return nil, fmt.Errorf("%s: %v", fv.Key, err)
			}
		}
		v := songVariantOf(fv.Key, e, fv.Pinned)
		if own {
			songUseOwnLyrics(&v, e)
		}
		v.titlesDone, v.registered, v.winnerTitle = true, fv.Registered, fv.WinnerTitle
		vs = append(vs, v)
	}
	slices.SortFunc(vs, func(a, b songVariant) int { return strings.Compare(a.key, b.key) })
	splits := map[string]bool{}
	for _, s := range f.Splits {
		splits[songPairKey(s[0], s[1])] = true
	}
	ids := map[string]mbArtistIdentity{}
	for name, mbid := range f.Identities {
		ids[name] = mbArtistIdentity{Mbid: mbid}
	}
	artistIdentityMu.Lock()
	saved := artistIdentityCache
	artistIdentityCache = ids
	artistIdentityMu.Unlock()
	defer func() {
		artistIdentityMu.Lock()
		artistIdentityCache = saved
		artistIdentityMu.Unlock()
	}()
	return buildSongEntities(vs, splits, ""), nil
}

// songGoldenGroups:按 of(写法 → 所在组)分组,组内、组间都排好序。
func songGoldenGroups(b *songEntityBuild, of []int) [][]string {
	by := map[int][]string{}
	for i := range b.variants {
		by[of[i]] = append(by[of[i]], b.variants[i].key)
	}
	groups := make([][]string, 0, len(by))
	for _, g := range by {
		groups = append(groups, g)
	}
	return songGoldenCanon(groups)
}

func songGoldenCanon(groups [][]string) [][]string {
	out := make([][]string, 0, len(groups))
	for _, g := range groups {
		g = slices.Clone(g)
		sort.Strings(g)
		out = append(out, g)
	}
	slices.SortFunc(out, func(a, b []string) int { return strings.Compare(a[0], b[0]) })
	return out
}

func songGoldenSnapshotOf(b *songEntityBuild) songGoldenSnapshot {
	key := func(i int) string { return b.variants[i].key }
	s := songGoldenSnapshot{ShareGroups: songGoldenGroups(b, b.shareOf), Edges: []string{}}
	for i, e := range b.edges {
		line := fmt.Sprintf("%s %s ↔ %s", e.kind, key(e.a), key(e.b))
		if e.value != "" {
			line += " " + e.value
		}
		if e.countOnly {
			line += " count_only"
		}
		if e.share {
			line += " share"
		}
		if b.edgeVeto[i] {
			line += " vetoed"
		}
		s.Edges = append(s.Edges, line)
	}
	sort.Strings(s.Edges)
	seen := map[string]bool{}
	for _, v := range b.vetoed {
		line := fmt.Sprintf("%s: %s ↔ %s (%s %s ↔ %s)", v.reason, key(v.x), key(v.y), v.edge.kind, key(v.edge.a), key(v.edge.b))
		if !seen[line] {
			seen[line] = true
			s.Vetoes = append(s.Vetoes, line)
		}
	}
	sort.Strings(s.Vetoes)
	if len(b.gateDrops) > 0 {
		s.GateDrops = map[string]int{}
		for k, n := range b.gateDrops {
			s.GateDrops[k] = n
		}
	}
	return s
}

func TestSongEntityGolden(t *testing.T) {
	update := os.Getenv("SONG_ENTITY_GOLDEN_UPDATE") == "1"
	for _, f := range songGoldenLoadAll(t) {
		t.Run(f.ID, func(t *testing.T) {
			b, err := songGoldenBuild(f)
			if err != nil {
				t.Fatal(err)
			}
			if got, want := songGoldenGroups(b, b.entityOf), songGoldenCanon(f.Truth); !reflect.DeepEqual(got, want) {
				t.Fatalf("[划分] 实体划分跟人判的不一样\n  得到 %v\n  应为 %v", got, want)
			}
			got := songGoldenSnapshotOf(b)
			if reflect.DeepEqual(got, f.Expect) {
				return
			}
			if update {
				f.Expect = got
				if err := songGoldenWrite(filepath.Join(songGoldenDir, f.ID+".json"), f); err != nil {
					t.Fatal(err)
				}
				t.Logf("[快照] 已重写 expect")
				return
			}
			want, _ := json.MarshalIndent(f.Expect, "", "  ")
			have, _ := json.MarshalIndent(got, "", "  ")
			t.Errorf("[快照] 共享组 / 边 / 否决 / 闸有变化(有意的改动用 SONG_ENTITY_GOLDEN_UPDATE=1 重写)\n应为 %s\n得到 %s", want, have)
		})
	}
}

func TestSongEntityGoldenCategoryCoverage(t *testing.T) {
	covered := map[string]bool{}
	for _, f := range songGoldenLoadAll(t) {
		check, ok := songGoldenCategories[f.Category]
		if !ok {
			t.Errorf("%s: 不认识的类别 %q", f.ID, f.Category)
			continue
		}
		b, err := songGoldenBuild(f)
		if err != nil {
			t.Fatal(err)
		}
		if !check(b) {
			t.Errorf("%s: 没有体现类别 %q", f.ID, f.Category)
			continue
		}
		covered[f.Category] = true
	}
	for c := range songGoldenCategories {
		if !covered[c] {
			t.Errorf("类别 %q 没有案例", c)
		}
	}
}

// 案例自洽:至少两条写法、键不重复、truth 恰好覆盖全部写法;条目只带白名单里的字段;正文是置乱过的。
func TestSongEntityGoldenFixturesWellFormed(t *testing.T) {
	allowed := map[string]bool{}
	for _, k := range songGoldenEntryKeys {
		allowed[k] = true
	}
	for _, f := range songGoldenLoadAll(t) {
		keys := map[string]bool{}
		for _, v := range f.Variants {
			if keys[v.Key] {
				t.Errorf("%s: 写法 %q 重复", f.ID, v.Key)
			}
			keys[v.Key] = true
			var raw map[string]json.RawMessage
			if err := json.Unmarshal(v.Entry, &raw); err != nil {
				t.Fatalf("%s: %v", f.ID, err)
			}
			for k := range raw {
				if !allowed[k] {
					t.Errorf("%s / %s: 条目带了白名单外的字段 %q", f.ID, v.Key, k)
				}
			}
			var e enrichEntry
			_ = json.Unmarshal(v.Entry, &e)
			for _, text := range []string{e.Lyrics, e.LyricsYRC} {
				if line, found := goldenFindUnscrambledLine(text); found {
					t.Errorf("%s / %s: 正文像是明文: %q", f.ID, v.Key, line)
				}
			}
		}
		if len(keys) < 2 {
			t.Errorf("%s: 至少要两条写法", f.ID)
		}
		seen := map[string]bool{}
		for _, g := range f.Truth {
			for _, k := range g {
				if !keys[k] || seen[k] {
					t.Errorf("%s: truth 里的 %q 不在写法里或出现了两次", f.ID, k)
				}
				seen[k] = true
			}
		}
		if len(seen) != len(keys) {
			t.Errorf("%s: truth 没覆盖全部写法", f.ID)
		}
	}
}

var songGoldenEntryFieldRe = regexp.MustCompile(`\be\.([A-Z][A-Za-z0-9]*)`)

// songVariantOf / songVariantIDs 读到的条目字段,案例里都存了(或换成摘好的结果存)。
func TestSongEntityGoldenEntryKeys(t *testing.T) {
	src, err := os.ReadFile("songentityvariant.go")
	if err != nil {
		t.Fatal(err)
	}
	allowed := map[string]bool{}
	for _, k := range songGoldenEntryKeys {
		allowed[k] = true
	}
	typ := reflect.TypeOf(enrichEntry{})
	fields := map[string]bool{}
	for _, m := range songGoldenEntryFieldRe.FindAllStringSubmatch(string(src), -1) {
		fields[m[1]] = true
	}
	if len(fields) < 10 {
		t.Fatalf("从 songentityvariant.go 只认出 %d 个条目字段,写法变了要跟着改这条测试", len(fields))
	}
	for name := range fields {
		if songGoldenEntryFieldsReplaced[name] {
			continue
		}
		sf, ok := typ.FieldByName(name)
		if !ok {
			t.Errorf("enrichEntry 没有字段 %s", name)
			continue
		}
		tag, _, _ := strings.Cut(sf.Tag.Get("json"), ",")
		if !allowed[tag] {
			t.Errorf("建表读条目的 %s(%q),songGoldenEntryKeys 里没有", name, tag)
		}
	}
}
