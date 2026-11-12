package main

import (
	"bytes"
	"encoding/binary"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

const (
	writebackPlain = "写回测试 第一行 Writeback test line one\r\n第二行：中文、English、日本語\n\n最后一行"
	writebackLRC   = "[00:00.50]写回测试 第一行\n[00:02.00]第二行：中文、English、日本語\n[00:05.00]第三行 带标点「引号」"
)

// writebackAudio:一段伪随机的「音频」字节,末尾带一个 ID3v1(128 字节 TAG),写回前后要逐字节相同。
func writebackAudio(n int) []byte {
	r := rand.New(rand.NewSource(int64(n)))
	b := make([]byte, n)
	r.Read(b)
	b[0], b[1] = 0xFF, 0xFB
	v1 := make([]byte, 128)
	copy(v1, "TAG"+"ID3v1 title")
	return append(b, v1...)
}

// id3TagPadded:id3Tag 再补 padding 个 0。
func id3TagPadded(version byte, padding int, frames ...[]byte) []byte {
	var body []byte
	for _, f := range frames {
		body = append(body, f...)
	}
	body = append(body, make([]byte, padding)...)
	n := len(body)
	header := []byte{'I', 'D', '3', version, 0, 0, byte(n >> 21 & 0x7F), byte(n >> 14 & 0x7F), byte(n >> 7 & 0x7F), byte(n & 0x7F)}
	return append(header, body...)
}

func txxxBody(desc, text string) []byte {
	return append(append(append([]byte{3}, desc...), 0), text...)
}

func fileIno(t *testing.T, path string) uint64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Sys().(*syscall.Stat_t).Ino
}

// parseID3ForTest 独立于写入器拆帧(只认 v2.3 / v2.4、不反同步),交回版本、标签区总长和帧。
func parseID3ForTest(t *testing.T, data []byte) (byte, int, [][]byte) {
	t.Helper()
	if !bytes.HasPrefix(data, []byte("ID3")) {
		t.Fatalf("没有 ID3 头")
	}
	version := data[3]
	size := syncsafeInt(data[6:10])
	tag := data[10 : 10+size]
	var frames [][]byte
	for pos := 0; pos+10 <= len(tag) && tag[pos] != 0; {
		var n int
		if version == 4 {
			n = syncsafeInt(tag[pos+4 : pos+8])
		} else {
			n = int(binary.BigEndian.Uint32(tag[pos+4 : pos+8]))
		}
		frames = append(frames, tag[pos:pos+10+n])
		pos += 10 + n
	}
	return version, 10 + size, frames
}

func noLeftoverClones(t *testing.T, dir string) {
	t.Helper()
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), ".lyrimuse-") {
			t.Errorf("克隆没清掉:%s", e.Name())
		}
	}
}

