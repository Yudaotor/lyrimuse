package main

import (
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"testing"
)

// 并条目时,落选那条按自己时长核过的号对不上胜者的时长就降成 searched;对得上、胜者时长未知时级别照旧;同一个播放器的同一个
// 曲目 id 时播放器报的号照旧,别的照样降。
func TestMergeEntryISRCsAcrossDuration(t *testing.T) {
	lx := map[string]string{lxMusicBundleID: "mg_1135716854"}
	for _, c := range []struct {
		name     string
		dst, src enrichEntry
		want     map[string]string
	}{
		{"时长对不上",
			enrichEntry{DurationSecs: 241, ISRCs: []string{"USRH12000012"}, ISRCLevels: map[string]string{"USRH12000012": isrcLevelVerified}},
			enrichEntry{DurationSecs: 401.707324, ISRCs: []string{"USWB12000810"}, ISRCLevels: map[string]string{"USWB12000810": isrcLevelVerified}},
			map[string]string{"USRH12000012": isrcLevelVerified, "USWB12000810": isrcLevelSearched}},
		{"时长对得上",
			enrichEntry{DurationSecs: 241},
			enrichEntry{DurationSecs: 241.132, ISRCs: []string{"USRH12000012"}, ISRCLevels: map[string]string{"USRH12000012": isrcLevelVerified}},
			map[string]string{"USRH12000012": isrcLevelVerified}},
		{"胜者时长未知",
			enrichEntry{},
			enrichEntry{DurationSecs: 241, ISRCs: []string{"USRH12000012"}, ISRCLevels: map[string]string{"USRH12000012": isrcLevelVerified}},
			map[string]string{"USRH12000012": isrcLevelVerified}},
		{"同一个曲目 id:播放器报的照旧",
			enrichEntry{DurationSecs: 241, PlayerSongIDs: lx},
			enrichEntry{DurationSecs: 401.707324, PlayerSongIDs: lx, ISRCs: []string{"USWB12000810", "USRH12000012"},
				ISRCLevels: map[string]string{"USWB12000810": isrcLevelPlayer, "USRH12000012": isrcLevelVerified}},
			map[string]string{"USWB12000810": isrcLevelPlayer, "USRH12000012": isrcLevelSearched}},
		{"不同录音:播放器报的也降,没记级别的记成 searched",
			enrichEntry{DurationSecs: 241},
			enrichEntry{DurationSecs: 401.707324, PlayerSongIDs: lx, ISRCs: []string{"USWB12000810", "USRH12000012"},
				ISRCLevels: map[string]string{"USWB12000810": isrcLevelPlayer}},
			map[string]string{"USWB12000810": isrcLevelSearched, "USRH12000012": isrcLevelSearched}},
	} {
		dst := c.dst
		mergeEntryISRCs(&dst, c.src)
		if !maps.Equal(dst.ISRCLevels, c.want) {
			t.Errorf("%s: levels %v, want %v", c.name, dst.ISRCLevels, c.want)
		}
	}
}

// Prince《Can't Stop This Feeling I Got》:「~dur2」(160 秒,洛雪放过)并回没放过的基条目(264 秒,带着 LP 版那一轨核过的号)、
// 变体留下时,基条目的号带过来只算检索配的,ListenBrainz 不再拿它报录音。
func TestMergePeripheralIntoDemotesOffDurationISRC(t *testing.T) {
	winner := enrichEntry{DurationSecs: 160.368367, Players: []string{lxMusicBundleID},
		PlayerSongIDs: map[string]string{lxMusicBundleID: "mg_1125475243"}}
	loser := enrichEntry{DurationSecs: 264, ISRCs: []string{"USWB10103250"},
		ISRCLevels: map[string]string{"USWB10103250": isrcLevelVerified}}
	got := mergePeripheralInto(winner, loser)
	if got.ISRCLevels["USWB10103250"] != isrcLevelSearched {
		t.Errorf("levels %v, want USWB10103250 searched", got.ISRCLevels)
	}
	if code := got.confidentISRC(); code != "" {
		t.Errorf("confidentISRC = %q, want empty", code)
	}
}

