package main

import (
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
)

// LRCGET 前端(npm yaml)的写法:双引号、序列缩进在键下面、超过 80 列的字符串折行、plain 是块标量。
const lyricsfileNpmStyle = `version: "1.0"
metadata:
  title: Shape of You
  artist: Ed Sheeran
  duration_ms: 235000
  instrumental: false
lines:
  - text: The club isn't the best place to find a lover so the bar is where I go, said
      the man
    start_ms: 12450
    end_ms: 18200
    words:
      - text: "The "
        start_ms: 12450
        end_ms: 12900
      - text: "club "
        start_ms: 12900
        end_ms: 13500
      - text: lover
        start_ms: 17100
        end_ms: 18200
  - text: 夜に駆ける
    start_ms: 20000
    end_ms: 22000
    words:
      - text: 夜に
        start_ms: 20000
        end_ms: 21000
      - text: 駆ける
        start_ms: 21000
        end_ms: 22000
  - text: no word timing here
    start_ms: 23000
    end_ms: 24000
    words: []
plain: |-
  The club isn't the best place

  # not a comment, part of the block
  夜に駆ける
`

// 服务端 / LRCGET 后端(serde_yaml)的写法:单引号、序列跟键对齐、最后一个词没给 end_ms。
const lyricsfileSerdeStyle = `version: '1.0'
metadata:
  title: Hello
  artist: Adele
  album: '25'
  duration_ms: 295000
  instrumental: false
lines:
- text: Hello, it's me
  start_ms: 6220
  end_ms: 11840
  words:
  - text: 'Hello, '
    start_ms: 6220
    end_ms: 7000
  - text: 'it''s '
    start_ms: 7000
    end_ms: 7400
  - text: me
    start_ms: 7400
- text: ''
  start_ms: 11840
  end_ms:
`

func TestLyricsfileWordsToYRC(t *testing.T) {
	for _, c := range []struct {
		name, doc, want string
	}{
		{"npm yaml", lyricsfileNpmStyle,
			"[12450,5750](12450,450,0)The (12900,600,0)club (17100,1100,0)lover\n[20000,2000](20000,1000,0)夜に(21000,1000,0)駆ける"},
		{"serde_yaml", lyricsfileSerdeStyle,
			"[6220,5620](6220,780,0)Hello, (7000,400,0)it's (7400,4440,0)me"},
	} {
		if got := lyricsfileWordsToYRC(c.doc); got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, c.want)
		}
	}
}

func TestLyricsfileWordsToYRCRejects(t *testing.T) {
	withOffset := strings.Replace(lyricsfileSerdeStyle, "  instrumental: false\n", "  instrumental: false\n  offset_ms: -200\n", 1)
	if got, want := lyricsfileWordsToYRC(withOffset), lyricsfileWordsToYRC(lyricsfileSerdeStyle); got != want || got == "" {
		t.Errorf("offset_ms 不改逐字的时间(跟逐行轨一样用原始时间): %q vs %q", got, want)
	}
	disordered := strings.Replace(lyricsfileSerdeStyle, "    start_ms: 7400\n", "    start_ms: 6000\n", 1)
	for name, doc := range map[string]string{
		"没有逐字":         "version: '1.0'\nmetadata:\n  title: Hello\nlines:\n- text: Hello\n  start_ms: 1\n  end_ms: 2\n",
		"lines 为 null": "version: \"1.0\"\nmetadata:\n  title: x\nlines: null\nplain: |-\n  a\n  b\n",
		"非空流式集合":       "version: '1.0'\nlines:\n- text: a\n  start_ms: 1\n  words: [{text: a, start_ms: 1}]\n",
		"锚点":           "version: '1.0'\nlines: &l\n- text: a\n",
		"tab 缩进":       "version: '1.0'\nlines:\n\t- text: a\n",
		"词的顺序乱了":       disordered,
		"不是 YAML":      "<html>oops</html>",
		"空":            "",
	} {
		if got := lyricsfileWordsToYRC(doc); got != "" {
			t.Errorf("%s: 应当放弃,得到 %q", name, got)
		}
	}
}

