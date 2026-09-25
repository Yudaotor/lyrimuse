package main

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// ---- 测试里现造 LevelDB 文件(只造读取器要认的那部分格式)----

type testLDBEntry struct {
	key     string
	seq     uint64
	value   string
	deleted bool
}

func testInternalKey(e testLDBEntry) []byte {
	typ := uint64(1)
	if e.deleted {
		typ = 0
	}
	tag := make([]byte, 8)
	binary.LittleEndian.PutUint64(tag, e.seq<<8|typ)
	return append([]byte(e.key), tag...)
}

// testBuildBlock 按 LevelDB 块格式编码(每条都当 restart 点,不做前缀共享 —— 读取器两种都得认,
// 前缀共享那一支由 testBuildSharedBlock 覆盖)。
func testBuildBlock(keys, values [][]byte, share bool) []byte {
	var b bytes.Buffer
	var restarts []uint32
	var prev []byte
	for i := range keys {
		shared := 0
		if share && i > 0 {
			for shared < len(prev) && shared < len(keys[i]) && prev[shared] == keys[i][shared] {
				shared++
			}
		} else {
			restarts = append(restarts, uint32(b.Len()))
		}
		b.Write(binary.AppendUvarint(nil, uint64(shared)))
		b.Write(binary.AppendUvarint(nil, uint64(len(keys[i])-shared)))
		b.Write(binary.AppendUvarint(nil, uint64(len(values[i]))))
		b.Write(keys[i][shared:])
		b.Write(values[i])
		prev = keys[i]
	}
	if len(restarts) == 0 {
		restarts = []uint32{0}
	}
	for _, r := range restarts {
		_ = binary.Write(&b, binary.LittleEndian, r)
	}
	_ = binary.Write(&b, binary.LittleEndian, uint32(len(restarts)))
	return b.Bytes()
}

// testSnappyLiteral 把一段字节编码成「全是 literal」的 Snappy 流 —— 合法的 Snappy,足够让读取器走一遍
// 解压那一支。copy 元素的解码由 TestSnappyDecodeCopies 单独钉。
func testSnappyLiteral(src []byte) []byte {
	out := binary.AppendUvarint(nil, uint64(len(src)))
	for len(src) > 0 {
		n := len(src)
		if n > 60 {
			n = 60
		}
		out = append(out, byte((n-1)<<2))
		out = append(out, src[:n]...)
		src = src[n:]
	}
	return out
}

// testWriteTable 写一个 SSTable:entries 按 internal key 排序后,每 perBlock 条一个数据块。
func testWriteTable(t *testing.T, path string, entries []testLDBEntry, perBlock int, compress bool) {
	t.Helper()
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].key != entries[j].key {
			return entries[i].key < entries[j].key
		}
		return entries[i].seq > entries[j].seq // 同一个 user key 新版本在前
	})
	var file bytes.Buffer
	writeBlock := func(content []byte) (off, size uint64) {
		off = uint64(file.Len())
		typ := byte(0)
		if compress {
			content = testSnappyLiteral(content)
			typ = 1
		}
		file.Write(content)
		file.WriteByte(typ)
		file.Write([]byte{0, 0, 0, 0}) // CRC:读取器不校验
		return off, uint64(len(content))
	}
	var idxKeys, idxVals [][]byte
	for i := 0; i < len(entries); i += perBlock {
		end := i + perBlock
		if end > len(entries) {
			end = len(entries)
		}
		var ks, vs [][]byte
		for _, e := range entries[i:end] {
			ks = append(ks, testInternalKey(e))
			vs = append(vs, []byte(e.value))
		}
		off, size := writeBlock(testBuildBlock(ks, vs, true))
		idxKeys = append(idxKeys, ks[len(ks)-1]) // 分隔 key 直接用块里最后一个 key
		idxVals = append(idxVals, append(binary.AppendUvarint(nil, off), binary.AppendUvarint(nil, size)...))
	}
	metaOff, metaSize := writeBlock(testBuildBlock(nil, nil, false))
	idxOff, idxSize := writeBlock(testBuildBlock(idxKeys, idxVals, false))
	footer := make([]byte, 0, 48)
	footer = binary.AppendUvarint(footer, metaOff)
	footer = binary.AppendUvarint(footer, metaSize)
	footer = binary.AppendUvarint(footer, idxOff)
	footer = binary.AppendUvarint(footer, idxSize)
	footer = append(footer, make([]byte, 40-len(footer))...)
	footer = binary.LittleEndian.AppendUint64(footer, 0xdb4775248b80fb57)
	file.Write(footer)
	if err := os.WriteFile(path, file.Bytes(), 0o644); err != nil {
		t.Fatalf("写 SSTable: %v", err)
	}
}