func TestLyricsWritebackMP3(t *testing.T) {
	audio := writebackAudio(40000)
	for _, version := range []byte{3, 4, 0} {
		for _, text := range []string{writebackPlain, writebackLRC} {
			var keptFrames [][]byte
			var data []byte
			if version != 0 {
				keptFrames = [][]byte{
					id3Frame(version, "TIT2", append([]byte{3}, "稻香"...)),
					id3Frame(version, "TPE1", append([]byte{3}, "周杰伦"...)),
					id3Frame(version, "APIC", append([]byte{0}, bytes.Repeat([]byte{0xAB}, 3000)...)),
					id3Frame(version, "COMM", usltBody(3, []byte("注释保留"))),
					id3Frame(version, "TXXX", txxxBody("REPLAYGAIN_TRACK_GAIN", "-6.5 dB")),
				}
				all := [][]byte{keptFrames[0], id3Frame(version, "USLT", usltBody(3, []byte("旧歌词"))), keptFrames[1], keptFrames[2],
					id3Frame(version, "TXXX", txxxBody("LYRICS", "[00:01.00]旧的自定义帧")), keptFrames[3], keptFrames[4]}
				data = append(id3TagPadded(version, 64, all...), audio...)
			} else {
				data = append([]byte(nil), audio...)
			}
			path := writeTemp(t, "song.mp3", data)
			oldIno := fileIno(t, path)
			held, err := os.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			got, err := writeLyricsToFile(path, text, true)
			if err != nil {
				held.Close()
				t.Fatalf("v2.%d 写入失败:%v", version, err)
			}
			if got != path {
				resolved, _ := filepath.EvalSymlinks(path)
				if got != resolved {
					t.Errorf("交回的路径 %q", got)
				}
			}
			oldView := make([]byte, len(data))
			if _, err := held.ReadAt(oldView, 0); err != nil || !bytes.Equal(oldView, data) {
				t.Errorf("v2.%d:写入前打开的文件句柄应仍读到原内容(克隆 + 改名,不就地写)", version)
			}
			held.Close()
			if fileIno(t, path) == oldIno {
				t.Errorf("v2.%d:inode 没变,说明是就地写", version)
			}
			out, _ := os.ReadFile(path)
			want := normalizeWritebackLyrics(text)
			if tags := readLocalFileTags(path); !tags.hasLyrics || tags.lyrics != want {
				t.Errorf("v2.%d 回读:得到 %q,想要 %q", version, tags.lyrics, want)
			}
			wantVersion := version
			if version == 0 {
				wantVersion = 4
			}
			v, headLen, frames := parseID3ForTest(t, out)
			if v != wantVersion {
				t.Errorf("版本:得到 v2.%d,想要 v2.%d", v, wantVersion)
			}
			if !bytes.Equal(out[headLen:], audio) {
				t.Errorf("v2.%d:标签区之后的音频字节变了", version)
			}
			var others [][]byte
			var uslt [][]byte
			for _, f := range frames {
				switch string(f[:4]) {
				case "USLT":
					uslt = append(uslt, f)
				case "SYLT":
					t.Errorf("不应写 SYLT")
				default:
					if string(f[:4]) == "TXXX" && bytes.Contains(f, []byte("LYRICS\x00")) {
						t.Errorf("旧的 TXXX:LYRICS 应去掉")
						continue
					}
					others = append(others, f)
				}
			}
			if len(others) != len(keptFrames) {
				t.Fatalf("v2.%d:留下 %d 个别的帧,原有 %d 个", version, len(others), len(keptFrames))
			}
			for i := range others {
				if !bytes.Equal(others[i], keptFrames[i]) {
					t.Errorf("v2.%d:第 %d 个帧 %s 变了", version, i, keptFrames[i][:4])
				}
			}
			if len(uslt) != 1 {
				t.Fatalf("v2.%d:USLT 有 %d 个", version, len(uslt))
			}
			wantEnc := byte(3)
			if wantVersion == 3 {
				wantEnc = 1
			}
			if uslt[0][10] != wantEnc {
				t.Errorf("v2.%d:USLT 编码 %d,想要 %d", version, uslt[0][10], wantEnc)
			}
			lang := string(uslt[0][11:14])
			if version != 0 && lang != "chi" || version == 0 && lang != "eng" {
				t.Errorf("v2.%d:USLT 语言 %q", version, lang)
			}
			noLeftoverClones(t, filepath.Dir(path))
		}
	}
}

func TestLyricsWritebackMP3PaddingReuseAndGrowth(t *testing.T) {
	audio := writebackAudio(20000)
	title := id3Frame(4, "TIT2", append([]byte{3}, "x"...))
	data := append(id3TagPadded(4, 4096, title), audio...)
	path := writeTemp(t, "pad.mp3", data)
	if _, err := writeLyricsToFile(path, writebackLRC, false); err != nil {
		t.Fatal(err)
	}
	out, _ := os.ReadFile(path)
	if len(out) != len(data) {
		t.Errorf("padding 放得下时文件长度不变:%d → %d", len(data), len(out))
	}
	long := strings.Repeat("[00:01.00]很长的一行歌词 long line of lyrics\n", 400)
	if _, err := writeLyricsToFile(path, long, true); err != nil {
		t.Fatal(err)
	}
	out, _ = os.ReadFile(path)
	_, headLen, _ := parseID3ForTest(t, out)
	if headLen <= len(data)-len(audio) || !bytes.Equal(out[headLen:], audio) {
		t.Errorf("放不下时标签变长、音频原样接在后面:headLen=%d", headLen)
	}
	if tags := readLocalFileTags(path); tags.lyrics != normalizeWritebackLyrics(long) {
		t.Errorf("变长后回读不对")
	}
}

