package main

import (
	"path/filepath"
	"testing"
	"time"
)

// 酷狗听书:sqlite 那份队列里这一集的条目类是 KGSoundReadInfo,判成有声内容;歌(CollectSongEntity 等)和听书页的电台轻音乐
// (KGHotRadioAduioInfo)不是。
func writeKugouSpokenQueue(t *testing.T) {
	t.Helper()
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "郭德纲、于谦 - 大上寿-郭德纲、于谦（带返场）-01", album: "郭德纲&于谦|逗笑相声合集", singers: []string{"郭德纲", "于谦"},
			seconds: 242, extra: map[string]any{"mixId": "780459243", "payAlbumID": "156736159", "classname": "KGSoundReadInfo", "audioType": 2}},
		{musicName: "Cody Simpson - Summertime of Our Lives", album: "Summertime", singers: []string{"Cody Simpson"},
			seconds: 200, extra: map[string]any{"mixId": "1", "payAlbumID": "2", "classname": "CollectSongEntity", "audioType": 1}},
		{musicName: "丽声文化传媒 - [轻音乐] 安心夜", album: "安心夜", singers: []string{"丽声文化传媒"},
			seconds: 183, extra: map[string]any{"mixId": "3", "classname": "KGHotRadioAduioInfo", "audioType": 1001}},
	})
	old := kugouNowPlayingOverride
	kugouNowPlayingOverride = filepath.Join(t.TempDir(), "no-userCurrentPlayList.plist")
	t.Cleanup(func() { kugouNowPlayingOverride = old })
}

func TestKugouPlayingSongInfoMarksSoundRead(t *testing.T) {
	writeKugouSpokenQueue(t)
	if mix, album, spoken := kugouPlayingSongInfo("郭德纲、于谦", "大上寿-郭德纲、于谦（带返场）-01", 242); !spoken || mix != "780459243" || album != "156736159" {
		t.Errorf("听书这一集: mix=%q album=%q spoken=%v", mix, album, spoken)
	}
	if _, _, spoken := kugouPlayingSongInfo("郭德纲、于谦", "大上寿-郭德纲、于谦（带返场）-01", 0); !spoken {
		t.Error("开播那拍时长还是 0 也认")
	}
	if mix, _, spoken := kugouPlayingSongInfo("Cody Simpson", "Summertime of Our Lives", 200); spoken || mix != "1" {
		t.Errorf("歌不是有声内容: mix=%q spoken=%v", mix, spoken)
	}
	if _, _, spoken := kugouPlayingSongInfo("丽声文化传媒", "[轻音乐] 安心夜", 183); spoken {
		t.Error("听书页的电台轻音乐不是有声内容")
	}
	if _, _, spoken := kugouPlayingSongInfo("郭德纲、于谦", "大上寿-郭德纲、于谦（带返场）-02", 235); spoken {
		t.Error("队列里没有这一集不下结论")
	}
}

// 判成有声内容的记进条目,只置不清;别的播放器的 id 照旧。合并两条写法时带过去。
func TestApplyPlayerCatalogIDsMarksSpoken(t *testing.T) {
	var e enrichEntry
	if !applyPlayerCatalogIDsLocked(&e, kugouMusicBundleID, playerCatalogIDs{songID: "780459243", songAlbum: "156736159", spoken: true}) ||
		!e.PlayerSpoken || e.PlayerSongIDs[kugouMusicBundleID] != "780459243" {
		t.Fatalf("记下有声: %+v", e)
	}
	if applyPlayerCatalogIDsLocked(&e, kugouMusicBundleID, playerCatalogIDs{songID: "780459243", songAlbum: "156736159"}) || !e.PlayerSpoken {
		t.Errorf("没读到不清掉: changed / spoken=%v", e.PlayerSpoken)
	}
	song := enrichEntry{PlayerSongIDs: map[string]string{kugouMusicBundleID: "1"}}
	if !applyPlayerCatalogIDsLocked(&song, kugouMusicBundleID, playerCatalogIDs{songID: "1", spoken: true}) || !song.PlayerSpoken {
		t.Error("id 没变、只多了有声这一样也算改了")
	}
	if !mergePeripheralInto(enrichEntry{}, enrichEntry{PlayerSpoken: true}).PlayerSpoken {
		t.Error("合并写法带上有声标记")
	}
}

// 开播那一拍就按酷狗的队列判出有声内容:不宣布正在播放、不提交收听;同一首放成歌的照常宣布。
func TestHandleKugouSoundReadIsNotASong(t *testing.T) {
	resetPlayerCatalogMemo(t)
	writeKugouSpokenQueue(t)
	at := handleClock()
	tick := func(artist, title string, dur, pos float64, ts time.Time) snapshot {
		return snapshot{Title: title, Artist: artist, Album: "专辑", Bundle: kugouMusicBundleID, Duration: dur,
			Playing: true, Rate: 1, Position: pos, AnchorTS: ts}
	}
	ep := tick("郭德纲、于谦", "大上寿-郭德纲、于谦（带返场）-01", 242, 0, at(0))
	p := handleTestPoller(t, ep)
	handleTick(p, at(0), ep)
	if !p.sess.isSpoken || p.sess.announcing {
		t.Fatalf("开播就判成有声: spoken=%v announcing=%v", p.sess.isSpoken, p.sess.announcing)
	}
	for s := 10; s <= 200; s += 10 {
		handleTick(p, at(s), tick("郭德纲、于谦", "大上寿-郭德纲、于谦（带返场）-01", 242, float64(s), at(s)))
	}
	if !p.sess.isSpoken || p.sess.announcing || !p.sess.listenSent || len(p.submitsInflight) != 0 {
		t.Fatalf("有声内容不当歌: spoken=%v announcing=%v sent=%v inflight=%d",
			p.sess.isSpoken, p.sess.announcing, p.sess.listenSent, len(p.submitsInflight))
	}

	song := tick("Cody Simpson", "Summertime of Our Lives", 200, 0, at(0))
	q := handleTestPoller(t, song)
	handleTick(q, at(0), song)
	if q.sess.isSpoken {
		t.Fatal("歌照常当歌")
	}
}

// 「此刻在播」plist 那份队列只装歌:从它认出来的不是有声内容,也不去读 sqlite 那份。
func TestKugouPlayingSongInfoFromPlistIsASong(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{{"甲、乙 - 第一首", "甲", "AAAA01", 200}}, 0)
	old := kugouNowPlayingOverride
	kugouNowPlayingOverride = kugouQueuePlistOverride
	t.Cleanup(func() { kugouNowPlayingOverride = old })
	writeTestKugouLibrary(t, []testKugouLibRow{{"甲、乙 - 第一首", "甲", "aaaa01", 200, "586000001", 70001, 3}})
	if mix, _, spoken := kugouPlayingSongInfo("甲", "第一首", 200); mix != "586000001" || spoken {
		t.Errorf("plist 里的歌: mix=%q spoken=%v", mix, spoken)
	}
}

// 只看酷狗:别的播放器不为这一判去读本机数据。
func TestPlayerMarksSpokenOnlyKugou(t *testing.T) {
	resetPlayerCatalogMemo(t)
	if playerMarksSpoken(snapshot{Title: "通史-000引言", Artist: "茂桐笙花", Bundle: qqMusicBundleID, Duration: 261}) {
		t.Error("QQ 不走这一判")
	}
	playerCatalogMu.Lock()
	n := len(playerCatalogMemo)
	playerCatalogMu.Unlock()
	if n != 0 {
		t.Errorf("别的播放器不读本机数据: 记忆里有 %d 条", n)
	}
}
