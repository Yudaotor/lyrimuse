package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// QQ 音乐客户端自己缓存在本机的逐字歌词 —— QQ 源取逐字歌词的另一条路。
//
// QQ Mac 客户端放过的歌,逐字歌词和译文按**数字歌曲 id** 存在自己容器里 iRRCache/rrdbcache.sqlite 的 Cache 表:
// keyId `<id>.qrc` / `<id>_trans.lrc`,data 是 NSKeyedArchiver 归档的一个字符串,内容跟网关 GetPlayLyricInfo 响应里
// lyric / trans 两个字段**同一种**十六进制密文,decryptQRC / qqAuxiliaryLRC 原样解得开。同表还有 `<id>.lrc`(没有逐字时
// 的整行,纯音乐那条是明文提示句)、`<id>_yinyi.lrc`(粤语歌的音译)、`<id>.taginfo`(各轨版本号)和别的缓存,这里都不读:
// 整行和音译跟接口哪个字段对应没核过。没有罗马音那一轨,所以只有接口本来就不给罗马音的语种才先用它(qqLocalLyricsFirst)。
//
// 数字 id 照旧经 qqSongMetaByMid 取。表在 QQ 的沙盒容器里,读它要「完全磁盘访问」。全程失败当没命中:没装 QQ、没放过这首、
// 读不动、格式变了,调用方照常联网。见 09 章决策 340。

// qqRRCacheOverride 让单测把库指到临时路径。空 = 用真实路径。
var qqRRCacheOverride string

// qqRRCacheMaxBytes 是一条缓存(归档后的密文)的大小上限。真实的逐字歌词几 KB,这里只防格式变了读进一大块别的东西。
const qqRRCacheMaxBytes = 1 << 20

func qqRRCachePath() string {
	if qqRRCacheOverride != "" {
		return qqRRCacheOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.tencent.QQMusicMac/Data/Library",
		"Application Support/QQMusicMac/iRRCache/rrdbcache.sqlite")
}

// qqLocalLyricsFirst:这个语种(单曲详情的 language)本机缓存先用、不先联网。只认国语(0)、英语(5):接口对它们不给罗马音,
// 本机那份跟问到的一样全。粤语本机多一轨音译、日韩接口给罗马音,先联网,本机那份最后兜底。
func qqLocalLyricsFirst(language int) bool {
	return language == 0 || language == 5
}

// qqLocalQRC 读本机缓存里这首(数字 id)的逐字歌词和译文。没有逐字歌词、或解出来没有可用的逐字 / 整行,ok=false。
func qqLocalQRC(id int64) (qqQRCResult, bool) {
	path := qqRRCachePath()
	if path == "" {
		return qqQRCResult{}, false
	}
	if _, err := os.Stat(path); err != nil {
		noteLocalCacheDenied("qq", path, err)
		return qqQRCResult{}, false
	}
	qrcKey, transKey := fmt.Sprintf("%d.qrc", id), fmt.Sprintf("%d_trans.lrc", id)
	rows, ok := qqRRCacheRows(path, qrcKey, transKey)
	if !ok {
		noteLocalCacheReadFailure("qq", path)
		return qqQRCResult{}, false
	}
	noteLocalCacheReadable("qq")
	qrc := qqArchivedString(rows[qrcKey])
	if qrc == "" {
		return qqQRCResult{}, false
	}
	res := qqApplyDecrypted(qqQRCResult{tr: qqAuxiliaryLRC(qqArchivedString(rows[transKey]))}, decryptQRC(qrc))
	if res.yrc == "" && res.line == "" {
		return qqQRCResult{}, false
	}
	log.Printf("qq rrcache: lyrics for song %d from the client cache (translation %v)", id, res.tr != "")
	return res, true
}

// qqRRCacheRows 按键取 Cache 表的 data(原始字节)。查不动(没权限、库被锁、格式变了)ok=false;键不在表里不算失败。
//
// 这个库是 WAL 模式。先按 mode=ro 打开,能读到还没并回主库的新条目;QQ 退出时检查点过、删掉了 -wal / -shm 的话只读连接
// 建不了它们、打不开,这时 WAL 里没有东西,改用 immutable=1 照样读得全。别退回读写连接:那会在 QQ 的容器里建文件。
func qqRRCacheRows(path string, keys ...string) (map[string][]byte, bool) {
	quoted := make([]string, len(keys))
	for i, k := range keys {
		quoted[i] = "'" + strings.ReplaceAll(k, "'", "''") + "'"
	}
	sql := "SELECT keyId, hex(data) AS data FROM Cache WHERE keyId IN (" + strings.Join(quoted, ",") + ")"
	out, err := qqRRCacheQuery(path, "mode=ro", sql)
	if err != nil {
		if _, walErr := os.Stat(path + "-wal"); walErr == nil {
			return nil, false
		}
		if out, err = qqRRCacheQuery(path, "immutable=1", sql); err != nil {
			return nil, false
		}
	}
	rows := map[string][]byte{}
	trimmed := bytes.TrimSpace(out)
	// sqlite3 -json 对零行输出空串,不是 "[]"。
	if len(trimmed) == 0 {
		return rows, true
	}
	var parsed []struct {
		KeyID string `json:"keyId"`
		Data  string `json:"data"`
	}
	if err := json.Unmarshal(trimmed, &parsed); err != nil {
		noteParserUnrecognized("qq-rrcache", err.Error())
		return nil, false
	}
	for _, r := range parsed {
		if len(r.Data) > 2*qqRRCacheMaxBytes {
			continue
		}
		if b, err := hex.DecodeString(r.Data); err == nil {
			rows[r.KeyID] = b
		}
	}
	return rows, true
}

func qqRRCacheQuery(path, query, sql string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), qqLocalQueryTimeout)
	defer cancel()
	// 路径里带空格("Application Support"),用 net/url 组 URI 才会转义成 %20。
	uri := (&neturl.URL{Scheme: "file", Path: path, RawQuery: query}).String()
	return exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, sql).Output()
}

// qqArchivedString 解开 NSKeyedArchiver 归档的一个字符串(根对象就是它)。不是这个形状返回空串。
func qqArchivedString(blob []byte) string {
	if len(blob) == 0 {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), qqLocalQueryTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", "-")
	cmd.Stdin = bytes.NewReader(blob)
	out, err := cmd.Output()
	if err != nil {
		noteParserUnrecognized("qq-rrcache", "plutil could not read the entry")
		return ""
	}
	root, err := parsePlistXML(out)
	if err != nil {
		noteParserUnrecognized("qq-rrcache", err.Error())
		return ""
	}
	rootMap, _ := root.(map[string]any)
	objs, _ := rootMap["$objects"].([]any)
	top, _ := rootMap["$top"].(map[string]any)
	s, ok := qqDeref(objs, top["root"]).(string)
	if !ok {
		noteParserUnrecognized("qq-rrcache", "entry is not an archived string")
		return ""
	}
	noteParserRecognized("qq-rrcache")
	return strings.TrimSpace(s)
}
