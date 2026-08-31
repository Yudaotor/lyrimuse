package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
)

// 机器翻译兜底:歌词源自带社区译文时一律用社区译文,没有才拿 MyMemory 机翻补上。
//
// 为什么需要:lyrics_tr 目前只在网易云/Musixmatch 恰好带社区翻译时才有。实测本机缓存
// 179 条有歌词的记录里带译文的 40 条(22%),而"歌词里没有中文"的外语歌 32 条里带译文的
// 只有 1 条 —— 也就是听英文/日文歌时 97% 看不到翻译,恰恰是最需要翻译的场景。
//
// 为什么是 MyMemory:免费、不需要 API key(可选传邮箱提额),而且实测日译中/英译中的质量
// 对"看个大意"这个用途够用:
//
//	君のことが好きだから      → 因为我喜欢你
//	The painful youth I've had → 我经历过的痛苦的青春
//
// 译文沿用**主歌词自己的时间戳**逐行生成,不另求时间轴 —— 天然逐行对齐,比社区译文各自
// 带一套时间戳还准(播放端是按最近时间戳配对的,见 LyricsSyncEngine.nearestText)。
const (
	// MyMemory 单次请求的硬上限,实测超了直接 403:
	// "QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS"。
	// 留 40 字符余量给换行和 URL 编码的波动。
	translateMaxChunkChars = 460
	// 一首歌最多切这么多块。整首歌约 1500 字符 ≈ 4 块;给到 12 块(≈5500 字符)足够覆盖
	// 长歌,再多就不是歌词了,拒掉免得一首歌把当天配额吃光。
	translateMaxChunks = 12
	// 源语言跟目标语言相同时 MyMemory 不报错,而是把这句**当作译文返回** —— 不识别就会
	// 让中文歌的译文栏显示 "PLEASE SELECT TWO DISTINCT LANGUAGES"。
	translateSameLangSentinel = "PLEASE SELECT TWO DISTINCT LANGUAGES"
	// 当天配额用尽时 MyMemory **不是**把 quotaFinished 置真,而是回一个 HTTP 429 + 这句
	// 警告文本(实测:"MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR
	// TODAY. NEXT AVAILABLE IN 15 HOURS...")。只认 quotaFinished 会把它当成普通失败,
	// 白烧一次重试次数 —— 三次烧完这首歌就再也不会被翻了。
	translateQuotaSentinel = "ALL AVAILABLE FREE TRANSLATIONS"
)

var lrcLinePattern = regexp.MustCompile(`^\s*(\[\d+:\d+(?:[.:]\d+)?\])\s*(.*)$`)

type lrcLine struct {
	tag  string // 含方括号的时间标签,如 "[00:20.94]"
	text string
}

// parseLRCLines 只留带时间标签、且正文非空的行。`[by:]`/`[ar:]` 这类元信息标签不匹配
// 时间戳格式,自然被丢掉 —— 它们不该被翻译,也不该占一行译文。
func parseLRCLines(lrc string) []lrcLine {
	var out []lrcLine
	for _, raw := range strings.Split(lrc, "\n") {
		m := lrcLinePattern.FindStringSubmatch(raw)
		if m == nil {
			continue
		}
		if text := strings.TrimSpace(m[2]); text != "" {
			out = append(out, lrcLine{tag: m[1], text: text})
		}
	}
	return out
}

// chunkForTranslation 按 translateMaxChunkChars 把行分组,**不拆行** —— 一行必须完整地
// 待在一个块里,否则回来的译文没法跟行对上。单行本身就超长(理论上不会,歌词一行几十字)
// 时单独成块,交给上层按"行数对不上就整块作废"处理。
func chunkForTranslation(texts []string) [][]string {
	var chunks [][]string
	var cur []string
	curLen := 0
	for _, t := range texts {
		n := len(t) + 1 // +1 是拼接用的换行
		if len(cur) > 0 && curLen+n > translateMaxChunkChars {
			chunks = append(chunks, cur)
			cur, curLen = nil, 0
		}
		cur = append(cur, t)
		curLen += n
	}
	if len(cur) > 0 {
		chunks = append(chunks, cur)
	}
	return chunks
}