func TestParseLyricsfileYAMLScalars(t *testing.T) {
	doc := "a: plain value # comment\n" +
		"b: 'single ''quoted'' # not comment'\n" +
		"c: \"double \\\"q\\\" \\u00e9 \\n x\"\n" +
		"d: \"folded\n  across lines\"\n" +
		"e: ~\n" +
		"f:\n" +
		"g: []\n" +
		"h: >-\n  one\n  two\n" +
		"\"quoted key\": 1\n"
	v, ok := parseLyricsfileYAML(doc)
	m, _ := v.(map[string]any)
	if !ok || m == nil {
		t.Fatalf("应能解析: %v", v)
	}
	want := map[string]any{"a": "plain value", "b": "single 'quoted' # not comment", "c": "double \"q\" é \n x",
		"d": "folded across lines", "h": "one two", "quoted key": "1"}
	for k, w := range want {
		if m[k] != w {
			t.Errorf("%s = %#v, want %#v", k, m[k], w)
		}
	}
	for _, k := range []string{"e", "f"} {
		if v, present := m[k]; !present || v != nil {
			t.Errorf("%s 应为 null,实际 %#v(present=%v)", k, v, present)
		}
	}
	if g, _ := m["g"].([]any); g == nil || len(g) != 0 {
		t.Errorf("g 应为空序列,实际 %#v", m["g"])
	}
}

// 带逐字的条目:get 拿到的结果里有 yrc;服务端没标 hasWordSync、文档里也没 words 的不解析。
func TestLRCLIBGetCarriesWordTiming(t *testing.T) {
	item := func(hasWS bool, doc string) string {
		ws := "false"
		if hasWS {
			ws = "true"
		}
		return `{"trackName":"Hello","artistName":"Adele","duration":295,"syncedLyrics":"[00:06.22]Hello, it's me\n[00:11.84]\n[00:12.00]a\n[00:13.00]b",` +
			`"hasWordSync":` + ws + `,"lyricsfile":` + jsonString(doc) + `}`
	}
	var body string
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) { return http.StatusOK, nil, body })
	body = item(true, lyricsfileSerdeStyle)
	if r := resolveLRCLIBLyric(qqRoundCtx(), "Adele", "Hello", "", 295); !strings.HasPrefix(r.yrc, "[6220,5620](6220,780,0)Hello, ") {
		t.Fatalf("应带上逐字: %q", r.yrc)
	}
	lrclibMu.Lock()
	lrclibCache = map[string]lrclibResult{}
	lrclibMu.Unlock()
	body = item(false, "version: '1.0'\nlines:\n- text: Hello\n  start_ms: 6220\n")
	if r := resolveLRCLIBLyric(qqRoundCtx(), "Adele", "Hello", "", 295); r.lyrics == "" || r.yrc != "" {
		t.Fatalf("没有逐字的条目只出逐行: lyrics=%q yrc=%q", r.lyrics, r.yrc)
	}
}

func jsonString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// LRCLIB 的逐字从源结果一路带进候选:打分结果里有逐字轨、标成有逐字。
func TestRankCarriesLRCLIBWordTiming(t *testing.T) {
	var lrc, yrc strings.Builder
	for i := 0; i < 12; i++ {
		ms := 10000 + i*4000
		lrc.WriteString(formatLRCTime(ms) + "Line number " + string(rune('A'+i)) + " goes here\n")
		yrc.WriteString("[" + strconv.Itoa(ms) + ",3000](" + strconv.Itoa(ms) + ",3000,0)Line number " + string(rune('A'+i)) + " goes here\n")
	}
	raw := map[string]lyricSourceResult{
		"lrclib": {source: "lrclib", lyr: lrc.String(), yrc: strings.TrimSuffix(yrc.String(), "\n"), srcDur: 60},
	}
	scored := rankLyricSourceResults("someone", "song", "", 60, raw)
	if len(scored) == 0 || scored[0].Source != "lrclib" || !scored[0].HasWordTiming || scored[0].LyricsYRC == "" {
		t.Fatalf("lrclib 候选应带上逐字: %+v", scored)
	}
}

