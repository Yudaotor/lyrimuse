package main

import (
	"bytes"
	"compress/zlib"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 合成一个跟酷狗客户端落盘形态一致的 .krc:zlib 压缩 → 逐字节异或 krcXORKey → 前面加
// "krc1" 魔数。用合成数据而不是拷一份真文件:真文件是用户自己的听歌记录,不该进仓库,
// 而格式契约("krc1"+xor+zlib)本身就是这里要钉住的东西。
func writeTestKRC(t *testing.T, dir, name, body string) string {
	t.Helper()
	var buf bytes.Buffer
	zw := zlib.NewWriter(&buf)
	if _, err := zw.Write([]byte(body)); err != nil {
		t.Fatalf("zlib write: %v", err)
	}
	zw.Close()
	raw := buf.Bytes()
	out := make([]byte, 0, len(raw)+4)
	out = append(out, []byte("krc1")...)
	for i, b := range raw {
		out = append(out, b^krcXORKey[i%len(krcXORKey)])
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}

// 形态照着真实文件来:头部一串元标签,正文每行 `[行始ms,行长ms]<相对ms,时长ms,flag>字`。
const testKRCGeLian = `[id:$00000000]
[ar:周杰伦]
[ti:搁浅]
[by:]
[hash:fbc234520fed713c30c1c026e7352770]
[al:七里香]
[sign:]
[qq:]
[total:0]
[offset:0]
[61230,2000]<0,500,0>雨<500,500,0>後<1000,1000,0>的<2000,0,0>操場
[63500,1500]<0,700,0>那<700,800,0>對話`

func resetKugouLocalIndex(t *testing.T, dir string) {
	t.Helper()
	kugouLocalMu.Lock()
	kugouLocalIndex, kugouLocalReady, kugouLocalScanned = nil, false, time.Time{}
	kugouLocalDirMod = time.Time{}
	kugouLocalMu.Unlock()
	old := kugouLocalDirOverride
	kugouLocalDirOverride = dir
	t.Cleanup(func() {
		kugouLocalDirOverride = old
		kugouLocalMu.Lock()
		kugouLocalIndex, kugouLocalReady, kugouLocalScanned = nil, false, time.Time{}
		kugouLocalDirMod = time.Time{}
		kugouLocalMu.Unlock()
	})
}

func TestDecryptKRCBytesRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := writeTestKRC(t, dir, "x.krc", testKRCGeLian)
	got := decryptKRCFile(path)
	if !strings.Contains(got, "[ti:搁浅]") || !strings.Contains(got, "<0,500,0>雨") {
		t.Fatalf("解密结果不对: %.80q", got)
	}
	// 不是 krc1 开头的文件(同目录下那批 artistsInfo- plist 就是)必须安静返回空串,不 panic。
	plain := filepath.Join(dir, "notkrc.krc")
	os.WriteFile(plain, []byte("<?xml version=\"1.0\"?><plist/>"), 0o644)
	if got := decryptKRCFile(plain); got != "" {
		t.Fatalf("非 KRC 文件该返回空串,得到 %.40q", got)
	}
	if got := decryptKRCFile(filepath.Join(dir, "没有这个文件.krc")); got != "" {
		t.Fatalf("文件不存在该返回空串,得到 %.40q", got)
	}
}

func TestKRCToLRC(t *testing.T) {
	lrc := krcToLRC(testKRCGeLian)
	want := []string{"[ti:搁浅]", "[ar:周杰伦]", "[al:七里香]", "[offset:0]",
		"[01:01.23]雨後的操場", "[01:03.50]那對話"}
	for _, w := range want {
		if !strings.Contains(lrc, w) {
			t.Errorf("LRC 里缺 %q\n实际:\n%s", w, lrc)
		}
	}
	// KRC 自己那几个非 LRC 元标签不该漏进去 —— 下游会把它们当歌词行显示。
	for _, bad := range []string{"[hash:", "[sign:", "[qq:", "[total:", "[id:"} {
		if strings.Contains(lrc, bad) {
			t.Errorf("LRC 里不该有 %q\n实际:\n%s", bad, lrc)
		}
	}
	// 行内逐字标记必须清干净(逐字数据由 krcToYRC 单独产出)。
	if strings.Contains(lrc, "<") {
		t.Errorf("LRC 残留逐字标记:\n%s", lrc)
	}
	if krcToLRC("") != "" || krcToLRC("[ti:只有头没有正文]") != "" {
		t.Error("没有计时行时应返回空串,免得把一份没有歌词的壳当成候选")
	}
}

func TestKugouLocalLyricHit(t *testing.T) {
	dir := t.TempDir()
	writeTestKRC(t, dir, "周杰伦 - 搁浅_abc.krc", testKRCGeLian)
	// 同目录下的歌手资料 plist 不是歌词,索引必须跳过它而不是报错。
	os.WriteFile(filepath.Join(dir, "artistsInfo-周杰伦 - 搁浅_abc"), []byte("<?xml?>"), 0o644)
	resetKugouLocalIndex(t, dir)

	r, ok := kugouLocalLyric("周杰伦", "搁浅", "七里香")
	if !ok {
		t.Fatal("本地缓存里有这首歌,应该命中")
	}
	if !strings.Contains(r.lrc, "[01:01.23]雨後的操場") {
		t.Errorf("整行歌词不对:\n%s", r.lrc)
	}
	// 逐字数据要按 krcToYRC 的规矩转成绝对时间戳(61230+500=61730)。
	if !strings.Contains(r.yrc, "(61730,500,0)後") {
		t.Errorf("逐字数据没转成绝对时间戳:\n%s", r.yrc)
	}
	if r.artist != "周杰伦" || r.title != "搁浅" || r.album != "七里香" {
		t.Errorf("元数据不对: %q / %q / %q", r.artist, r.title, r.album)
	}
	if r.durationSecs != 0 {
		t.Errorf("KRC 的 [total:] 实测恒为 0,不该报出一个假时长: %v", r.durationSecs)
	}

	// 繁简 / 大小写 / 标点的差异由 normLoose 折掉 —— 本地曲库标的是简体、播放器报的是
	// 繁体(或反过来)时照样要命中,这正是 normLoose 存在的理由。
	if _, ok := kugouLocalLyric("周杰倫", "擱淺", ""); !ok {
		t.Error("繁体歌名应该能命中同一份缓存")
	}
	if _, ok := kugouLocalLyric("周杰伦", "不存在的歌", ""); ok {
		t.Error("没有的歌不该命中")
	}
	if _, ok := kugouLocalLyric("", "搁浅", ""); ok {
		t.Error("歌手为空时不该拿歌名硬匹配")
	}
}

func TestKugouLocalLyricPicksByAlbum(t *testing.T) {
	dir := t.TempDir()
	writeTestKRC(t, dir, "a.krc", testKRCGeLian)
	live := strings.ReplaceAll(testKRCGeLian, "[al:七里香]", "[al:无与伦比演唱会]")
	writeTestKRC(t, dir, "b.krc", live)
	resetKugouLocalIndex(t, dir)

	r, ok := kugouLocalLyric("周杰伦", "搁浅", "无与伦比演唱会")
	if !ok {
		t.Fatal("应该命中")
	}
	if r.album != "无与伦比演唱会" {
		t.Errorf("同名两份时该挑专辑对得上的那份,得到 %q", r.album)
	}
	// 专辑对不上时不硬挑,返回第一份交给下游打分去比 —— 不在这一层武断否掉。
	if _, ok := kugouLocalLyric("周杰伦", "搁浅", "完全不相干的专辑"); !ok {
		t.Error("专辑对不上也该给出候选,由 scoreLyricCandidate 决定用不用")
	}
}

func TestKugouLocalLyricMissingDir(t *testing.T) {
	resetKugouLocalIndex(t, filepath.Join(t.TempDir(), "没有这个目录"))
	if _, ok := kugouLocalLyric("周杰伦", "搁浅", ""); ok {
		t.Error("目录不存在时必须安静地当作没命中(没装酷狗的人是多数)")
	}
}

// kugou 有两个产出点(正常轮、熔断冷却时的本地兜底),都经 kugouSourceResult 摊平。
// 这条盯的是**别漏字段**:漏一个的后果是"歌词出来了,但逐字/译文/专辑名莫名其妙没了",
// 而且只在冷却那条路上出现,极难撞见。
func TestKugouSourceResultCarriesEveryField(t *testing.T) {
	src := kugouResult{
		lrc: "[00:01.00]词", yrc: "[1000,500](1000,500,0)词", tr: "[00:01.00]translated",
		roma: "[00:01.00]ci", durationSecs: 233.5,
		title: "搁浅", artist: "周杰伦", album: "七里香", cover: "http://x/y.jpg",
		language: songLanguageMandarin,
	}
	got := kugouSourceResult(src)
	for _, c := range []struct {
		name      string
		got, want any
	}{
		{"source", got.source, "kugou"},
		{"lyr", got.lyr, src.lrc},
		{"yrc", got.yrc, src.yrc},
		{"tr", got.tr, src.tr},
		{"roma", got.roma, src.roma},
		{"matchTitle", got.matchTitle, src.title},
		{"matchArtist", got.matchArtist, src.artist},
		{"matchAlbum", got.matchAlbum, src.album},
		{"matchCover", got.matchCover, src.cover},
		{"srcDur", got.srcDur, src.durationSecs},
		{"language", got.language, src.language},
	} {
		if c.got != c.want {
			t.Errorf("%s: 得到 %v,期望 %v", c.name, c.got, c.want)
		}
	}
}
