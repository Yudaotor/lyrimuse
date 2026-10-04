package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 合成的 fsCachedData 条目,不读本机真实的 Apple Music 缓存。

// appleLocalTTML 造一份 Apple 形状的 TTML:正文两行(itunes:key=L1/L2),可选带一个
// <translations> 块。transKeys 用来造"译文 key 跟正文对不上"那种真实数据(见
// applemusicSubtitleTranslation 头注里的 Butterflies 案)。
func appleLocalTTML(kind string, transKeys []string) string {
	body := `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="en"><head><metadata>`
	if kind != "" {
		body += `<iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations><translation type="` + kind + `" xml:lang="zh-Hans">`
		for i, k := range transKeys {
			body += `<text for="` + k + `">译文第` + string(rune('1'+i)) + `行</text>`
		}
		body += `</translation></translations></iTunesMetadata>`
	}
	body += `<ttm:agent type="person" xml:id="v1"/></metadata></head><body dur="0:30.000"><div begin="7.439" end="10.928">` +
		`<p begin="7.439" end="9.027" itunes:key="L1" ttm:agent="v1"><span begin="7.439" end="7.619">Hello</span> <span begin="7.619" end="7.759">world</span></p>` +
		`<p begin="9.341" end="10.928" itunes:key="L2" ttm:agent="v1"><span begin="9.341" end="9.581">Second</span> <span begin="9.581" end="9.741">line</span></p>` +
		`</div></body></tt>`
	return body
}