// 照菅原圭《back shot》那份(LRCGET 前端写法)造:音译声明、整行注音、逐字注音。
const lyricsfileTranslitDoc = `version: "1.0"
metadata:
  title: back shot
  artist: 菅原圭
  language: ja
  transliterations:
    - id: hira
      system: ja-Hrkt
    - id: romaji
      system: ja-Latn
lines:
  - text: 止め処ない夜に
    words:
      - text: 止
        start_ms: 1740
        end_ms: 2000
        transliteration:
          hira: と
          romaji: to
      - text: め
        start_ms: 2000
        end_ms: 2291
        transliteration:
          romaji: me
      - text: 処
        start_ms: 2291
        end_ms: 2501
        transliteration:
          hira: ど
          romaji: do
      - text: ない
        start_ms: 2501
        end_ms: 2900
        transliteration:
          romaji: nai
      - text: 夜
        start_ms: 2900
        end_ms: 3400
        transliteration:
          hira: よる
          romaji: yoru
      - text: に
        start_ms: 3400
        end_ms: 3600
        transliteration:
          romaji: ni
    transliteration:
      hira: とめどないよるに
      romaji: tomedonai yoru ni
    start_ms: 1740
    end_ms: 3600
  - text: 教えてyour back shot
    words:
      - text: 教え
        start_ms: 5900
        end_ms: 6400
        transliteration:
          hira: おしえ
          romaji: oshie
      - text: て
        start_ms: 6400
        end_ms: 6600
        transliteration:
          romaji: te
      - text: "your "
        start_ms: 6600
        end_ms: 6900
      - text: "back "
        start_ms: 6900
        end_ms: 7200
      - text: shot
        start_ms: 7200
        end_ms: 7600
    start_ms: 5900
    end_ms: 7600
  - text: 見つめ引き返す
    words:
      - text: 見つめ
        start_ms: 8000
        end_ms: 8600
        transliteration:
          hira: ミツメ
      - text: 引き返す
        start_ms: 8600
        end_ms: 9400
        transliteration:
          hira: ひきかえす
    start_ms: 8000
    end_ms: 9400
`

const lyricsfileTranslitSynced = "[00:01.74]止め処ない夜に\n[00:05.90]教えてyour back shot\n[00:08.00]見つめ引き返す\n[00:10.00]逐字里没有的一行\n[00:12.00]"

func TestLyricsfileRomaAndKana(t *testing.T) {
	ex := lyricsfileExtrasFrom(lyricsfileTranslitDoc, lyricsfileTranslitSynced)
	wantRoma := "[00:01.74]tomedonai yoru ni\n[00:05.90]oshie te your back shot"
	if ex.roma != wantRoma {
		t.Errorf("roma:\n got %q\nwant %q", ex.roma, wantRoma)
	}
	// 止→と、処→ど、夜→よる;教え 去掉送假名只标「おし」;見つめ 片假名读音转平假名、去掉「つめ」;
	// 引き返す 两段汉字被假名隔开,逐字空条目(2 个);最后一行 lyricsfile 里没有,它的 8 个汉字全空条目。
	wantKana := "[kana:1と1ど1よる1おし1み1111111111]"
	if ex.kana != wantKana {
		t.Errorf("kana:\n got %q\nwant %q", ex.kana, wantKana)
	}
	need := 0
	for _, body := range kanaBodyLines(lyricsfileTranslitSynced) {
		for _, r := range body {
			if kanaNeedsAnnotation(r) {
				need++
			}
		}
	}
	covered := 0
	for _, r := range strings.TrimSuffix(strings.TrimPrefix(ex.kana, "[kana:"), "]") {
		if r >= '1' && r <= '9' {
			covered += int(r - '0')
		}
	}
	if covered != need {
		t.Errorf("条目覆盖 %d 个字,正文待标字 %d 个 —— App 那边对不上会整份弃用", covered, need)
	}
}

func TestKanaEntryFor(t *testing.T) {
	for _, c := range []struct {
		text, reading, want string
		n                   int
		clean               bool
	}{
		{"教え", "おしえ", "おし", 1, true},  // 读音带送假名:去掉
		{"失っ", "うしな", "うしな", 1, true}, // 只注了汉字:原样
		{"お茶", "おちゃ", "ちゃ", 1, true},  // 头上的假名同样去掉
		{"見つめ", "ミツメ", "み", 1, true},  // 片假名读音转平假名
		{"秘密", "ひみつ", "ひみつ", 2, true},
		{"夜", "", "", 1, true},
		{"引き返す", "ひきかえす", "", 2, false}, // 汉字被假名隔开,拆不出
		{"つ", "つ", "", 0, true},
		{"夜", "yoru", "", 1, false},
	} {
		n, got, clean := kanaEntryFor(c.text, c.reading)
		if n != c.n || got != c.want || clean != c.clean {
			t.Errorf("kanaEntryFor(%q, %q) = %d, %q, %v; want %d, %q, %v", c.text, c.reading, n, got, clean, c.n, c.want, c.clean)
		}
	}
}

