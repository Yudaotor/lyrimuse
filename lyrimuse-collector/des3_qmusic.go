// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

// 3DES 解密,专供 QQ 音乐 GetPlayLyricInfo 的 QRC 逐字歌词用——Go 标准库 crypto/des 是
// 标准 FIPS-46 DES,实测坐实(见 qq.go 里 decryptQRC 的验证过程)对不上 QQ 音乐这份密文;
// 逐字移植社区已逆向、已用真实歌曲验证解密成功的这份实现(参考
// https://github.com/WXRIW/QQMusicDecoder 的 C# 版本,和 chenmozhijin/LDDC 的 Python
// 移植版),保留全部魔数与位运算顺序,任何"看起来等价"的改写都可能导致不兼容,不要动。

var qmSbox = [8][64]int{
	{14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
		0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
		4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
		15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13},
	{15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
		3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
		0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
		13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9},
	{10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
		13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
		13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
		1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12},
	{7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
		13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
		10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
		3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14},
	{2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
		14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
		4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
		11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3},
	{12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
		10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
		9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
		4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13},
	{4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
		13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
		1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
		6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12},
	{13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
		1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
		7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
		2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11},
}

func qmBitnum(a []byte, b, c uint) uint32 {
	return uint32(((a[(b/32)*4+3-(b%32)/8] >> (7 - b%8)) & 1)) << c
}

func qmBitnumIntr(a uint32, b, c uint) uint32 {
	return ((a >> (31 - b)) & 1) << c
}

func qmBitnumIntl(a uint32, b, c uint) uint32 {
	return ((a << b) & 0x80000000) >> c
}

func qmSboxBit(a int) int {
	return (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4)
}

func qmInitialPermutation(in []byte) (uint32, uint32) {
	s0 := qmBitnum(in, 57, 31) | qmBitnum(in, 49, 30) | qmBitnum(in, 41, 29) | qmBitnum(in, 33, 28) |
		qmBitnum(in, 25, 27) | qmBitnum(in, 17, 26) | qmBitnum(in, 9, 25) | qmBitnum(in, 1, 24) |
		qmBitnum(in, 59, 23) | qmBitnum(in, 51, 22) | qmBitnum(in, 43, 21) | qmBitnum(in, 35, 20) |
		qmBitnum(in, 27, 19) | qmBitnum(in, 19, 18) | qmBitnum(in, 11, 17) | qmBitnum(in, 3, 16) |
		qmBitnum(in, 61, 15) | qmBitnum(in, 53, 14) | qmBitnum(in, 45, 13) | qmBitnum(in, 37, 12) |
		qmBitnum(in, 29, 11) | qmBitnum(in, 21, 10) | qmBitnum(in, 13, 9) | qmBitnum(in, 5, 8) |
		qmBitnum(in, 63, 7) | qmBitnum(in, 55, 6) | qmBitnum(in, 47, 5) | qmBitnum(in, 39, 4) |
		qmBitnum(in, 31, 3) | qmBitnum(in, 23, 2) | qmBitnum(in, 15, 1) | qmBitnum(in, 7, 0)
	s1 := qmBitnum(in, 56, 31) | qmBitnum(in, 48, 30) | qmBitnum(in, 40, 29) | qmBitnum(in, 32, 28) |
		qmBitnum(in, 24, 27) | qmBitnum(in, 16, 26) | qmBitnum(in, 8, 25) | qmBitnum(in, 0, 24) |
		qmBitnum(in, 58, 23) | qmBitnum(in, 50, 22) | qmBitnum(in, 42, 21) | qmBitnum(in, 34, 20) |
		qmBitnum(in, 26, 19) | qmBitnum(in, 18, 18) | qmBitnum(in, 10, 17) | qmBitnum(in, 2, 16) |
		qmBitnum(in, 60, 15) | qmBitnum(in, 52, 14) | qmBitnum(in, 44, 13) | qmBitnum(in, 36, 12) |
		qmBitnum(in, 28, 11) | qmBitnum(in, 20, 10) | qmBitnum(in, 12, 9) | qmBitnum(in, 4, 8) |
		qmBitnum(in, 62, 7) | qmBitnum(in, 54, 6) | qmBitnum(in, 46, 5) | qmBitnum(in, 38, 4) |
		qmBitnum(in, 30, 3) | qmBitnum(in, 22, 2) | qmBitnum(in, 14, 1) | qmBitnum(in, 6, 0)
	return s0, s1
}

