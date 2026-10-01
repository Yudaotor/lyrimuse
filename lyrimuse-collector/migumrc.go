package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf16"
)

// ---- 咪咕逐字歌词(MRC) ----
//
// 搜索结果每条带 `mrcurl`(逐字歌词文件直链),文件是十六进制文本:每 16 个十六进制字符是一个
// 64 位整数,整组用 XXTEA(64 位字长、DELTA 0x9E3779B9、9 个固定密钥里按 (p&3)^e 取前 4 个)
// 解密,结果按小端拼回字节、以 UTF-16LE 解码。明文跟 QQ QRC 同一个形状:
//
//	[5309,898]编(5309,249)曲(5558,150)：周(5708,150)…
//
// `[行始,行长]`,词在前、`(词始,词长)` 在后,词始是绝对毫秒 —— 直接交给 qrcToYRC。开头几行是
// `[0,0]` 的标题 / 作词作曲(每个词都是 `(0,0)`),先剥掉。

const miguMRCDelta = int64(0x9E3779B9)

var miguMRCKey = [...]int64{
	27303562373562475,
	18014862372307051,
	22799692160172081,
	34058940340699235,
}

const miguMRCMaxSize = int64(1 << 20)

// miguFetchMRCYRC 下载并解密一份 MRC,转成 YRC。任何一步失败都返回空串,调用方照旧只用逐行歌词。
func miguFetchMRCYRC(ctx context.Context, url string) string {
	url = strings.TrimSpace(url)
	if url == "" {
		return ""
	}
	body, err := miguFetchFile(ctx, url, miguMRCMaxSize)
	if err != nil {
		noteLyricSubFetchFailure(ctx)
		return ""
	}
	mrc, err := miguDecryptMRC(string(body))
	if err != nil {
		return ""
	}
	return miguMRCToYRC(mrc)
}

// miguDecryptMRC 解密 MRC 文件正文(十六进制文本)。
func miguDecryptMRC(hexText string) (string, error) {
	hexText = strings.TrimSpace(hexText)
	n := len(hexText) / 16
	if n < 2 {
		return "", fmt.Errorf("mrc too short")
	}
	v := make([]int64, n)
	for i := range v {
		u, err := strconv.ParseUint(hexText[i*16:i*16+16], 16, 64)
		if err != nil {
			return "", err
		}
		v[i] = int64(u)
	}
	miguXXTEADecrypt(v)
	buf := make([]byte, 8*n)
	for i, x := range v {
		binary.LittleEndian.PutUint64(buf[i*8:], uint64(x))
	}
	units := make([]uint16, len(buf)/2)
	for i := range units {
		units[i] = binary.LittleEndian.Uint16(buf[i*2:])
	}
	return strings.TrimRight(string(utf16.Decode(units)), "\x00"), nil
}

// miguXXTEADecrypt 原地解密。整数运算按 int64 回绕、右移为算术右移 —— 跟咪咕客户端一致,
// 别改成 uint64。
func miguXXTEADecrypt(v []int64) {
	n := len(v)
	rounds := int64(6 + 52/n)
	sum := rounds * miguMRCDelta
	y := v[0]
	for sum != 0 {
		e := (sum >> 2) & 3
		var p int
		for p = n - 1; p > 0; p-- {
			z := v[p-1]
			v[p] -= miguXXTEAMix(sum, y, z, p, e)
			y = v[p]
		}
		z := v[n-1]
		v[0] -= miguXXTEAMix(sum, y, z, 0, e)
		y = v[0]
		sum -= miguMRCDelta
	}
}

func miguXXTEAMix(sum, y, z int64, p int, e int64) int64 {
	return ((z>>5 ^ y<<2) + (y>>3 ^ z<<4)) ^ ((sum ^ y) + (miguMRCKey[(int64(p)&3)^e] ^ z))
}

// miguMRCToYRC 剥掉 `[0,0]` 开头的标题 / 署名行后交给 qrcToYRC。一行逐字都没有时返回空串。
func miguMRCToYRC(mrc string) string {
	mrc = strings.ReplaceAll(strings.ReplaceAll(mrc, "\r\n", "\n"), "\r", "\n")
	var kept []string
	timed := false
	for _, line := range strings.Split(mrc, "\n") {
		m := qrcLineHeadRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		if m[1] == "0" && m[2] == "0" {
			continue
		}
		if !qrcWordTimingRegex.MatchString(line[len(m[0]):]) {
			continue
		}
		timed = true
		kept = append(kept, line)
	}
	if !timed {
		return ""
	}
	return qrcToYRC(strings.Join(kept, "\n"))
}
