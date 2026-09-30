package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ---- 酷我逐字歌词(lrcx) ----
//
// 逐行歌词走网页端 `openapi/v1/www/lyric/getlyric`(见 kuwo.go);逐字另走客户端接口
// `mlyric.kuwo.cn/mobi.s?type=lyric&lrcx=1`,同一个 musicId,两个接口的行时间戳一致。
//
// 响应体:`tp=content…` 头,空行之后是 zlib 压缩的 base64 文本,解开后逐字节与固定密钥
// `yeelion` 异或,得到 UTF-8 正文。正文形如:
//
//	[kuwo:071]
//	[00:19.205]<1183,-1183>I <2231,-541>never …
//	[00:27.326]<0,0>我<0,0>从<0,0>未…            ← 上一句的中文译文,挂在下一句原文的时间戳上
//	[00:27.326]<1113,-1113>I <1915,-325>never …
//
// 每个 `<a,b>` 不是明文时间:`[kuwo:NNN]` 的 NNN 按八进制读出 v,k1 = v/10、k2 = v%10,
// 词起点 = |a+b| / (2·k1)、词长 = |a−b| / (2·k2),都是相对行首的毫秒(kuwoLrcxWordTiming)。
// 词都在标记**之后**(跟 QQ QRC 相反)。
//
// 译文行和空占位行的所有标记都是 `<0,0>`,转换时整行丢掉,只留原文。**别把这份逐字轨交给
// adoptBakedTranslation**:它按行起始时间 ±80ms 删掉被摘出的译文行,而酷我的译文行跟下一句
// 原文同一个时间戳,原文那行会被一起删掉。

const kuwoLrcxKey = "yeelion"

var (
	kuwoLrcxBases       = []string{"https://mlyric.kuwo.cn", "http://mlyric.kuwo.cn"}
	kuwoLrcxHeaderRe    = regexp.MustCompile(`^\[kuwo:(\d+)`)
	kuwoLrcxLineRe      = regexp.MustCompile(`^\[(\d{1,3}):(\d{2})\.(\d{1,3})\](.*)$`)
	kuwoLrcxWordTimeRe  = regexp.MustCompile(`<(-?\d+),(-?\d+)(?:,-?\d+)?>`)
	kuwoLrcxBodyMaxSize = int64(512 << 10)
)

// kuwoFetchLrcxYRC 拉一首歌的逐字歌词并转成 YRC。拿不到、解不开、没有逐字都返回空串:
// 调用方照旧只用逐行歌词,不算错误。
func kuwoFetchLrcxYRC(ctx context.Context, musicID string) string {
	if musicID == "" {
		return ""
	}
	var yrc string
	reached := false
	_ = tryEach(ctx, kuwoLrcxBases, func(base string) error {
		raw, err := kuwoFetchLrcxAt(ctx, base, musicID)
		if err != nil {
			return err
		}
		reached = true
		text, err := kuwoDecodeLrcx(raw)
		if err != nil {
			return err
		}
		yrc = kuwoLrcxToYRC(text)
		return nil
	})
	// 一个主机都没问成:这份结果缺了逐字,不能缓存(见 lyricsubfetch.go)。问成了、解不开的是这首没有 lrcx。
	if !reached {
		noteLyricSubFetchFailure(ctx)
	}
	return yrc
}

func kuwoFetchLrcxAt(ctx context.Context, base, musicID string) ([]byte, error) {
	return kuwoFetchMobiLyricAt(ctx, base, musicID, "1")
}

// kuwoFetchMobiLRC 拉 mlyric 的 lrcx=0:同一个接口不带逐字的那一档,响应体的封装与 lrcx=1 相同(kuwoDecodeLrcx),
// 解开是标准逐行 LRC,跟网页端 getlyric 同一份、同样的时间戳与烘入译文。给 kuwoFetchLyric 在网页端几个主机都没问成时兜底。
func kuwoFetchMobiLRC(ctx context.Context, musicID string) (string, error) {
	var lrc string
	err := tryEach(ctx, kuwoLrcxBases, func(base string) error {
		raw, err := kuwoFetchMobiLyricAt(ctx, base, musicID, "0")
		if err != nil {
			return err
		}
		text, err := kuwoDecodeLrcx(raw)
		if err != nil {
			return err
		}
		lrc = text
		return nil
	})
	return lrc, err
}

func kuwoFetchMobiLyricAt(ctx context.Context, base, musicID, lrcx string) ([]byte, error) {
	u := base + "/mobi.s?f=web&type=lyric&lrcx=" + lrcx + "&encode=utf8&rid=" + neturl.QueryEscape(musicID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, kuwoLrcxBodyMaxSize))
}