func qmInversePermutation(s0, s1 uint32) [8]byte {
	var data [8]byte
	data[3] = byte(qmBitnumIntr(s1, 7, 7) | qmBitnumIntr(s0, 7, 6) | qmBitnumIntr(s1, 15, 5) |
		qmBitnumIntr(s0, 15, 4) | qmBitnumIntr(s1, 23, 3) | qmBitnumIntr(s0, 23, 2) |
		qmBitnumIntr(s1, 31, 1) | qmBitnumIntr(s0, 31, 0))
	data[2] = byte(qmBitnumIntr(s1, 6, 7) | qmBitnumIntr(s0, 6, 6) | qmBitnumIntr(s1, 14, 5) |
		qmBitnumIntr(s0, 14, 4) | qmBitnumIntr(s1, 22, 3) | qmBitnumIntr(s0, 22, 2) |
		qmBitnumIntr(s1, 30, 1) | qmBitnumIntr(s0, 30, 0))
	data[1] = byte(qmBitnumIntr(s1, 5, 7) | qmBitnumIntr(s0, 5, 6) | qmBitnumIntr(s1, 13, 5) |
		qmBitnumIntr(s0, 13, 4) | qmBitnumIntr(s1, 21, 3) | qmBitnumIntr(s0, 21, 2) |
		qmBitnumIntr(s1, 29, 1) | qmBitnumIntr(s0, 29, 0))
	data[0] = byte(qmBitnumIntr(s1, 4, 7) | qmBitnumIntr(s0, 4, 6) | qmBitnumIntr(s1, 12, 5) |
		qmBitnumIntr(s0, 12, 4) | qmBitnumIntr(s1, 20, 3) | qmBitnumIntr(s0, 20, 2) |
		qmBitnumIntr(s1, 28, 1) | qmBitnumIntr(s0, 28, 0))
	data[7] = byte(qmBitnumIntr(s1, 3, 7) | qmBitnumIntr(s0, 3, 6) | qmBitnumIntr(s1, 11, 5) |
		qmBitnumIntr(s0, 11, 4) | qmBitnumIntr(s1, 19, 3) | qmBitnumIntr(s0, 19, 2) |
		qmBitnumIntr(s1, 27, 1) | qmBitnumIntr(s0, 27, 0))
	data[6] = byte(qmBitnumIntr(s1, 2, 7) | qmBitnumIntr(s0, 2, 6) | qmBitnumIntr(s1, 10, 5) |
		qmBitnumIntr(s0, 10, 4) | qmBitnumIntr(s1, 18, 3) | qmBitnumIntr(s0, 18, 2) |
		qmBitnumIntr(s1, 26, 1) | qmBitnumIntr(s0, 26, 0))
	data[5] = byte(qmBitnumIntr(s1, 1, 7) | qmBitnumIntr(s0, 1, 6) | qmBitnumIntr(s1, 9, 5) |
		qmBitnumIntr(s0, 9, 4) | qmBitnumIntr(s1, 17, 3) | qmBitnumIntr(s0, 17, 2) |
		qmBitnumIntr(s1, 25, 1) | qmBitnumIntr(s0, 25, 0))
	data[4] = byte(qmBitnumIntr(s1, 0, 7) | qmBitnumIntr(s0, 0, 6) | qmBitnumIntr(s1, 8, 5) |
		qmBitnumIntr(s0, 8, 4) | qmBitnumIntr(s1, 16, 3) | qmBitnumIntr(s0, 16, 2) |
		qmBitnumIntr(s1, 24, 1) | qmBitnumIntr(s0, 24, 0))
	return data
}

