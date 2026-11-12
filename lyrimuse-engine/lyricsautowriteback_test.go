package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// setUpAutoWriteback:编辑通道的临时环境 + 写入记录放临时目录 + 开关打开 + 同步执行;当前曲目、正在播的 key 测完还原。
func setUpAutoWriteback(t *testing.T, entries map[string]enrichEntry) {
	t.Helper()
	setUpEnrichEditTest(t, entries)
	setFeatures(featureFlags{LyricsAutoWriteback: true})
	record := filepath.Join(t.TempDir(), "writeback.json")
	savedPath, savedSync, savedPlaying := lyricsWritebackRecordPath, autoWritebackSync, enrichPlayingKey.Load()
	lyricsWritebackRecordPath = func() string { return record }
	autoWritebackSync = true
	autoWritebackLastTry = ""
	t.Cleanup(func() {
		lyricsWritebackRecordPath, autoWritebackSync = savedPath, savedSync
		enrichPlayingKey.Store(savedPlaying)
		autoWritebackLastTry = ""
		noteLocalFileCurrentTrack("", "", "", "")
	})
}

func playLocalFile(bundle, artist, title, album, path string) {
	key := enrichKey(artist, title, album)
	enrichPlayingKey.Store(&key)
	noteLocalFileCurrentTrack(bundle, artist, title, path)
}

func TestLrcToPlainText(t *testing.T) {
	in := "[ar:周杰伦]\n[offset:0]\n[00:01.00]第一行\n[00:02.00][00:30.00]重复的一行\n[00:03.00]\n[00:04.00]<00:04.00>逐<00:04.50>字\n没有时间的行"
	want := "第一行\n重复的一行\n逐字\n没有时间的行"
	if got := lrcToPlainText(in); got != want {
		t.Errorf("得到 %q,想要 %q", got, want)
	}
	if got := lrcToPlainText("纯文本\n第二行"); got != "纯文本\n第二行" {
		t.Errorf("不是 LRC 的原样:%q", got)
	}
	if !writebackWantsPlainText(appleMusicBundleID) || writebackWantsPlainText(reampBundleID) {
		t.Errorf("只有 Apple Music 的曲目写纯文本")
	}
}

func TestLyricsWritebackEditChannelAppleMusicWritesPlainText(t *testing.T) {
	const key = "a|music|"
	setUpEnrichEditTest(t, map[string]enrichEntry{key: {Lyrics: bt(writebackLRC)}})
	path := writeTemp(t, "m.mp3", writebackAudio(3000))
	res := applyEnrichEdit(enrichEditRequest{Op: "write_file_lyrics", Key: key, FilePath: path, Player: appleMusicBundleID})
	if !res.OK {
		t.Fatalf("%+v", res)
	}
	got := readLocalFileTags(path).lyrics
	if got != lrcToPlainText(writebackLRC) || localFileLRCTimestamp.MatchString(got) {
		t.Errorf("Apple Music 的曲目只写文字:%q", got)
	}
}

func TestAutoWritebackLyrics(t *testing.T) {
	const artist, title = "周杰伦", "稻香"
	key := enrichKey(artist, title, "魔杰座")
	setUpAutoWriteback(t, map[string]enrichEntry{key: {Lyrics: bt(writebackLRC), TS: 1}})
	path := writeTemp(t, "song.mp3", writebackAudio(3000))
	playLocalFile(reampBundleID, artist, title, "魔杰座", path)

	setFeatures(featureFlags{})
	maybeAutoWritebackLyrics()
	if readLocalFileTags(path).hasLyrics {
		t.Fatalf("开关关着不写")
	}
	setFeatures(featureFlags{LyricsAutoWriteback: true})

	if got := autoWritebackLyricsOnce(); got != autoWBWritten {
		t.Fatalf("第一次:%s", got)
	}
	if readLocalFileTags(path).lyrics != writebackLRC {
		t.Errorf("写进去的是这首的歌词")
	}
	if got := autoWritebackLyricsOnce(); got != autoWBSeen {
		t.Errorf("同一份不再试:%s", got)
	}
	autoWritebackLastTry = ""
	if got := autoWritebackLyricsOnce(); got != autoWBUpToDate {
		t.Errorf("文件里已经是这份:%s", got)
	}

	enrichMu.Lock()
	e := enrichCache[key]
	e.Lyrics = bt("[00:01.00]改过的歌词")
	enrichCache[key] = e
	enrichMu.Unlock()
	if got := autoWritebackLyricsOnce(); got != autoWBWritten {
		t.Fatalf("歌词换了、文件里是自己上次写的:%s", got)
	}
	if readLocalFileTags(path).lyrics != "[00:01.00]改过的歌词" {
		t.Errorf("覆盖成新的")
	}

	foreign := append(id3TagPadded(4, 64, id3Frame(4, "USLT", usltBody(3, []byte("别人写的歌词")))), writebackAudio(3000)...)
	if err := os.WriteFile(path, foreign, 0o644); err != nil {
		t.Fatal(err)
	}
	autoWritebackLastTry = ""
	if got := autoWritebackLyricsOnce(); got != autoWBForeign {
		t.Errorf("别人写的不覆盖:%s", got)
	}
	if out, _ := os.ReadFile(path); !bytes.Equal(out, foreign) {
		t.Errorf("文件不动")
	}
}

