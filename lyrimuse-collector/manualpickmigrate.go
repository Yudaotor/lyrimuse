package main

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"strings"
)

// manualPickFingerprint 必须跟 Swift 侧 LyrimuseCore/ManualPickLock.fingerprint **逐字节
// 一致**:这边写进缓存的指纹,是那边在"开关打开时要不要锁这首歌"里拿去比对的。两边漂开
// 的后果是静默的——老用户打开开关,一首都锁不上,而且没有任何迹象说明为什么。
//
// 口径:先把 LRC 归一化成"只剩词"(见 manualPickCanonicalLyrics),再取 SHA256 小写十六进制
// 前 12 位;归一化后为空时给空串(而不是空串的哈希,否则两首都没歌词的歌会互相匹配)。
// TestManualPickFingerprintMatchesSwift 用一组金标准值把两边钉在一起,Swift selftest 里有
// 同样输入、同样期望的一条。
//
// ⚠️ **不含时间戳、不含 YRC**,这不是省事而是要害:collector 启动时的几道规范化
// (migrateYRCWhitespaceTokens 重排逐字词条、migrateLyricTimelines 重挂行时间轴)会在采纳
// 之后的几秒内改写内容,对原始字节取指纹的话当场失配、开关一首都锁不上,而且完全静默。
// 完整来龙去脉见 Swift 侧 ManualPickLock.fingerprint 的头注。
func manualPickFingerprint(lyrics string) string {
	canonical := manualPickCanonicalLyrics(lyrics)
	if canonical == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(canonical))
	return hex.EncodeToString(sum[:])[:12]
}

// manualPickCanonicalLyrics 逐行剥掉开头所有 `[...]` 方括号组(行时间戳,以及
// [ti:]/[ar:]/[al:]/[by:]/[offset:] 这些元数据标签)、去掉首尾空白、丢掉空行。
//
// 必须跟 Swift 侧 ManualPickLock.canonicalLyrics 逐字节一致。空白判定两边都取 Unicode
// 全集(这里的 strings.TrimSpace / 那边的 .whitespacesAndNewlines),CRLF、NBSP 也一致。
func manualPickCanonicalLyrics(lyrics string) string {
	var b strings.Builder
	for _, raw := range strings.Split(lyrics, "\n") {
		line := strings.TrimSpace(raw)
		// 一行可能挂多个时间戳(`[00:12.00][00:45.00]同一句`),逐个剥。
		for strings.HasPrefix(line, "[") {
			end := strings.Index(line, "]")
			if end < 0 {
				break
			}
			line = strings.TrimSpace(line[end+1:])
		}
		if line == "" {
			continue
		}
		if b.Len() > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(line)
	}
	return b.String()
}

// migrateManualPickMarks 把存量的 lyrics_source_choice 转成新的「手动选定」留痕
// manual_pick_sha,并清掉这个已被推翻的旧字段。一次性迁移,幂等(转完源字段就空了)。
//
// # 为什么需要它
//
// 2026-09-01 加的「手动选定歌词后锁定」开关,打开时要追溯锁定"用户手动选过的歌",判据是
// manual_pick_sha —— 而这个字段是当天才有的。对**已经装着 v1.4.0 的用户**来说,他们历史
// 上通过「采纳候选」选过的歌一条留痕都没有,打开开关会得到"还没有手动选定过歌词" ——
// 对他们这是**假话**,他们明明选过。
//
// lyrics_source_choice 正好是那段历史唯一的证据:它 2026-08-22 上线(commit d0296db)、
// v1.4.0 在 08-24 打的 tag,所以线上用户缓存里确实有;而它的**唯一写入方**就是那两个
// 「采纳候选」调用点,非空即"用户手动采纳过这首歌",不会误判。
//
// # 迁移规则与取舍
//
//   - 只在 lyrics_source != lyrics_source_choice 时**不**写标记:当前这份内容已经不是他
//     选的那个源给的了(他后来禁用了那个源,或走了别的路径),按新语义就不该算"他选的那份"。
//   - 已经 manual_lyrics 的不写标记:它本来就是锁着的,不需要靠开关去锁;更要紧的是,
//     manual_pick_sha 同时也是"关掉开关时可以解锁"的凭据,给一条已锁的记录补上它,等于
//     让它变得可被批量解锁 —— 而 manual_lyrics 这一个标记**分不出**"08-22 之前采纳候选
//     锁的"和"手改过正文锁的",后者一旦被解开,那份删了就找不回来的内容就重新暴露给自动
//     覆盖。不解锁只是少做一件事,误解锁是不可逆的损失,保守是对的。
//   - 精度上的一处诚实交代:如果这首歌在采纳之后被**同源升级**过(那正是 lyrics_source_choice
//     当初的设计意图——约束在源内但允许升级),这里记下的是升级**后**的内容指纹,严格说
//     不是"他当初点的那一份"。接受:用户表达的意图是"这首歌我要这个源的词",当前内容满足
//     这个意图,开关打开时锁住它就是他想要的。
//   - lyrics_source_choice 一律清掉(哪怕这条没写标记):这个"只约束源"的中间态已经被用户
//     否掉,留着它 collector 仍会把重选约束在那个源内 —— 那是一道用户没要过、界面上又几乎
//     看不见的隐形约束。清掉 = 把旧语义换成新语义,而不是两套并存。
//
// # 调用时机
//
// ⚠️ 必须排在 importLyricsFromFiles / migrateYRCWhitespaceTokens / migrateLyricTimelines
// **之后** —— 那三步都会重写 Lyrics/LyricsYRC,在它们之前算指纹的话,写下的指纹当场就
// 过期了,老用户打开开关照样一首都锁不上(而且同样是静默的)。见 main.go 的调用点。
func migrateManualPickMarks() {
	enrichMu.Lock()
	marked, cleared := 0, 0
	for k, e := range enrichCache {
		if e.LyricsSourceChoice == "" {
			continue
		}
		choice := e.LyricsSourceChoice
		e.LyricsSourceChoice = ""
		cleared++
		// 已经有留痕的不覆盖:那是 App 侧新写的,比这里从旧字段推断出来的更权威。
		// 指纹为空(正文只剩元数据标签、归一化后没有词)时不写:空标记等于"没有留痕",
		// 写进去只会让缓存里多一个永远匹配不上的空字段。
		if sha := manualPickFingerprint(e.Lyrics); sha != "" &&
			e.ManualPickSHA == "" && !e.ManualLyrics && e.LyricsSource == choice {
			e.ManualPickSHA = sha
			marked++
		}
		enrichCache[k] = e
	}
	enrichMu.Unlock()
	if cleared > 0 {
		log.Printf("manual pick migration: converted %d/%d legacy lyrics_source_choice entries into manual pick marks",
			marked, cleared)
		saveEnrichCache()
	}
}
