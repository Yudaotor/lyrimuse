package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeMBArtists:按搜索词给出首条艺人和它的别名。people 的键是搜索词,值是 MusicBrainz 上那位艺人的主名和别名;
// down 里的搜索词答 503。
func fakeMBArtists(people map[string][2]string, down map[string]bool) func(string) ([]byte, error) {
	return func(u string) ([]byte, error) {
		if i := strings.Index(u, "?query="); i >= 0 {
			q, _ := url.QueryUnescape(strings.SplitN(u[i+len("?query="):], "&", 2)[0])
			if down[q] {
				return nil, errors.New("musicbrainz: status 503")
			}
			p, ok := people[q]
			if !ok {
				return []byte(`{"artists":[]}`), nil
			}
			return []byte(`{"artists":[{"id":"mbid-` + strings.ReplaceAll(q, " ", "_") + `","name":"` + p[0] + `","score":100}]}`), nil
		}
		for q, p := range people {
			if strings.Contains(u, "mbid-"+strings.ReplaceAll(q, " ", "_")) {
				aliases := `[{"name":"` + p[0] + `","locale":"zh","type":"Artist name"}`
				if p[1] != "" {
					aliases += `,{"name":"` + p[1] + `","locale":"en","type":"Artist name"}`
				}
				return []byte(`{"name":"` + p[0] + `","country":"CN","aliases":` + aliases + `]}`), nil
			}
		}
		return nil, errors.New("unexpected " + u)
	}
}

// 搜索首条分数够高、却不是本地这位(别名里没有本地写法):不收它的中文名。是这位的照收。
func TestChineseAliasRequiresSameArtist(t *testing.T) {
	withFakeMBFetch(t, fakeMBArtists(map[string][2]string{
		"Lexie Liu": {"刘昱妤", ""},         // 首条是另一位歌手
		"Jay Chou":  {"周杰伦", "Jay Chou"}, // 别名里登记了本地写法
	}, nil))
	ctx := context.Background()
	if v, err := lookupMusicBrainzChineseAlias(ctx, "Lexie Liu"); err != nil || v != "" {
		t.Errorf("首条不是本地这位,不该收它的中文名: %q %v", v, err)
	}
	if v, err := lookupMusicBrainzChineseAlias(ctx, "Jay Chou"); err != nil || v != "周杰伦" {
		t.Errorf("别名里有本地写法:照收,got %q %v", v, err)
	}
}

// withArtistAliasCache:换一份内存别名缓存、落盘到临时文件(先把 m 写进去当盘上那份)。
func withArtistAliasCache(t *testing.T, m map[string]string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "alias.json")
	b, _ := json.Marshal(m)
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	artistAliasMu.Lock()
	savedCache, savedPath, savedRemoved := artistAliasCache, artistAliasPath, artistAliasRemoved
	artistAliasCache, artistAliasPath, artistAliasRemoved = map[string]string{}, path, map[string]bool{}
	for k, v := range m {
		artistAliasCache[k] = v
	}
	artistAliasMu.Unlock()
	t.Cleanup(func() {
		artistAliasMu.Lock()
		artistAliasCache, artistAliasPath, artistAliasRemoved = savedCache, savedPath, savedRemoved
		artistAliasMu.Unlock()
	})
	return path
}