// writeAppleLocalCache 造一个缓存目录。rels 的键是 "syllable-lyrics" / "lyrics"。
func writeAppleLocalCache(t *testing.T, entries []struct {
	ID   string
	Name string
	Rels map[string]string
}) string {
	t.Helper()
	dir := t.TempDir()
	for i, e := range entries {
		payload := map[string]any{"data": []any{}}
		rel := map[string]any{}
		for kind, ttml := range e.Rels {
			rel[kind] = map[string]any{"data": []any{
				map[string]any{"attributes": map[string]any{"ttmlLocalizations": ttml}},
			}}
		}
		payload["data"] = []any{map[string]any{
			"id": e.ID, "type": "songs",
			"attributes": map[string]any{
				"name": e.Name, "artistName": "某歌手", "albumName": "某专辑",
				"durationInMillis": 240000,
				"artwork":          map[string]any{"url": "https://example.invalid/{w}x{h}bb.jpg"},
			},
			"relationships": rel,
		}}
		b, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "entry"+string(rune('a'+i))), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// 混一个二进制文件(真实目录里大半是封面图),必须被安静跳过。
	if err := os.WriteFile(filepath.Join(dir, "artwork.bin"), []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10}, 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func resetAppleLocalIndex(t *testing.T, dir string) {
	t.Helper()
	clear := func() {
		applemusicLocalMu.Lock()
		applemusicLocalIndex, applemusicLocalReady = nil, false
		applemusicLocalScanned, applemusicLocalDirMod = time.Time{}, time.Time{}
		applemusicLocalMu.Unlock()
	}
	clear()
	old := applemusicLocalDirOverride
	applemusicLocalDirOverride = dir
	t.Cleanup(func() { applemusicLocalDirOverride = old; clear() })
}

type appleLocalSpec = struct {
	ID   string
	Name string
	Rels map[string]string
}

func TestApplemusicLocalLyricHit(t *testing.T) {
	dir := writeAppleLocalCache(t, []appleLocalSpec{
		{ID: "111", Name: "有逐字", Rels: map[string]string{"syllable-lyrics": appleLocalTTML("", nil)}},
	})
	resetAppleLocalIndex(t, dir)
	r, ok := applemusicLocalLyric("111", "", "", "", 0)
	if !ok {
		t.Fatal("应当命中本地缓存")
	}
	if r.lyrics == "" || r.yrc == "" {
		t.Fatalf("逐字那份必须同时给出整行和逐字: 整行%d 逐字%d", len(r.lyrics), len(r.yrc))
	}
	if r.title != "有逐字" || r.album != "某专辑" || r.artist != "某歌手" {
		t.Fatalf("元数据没透传: %+v", r)
	}
	if r.durationSecs != 240 {
		t.Fatalf("时长应从毫秒换算成 240s,得到 %v", r.durationSecs)
	}
	// cover 必须把 {w}x{h} 模板替换掉 —— 原样用会 404。
	if strings.Contains(r.cover, "{w}") || r.cover == "" {
		t.Fatalf("cover 模板没替换: %q", r.cover)
	}
	if r.plainOnly {
		t.Fatal("逐字那份不该标 plainOnly")
	}
}

func TestApplemusicLocalPrefersSyllable(t *testing.T) {
	dir := writeAppleLocalCache(t, []appleLocalSpec{
		{ID: "222", Name: "两种都有", Rels: map[string]string{
			"lyrics":          appleLocalTTML("", nil),
			"syllable-lyrics": appleLocalTTML("", nil),
		}},
	})
	resetAppleLocalIndex(t, dir)
	r, ok := applemusicLocalLyric("222", "", "", "", 0)
	if !ok || r.yrc == "" {
		t.Fatalf("两种都在时必须选逐字那份: ok=%v 逐字%d字", ok, len(r.yrc))
	}
}

func TestApplemusicLocalTranslationOnlySubtitle(t *testing.T) {
	dir := writeAppleLocalCache(t, []appleLocalSpec{
		// ① 真翻译(subtitle),key 对得上 → 应当拿到译文
		{ID: "301", Name: "真翻译", Rels: map[string]string{
			"syllable-lyrics": appleLocalTTML("subtitle", []string{"L1", "L2"})}},
		// ② 繁简替换(replacement) → 必须忽略:那不是译文,仓库另有 toSimplified 处理繁简
		{ID: "302", Name: "繁简替换", Rels: map[string]string{
			"syllable-lyrics": appleLocalTTML("replacement", []string{"L1", "L2"})}},
		// ③ key 对不上(Apple 自己的数据就有这种) → 宁可不给也不按顺序硬凑
		{ID: "303", Name: "key错位", Rels: map[string]string{
			"syllable-lyrics": appleLocalTTML("subtitle", []string{"L83274", "L83275"})}},
	})
	resetAppleLocalIndex(t, dir)

	r, ok := applemusicLocalLyric("301", "", "", "", 0)
	if !ok || r.tr == "" {
		t.Fatalf("subtitle 型应当解析出译文: ok=%v tr=%q", ok, r.tr)
	}
	if !strings.Contains(r.tr, "[00:07.") {
		t.Fatalf("译文时间戳应当取自正文的 <p begin>: %q", strings.SplitN(r.tr, "\n", 2)[0])
	}
	if r2, ok := applemusicLocalLyric("302", "", "", "", 0); !ok || r2.tr != "" {
		t.Fatalf("replacement(繁简)不该当译文: ok=%v tr=%q", ok, r2.tr)
	}
	if r3, ok := applemusicLocalLyric("303", "", "", "", 0); !ok || r3.tr != "" {
		t.Fatalf("key 对不上时不该硬凑译文: ok=%v tr=%q", ok, r3.tr)
	}
}

func TestApplemusicLocalMisses(t *testing.T) {
	dir := writeAppleLocalCache(t, []appleLocalSpec{
		{ID: "111", Name: "有逐字", Rels: map[string]string{"syllable-lyrics": appleLocalTTML("", nil)}},
	})
	resetAppleLocalIndex(t, dir)
	if _, ok := applemusicLocalLyric("", "", "", "", 0); ok {
		t.Error("catalogID 为空时不该命中")
	}
	if _, ok := applemusicLocalLyric("999", "", "", "", 0); ok {
		t.Error("不存在的 id 不该命中")
	}
}

func TestApplemusicLocalMissingDir(t *testing.T) {
	resetAppleLocalIndex(t, filepath.Join(t.TempDir(), "没有这个目录"))
	if _, ok := applemusicLocalLyric("111", "", "", "", 0); ok {
		t.Error("目录不存在时不该命中")
	}
}

func TestApplemusicLocalMatchesByNameWhenNoCatalogID(t *testing.T) {
	// 这条是主力路径:实测从资料库播放时 MediaRemote 给的 uniqueIdentifier 是**负数**
	// 持久 ID,appleCatalogAnchor 不成立、catalog id 拿不到。只按 id 查的话这条路在最常见
	// 的场景下等于不存在。
	dir := writeAppleLocalCache(t, []appleLocalSpec{
		{ID: "401", Name: "按名字找得到", Rels: map[string]string{"syllable-lyrics": appleLocalTTML("", nil)}},
	})
	resetAppleLocalIndex(t, dir)
	r, ok := applemusicLocalLyric("", "某歌手", "按名字找得到", "某专辑", 240)
	if !ok || r.yrc == "" {
		t.Fatalf("catalog id 为空时应当按名字命中: ok=%v 逐字%d字", ok, len(r.yrc))
	}
	// 歌手对不上不该命中 —— 这条路比按 id 松,身份闸不能省。
	if _, ok := applemusicLocalLyric("", "别的歌手", "按名字找得到", "", 240); ok {
		t.Error("歌手对不上不该命中")
	}
	// 时长差 >12% 不该命中:缓存里同时躺着同一首歌的现场版/原版是常态。
	if _, ok := applemusicLocalLyric("", "某歌手", "按名字找得到", "", 400); ok {
		t.Error("时长差 >12%% 不该命中")
	}
	// 播放器没报时长时 sourceDurationFits 不下结论 → 照常命中。
	if _, ok := applemusicLocalLyric("", "某歌手", "按名字找得到", "", 0); !ok {
		t.Error("时长未知时应当命中")
	}
}

func TestApplemusicLocalPicksClosestDuration(t *testing.T) {
	// 同名同歌手的两版(现场 / 原版),按时长挑。
	dir := t.TempDir()
	for i, spec := range []struct {
		id string
		ms int
	}{{"501", 300000}, {"502", 240000}} {
		payload := map[string]any{"data": []any{map[string]any{
			"id": spec.id, "type": "songs",
			"attributes": map[string]any{
				"name": "同名歌", "artistName": "某歌手", "albumName": "专辑" + spec.id,
				"durationInMillis": spec.ms,
				"artwork":          map[string]any{"url": "https://example.invalid/{w}x{h}bb.jpg"},
			},
			"relationships": map[string]any{"syllable-lyrics": map[string]any{"data": []any{
				map[string]any{"attributes": map[string]any{"ttmlLocalizations": appleLocalTTML("", nil)}}}}},
		}}}
		b, _ := json.Marshal(payload)
		if err := os.WriteFile(filepath.Join(dir, "e"+string(rune('a'+i))), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	resetAppleLocalIndex(t, dir)
	r, ok := applemusicLocalLyric("", "某歌手", "同名歌", "", 240)
	if !ok || r.album != "专辑502" {
		t.Fatalf("应挑中时长最接近的那版: ok=%v album=%q", ok, r.album)
	}
}