// 原地改时长:按旧时长核过的号降成 searched,播放器报的不降,原来那份 isrc_levels 不改;时长对得上时不动。
func TestDemoteISRCsAcrossDuration(t *testing.T) {
	levels := map[string]string{"USRH12000012": isrcLevelVerified, "USWB12000810": isrcLevelPlayer, "USWB10003360": isrcLevelSearched}
	e := enrichEntry{DurationSecs: 241, ISRCs: []string{"USRH12000012", "USWB12000810", "USWB10003360", "USQX92001153"}, ISRCLevels: levels}
	if demoteISRCsAcrossDuration(&e, 241, 241.9) {
		t.Fatal("时长对得上不该降")
	}
	if !demoteISRCsAcrossDuration(&e, 241, 401.707324) {
		t.Fatal("时长对不上该降")
	}
	want := map[string]string{"USRH12000012": isrcLevelSearched, "USWB12000810": isrcLevelPlayer,
		"USWB10003360": isrcLevelSearched, "USQX92001153": isrcLevelSearched}
	if !maps.Equal(e.ISRCLevels, want) {
		t.Errorf("levels %v, want %v", e.ISRCLevels, want)
	}
	if levels["USRH12000012"] != isrcLevelVerified || len(levels) != 3 {
		t.Errorf("原来那份被改了: %v", levels)
	}
	if demoteISRCsAcrossDuration(&e, 241, 401.707324) {
		t.Error("再降一遍不该有改动")
	}
}

// Prince《Strange Relationship(2020 Remaster)》:没放过的基条目(241 秒,原版那一轨核过的 USRH12000012)分高留下、并进洛雪放的
// 「~dur2」(401.7 秒,USWB12000810),之后同一个曲目 id 把时长原地改成 401.7 秒。两个号都证明不了是这一条,不报;按新时长重搜
// 核过 USWB12000810 后报它。
func TestStrangeRelationshipConfidentISRC(t *testing.T) {
	base := enrichEntry{DurationSecs: 241, ISRCs: []string{"USRH12000012"}, ISRCLevels: map[string]string{"USRH12000012": isrcLevelVerified}}
	variant := enrichEntry{DurationSecs: 401.707324, Players: []string{lxMusicBundleID},
		PlayerSongIDs: map[string]string{lxMusicBundleID: "mg_1135716854"},
		ISRCs:         []string{"USWB12000810"}, ISRCLevels: map[string]string{"USWB12000810": isrcLevelVerified}}
	e := mergePeripheralInto(base, variant)
	demoteISRCsAcrossDuration(&e, e.DurationSecs, 401.707324)
	e.DurationSecs = 401.707324
	if code := e.confidentISRC(); code != "" {
		t.Fatalf("confidentISRC = %q, want empty (levels %v)", code, e.ISRCLevels)
	}
	recordISRCs(&e, []recordedISRC{{"USWB12000810", isrcLevelVerified}})
	if code := e.confidentISRC(); code != "USWB12000810" {
		t.Errorf("confidentISRC = %q, want USWB12000810 (levels %v)", code, e.ISRCLevels)
	}
}

// 电台真曲长补进来时,按原来那个时长核过的号同样降级。
func TestRadioDurationHintDemotesISRCs(t *testing.T) {
	saved := radioDurationHints
	t.Cleanup(func() { radioDurationHints = saved })
	radioDurationHints = map[string]float64{"a|b|c": 226.283}
	e := enrichEntry{DurationSecs: 3390.122, ISRCs: []string{"USUG12505893"}, ISRCLevels: map[string]string{"USUG12505893": isrcLevelVerified}}
	if !applyRadioDurationHintLocked("a|b|c", &e) {
		t.Fatal("没写进时长")
	}
	if e.DurationSecs != 226.283 || e.ISRCLevels["USUG12505893"] != isrcLevelSearched {
		t.Errorf("got %.3f %v", e.DurationSecs, e.ISRCLevels)
	}
}

