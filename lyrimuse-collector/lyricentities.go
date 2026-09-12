package main

import (
	"html"
	"log"
	"regexp"
	"strings"
)

// 歌词正文里的 HTML / XML 字符实体(2026-09-09 用户报 Prince《Free》的灵动岛歌词里满屏
// `they&apos;re` 这种"乱码")。
//
// 这是歌词源自己数据库里的脏数据,不是我们转义链路的 bug(json 解码早就正常完成了)。全库
// 核实(4145 条缓存,按 lyrics_source 分组数实体):酷狗 1695 条里 11 条命中——`&apos;` 382 处、
// `&quot;` 6、`&amp;` 4,全是英文老歌 + 少数国语歌,整行歌词与逐字(KRC)两轨**同样**带着;网易云
// 1203 条里 1 条 `&nbsp;`(Chaka Khan《Fool's Paradise》"Whoa&nbsp;?");QQ 842 / Musixmatch 190 /
// LRCLIB 74 / AMLL 16 零命中。`&apos;` 连 HTML4 都不认(它是 XML 预定义实体),说明是上传端某个
// XML 工具链把整份词转义了一遍就这么入库了。
//
// 决策 #34(网易云 `\'`)那次刻意只做定点替换、不做通用清洗器,理由是"命中面就一种组合,做通用
// 反而可能误吃真实歌词"。这次不同:①第二个源、四种实体、还带 XML 味的 `&apos;`,再定点替换等于
// 每出一种加一行;②字符实体本身是有精确语法的编码(`&名字;` / `&#十进制;` / `&#x十六进制;`),
// 按语法认、只解标准库认识的实体名,不存在"误吃真实歌词"的开放性——下面三条边界把它收得比
// 裸 html.UnescapeString 严得多。
//
// 三条边界(单测 lyricentities_test.go 逐条钉着):
//   - **只认带分号收尾的实体**。html.UnescapeString 按 HTML5 规范会把 `&amp` `&lt` `&not` `&copy`
//     这些**不带分号的遗留实体**也解掉——歌词里 "Q&A" "R&B" "rock&roll" 后面紧跟字母的写法
//     不少,"&notice" 会被它咬成 "¬ice"。所以先用正则圈出 `&…;` 整段,再只对这一段调标准库。
//   - **不认识的实体名原样保留**(标准库解不动就是原样,比如 "R&B;")。
//   - **解出来是控制字符的不换**(`&#10;` 之类会把 LRC 一行拆成两行、把行结构打乱);`&nbsp;`
//     (以及 `&#160;` 等一切解成 U+00A0 的)换成**普通空格**而不是 NBSP——它在源里就是编辑器塞的
//     一个空格,留 NBSP 只会让换行 / 跑马灯 / 指纹归一化多一种空白要认。
//
// 只解**一层**:`&amp;apos;` 解成 `&apos;` 就停(正则匹配完 `&amp;` 之后从它后面继续扫,不回头)。
// 幂等性靠调用方保证——每份文本只在一个门口解一次,见 decodeLyricSourceEntities / migrateLyricEntities。
var lyricEntityRe = regexp.MustCompile(`&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});`)

// decodeLyricEntities 把一段歌词文本里的字符实体还原成字符。没有 `&` 的文本零分配直接返回
// (全库 99.7% 的歌词走这条早退)。
func decodeLyricEntities(s string) string {
	if !strings.Contains(s, "&") {
		return s
	}
	return lyricEntityRe.ReplaceAllStringFunc(s, func(m string) string {
		u := html.UnescapeString(m)
		if u == m {
			return m // 标准库不认识的实体名(歌词里的 "R&B;" 之类),原样留下
		}
		if u == "\u00a0" {
			return " "
		}
		for _, r := range u {
			if r < 0x20 || r == 0x7f {
				return m // 控制字符不该出现在歌词里,宁可原样留着也不要把行结构打乱
			}
		}
		return u
	})
}

// decodeLyricSourceResultEntities 对一路源应答里**所有**歌词文本字段过一遍 decodeLyricEntities,
// 返回副本(lyricSourceResult 是值类型,改的是拷贝)。九个源一视同仁:实体是编码层面的东西,
// 哪个源的 JSON / XML / KRC 里带着都一样该解;今天没命中的源不代表明天不会。
//
// 不动 matchTitle / matchArtist / matchAlbum:那是各源搜索接口给的曲目元信息,全库决策存档
// (lyrics_decision 里每条候选的 title / artist / album)零命中,而且它们参与标题 / 歌手比对,
// 不该在这里顺手改。
func decodeLyricSourceResultEntities(r lyricSourceResult) lyricSourceResult {
	r.lyr = decodeLyricEntities(r.lyr)
	r.yrc = decodeLyricEntities(r.yrc)
	r.tr = decodeLyricEntities(r.tr)
	r.roma = decodeLyricEntities(r.roma)
	r.ne.Lyrics = decodeLyricEntities(r.ne.Lyrics)
	r.ne.Trans = decodeLyricEntities(r.ne.Trans)
	r.ne.Roma = decodeLyricEntities(r.ne.Roma)
	r.ne.YRC = decodeLyricEntities(r.ne.YRC)
	r.amll.lrc = decodeLyricEntities(r.amll.lrc)
	r.amll.yrc = decodeLyricEntities(r.amll.yrc)
	r.amll.tr = decodeLyricEntities(r.amll.tr)
	return r
}