// qmRoundKey is one of the 16 DES round keys: 6 bytes (48 bits), each byte's
// low 6 bits significant — matches the Python schedule[i][j] shape exactly.
type qmRoundKey [6]int

func qmF(state uint32, key qmRoundKey) uint32 {
	t1 := qmBitnumIntl(state, 31, 0) | ((state & 0xf0000000) >> 1) | qmBitnumIntl(state, 4, 5) |
		qmBitnumIntl(state, 3, 6) | ((state & 0x0f000000) >> 3) | qmBitnumIntl(state, 8, 11) |
		qmBitnumIntl(state, 7, 12) | ((state & 0x00f00000) >> 5) | qmBitnumIntl(state, 12, 17) |
		qmBitnumIntl(state, 11, 18) | ((state & 0x000f0000) >> 7) | qmBitnumIntl(state, 16, 23)
	t2 := qmBitnumIntl(state, 15, 0) | ((state & 0x0000f000) << 15) | qmBitnumIntl(state, 20, 5) |
		qmBitnumIntl(state, 19, 6) | ((state & 0x00000f00) << 13) | qmBitnumIntl(state, 24, 11) |
		qmBitnumIntl(state, 23, 12) | ((state & 0x000000f0) << 11) | qmBitnumIntl(state, 28, 17) |
		qmBitnumIntl(state, 27, 18) | ((state & 0x0000000f) << 9) | qmBitnumIntl(state, 0, 23)

	lrgstate := [6]int{
		int((t1 >> 24) & 0xff), int((t1 >> 16) & 0xff), int((t1 >> 8) & 0xff),
		int((t2 >> 24) & 0xff), int((t2 >> 16) & 0xff), int((t2 >> 8) & 0xff),
	}
	for i := 0; i < 6; i++ {
		lrgstate[i] ^= key[i]
	}

	s := (uint32(qmSbox[0][qmSboxBit(lrgstate[0]>>2)]) << 28) |
		(uint32(qmSbox[1][qmSboxBit(((lrgstate[0]&0x03)<<4)|(lrgstate[1]>>4))]) << 24) |
		(uint32(qmSbox[2][qmSboxBit(((lrgstate[1]&0x0f)<<2)|(lrgstate[2]>>6))]) << 20) |
		(uint32(qmSbox[3][qmSboxBit(lrgstate[2]&0x3f)]) << 16) |
		(uint32(qmSbox[4][qmSboxBit(lrgstate[3]>>2)]) << 12) |
		(uint32(qmSbox[5][qmSboxBit(((lrgstate[3]&0x03)<<4)|(lrgstate[4]>>4))]) << 8) |
		(uint32(qmSbox[6][qmSboxBit(((lrgstate[4]&0x0f)<<2)|(lrgstate[5]>>6))]) << 4) |
		uint32(qmSbox[7][qmSboxBit(lrgstate[5]&0x3f)])

	return qmBitnumIntl(s, 15, 0) | qmBitnumIntl(s, 6, 1) | qmBitnumIntl(s, 19, 2) |
		qmBitnumIntl(s, 20, 3) | qmBitnumIntl(s, 28, 4) | qmBitnumIntl(s, 11, 5) |
		qmBitnumIntl(s, 27, 6) | qmBitnumIntl(s, 16, 7) | qmBitnumIntl(s, 0, 8) |
		qmBitnumIntl(s, 14, 9) | qmBitnumIntl(s, 22, 10) | qmBitnumIntl(s, 25, 11) |
		qmBitnumIntl(s, 4, 12) | qmBitnumIntl(s, 17, 13) | qmBitnumIntl(s, 30, 14) |
		qmBitnumIntl(s, 9, 15) | qmBitnumIntl(s, 1, 16) | qmBitnumIntl(s, 7, 17) |
		qmBitnumIntl(s, 23, 18) | qmBitnumIntl(s, 13, 19) | qmBitnumIntl(s, 31, 20) |
		qmBitnumIntl(s, 26, 21) | qmBitnumIntl(s, 2, 22) | qmBitnumIntl(s, 8, 23) |
		qmBitnumIntl(s, 18, 24) | qmBitnumIntl(s, 12, 25) | qmBitnumIntl(s, 29, 26) |
		qmBitnumIntl(s, 5, 27) | qmBitnumIntl(s, 21, 28) | qmBitnumIntl(s, 10, 29) |
		qmBitnumIntl(s, 3, 30) | qmBitnumIntl(s, 24, 31)
}

