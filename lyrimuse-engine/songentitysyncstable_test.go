//go:build devtools

package main

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"
)

// 同步不改变分组:每个回归案例按共享组模拟一次整组自动同步、一次手改同步(songSimulateShareSync,记下同步之前的留底),再建一次表,
// 实体划分、共享组、证据边、否决、被闸挡下的边数都跟同步之前一样。证据要是跟着同步结果变,同步就会拆开自己所在的组、来回翻
// (18 章决策 59)。另按「证据看现在那份歌词」建一遍当对照:至少要有一个案例会变,不然这组案例测不出这一类。
func TestSongEntityGoldenSyncKeepsPartition(t *testing.T) {
	saved := songSharePreOf
	t.Cleanup(func() { songSharePreOf = saved })
	sensitive, synced := 0, 0
	for _, f := range songGoldenLoadAll(t) {
		for _, manual := range []bool{false, true} {
			entries := map[string]enrichEntry{}
			for _, fv := range f.Variants {
				var e enrichEntry
				if err := json.Unmarshal(fv.Entry, &e); err != nil {
					t.Fatalf("%s %s: %v", f.ID, fv.Key, err)
				}
				entries[fv.Key] = e
			}
			pres := songSimulatedPres{}
			songSharePreOf = pres.lookup(nil)
			before, err := songGoldenBuildWith(f, entries, true)
			if err != nil {
				t.Fatal(err)
			}
			want, wantEntities := songGoldenSnapshotOf(before), songGoldenGroups(before, before.entityOf)
			groups, _ := songSimulateShareSync(before, entries, manual, time.Unix(6_000_000, 0), pres.keep)
			synced += groups
			after, err := songGoldenBuildWith(f, entries, true)
			if err != nil {
				t.Fatal(err)
			}
			if got := songGoldenGroups(after, after.entityOf); !reflect.DeepEqual(got, wantEntities) {
				t.Errorf("%s(手改 %v):同步之后实体划分变了\n  之前 %v\n  之后 %v", f.ID, manual, wantEntities, got)
			}
			if got := songGoldenSnapshotOf(after); !reflect.DeepEqual(got, want) {
				t.Errorf("%s(手改 %v):同步之后共享组 / 证据边 / 否决变了\n  之前 %+v\n  之后 %+v", f.ID, manual, want, got)
			}
			songSharePreOf = func(string, enrichEntry) (enrichEntry, bool) { return enrichEntry{}, false }
			naive, err := songGoldenBuildWith(f, entries, true)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(songGoldenSnapshotOf(naive), want) {
				sensitive++
			}
		}
	}
	if synced == 0 {
		t.Fatal("一组都没同步上:案例里没有两条以上、有词的共享组,这条测试没跑到")
	}
	if sensitive == 0 {
		t.Error("证据看现在那份歌词时也一个案例都没变:这组案例测不出「证据跟着同步结果变」这一类,补一个靠歌词连着的案例")
	}
}