func TestLyricsWritebackV23Unsynchronised(t *testing.T) {
	audio := writebackAudio(5000)
	title := id3Frame(3, "TIT2", append([]byte{0}, "ab"...))
	tag := id3TagPadded(3, 32, title)
	tag[5] = 0x80
	path := writeTemp(t, "unsync.mp3", append(tag, audio...))
	if _, err := writeLyricsToFile(path, writebackPlain, true); err != nil {
		t.Fatal(err)
	}
	out, _ := os.ReadFile(path)
	if out[5] != 0 {
		t.Errorf("写回后不再标反同步:flags=%x", out[5])
	}
	if tags := readLocalFileTags(path); tags.lyrics != normalizeWritebackLyrics(writebackPlain) {
		t.Errorf("回读不对:%q", tags.lyrics)
	}
}

func flacBlockBytes(kind byte, last bool, body []byte) []byte {
	if last {
		kind |= 0x80
	}
	return append([]byte{kind, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}, body...)
}

// parseFLACForTest 独立于写入器拆元数据块,交回块(类型 + 正文)和音频起点。
func parseFLACForTest(t *testing.T, data []byte) ([]flacBlock, int) {
	t.Helper()
	if !bytes.HasPrefix(data, []byte("fLaC")) {
		t.Fatalf("没有 fLaC")
	}
	pos := 4
	var blocks []flacBlock
	for {
		h := data[pos]
		size := int(data[pos+1])<<16 | int(data[pos+2])<<8 | int(data[pos+3])
		blocks = append(blocks, flacBlock{kind: h & 0x7F, body: data[pos+4 : pos+4+size]})
		pos += 4 + size
		if h&0x80 != 0 {
			return blocks, pos
		}
	}
}

func TestLyricsWritebackFLAC(t *testing.T) {
	audio := writebackAudio(30000)
	streamInfo := bytes.Repeat([]byte{0x11}, 34)
	seek := bytes.Repeat([]byte{0x22}, 36)
	picture := bytes.Repeat([]byte{0x33}, 2000)
	comment := vorbisComment("TITLE=稻香", "UNSYNCEDLYRICS=旧的", "ARTIST=周杰伦", "lyrics=[00:01.00]旧", "REPLAYGAIN_TRACK_GAIN=-6.5 dB")
	cases := map[string][]byte{
		"有注释块和 padding": bytes.Join([][]byte{[]byte("fLaC"), flacBlockBytes(0, false, streamInfo), flacBlockBytes(3, false, seek),
			flacBlockBytes(4, false, comment), flacBlockBytes(6, false, picture), flacBlockBytes(1, true, make([]byte, 8192))}, nil),
		"没有注释块也没有 padding": bytes.Join([][]byte{[]byte("fLaC"), flacBlockBytes(0, false, streamInfo), flacBlockBytes(3, false, seek),
			flacBlockBytes(6, true, picture)}, nil),
	}
	for name, head := range cases {
		for _, text := range []string{writebackPlain, writebackLRC} {
			data := append(append([]byte(nil), head...), audio...)
			path := writeTemp(t, "song.flac", data)
			oldIno := fileIno(t, path)
			if _, err := writeLyricsToFile(path, text, true); err != nil {
				t.Fatalf("%s:写入失败:%v", name, err)
			}
			if fileIno(t, path) == oldIno {
				t.Errorf("%s:inode 没变,说明是就地写", name)
			}
			out, _ := os.ReadFile(path)
			want := normalizeWritebackLyrics(text)
			if tags := readLocalFileTags(path); !tags.hasLyrics || tags.lyrics != want {
				t.Errorf("%s 回读:得到 %q,想要 %q", name, tags.lyrics, want)
			}
			blocks, audioStart := parseFLACForTest(t, out)
			if !bytes.Equal(out[audioStart:], audio) {
				t.Errorf("%s:音频帧变了", name)
			}
			origBlocks, _ := parseFLACForTest(t, head)
			var wantOthers, gotOthers []flacBlock
			for _, b := range origBlocks {
				if b.kind != 4 && b.kind != 1 {
					wantOthers = append(wantOthers, b)
				}
			}
			var comments [][]byte
			for _, b := range blocks {
				switch b.kind {
				case 4:
					comments = append(comments, b.body)
				case 1:
				default:
					gotOthers = append(gotOthers, b)
				}
			}
			if blocks[0].kind != 0 || (len(comments) == 1 && blocks[1].kind != 4 && name != "有注释块和 padding") {
				t.Errorf("%s:STREAMINFO 在最前、新建的注释块紧跟其后", name)
			}
			if len(gotOthers) != len(wantOthers) {
				t.Fatalf("%s:别的块 %d 个,原有 %d 个", name, len(gotOthers), len(wantOthers))
			}
			for i := range gotOthers {
				if gotOthers[i].kind != wantOthers[i].kind || !bytes.Equal(gotOthers[i].body, wantOthers[i].body) {
					t.Errorf("%s:第 %d 个块(类型 %d)变了", name, i, wantOthers[i].kind)
				}
			}
			if len(comments) != 1 {
				t.Fatalf("%s:注释块 %d 个", name, len(comments))
			}
			vendor, entries, ok := parseVorbisComment(comments[0])
			if !ok {
				t.Fatalf("%s:注释块拆不开", name)
			}
			var lyricsEntries, rest []string
			for _, e := range entries {
				k, _, _ := strings.Cut(string(e), "=")
				if isLyricsTagKey(k) {
					lyricsEntries = append(lyricsEntries, string(e))
				} else {
					rest = append(rest, string(e))
				}
			}
			if len(lyricsEntries) != 1 || lyricsEntries[0] != "LYRICS="+want {
				t.Errorf("%s:歌词条目 %q", name, lyricsEntries)
			}
			if name == "有注释块和 padding" {
				if string(vendor) != "vendor" || strings.Join(rest, "|") != "TITLE=稻香|ARTIST=周杰伦|REPLAYGAIN_TRACK_GAIN=-6.5 dB" {
					t.Errorf("厂商串和别的条目应原样:%q %q", vendor, rest)
				}
				if len(out) != len(data) {
					t.Errorf("padding 放得下时文件长度不变:%d → %d", len(data), len(out))
				}
			} else if string(vendor) != flacWritebackVendor || len(rest) != 0 {
				t.Errorf("新建的注释块:%q %q", vendor, rest)
			}
			noLeftoverClones(t, filepath.Dir(path))
		}
	}
}