// 存量:时长跟选词时长差过两倍容差的,播放器报的以外都降;合并备份里记着这个号的几条时长都对不上现在这一条的,降;
// 差得少、没有证据、对得上的不动。再跑一遍没有改动。
func TestMigrateISRCDurationRecheck(t *testing.T) {
	savedPath := enrichPath
	t.Cleanup(func() { enrichPath = savedPath })
	enrichPath = ""
	const strange = "Prince|Strange Relationship(2020 Remaster)|Sign O' The Times (Super Deluxe) [Explicit]"
	const blue = "Prince|Computer Blue|Purple Rain"
	const rules = "Dua Lipa|New Rules|Dua Lipa (Deluxe)"
	const other = "Prince|Strange Relationship|Sign 'O' The Times"
	withEnrichCache(t, map[string]enrichEntry{
		strange: {DurationSecs: 401.707324, ResolvedDurationSecs: 401.707324, ISRCs: []string{"USRH12000012", "USWB12000810"},
			ISRCLevels: map[string]string{"USRH12000012": isrcLevelVerified, "USWB12000810": isrcLevelVerified}},
		blue: {DurationSecs: 271, ResolvedDurationSecs: 239.5178, ISRCs: []string{"USWB10001875", "USWB11700193", "USWB10001876"},
			ISRCLevels: map[string]string{"USWB10001875": isrcLevelVerified, "USWB10001876": isrcLevelPlayer}},
		rules: {DurationSecs: 209.32, ResolvedDurationSecs: 212, ISRCs: []string{"GBAHT1600310"},
			ISRCLevels: map[string]string{"GBAHT1600310": isrcLevelVerified}},
		other: {DurationSecs: 241, ResolvedDurationSecs: 241, ISRCs: []string{"USRH12000012"},
			ISRCLevels: map[string]string{"USRH12000012": isrcLevelVerified}},
	})
	backups := []map[string]isrcBackupEntry{{
		strange: {ISRCs: []string{"USRH12000012"}, DurationSecs: 241},
		"Prince|Strange Relationship(2020 Remaster)~dur2|Sign O' The Times (Super Deluxe) [Explicit]": {
			ISRCs: []string{"USWB12000810"}, DurationSecs: 401.707324},
	}}
	want := map[string]map[string]string{
		strange: {"USRH12000012": isrcLevelSearched, "USWB12000810": isrcLevelVerified},
		blue:    {"USWB10001875": isrcLevelSearched, "USWB11700193": isrcLevelSearched, "USWB10001876": isrcLevelPlayer},
		rules:   {"GBAHT1600310": isrcLevelVerified},
		other:   {"USRH12000012": isrcLevelVerified},
	}
	for round := 1; round <= 2; round++ {
		migrateISRCDurationRecheck(func() []map[string]isrcBackupEntry { return backups })
		enrichMu.Lock()
		for k, w := range want {
			if got := enrichCache[k].ISRCLevels; !maps.Equal(got, w) {
				t.Errorf("round %d %s: levels %v, want %v", round, k, got, w)
			}
		}
		dirty := enrichDirty
		enrichDirty = false
		enrichMu.Unlock()
		if round == 2 && dirty {
			t.Error("再跑一遍不该有改动")
		}
	}
}

// 合并备份只读主缓存旁边 `.keynorm-<时间>.bak` 这一种名字,解不开的跳过。
func TestReadEnrichKeyMergeBackups(t *testing.T) {
	savedPath := enrichPath
	t.Cleanup(func() { enrichPath = savedPath })
	dir := t.TempDir()
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	good, _ := json.Marshal(map[string]enrichEntry{"a|b|c": {DurationSecs: 241, ISRCs: []string{"USRH12000012"}}})
	for name, data := range map[string][]byte{
		clientName + "-enrich-cache.json.keynorm-20261018-202628.bak": good,
		clientName + "-enrich-cache.json.keynorm-20261018-202140.bak": []byte("{"),
		clientName + "-enrich-cache.json.pre-keynorm.bak":             good,
		"other.json.keynorm-20261018-202628.bak":                      good,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	got := readEnrichKeyMergeBackups()
	if len(got) != 1 || got[0]["a|b|c"].DurationSecs != 241 || len(got[0]["a|b|c"].ISRCs) != 1 {
		t.Errorf("got %+v", got)
	}
}