func TestLyricsfileTransliterationIDs(t *testing.T) {
	declared := map[string]any{"transliterations": []any{
		map[string]any{"id": "kana", "system": "ja-Hira"}, map[string]any{"id": "latin", "system": "ja-Latn"}}}
	if roma, kana := lyricsfileTransliterationIDs(declared); roma != "latin" || kana != "kana" {
		t.Errorf("按声明的系统认: roma=%q kana=%q", roma, kana)
	}
	if roma, kana := lyricsfileTransliterationIDs(map[string]any{}); roma != "romaji" || kana != "hira" {
		t.Errorf("没声明时用 LRCGET 的默认 id: roma=%q kana=%q", roma, kana)
	}
	pinyinOnly := map[string]any{"transliterations": []any{map[string]any{"id": "py", "system": "zh-Latn"}}}
	if roma, kana := lyricsfileTransliterationIDs(pinyinOnly); roma != "py" || kana != "" {
		t.Errorf("只有拼音时没有假名读音: roma=%q kana=%q", roma, kana)
	}
}

// 没有假名读音可用时不出 [kana:] 行。
func TestLyricsfileKanaRequiresReadings(t *testing.T) {
	doc := strings.ReplaceAll(lyricsfileTranslitDoc, "hira:", "other:")
	if k := lyricsfileExtrasFrom(doc, lyricsfileTranslitSynced).kana; k != "" {
		t.Errorf("没有读音时不该出标注: %q", k)
	}
}

// 带音译的条目:结果里有逐行罗马音,正文前面拼了 [kana:] 行(正文本身不动)。
func TestLRCLIBCarriesRomanizationAndKana(t *testing.T) {
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		return http.StatusOK, nil, `{"trackName":"back shot","artistName":"菅原圭","duration":12,"syncedLyrics":` + jsonString(lyricsfileTranslitSynced) +
			`,"hasWordSync":true,"lyricsfile":` + jsonString(lyricsfileTranslitDoc) + `}`
	})
	r := resolveLRCLIBLyric(qqRoundCtx(), "菅原圭", "back shot", "", 12)
	if !strings.HasPrefix(r.roma, "[00:01.74]tomedonai yoru ni\n") {
		t.Errorf("应带上逐行罗马音: %q", r.roma)
	}
	if want := "[kana:1と1ど1よる1おし1み1111111111]\n" + lyricsfileTranslitSynced; r.lyrics != want {
		t.Errorf("正文前面应拼上 [kana:] 行:\n got %q\nwant %q", r.lyrics, want)
	}
}

// LRCLIB 胜出时它的罗马音进结果。
func TestRankCarriesLRCLIBRomanization(t *testing.T) {
	var lrc, roma strings.Builder
	for i := 0; i < 12; i++ {
		ms := 10000 + i*4000
		lrc.WriteString(formatLRCTime(ms) + "夜に駆ける君の手を" + strconv.Itoa(i) + "\n")
		roma.WriteString(formatLRCTime(ms) + "yoru ni kakeru kimi no te wo " + strconv.Itoa(i) + "\n")
	}
	raw := map[string]lyricSourceResult{
		"lrclib": {source: "lrclib", lyr: lrc.String(), roma: strings.TrimSuffix(roma.String(), "\n"), srcDur: 60},
	}
	scored := rankLyricSourceResults("someone", "song", "", 60, raw)
	if len(scored) == 0 || scored[0].Source != "lrclib" || !strings.HasPrefix(scored[0].LyricsRoma, "[00:10.00]yoru ni kakeru") {
		t.Fatalf("lrclib 的罗马音应进结果: %+v", scored)
	}
}

// Go 侧拼 [kana:] 用的待标字与正文行判定,跟 App 的 KanaAnnotation 必须一致:对不齐时 App 整份弃用、不报错。
func TestKanaAnnotationMirrorsSwift(t *testing.T) {
	src, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Lyrics/KanaAnnotation.swift")
	if err != nil {
		t.Fatal(err)
	}
	for _, lit := range []string{"0x4E00", "0x9FFF", "0x3400", "0x4DBF", `c == "々"`, `pattern: #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#`} {
		if !strings.Contains(string(src), lit) {
			t.Errorf("KanaAnnotation.swift 里找不到 %s —— 两边的判定改过,lyricsfile.go 的 kanaNeedsAnnotation / kanaBodyLines 要同步", lit)
		}
	}
	if kanaLRCTimeTag.String() != `\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]` {
		t.Errorf("kanaLRCTimeTag = %s,跟 Swift 的 lrcTimeTag 不一致", kanaLRCTimeTag)
	}
}

// lyricsfileWordsToYRC 只取逐字 YRC。没有逐字、解析不了时返回空串。
func lyricsfileWordsToYRC(doc string) string {
	return lyricsfileExtrasFrom(doc, "").yrc
}