func sampleMP3WithLyrics(t *testing.T) (string, []byte) {
	t.Helper()
	data := append(id3TagPadded(4, 128, id3Frame(4, "TIT2", append([]byte{3}, "x"...)),
		id3Frame(4, "USLT", usltBody(3, []byte("原有歌词")))), writebackAudio(8000)...)
	return writeTemp(t, "has.mp3", data), data
}

func wantWritebackCode(t *testing.T, err error, code string) {
	t.Helper()
	if err == nil || lyricsWritebackCode(err) != code {
		t.Errorf("想要错误码 %s,得到 %v", code, err)
	}
}

func TestLyricsWritebackRefusals(t *testing.T) {
	path, data := sampleMP3WithLyrics(t)
	_, err := writeLyricsToFile(path, writebackLRC, false)
	wantWritebackCode(t, err, wbErrHasLyrics)
	if out, _ := os.ReadFile(path); !bytes.Equal(out, data) {
		t.Errorf("没允许覆盖时文件不动")
	}

	v22 := append([]byte{'I', 'D', '3', 2, 0, 0, 0, 0, 0, 10}, make([]byte, 10)...)
	_, err = writeLyricsToFile(writeTemp(t, "v22.mp3", append(v22, writebackAudio(100)...)), writebackLRC, true)
	wantWritebackCode(t, err, wbErrUnsupportedTag)

	_, err = writeLyricsToFile(writeTemp(t, "a.m4a", []byte("....ftyp")), writebackLRC, true)
	wantWritebackCode(t, err, wbErrUnsupportedFormat)

	_, err = writeLyricsToFile(filepath.Join(t.TempDir(), "missing.mp3"), writebackLRC, true)
	wantWritebackCode(t, err, wbErrNotFound)

	_, err = writeLyricsToFile(writeTemp(t, "empty.mp3", writebackAudio(100)), " \n ", true)
	wantWritebackCode(t, err, wbErrNoLyrics)

	_, err = writeLyricsToFile(writeTemp(t, "pre.flac", append([]byte("ID3\x04\x00\x00\x00\x00\x00\x00"), "fLaC"...)), writebackLRC, true)
	wantWritebackCode(t, err, wbErrUnsupportedTag)

	broken := id3TagPadded(4, 0, id3Frame(4, "TIT2", []byte{3, 'x'}))
	broken[13+4] = 0x7F
	_, err = writeLyricsToFile(writeTemp(t, "broken.mp3", append(broken, writebackAudio(100)...)), writebackLRC, true)
	wantWritebackCode(t, err, wbErrUnsupportedTag)
}