// testWriteLog 写一个写前日志,每个 batch 一条 FULL 记录。
func testWriteLog(t *testing.T, path string, batches [][]testLDBEntry) {
	t.Helper()
	var file bytes.Buffer
	for _, batch := range batches {
		var b bytes.Buffer
		_ = binary.Write(&b, binary.LittleEndian, batch[0].seq)
		_ = binary.Write(&b, binary.LittleEndian, uint32(len(batch)))
		for _, e := range batch {
			if e.deleted {
				b.WriteByte(0)
				b.Write(binary.AppendUvarint(nil, uint64(len(e.key))))
				b.WriteString(e.key)
				continue
			}
			b.WriteByte(1)
			b.Write(binary.AppendUvarint(nil, uint64(len(e.key))))
			b.WriteString(e.key)
			b.Write(binary.AppendUvarint(nil, uint64(len(e.value))))
			b.WriteString(e.value)
		}
		hdr := make([]byte, 7)
		binary.LittleEndian.PutUint16(hdr[4:], uint16(b.Len()))
		hdr[6] = 1
		file.Write(hdr)
		file.Write(b.Bytes())
	}
	if err := os.WriteFile(path, file.Bytes(), 0o644); err != nil {
		t.Fatalf("写 .log: %v", err)
	}
}

// ---- 测试 ----

func TestLDBGetAcrossBlocksAndCompression(t *testing.T) {
	for _, compress := range []bool{false, true} {
		dir := t.TempDir()
		var entries []testLDBEntry
		for i := 0; i < 40; i++ {
			entries = append(entries, testLDBEntry{key: "k" + string(rune('a'+i%26)) + string(rune('0'+i/26)), seq: uint64(i + 1), value: "v" + string(rune('A'+i%26))})
		}
		testWriteTable(t, filepath.Join(dir, "000001.ldb"), entries, 7, compress)
		got := ldbGet(dir, [][]byte{[]byte("ka0"), []byte("kn0"), []byte("kz0"), []byte("kb1"), []byte("nope")})
		want := map[string]string{"ka0": "vA", "kn0": "vN", "kz0": "vZ", "kb1": "vB"}
		if len(got) != len(want) {
			t.Fatalf("compress=%v: 取到 %d 条,期望 %d: %q", compress, len(got), len(want), got)
		}
		for k, v := range want {
			if string(got[k]) != v {
				t.Errorf("compress=%v: %s = %q, 期望 %q", compress, k, got[k], v)
			}
		}
	}
}

