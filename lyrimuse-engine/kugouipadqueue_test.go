package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func kugouIPadRandomStateB64(history []int, index, count int) string {
	b, _ := json.Marshal(map[string]any{"queueHash": "h", "historySongIndexes": history, "historyIndex": index,
		"songCount": count, "pendingSongIndexes": []int{}})
	return base64.StdEncoding.EncodeToString(b)
}

// 随机抽取记录指的当前这首:historySongIndexes[historyIndex];歌数跟队列对不上、下标越界、解不开都不给。
func TestKugouIPadShuffleCurrent(t *testing.T) {
	cases := []struct {
		raw   string
		songs int
		want  int
	}{
		{kugouIPadRandomStateB64([]int{2, 20, 15, 29}, 3, 30), 30, 29},
		{kugouIPadRandomStateB64([]int{2, 20, 15, 29}, 1, 30) + "\n", 30, 20},
		{kugouIPadRandomStateB64([]int{2, 20, 15, 29}, 3, 30), 31, -1},
		{kugouIPadRandomStateB64([]int{2, 20}, 2, 30), 30, -1},
		{kugouIPadRandomStateB64([]int{2, 40}, 1, 30), 30, -1},
		{"not base64!", 30, -1},
		{base64.StdEncoding.EncodeToString([]byte("[]")), 30, -1},
	}
	for i, c := range cases {
		if got := kugouIPadShuffleCurrent([]byte(c.raw), c.songs); got != c.want {
			t.Errorf("#%d: got %d, want %d", i, got, c.want)
		}
	}
}