func TestLyricsWritebackNotWritable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 不受权限位限制")
	}
	path, data := sampleMP3WithLyrics(t)
	if err := os.Chmod(path, 0o444); err != nil {
		t.Fatal(err)
	}
	_, err := writeLyricsToFile(path, writebackLRC, true)
	wantWritebackCode(t, err, wbErrNotWritable)

	dir := filepath.Join(t.TempDir(), "locked")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	inLocked := filepath.Join(dir, "a.mp3")
	if err := os.WriteFile(inLocked, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })
	_, err = writeLyricsToFile(inLocked, writebackLRC, true)
	wantWritebackCode(t, err, wbErrNotWritable)
	if out, _ := os.ReadFile(inLocked); !bytes.Equal(out, data) {
		t.Errorf("目录不可写时文件不动")
	}
}

func TestLyricsWritebackLinks(t *testing.T) {
	path, _ := sampleMP3WithLyrics(t)
	hard := filepath.Join(filepath.Dir(path), "hard.mp3")
	if err := os.Link(path, hard); err != nil {
		t.Fatal(err)
	}
	_, err := writeLyricsToFile(path, writebackLRC, true)
	wantWritebackCode(t, err, wbErrHardLinked)
	os.Remove(hard)

	link := filepath.Join(t.TempDir(), "link.mp3")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	got, err := writeLyricsToFile(link, writebackLRC, true)
	if err != nil {
		t.Fatal(err)
	}
	real, _ := filepath.EvalSymlinks(path)
	if got != real {
		t.Errorf("软链接写到它指向的文件:得到 %q,想要 %q", got, real)
	}
	if fi, err := os.Lstat(link); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Errorf("软链接本身应保持是软链接")
	}
	if tags := readLocalFileTags(path); tags.lyrics != writebackLRC {
		t.Errorf("目标文件回读不对")
	}
}

func TestLyricsWritebackLocationChecks(t *testing.T) {
	home := "/Users/u"
	for path, want := range map[string]string{
		"/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a.mp3": wbErrCloudLocation,
		"/Users/u/Library/CloudStorage/Dropbox/a.flac":                wbErrCloudLocation,
		"/Users/u/Music/a.mp3":                                        "",
		"/Users/u/Library/Mobile Documents.mp3":                       "",
	} {
		err := cloudLocationErr(path, home)
		if want == "" && err != nil || want != "" && lyricsWritebackCode(err) != want {
			t.Errorf("%s:%v", path, err)
		}
	}
	wantWritebackCode(t, volumeFlagsErr(mntLocal|mntReadOnly), wbErrReadOnlyVolume)
	wantWritebackCode(t, volumeFlagsErr(0), wbErrNetworkLocation)
	if err := volumeFlagsErr(mntLocal); err != nil {
		t.Errorf("本地可写卷:%v", err)
	}
}