// 【已删除】looksLikeTargetLanguage(2026-08-23)
//
// 它做的是"整首歌是不是已经就是目标语言,是的话整个跳过"。判据是 looksChinese ——
// 汉字占多数就算中文,而且注释明确写着"中英混排的华语歌也应该判成中文"。
//
// 那句话对**它原本要判的东西**是对的:looksChinese 是用来认"已有译文是什么语言"的
// (translationUsable 里那三处),一份中英混排的中文译文当然算中文译文。
// 但用它来判"正文要不要翻"就错了 —— 华语歌里整行英文的副歌很常见,
// 《方大同 - 月亮代表我的心》44 行里 35 行中文、8 行 "It represent my heart!",
// 汉字占多数 ⇒ 判成"已经是中文" ⇒ 整首跳过,那 8 行英文永远等不到译文
// (2026-08-23 用户报的就是这个)。
//
// 两处调用都删了,改由**逐行**判定接管:
//   - needsTranslationBackfill 靠 anyLineNeedsTranslation(有任何一行需要翻才起 goroutine,
//     省配额的意图一样达到,而且更准);
//   - machineTranslateLRCWithBase 内部本来就是逐行挑行、翻完按下标散回去的
//     (没送去翻的行留空串),那套逻辑一直是对的,只是被这道整首闸挡在门外没机会跑。
// 逐行判据是 dominantScript:「我们的时光 baby 一起走过」主体是汉字 ⇒ 不翻;
// 「It represent my heart!」主体是拉丁 ⇒ 翻。行内混排和整行外语,这才分得开。

// looksChinese 判断一段文本是不是中文。只认中文这一种语言 —— 判别只是个兜底,用在
// 没记语言的老条目上,而"是不是中文"恰好是唯一需要判、也判得准的一种(会自带译文的
// 两个源里,网易云固定给中文)。
func looksChinese(text string) bool {
	var han, letters int
	for _, r := range text {
		switch {
		case unicode.Is(unicode.Han, r):
			han++
		case unicode.IsLetter(r):
			letters++
		}
	}
	// 汉字占"有意义字符"的多数就当成中文。中英混排的华语歌(常见)也应该判成中文,
	// 所以阈值不设成"完全没有拉丁字母"。
	return han > 0 && han >= letters
}

// translationUsable 判断一条已有的译文对**当前**的目标语言还算不算数。
//
// 这是这次改动的核心。原来的判断是"有译文就跳过",于是一首网易云歌词一旦带上它那份
// 固定中文的社区译文,把设置改成日语的用户就永远只能看到中文 —— 机翻根本没机会跑。
// 而降低网易云/QQ 的打分并不能解决这件事:打分里压根没有"有译文"这一项(见
// scoreLyricCandidate),译文不参与选源;降分只会把原文歌词的质量一起赔进去。
func translationUsable(e enrichEntry, target string) bool {
	if e.LyricsTr == "" {
		return false
	}
	// ⚠️ 记的语言跟正文自相矛盾时,以**正文**为准 —— 标签会骗人,正文不会。
	//
	// 2026-08-09 实测抓到:App 侧"采纳候选/手改译文"那条路(EnrichCacheStore.saveEdit)
	// 只写 lyrics_tr,不动 lyrics_tr_lang / lyrics_tr_source。于是采纳一份网易云的中文
	// 社区译文之后,语言标签还留着上一轮机翻写的 "en",这道门一看"语言 en、目标 en"就放行,
	// 机翻永远不会再接手 —— 用户把译文语言选成英文,却永远只看到中文。那条写入路径已经
	// 修好,但这里也要挡一层:这是唯一消费 LyricsTrLang 的地方,把不变式钉在这里,既能自愈
	// 已经写坏的老条目,也不指望以后每一个写入方都记得同步这两个字段。
	lang := e.LyricsTrLang
	if lang != "" && !strings.HasPrefix(strings.ToLower(lang), "zh") && looksChinese(e.LyricsTr) {
		lang = "" // 标签说不是中文、正文明明是中文 → 当作语言不详,走下面的文本判别
	}
	if lang != "" {
		return myMemoryLangCode(lang) == target
	}
	// 语言不详(老条目,或用户手改过 lyrics/ 里的译文):只在能确定的方向上下判断。
	if strings.HasPrefix(strings.ToLower(target), "zh") {
		// 目标是中文:看着是中文才算数。
		return looksChinese(e.LyricsTr)
	}
	// 目标不是中文:看着是中文的一定用不上(网易云那份就是这种);其余判不出来,保守
	// 当作算数 —— 宁可留着一份可能本来就对的社区译文,也不要平白重翻一遍。
	return !looksChinese(e.LyricsTr)
}

type translationResult struct {
	lrc          string
	quotaReached bool
}

// machineTranslateLRC 把主歌词逐行机翻成 target 语言,返回一份跟主歌词同时间戳的译文 LRC。
// 返回空串表示"这次没有译文"(已经是目标语言/一行都没翻成/配额用尽),不是错误。
// translateBaseURL 为空时走 MyMemory 正式端点。留这个包级变量是为了让测试能把
// backfillTranslation **整条**路径(翻译 → 写缓存 → 落盘)跑起来,而不是只能测中间那段。
var translateBaseURL string

func machineTranslateLRC(ctx context.Context, hc *http.Client, lyrics, target string) (translationResult, error) {
	return machineTranslateLRCWithBase(ctx, hc, translateBaseURL, lyrics, target)
}

