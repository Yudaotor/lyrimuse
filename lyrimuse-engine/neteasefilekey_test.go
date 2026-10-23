package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"encoding/base64"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// realNeteaseFileKey:网易云下载的《いけないボーダーライン》(ワルキューレ)注释里原样的那段。
const realNeteaseFileKey = "163 key(Don't modify):L64FU3W4YxX3ZFTmbZ+8/S2B+/wBoyeTp7afEUhS1QrqwYLNhzaZvWuGiT3va6aojeQiUHiR4DS8ejJIwKDyv5GE5Mc5DxlbnLSbb99iiXCVJ65Xa3oipmMvFNF3unCgLbRrWVk9I6CW5alwNsAxjXViX6TdUmUSdj6OFRHYnx881BK/7fPXr3m84bH2Tyl9Yero/j/ogsoD4PoeP+mP5AegSEMIqqbPAVuR52uRSFjBtbJ1EtY2eLGjCWj59jJH+Cyg7pJ+OfOL1d/Ff0LGd2cqGhOr9Rt1KjTcFJ8gOxXdxcU7nCy5sUA7FDPDaUmPc68Z1SqhQi03NCuMxGeS4LUWBnmigRxRA7pJ2rNTYaiouUu9zQzUq/m68RZwC7ww7bKsr3YiTbNN1eGHUv5bgWnd0LOpj0yBn2meolWEQwosKOsiI7nVxJSeLZTyiLuv6CULKfyYSr0Ga3ZSuvZxfBG1GOcy3GY4XQNriMK8fvaDNG3RVlO2ypYKLI75usZWQ+d2uuBUs+IKuQXJ99bgcQCMKOSqLuIrboOz1k65chuwxL4iLEtgpxSRZUoQICESHKt543PVHsMegTrDpgQ1tb6YJjvKmEzuwvoNE6KtPXYLZxPzPDaIqQ8z6YDXo2E/Yki52rO7tqeMAJL7s+AkhnFDHZa0rupUANVUeefVoNU="

// encryptNeteaseFileKey:照网易云的写法拼一条注释(PKCS#7 填充后 AES-128-ECB,再 Base64)。
func encryptNeteaseFileKey(plain string) string {
	b := []byte(plain)
	pad := aes.BlockSize - len(b)%aes.BlockSize
	b = append(b, bytes.Repeat([]byte{byte(pad)}, pad)...)
	block, _ := aes.NewCipher(neteaseFileKeyAES)
	for i := 0; i < len(b); i += aes.BlockSize {
		block.Encrypt(b[i:i+aes.BlockSize], b[i:i+aes.BlockSize])
	}
	return neteaseFileKeyPrefix + base64.StdEncoding.EncodeToString(b)
}

func TestParseNeteaseFileKey(t *testing.T) {
	k, ok := parseNeteaseFileKey(realNeteaseFileKey)
	if !ok || k.MusicID != 41629793 || k.AlbumID != 3443213 || k.MusicName != "いけないボーダーライン" || k.Duration != 278047 {
		t.Fatalf("真实文件里的那段: ok=%v %+v", ok, k)
	}
	if got := strings.Join(k.artistNames(), "/"); got != "ワルキューレ" {
		t.Errorf("歌手: %q", got)
	}
	s := k.song()
	if s.ID != 41629793 || s.Album.ID != 3443213 || s.Album.Name != "いけないボーダーライン" || len(s.Artists) != 1 ||
		!strings.HasPrefix(s.Album.PicURL, "https://p3.music.126.net/") || s.Duration != 278047 {
		t.Errorf("换成网易云源的结果: %+v", s)
	}

	num, ok := parseNeteaseFileKey(encryptNeteaseFileKey(`music:{"musicId":5237118,"musicName":"一丝不挂","artist":[["陈奕迅",2116],["",0]],"albumId":null,"duration":3000}`))
	if !ok || num.MusicID != 5237118 || num.AlbumID != 0 || strings.Join(num.artistNames(), "/") != "陈奕迅" {
		t.Errorf("id 写成数字、专辑 id 是 null、空歌手名跳过: ok=%v %+v", ok, num)
	}
	for name, c := range map[string]string{
		"占位(解开没有内容)":   "163 key(Don't modify):6YURAByiRHQ6CI5tvtxzQg==",
		"不是这种注释":       "Downloaded from somewhere",
		"不是 music:":    encryptNeteaseFileKey(`program:{"musicId":"1"}`),
		"没有曲目 id":      encryptNeteaseFileKey(`music:{"musicName":"x"}`),
		"Base64 坏了":    neteaseFileKeyPrefix + "!!!",
		"长度不是整块":       neteaseFileKeyPrefix + base64.StdEncoding.EncodeToString([]byte("short")),
		"填充不对(换了密钥写的)": neteaseFileKeyPrefix + base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)),
	} {
		if k, ok := parseNeteaseFileKey(c); ok {
			t.Errorf("%s 不该认: %+v", name, k)
		}
	}
}