// 自校验:克隆写完之后被改坏,一律放弃替换、原文件不动、克隆清掉。
func TestLyricsWritebackSelfCheckRejectsCorruptClone(t *testing.T) {
	t.Cleanup(func() { lyricsWritebackAfterWrite = nil })
	corrupt := map[string]func(data []byte, headLen int){
		wbErrAudioMismatch:    func(d []byte, h int) { d[len(d)-500] ^= 0xFF },
		wbErrTagsNotPreserved: func(d []byte, h int) { d[20] ^= 0x01 },
	}
	for code, mutate := range corrupt {
		for _, ext := range []string{"mp3", "flac"} {
			var data []byte
			if ext == "mp3" {
				data = append(id3TagPadded(4, 256, id3Frame(4, "TIT2", append([]byte{3}, "title-frame-bytes"...))), writebackAudio(6000)...)
			} else {
				data = bytes.Join([][]byte{[]byte("fLaC"), flacBlockBytes(0, false, bytes.Repeat([]byte{0x11}, 34)),
					flacBlockBytes(1, true, make([]byte, 1024)), writebackAudio(6000)}, nil)
			}
			path := writeTemp(t, "c."+ext, data)
			lyricsWritebackAfterWrite = func(clone string) {
				d, err := os.ReadFile(clone)
				if err != nil {
					t.Fatal(err)
				}
				mutate(d, 0)
				if err := os.WriteFile(clone, d, 0o644); err != nil {
					t.Fatal(err)
				}
			}
			_, err := writeLyricsToFile(path, writebackLRC, true)
			if lyricsWritebackCode(err) != code {
				t.Errorf("%s:想要 %s,得到 %v", ext, code, err)
			}
			if out, _ := os.ReadFile(path); !bytes.Equal(out, data) {
				t.Errorf("%s %s:自校验失败时原文件不动", ext, code)
			}
			noLeftoverClones(t, filepath.Dir(path))
		}
	}
	path := writeTemp(t, "r.mp3", writebackAudio(3000))
	lyricsWritebackAfterWrite = func(clone string) {
		d, _ := os.ReadFile(clone)
		i := bytes.Index(d, []byte("第三行"))
		copy(d[i:], "第四行")
		os.WriteFile(clone, d, 0o644)
	}
	_, err := writeLyricsToFile(path, writebackLRC, true)
	wantWritebackCode(t, err, wbErrReadbackMismatch)
}

func TestLyricsWritebackEditChannel(t *testing.T) {
	const key = "周杰伦|稻香|魔杰座"
	setUpEnrichEditTest(t, map[string]enrichEntry{
		key:        {Lyrics: bt(writebackLRC)},
		"a|plain|": {PlainLyrics: bt(writebackPlain)},
		"a|none|":  {Instrumental: true},
	})
	path := writeTemp(t, "song.mp3", writebackAudio(4000))

	res := applyEnrichEdit(enrichEditRequest{Op: "probe_file_lyrics", FilePath: path})
	if !res.OK || res.FileHasLyrics {
		t.Fatalf("probe 没有歌词的文件:%+v", res)
	}
	res = applyEnrichEdit(enrichEditRequest{Op: "write_file_lyrics", Key: key, FilePath: path})
	if !res.OK || res.Changed != 1 || res.FilePath == "" {
		t.Fatalf("写入:%+v", res)
	}
	if tags := readLocalFileTags(path); tags.lyrics != writebackLRC {
		t.Errorf("写进去的是这首的逐行歌词:%q", tags.lyrics)
	}
	if res = applyEnrichEdit(enrichEditRequest{Op: "probe_file_lyrics", FilePath: path}); !res.OK || !res.FileHasLyrics {
		t.Errorf("probe 写过的文件:%+v", res)
	}
	res = applyEnrichEdit(enrichEditRequest{Op: "write_file_lyrics", Key: "a|plain|", FilePath: path})
	if res.OK || res.ErrorCode != wbErrHasLyrics {
		t.Errorf("没带覆盖时拒绝:%+v", res)
	}
	res = applyEnrichEdit(enrichEditRequest{Op: "write_file_lyrics", Key: "a|plain|", FilePath: path, Value: true})
	if !res.OK {
		t.Fatalf("覆盖:%+v", res)
	}
	if tags := readLocalFileTags(path); tags.lyrics != normalizeWritebackLyrics(writebackPlain) {
		t.Errorf("只有纯文本的写纯文本:%q", tags.lyrics)
	}
	res = applyEnrichEdit(enrichEditRequest{Op: "write_file_lyrics", Key: "a|none|", FilePath: path, Value: true})
	if res.OK || res.ErrorCode != wbErrNoLyrics {
		t.Errorf("没有歌词的条目:%+v", res)
	}
	res = applyEnrichEdit(enrichEditRequest{Op: "write_file_lyrics", Key: key, FilePath: path + ".m4a"})
	if res.OK || res.ErrorCode != wbErrUnsupportedFormat {
		t.Errorf("不支持的格式:%+v", res)
	}
}