// 同一个 key 散在 .ldb 和 .log 里:按 sequence 取最新;最新的是删除标记就当不存在。
func TestLDBGetNewestVersionWinsAndDeletesHide(t *testing.T) {
	dir := t.TempDir()
	testWriteTable(t, filepath.Join(dir, "000005.ldb"), []testLDBEntry{
		{key: "a", seq: 10, value: "旧"},
		{key: "b", seq: 11, value: "会被删"},
		{key: "c", seq: 12, value: "只在表里"},
	}, 2, false)
	// 一个已经被合并掉、还没来得及删的旧文件:里面同一个 key 的 sequence 更小,不该盖掉新值。
	testWriteTable(t, filepath.Join(dir, "000003.ldb"), []testLDBEntry{{key: "c", seq: 2, value: "更旧的残留"}}, 4, true)
	testWriteLog(t, filepath.Join(dir, "000009.log"), [][]testLDBEntry{
		{{key: "a", seq: 20, value: "新"}},
		{{key: "b", seq: 21, deleted: true}},
	})
	got := ldbGet(dir, [][]byte{[]byte("a"), []byte("b"), []byte("c")})
	if string(got["a"]) != "新" {
		t.Errorf("a = %q,期望 .log 里 sequence 更大的「新」", got["a"])
	}
	if _, ok := got["b"]; ok {
		t.Errorf("b 最新一版是删除标记,不该返回值: %q", got["b"])
	}
	if string(got["c"]) != "只在表里" {
		t.Errorf("c = %q", got["c"])
	}
}

// 同一个 user key 的新旧两版恰好跨了数据块边界:读取器要接着看下一块。
func TestLDBGetVersionsSpanningBlocks(t *testing.T) {
	dir := t.TempDir()
	testWriteTable(t, filepath.Join(dir, "000001.ldb"), []testLDBEntry{
		{key: "a", seq: 1, value: "a"},
		{key: "x", seq: 9, value: "新版"},
		{key: "x", seq: 3, value: "旧版"},
		{key: "z", seq: 2, value: "z"},
	}, 2, false) // 块一:a, x@9;块二:x@3, z
	if got := ldbGet(dir, [][]byte{[]byte("x")}); string(got["x"]) != "新版" {
		t.Errorf("x = %q,期望「新版」", got["x"])
	}
}

// 坏文件(被截断 / 不是 SSTable)跳过,不影响其它文件,也不 panic。
func TestLDBGetSkipsBrokenFiles(t *testing.T) {
	dir := t.TempDir()
	testWriteTable(t, filepath.Join(dir, "000001.ldb"), []testLDBEntry{{key: "ok", seq: 1, value: "好"}}, 4, false)
	_ = os.WriteFile(filepath.Join(dir, "000002.ldb"), []byte("这不是一个 SSTable"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "000003.log"), []byte{1, 2, 3, 4, 0xff, 0xff, 1}, 0o644)
	if got := ldbGet(dir, [][]byte{[]byte("ok")}); string(got["ok"]) != "好" {
		t.Errorf("坏文件不该连累好文件: %q", got)
	}
	if got := ldbGet(filepath.Join(dir, "no-such-dir"), [][]byte{[]byte("ok")}); len(got) != 0 {
		t.Errorf("目录不存在该返回空")
	}
}

func TestSnappyDecodeCopies(t *testing.T) {
	// "abcd" literal,然后 copy1(offset 4, len 8)→ "abcdabcd",合起来 "abcdabcdabcd"(重叠拷贝)。
	src := []byte{12, (4 - 1) << 2, 'a', 'b', 'c', 'd', 0x01 | (8-4)<<2, 4}
	got, err := snappyDecode(src)
	if err != nil || string(got) != "abcdabcdabcd" {
		t.Fatalf("得到 %q, %v", got, err)
	}
	// copy2(offset 2, len 3)
	src = []byte{5, (2 - 1) << 2, 'x', 'y', 0x02 | (3-1)<<2, 2, 0}
	if got, err := snappyDecode(src); err != nil || string(got) != "xyxyx" {
		t.Fatalf("copy2 得到 %q, %v", got, err)
	}
	// 长度对不上 / offset 越界:报错而不是 panic
	for _, bad := range [][]byte{{9, 0, 'a'}, {4, 0x01 | 0<<2, 9}} {
		if _, err := snappyDecode(bad); err == nil {
			t.Errorf("%v 该报错", bad)
		}
	}
}
