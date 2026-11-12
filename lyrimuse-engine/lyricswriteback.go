package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

// 歌词写回:把歌词管理里一首歌的歌词写进它的本地音频文件(MP3 的 ID3v2 USLT、FLAC 的 VORBIS_COMMENT LYRICS)。
// 只在用户点按钮时由编辑通道(write_file_lyrics)触发,引擎是唯一写音频文件的一方。见 11 章决策 162。
//
// 写法一律是「同目录克隆 → 改克隆 → 自校验 → rename 换掉原文件」,不就地写:正在放这个文件的播放器手上是旧 inode,
// 不受影响;中途失败只删克隆,原文件一个字节不动。自校验三项,任一不过就放弃替换:
//   - 克隆里标签区之后的字节(音频帧、文件尾的 ID3v1 / APE 等)跟原文件逐字节相同;
//   - 用引擎自己的读法(readLocalFileTags)回读克隆,歌词跟要写的一字不差;
//   - 克隆的标签区里歌词以外的帧 / 元数据块跟原文件逐字节相同、顺序不变。

// lyricsWritebackErr 带一个稳定的错误码,App 按码选文案;Error() 是「码: 细节」。
type lyricsWritebackErr struct {
	code string
	err  error
}

func (e *lyricsWritebackErr) Error() string {
	if e.err == nil {
		return e.code
	}
	return e.code + ": " + e.err.Error()
}

func (e *lyricsWritebackErr) Unwrap() error { return e.err }

// 错误码。App 侧按这些字面量分文案,改名要两边同步。
const (
	wbErrUnsupportedFormat = "unsupported_format" // 不是 MP3 / FLAC
	wbErrUnsupportedTag    = "unsupported_tag"    // 标签版本或布局不在写入范围(ID3v2.2、v2.4 整体反同步、帧表损坏、FLAC 前面套 ID3)
	wbErrNotFound          = "not_found"          // 文件不存在
	wbErrNotRegular        = "not_regular"        // 不是普通文件
	wbErrHardLinked        = "hard_linked"        // 有多个硬链接:换文件会把它们拆开
	wbErrNotWritable       = "not_writable"       // 文件或所在目录没有写权限
	wbErrReadOnlyVolume    = "read_only_volume"   // 在只读卷上
	wbErrCloudLocation     = "cloud_location"     // 在 iCloud 云盘 / 第三方云盘目录,或文件只在云端
	wbErrNetworkLocation   = "network_location"   // 在网络卷上
	wbErrHasLyrics         = "file_has_lyrics"    // 文件里已有歌词,请求没允许覆盖
	wbErrNoLyrics          = "no_lyrics"          // 这首在缓存里没有歌词可写
	wbErrNoFile            = "no_file"            // 请求没带文件路径
	wbErrFileChanged       = "file_changed"       // 写的过程中原文件被别人改了
	wbErrAudioMismatch     = "audio_mismatch"     // 自校验:音频区跟原文件不一致
	wbErrReadbackMismatch  = "readback_mismatch"  // 自校验:回读的歌词跟要写的不一样
	wbErrTagsNotPreserved  = "tags_not_preserved" // 自校验:歌词以外的帧 / 块变了
	wbErrIO                = "io"                 // 其余读写失败
)

func wbErr(code string, err error) error { return &lyricsWritebackErr{code: code, err: err} }

func wbErrf(code, format string, args ...any) error {
	return &lyricsWritebackErr{code: code, err: fmt.Errorf(format, args...)}
}

// lyricsWritebackCode 取错误码;不是写回错误时为 io。
func lyricsWritebackCode(err error) string {
	var we *lyricsWritebackErr
	if errors.As(err, &we) {
		return we.code
	}
	return wbErrIO
}

// lyricsTagLayout:一个文件开头的标签区(MP3 的 ID3v2、FLAC 的 fLaC + 元数据块)和它后面的音频区。
type lyricsTagLayout struct {
	head       []byte // 原文件 [0, audioStart)
	audioStart int64
	hasLyrics  bool
	// build 拼出写进 text 之后的新标签区。原标签区放得下时长度跟 head 相同(用掉 / 让出 padding),音频区不挪。
	build func(text string) ([]byte, error)
	// preserved 核对新标签区里歌词以外的部分跟原来逐字节相同。
	preserved func(newHead []byte) error
}

