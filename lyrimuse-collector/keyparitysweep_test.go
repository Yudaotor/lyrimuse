package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"unicode"
)

// 逐码点跨语言对拍的对照文件。App 侧 lyrimuse-selftest 的 CacheKeyTests「逐码点对拍」读同一份
// 文件、用 Swift 实现重算每个窗口的哈希逐窗比对;两边任何一侧的实现、或 Unicode 数据变了,
// 这里或那里会红。
//
// 收录范围:U+0000–U+3FFFF 与 U+E0000–U+E0FFF 里 Go 的 unicode 表认为已分配的码点(见
// keyParitySweepIncluded)。Go 表里还没有的码点不收:macOS 的 Unicode 版本通常更新,那些字在两边的
// 大小写映射本来就不同,收进来只会是永远对不上的噪音;Go 升级 Unicode 表后范围自动跟着扩大。
//
// 每个码点的记录是 keyParitySweepRecord 的七段输出,记录格式、上下文字符串、窗口划分必须跟
// Swift 侧逐字一致,改一边必须改另一边。重新生成:KEYPARITY_SWEEP_UPDATE=1 go test -run TestKeyParitySweepFixture。
const keyParitySweepFixture = "testdata/keyparity/sweep.txt"

const keyParitySweepWindow = 256

func keyParitySweepIncluded(r rune) bool {
	if r >= 0xD800 && r <= 0xDFFF {
		return false
	}
	if !(r <= 0x3FFFF || (r >= 0xE0000 && r <= 0xE0FFF)) {
		return false
	}
	return unicode.In(r, unicode.L, unicode.M, unicode.N, unicode.P, unicode.S, unicode.Z,
		unicode.Cc, unicode.Cf, unicode.Co)
}

// keyParitySweepRecord 一个码点的七段输出,段之间 0x1F、记录末尾 0x1E。
func keyParitySweepRecord(r rune) []byte {
	u := string(r)
	parts := []string{
		cleanMediaTag(" " + u + "A" + u + u + "B" + u),
		loosenEnrichKey(u + "Ab" + u + "|" + u),
		normEnrichTitle("T" + u + "(" + u + "x" + u + ")" + u),
		normEnrichTitle("T (" + u + "live)"),
		sanitizeLyricsFilename(u + "a|b" + u),
		manualPickCanonicalLyrics(u + "[00:01.00]" + u + "w" + u + "\n[" + u + "]x" + u),
		strings.ToLower(u),
	}
	return []byte(strings.Join(parts, "\x1f") + "\x1e")
}

func keyParitySweepLines() []string {
	var lines []string
	emit := func(start, end rune) {
		for w := start; w <= end; w += keyParitySweepWindow {
			bitmap := make([]byte, keyParitySweepWindow/8)
			h := sha256.New()
			n := 0
			for i := rune(0); i < keyParitySweepWindow; i++ {
				r := w + i
				if !keyParitySweepIncluded(r) {
					continue
				}
				bitmap[i/8] |= 1 << (i % 8)
				h.Write(keyParitySweepRecord(r))
				n++
			}
			if n == 0 {
				continue
			}
			lines = append(lines, fmt.Sprintf("%x %s %x", w, hex.EncodeToString(bitmap), h.Sum(nil)))
		}
	}
	emit(0, 0x3FFFF)
	emit(0xE0000, 0xE0FFF)
	return lines
}

func TestKeyParitySweepFixture(t *testing.T) {
	var b bytes.Buffer
	b.WriteString("# 由 lyrimuse-collector/keyparitysweep_test.go 生成,不要手改。每行:窗口起点(十六进制) 收录位图 七段输出的 SHA-256\n")
	b.WriteString("# unicode " + unicode.Version + "\n")
	for _, l := range keyParitySweepLines() {
		b.WriteString(l + "\n")
	}
	if os.Getenv("KEYPARITY_SWEEP_UPDATE") == "1" {
		if err := os.MkdirAll("testdata/keyparity", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(keyParitySweepFixture, b.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(keyParitySweepFixture)
	if err != nil {
		t.Fatalf("读不到 %s(KEYPARITY_SWEEP_UPDATE=1 生成):%v", keyParitySweepFixture, err)
	}
	if bytes.Equal(want, b.Bytes()) {
		return
	}
	got := strings.Split(b.String(), "\n")
	old := strings.Split(string(want), "\n")
	shown := 0
	for i := 0; i < len(got) || i < len(old); i++ {
		var g, o string
		if i < len(got) {
			g = got[i]
		}
		if i < len(old) {
			o = old[i]
		}
		if g != o && shown < 5 {
			t.Errorf("第 %s 行不一致:\n  文件 %q\n  现算 %q", strconv.Itoa(i+1), o, g)
			shown++
		}
	}
	t.Fatalf("%s 不是最新:实现或 Go 的 Unicode 表变了。确认是有意的改动后 KEYPARITY_SWEEP_UPDATE=1 重新生成,并跑 App 侧 selftest 核对", keyParitySweepFixture)
}