func writeTestKugouIPadCurrentList(t *testing.T, path, b64 string) {
	t.Helper()
	body := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>currentPlayListRandomState</key><data>` + b64 + `</data>
<key>kPlayListSaveFromPage</key><string>每日推荐</string>
</dict></plist>`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// 名单:队列次序、歌名取 showName、署名取 singerInfo(没有时 musicName 前缀)、专辑、整秒时长,外加随机抽取记录指的那首;
// 两份文件都没变时不重写,队列库没了就删掉名单。
func TestKugouIPadQueuePublisher(t *testing.T) {
	writeTestKugouIPadQueue(t, []testKugouSong{
		{musicName: "孙燕姿 - 开始懂了", album: "我要的幸福", seconds: 271, singers: []string{"孙燕姿", "林俊杰"}},
		{musicName: "叶子舒 - AYOU", showName: "AYOU (重新出发吗)", album: "AYOU(重新出发吗)", seconds: 204},
		{musicName: "宋冬野 - 安和桥", album: "安和桥北", seconds: 251},
	})
	dir := t.TempDir()
	list := filepath.Join(dir, "userCurrentPlayList.plist")
	writeTestKugouIPadCurrentList(t, list, kugouIPadRandomStateB64([]int{0, 1}, 1, 3))
	p := &kugouIPadQueuePublisher{statePath: filepath.Join(dir, "state.json"), dbPath: kugouIPadQueueOverride, listPath: list}
	if !p.refresh() {
		t.Fatal("读得到队列时要写名单")
	}
	read := func() kugouIPadQueueState {
		t.Helper()
		b, err := os.ReadFile(p.statePath)
		if err != nil {
			t.Fatalf("名单没写出来: %v", err)
		}
		var st kugouIPadQueueState
		if err := json.Unmarshal(b, &st); err != nil {
			t.Fatalf("名单解不开: %v", err)
		}
		return st
	}
	st := read()
	want := []kugouIPadQueueEntry{
		{Title: "开始懂了", Artist: "孙燕姿、林俊杰", Album: "我要的幸福", Seconds: 271},
		{Title: "AYOU (重新出发吗)", Artist: "叶子舒", Album: "AYOU(重新出发吗)", Seconds: 204},
		{Title: "安和桥", Artist: "宋冬野", Album: "安和桥北", Seconds: 251},
	}
	if len(st.Songs) != len(want) {
		t.Fatalf("songs = %+v", st.Songs)
	}
	for i := range want {
		if st.Songs[i] != want[i] {
			t.Errorf("songs[%d] = %+v, want %+v", i, st.Songs[i], want[i])
		}
	}
	if st.ShuffleCurrent != 1 || st.ShuffleAt <= 0 || st.UpdatedAt <= 0 {
		t.Errorf("随机抽取记录: %+v", st)
	}

	if err := os.Remove(p.statePath); err != nil {
		t.Fatal(err)
	}
	if !p.refresh() {
		t.Error("没变时照旧算有名单")
	}
	if _, err := os.Stat(p.statePath); err == nil {
		t.Error("两份文件都没变时不该重读重写")
	}

	writeTestKugouIPadCurrentList(t, list, kugouIPadRandomStateB64([]int{0, 1, 2}, 2, 3)+"  ")
	p.refresh()
	if st := read(); st.ShuffleCurrent != 2 {
		t.Errorf("换歌后抽取记录改写:当前那首跟着换, got %d", st.ShuffleCurrent)
	}

	if err := os.WriteFile(kugouIPadQueueOverride, []byte("not a database"), 0o644); err != nil {
		t.Fatal(err)
	}
	if p.refresh() {
		t.Error("队列库读不了不该再有名单")
	}
	if _, err := os.Stat(p.statePath); err == nil {
		t.Error("队列库读不了要删掉名单")
	}

	writeTestKugouIPadQueue(t, []testKugouSong{{musicName: "宋冬野 - 安和桥", album: "安和桥北", seconds: 251}})
	p.dbPath = kugouIPadQueueOverride
	if !p.refresh() {
		t.Fatal("队列库又读得到了")
	}
	if err := os.Remove(kugouIPadQueueOverride); err != nil {
		t.Fatal(err)
	}
	if p.refresh() {
		t.Error("队列库没了不该再有名单")
	}
	if _, err := os.Stat(p.statePath); err == nil {
		t.Error("队列库没了要删掉名单")
	}
}

// 没有随机抽取记录(那份 plist 不在)时只给队列,当前那首记 -1。
func TestKugouIPadQueuePublisherWithoutShuffle(t *testing.T) {
	writeTestKugouIPadQueue(t, []testKugouSong{{musicName: "宋冬野 - 安和桥", album: "安和桥北", seconds: 251}})
	dir := t.TempDir()
	p := &kugouIPadQueuePublisher{statePath: filepath.Join(dir, "state.json"), dbPath: kugouIPadQueueOverride,
		listPath: filepath.Join(dir, "missing.plist")}
	if !p.refresh() {
		t.Fatal("读得到队列时要写名单")
	}
	b, _ := os.ReadFile(p.statePath)
	var st kugouIPadQueueState
	if err := json.Unmarshal(b, &st); err != nil || len(st.Songs) != 1 || st.ShuffleCurrent != -1 {
		t.Errorf("名单 %s (%v)", b, err)
	}
}

// 名单文件名跟 App 那份同一个名字。
func TestKugouIPadQueueFileSharedWithApp(t *testing.T) {
	core, err := os.ReadFile(filepath.Join("..", "lyrimuse", "Sources", "LyrimuseCore", "Local", "KugouIPadTitleRepair.swift"))
	if err != nil {
		t.Skip("没有 App 源码")
	}
	if !containsCode(string(core), `LyrimusePaths.configFile("`+clientName+`-kugou-ipad-queue.json")`) {
		t.Error("App 读的名单文件名跟引擎写的不一样")
	}
}

// Mac 版那个目录里没有、iPad 版的有这张专辑的动态封面:认 iPad 版那份。
func TestKugouMotionCoverFromIPadDir(t *testing.T) {
	mac, ipad := t.TempDir(), t.TempDir()
	oldMac, oldIPad := kugouDynamicArtworkOverride, kugouIPadDynamicArtworkOverride
	kugouDynamicArtworkOverride, kugouIPadDynamicArtworkOverride = mac, ipad
	t.Cleanup(func() { kugouDynamicArtworkOverride, kugouIPadDynamicArtworkOverride = oldMac, oldIPad })
	if err := os.WriteFile(filepath.Join(ipad, "969063.mp4"), []byte("kugou-mp4"), 0o600); err != nil {
		t.Fatal(err)
	}
	e := enrichEntry{CoverURL: "c", PlayerAlbumIDs: map[string]string{kugouMusicBundleID: "969063"}}
	if id, file := kugouMotionCoverAlbum(e); id != "969063" || file != filepath.Join(ipad, "969063.mp4") {
		t.Errorf("iPad 版那份: id=%q file=%q", id, file)
	}
	if err := os.WriteFile(filepath.Join(mac, "969063.mp4"), []byte("mac-mp4"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, file := kugouMotionCoverAlbum(e); file != filepath.Join(mac, "969063.mp4") {
		t.Errorf("两份都有时先认 Mac 版的: %q", file)
	}
	kugouDynamicArtworkOverride, kugouIPadDynamicArtworkOverride = filepath.Join(mac, "missing"), filepath.Join(ipad, "missing")
	if id, _ := kugouMotionCoverAlbum(e); id != "" {
		t.Errorf("两个目录都读不了当没有: %q", id)
	}
}