// 存量重核(手工表里的写法不重核,这里用表外的名字):认错人的作废(盘上也删掉,不被 mergeMissingFromDisk 并回来),同一位歌手条目上的 canonical_artist 一并清掉;
// 对的不动,别的歌手的条目不碰;有一条没问成就不算完成。
func TestRecheckArtistAliasesDropsWrongPerson(t *testing.T) {
	withFakeMBFetch(t, fakeMBArtists(map[string][2]string{
		"Wrong Match": {"某某", ""},
		"Jay Chou":    {"周杰伦", "Jay Chou"},
	}, map[string]bool{"Crowd Lu": true}))
	path := withArtistAliasCache(t, map[string]string{"Wrong Match": "某某", "Jay Chou": "周杰伦", "Crowd Lu": "卢广仲"})
	withEnrichCache(t, map[string]enrichEntry{
		enrichKey("Wrong Match", "Song", "Album"): {CanonicalArtist: "某某"},
		enrichKey("Someone", "Other", "Album"):    {CanonicalArtist: "某某"},
		enrichKey("Jay Chou", "晴天", "叶惠美"):        {CanonicalArtist: "周杰伦"},
	})

	changed, complete := recheckArtistAliases(context.Background(), migrationScope{all: true})
	if changed != 1 || complete {
		t.Errorf("改 1 条、Crowd Lu 没问成不算完成,got changed=%d complete=%v", changed, complete)
	}
	artistAliasMu.Lock()
	wrong, jay, crowd := artistAliasCache["Wrong Match"], artistAliasCache["Jay Chou"], artistAliasCache["Crowd Lu"]
	artistAliasMu.Unlock()
	if wrong != "" || jay != "周杰伦" || crowd != "卢广仲" {
		t.Errorf("内存缓存: Wrong Match=%q Jay Chou=%q Crowd Lu=%q", wrong, jay, crowd)
	}
	var disk map[string]string
	b, _ := os.ReadFile(path)
	if err := json.Unmarshal(b, &disk); err != nil {
		t.Fatal(err)
	}
	if _, ok := disk["Wrong Match"]; ok || disk["Jay Chou"] != "周杰伦" || disk["Crowd Lu"] != "卢广仲" {
		t.Errorf("盘上那份: %v", disk)
	}
	if e := enrichCache[enrichKey("Wrong Match", "Song", "Album")]; e.CanonicalArtist != "" {
		t.Errorf("同一位歌手的条目 canonical_artist 要清掉: %q", e.CanonicalArtist)
	}
	if e := enrichCache[enrichKey("Someone", "Other", "Album")]; e.CanonicalArtist != "某某" {
		t.Errorf("别的歌手的条目不碰: %q", e.CanonicalArtist)
	}
	if e := enrichCache[enrichKey("Jay Chou", "晴天", "叶惠美")]; e.CanonicalArtist != "周杰伦" {
		t.Errorf("对的不动: %q", e.CanonicalArtist)
	}
}

// 作废的超过一半、又至少 recheckMaxRemovedFloor 条:更像 MusicBrainz 应答变了形状,整批不改、不算完成。
func TestRecheckArtistAliasesKeepsAllOnMassDrop(t *testing.T) {
	withFakeMBFetch(t, fakeMBArtists(nil, nil)) // 谁都搜不到
	old := map[string]string{"A1": "甲", "A2": "乙", "A3": "丙", "A4": "丁", "A5": "戊", "A6": "己"}
	withArtistAliasCache(t, old)
	withEnrichCache(t, nil)
	changed, complete := recheckArtistAliases(context.Background(), migrationScope{all: true})
	if changed != 0 || complete {
		t.Errorf("整批不改、不算完成,got changed=%d complete=%v", changed, complete)
	}
	artistAliasMu.Lock()
	defer artistAliasMu.Unlock()
	for k, v := range old {
		if artistAliasCache[k] != v {
			t.Errorf("%s 不该动: %q", k, artistAliasCache[k])
		}
	}
}

// 排序名原样、倒成「名 姓」都认;排序名对不上的照旧不认。
func TestMBNameBelongsToArtistBySortName(t *testing.T) {
	zh := []mbAlias{{Name: "蕭煌奇", Locale: "zh", Type: "Artist name"}}
	for raw, want := range map[string]bool{"Ricky Hsiao": true, "Hsiao, Ricky": true, "蕭煌奇": true, "Lexie Liu": false, "Ricky": false} {
		if got := mbNameBelongsToArtist("蕭煌奇", "Hsiao, Ricky", zh, raw); got != want {
			t.Errorf("%q: got %v want %v", raw, got, want)
		}
	}
}

// 只补扫 lyrics/ 文件夹改过的几条时,只重查那几首歌的歌手,别的不问。
func TestRecheckArtistAliasesHonorsRecheckScope(t *testing.T) {
	calls := withFakeMBFetch(t, fakeMBArtists(map[string][2]string{"Wrong Match": {"某某", ""}}, nil))
	withArtistAliasCache(t, map[string]string{"Wrong Match": "某某", "Jay Chou": "周杰伦"})
	key := enrichKey("Wrong Match", "Song", "Album")
	withEnrichCache(t, map[string]enrichEntry{key: {CanonicalArtist: "某某"}, enrichKey("Jay Chou", "晴天", "叶惠美"): {}})
	changed, complete := recheckArtistAliases(context.Background(), migrationScope{keys: []string{key}})
	if changed != 1 || !complete {
		t.Errorf("补扫的那位改掉,got changed=%d complete=%v", changed, complete)
	}
	for _, u := range *calls {
		if strings.Contains(u, "Jay") {
			t.Errorf("补扫范围外的歌手不该问: %s", u)
		}
	}
}
