// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
)

// 「配置搬家」带过来的 enrich 缓存非歌词字段,在这里被采纳进缓存(2026-09-02)。
//
// ## 为什么需要这一步
//
// 歌词库备份 sidecar(`Lyrimuse-Lyrics-*.json.z`)此前只带 `lyrics/` 文件族 —— 那是歌词
// 六字段(正文/译文/罗马音/逐字/来源/人工标记)的权威源,`importLyricsFromFiles` 会把它们
// 灌回缓存。当时的判断是"缓存里其余字段都是可重新解析的派生数据",但这条对几类东西
// **不成立**,用户实测撞上(原话「在另外电脑导入了配置,但是并没有把歌曲的决策解析给
// 带过来」):
//
//   - `lyrics_decision` / `lyrics_decision_applied`:记的是**当时那一轮**各源分别给了什么、
//     得了多少分,是历史快照。重新解析只会写一份今天的,「解析决策」里的证据链就断了。
//   - `plain_lyrics` / `plain_lyrics_source`:用户手点「采纳为静态文本」的结果。没有时间戳,
//     不属于四种歌词后缀,压根没有对应的导出文件 —— 此前**不在任何备份里**。
//   - `manual_pick_sha`:手动选定后锁定的追溯凭据。同样没落文件,丢了之后
//     ManualPickLock 把这首歌算成"从没手动选过",锁不上而且完全静默。
//   - `lyrics_scoring_version`:丢了读成 0、落后于当前打分版本,`needsLyricsRescore` 会把
//     **全库**排进"按新规则重选一次"的队列 —— 赢家一变就把刚恢复的正文换掉,连带单曲
//     校正值的内容指纹一起失效(只有 manual_lyrics 和 pins 名单挡得住)。
//
// 所以现在 sidecar 里多带一份"整份缓存剥掉那六个歌词字段"的 JSON(Swift 侧
// `LyricsBackupArchive.strippedMeta`),恢复时落成这份待采纳文件,由这里合并。
//
// ## 为什么是"落文件 + 启动时采纳",不是恢复时直接盖缓存
//
// collector 内存里握着整份缓存、有七处会整份写回磁盘 —— 在外面盖 `-enrich-cache.json`
// 大概率被它整份盖回去(2026-08-14「清空了又回来」)。交给 collector 自己在启动路径里合并,
// 跟 `importLyricsFromFiles` 同一个时机、同一把 enrichMu 锁,天然没有竞态。

// enrichRestoreSuffix 是采纳完之后给这份文件改的名。
//
// ⚠️ 刻意**不删**:这是用户换机器时唯一一份"决策数据"的落地副本,而 saveEnrichCache 没有
// 错误返回(内部只 log),这里无法确证"已经安全落盘"。改名既保证不会被下次启动重复采纳
// (下面只认精确文件名),又留一条人工找回的路 —— 9.7 MB 躺在 43 MB 的缓存旁边,代价可以忽略。
// 同名会被覆盖,所以最多只留一份。
const enrichRestoreSuffix = ".applied"

// adoptEnrichRestore 把待采纳文件合并进 enrichCache。
//
// ⚠️ 调用时机(见 main.go 的调用点):必须排在 loadEnrichCache **之后**(要有 enrichPath 才
// 落得了盘)、migrateEnrichKeys **之前**(备份里的 key 是导出那台机器当时的写法,得跟着一起
// 归一化)、importLyricsFromFiles **之前**(那一步负责让 lyrics/ 文件族赢下六个歌词字段)。
//
// 合并粒度是**字段级**,不是整条替换:先把本机那条序列化成 map,再用备份里出现过的字段
// 逐个盖上去。两个后果都是刻意的 ——
//   - 备份里**没有**的字段(含那六个歌词字段,Swift 侧已剥掉)保持本机的值不动,所以既不会
//     把刚从文件导进来的正文清掉,也不会把本机已经解析出来、而备份里没有的东西弄丢;
//   - 备份里**有**的字段一律赢 —— 用户点的是"恢复",期待的是回到备份里那个样子。
func adoptEnrichRestore(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return // 不存在是绝大多数情况(没在搬家),不是错误
	}
	var incoming map[string]map[string]json.RawMessage
	if err := json.Unmarshal(data, &incoming); err != nil {
		// 解不出来就**原样留着**:这份文件是用户搬家时的决策数据,删掉等于替他做了
		// "反正也用不上"的决定。留着还能人工看/修。
		log.Printf("enrich restore: %s 解析失败,原样保留不采纳: %v", filepath.Base(path), err)
		return
	}

	enrichMu.Lock()
	created, mergedInto, skipped := 0, 0, 0
	for key, fields := range incoming {
		if key == "" || len(fields) == 0 {
			skipped++
			continue
		}
		// 本机那条(可能不存在)→ 字段 map。json tag 上普遍带 omitempty,所以零值字段
		// 压根不会出现在这份 map 里,下面的覆盖天然是"并集,备份优先"。
		base := map[string]json.RawMessage{}
		if old, ok := enrichCache[key]; ok {
			if b, err := json.Marshal(old); err == nil {
				_ = json.Unmarshal(b, &base)
			}
			mergedInto++
		} else {
			created++
		}
		for field, raw := range fields {
			base[field] = raw
		}
		// 回到结构体。⚠️ 结构体里没声明的字段在这一步被 encoding/json 丢掉 —— 跟缓存本身
		// 每次落盘的行为完全一致(见 enrich.go 里 PlainLyrics 那段注释),不是这里新引入的
		// 损耗:备份是从同一个结构体序列化出来的,除非两台机器版本差着字段。
		merged, err := json.Marshal(base)
		if err != nil {
			skipped++
			continue
		}
		var e enrichEntry
		if err := json.Unmarshal(merged, &e); err != nil {
			skipped++
			continue
		}
		enrichCache[key] = e
	}
	if created+mergedInto > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	saveEnrichCache() // 内部自己取 enrichMu,必须在解锁之后调

	applied := path + enrichRestoreSuffix
	if err := os.Rename(path, applied); err != nil {
		// 改名失败的后果是下次启动会再采纳一遍。重复采纳本身是幂等的(同样的字段盖成
		// 同样的值),唯一的偏差是"这台机器在两次启动之间新解析出来的字段会被备份里的
		// 旧值再盖一次" —— 所以要吵一声,别让它无声地长期存在。
		log.Printf("enrich restore: 采纳完了但改名失败(下次启动会重复采纳一遍): %v", err)
	}
	log.Printf("enrich restore: 采纳 %d 条(新建 %d、并入 %d、跳过 %d),文件改名为 %s",
		created+mergedInto, created, mergedInto, skipped, filepath.Base(applied))
}
