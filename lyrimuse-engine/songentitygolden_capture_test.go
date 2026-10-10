//go:build devtools

// songentitygolden_capture_test.go — 歌曲实体案例的采集器。默认跳过;只在显式给出案例清单时读一次本机缓存,
// 把挑中的写法置乱后写成 testdata/songentity/<id>.json。
//
//	SONG_ENTITY_GOLDEN_CAPTURE=<清单.json> GOTOOLCHAIN=go1.24.4 go test -run 'TestSongEntityGoldenCapture$' -v .
//
// 清单是一个数组,每项 {"id", "category", "note", "truth": [[写法键…], …]}:truth 是人判的同一份录音分组,要列全
// 它涉及的实体的每一条写法(全库建表时那几个实体整个搬进来)。写入前的硬闸,任何一道不过就不写:
//  1. truth 里的写法恰好是全库建表时那几个实体的全部写法;
//  2. 只拿这几条建表,实体划分、共享组跟全库建表时一样,实体划分跟 truth 一样;
//  3. 置乱前后建表的结果(划分与快照)逐项相同;
//  4. 写出的文件读回来按 TestSongEntityGolden 同一条路跑一遍,结果不变,且体现它声称的类别。
//
// ~/.config/lyrimuse 下的文件只读:加载进内存后把回写路径清空,跑完把包级状态还原。
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

type songGoldenCaptureSpec struct {
	ID       string     `json:"id"`
	Category string     `json:"category"`
	Note     string     `json:"note"`
	Truth    [][]string `json:"truth"`
}

