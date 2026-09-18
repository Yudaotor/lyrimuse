package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 全部用合成的 QueueCache,不读本机真实的汽水缓存(TestMain 已经把 override 指到不存在
// 的路径,这里各用例再自己指到临时文件)。
//
// ⚠️ fixture 里的曲目取自本机真实 QueueCache 的字段值(曲名/歌手/专辑/毫秒时长都是
// 原样),但 vocal==2 那条是**构造**的 —— 真实队列那 24 首 vocal 全是 1,一条纯音乐
// 样本都没有。见 sodalocal.go 头注里"未实测验证"那段。

// sodaTestTrack 按 QueueCache 里真实的写法造一条曲目。artist 用 "|" 分隔多个署名。
func sodaTestTrack(name, artist, album string, durationMS int64, vocal int) map[string]any {
	artists := []map[string]any{}
	for _, a := range splitNonEmpty(artist, "|") {
		artists = append(artists, map[string]any{"id": "1", "name": a})
	}
	return map[string]any{
		"name": name, "duration": durationMS, "vocal": vocal,
		"artists": artists,
		"album":   map[string]any{"id": "9", "name": album},
	}
}

func splitNonEmpty(s, sep string) []string {
	var out []string
	for _, p := range bytes.Split([]byte(s), []byte(sep)) {
		if len(p) > 0 {
			out = append(out, string(p))
		}
	}
	return out
}

// writeTestSodaQueue 造一个跟真实文件同构的 QueueCache:4 字节 "LUNA" + 原生 gzip + JSON。
func writeTestSodaQueue(t *testing.T, tracks []map[string]any) string {
	t.Helper()
	playables := make([]map[string]any, 0, len(tracks))
	for _, tr := range tracks {
		playables = append(playables, map[string]any{"key": "track-x", "type": "track", "track": tr})
	}
	body, err := json.Marshal(map[string]any{
		"u_597773443927244:feed": map[string]any{
			"version": 2, "savedAt": 1789733545230, "hasMore": true,
			"playables": playables,
		},
	})
	if err != nil {
		t.Fatalf("造 JSON 失败: %v", err)
	}
	var buf bytes.Buffer
	buf.Write(sodaLocalMagic)
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(body); err != nil {
		t.Fatalf("压缩失败: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("关闭 gzip 失败: %v", err)
	}
	dir := filepath.Join(t.TempDir(), "LunaStorage")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("建目录失败: %v", err)
	}
	path := filepath.Join(dir, "QueueCache")
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatalf("写文件失败: %v", err)
	}
	return path
}

func resetSodaLocalIndex(t *testing.T, path string) {
	t.Helper()
	clear := func() {
		sodaLocalMu.Lock()
		sodaLocalIndex, sodaLocalReady, sodaLocalScanned = nil, false, time.Time{}
		sodaLocalMod, sodaLocalSize = time.Time{}, 0
		sodaLocalMu.Unlock()
	}
	clear()
	old := sodaLocalQueueOverride
	sodaLocalQueueOverride = path
	t.Cleanup(func() {
		sodaLocalQueueOverride = old
		clear()
	})
}