// lyricsWritebackFormats:写回支持的扩展名(小写,不带点) → 读标签区的函数。
var lyricsWritebackFormats = map[string]func(io.ReadSeeker, int64) (lyricsTagLayout, error){
	"mp3":  id3WritebackLayout,
	"flac": flacWritebackLayout,
}

func lyricsWritebackExt(path string) string {
	return strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
}

// lyricsWritebackSupported:这个扩展名在写回范围里。
func lyricsWritebackSupported(path string) bool {
	_, ok := lyricsWritebackFormats[lyricsWritebackExt(path)]
	return ok
}

// normalizeWritebackLyrics 是实际写进文件的正文:换行统一成 \n、去掉控制字符和末尾空白。回读按它逐字比。
func normalizeWritebackLyrics(text string) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	text = stripLyricControlChars(text)
	return strings.TrimRight(text, " \t\n")
}

// lyricsWritebackProbe:写之前给确认框用的信息。
type lyricsWritebackProbe struct {
	path      string // 解开软链接之后真正会被替换的文件
	hasLyrics bool
}

// probeLyricsWriteback 检查文件能不能写、里面已有没有歌词,不写任何东西。
func probeLyricsWriteback(path string) (lyricsWritebackProbe, error) {
	real, _, err := lyricsWritebackTarget(path)
	if err != nil {
		return lyricsWritebackProbe{}, err
	}
	layout, err := readLyricsTagLayout(real)
	if err != nil {
		return lyricsWritebackProbe{}, err
	}
	return lyricsWritebackProbe{path: real, hasLyrics: layout.hasLyrics}, nil
}

// lyricsWritebackAfterWrite:克隆写完、自校验之前调一下(单测用它往克隆里注入损坏)。生产代码不设。
var lyricsWritebackAfterWrite func(clonePath string)

// writeLyricsToFile 把 text 写进 path 的标签。overwrite 为假时文件里已有歌词就拒绝(file_has_lyrics)。
// 成功交回真正被替换的文件路径。
func writeLyricsToFile(path, text string, overwrite bool) (string, error) {
	text = normalizeWritebackLyrics(text)
	if text == "" {
		return "", wbErr(wbErrNoLyrics, nil)
	}
	real, before, err := lyricsWritebackTarget(path)
	if err != nil {
		return "", err
	}
	layout, err := readLyricsTagLayout(real)
	if err != nil {
		return "", err
	}
	if layout.hasLyrics && !overwrite {
		return "", wbErr(wbErrHasLyrics, nil)
	}
	newHead, err := layout.build(text)
	if err != nil {
		return "", err
	}
	if err := layout.preserved(newHead); err != nil {
		return "", err
	}
	clone, err := cloneForWriteback(real)
	if err != nil {
		return "", err
	}
	replaced := false
	defer func() {
		if !replaced {
			_ = os.Remove(clone)
		}
	}()
	if err := writeWritebackClone(clone, real, newHead, layout); err != nil {
		return "", err
	}
	if lyricsWritebackAfterWrite != nil {
		lyricsWritebackAfterWrite(clone)
	}
	if err := verifyWritebackClone(clone, real, text, layout); err != nil {
		return "", err
	}
	after, err := os.Stat(real)
	if err != nil || !sameFileVersion(before, after) {
		return "", wbErr(wbErrFileChanged, err)
	}
	if err := os.Rename(clone, real); err != nil {
		noteFileErr("rename", real, err)
		return "", wbErr(wbErrIO, err)
	}
	replaced = true
	syncDir(filepath.Dir(real))
	log.Printf("lyrics writeback: wrote %d bytes of lyrics into %s", len(text), tildeHome(real))
	return real, nil
}