// ── 逐行按文字系统分流 ───────────────────────────────────────────────────────
//
// 2026-08-10 实测坐实的真 bug:宇多田ヒカル 的 First Love 是**日英混排**(主歌日文、
// 副歌整段英文),译文目标选英文时,两个后端对**整批文本**做语种识别都判成"英文",于是
//
//	on-device helper: {"ok":false,"source":"en","reason":"same-language"}
//	MyMemory:         "PLEASE SELECT TWO DISTINCT LANGUAGES"
//
// 前者退成"不可用"、后者直接报错,一路走到 TranslationRetryCount++;攒够 3 次之后这首歌
// **永久**不再尝试。用户看到的就是"明明选了英文译文,这首歌一句译文都没有",而它那些日文
// 行显然是需要翻的。
//
// 修法:送去翻之前先逐行看文字系统,只把"跟目标语言不是同一套文字"的行送过去 —— 副歌那些
// 英文行本来就不需要译文(assembleTranslationLRC 也早就会跳过"没翻动"的行),剩下的日文行
// 单独成批,后端识别出来就是日文,两边都能正常工作。
//
// 只分到"翻译上真正有区别"的粒度。源和目标共用同一套文字时(法语歌 → 英文译文)这套判断
// 帮不上忙 —— 但那种情况整批识别本来也会失败,不比现在更糟。
type lyricScript int

const (
	scriptNone lyricScript = iota
	scriptLatin
	scriptHan
	scriptKana
	scriptHangul
	scriptCyrillic
	scriptArabic
	scriptThai
)

// scriptOrder 固定遍历次序 —— 直接遍历 map 求最大值会让"平手"的结果随机,同一行歌词
// 两次跑出不同结论。
var scriptOrder = []lyricScript{
	scriptKana, scriptHangul, scriptHan, scriptCyrillic, scriptArabic, scriptThai, scriptLatin,
}

// dominantScript 返回一行文本里占多数的文字系统;一个字母都没有(纯符号/数字/空)时是
// scriptNone。假名优先于汉字:日文行里汉字常比假名多,但只要出现假名就一定是日文。
func dominantScript(s string) lyricScript {
	counts := map[lyricScript]int{}
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r):
			counts[scriptKana]++
		case unicode.Is(unicode.Han, r):
			counts[scriptHan]++
		case unicode.Is(unicode.Hangul, r):
			counts[scriptHangul]++
		case unicode.Is(unicode.Cyrillic, r):
			counts[scriptCyrillic]++
		case unicode.Is(unicode.Arabic, r):
			counts[scriptArabic]++
		case unicode.Is(unicode.Thai, r):
			counts[scriptThai]++
		case unicode.IsLetter(r):
			counts[scriptLatin]++
		}
	}
	if counts[scriptKana] > 0 {
		return scriptKana
	}
	best, bestN := scriptNone, 0
	for _, k := range scriptOrder {
		if counts[k] > bestN {
			best, bestN = k, counts[k]
		}
	}
	return best
}

// targetScripts 目标语言写出来会用到哪几套文字。
func targetScripts(target string) []lyricScript {
	t := strings.ToLower(strings.TrimSpace(target))
	switch {
	case strings.HasPrefix(t, "zh"):
		return []lyricScript{scriptHan}
	case strings.HasPrefix(t, "ja"):
		return []lyricScript{scriptKana, scriptHan}
	case strings.HasPrefix(t, "ko"):
		return []lyricScript{scriptHangul}
	case strings.HasPrefix(t, "ru"), strings.HasPrefix(t, "uk"):
		return []lyricScript{scriptCyrillic}
	case strings.HasPrefix(t, "ar"):
		return []lyricScript{scriptArabic}
	case strings.HasPrefix(t, "th"):
		return []lyricScript{scriptThai}
	default:
		return []lyricScript{scriptLatin}
	}
}

// lineNeedsTranslation:这一行还需不需要翻成 target。
func lineNeedsTranslation(text, target string) bool {
	s := dominantScript(text)
	if s == scriptNone {
		return false // 纯符号/数字,没什么可翻
	}
	for _, ts := range targetScripts(target) {
		if s == ts {
			return false
		}
	}
	return true
}

// anyLineNeedsTranslation:整首歌里还有没有需要翻的行。给 needsTranslationBackfill 用,
// 免得一首整篇都已经是目标语言的歌反复起 goroutine、白烧三次重试额度。
func anyLineNeedsTranslation(lyrics, target string) bool {
	for _, l := range parseLRCLines(lyrics) {
		if lineNeedsTranslation(l.text, target) {
			return true
		}
	}
	return false
}