// TestSodaLocalInstrumental 覆盖这条路径的判定面:vocal==2 才算纯音乐,vocal==1 不算,
// 时长对不上不算,歌手名缺失不算。
func TestSodaLocalInstrumental(t *testing.T) {
	path := writeTestSodaQueue(t, []map[string]any{
		// 真实队列里的三首(vocal 原样 = 1)。
		sodaTestTrack("Rosy (15 Khalil Live in HK 2011)", "方大同", "15 Khalil Fong Live in Hong Kong 2011", 259947, 1),
		sodaTestTrack("味道（Feat. Zion.T/Crush）", "Zion.T|Crush|方大同", "JTW西游记", 250099, 1),
		// 构造的纯音乐条目(真实样本里没有 vocal==2 的)。
		sodaTestTrack("某支纯音乐", "某乐手", "某专辑", 180000, 2),
	})
	resetSodaLocalIndex(t, path)

	cases := []struct {
		name                 string
		artist, title, album string
		durationSecs         float64
		want                 bool
	}{
		{"vocal==2 判为纯音乐", "某乐手", "某支纯音乐", "某专辑", 180, true},
		{"vocal==1 不判为纯音乐", "方大同", "Rosy (15 Khalil Live in HK 2011)", "15 Khalil Fong Live in Hong Kong 2011", 259.947, false},
		{"队列里没有这首歌", "查无此人", "查无此曲", "", 200, false},
		{"时长对不上就不认(纯音乐结论宁可不给)", "某乐手", "某支纯音乐", "某专辑", 300, false},
		{"歌手名缺失不做只按歌名的兜底", "", "某支纯音乐", "某专辑", 180, false},
		{"歌名缺失同样不兜底", "某乐手", "", "某专辑", 180, false},
		{"专辑对不上但时长对得上,仍然认", "某乐手", "某支纯音乐", "另一张专辑", 180, true},
		{"本地时长未知(0)时不卡时长闸", "某乐手", "某支纯音乐", "某专辑", 0, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := sodaLocalInstrumental(c.artist, c.title, c.album, c.durationSecs)
			if got != c.want {
				t.Fatalf("sodaLocalInstrumental(%q,%q,%q,%v) = %v, 期望 %v",
					c.artist, c.title, c.album, c.durationSecs, got, c.want)
			}
		})
	}
}

// TestSodaLocalMultiArtistIndexed 多歌手曲目每个署名都要能查到 —— 本地标签常只写其中
// 一位。真实队列里《味道（Feat. Zion.T/Crush）》就是三人合唱。
func TestSodaLocalMultiArtistIndexed(t *testing.T) {
	path := writeTestSodaQueue(t, []map[string]any{
		sodaTestTrack("三人合唱的纯音乐", "Zion.T|Crush|方大同", "JTW西游记", 250099, 2),
	})
	resetSodaLocalIndex(t, path)

	for _, artist := range []string{"Zion.T", "Crush", "方大同"} {
		if !sodaLocalInstrumental(artist, "三人合唱的纯音乐", "JTW西游记", 250.099) {
			t.Fatalf("署名 %q 应该也能查到这条多歌手曲目", artist)
		}
	}
}

// TestSodaLocalDecodeRejectsBadInput 格式判断保持严格:魔数不对 / 不是 gzip / JSON 坏了,
// 一律不命中,且不能 panic。读的是另一个 App 的缓存,对方升级随时可能改格式。
func TestSodaLocalDecodeRejectsBadInput(t *testing.T) {
	good := func() []byte {
		var buf bytes.Buffer
		buf.Write(sodaLocalMagic)
		zw := gzip.NewWriter(&buf)
		zw.Write([]byte(`{"k":{"playables":[{"track":{"name":"x","vocal":2,"artists":[{"name":"y"}]}}]}}`))
		zw.Close()
		return buf.Bytes()
	}()

	cases := []struct {
		name    string
		raw     []byte
		wantLen int
		wantErr bool
	}{
		{"正常输入", good, 1, false},
		{"空文件", nil, 0, false},
		{"魔数不对(直接是 gzip,没有 LUNA 头)", good[len(sodaLocalMagic):], 0, false},
		{"魔数对但后面不是 gzip", append(append([]byte{}, sodaLocalMagic...), []byte("not gzip")...), 0, true},
		{"只有魔数", sodaLocalMagic, 0, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tracks, err := decodeSodaLocalQueue(c.raw)
			if (err != nil) != c.wantErr {
				t.Fatalf("err = %v, 期望有错 = %v", err, c.wantErr)
			}
			if len(tracks) != c.wantLen {
				t.Fatalf("解出 %d 条,期望 %d 条", len(tracks), c.wantLen)
			}
		})
	}
}