func TestSongEntityGoldenCapture(t *testing.T) {
	specPath := os.Getenv("SONG_ENTITY_GOLDEN_CAPTURE")
	if specPath == "" {
		t.Skip("SONG_ENTITY_GOLDEN_CAPTURE 没给,跳过")
	}
	data, err := os.ReadFile(specPath)
	if err != nil {
		t.Fatal(err)
	}
	var specs []songGoldenCaptureSpec
	if err := json.Unmarshal(data, &specs); err != nil {
		t.Fatal(err)
	}
	cfgDir := configDir()
	if cfgDir == "" {
		t.Fatal("找不到配置目录")
	}

	savedFeatures, savedPins := features(), lyricsPinsPath
	enrichMu.Lock()
	savedCache := enrichCache
	enrichMu.Unlock()
	artistIdentityMu.Lock()
	savedIDs, savedIDPath := artistIdentityCache, artistIdentityPath
	artistIdentityMu.Unlock()
	t.Cleanup(func() {
		setFeatures(savedFeatures)
		lyricsPinsPath = savedPins
		enrichMu.Lock()
		enrichCache = savedCache
		enrichMu.Unlock()
		artistIdentityMu.Lock()
		artistIdentityCache, artistIdentityPath = savedIDs, savedIDPath
		artistIdentityMu.Unlock()
	})
	setFeatures(loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json")))
	lyricsPinsPath = filepath.Join(cfgDir, clientName+"-lyrics-pins.json")
	loadArtistIdentityCache(filepath.Join(cfgDir, clientName+"-artist-identity-cache.json"))
	artistIdentityMu.Lock()
	artistIdentityPath = ""
	artistIdentityMu.Unlock()
	loadEnrichForMaintenance(cfgDir, false)
	enrichMu.Lock()
	snapshot := make(map[string]enrichEntry, len(enrichCache))
	for k, v := range enrichCache {
		snapshot[k] = v
	}
	enrichMu.Unlock()
	if len(snapshot) == 0 {
		t.Fatal("enrich 缓存是空的或读不了")
	}
	decisionsDir := filepath.Join(cfgDir, clientName+"-decisions")
	splits := readSongEntityUserSplits(filepath.Join(cfgDir, clientName+"-song-entity-user.json"))
	full := buildSongEntities(songVariantsFromCache(snapshot, lyricsPinnedKeys()), splits, decisionsDir)
	idx := map[string]int{}
	for i := range full.variants {
		idx[full.variants[i].key] = i
	}

	for _, spec := range specs {
		t.Run(spec.ID, func(t *testing.T) {
			if _, ok := songGoldenCategories[spec.Category]; !ok {
				t.Fatalf("不认识的类别 %q", spec.Category)
			}
			// 闸 1:truth 恰好是那几个实体的全部写法。
			var keys []string
			for _, g := range spec.Truth {
				keys = append(keys, g...)
			}
			ents := map[int]bool{}
			for _, k := range keys {
				i, ok := idx[k]
				if !ok {
					t.Fatalf("缓存里没有写法 %q", k)
				}
				ents[full.entityOf[i]] = true
			}
			var members []int
			for ci := range ents {
				members = append(members, full.clusters[ci]...)
			}
			var memberKeys []string
			for _, m := range members {
				memberKeys = append(memberKeys, full.variants[m].key)
			}
			slices.Sort(memberKeys)
			sortedKeys := slices.Clone(keys)
			slices.Sort(sortedKeys)
			if !slices.Equal(memberKeys, sortedKeys) {
				t.Fatalf("truth 要列全涉及的实体的写法\n  实体里有 %q\n  truth 有 %q", memberKeys, sortedKeys)
			}

			plain := &songGoldenFixture{
				ID: spec.ID, Category: spec.Category, Note: spec.Note, CapturedAt: time.Now().Format("2006-01-02"),
				Truth: spec.Truth,
			}
			for _, k := range memberKeys {
				v := full.variants[idx[k]]
				v.loadDecisionTitles(decisionsDir)
				entry, err := songGoldenEntryJSON(snapshot[k])
				if err != nil {
					t.Fatal(err)
				}
				plain.Variants = append(plain.Variants, songGoldenVariant{
					Key: k, Pinned: v.pinned, Registered: v.registered, WinnerTitle: v.winnerTitle, Entry: entry,
				})
				for _, name := range []string{v.artist, v.primary} {
					if id, ok := cachedArtistIdentity(name); ok && id.Mbid != "" {
						if plain.Identities == nil {
							plain.Identities = map[string]string{}
						}
						plain.Identities[name] = id.Mbid
					}
				}
			}
			for _, k := range memberKeys {
				for _, l := range memberKeys {
					if k < l && splits[songPairKey(k, l)] {
						plain.Splits = append(plain.Splits, [2]string{k, l})
					}
				}
			}

			// 闸 2:子集建表跟全库建表一样,跟 truth 一样。
			pb, err := songGoldenBuild(plain)
			if err != nil {
				t.Fatal(err)
			}
			fullOf := func(of []int) [][]string {
				by := map[int][]string{}
				for _, m := range members {
					by[of[m]] = append(by[of[m]], full.variants[m].key)
				}
				var gs [][]string
				for _, g := range by {
					gs = append(gs, g)
				}
				return songGoldenCanon(gs)
			}
			if got, want := songGoldenGroups(pb, pb.entityOf), fullOf(full.entityOf); !reflect.DeepEqual(got, want) {
				t.Fatalf("只拿这几条建表跟全库不一样\n  子集 %v\n  全库 %v", got, want)
			}
			if got, want := songGoldenGroups(pb, pb.shareOf), fullOf(full.shareOf); !reflect.DeepEqual(got, want) {
				t.Fatalf("共享组跟全库不一样\n  子集 %v\n  全库 %v", got, want)
			}
			if got, want := songGoldenGroups(pb, pb.entityOf), songGoldenCanon(spec.Truth); !reflect.DeepEqual(got, want) {
				t.Fatalf("实体划分跟 truth 不一样,不采\n  得到 %v\n  truth %v", got, want)
			}
			plainSnap := songGoldenSnapshotOf(pb)

			// 闸 3:置乱前后一样。
			fx, err := songGoldenScramble(plain)
			if err != nil {
				t.Fatal(err)
			}
			sb, err := songGoldenBuild(fx)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(songGoldenGroups(sb, sb.entityOf), songGoldenGroups(pb, pb.entityOf)) ||
				!reflect.DeepEqual(songGoldenSnapshotOf(sb), plainSnap) {
				t.Fatalf("置乱前后建表结果不同\n  置乱前 %+v\n  置乱后 %+v", plainSnap, songGoldenSnapshotOf(sb))
			}
			fx.Expect = plainSnap

			// 闸 4:写出、读回、重跑。
			path := filepath.Join(songGoldenDir, spec.ID+".json")
			if err := os.MkdirAll(songGoldenDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := songGoldenWrite(path, fx); err != nil {
				t.Fatal(err)
			}
			back, err := songGoldenRead(path)
			if err == nil {
				var rb *songEntityBuild
				if rb, err = songGoldenBuild(back); err == nil {
					switch {
					case !reflect.DeepEqual(songGoldenSnapshotOf(rb), plainSnap):
						err = errString("读回来重跑,快照变了")
					case !songGoldenCategories[spec.Category](rb):
						err = errString("没有体现类别 " + spec.Category)
					}
				}
			}
			if err != nil {
				_ = os.Remove(path)
				t.Fatalf("%s 没写成: %v", path, err)
			}
			t.Logf("写出 %s:%d 条写法,%d 个实体", path, len(fx.Variants), len(spec.Truth))
		})
	}
}

type errString string

func (e errString) Error() string { return string(e) }

// songGoldenEntryJSON:条目里 songGoldenEntryKeys 那几个字段(空的不写)。
func songGoldenEntryJSON(e enrichEntry) (json.RawMessage, error) {
	data, err := json.Marshal(e)
	if err != nil {
		return nil, err
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(data, &all); err != nil {
		return nil, err
	}
	kept := map[string]json.RawMessage{}
	for _, k := range songGoldenEntryKeys {
		if v, ok := all[k]; ok {
			kept[k] = v
		}
	}
	return json.Marshal(kept)
}

// songGoldenScramble:案例里全部写法的正文、逐字共用一套双射置乱(lyricsgolden 的置乱器),种子是案例 id。
func songGoldenScramble(f *songGoldenFixture) (*songGoldenFixture, error) {
	entries := make([]map[string]json.RawMessage, len(f.Variants))
	var texts []goldenText
	for i, v := range f.Variants {
		if err := json.Unmarshal(v.Entry, &entries[i]); err != nil {
			return nil, err
		}
		var e enrichEntry
		if err := json.Unmarshal(v.Entry, &e); err != nil {
			return nil, err
		}
		texts = append(texts, goldenText{e.Lyrics, false}, goldenText{e.LyricsYRC, true})
	}
	s := newGoldenScrambler(f.ID, texts)
	out := *f
	out.Variants = slices.Clone(f.Variants)
	for i := range out.Variants {
		for _, field := range []struct {
			key string
			yrc bool
		}{{"lyrics", false}, {"lyrics_yrc", true}} {
			raw, ok := entries[i][field.key]
			if !ok {
				continue
			}
			var text string
			if err := json.Unmarshal(raw, &text); err != nil {
				return nil, err
			}
			enc, err := json.Marshal(s.scrambleText(text, field.yrc))
			if err != nil {
				return nil, err
			}
			entries[i][field.key] = enc
		}
		data, err := json.Marshal(entries[i])
		if err != nil {
			return nil, err
		}
		out.Variants[i].Entry = data
	}
	if strings.TrimSpace(out.Note) == "" {
		return nil, errString("note 不能空")
	}
	return &out, nil
}