func TestNeteaseFileKeyDurationAgrees(t *testing.T) {
	k := neteaseFileKey{Duration: 278047}
	for _, c := range []struct {
		dur  float64
		want bool
	}{{278, true}, {280.9, true}, {281.2, false}, {200, false}, {0, true}} {
		if got := neteaseFileKeyDurationAgrees(k, c.dur); got != c.want {
			t.Errorf("时长 %.1f: %v", c.dur, got)
		}
	}
	if !neteaseFileKeyDurationAgrees(neteaseFileKey{}, 200) {
		t.Error("标签里没有时长时不拦")
	}
}

// 注释在三种标签里各自的位置:ID3 的 COMM、Vorbis 的 COMMENT / DESCRIPTION、MP4 的 ©cmt;歌词照旧。
func TestLocalFileTagsReadComments(t *testing.T) {
	comm := append([]byte{3, 'e', 'n', 'g', 0}, realNeteaseFileKey...)
	tag := id3Tag(3, id3Frame(3, "COMM", comm), id3Frame(3, "USLT", usltBody(3, []byte(embeddedLRC))))
	got := tagsFromID3(tag[:10], tag[10:])
	if !got.hasLyrics || got.lyrics != embeddedLRC || len(got.comments) != 1 || got.comments[0] != realNeteaseFileKey {
		t.Errorf("ID3: %+v", got)
	}
	txxx := append([]byte{0}, "comment\x00"+realNeteaseFileKey...)
	tag = id3Tag(3, id3Frame(3, "TXXX", txxx))
	if got := tagsFromID3(tag[:10], tag[10:]); len(got.comments) != 1 || got.comments[0] != realNeteaseFileKey || got.hasLyrics {
		t.Errorf("ID3 的 TXXX:comment(ffmpeg 重写标签时的存法): %+v", got)
	}
	v := tagsFromVorbisComment(vorbisComment("TITLE=x", "DESCRIPTION="+realNeteaseFileKey, "comment=其它", "LYRICS="+embeddedLRC))
	if v.lyrics != embeddedLRC || strings.Join(v.comments, "|") != realNeteaseFileKey+"|其它" {
		t.Errorf("Vorbis: %+v", v)
	}
	atom := func(kind string, body ...[]byte) []byte {
		var b []byte
		for _, x := range body {
			b = append(b, x...)
		}
		return append(append(binary.BigEndian.AppendUint32(nil, uint32(8+len(b))), kind...), b...)
	}
	data := func(s string) []byte { return atom("data", []byte{0, 0, 0, 1, 0, 0, 0, 0}, []byte(s)) }
	moov := atom("udta", atom("meta", []byte{0, 0, 0, 0}, atom("ilst", atom("\xa9cmt", data(realNeteaseFileKey)), atom("\xa9lyr", data(embeddedLRC)))))
	m := tagsFromMP4Moov(moov)
	if m.lyrics != embeddedLRC || len(m.comments) != 1 || m.comments[0] != realNeteaseFileKey {
		t.Errorf("MP4: %+v", m)
	}
}

