package main

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"reflect"
	"strings"
	"sync"
)

// enrichEntry 的 JSON 编解码:**保留这个二进制不认识的键**。
//
// 为什么需要(2026-09-05,真实事故):enrich 缓存是一份 map[string]enrichEntry 整体
// json.Marshal/Unmarshal 的文件,而写它的不止常驻 collector 一个——search-lyrics -pick /
// resync-lyrics / backfill-roma / recheck-cover 这些一次性子命令,以及 Swift 侧的"歌词管理",
// 都会整份读进来、改几条、整份写回。Go 这一侧只要跑的二进制比文件里的字段老(结构体里还
// 没声明某个键),标准库 Unmarshal 就把那个键丢在地上,下一次 Marshal 自然没有它。
// 09-03 10:15 一次 `backfill-roma -apply` 正是这样把 08-31 之后新加的 plain_lyrics /
// plain_lyrics_source / song_language / manual_pick_sha 在 1082 条记录上静默抹掉(同 key
// 同 ts,只是字段少了;对照 backup-pre-backfill-roma-20260903-101525 里的那份能一条条对上)。
// 在此之前 PlainLyrics 字段本身的注释就记着同一类担心("不声明就会被 Go 冲掉"),当时的
// 解法是追着把 Swift 写的键一个个声明进结构体——那只防"字段没声明",防不住"字段声明了但
// 跑的是老构建"。这里改成通用的:未知键原样进 enrichEntry.Unknown,写回时原样带上。
//
// 两条实现取舍:
//   - 解码走两档。先用 DisallowUnknownFields 严格解一次——二进制认识全部字段(日常
//     情况)时一遍就完,零额外开销;只有撞到"unknown field"才退回宽松档,再解一遍原始
//     map 把不认识的键挑出来。缓存 50MB+、每次一次性子命令启动都要整份加载,不能给日常
//     路径无条件加一遍全量二次解析。
//   - 编码只在 Unknown 非空时才做合并(先按结构体编一遍,再解成 map 把未知键补进去、重新
//     编)。已知键永远赢:同名键以结构体字段为准,Unknown 里的旧值不会顶掉本次写入。
//
// 顺带在 loadEnrichCache 里数一下带未知键的记录数,非零就 Warn 一行——那就是"你正在用一个
// 比缓存文件老的构建"的直接信号,比事后对备份找丢了什么字段便宜得多。
//
// 边界(刻意接受):只保**顶层**键。嵌套结构(lyrics_decision 那两个只写不读的决策存档)里
// 的未知键仍按标准库语义丢弃——严格档对嵌套字段同样生效,所以它们也会触发宽松档,只是
// 宽松档不往下钻。决策存档是复盘元数据,丢一个新分项不构成数据丢失;真要保就得把整份
// 存档按 RawMessage 原样搬,不值得为它给热路径加复杂度。

// enrichEntryPlain 是去掉方法集的同构类型:靠它调用标准库的默认编解码,避免在
// MarshalJSON/UnmarshalJSON 里递归到自己。
type enrichEntryPlain enrichEntry

var (
	enrichEntryKnownKeysOnce sync.Once
	enrichEntryKnownKeys     map[string]bool
)

// enrichEntryKnownJSONKeys 从结构体 tag 里算一次"这个二进制认识哪些键"。只看顶层字段、
// 只认显式 json tag(enrichEntry 全部字段都带 tag;`json:"-"` 的不算键)。
func enrichEntryKnownJSONKeys() map[string]bool {
	enrichEntryKnownKeysOnce.Do(func() {
		keys := map[string]bool{}
		t := reflect.TypeOf(enrichEntryPlain{})
		for i := 0; i < t.NumField(); i++ {
			tag := t.Field(i).Tag.Get("json")
			name := strings.Split(tag, ",")[0]
			if name == "" || name == "-" {
				continue
			}
			keys[name] = true
		}
		enrichEntryKnownKeys = keys
	})
	return enrichEntryKnownKeys
}

func (e *enrichEntry) UnmarshalJSON(b []byte) error {
	var p enrichEntryPlain
	strict := json.NewDecoder(bytes.NewReader(b))
	strict.DisallowUnknownFields()
	err := strict.Decode(&p)
	if err == nil {
		*e = enrichEntry(p)
		return nil
	}
	if !strings.Contains(err.Error(), "unknown field") {
		return err
	}
	// 宽松档:标准库自己会跳过不认识的键,再从原始 map 里把它们捞出来。
	p = enrichEntryPlain{}
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	known := enrichEntryKnownJSONKeys()
	for k, v := range raw {
		if known[k] {
			continue
		}
		if p.Unknown == nil {
			p.Unknown = map[string]json.RawMessage{}
		}
		p.Unknown[k] = v
	}
	*e = enrichEntry(p)
	return nil
}

func (e enrichEntry) MarshalJSON() ([]byte, error) {
	b, err := json.Marshal(enrichEntryPlain(e))
	if err != nil || len(e.Unknown) == 0 {
		return b, err
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	for k, v := range e.Unknown {
		if _, taken := m[k]; taken {
			continue // 已知键(或本次刚写的)为准,未知里的同名旧值不顶替
		}
		m[k] = v
	}
	return json.Marshal(m)
}

// enrichEntriesWithUnknownKeys 数出带未知键的记录数,给 loadEnrichCache 打那一行 Warn。
func enrichEntriesWithUnknownKeys(m map[string]enrichEntry) int {
	n := 0
	for _, e := range m {
		if len(e.Unknown) > 0 {
			n++
		}
	}
	return n
}

func warnEnrichUnknownKeys(m map[string]enrichEntry) {
	if n := enrichEntriesWithUnknownKeys(m); n > 0 {
		slog.Warn("enrich cache: entries carry fields this build does not know, preserving them verbatim (older build than the cache file?)", "entries", n)
	}
}
