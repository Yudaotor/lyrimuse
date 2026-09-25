package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// 只读的 LevelDB 取数:给定一个 LevelDB 目录和一组 key,返回每个 key 当前的值。
//
// ## 为什么自己写
//
// 这个 module 零外部依赖(同 plistxml.go / exec sqlite3 那几处的理由),而 Go 标准库既没有
// LevelDB 也没有 Snappy。要读的是别的 App(Spotify)正在用的库,所以:
//
//   - **不开库、不抢锁**:LevelDB 的 LOCK 文件由 Spotify 持有,这里只按文件格式读 .ldb / .log
//     原始字节,不写任何东西。
//   - **只按 key 精确查**:SSTable 自带索引块,先读索引定位到可能含这个 key 的那一个数据块,
//     再解那一块,不把整个库(实测 27 万条、几十 MB)读进内存。
//   - **读的途中文件被合并掉是正常的**(Spotify 在跑,compaction 随时会发生):单个文件读失败就
//     跳过,整体仍按"尽力而为"返回;调用方拿不到就退回别的路径,不报错。
//
// ## 版本与删除
//
// 同一个 user key 可能同时出现在好几个文件里(新写入还在 .log、旧值在某个 .ldb 里等着被合并),
// 每条都带一个 sequence number,取最大的那条;最大的那条是删除标记就当作不存在。这里不读
// MANIFEST 判断哪些 .ldb 还"活着"——已经被合并掉、但还没来得及删的旧文件,它们里面的条目
// sequence 一定更小,按 sequence 取最新天然就把它们盖掉了。
//
// 格式依据:LevelDB 的 table_format.md / log_format.md;Snappy 的 format_description.txt。

// ldbMaxFileBytes:单个文件的读入上限。实测 Spotify 的 .ldb 在 2MB 上下,.log 也是 2MB 级;
// 64MB 防的是"文件异常膨胀"把内存吃光,不是格式约束。
const ldbMaxFileBytes = 64 << 20

// ldbValue 是查到的一个版本。
type ldbValue struct {
	seq     uint64
	value   []byte
	deleted bool
}

// ldbGet 在 dir 这个 LevelDB 目录里查 keys,返回 key → 当前值(不存在 / 已删除的不在结果里)。
func ldbGet(dir string, keys [][]byte) map[string][]byte {
	if len(keys) == 0 {
		return nil
	}
	want := make(map[string]bool, len(keys))
	sorted := make([][]byte, 0, len(keys))
	for _, k := range keys {
		if !want[string(k)] {
			want[string(k)] = true
			sorted = append(sorted, k)
		}
	}
	sort.Slice(sorted, func(i, j int) bool { return bytes.Compare(sorted[i], sorted[j]) < 0 })

	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	best := map[string]ldbValue{}
	keep := func(k []byte, v ldbValue) {
		if cur, ok := best[string(k)]; !ok || v.seq > cur.seq {
			best[string(k)] = v
		}
	}
	for _, e := range ents {
		name := e.Name()
		path := filepath.Join(dir, name)
		switch {
		case strings.HasSuffix(name, ".ldb") || strings.HasSuffix(name, ".sst"):
			_ = ldbTableLookup(path, sorted, keep) // 读失败(被合并掉 / 格式不认识)就跳过这个文件
		case strings.HasSuffix(name, ".log"):
			_ = ldbLogScan(path, want, keep)
		}
	}
	out := make(map[string][]byte, len(best))
	for k, v := range best {
		if !v.deleted {
			out[k] = v.value
		}
	}
	return out
}

func ldbReadFile(path string) ([]byte, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if st.Size() > ldbMaxFileBytes {
		return nil, errors.New("leveldb: file too large")
	}
	return os.ReadFile(path)
}

// ---- SSTable ----

// ldbBlockHandle 是 (offset, size) 两个 varint。
func ldbBlockHandle(b []byte) (off, size uint64, rest []byte, ok bool) {
	off, n := binary.Uvarint(b)
	if n <= 0 {
		return 0, 0, nil, false
	}
	size, m := binary.Uvarint(b[n:])
	if m <= 0 {
		return 0, 0, nil, false
	}
	return off, size, b[n+m:], true
}

// ldbReadBlock 按位置读出一个块(按块尾的压缩类型决定要不要解 Snappy)。
//
// 用 ReadAt 只读这一块,不把整个文件读进来:一次换歌要查二十来个 2MB 的 .ldb,整份读就是每次
// 几十 MB 的 I/O,而实际用到的只有每个文件的尾部、索引块和命中的那一个数据块。
func ldbReadBlock(f *os.File, fileSize int64, off, size uint64) ([]byte, error) {
	if off+size+5 > uint64(fileSize) || size > ldbMaxFileBytes { // 块后面跟 1 字节压缩类型 + 4 字节 CRC
		return nil, errors.New("leveldb: block out of range")
	}
	buf := make([]byte, size+1)
	if _, err := f.ReadAt(buf, int64(off)); err != nil {
		return nil, err
	}
	raw, typ := buf[:size], buf[size]
	switch typ {
	case 0:
		return raw, nil
	case 1:
		return snappyDecode(raw)
	}
	return nil, errors.New("leveldb: unknown block compression")
}