// lyricsWritebackTarget 解开软链接、按位置和权限把关,交回真正要替换的文件和它此刻的状态。
func lyricsWritebackTarget(path string) (string, os.FileInfo, error) {
	if path == "" {
		return "", nil, wbErr(wbErrNoFile, nil)
	}
	if !lyricsWritebackSupported(path) {
		return "", nil, wbErrf(wbErrUnsupportedFormat, "%s", filepath.Ext(path))
	}
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", nil, wbErr(wbErrNotFound, err)
		}
		return "", nil, wbErr(wbErrIO, err)
	}
	if real, err = filepath.Abs(real); err != nil {
		return "", nil, wbErr(wbErrIO, err)
	}
	if !lyricsWritebackSupported(real) {
		return "", nil, wbErrf(wbErrUnsupportedFormat, "%s", filepath.Ext(real))
	}
	if home, err := os.UserHomeDir(); err == nil {
		if err := cloudLocationErr(real, home); err != nil {
			return "", nil, err
		}
	}
	info, err := os.Stat(real)
	if err != nil {
		return "", nil, wbErr(wbErrIO, err)
	}
	if !info.Mode().IsRegular() {
		return "", nil, wbErr(wbErrNotRegular, nil)
	}
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		if st.Nlink > 1 {
			return "", nil, wbErr(wbErrHardLinked, nil)
		}
		if st.Flags&sfDataless != 0 {
			return "", nil, wbErrf(wbErrCloudLocation, "file is not downloaded")
		}
	}
	var sfs syscall.Statfs_t
	if err := syscall.Statfs(real, &sfs); err == nil {
		if err := volumeFlagsErr(sfs.Flags); err != nil {
			return "", nil, err
		}
	}
	for _, p := range []string{real, filepath.Dir(real)} {
		if err := syscall.Access(p, accessWriteOK); err != nil {
			if errors.Is(err, syscall.EROFS) {
				return "", nil, wbErr(wbErrReadOnlyVolume, err)
			}
			return "", nil, wbErr(wbErrNotWritable, err)
		}
	}
	return real, info, nil
}

const (
	accessWriteOK = 0x2        // W_OK
	sfDataless    = 0x40000000 // st_flags 的 SF_DATALESS:文件内容只在云端
	mntReadOnly   = 0x00000001 // statfs f_flags 的 MNT_RDONLY
	mntLocal      = 0x00001000 // statfs f_flags 的 MNT_LOCAL
)

// volumeFlagsErr:按 statfs 的 f_flags 判只读卷、网络卷。
func volumeFlagsErr(flags uint32) error {
	if flags&mntReadOnly != 0 {
		return wbErr(wbErrReadOnlyVolume, nil)
	}
	if flags&mntLocal == 0 {
		return wbErr(wbErrNetworkLocation, nil)
	}
	return nil
}

// cloudLocationErr:路径在 iCloud 云盘(~/Library/Mobile Documents)或文件提供程序的云盘目录(~/Library/CloudStorage)里。
// 这两处的文件改了就会重新上传,也可能只是占位文件。
func cloudLocationErr(path, home string) error {
	for _, root := range []string{
		filepath.Join(home, "Library", "Mobile Documents"),
		filepath.Join(home, "Library", "CloudStorage"),
	} {
		if strings.HasPrefix(path, root+string(filepath.Separator)) {
			return wbErr(wbErrCloudLocation, nil)
		}
	}
	return nil
}

// sameFileVersion:同一个 inode、大小和修改时间都没变。
func sameFileVersion(a, b os.FileInfo) bool {
	if a == nil || b == nil || a.Size() != b.Size() || !a.ModTime().Equal(b.ModTime()) {
		return false
	}
	sa, ok1 := a.Sys().(*syscall.Stat_t)
	sb, ok2 := b.Sys().(*syscall.Stat_t)
	if !ok1 || !ok2 {
		return false
	}
	return sa.Dev == sb.Dev && sa.Ino == sb.Ino
}

// readLyricsTagLayout 按扩展名读文件开头的标签区。
func readLyricsTagLayout(path string) (lyricsTagLayout, error) {
	parse, ok := lyricsWritebackFormats[lyricsWritebackExt(path)]
	if !ok {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedFormat, "%s", filepath.Ext(path))
	}
	f, err := os.Open(path)
	if err != nil {
		noteFileErr("read", path, err)
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	return parse(f, info.Size())
}

// cloneForWriteback 在同目录克隆一份(APFS 上是 clonefile,不占空间;别的文件系统退回整份复制),权限、扩展属性、
// 创建时间跟着走。克隆的文件名以点开头、保留扩展名(回读按扩展名认格式)。
func cloneForWriteback(real string) (string, error) {
	var suffix [6]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return "", wbErr(wbErrIO, err)
	}
	dir, name := filepath.Split(real)
	clone := filepath.Join(dir, "."+strings.TrimSuffix(name, filepath.Ext(name))+".lyrimuse-"+hex.EncodeToString(suffix[:])+filepath.Ext(name))
	if _, err := os.Lstat(clone); err == nil {
		return "", wbErrf(wbErrIO, "temporary file already exists")
	}
	if out, err := exec.Command("/bin/cp", "-c", "-p", real, clone).CombinedOutput(); err != nil {
		_ = os.Remove(clone)
		if out2, err2 := exec.Command("/bin/cp", "-p", real, clone).CombinedOutput(); err2 != nil {
			_ = os.Remove(clone)
			return "", wbErrf(wbErrIO, "copy: %v %s / %v %s", err, bytes.TrimSpace(out), err2, bytes.TrimSpace(out2))
		}
	}
	return clone, nil
}