// machineTranslateLRCWithBase 是上面那个的可注入版本,baseURL 为空时用 MyMemory 正式端点。
// 单测靠它把整条链路(分块 → 请求 → 行数校验 → 回写时间戳)跑在本地假服务器上。
func machineTranslateLRCWithBase(ctx context.Context, hc *http.Client, baseURL, lyrics, target string) (translationResult, error) {
	if lyrics == "" || target == "" {
		return translationResult{}, nil
	}
	lines := parseLRCLines(lyrics)
	if len(lines) == 0 {
		return translationResult{}, nil
	}
	// 只把"跟目标语言不是同一套文字"的行送去翻,理由见 dominantScript 那一段。
	//
	// 署名行先剔掉(2026-08-23):`[00:02.000] 编曲 : Edward Chan/方大同` 这种行拉丁字母
	// 比汉字多,dominantScript 判成 latin,于是被当歌词送去翻。三个后果:展示端本来就会
	// 用 creditLinePattern 把它过滤掉(白翻)、退到 MyMemory 的机器白烧配额、而且它会拉高
	// 下面 assembleTranslationLRC 的 attempted 分母 —— 署名行占比高的短歌可能因此撞上
	// "written*3 < attempted" 那道阈值、整份译文被判作废。
	//
	// ⚠️ 用 isCreditLineWithSpeakers 而不是 isCreditLine:后者含 genericHanCreditLineRe
	// 那条纯结构正则(短汉字 + 冒号),「男：It represent my heart!」会被它命中 —— 那是
	// 真歌词,剔掉就等于对唱歌的英文行永远没译文。带上这一份的说话人标签当豁免才分得开。
	//
	// 按原文**去重**再送翻(2026-08-26,Michael Jackson《Beat It》实测坐实):副歌反复的歌
	// 逐行独立发请求,同一句"Just beat it (beat it), beat it (beat it)"出现 7 次,翻译
	// 结果对同一份输入**不保证一致**——on-device 的 TranslationSession.Request 逐行互不
	// 知情,7 次里 6 次原样吐回来、只有 1 次真翻了,而 assembleTranslationLRC 那条"翻出来
	// 等于原文就不写进译文栏"的规则会把那 6 次全部悄悄丢掉。歌词越重复,译文看起来就越
	// 支离破碎,却不是网络配额或语言包的问题。
	//
	// occurrences[k] 记录 uniqueTexts[k] 这句话在原文里出现过的**全部**下标——翻完按
	// uniqueTexts 的下标算出结果,一次性广播回它的每一个出现位置,保证同一句话不管重复
	// 几次,结果必然一致(要么都翻、要么都没翻,不会随机命中一两次)。副产品是重复句子只翻
	// 一次:MyMemory 那条网络兜底路的字符配额、on-device 的请求数,两条路都跟着省。
	speakers := lyricSpeakerLabels(lyrics)
	seen := map[string]int{}
	var uniqueTexts []string
	var occurrences [][]int
	totalAttempted := 0
	for i, l := range lines {
		if isCreditLineWithSpeakers(strings.TrimSpace(l.text), speakers) {
			continue
		}
		if !lineNeedsTranslation(l.text, target) {
			continue
		}
		totalAttempted++
		if k, ok := seen[l.text]; ok {
			occurrences[k] = append(occurrences[k], i)
			continue
		}
		seen[l.text] = len(uniqueTexts)
		uniqueTexts = append(uniqueTexts, l.text)
		occurrences = append(occurrences, []int{i})
	}
	if len(uniqueTexts) == 0 {
		return translationResult{}, nil // 整首都已经是目标语言了
	}
	// scatter 把"只翻了一部分"的结果按 uniqueTexts 的下标广播回它在原文里的每一个出现
	// 位置,没送去翻(或没翻成)的行留空串(assembleTranslationLRC 会跳过空串,不会在
	// 译文栏重复一遍原文)。
	scatter := func(out []string) []string {
		full := make([]string, len(lines))
		for k, occ := range occurrences {
			if k >= len(out) {
				break
			}
			for _, i := range occ {
				full[i] = out[k]
			}
		}
		return full
	}
	// 优先端上翻译:不联网、无配额、歌词不出这台机器,而且没有 500 字符的分块限制,
	// 整首歌一次翻完。失败(系统太老/语言包没装/helper 不在)才退到 MyMemory。
	if out, err := onDeviceTranslate(ctx, appleLangCode(target), uniqueTexts); err == nil {
		return assembleTranslationLRC(lines, scatter(out), totalAttempted), nil
	} else if !errors.Is(err, errOnDeviceUnavailable) {
		log.Printf("translate: on-device failed, falling back to network: %v", err)
	}

	chunks := chunkForTranslation(uniqueTexts)
	if len(chunks) > translateMaxChunks {
		return translationResult{}, fmt.Errorf("lyrics too long: %d chunks", len(chunks))
	}

	translated := make([]string, 0, len(uniqueTexts))
	for _, chunk := range chunks {
		out, quota, err := translateChunk(ctx, hc, baseURL, chunk, target)
		if quota {
			return translationResult{quotaReached: true}, nil
		}
		if err != nil {
			return translationResult{}, err
		}
		// 行数对不上就整块作废,用原文占位 —— 错位的译文比没有译文更糟:第 3 行的中文
		// 挂在第 5 行的歌词下面,用户没法察觉是错的,只会觉得翻译很离谱。
		if len(out) != len(chunk) {
			out = chunk
		}
		translated = append(translated, out...)
	}

	return assembleTranslationLRC(lines, scatter(translated), totalAttempted), nil
}

