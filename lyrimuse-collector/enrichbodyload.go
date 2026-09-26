package main

import (
	"encoding/json"
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"sync"
)

// 主缓存里的**精简条目**:形状跟精简索引那一条一样(`leanForIndex`)—— 带 `body_crc`,主歌词 `lyrics`
// 留着,另外四块正文(逐字 / 译文 / 罗马音 / 纯文本)不在主缓存里,在这首歌的正文小文件里
// (`lyrimuse-lyrics-bodies/`,见 enrichindex.go)。
//
// 为什么:主缓存 86% 是正文(8600 多条时 107 MB 里约 93 MB),而正文小文件里本来就有一模一样的一份,
// 每次保存都把这 93 MB 重新编码、重写一遍。主缓存只存元数据 + 主歌词之后,一次保存只写三十几 MB。
//
// 加载时把正文补回来(`hydrateEnrichBodies`),补完清掉 `body_crc` / `body_fields`:内存里的条目跟
// 完整格式读进来的**一模一样**,读正文的几十处代码都不用知道磁盘上是哪种格式。一份文件里两种条目可以
// 混着(判据是逐条有没有 `body_crc`),完整格式的旧文件照常能读。
//
// 正文小文件的三种情况:
//   - 文件自洽(文件里记的校验值 = 按内容重算的)、跟主缓存记的一致 → 用它。
//   - 文件自洽、但跟主缓存记的**不一致** → 也用它:保存的顺序是先写正文小文件、再写主缓存,两步之间
//     被打断(强杀 / 断电)时,小文件是新的那一份,主缓存还是旧的。
//   - 文件缺失或不自洽 → 这一条只剩主缓存里的主歌词。常驻进程紧接着会从 lyrics/ 文件夹对账
//     (`importLyricsFromFiles`),那里有主歌词 / 译文 / 罗马音 / 逐字四种文件,能补回来的都会补回来。
//
// 正文小文件并发读(8000 多个小文件串行读要一秒多,比读一份完整格式的主缓存还慢)。

// enrichBodyLoadWorkers 并发读正文小文件的上限。
const enrichBodyLoadWorkers = 8

// bodyHydrateStats 一次加载里精简条目的去向,给启动日志用。
type bodyHydrateStats struct {
	lean, restored, newer, missing int
	missingKeys                    []string // 最多记 3 条,日志里点名
	// full:正文还整块写在主缓存里的条目(老格式)。非零时第一次改写成精简格式之前要先留一份备份。
	full int
}

func (s bodyHydrateStats) log() {
	if s.lean == 0 {
		return
	}
	log.Printf("cache: restored lyrics bodies of %d lean entries from side files (%d newer than the cache)", s.restored+s.newer, s.newer)
	if s.missing > 0 {
		slog.Warn("cache: lyrics body side files missing or damaged, keeping only the main lyrics until the lyrics folder refills them",
			"entries", s.missing, "examples", s.missingKeys)
	}
}

// hydrateEnrichBodies 把 m 里的精简条目补回正文(原地改 m),dir 是正文小文件目录。
func hydrateEnrichBodies(m map[string]enrichEntry, dir string) bodyHydrateStats {
	var keys []string
	full := 0
	for k, e := range m {
		switch {
		case e.BodyCRC != 0:
			keys = append(keys, k)
		case e.LyricsYRC != "" || e.LyricsTr != "" || e.LyricsRoma != "" || e.PlainLyrics != "":
			full++
		}
	}
	st := bodyHydrateStats{lean: len(keys), full: full}
	if len(keys) == 0 {
		return st
	}
	bodies := make([]*enrichBody, len(keys))
	workers := min(enrichBodyLoadWorkers, runtime.NumCPU(), len(keys))
	next := make(chan int)
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range next {
				bodies[i] = readEnrichBody(filepath.Join(dir, decisionSidecarName(keys[i])))
			}
		}()
	}
	for i := range keys {
		next <- i
	}
	close(next)
	wg.Wait()

	for i, k := range keys {
		e := m[k]
		want := e.BodyCRC
		e.BodyCRC, e.BodyFields = 0, 0
		switch b := bodies[i]; {
		case b == nil:
			st.missing++
			if len(st.missingKeys) < 3 {
				st.missingKeys = append(st.missingKeys, k)
			}
		default:
			e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics = b.Lyrics, b.LyricsTr, b.LyricsRoma, b.LyricsYRC, b.PlainLyrics
			if b.CRC == want {
				st.restored++
			} else {
				st.newer++
			}
		}
		m[k] = e
	}
	return st
}

// readEnrichBody 读一份正文小文件,自洽才返回(读不到、解不开、校验值对不上内容都是 nil)。
func readEnrichBody(path string) *enrichBody {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var b enrichBody
	if json.Unmarshal(data, &b) != nil || b.CRC == 0 {
		return nil
	}
	got := enrichBodyCRC(enrichEntry{Lyrics: b.Lyrics, LyricsTr: b.LyricsTr, LyricsRoma: b.LyricsRoma,
		LyricsYRC: b.LyricsYRC, PlainLyrics: b.PlainLyrics})
	if got != b.CRC {
		return nil
	}
	return &b
}