// TestSodaLocalDecodeRealFormat 用真实文件里的字段形状解一遍,盯住"字段名改了就静默
// 失效"这类回归 —— duration 是毫秒整数、artists 是对象数组、album 是嵌套对象。
func TestSodaLocalDecodeRealFormat(t *testing.T) {
	var buf bytes.Buffer
	buf.Write(sodaLocalMagic)
	zw := gzip.NewWriter(&buf)
	// 这段 JSON 的字段名与嵌套形状照抄本机真实 QueueCache。
	zw.Write([]byte(`{"u_597773443927244:feed":{"version":2,"savedAt":1789733545230,"cursor":null,"hasMore":true,"playables":[{"key":"track-6705073168131819522","type":"track","track":{"id":"6705073168131819522","album":{"id":"1","name":"15 Khalil Fong Live in Hong Kong 2011"},"artists":[{"id":"2","name":"方大同"}],"duration":259947,"name":"Rosy (15 Khalil Live in HK 2011)","vocal":1,"first_vocal":{"duration":47232,"start":16704},"chorus":{"duration":0,"start":63936},"lang_codes":["EN"]}}]}}`))
	zw.Close()

	tracks, err := decodeSodaLocalQueue(buf.Bytes())
	if err != nil {
		t.Fatalf("解真实格式失败: %v", err)
	}
	if len(tracks) != 1 {
		t.Fatalf("解出 %d 条,期望 1 条", len(tracks))
	}
	got := tracks[0]
	if got.Name != "Rosy (15 Khalil Live in HK 2011)" {
		t.Fatalf("name = %q", got.Name)
	}
	// 259947ms 这个值本身是证据:MediaRemote 对同一首歌报的 duration 是 259.947007s,
	// 两边逐毫秒一致 —— 这正是"匹配维度零增量"那条结论的来源。
	if got.Duration != 259947 {
		t.Fatalf("duration = %d, 期望 259947", got.Duration)
	}
	if got.Vocal != 1 {
		t.Fatalf("vocal = %d, 期望 1", got.Vocal)
	}
	if len(got.Artists) != 1 || got.Artists[0].Name != "方大同" {
		t.Fatalf("artists = %+v", got.Artists)
	}
	if got.Album.Name != "15 Khalil Fong Live in Hong Kong 2011" {
		t.Fatalf("album = %q", got.Album.Name)
	}
}

// TestInstrumentalFromScoredOrder 联网信号是主力、本地兜底在最后 —— 顺序反了会让
// 覆盖面窄且未经真实样本验证的本地信号抢在四个联网源前面。
func TestInstrumentalFromScoredOrder(t *testing.T) {
	path := writeTestSodaQueue(t, []map[string]any{
		sodaTestTrack("某支纯音乐", "某乐手", "某专辑", 180000, 2),
	})
	resetSodaLocalIndex(t, path)

	t.Run("联网源给了就用联网源的来源标签", func(t *testing.T) {
		scored := []scoredLyricCandidateResult{{Source: "lrclib", Instrumental: true}}
		ok, src := instrumentalFromScored(scored, "某乐手", "某支纯音乐", "某专辑", 180)
		if !ok || src != "lrclib" {
			t.Fatalf("ok=%v src=%q, 期望 true/\"lrclib\"", ok, src)
		}
	})

	t.Run("联网源都沉默时才用本地兜底", func(t *testing.T) {
		ok, src := instrumentalFromScored(nil, "某乐手", "某支纯音乐", "某专辑", 180)
		if !ok || src != "soda local" {
			t.Fatalf("ok=%v src=%q, 期望 true/\"soda local\"", ok, src)
		}
	})

	t.Run("两边都没有就是没有", func(t *testing.T) {
		scored := []scoredLyricCandidateResult{{Source: "qq", Lyrics: "[00:01.00]词"}}
		ok, src := instrumentalFromScored(scored, "查无此人", "查无此曲", "", 200)
		if ok || src != "" {
			t.Fatalf("ok=%v src=%q, 期望 false/\"\"", ok, src)
		}
	})
}