// assembleTranslationLRC 把逐行译文拼回一份跟主歌词同时间戳的 LRC。两条翻译路径(端上
// helper / MyMemory)共用,保证它们产出的形状完全一致。
// attempted 是这次**真正送去翻**的行数(不是整首歌的行数)。下面那道"翻出来太少就当没成"
// 的闸门必须拿它当分母 —— 2026-08-10 起只翻"跟目标语言不同文字"的行,像 First Love 这种
// 日英混排的歌,一半行本来就不需要译文,用总行数当分母会把一份完全正常的译文判成失败。
func assembleTranslationLRC(lines []lrcLine, translated []string, attempted int) translationResult {
	var b strings.Builder
	written := 0
	for i, l := range lines {
		if i >= len(translated) {
			break
		}
		t := strings.TrimSpace(translated[i])
		if t == "" || t == l.text { // 没翻动的行不写进译文,免得译文栏重复一遍原文
			continue
		}
		b.WriteString(l.tag)
		b.WriteString(t)
		b.WriteString("\n")
		written++
	}
	// 太少行翻出来说明这次基本没成 —— 与其给一份七零八落的译文,不如当作没有。
	if attempted <= 0 || written*3 < attempted {
		return translationResult{}
	}
	return translationResult{lrc: strings.TrimRight(b.String(), "\n")}
}

// randomTranslateEmail 每次请求现生成一个邮箱。
//
// MyMemory 的免费额度是**按 de= 里的邮箱分别计**的(匿名约 5000 字符/天,带邮箱约 50000),
// 所以每次换一个就不会被单个地址的日额度卡住 —— 而歌词兜底翻译本来就零零散散、每首几百
// 字符,固定一个地址很容易在听得多的那天用光。
//
// 不让用户自己填:填邮箱这一步对用户毫无收益(纯粹是第三方的计量口径),还要把真实邮箱交给
// 一个只用来翻歌词的服务。
//
// 域名固定 example.com:RFC 2606 保留域,不解析、收不了信,所以随机出来的地址不可能撞上
// 某个真人的邮箱。换成一个真实域名就有这个风险。
func randomTranslateEmail() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand 读不出来基本等于系统出了大问题;退回时间戳也比整个请求发不出去强。
		return fmt.Sprintf("lyrimuse-%d@example.com", time.Now().UnixNano())
	}
	return "lyrimuse-" + hex.EncodeToString(b[:]) + "@example.com"
}