// 这首的文件:待播挂在 ctx 上的优先,否则看 App 报的当前文件;时长对不上(按文件名拼错了路径)不认;每首只读一次标签。
func TestNeteaseFileKeySong(t *testing.T) {
	comm := append([]byte{3, 'e', 'n', 'g', 0}, realNeteaseFileKey...)
	audio := writeTemp(t, "ワルキューレ - いけないボーダーライン.mp3", id3Tag(3, id3Frame(3, "COMM", comm)))
	plain := filepath.Join(filepath.Dir(audio), "plain.mp3")
	if err := os.WriteFile(plain, id3Tag(3, id3Frame(3, "TIT2", []byte{3, 'x'})), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { noteLocalFileCurrentTrack("", "", "", "") })

	if s, ok := neteaseFileKeySong(withLocalFilePath(context.Background(), audio), "ワルキューレ", "いけないボーダーライン", 278); !ok || s.ID != 41629793 {
		t.Errorf("待播挂着文件: ok=%v %d", ok, s.ID)
	}
	if _, ok := neteaseFileKeySong(withLocalFilePath(context.Background(), audio), "ワルキューレ", "いけないボーダーライン", 200); ok {
		t.Error("时长差太多不认")
	}
	if _, ok := neteaseFileKeySong(withLocalFilePath(context.Background(), plain), "a", "b", 0); ok {
		t.Error("没有 163 key 的文件")
	}
	if _, ok := neteaseFileKeySong(context.Background(), "ワルキューレ", "いけないボーダーライン", 278); ok {
		t.Error("没挂文件、也不是当前在放的")
	}
	noteLocalFileCurrentTrack(voxBundleID, "ワルキューレ", "いけないボーダーライン", audio)
	if s, ok := neteaseFileKeySong(context.Background(), "ワルキューレ", "いけないボーダーライン", 0); !ok || s.ID != 41629793 {
		t.Errorf("当前在放的文件: ok=%v %d", ok, s.ID)
	}
	if _, ok := neteaseFileKeySong(context.Background(), "别人", "下一首", 0); ok {
		t.Error("别的歌不拿当前文件的")
	}
	if p := localFilePathFor(withLocalFilePath(context.Background(), plain), "ワルキューレ", "いけないボーダーライン"); p != plain {
		t.Errorf("ctx 上挂着的优先于当前文件: %q", p)
	}
}

// 网易云源:本机曲库没有时按文件标签里的 id 取,不走搜索,算本机身份。
func TestNeteaseFileKeyIsWired(t *testing.T) {
	b, err := os.ReadFile("netease.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(b), "} else if keyed, ok := neteaseFileKeySong(ctx, artist, title, durationSecs); ok {\n\t\t// 本地文件标签里网易云记下的这首(neteasefilekey.go),同样不经搜索。\n\t\tchosen = &keyed\n\t\tfromLocalClient = true\n\t\tqueries = nil\n\t}") {
		t.Error("netease.go 没接文件标签里的曲目 id")
	}
}

// 待播带上文件:VOX 是库里的地址,reAMP 是 App 交的完整路径(当前这首也按完整路径认),Pine 按当前文件的目录拼文件名。
func TestUpcomingCarriesLocalFilePaths(t *testing.T) {
	if tr, ok := voxRowTrack(voxUpcomingRow{URL: voxFileURL("a.mp3"), Name: "A", Artist: "甲"}); !ok || tr.path != "/Users/x/Music/歌/a.mp3" {
		t.Errorf("VOX: ok=%v %q", ok, tr.path)
	}

	t.Cleanup(func() { noteLocalFileCurrentTrack("", "", "", "") })
	full := []pineQueueTrack{
		{Title: "A", Artist: "甲", File: "/m/1/a.mp3"}, {Title: "A", Artist: "甲", File: "/m/2/a.mp3"}, {Title: "B", Artist: "乙", File: "/m/2/b.mp3"},
	}
	withReampQueue(t, "off", full)
	noteLocalFileCurrentTrack(reampBundleID, "甲", "A", "/m/2/a.mp3")
	res, ok := reampUpcoming("甲", "A", 5)
	if !ok || pineGot(res) != "B" || res[0].path != "/m/2/b.mp3" {
		t.Errorf("reAMP 按完整路径认出第二份、待播带路径: ok=%v %q %+v", ok, pineGot(res), res)
	}

	tracks := []pineQueueTrack{{Title: "A", Artist: "甲", File: "a.mp3"}, {Title: "B", Artist: "乙", File: "b.mp3"}, {Title: "C", Artist: "丙"}}
	pineFillPaths(tracks, "/Users/x/Music/专辑/a.mp3")
	if tracks[1].path != "/Users/x/Music/专辑/b.mp3" || tracks[2].path != "" {
		t.Errorf("Pine 按当前目录拼: %+v", tracks)
	}
	none := []pineQueueTrack{{Title: "B", Artist: "乙", File: "b.mp3"}}
	pineFillPaths(none, "")
	if none[0].path != "" {
		t.Error("不知道当前文件时不拼")
	}
	if up, _ := pineListUpcoming(tracks, 0, 1, false, false); len(up) != 1 || up[0].path != "/Users/x/Music/专辑/b.mp3" {
		t.Errorf("列表往后取时带上: %+v", up)
	}
}