// decodeLyricSourceEntities 是 rankLyricSourceResults 的第一步:把这一轮各源原始应答里的歌词
// 文本全部解一遍,返回**新** map、不改调用方那份。两个理由:
//   - fetchScoredLyricCandidatesStreaming 每来一个源就拿**同一份** raw 全量重跑一次 rank,原地
//     改的话同一段文本会被解好几遍(`&amp;apos;` 第二遍就变成 `'`,不再是"只解一层");
//   - 回归金标集(lyricSourceResultTap → testdata/lyricsgolden)固化的是各源**原始**应答,回放
//     时同样走 rank、在这里解——跟生产同一条路,而不是把解过的文本当原始应答存进样本。
//
// 放在 rank 这一个门口而不是九个源各自的适配器里:候选、决策存档、「搜索候选歌词」弹窗的预览、
// 手动采纳写进缓存的正文,全部从 rank 的产物里来,一处解完下游全干净。
func decodeLyricSourceEntities(raw map[string]lyricSourceResult) map[string]lyricSourceResult {
	out := make(map[string]lyricSourceResult, len(raw))
	for k, r := range raw {
		out[k] = decodeLyricSourceResultEntities(r)
	}
	return out
}

// migrateLyricEntities 对**存量** enrich 缓存跑一遍 decodeLyricEntities(五个歌词文本字段:
// lyrics / lyrics_tr / lyrics_roma / lyrics_yrc / plain_lyrics)。rank 那道门只管新抓取的;
// 已经落盘的那 12 条(见文件头)不靠它就要等下次重新解析才自愈——而这些歌多半早就锁定 /
// 有 pin,根本不会再解析。
//
// 调用时机(main.go):importLyricsFromFiles 之后(lyrics/ 文件夹赢完,改的才是权威内容)、
// exportLyricsFiles 之前(修完由 export 把干净的正文写回导出文件);也必须在
// migrateManualPickMarks 之前(那一步按最终正文算指纹)。形态照抄 migrateYRCWhitespaceTokens。
// 幂等:解过一遍的正文不再含实体,再跑是空操作。
//
// 不跳过 manual_lyrics:跟 migrateYRCWhitespaceTokens 同一口径——这是无损的格式规范化(词一个
// 不变,只是把编码还原),不是自愈路径换内容;用户锁住的正是那份词,`they&apos;re` 显示成
// `they're` 是他要的。手动选定留痕 manual_pick_sha 同理:改前跟正文对得上的,改后按新正文重算,
// 否则这一步会把用户「选过、还是他选的那份」的歌无声改判成「已被换掉」(ManualPickLock.state)。
//
// 已知代价(接受,08 章早有结论):App 侧单曲时间轴校正值的 key 含 lyrics+yrc 的内容指纹,正文
// 一变旧值就查不到——跟 rescore / 重挂时间轴 / 空白词条清洗改正文时一样,受影响的歌要重调一次。
func migrateLyricEntities() {
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		lyrics := decodeLyricEntities(e.Lyrics)
		tr := decodeLyricEntities(e.LyricsTr)
		roma := decodeLyricEntities(e.LyricsRoma)
		yrc := decodeLyricEntities(e.LyricsYRC)
		plain := decodeLyricEntities(e.PlainLyrics)
		if lyrics == e.Lyrics && tr == e.LyricsTr && roma == e.LyricsRoma && yrc == e.LyricsYRC && plain == e.PlainLyrics {
			continue
		}
		if e.ManualPickSHA != "" && e.ManualPickSHA == manualPickFingerprint(e.Lyrics) {
			e.ManualPickSHA = manualPickFingerprint(lyrics)
		}
		e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics = lyrics, tr, roma, yrc, plain
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		// 必须显式置脏,否则 saveEnrichCache 是空操作——同 migrateLyricTimelines 里那条
		// 2026-09-01 实测坐实的潜伏 bug。
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("lyric entity migration: decoded HTML entities in %d entries", fixed)
		saveEnrichCache()
	}
}