// ldbBlockEntries 遍历一个块里的全部条目(key 前缀压缩,块尾是 restart 数组)。
func ldbBlockEntries(b []byte, fn func(key, value []byte) bool) error {
	if len(b) < 4 {
		return errors.New("leveldb: short block")
	}
	nRestart := binary.LittleEndian.Uint32(b[len(b)-4:])
	end := len(b) - 4 - int(nRestart)*4
	if end < 0 {
		return errors.New("leveldb: bad restart count")
	}
	var key []byte
	i := 0
	for i < end {
		shared, n1 := binary.Uvarint(b[i:])
		if n1 <= 0 {
			return errors.New("leveldb: bad entry")
		}
		i += n1
		nonShared, n2 := binary.Uvarint(b[i:])
		if n2 <= 0 {
			return errors.New("leveldb: bad entry")
		}
		i += n2
		vlen, n3 := binary.Uvarint(b[i:])
		if n3 <= 0 {
			return errors.New("leveldb: bad entry")
		}
		i += n3
		if shared > uint64(len(key)) || uint64(i)+nonShared+vlen > uint64(end) {
			return errors.New("leveldb: entry out of range")
		}
		key = append(key[:shared:shared], b[i:i+int(nonShared)]...)
		i += int(nonShared)
		value := b[i : i+int(vlen)]
		i += int(vlen)
		if !fn(key, value) {
			return nil
		}
	}
	return nil
}

// ldbSplitInternalKey 把 internal key 拆成 user key 与 (sequence, type)。
func ldbSplitInternalKey(ik []byte) (user []byte, seq uint64, typ byte, ok bool) {
	if len(ik) < 8 {
		return nil, 0, 0, false
	}
	tag := binary.LittleEndian.Uint64(ik[len(ik)-8:])
	return ik[:len(ik)-8], tag >> 8, byte(tag & 0xff), true
}

// ldbTableLookup 在一个 SSTable 里查 sorted(已按字节序排好)这些 key。
//
// 索引块的每一条是「≥ 该数据块最后一个 key 的分隔 key → 数据块位置」,按序排列。所以一个 key
// 只可能落在第一个分隔 key ≥ 它的那个块里 —— 同一个 user key 的多个版本恰好跨块时,会接着落进
// 后面的块,这里继续往后看,直到块的第一个 key 已经比它大为止。
func ldbTableLookup(path string, sorted [][]byte, keep func([]byte, ldbValue)) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	size := st.Size()
	if size < 48 {
		return errors.New("leveldb: short table")
	}
	footer := make([]byte, 48)
	if _, err := f.ReadAt(footer, size-48); err != nil {
		return err
	}
	if binary.LittleEndian.Uint64(footer[40:]) != 0xdb4775248b80fb57 {
		return errors.New("leveldb: bad table magic")
	}
	_, _, rest, ok := ldbBlockHandle(footer) // metaindex,用不上
	if !ok {
		return errors.New("leveldb: bad footer")
	}
	ioff, isize, _, ok := ldbBlockHandle(rest)
	if !ok {
		return errors.New("leveldb: bad footer")
	}
	index, err := ldbReadBlock(f, size, ioff, isize)
	if err != nil {
		return err
	}
	type handle struct {
		sep       []byte
		off, size uint64
	}
	var handles []handle
	if err := ldbBlockEntries(index, func(k, v []byte) bool {
		user, _, _, ok := ldbSplitInternalKey(k)
		off, size, _, ok2 := ldbBlockHandle(v)
		if ok && ok2 {
			handles = append(handles, handle{sep: append([]byte(nil), user...), off: off, size: size})
		}
		return true
	}); err != nil {
		return err
	}
	decoded := map[int][]byte{}
	for _, want := range sorted {
		start := sort.Search(len(handles), func(i int) bool { return bytes.Compare(handles[i].sep, want) >= 0 })
		for bi := start; bi < len(handles); bi++ {
			blk, done := decoded[bi]
			if !done {
				blk, err = ldbReadBlock(f, size, handles[bi].off, handles[bi].size)
				if err != nil {
					break
				}
				decoded[bi] = blk
			}
			passed := false
			_ = ldbBlockEntries(blk, func(k, v []byte) bool {
				user, seq, typ, ok := ldbSplitInternalKey(k)
				if !ok {
					return true
				}
				switch c := bytes.Compare(user, want); {
				case c == 0:
					keep(want, ldbValue{seq: seq, value: append([]byte(nil), v...), deleted: typ == 0})
				case c > 0:
					passed = true
					return false
				}
				return true
			})
			if passed {
				break
			}
		}
	}
	return nil
}