// translateChunk 发一次 MyMemory 请求。第二个返回值为真表示当天配额用尽(调用方应该整体
// 停下,而不是继续把剩下的块也撞上去)。
func translateChunk(ctx context.Context, hc *http.Client, baseURL string, lines []string, target string) ([]string, bool, error) {
	q := neturl.Values{}
	q.Set("q", strings.Join(lines, "\n"))
	// autodetect:实测跟显式指定源语言结果一致,省掉自己做语种识别这一整块。
	q.Set("langpair", "autodetect|"+target)
	q.Set("de", randomTranslateEmail())
	if baseURL == "" {
		baseURL = "https://api.mymemory.translated.net/get"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"?"+q.Encode(), nil)
	if err != nil {
		return nil, false, fmt.Errorf("build request: %w", err)
	}
	resp, err := doHTTPTracked(hc, req)
	if err != nil {
		return nil, false, fmt.Errorf("translate: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		ResponseData struct {
			TranslatedText string `json:"translatedText"`
		} `json:"responseData"`
		ResponseStatus  json.RawMessage `json:"responseStatus"`
		ResponseDetails string          `json:"responseDetails"`
		QuotaFinished   bool            `json:"quotaFinished"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, false, fmt.Errorf("decode translate response: %w", err)
	}
	if body.QuotaFinished ||
		resp.StatusCode == http.StatusTooManyRequests ||
		strings.Contains(strings.ToUpper(body.ResponseDetails), translateQuotaSentinel) {
		return nil, true, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, false, fmt.Errorf("translate status %d: %s", resp.StatusCode, body.ResponseDetails)
	}
	text := body.ResponseData.TranslatedText
	if text == "" || strings.Contains(strings.ToUpper(text), translateSameLangSentinel) {
		return nil, false, fmt.Errorf("no usable translation: %q", body.ResponseDetails)
	}
	return strings.Split(text, "\n"), false, nil
}

var translateClient = &http.Client{Timeout: 15 * time.Second}

// translationBackfillMaxAttempts / translationBackfillInterval:机翻补全的上限与节流。
//
// 这条路径跟 needsPeripheralBackfill / needsLyricsRescore 是同一个范式:只在这首歌被播放
// 时才可能触发,所以这两个数控制的是"最坏情况下一首歌总共会多打几次翻译接口"。3 次足够
// 覆盖偶发网络抖动;间隔 6 小时主要是给"当天配额用尽"留出恢复时间 —— MyMemory 的配额按天
// 重置,几分钟后重试只会再撞一次墙、白烧一次尝试次数。
const (
	translationBackfillMaxAttempts = 3
	translationBackfillInterval    = 6 * time.Hour
)

// invalidateStaleTranslations 把语言跟当前设置对不上的**机翻**译文清掉,让它们下次
// 播放时按新语言重翻。
//
// 为什么需要:needsTranslationBackfill 本来就能判出"记录的语言 != 当前目标"并触发重翻,
// 但那道判断只在**播放到这首歌时**才跑(见 enrich.go 主循环里那串 else if)。于是用户把
// 译文语言从英文改回中文之后,以前听过的歌仍然显示英文译文,直到碰巧再放一次 —— 2026-08-13
// 用户报的就是这个。当时实测本机缓存:12 条语言不匹配,其中 11 条"会在下次播放时重翻",
// 也就是机制在、只是没有触发的机会。
//
// 放在启动时扫一遍正好覆盖这个场景:Swift 侧改完译文语言会重启 collector
// (FeatureSettingsStore.save → CollectorControl.restartAndWaitAsync)。
//
// **只清 lyrics_tr_source == "machine" 的**。歌词源自带的社区译文(网易云/Musixmatch)
// 质量高于机翻,而且清掉之后万一机翻失败(没网/超额),用户就一份译文都没有了;留着它
// translationUsable 照样判它不可用、让机翻覆盖过去,那条路本来就通。
//
// ⚠️ 调用点必须夹在 importLyricsFromFiles() 和 exportLyricsFiles() 之间:前者让磁盘上的
// lyrics/ 文件赢(那是权威源),后者会把这里清空的字段同步成"删掉对应的 .tr.lrc"
// (见 lyricsexport.go 里 content == "" 时的 os.Remove)。顺序错了,清掉的译文会在下次
// 启动被 import 原样导回来。
func invalidateStaleTranslations() {
	target := myMemoryLangCode(features.LyricsTranslationLanguage)
	if target == "" {
		return
	}
	enrichMu.Lock()
	cleared := 0
	for key, e := range enrichCache {
		if e.LyricsTr == "" || e.LyricsTrSource != "machine" {
			continue
		}
		// 语言不详的不动:判不出来就别删,交给 translationUsable 那套文本判别去处理。
		if e.LyricsTrLang == "" || myMemoryLangCode(e.LyricsTrLang) == target {
			continue
		}
		e.LyricsTr, e.LyricsTrLang, e.LyricsTrSource = "", "", ""
		// 连同这门语言的重试计数/节流一起清,否则新语言的第一次尝试可能被上一门语言
		// 攒下的次数挡掉(needsTranslationBackfill 里 sameTarget 那段的同一个道理)。
		e.TranslationRetryCount, e.TranslationTS, e.TranslationLang = 0, 0, ""
		enrichCache[key] = e
		cleared++
	}
	if cleared > 0 {
		// 必须置脏:saveEnrichCache 开头就是 `if !enrichDirty || enrichPath == "" { return }`,
		// 不置的话下面那次保存会被静默跳过,清空只活在内存里、重启就回来了。
		enrichDirty = true
	}
	enrichMu.Unlock()
	if cleared > 0 {
		log.Printf("cleared %d machine translation(s) whose language no longer matches %q", cleared, target)
		// 必须在解锁之后:saveEnrichCache 自己要拿同一把 enrichMu。
		saveEnrichCache()
	}
}

// needsTranslationBackfill 判断这条要不要机翻补一份译文。
//
// 已经有 lyrics_tr 就一律不动 —— 社区翻译(网易云/Musixmatch 的人工译文)质量高于机翻,
// 机翻只是"没有社区译文时总比没有强"的兜底,不是升级。
func needsTranslationBackfill(e enrichEntry) bool {
	if !features.LyricsMachineTranslation {
		return false
	}
	if e.Lyrics == "" {
		return false
	}
	target := myMemoryLangCode(features.LyricsTranslationLanguage)
	if target == "" {
		return false
	}
	if translationUsable(e, target) {
		return false
	}
	// 次数上限和节流只对"同一个目标语言"成立:用户刚把语言从中文改成日语时,之前为中文
	// 累计的失败次数(比如那时日语包没装)不该把新语言的第一次尝试就挡掉。老条目没记
	// TranslationLang,当成同一个语言看待 —— 保守,维持原有行为。
	sameTarget := e.TranslationLang == "" || e.TranslationLang == target
	if sameTarget && e.TranslationRetryCount >= translationBackfillMaxAttempts {
		return false
	}
	// 逐行看:一行都不需要翻(整首都已经是目标语言那套文字)时别起 goroutine —— 否则会
	// 一次次翻出空结果、把三次重试额度白白烧完,之后这首歌就算真该翻也不会再试了。
	//
	// ⚠️ 这里曾经还有一道 looksLikeTargetLanguage 的**整首**判定排在前面,它把
	// "汉字占多数"的歌整首跳过,于是华语歌里整行英文的副歌永远等不到译文。
	// 已删除,理由见文件上方那段【已删除】注释 —— 下面这条逐行判定完全覆盖它的意图。
	if !anyLineNeedsTranslation(e.Lyrics, target) {
		return false
	}
	if sameTarget && e.TranslationTS > 0 &&
		time.Now().Unix()-e.TranslationTS < int64(translationBackfillInterval/time.Second) {
		return false
	}
	return true
}

// myMemoryLangCode 把 features.LyricsTranslationLanguage 的 ISO 639-1 代码转成 MyMemory
// 认的写法。只有中文需要转:MyMemory 要 zh-CN/zh-TW 这种带地区的写法,而那个设置里存的是
// 两位代码。其余语言原样透传。
func myMemoryLangCode(iso string) string {
	switch strings.ToLower(strings.TrimSpace(iso)) {
	case "":
		return ""
	case "zh", "zh-hans", "zh-cn":
		return "zh-CN"
	case "zh-hant", "zh-tw":
		return "zh-TW"
	default:
		return strings.ToLower(iso)
	}
}

// backfillTranslation 后台给一条已有歌词、但没有译文的记录补一份机翻。
//
// 跟 backfillPeripheralFields / rescoreLyrics 同一个范式(inflight 去重 + 重新取锁 +
// 条目可能已被删)。不管成没成都记一次尝试,否则真的翻不出来的歌会每次播放都重试。
func backfillTranslation(key string) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	lyrics := enrichCache[key].Lyrics
	enrichMu.Unlock()
	if lyrics == "" {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	target := myMemoryLangCode(features.LyricsTranslationLanguage)
	res, err := machineTranslateLRC(ctx, translateClient, lyrics, target)

	enrichMu.Lock()
	// 解锁之后再落盘 —— App 侧读的是**磁盘上**这份缓存文件(EnrichCacheReader 每次直读
	// 文件),只把 enrichDirty 标成 true 是不够的:补出来的东西只活在 collector 内存里,
	// 界面永远看不到。2026-08-08 用户报"译文语言切成英文了还是没有翻译",日志里译文明明
	// 一首首翻出来了,而缓存文件停在两小时前——就是这里漏了这一步。resolveEnrichAsync /
	// backfillPeripheralFields 一直是"解锁→saveEnrichCache",另外三条补全路径全漏了。
	//
	// 顺序不能反:saveEnrichCache 和 exportLyricsFiles 自己都要拿同一把 enrichMu,
	// 在持锁期间调用会死锁。
	//
	// 导出只在歌词族字段真的变了的时候做:它每次都要全量扫一遍 enrichCache,而这几条
	// 路径就算什么都没补上也会推进重试计数/时间戳(那些只要落盘、不涉及 lyrics/ 文件)。
	lyricsChanged := false
	defer func() {
		enrichMu.Unlock()
		saveEnrichCache()
		if !lyricsChanged {
			return
		}
		exportLyricsFiles()
		// 非阻塞通知 poll 立刻重推。跟 saveEnrichCache 一样,原来只有 resolveEnrichAsync /
		// backfillPeripheralFields 做了这一步,这三条补全路径全漏了 —— 于是同一首歌播到
		// 中途才补出来的译文,要等下一次换歌才会被推出去(2026-08-09 用户问"为什么当前这
		// 歌没有英文译文",译文其实早就翻好、也落盘了,只是没人通知)。
		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
	}()
	e, ok := enrichCache[key]
	if !ok {
		// 翻译这段时间里这条被用户在"歌词管理"里删掉了 —— 不要把它复活回去。
		return
	}
	// 期间用户可能刚好手动采纳了一份**用得上的**社区译文;那份优先,别覆盖。用得上是
	// 关键限定:一份语言对不上的社区译文正是这次翻译要顶替的东西,不能反过来挡住它。
	if translationUsable(e, target) {
		return
	}
	e.TranslationTS = time.Now().Unix()
	if e.TranslationLang != target {
		// 换了目标语言:上一门语言累计的失败次数不作数,从头再来。
		e.TranslationRetryCount = 0
		e.TranslationLang = target
	}
	switch {
	case res.quotaReached:
		// **不**记这次尝试:配额是全局的、跟这首歌翻不翻得出来无关,记进去等于让今天
		// 恰好轮到的那几首歌白白烧掉重试额度,以后再也不会被翻。只更新时间戳做节流。
		log.Printf("translate: %s deferred, daily quota reached", key)
	case err != nil:
		e.TranslationRetryCount++
		log.Printf("translate: %s failed: %v", key, err)
	case res.lrc == "":
		e.TranslationRetryCount++
		log.Printf("translate: %s produced nothing usable (already target language, or too few lines translated)", key)
	default:
		e.LyricsTr = res.lrc
		e.LyricsTrSource = lyricsTrSourceMachine
		e.LyricsTrLang = target
		lyricsChanged = true
		log.Printf("translate: %s got a machine translation (%d lines)", key, strings.Count(res.lrc, "\n")+1)
	}
	enrichCache[key] = e
	enrichDirty = true
}

// lyricsTrSourceMachine 是 enrichEntry.LyricsTrSource 目前唯一的非空取值。
const lyricsTrSourceMachine = "machine"

// errOnDeviceUnavailable 表示"这台机器上这条路本来就走不通"(系统太老/语言包没装/helper
// 不在),跟"该翻但翻失败了"区分开:前者是常态、不该刷日志,后者才值得记一笔。
var errOnDeviceUnavailable = errors.New("on-device translation unavailable")

// onDeviceTranslate 调打包在 Contents/Resources/ 里的 Swift 小助手做端上翻译。
//
// 为什么要起子进程:Apple 的 Translation 框架只有 Swift/ObjC 接口,Go 调不了。helper 的
// 位置按自己的可执行文件相对定位,跟 media-control 完全一样(见 system.go 的
// mediaControlBinaryPath)。开发时直接跑 collector 二进制不在 .app 里,找不到 helper 会
// 返回 errOnDeviceUnavailable,自动退回网络翻译。
func onDeviceTranslate(ctx context.Context, target string, lines []string) ([]string, error) {
	if target == "" || len(lines) == 0 {
		return nil, errOnDeviceUnavailable
	}
	exe, err := os.Executable()
	if err != nil {
		return nil, errOnDeviceUnavailable
	}
	bin := filepath.Join(filepath.Dir(exe), "lyrics-translate")
	if _, err := os.Stat(bin); err != nil {
		return nil, errOnDeviceUnavailable
	}
	payload, err := json.Marshal(struct {
		Target string   `json:"target"`
		Lines  []string `json:"lines"`
	}{Target: target, Lines: lines})
	if err != nil {
		return nil, fmt.Errorf("marshal translate request: %w", err)
	}

	cmd := exec.CommandContext(ctx, bin)
	cmd.Stdin = bytes.NewReader(payload)
	out, err := cmd.Output()
	// helper 用退出码非 0 表示"没翻成",但原因写在 stdout 的 JSON 里 —— 先解析再判错,
	// 别把"语言包没装"这种正常情况报成执行失败。
	var res struct {
		OK     bool     `json:"ok"`
		Source string   `json:"source"`
		Lines  []string `json:"lines"`
		Reason string   `json:"reason"`
	}
	if jsonErr := json.Unmarshal(out, &res); jsonErr != nil {
		if err != nil {
			return nil, fmt.Errorf("run lyrics-translate: %w", err)
		}
		return nil, fmt.Errorf("parse lyrics-translate output: %w", jsonErr)
	}
	if !res.OK {
		switch res.Reason {
		case "same-language", "needs-macos-26", "no-translation-framework", "undetected-source":
			return nil, errOnDeviceUnavailable
		case "supported", "notSupported", "unsupported":
			// 语言包没下载。这是最值得让用户知道的一种"不可用",单独记一条日志,
			// 但仍然算 unavailable(退回网络翻译),不当作错误刷屏。
			log.Printf("translate: on-device pack for %s not installed (%s), using network fallback",
				res.Source, res.Reason)
			return nil, errOnDeviceUnavailable
		default:
			return nil, fmt.Errorf("lyrics-translate: %s", res.Reason)
		}
	}
	if len(res.Lines) != len(lines) {
		return nil, fmt.Errorf("lyrics-translate returned %d lines for %d", len(res.Lines), len(lines))
	}
	return res.Lines, nil
}

// appleLangCode 把 features.LyricsTranslationLanguage 的 ISO 639-1 代码转成 Apple
// Translation 认的 BCP-47 写法。跟 myMemoryLangCode 分开:同一个"中文"两边写法不同
// (zh-Hans vs zh-CN),混用会让其中一条路静默失效。
func appleLangCode(iso string) string {
	switch strings.ToLower(strings.TrimSpace(iso)) {
	case "":
		return ""
	case "zh", "zh-cn", "zh-hans":
		return "zh-Hans"
	case "zh-tw", "zh-hant":
		return "zh-Hant"
	default:
		return strings.ToLower(iso)
	}
}