// qmCrypt runs one single-DES 16-round Feistel pass (encrypt or decrypt is
// determined entirely by the round-key ORDER baked into the schedule, same as
// the Python/C# reference — this function itself doesn't know which).
func qmCrypt(in []byte, key [16]qmRoundKey) [8]byte {
	s0, s1 := qmInitialPermutation(in)
	for idx := 0; idx < 15; idx++ {
		prevS1 := s1
		s1 = qmF(s1, key[idx]) ^ s0
		s0 = prevS1
	}
	s0 = qmF(s1, key[15]) ^ s0
	return qmInversePermutation(s0, s1)
}

const (
	qmEncrypt = 1
	qmDecrypt = 0
)

var (
	qmKeyRndShift    = [16]uint{1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1}
	qmKeyPermC       = [28]uint{56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35}
	qmKeyPermD       = [28]uint{62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3}
	qmKeyCompression = [48]uint{13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36,
		46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31}
)

func qmKeySchedule(key []byte, mode int) [16]qmRoundKey {
	var schedule [16]qmRoundKey
	var c, d uint32
	for i := uint(0); i < 28; i++ {
		c |= qmBitnum(key, qmKeyPermC[i], 31-i)
		d |= qmBitnum(key, qmKeyPermD[i], 31-i)
	}
	for i := 0; i < 16; i++ {
		shift := qmKeyRndShift[i]
		c = ((c << shift) | (c >> (28 - shift))) & 0xfffffff0
		d = ((d << shift) | (d >> (28 - shift))) & 0xfffffff0

		togen := i
		if mode == qmDecrypt {
			togen = 15 - i
		}
		for j := range schedule[togen] {
			schedule[togen][j] = 0
		}
		for j := uint(0); j < 24; j++ {
			schedule[togen][j/8] |= int(qmBitnumIntr(c, qmKeyCompression[j], 7-(j%8)))
		}
		for j := uint(24); j < 48; j++ {
			schedule[togen][j/8] |= int(qmBitnumIntr(d, qmKeyCompression[j]-27, 7-(j%8)))
		}
	}
	return schedule
}

// qm3DESDecrypt implements the EDE3 3DES decrypt this codebase's KRC/QRC
// counterpart implementations use (D(k3)→E(k2)→D(k1)), ECB-style (8-byte
// blocks, no chaining) — matches decryptQRC's caller, which feeds it whole
// multi-block ciphertexts and expects the equivalent plaintext back.
func qm3DESDecrypt(key, data []byte) []byte {
	if len(key) != 24 {
		return nil
	}
	sched := [3][16]qmRoundKey{
		qmKeySchedule(key[16:24], qmDecrypt),
		qmKeySchedule(key[8:16], qmEncrypt),
		qmKeySchedule(key[0:8], qmDecrypt),
	}
	out := make([]byte, len(data))
	for off := 0; off+8 <= len(data); off += 8 {
		block := data[off : off+8]
		for _, s := range sched {
			b := qmCrypt(block, s)
			block = b[:]
		}
		copy(out[off:off+8], block)
	}
	return out
}