// writeWritebackClone 把新标签区写进克隆:长度不变时只覆盖开头那一段;变了就从原文件把音频区接在后面、截掉多余的尾巴。
// 最后 fsync。
func writeWritebackClone(clone, real string, newHead []byte, layout lyricsTagLayout) error {
	f, err := os.OpenFile(clone, os.O_WRONLY, 0)
	if err != nil {
		return wbErr(wbErrIO, err)
	}
	defer f.Close()
	if _, err := f.WriteAt(newHead, 0); err != nil {
		return wbErr(wbErrIO, err)
	}
	if len(newHead) != len(layout.head) {
		src, err := os.Open(real)
		if err != nil {
			return wbErr(wbErrIO, err)
		}
		defer src.Close()
		if _, err := src.Seek(layout.audioStart, io.SeekStart); err != nil {
			return wbErr(wbErrIO, err)
		}
		if _, err := f.Seek(int64(len(newHead)), io.SeekStart); err != nil {
			return wbErr(wbErrIO, err)
		}
		n, err := io.Copy(f, src)
		if err != nil {
			return wbErr(wbErrIO, err)
		}
		if err := f.Truncate(int64(len(newHead)) + n); err != nil {
			return wbErr(wbErrIO, err)
		}
	}
	if err := f.Sync(); err != nil {
		return wbErr(wbErrIO, err)
	}
	return nil
}

// verifyWritebackClone 是替换前的自校验,见文件头注的三项。
func verifyWritebackClone(clone, real, text string, orig lyricsTagLayout) error {
	got, err := readLyricsTagLayout(clone)
	if err != nil {
		return wbErr(wbErrReadbackMismatch, err)
	}
	if err := orig.preserved(got.head); err != nil {
		return err
	}
	if err := sameAudioRegion(real, orig.audioStart, clone, got.audioStart); err != nil {
		return err
	}
	tags := readLocalFileTags(clone)
	if !tags.hasLyrics || tags.lyrics != text {
		return wbErrf(wbErrReadbackMismatch, "read back %d bytes, wrote %d", len(tags.lyrics), len(text))
	}
	return nil
}

// sameAudioRegion:a 从 aStart、b 从 bStart 起到文件末尾逐字节相同。
func sameAudioRegion(a string, aStart int64, b string, bStart int64) error {
	fa, err := os.Open(a)
	if err != nil {
		return wbErr(wbErrIO, err)
	}
	defer fa.Close()
	fb, err := os.Open(b)
	if err != nil {
		return wbErr(wbErrIO, err)
	}
	defer fb.Close()
	ia, err := fa.Stat()
	if err != nil {
		return wbErr(wbErrIO, err)
	}
	ib, err := fb.Stat()
	if err != nil {
		return wbErr(wbErrIO, err)
	}
	if ia.Size()-aStart != ib.Size()-bStart {
		return wbErrf(wbErrAudioMismatch, "audio length %d vs %d", ia.Size()-aStart, ib.Size()-bStart)
	}
	ra := io.NewSectionReader(fa, aStart, ia.Size()-aStart)
	rb := io.NewSectionReader(fb, bStart, ib.Size()-bStart)
	bufA, bufB := make([]byte, 1<<20), make([]byte, 1<<20)
	for {
		na, errA := io.ReadFull(ra, bufA)
		nb, errB := io.ReadFull(rb, bufB)
		if na != nb || !bytes.Equal(bufA[:na], bufB[:nb]) {
			return wbErr(wbErrAudioMismatch, nil)
		}
		doneA := errA == io.EOF || errA == io.ErrUnexpectedEOF
		doneB := errB == io.EOF || errB == io.ErrUnexpectedEOF
		if errA != nil && !doneA {
			return wbErr(wbErrIO, errA)
		}
		if errB != nil && !doneB {
			return wbErr(wbErrIO, errB)
		}
		if doneA || doneB {
			if doneA != doneB {
				return wbErr(wbErrAudioMismatch, nil)
			}
			return nil
		}
	}
}