func TestAutoWritebackLyricsSkips(t *testing.T) {
	const artist = "A"
	setUpAutoWriteback(t, map[string]enrichEntry{
		enrichKey(artist, "inst", ""):    {Lyrics: bt(writebackLRC), TS: 1, Instrumental: true},
		enrichKey(artist, "pending", ""): {Lyrics: bt(writebackLRC)},
		enrichKey(artist, "busy", ""):    {Lyrics: bt(writebackLRC), TS: 1},
		enrichKey(artist, "empty", ""):   {TS: 1},
		enrichKey(artist, "ok", ""):      {Lyrics: bt(writebackLRC), TS: 1},
	})
	enrichMu.Lock()
	savedInflight := enrichInflight
	enrichInflight = map[string]bool{enrichKey(artist, "busy", ""): true}
	enrichMu.Unlock()
	t.Cleanup(func() { enrichMu.Lock(); enrichInflight = savedInflight; enrichMu.Unlock() })

	for _, title := range []string{"inst", "pending", "busy", "empty"} {
		path := writeTemp(t, title+".mp3", writebackAudio(2000))
		playLocalFile(reampBundleID, artist, title, "", path)
		autoWritebackLastTry = ""
		if got := autoWritebackLyricsOnce(); got != autoWBSkipped || readLocalFileTags(path).hasLyrics {
			t.Errorf("%s:想要 skipped,得到 %s", title, got)
		}
	}
	path := writeTemp(t, "ok.m4a", []byte("....ftyp"))
	playLocalFile(reampBundleID, artist, "ok", "", path)
	if got := autoWritebackLyricsOnce(); got != autoWBSkipped {
		t.Errorf("不支持的格式:%s", got)
	}
	mp3 := writeTemp(t, "other.mp3", writebackAudio(2000))
	playLocalFile(reampBundleID, artist, "ok", "", mp3)
	other := enrichKey(artist, "another song", "")
	enrichPlayingKey.Store(&other)
	if got := autoWritebackLyricsOnce(); got != autoWBSkipped {
		t.Errorf("正在播的 key 跟当前文件对不上(换歌那一拍):%s", got)
	}
}

func TestAutoWritebackAppleMusicPlainAndRecordCap(t *testing.T) {
	const artist, title = "A", "music"
	setUpAutoWriteback(t, map[string]enrichEntry{enrichKey(artist, title, ""): {Lyrics: bt(writebackLRC), TS: 1}})
	path := writeTemp(t, "m.flac", bytes.Join([][]byte{[]byte("fLaC"), flacBlockBytes(0, true, make([]byte, 34)), writebackAudio(2000)}, nil))
	playLocalFile(appleMusicBundleID, artist, title, "", path)
	if got := autoWritebackLyricsOnce(); got != autoWBWritten {
		t.Fatalf("%s", got)
	}
	if got := readLocalFileTags(path).lyrics; got != lrcToPlainText(writebackLRC) {
		t.Errorf("Apple Music 的曲目只写文字:%q", got)
	}
	real, _ := filepath.EvalSymlinks(path)
	if lyricsWrittenBackSHA(real) != writebackTextSHA(lrcToPlainText(writebackLRC)) {
		t.Errorf("写入记录按实际文件记下正文哈希")
	}

	rec := lyricsWritebackRecord{Files: map[string]lyricsWritebackRecordEntry{}}
	for j := 0; j < lyricsWritebackRecordMax; j++ {
		rec.Files[fmt.Sprintf("/x/%d.mp3", j)] = lyricsWritebackRecordEntry{SHA: "s", At: int64(j + 1)}
	}
	data, _ := json.Marshal(rec)
	if err := os.WriteFile(lyricsWritebackRecordPath(), data, 0o644); err != nil {
		t.Fatal(err)
	}
	noteLyricsWrittenBack("/new", "t")
	lyricsWritebackRecordMu.Lock()
	n := len(loadLyricsWritebackRecordLocked().Files)
	lyricsWritebackRecordMu.Unlock()
	if n != lyricsWritebackRecordMax {
		t.Errorf("写入记录封顶 %d 条,得到 %d", lyricsWritebackRecordMax, n)
	}
	if lyricsWrittenBackSHA("/new") == "" || lyricsWrittenBackSHA("/x/0.mp3") != "" {
		t.Errorf("新写的留着、丢的是最早的")
	}
}