// ---- 写前日志(.log)----

// ldbLogScan 读一个写前日志:32KB 一块,每条物理记录 7 字节头(CRC 4 + 长度 2 + 类型 1),
// FULL / FIRST+MIDDLE*+LAST 拼成一条 WriteBatch,再拆出里面的 Put / Delete。
func ldbLogScan(path string, want map[string]bool, keep func([]byte, ldbValue)) error {
	data, err := ldbReadFile(path)
	if err != nil {
		return err
	}
	const blockSize = 32768
	var rec []byte
	for i := 0; i+7 <= len(data); {
		if left := blockSize - i%blockSize; left < 7 {
			i += left // 块尾不够放一个头,补零跳过
			continue
		}
		length := int(binary.LittleEndian.Uint16(data[i+4:]))
		typ := data[i+6]
		if i+7+length > len(data) {
			break // 写到一半的尾巴
		}
		payload := data[i+7 : i+7+length]
		i += 7 + length
		switch typ {
		case 1: // FULL
			ldbApplyBatch(payload, want, keep)
		case 2: // FIRST
			rec = append(rec[:0], payload...)
		case 3: // MIDDLE
			rec = append(rec, payload...)
		case 4: // LAST
			rec = append(rec, payload...)
			ldbApplyBatch(rec, want, keep)
			rec = rec[:0]
		}
	}
	return nil
}

// ldbApplyBatch 拆一条 WriteBatch:8 字节起始 sequence + 4 字节条数 + 若干 (type, key[, value])。
func ldbApplyBatch(b []byte, want map[string]bool, keep func([]byte, ldbValue)) {
	if len(b) < 12 {
		return
	}
	seq := binary.LittleEndian.Uint64(b)
	count := binary.LittleEndian.Uint32(b[8:])
	i := 12
	readSlice := func() ([]byte, bool) {
		n, m := binary.Uvarint(b[i:])
		if m <= 0 || uint64(i+m)+n > uint64(len(b)) {
			return nil, false
		}
		s := b[i+m : i+m+int(n)]
		i += m + int(n)
		return s, true
	}
	for c := uint32(0); c < count && i < len(b); c++ {
		typ := b[i]
		i++
		k, ok := readSlice()
		if !ok {
			return
		}
		var v []byte
		if typ == 1 {
			if v, ok = readSlice(); !ok {
				return
			}
		}
		if want[string(k)] {
			keep(k, ldbValue{seq: seq + uint64(c), value: append([]byte(nil), v...), deleted: typ == 0})
		}
	}
}

// ---- Snappy(块格式,不是 framing 格式)----

// snappyDecode 解一段 Snappy 块:开头是解压后长度(varint),之后是 literal / copy 两类元素。
func snappyDecode(src []byte) ([]byte, error) {
	n, hdr := binary.Uvarint(src)
	if hdr <= 0 || n > ldbMaxFileBytes {
		return nil, errors.New("snappy: bad header")
	}
	dst := make([]byte, 0, n)
	for i := hdr; i < len(src); {
		tag := src[i]
		i++
		var length, offset int
		switch tag & 3 {
		case 0: // literal
			length = int(tag >> 2)
			if length >= 60 {
				nb := length - 59
				if i+nb > len(src) {
					return nil, errors.New("snappy: bad literal")
				}
				length = 0
				for k := 0; k < nb; k++ {
					length |= int(src[i+k]) << (8 * k)
				}
				i += nb
			}
			length++
			if i+length > len(src) {
				return nil, errors.New("snappy: literal out of range")
			}
			dst = append(dst, src[i:i+length]...)
			i += length
			continue
		case 1:
			if i >= len(src) {
				return nil, errors.New("snappy: bad copy1")
			}
			length = int(tag>>2&7) + 4
			offset = int(tag>>5)<<8 | int(src[i])
			i++
		case 2:
			if i+2 > len(src) {
				return nil, errors.New("snappy: bad copy2")
			}
			length = int(tag>>2) + 1
			offset = int(binary.LittleEndian.Uint16(src[i:]))
			i += 2
		case 3:
			if i+4 > len(src) {
				return nil, errors.New("snappy: bad copy4")
			}
			length = int(tag>>2) + 1
			offset = int(binary.LittleEndian.Uint32(src[i:]))
			i += 4
		}
		if offset <= 0 || offset > len(dst) {
			return nil, errors.New("snappy: bad offset")
		}
		// 源和目标可能重叠(offset < length 表示重复一段),只能逐字节拷。
		for k := 0; k < length; k++ {
			dst = append(dst, dst[len(dst)-offset])
		}
	}
	if uint64(len(dst)) != n {
		return nil, errors.New("snappy: length mismatch")
	}
	return dst, nil
}