// kuwoDecodeLrcx 解开 mlyric 响应体(lrcx=0 / 1 同一种封装):去掉 `tp=content` 头 → zlib → base64 → 与 `yeelion` 逐字节异或。
func kuwoDecodeLrcx(raw []byte) (string, error) {
	if len(raw) < 10 || !strings.EqualFold(string(raw[:10]), "tp=content") {
		return "", fmt.Errorf("unexpected lrcx header")
	}
	sep := bytes.Index(raw, []byte("\r\n\r\n"))
	if sep < 0 {
		return "", fmt.Errorf("lrcx body separator missing")
	}
	zr, err := zlib.NewReader(bytes.NewReader(raw[sep+4:]))
	if err != nil {
		return "", err
	}
	defer zr.Close()
	b64, err := io.ReadAll(io.LimitReader(zr, 4*kuwoLrcxBodyMaxSize))
	if err != nil {
		return "", err
	}
	data, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b64)))
	if err != nil {
		return "", err
	}
	key := []byte(kuwoLrcxKey)
	for i := range data {
		data[i] ^= key[i%len(key)]
	}
	return string(data), nil
}

// kuwoLrcxCoefficients 从 `[kuwo:NNN]` 读出两个系数。NNN 是八进制;任一系数为 0 时无法换算,
// 返回 ok=false。
func kuwoLrcxCoefficients(text string) (k1, k2 int, ok bool) {
	for _, line := range strings.Split(text, "\n") {
		m := kuwoLrcxHeaderRe.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil {
			continue
		}
		v, err := strconv.ParseInt(m[1], 8, 64)
		if err != nil {
			return 0, 0, false
		}
		k1, k2 = int(v/10), int(v%10)
		return k1, k2, k1 != 0 && k2 != 0
	}
	return 0, 0, false
}

// kuwoLrcxWordTiming 把一个 `<a,b>` 换算成相对行首的起点和终点(毫秒)。
func kuwoLrcxWordTiming(a, b, k1, k2 int) (start, end int) {
	start = absInt(a+b) / (2 * k1)
	end = absInt(a-b)/(2*k2) + start
	return start, end
}

func absInt(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// kuwoLrcxToYRC 把解开后的 lrcx 正文转成 YRC:`[行始,行长](词始,词长,0)词…`,词始为绝对毫秒。
// 丢掉所有标记都是 `<0,0>` 的行(译文行、空占位行)和没有文字的行。后一个词的起点早于前一个词的
// 终点时,把前一个词截到后一个词的起点(同酷我客户端的处理)。没有系数或一行逐字都没有时返回空串。
func kuwoLrcxToYRC(text string) string {
	k1, k2, ok := kuwoLrcxCoefficients(text)
	if !ok {
		return ""
	}
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	type word struct {
		start, end int
		text       string
	}
	var out []string
	for _, line := range strings.Split(text, "\n") {
		m := kuwoLrcxLineRe.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil {
			continue
		}
		mm, _ := strconv.Atoi(m[1])
		ss, _ := strconv.Atoi(m[2])
		frac, _ := strconv.Atoi(m[3])
		if len(m[3]) == 2 {
			frac *= 10
		} else if len(m[3]) == 1 {
			frac *= 100
		}
		lineStart := (mm*60+ss)*1000 + frac
		body := m[4]
		locs := kuwoLrcxWordTimeRe.FindAllStringSubmatchIndex(body, -1)
		if len(locs) == 0 {
			continue
		}
		words := make([]word, 0, len(locs))
		allZero := true
		for i, loc := range locs {
			a, _ := strconv.Atoi(body[loc[2]:loc[3]])
			b, _ := strconv.Atoi(body[loc[4]:loc[5]])
			if a != 0 || b != 0 {
				allZero = false
			}
			textEnd := len(body)
			if i+1 < len(locs) {
				textEnd = locs[i+1][0]
			}
			start, end := kuwoLrcxWordTiming(a, b, k1, k2)
			if n := len(words); n > 0 && start < words[n-1].end {
				words[n-1].end = start
				if words[n-1].start > words[n-1].end {
					words[n-1].start = words[n-1].end
				}
			}
			words = append(words, word{start: start, end: end, text: body[loc[1]:textEnd]})
		}
		if allZero {
			continue
		}
		var hasText bool
		lineEnd := 0
		for _, w := range words {
			if strings.TrimSpace(w.text) != "" {
				hasText = true
			}
			if w.end > lineEnd {
				lineEnd = w.end
			}
		}
		if !hasText {
			continue
		}
		var b strings.Builder
		fmt.Fprintf(&b, "[%d,%d]", lineStart, lineEnd)
		for _, w := range words {
			fmt.Fprintf(&b, "(%d,%d,0)%s", lineStart+w.start, w.end-w.start, w.text)
		}
		out = append(out, b.String())
	}
	if len(out) == 0 {
		return ""
	}
	merged, _ := yrcMergeWhitespaceTokens(strings.Join(out, "\n"))
	return merged
}
