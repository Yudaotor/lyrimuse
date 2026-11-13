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
	backups := filepath.Join(t.TempDir(), "backups")
	savedPath, savedSync, savedPlaying, savedBackup := lyricsWritebackRecordPath, autoWritebackSync, enrichPlayingKey.Load(), lyricsWritebackBackupDir
	lyricsWritebackRecordPath = func() string { return record }
	lyricsWritebackBackupDir = func() string { return backups }
	autoWritebackSync = true
	autoWritebackLastTry = ""
	t.Cleanup(func() {
		lyricsWritebackRecordPath, autoWritebackSync, lyricsWritebackBackupDir = savedPath, savedSync, savedBackup
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

// readBackupIndex:测试用,读备份目录的索引。
func readBackupIndex(t *testing.T) lyricsWritebackBackupIndex {
	t.Helper()
	var idx lyricsWritebackBackupIndex
	data, err := os.ReadFile(filepath.Join(lyricsWritebackBackupDir(), lyricsWritebackBackupIndexName))
	if err != nil {
		return idx
	}
	if err := json.Unmarshal(data, &idx); err != nil {
		t.Fatal(err)
	}
	return idx
}

func TestAutoWritebackForeignOverwriteSwitch(t *testing.T) {
	const artist, title = "A", "foreign"
	key := enrichKey(artist, title, "")
	setUpAutoWriteback(t, map[string]enrichEntry{key: {Lyrics: bt(writebackLRC), TS: 1}})
	const theirs = "[00:01.00]别人写的歌词\n[00:02.00]第二行"
	foreign := append(id3TagPadded(4, 64, id3Frame(4, "USLT", usltBody(3, []byte(theirs)))), writebackAudio(3000)...)
	path := writeTemp(t, "f.mp3", foreign)
	real, _ := filepath.EvalSymlinks(path)
	playLocalFile(reampBundleID, artist, title, "", path)

	if got := autoWritebackLyricsOnce(); got != autoWBForeign {
		t.Fatalf("开关关:别人写的不覆盖,得到 %s", got)
	}
	if out, _ := os.ReadFile(path); !bytes.Equal(out, foreign) {
		t.Errorf("开关关:文件不动")
	}
	if n := len(readBackupIndex(t).Backups); n != 0 {
		t.Errorf("开关关:不留备份,得到 %d 份", n)
	}

	setFeatures(featureFlags{LyricsAutoWriteback: true, LyricsAutoWritebackOverwrite: true})
	if got := autoWritebackLyricsOnce(); got != autoWBOverwrote {
		t.Fatalf("这首放着时打开覆盖:同一份正文再试一次并覆盖,得到 %s", got)
	}
	if got := readLocalFileTags(path).lyrics; got != writebackLRC {
		t.Errorf("覆盖成这首的歌词:%q", got)
	}
	idx := readBackupIndex(t)
	if len(idx.Backups) != 1 {
		t.Fatalf("留一份备份,得到 %d 份", len(idx.Backups))
	}
	e := idx.Backups[0]
	if e.Path != real || e.SHA != writebackTextSHA(theirs) || filepath.Ext(e.File) != ".lrc" {
		t.Errorf("备份索引记下原文件、原歌词哈希,带时间标签存 .lrc:%+v", e)
	}
	if got, _ := os.ReadFile(filepath.Join(lyricsWritebackBackupDir(), e.File)); string(got) != theirs {
		t.Errorf("备份是原歌词一字不改:%q", got)
	}

	autoWritebackLastTry = ""
	if got := autoWritebackLyricsOnce(); got != autoWBUpToDate {
		t.Errorf("覆盖之后文件里已是这份,不重写:%s", got)
	}
	enrichMu.Lock()
	c := enrichCache[key]
	c.Lyrics = bt("[00:01.00]改过的歌词")
	enrichCache[key] = c
	enrichMu.Unlock()
	if got := autoWritebackLyricsOnce(); got != autoWBWritten {
		t.Errorf("文件里是自己写的:照样更新、不算覆盖别人,得到 %s", got)
	}
	if n := len(readBackupIndex(t).Backups); n != 1 {
		t.Errorf("更新自己写的不再备份,得到 %d 份", n)
	}

	if err := os.WriteFile(path, foreign, 0o644); err != nil {
		t.Fatal(err)
	}
	autoWritebackLastTry = ""
	if got := autoWritebackLyricsOnce(); got != autoWBOverwrote {
		t.Errorf("别的软件又写回同一份:再覆盖,得到 %s", got)
	}
	if n := len(readBackupIndex(t).Backups); n != 1 {
		t.Errorf("同一个文件同一份原歌词只备份一次,得到 %d 份", n)
	}
}

func TestAutoWritebackOverwriteNeedsBackup(t *testing.T) {
	const artist, title = "A", "nobackup"
	setUpAutoWriteback(t, map[string]enrichEntry{enrichKey(artist, title, ""): {Lyrics: bt(writebackLRC), TS: 1}})
	setFeatures(featureFlags{LyricsAutoWriteback: true, LyricsAutoWritebackOverwrite: true})
	foreign := append(id3TagPadded(4, 64, id3Frame(4, "USLT", usltBody(3, []byte("别人写的歌词")))), writebackAudio(2000)...)
	path := writeTemp(t, "n.mp3", foreign)
	playLocalFile(reampBundleID, artist, title, "", path)
	lyricsWritebackBackupDir = func() string { return "" }
	if got := autoWritebackLyricsOnce(); got != autoWBWriteFailed {
		t.Errorf("备份不成不覆盖:%s", got)
	}
	if out, _ := os.ReadFile(path); !bytes.Equal(out, foreign) {
		t.Errorf("备份不成:文件不动")
	}
}

func TestLyricsWritebackBackupCap(t *testing.T) {
	setUpAutoWriteback(t, nil)
	dir := lyricsWritebackBackupDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var idx lyricsWritebackBackupIndex
	for j := 0; j < lyricsWritebackBackupMax; j++ {
		name := fmt.Sprintf("%d.txt", j)
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		idx.Backups = append(idx.Backups, lyricsWritebackBackupEntry{File: name, Path: fmt.Sprintf("/x/%d.mp3", j), SHA: "s", At: int64(j + 1)})
	}
	idx.Backups = append(idx.Backups, lyricsWritebackBackupEntry{File: "../outside.txt", Path: "/evil.mp3", SHA: "s", At: 0})
	outside := filepath.Join(filepath.Dir(dir), "outside.txt")
	if err := os.WriteFile(outside, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(idx)
	if err := os.WriteFile(filepath.Join(dir, lyricsWritebackBackupIndexName), data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := backupForeignLyrics("/new/song.mp3", "新的原歌词"); err != nil {
		t.Fatal(err)
	}
	got := readBackupIndex(t)
	if len(got.Backups) != lyricsWritebackBackupMax {
		t.Errorf("备份封顶 %d 份,得到 %d", lyricsWritebackBackupMax, len(got.Backups))
	}
	if _, err := os.Stat(filepath.Join(dir, "0.txt")); !os.IsNotExist(err) {
		t.Errorf("删掉最早的那份备份文件")
	}
	if _, err := os.Stat(filepath.Join(dir, "1.txt")); err != nil {
		t.Errorf("第二早的留着")
	}
	if _, err := os.Stat(outside); err != nil {
		t.Errorf("索引里指到目录外的文件名不删")
	}
	last := got.Backups[len(got.Backups)-1]
	if last.Path != "/new/song.mp3" || filepath.Ext(last.File) != ".txt" {
		t.Errorf("新备份在最后,纯文本存 .txt:%+v", last)
	}
}

func TestFeaturesLyricsAutoWritebackOverwrite(t *testing.T) {
	dir := t.TempDir()
	for _, c := range []struct {
		json            string
		auto, overwrite bool
	}{
		{`{}`, false, false},
		{`{"lyrics_auto_writeback":true}`, true, false},
		{`{"lyrics_auto_writeback":true,"lyrics_auto_writeback_overwrite":true}`, true, true},
	} {
		path := filepath.Join(dir, "features.json")
		if err := os.WriteFile(path, []byte(c.json), 0o644); err != nil {
			t.Fatal(err)
		}
		f := loadFeatureFlags(path)
		if f.LyricsAutoWriteback != c.auto || f.LyricsAutoWritebackOverwrite != c.overwrite {
			t.Errorf("%s:得到 auto=%v overwrite=%v", c.json, f.LyricsAutoWriteback, f.LyricsAutoWritebackOverwrite)
		}
	}
}