func syncDir(dir string) {
	d, err := os.Open(dir)
	if err != nil {
		noteFileErr("sync", dir, err)
		return
	}
	_ = d.Sync()
	_ = d.Close()
}

// writebackPadding:标签区放不下、要整体变长时新留的 padding,跟 mutagen 的默认值一样(1 KiB + 音频区的千分之一),
// 上限 64 KiB。
func writebackPadding(audioBytes int64) int {
	p := 1024 + audioBytes/1000
	if p > 64<<10 {
		p = 64 << 10
	}
	return int(p)
}

// lyricsWritebackText:缓存里这一首要写进文件的歌词:有逐行歌词写 LRC,没有就写纯文本;plain 为真时 LRC 也去掉时间标签
// 只写文字。标了纯音乐的不写。交回的是 normalizeWritebackLyrics 之后的正文。调用方不持 enrichMu。
func lyricsWritebackText(key string, plain bool) (string, error) {
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok || e.Instrumental {
		return "", wbErr(wbErrNoLyrics, nil)
	}
	for _, body := range []bodyText{e.Lyrics, e.PlainLyrics} {
		if body.IsZero() {
			continue
		}
		s, err := body.load()
		if err != nil {
			return "", wbErr(wbErrIO, err)
		}
		if plain {
			s = lrcToPlainText(s)
		}
		if s = normalizeWritebackLyrics(s); s != "" {
			return s, nil
		}
	}
	return "", wbErr(wbErrNoLyrics, nil)
}

// writebackWantsPlainText:写给这个播放器放的文件时只写歌词文字。Apple Music 把文件里的歌词原样当纯文本显示,
// 时间标签会一行行露出来;它的曲目写去掉时间标签的文字。见 11 章决策 163。
func writebackWantsPlainText(bundleID string) bool {
	return bundleID == appleMusicBundleID
}

var (
	lrcLeadingTimestamps = regexp.MustCompile(`^(?:\s*\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\])+`)
	lrcWordTimestamps    = regexp.MustCompile(`<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>`)
	lrcMetadataLine      = regexp.MustCompile(`^\s*\[[A-Za-z][A-Za-z0-9_-]*:[^\]]*\]\s*$`)
)

// lrcToPlainText 去掉 LRC 的时间标签:行首的时间、行内逐字的 <时间>、整行的元信息标签([ar:] [offset:] 之类)都删,
// 只有时间没有字的行删掉。不是 LRC 的原样交回。
func lrcToPlainText(s string) string {
	if !localFileLRCTimestamp.MatchString(s) {
		return s
	}
	var out []string
	for _, line := range strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n") {
		if lrcMetadataLine.MatchString(line) {
			continue
		}
		stripped := lrcLeadingTimestamps.ReplaceAllString(line, "")
		timed := stripped != line
		stripped = strings.TrimSpace(lrcWordTimestamps.ReplaceAllString(stripped, ""))
		if timed && stripped == "" {
			continue
		}
		out = append(out, stripped)
	}
	return strings.Join(out, "\n")
}

// applyLyricsWritebackEdit 执行编辑通道的 probe_file_lyrics / write_file_lyrics。不动歌词缓存:文件改完,
// 引擎读内嵌歌词的缓存按大小和修改时间自己作废(localFileTagsMemo)。
func applyLyricsWritebackEdit(req enrichEditRequest) enrichEditResult {
	res := enrichEditResult{ID: req.ID, FilePath: req.FilePath}
	fail := func(err error) enrichEditResult {
		res.Error, res.ErrorCode = err.Error(), lyricsWritebackCode(err)
		warnf("enrich edit: op=%s failed: %v", req.Op, err)
		return res
	}
	if req.Op == "probe_file_lyrics" {
		p, err := probeLyricsWriteback(req.FilePath)
		if err != nil {
			return fail(err)
		}
		res.OK, res.FilePath, res.FileHasLyrics = true, p.path, p.hasLyrics
		return res
	}
	if req.Key == "" {
		return fail(fmt.Errorf("%s: empty key", req.Op))
	}
	text, err := lyricsWritebackText(req.Key, writebackWantsPlainText(req.Player))
	if err != nil {
		return fail(err)
	}
	real, err := writeLyricsToFile(req.FilePath, text, req.Value)
	if err != nil {
		return fail(err)
	}
	noteLyricsWrittenBack(real, text)
	res.OK, res.Changed, res.FilePath = true, 1, real
	log.Printf("enrich edit: op=%s changed=1", req.Op)
	return res
}
