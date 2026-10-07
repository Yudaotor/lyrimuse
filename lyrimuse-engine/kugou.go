package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"log"
	"math"
	neturl "net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// kugouLyric 是歌词第四个候选来源(酷狗音乐,非官方接口:搜索→KRC 歌词库搜索→下载,三步)。
// 只缓存成功(拿到逐行 LRC)的结果,跟 qqLyric/lrclibLyric 的缓存策略一致。是否采用交给
// enrich.go 里统一的 scoreLyricCandidate 打分决定,这里只负责"尽力拿一份候选"。
type kugouResult struct {
	lrc string
	yrc string // 归一化成 YRCParser 语法后的逐字数据,没有则空串
	// tr/roma:KRC 里 `[language:<base64>]` 内嵌的中文译文 / 罗马音两轨,已按 KRC 行始
	// 时间戳拼成逐行 LRC(加,见 krcLanguageTracks);没有则空串。
	tr, roma string
	// durationSecs:酷狗曲库自报的这首歌时长(秒),0=没给。透传用,见 lyricCandidate 同名字段。
	durationSecs float64
	// title/artist/album 是酷狗曲库里这首歌实际匹配到的歌名/歌手/专辑——纯粹给"搜索
	// 候选歌词"弹窗展示用,不参与任何匹配/打分逻辑,取自搜索结果本身(本来就已经查到,
	// 只是原来没往外传)。
	title, artist, album string
	// cover:加。搜索接口本身没有可靠的封面图字段(AlbumImage 实测经常是空
	// 字符串,这一点没变),但搜索结果带的 album_id 能换一次 album/info 接口拿到
	// imgurl——多一次请求,只在拿到候选(chosen != nil)之后才发,查不到/请求失败就留空,
	// 交给 enrich.go 的 coverOrFallback 退到 Apple 封面,不影响歌词本身的可用性。
	cover string
	// language:酷狗搜索接口 trans_param.language 字段折算出的
	// songLanguageMandarin/songLanguageCantonese,见 kugouCanonicalLanguage。透传用,
	// 跟 lyricCandidate.language 同一个模式,不参与打分。
	language string
	// noVocals:挑中的那一行 trans_param.language 是「纯音乐」(kugouLanguagePureMusic)。只认挑中的那一行:排在后面的同名行
	// 多是伴奏版。
	noVocals bool
	// fromLocalClient:这份歌词读自酷狗客户端自己的缓存(kugouLocalLyric),不是搜索来的。
	// 透传给 lyricCandidate.identityFromLocalClient,是同源加权的准入条件之一。
	fromLocalClient bool
	// localHash:本地缓存那份 KRC 的 [hash:],即这一版录音的文件 hash(跟搜索结果的 hash 是同一个值)。
	// 只给本地命中补封面用,见 kugouLocalCoverURL。
	localHash string
}

var (
	kugouMu    sync.Mutex
	kugouCache = map[string]kugouResult{}
)

func kugouLyric(ctx context.Context, artist, title, album string, durationSecs float64) kugouResult {
	if title == "" {
		return kugouResult{}
	}
	// album 进 key:它参与采纳判定(见 kugouOriginalGate 里的三角判据),同一个 (artist,title) 配不同专辑标签
	// 可能得出不同结果,不能共用一份缓存。
	key := artist + "|" + title + "|" + album
	kugouMu.Lock()
	if v, ok := kugouCache[key]; ok {
		kugouMu.Unlock()
		return v
	}
	kugouMu.Unlock()

	// 先问酷狗客户端自己的本地缓存 —— 命中就省掉搜索 → 歌词库 → 下载这条链路,而且拿到的是它为用户
	// 正在听的那一版下的那一份歌词(见 kugoulocal.go);本地缓存不带封面,只为封面再问一次搜索(kugouLocalCoverURL)。
	// 没命中照常走网络。
	ctx, sub := withLyricSubFetch(ctx)
	r, ok := kugouLocalLyric(artist, title, album, durationSecs)
	if ok {
		r.cover = kugouLocalCoverURL(ctx, artist, title, r.localHash)
	} else {
		r = resolveKugouLyric(ctx, artist, title, album, durationSecs)
	}
	// 逐字那一趟没问成的不缓存,见 lyricsubfetch.go。
	if r.lrc != "" && sub.complete(ctx) {
		kugouMu.Lock()
		kugouCache[key] = r
		kugouMu.Unlock()
	}
	return r
}

// krcXORKey 是酷狗 lyrics.kugou.com 下载接口对 fmt=krc(逐字)响应内容加密用的固定
// 16 字节异或密钥——公开算法(社区已逆向),已用真实歌曲验证解密成功(见 krcToYRC 注释)。
var krcXORKey = []byte{0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69}

// decryptKRC 解密 fmt=krc 下载响应的 base64 content:去掉开头 4 字节"krc1"魔数、按位
// 异或 krcXORKey(下标循环)、zlib 解压。任何一步失败都返回空串,不 panic。
func decryptKRC(b64 string) string {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return ""
	}
	return decryptKRCBytes(raw)
}

// decryptKRCBytes 是 decryptKRC 去掉 base64 那层的本体 —— 酷狗客户端落在本地的 .krc
// 文件就是这个形态(没有外层 base64),两条路共用同一段异或+解压,见 kugoulocal.go。
func decryptKRCBytes(raw []byte) string {
	if len(raw) <= 4 {
		return ""
	}
	body := raw[4:]
	dec := make([]byte, len(body))
	for i, b := range body {
		dec[i] = b ^ krcXORKey[i%len(krcXORKey)]
	}
	zr, err := zlib.NewReader(bytes.NewReader(dec))
	if err != nil {
		return ""
	}
	defer zr.Close()
	// 解压后的大小要封顶:这条下载走的是明文 http,中途被塞一个压缩炸弹就能把进程内存吃光。
	out, err := io.ReadAll(io.LimitReader(zr, krcDecompressedMaxBytes+1))
	if err != nil || len(out) > krcDecompressedMaxBytes {
		return ""
	}
	return string(out)
}

// krcDecompressedMaxBytes 一份 KRC 解压后的上限。真实的逐字歌词几十 KB,8 MB 留足了余量。
const krcDecompressedMaxBytes = 8 << 20

var (
	krcLineRegex = regexp.MustCompile(`^(\[(\d+),\d+\])(.*)$`)
	// 词始偏移可能是负数(这个字比行首早一点开始,`<-11,116,0>`);只认非负数字的话,这种标记会原样留在逐字数据和
	// 压出来的整行里。
	krcWordRegex = regexp.MustCompile(`<(-?\d+),(\d+),(\d+)>`)
)

// krcToYRC 把解密后的酷狗 KRC 正文转换成 YRCParser(desktop-lyrics)认识的语法。
//
// 酷狗原生:"[行始ms,行长ms]<词始ms,词长ms,flag>词"——这里的"词始ms"是相对这一行
// 行始的偏移量,从 0 开始逐词累加,加到这一行的行长为止。网易云原生 YRC:
// "[行始ms,行长ms](词始ms,词长ms,flag)词"——这里的"词始ms"是从整首歌开头算起的绝对
// 时间戳。两种格式外形都是"三个数字加一对括号",实际语义完全不是一回事:若只做尖括号
// →圆括号的语法转换而不做这层相对转绝对的换算,Swift 端(YRCParser 按"词始时间戳=
// 绝对播放位置"这个假设算 fillFraction)读到的词始时间戳会远小于真实播放位置,导致
// 这一行一开始播放,行内所有词的 fillFraction 立刻超过 1(已"填满"),整行瞬间全部
// 点亮,没有逐字推进效果。
//
// 修法:按行处理,每行先读出行始时间戳,再把行内每个词的相对偏移量都加上行始时间戳、
// 换算成绝对时间戳,才落成 YRCParser 认的语法。只对精确匹配 <数字,数字,数字> 的片段
// 动手,不做裸字符 Replace,避免歌词正文里偶然出现的尖括号被误伤。行头 [行始,行长] 和
// LRC 署名头([ti:]/[ar:] 等)本来就跟 YRC 兼容/会被 YRCParser 自然跳过,原样保留。
func krcToYRC(krc string) string {
	if krc == "" {
		return ""
	}
	normalized := strings.ReplaceAll(krc, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	lines := strings.Split(normalized, "\n")
	for i, line := range lines {
		m := krcLineRegex.FindStringSubmatch(line)
		if m == nil {
			continue // 署名头/其它不含 [行始,行长] 前缀的行,原样保留
		}
		lineStart, err := strconv.Atoi(m[2])
		if err != nil {
			continue
		}
		body := krcWordRegex.ReplaceAllStringFunc(m[3], func(match string) string {
			wm := krcWordRegex.FindStringSubmatch(match)
			wordStart, _ := strconv.Atoi(wm[1]) // 已经过 -?\d+ 校验,不会解析失败
			return fmt.Sprintf("(%d,%s,%s)", max(lineStart+wordStart, 0), wm[2], wm[3])
		})
		lines[i] = m[1] + body
	}
	// 纯空白词条在**源头**就归并掉,理由与 qrcToYRC 末尾那段相同(见 yrcwhitespace.go 头注)。
	// 本机缓存实测有 111 条酷狗条目带着这种词条,一直靠启动期那道迁移反复擦。
	merged, _ := yrcMergeWhitespaceTokens(strings.Join(lines, "\n"))
	return merged
}

// ---- 酷狗 KRC 内嵌的译文 / 罗马音轨(`[language:<base64>]`) ----
//
// 解密后的 KRC 正文里有一行 `[language:<base64>]`,base64 解出 JSON:
//
//	{"content":[{"type":1,"language":0,"lyricContent":[["要是这是场梦"],…]},
//	            {"type":0,"language":0,"lyricContent":[["yu ","me ","na ","ra ","ba"],…]}],"version":1}
//
// type 1 是中文译文、type 0 是音译;lyricContent 每一项对应 KRC 的一条计时行
// (`[行始,行长]<…>`),**按行序号对齐**,行数相等是格式契约(直连实测 5 首:
// Lemon 57/57、Ditto 73/73、Cruel Summer 73/73、Pretender 78/78、夜に駆ける 88/88;晴天
// 这类中文歌没有这一行)。片段拼接后就是这一行的文字,片段自带空格;空片段对应署名行。
// 行始时间戳取 KRC 那一行的行始——App 侧把译文贴到酷狗 fmt=lrc 那份整行歌词上用的是
// 700ms 最近邻,实测两套时间戳最近邻差最大 9ms。
//
// 韩文歌的 type 0 轨**不是罗马音,是中文谐音**(Ditto 实测:「马列做 say it back」
// 「啊亲们 挠木 摸咯」),照单全收会把这种谐音当罗马音显示。这里用汉字占比
// 把它挡掉(krcLanguageRomaMaxHanRatio);下游 usableValueAdd 的"原文假名占比 > 5%"是第二道闸。

var krcLanguageLineRegex = regexp.MustCompile(`^\[language:(.*)\]$`)

// krcLanguageRomaMaxHanRatio:type 0 轨正文里汉字占比超过这个值就当没有罗马音。真罗马音
// 是拉丁字母(实测 Lemon/Pretender/夜に駆ける 三首为 0),谐音轨实测 ≈0.9,取 0.3 两边都不擦边。
const krcLanguageRomaMaxHanRatio = 0.3

// splitKRCLanguageLine 把 `[language:…]` 行摘出来,返回 base64 正文与去掉该行后的 KRC。
// 没有就返回 ("", 原文)。
func splitKRCLanguageLine(krc string) (b64, rest string) {
	normalized := strings.ReplaceAll(strings.ReplaceAll(krc, "\r\n", "\n"), "\r", "\n")
	lines := strings.Split(normalized, "\n")
	for i, line := range lines {
		if m := krcLanguageLineRegex.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			return strings.TrimSpace(m[1]), strings.Join(append(lines[:i:i], lines[i+1:]...), "\n")
		}
	}
	return "", normalized
}

// krcLineStarts 返回 KRC 里每条计时行(`[行始,行长]<…>` 形态)的行始毫秒,顺序即行序号。
// 只认正文以 `<` 开头的行——[ti:]/[ar:] 这类署名头没有 [数字,数字] 前缀本来就进不来,
// 这里再要求 `<`,防某天出现不带逐字的 [数字,数字] 行把序号挤歪。
func krcLineStarts(krc string) []int {
	var starts []int
	for _, line := range strings.Split(krc, "\n") {
		m := krcLineRegex.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil || !strings.HasPrefix(strings.TrimSpace(m[3]), "<") {
			continue
		}
		start, err := strconv.Atoi(m[2])
		if err != nil {
			continue
		}
		starts = append(starts, start)
	}
	return starts
}

// krcLanguageTracks 把 `[language:]` 的 base64 正文解成 (译文 LRC, 罗马音 LRC),任一轨拿不到
// 就是空串。krc 是**去掉 language 行之后**的正文,只用来取各计时行的行始。
func krcLanguageTracks(b64, krc string) (tr, roma string) {
	if b64 == "" {
		return "", ""
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", ""
	}
	var payload struct {
		Content []struct {
			Type         int        `json:"type"`
			LyricContent [][]string `json:"lyricContent"`
		} `json:"content"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return "", ""
	}
	starts := krcLineStarts(krc)
	for _, track := range payload.Content {
		switch track.Type {
		case 1:
			if tr == "" {
				tr = krcLanguageTrackToLRC(track.LyricContent, starts)
			}
		case 0:
			if roma == "" {
				roma = krcLanguageTrackToLRC(track.LyricContent, starts)
			}
		}
	}
	if roma != "" && cjkRatio(roma) > krcLanguageRomaMaxHanRatio {
		roma = "" // 中文谐音轨,不是罗马音
	}
	return tr, roma
}

// krcLanguageTrackToLRC 按行序号把一条轨拼成逐行 LRC:行数与 KRC 计时行数不等就整轨放弃
// (对不齐宁可整体不要,跟假名标注同一口径);空行、`//` 占位行、版权声明行跳过;不够 3 行带戳当没有。
func krcLanguageTrackToLRC(content [][]string, starts []int) string {
	if len(content) == 0 || len(content) != len(starts) {
		return ""
	}
	var out []string
	for i, fragments := range content {
		text := strings.Join(strings.Fields(strings.Join(fragments, "")), " ")
		if text == "" || text == "//" || isTranslationNotice(text) {
			continue
		}
		ms := starts[i]
		out = append(out, fmt.Sprintf("[%02d:%02d.%03d]%s", ms/60000, (ms/1000)%60, ms%1000, text))
	}
	lrc := strings.Join(out, "\n")
	if !isTimedLRC(lrc) {
		return ""
	}
	return lrc
}

type kugouSong struct {
	Hash string `json:"hash"`
	// Hash320 / HashSQ:同一版录音另外两种音质的文件 hash。按 hash 认版本时三个都算,见 kugouSongByHash。
	Hash320    string  `json:"320hash"`
	HashSQ     string  `json:"sqhash"`
	SongName   string  `json:"songname"`
	SingerName string  `json:"singername"`
	AlbumName  string  `json:"album_name"`
	AlbumID    string  `json:"album_id"`
	Duration   float64 `json:"duration"` // 秒
	// TransParam.Language:酷狗搜索接口自带的语种标签,直接是人类可读字符串
	// ("国语"/"粤语",如周杰伦《稻香》→"国语"、Beyond《海阔天空》→"粤语")。
	TransParam struct {
		Language string `json:"language"`
		// UnionCover:这首歌的封面模板(带 {size}),多数是专辑封面;没有专辑封面的歌常给歌手头像,见 kugouSongCoverURL。
		UnionCover string `json:"union_cover"`
	} `json:"trans_param"`
	// Group:同一首歌挂在别的专辑(合辑、单曲、原专辑)下的条目,不另占结果的名次。
	Group []kugouSong `json:"group"`
}

// kugouSearchPageSize / kugouSearchPrimaryItems:搜歌一页取 kugouSearchPageSize 条(跟 10 条一样快,同一个请求),
// 挑选先只看前 kugouSearchPrimaryItems 条;一条都收不下时,整页和每条的 Group 才交给 kugouFallbackSong。
const (
	kugouSearchPageSize     = 30
	kugouSearchPrimaryItems = 10
)

// kugouLanguagePureMusic 是酷狗 trans_param.language 里的「纯音乐」,见 kugouResult.noVocals。
const kugouLanguagePureMusic = "纯音乐"

// kugouCanonicalLanguage 把酷狗 trans_param.language 的人类可读字符串折算成
// lyricCandidate.language 的取值,未识别的取值一律返回空串,不外推。
func kugouCanonicalLanguage(s string) string {
	switch s {
	case "国语":
		return songLanguageMandarin
	case "粤语":
		return songLanguageCantonese
	default:
		return ""
	}
}

// kugouEscape 编码查询参数值。mobilecdn.kugou.com/krcs.kugou.com 这两个接口不认标准
// application/x-www-form-urlencoded 里空格编码成 "+" 的写法(会直接搜出 0 结果),必须
// 编码成 "%20"——neturl.QueryEscape 对除空格外的字符转义规则都对,只把它的 "+" 输出替换
// 成 "%20" 即可,不用换成 PathEscape(PathEscape 不转义 "&"/"="等 query 里有特殊含义的
// 字符,遇到"Prince & The Revolution"这类歌手名会把 & 直接拼进 query 破坏参数边界)。
func kugouEscape(s string) string {
	return strings.ReplaceAll(neturl.QueryEscape(s), "+", "%20")
}

// kugouSearchRejected:搜索接口查无结果时仍回 status=1 / errcode=0(实测),两个字段在但不是
// 这两个值就是服务端拒绝。字段缺失不算:krcs 等别的接口不是这套约定,这里只给搜索用。
func kugouSearchRejected(status, errcode *int) bool {
	return (status != nil && *status != 1) || (errcode != nil && *errcode != 0)
}

// resolveKugouLyric:①搜索拿 hash/时长(歌手名+歌名都要对上,同 netease/qq 的身份校验;每个检索词的前
// kugouSearchPrimaryItems 条都挑不出时,交给 kugouFallbackSong);
// ②用 hash+时长 查 KRC 歌词库候选(krcs.kugou.com,官方推荐候选优先,取第一条);
// ③用候选的 id+accesskey 先下载 fmt=krc 逐字,整行歌词从它压出来(krcToLRC;fmt=lrc 那份带时间戳的行跟它
// 逐行相同,头部多几行酷狗自己的标签);KRC 没问成、解不开或压不出带时间戳的整行,才下载 fmt=lrc。
// 每一步的备用主机 / 备用后端见 kugoufallback.go。整行拿不到则整体放弃。任何一步
// 失败/拿不到都直接放弃,不重试(下次 enrich 短 TTL 到期自然再试)。
func resolveKugouLyric(ctx context.Context, artist, title, album string, durationSecs float64) kugouResult {
	// 搜索词逐个 variant 试,先命中先用(顺序由 searchTitleVariants 定,跟设置走)。带括号的标题在酷狗
	// 上不会返回空、而是回一串该歌手的热门歌,所以"搜砸了"表现为 pickKugouSearchCandidate
	// 一条都收不下,不是 kugouGet 报错——必须靠 chosen==nil 才能发现,不能只在 err != nil
	// 时才换词。详见 searchTitleVariants 的注释。第二跳(krcs 查 KRC 候选)身份是 hash 认的,keyword 照样
	// 去掉编号那几层(lyricQueryTitle):带着重录年份这类后缀,同一个 hash 也可能一条候选都不回。
	var chosen, held *kugouSong
	var pool []kugouSong
	searched := false
	for _, q := range searchTitleVariants(title) {
		songs, ok := kugouSearchSongs(ctx, artist+" "+q)
		if !ok {
			continue
		}
		searched = true
		primary := songs[:min(len(songs), kugouSearchPrimaryItems)]
		if lyricSearchItemsTap != nil {
			lyricSearchItemsTap("kugou", artist, title, album, durationSecs, primary)
		}
		chosen = pickKugouSearchCandidate(primary, artist, title, album, durationSecs)
		// 歌名带编号时完整歌名排在最前面(searchTitleVariants);它搜回来挑中的那条自报时长对不上时先记着,接着试去掉编号的
		// 写法,都没有更合适的再用它。
		if chosen != nil && hasStrongTitleIdentifier(title) && !sourceDurationFits(durationSecs, chosen.Duration) {
			if held == nil {
				held = chosen
			}
			chosen = nil
		}
		if chosen != nil {
			break
		}
		pool = kugouMergeSongs(pool, songs)
	}
	if chosen == nil {
		chosen = kugouFallbackSong(pool, artist, title, album, durationSecs)
	}
	if chosen == nil {
		chosen = held
	}
	if chosen == nil {
		if !searched {
			return kugouResult{}
		}
		return kugouKeywordLyric(ctx, artist, title, durationSecs, nil)
	}
	r := kugouLyricForSong(ctx, artist, title, durationSecs, chosen)
	r.noVocals = chosen.TransParam.Language == kugouLanguagePureMusic
	return r
}

// kugouLyricForSong 取挑中的那一首的歌词:先按 hash 查歌词库,查不到能用的再不带 hash 按关键词查(kugouKeywordLyric)。
func kugouLyricForSong(ctx context.Context, artist, title string, durationSecs float64, chosen *kugouSong) kugouResult {
	durMs := int64(chosen.Duration * 1000)
	if durMs <= 0 && durationSecs > 0 {
		durMs = int64(durationSecs * 1000)
	}
	var kr struct {
		Candidates []kugouLyricCandidate `json:"candidates"`
	}
	// 搜索词里歌名带编号时去掉带编号的那几层,见 lyricQueryTitle。
	krcURL := fmt.Sprintf("http://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=%s&duration=%d&hash=%s",
		kugouEscape(artist+" - "+lyricQueryTitle(title)), durMs, chosen.Hash)
	if err := kugouGet(ctx, krcURL, &kr); err != nil {
		return kugouResult{}
	}
	if len(kr.Candidates) == 0 {
		return kugouKeywordLyric(ctx, artist, title, durationSecs, chosen)
	}
	c := kr.Candidates[0]
	if c.ID == "" || c.AccessKey == "" {
		return kugouResult{}
	}
	// 第一条候选答了却没有能用的整行时,多半是酷狗给没词的歌挂的那条占位(「The Seasons Op. 37b: June - Barcarole」,
	// 正文只有「纯音乐,请欣赏」),跟候选为空一样再不带 hash 查一次。
	got, ok, answered := kugouFetchLyric(ctx, c.ID, c.AccessKey)
	if !ok {
		if answered {
			return kugouKeywordLyric(ctx, artist, title, durationSecs, chosen)
		}
		return kugouResult{}
	}
	return kugouResult{lrc: got.lrc, yrc: got.yrc, tr: got.tr, roma: got.roma, durationSecs: chosen.Duration, title: chosen.SongName, artist: chosen.SingerName, album: chosen.AlbumName, language: kugouCanonicalLanguage(chosen.TransParam.Language), cover: kugouSongCoverURL(ctx, chosen)}
}

// kugouLyricCandidate 是歌词库的一条候选(krcs / lyrics 两个主机的 /search)。
type kugouLyricCandidate struct {
	ID        string `json:"id"`
	AccessKey string `json:"accesskey"`
	Song      string `json:"song"`
	Singer    string `json:"singer"`
	Duration  int    `json:"duration"` // 毫秒
}

// kugouFetched 是一次下载拿到的整行、逐字、译文、罗马音。
type kugouFetched struct{ lrc, yrc, tr, roma string }

// kugouFetchLyric 按歌词候选下载:先 fmt=krc,整行用 krcToLRC 从它压出来(fmt=lrc 那份带时间戳的行跟它逐行相同);
// KRC 没问成、解不开或压不出带时间戳的整行,才下 fmt=lrc。整行拿不到 ok=false;answered 说的是 fmt=lrc 那次服务端
// 答了(只是没有能用的整行),不是没问成。
func kugouFetchLyric(ctx context.Context, id, accessKey string) (got kugouFetched, ok, answered bool) {
	var krcDl struct {
		Content string `json:"content"`
	}
	var lang, body string
	krcDlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=krc&charset=utf8", id, accessKey)
	if err := kugouGet(ctx, krcDlURL, &krcDl); err != nil {
		noteLyricSubFetchFailure(ctx)
	} else if krcDl.Content != "" {
		if decrypted := decryptKRC(krcDl.Content); decrypted != "" {
			// `[language:<base64>]` 那一行先摘出来(它是译文/罗马音两轨的载体,8~12KB 的
			// base64,原样留在逐字数据里只是一行 App 读不懂的垃圾、还会随 .yrc 导出),剩余
			// 正文才进 krcToYRC;两轨按 KRC 行序号对齐行始时间戳,见 krcLanguageTracks。
			lang, body = splitKRCLanguageLine(decrypted)
		}
	}
	got.lrc = krcToLRC(body)
	if !isTimedLRC(got.lrc) {
		var dl struct {
			Content string `json:"content"`
		}
		dlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=lrc&charset=utf8", id, accessKey)
		if err := kugouGet(ctx, dlURL, &dl); err != nil {
			return kugouFetched{}, false, false
		}
		raw, err := base64.StdEncoding.DecodeString(dl.Content)
		if err != nil || !isTimedLRC(string(raw)) {
			return kugouFetched{}, false, true
		}
		got.lrc = string(raw)
	}
	// KRC 里一条带逐字的计时行都没有(只剩头部标签)时不交逐字:这种壳转出来只有标签行,usableWordTiming 量不出
	// 它的结束时刻,会当成有逐字放行。
	if len(krcLineStarts(body)) > 0 {
		got.yrc = krcToYRC(body)
		got.tr, got.roma = krcLanguageTracks(lang, body)
	}
	return got, true, true
}

// kugouKeywordLyric:按 hash 查不到能用的歌词、或者搜歌挑不出曲目时,不带 hash、按「歌手 - 歌名」加本地时长再查一次
// 歌词库(同一首歌别的上传常挂着词),候选过 kugouKeywordCandidate 才下载。本地时长未知不查(没有时长闸,这种查法
// 会挑成片段或别的现场版)。主机先问 krcs(不带 hash 时 lyrics 那台有时回得少,按 hash 查两台一致)。挑中的曲目
// (chosen)时长也跟本地差 kugouFallbackDurationTolerance 以内时,身份(歌名 / 专辑 / 封面)用它;否则用候选自己的
// (挑中的是另一个版本,词却是这一版的)。见 09 章决策 148。
func kugouKeywordLyric(ctx context.Context, artist, title string, durationSecs float64, chosen *kugouSong) kugouResult {
	if durationSecs <= 0 {
		return kugouResult{}
	}
	var kr struct {
		Candidates []kugouLyricCandidate `json:"candidates"`
	}
	// 搜索词里歌名带编号时去掉带编号的那几层,见 lyricQueryTitle。
	u := fmt.Sprintf("http://krcs.kugou.com/search?ver=1&man=yes&client=pc&keyword=%s&duration=%d&hash=",
		kugouEscape(artist+" - "+lyricQueryTitle(title)), int64(durationSecs*1000))
	if err := kugouGet(ctx, u, &kr); err != nil {
		return kugouResult{}
	}
	c, found := kugouKeywordCandidate(kr.Candidates, artist, title, durationSecs)
	if !found {
		return kugouResult{}
	}
	got, ok, _ := kugouFetchLyric(ctx, c.ID, c.AccessKey)
	if !ok {
		return kugouResult{}
	}
	r := kugouResult{lrc: got.lrc, yrc: got.yrc, tr: got.tr, roma: got.roma, title: c.Song, artist: c.Singer, durationSecs: float64(c.Duration) / 1000}
	if chosen != nil && durationsWithin(chosen.Duration, durationSecs, kugouFallbackDurationTolerance) {
		r.title, r.artist, r.album, r.durationSecs = chosen.SongName, chosen.SingerName, chosen.AlbumName, chosen.Duration
		r.language = kugouCanonicalLanguage(chosen.TransParam.Language)
		r.cover = kugouSongCoverURL(ctx, chosen)
	}
	return r
}

// kugouKeywordCandidate 在不带 hash 查回的歌词候选里按顺序挑第一条:歌名过闸、歌手过 lyricSourceArtistMatches、歌名的
// 版本限定词一致(候选没有专辑名,只比歌名)、自报时长跟本地差 kugouFallbackDurationTolerance 以内。纯函数,便于单测。
func kugouKeywordCandidate(cands []kugouLyricCandidate, artist, title string, durationSecs float64) (kugouLyricCandidate, bool) {
	for _, c := range cands {
		if c.ID == "" || c.AccessKey == "" || !lyricTitleAccepted(c.Song, title) || !lyricSourceArtistMatches(c.Singer, artist) ||
			versionTagsMismatch(title, "", c.Song, "") || !durationsWithin(float64(c.Duration)/1000, durationSecs, kugouFallbackDurationTolerance) {
			continue
		}
		return c, true
	}
	return kugouLyricCandidate{}, false
}

// pickKugouSearchCandidate 从一页搜索结果里挑"这份歌词该跟谁走"。
//
// 之前是**第一条过闸就收工**——闸门只有标题(lyricTitleAccepted)和歌手,完全
// 不看专辑和时长,于是排序靠前的杂项能把同页靠后的正主顶掉。例如酷狗对"周杰伦 简单爱
// (Live)"(本地 273.227s)返回的第 1 条是「简单爱 (无与伦比演唱会 m 56s)」——一个 56 秒
// 的片段、专辑名为空,剥括号后标题也叫"简单爱"、歌手也对,先到先得直接定死;而第 2 条
// 才是「简单爱 (Live)」《The One 演唱会》273s——**标题跟本地 normLoose 精确相等 + 专辑
// token 对得上 + 时长只差 0.227s**,
// 三项证据全在,却永远轮不到。netease.go 的 queries 注释里早写过这个对比:"那三个源是取
// 第一条通过校验的候选就收工,搜索词一偏就直接定死在错版本上"——这里把酷狗从那个名单里
// 摘出来。
//
// 排序键(闸门原样保留,只改"过闸之后信谁"):
//  1. 标题档位:编号也对得上的同名(lyricTitleSameNumber,本地歌名带编号时才有)> 逐字同名(lyricTitleSameName)
//     > 剥括号后相等 > 其它过闸形态(跟 QQ 专辑维度路线 resolveQQMatchViaAlbum 的档位完全同构);
//  2. 同档位比 albumScore(200 精确 / 100 包含 / token 数,见 match.go);
//  3. 再同分比时长贴近度(本地或候选缺时长的当 +Inf,排最后);
//  4. 全都打平保持原序(搜索相关性排序,= 改动前的行为)。
//
// 只有一条过闸时四个键全部无事发生,跟旧行为逐位一致。
func pickKugouSearchCandidate(songs []kugouSong, artist, title, album string, durationSecs float64) *kugouSong {
	best, byTriangle := kugouRankSongs(songs, title, album, durationSecs, func(s *kugouSong) (ok, byTriangle bool) {
		return kugouOriginalGate(s, artist, title, album, durationSecs)
	})
	// 日志只报**最终选中**的那条(改成全页排序之前,triangle 一接受就等于选中,日志语义
	// 是一回事;现在 triangle 接受的候选也可能被排序比下去,不选中就不该说 accepted)。
	if best != nil && byTriangle {
		log.Printf("lyrics: kugou accepted %q by recording triangle (local artist %q vs source %q; album %q vs %q; dur %.3f vs %.3f)",
			best.SongName, artist, best.SingerName, album, best.AlbumName, durationSecs, best.Duration)
	}
	return best
}

// kugouOriginalGate 是 pickKugouSearchCandidate 的闸门:歌名过闸,歌手过 lyricSourceArtistMatches,不过时看三角判据
// (byTriangle=true)。
func kugouOriginalGate(s *kugouSong, artist, title, album string, durationSecs float64) (ok, byTriangle bool) {
	// 判定用的始终是**本地原样标题** title,不是搜索词——放宽的只是"拿什么去搜",
	// 不是"什么算匹配"。
	// 歌手闸用 lyricSourceArtistMatches:酷狗的合唱署名固定用顿号("UMI、V"),
	// 本地标签是 "&" 或换了合作者语言写法("UMI & 金泰亨")时 artistMatches 会把
	// 服务端明明召回成功的正主原地拒掉。
	if !lyricTitleAccepted(s.SongName, title) {
		return false, false
	}
	if lyricSourceArtistMatches(s.SingerName, artist) {
		return true, false
	}
	// 歌手闸不过 → 还有第二条依据:标题逐字同名 + 专辑对得上 + 时长紧密吻合
	// = 同一次录音。修的是"艺名与本名 / 乐队名与成员名"这类连分隔符都没有、
	// 段集交集档和别名轮都够不到的署名分歧(实测案例见
	// lyricRecordingTriangleMatches 的注释)。候选专辑名就是歌名(单曲)时还要两边歌手名互相包含,同网易云 / 汽水 /
	// Apple Music,见 lyricRecordingTriangleMatchesGuarded。
	if lyricRecordingTriangleMatchesGuarded(s.SongName, s.AlbumName, s.SingerName, s.Duration, title, album, artist, durationSecs) {
		return true, true
	}
	return false, false
}

// kugouRankSongs 在 accept 放行的条目里按 pickKugouSearchCandidate 头注的四个排序键挑一条;没有 hash 的跳过。
// 返回选中那条的 byTriangle。
func kugouRankSongs(songs []kugouSong, title, album string, durationSecs float64, accept func(s *kugouSong) (ok, byTriangle bool)) (*kugouSong, bool) {
	const (
		tierSameNumber = iota
		tierExact
		tierStripped
		tierAccepted
	)
	st := normLoose(stripParens(title))
	var best *kugouSong
	bestTier, bestAlbum := 0, 0
	bestDur := math.Inf(1)
	bestByTriangle, bestFits := false, false
	for i := range songs {
		s := &songs[i]
		if s.Hash == "" {
			continue
		}
		ok, byTriangle := accept(s)
		if !ok {
			continue
		}
		tier := tierAccepted
		switch {
		case lyricTitleSameNumber(s.SongName, title):
			tier = tierSameNumber
		case lyricTitleSameName(s.SongName, title):
			tier = tierExact
		case normLoose(stripParens(s.SongName)) == st:
			tier = tierStripped
		}
		asc := albumScore(s.AlbumName, album)
		dd := math.Inf(1)
		if durationSecs > 0 && s.Duration > 0 {
			dd = math.Abs(s.Duration - durationSecs)
		}
		// 自报曲长对不上(>12%,与打分层 sourceDurationOff 同口径)的候选排到所有对得上的后面,
		// 标题档只在同一组内部再比——理由见 match.go sourceDurationFits(PRINCE《319》X-cerpt 案)。
		fits := sourceDurationFits(durationSecs, s.Duration)
		better := false
		switch {
		case best == nil:
			better = true
		case fits != bestFits:
			better = fits
		case tier != bestTier:
			better = tier < bestTier
		case asc != bestAlbum:
			better = asc > bestAlbum
		case dd != bestDur:
			better = dd < bestDur
		}
		if better {
			best, bestTier, bestAlbum, bestDur, bestByTriangle, bestFits = s, tier, asc, dd, byTriangle, fits
		}
	}
	return best, bestByTriangle
}

// kugouFallbackDurationTolerance:后备闸里自报时长差多少以内才收(同 qqFallbackDurationTolerance)。
const kugouFallbackDurationTolerance = 0.03

// kugouAlbumDurationMaxDiffSecs:kugouFallbackSong ④ 歌名对不上时,自报时长跟本地差多少秒以内才收。
const kugouAlbumDurationMaxDiffSecs = 1.0

// kugouFallbackSong 是每个检索词的前 kugouSearchPrimaryItems 条都挑不出时的后备,在 pool(各次搜索的整页加每条的
// Group,见 kugouMergeSongs)里按顺序试,前一档有结果就用它,每一档都过版本闸(versionTagsMismatch,按完整的本地
// 歌名判):
//
//	① 原来的闸门(kugouOriginalGate):正主排在前 kugouSearchPrimaryItems 条以后,或者只挂在某条的 Group 里。
//	② 歌手名一个包含另一个(looseContains:酷狗的「关浩德Walter」「雅MIYAVI」对本地的「关浩德」「MIYAVI」):歌名
//	   过闸,自报时长差在 kugouFallbackDurationTolerance 以内;本地时长未知时改要求专辑对得上(albumScore ≥ 100)。
//	③ 歌名的「 - 尾段」写法(dashTailAsBracket):酷狗一侧改成括号再过歌名闸,自报时长要在 sourceDurationFits
//	   以内;本地一侧(「X - 电视剧《Y》主题曲」)也改成括号,自报时长差要在 kugouFallbackDurationTolerance 以内。
//	   歌手过 lyricSourceArtistMatches 或 looseContains。
//	④ 歌名对不上(另一种文字的原名、异体字):歌手(lyricSourceArtistMatches)和专辑(albumScore ≥ 100)对得上、
//	   自报时长跟本地差 kugouAlbumDurationMaxDiffSecs 以内,而且 pool 里只有这一条。
//
// ①～③ 有几条放行时按 kugouRankSongs 排。见 09 章决策 148。
func kugouFallbackSong(pool []kugouSong, artist, title, album string, durationSecs float64) *kugouSong {
	versionOK := func(s *kugouSong) bool { return !versionTagsMismatch(title, album, s.SongName, s.AlbumName) }
	near := func(s *kugouSong) bool {
		return durationsWithin(s.Duration, durationSecs, kugouFallbackDurationTolerance)
	}
	gates := []func(s *kugouSong) (bool, bool){
		func(s *kugouSong) (bool, bool) {
			ok, byTriangle := kugouOriginalGate(s, artist, title, album, durationSecs)
			return ok && versionOK(s), byTriangle
		},
		func(s *kugouSong) (bool, bool) {
			if !lyricTitleAccepted(s.SongName, title) || !looseContains(s.SingerName, artist) || !versionOK(s) {
				return false, false
			}
			if durationSecs > 0 {
				return near(s), false
			}
			return albumScore(s.AlbumName, album) >= 100, false
		},
		func(s *kugouSong) (bool, bool) {
			if !(lyricSourceArtistMatches(s.SingerName, artist) || looseContains(s.SingerName, artist)) || !versionOK(s) {
				return false, false
			}
			name, local := dashTailAsBracket(s.SongName), dashTailAsBracket(title)
			switch {
			case name != s.SongName && lyricTitleAccepted(name, title):
				return sourceDurationFits(durationSecs, s.Duration), false
			case local != title && lyricTitleAccepted(name, local):
				return near(s), false
			}
			return false, false
		},
	}
	for _, gate := range gates {
		if best, _ := kugouRankSongs(pool, title, album, durationSecs, gate); best != nil {
			return best
		}
	}
	return kugouAlbumDurationSong(pool, artist, title, album, durationSecs)
}

// kugouAlbumDurationSong 是 kugouFallbackSong 的 ④。
func kugouAlbumDurationSong(pool []kugouSong, artist, title, album string, durationSecs float64) *kugouSong {
	if album == "" || durationSecs <= 0 {
		return nil
	}
	var hit *kugouSong
	for i := range pool {
		s := &pool[i]
		if s.Hash == "" || s.Duration <= 0 || math.Abs(s.Duration-durationSecs) > kugouAlbumDurationMaxDiffSecs ||
			!lyricSourceArtistMatches(s.SingerName, artist) || albumScore(s.AlbumName, album) < 100 ||
			versionTagsMismatch(title, album, s.SongName, s.AlbumName) {
			continue
		}
		if hit != nil {
			return nil
		}
		hit = s
	}
	return hit
}

// kugouMergeSongs 把 songs 和每条的 Group 里 pool 还没有的条目(按 hash)接在 pool 后面。
func kugouMergeSongs(pool, songs []kugouSong) []kugouSong {
	seen := make(map[string]bool, len(pool))
	for _, s := range pool {
		seen[s.Hash] = true
	}
	add := func(s kugouSong) {
		if s.Hash != "" && !seen[s.Hash] {
			seen[s.Hash] = true
			pool = append(pool, s)
		}
	}
	for _, s := range songs {
		add(s)
		for _, g := range s.Group {
			add(g)
		}
	}
	return pool
}

// kugouLocalCoverURL 给本地缓存命中的那份补封面:本地 KRC 不带封面,拿它的 [hash:] 在搜索结果里认出同一版录音,
// 取那一条的封面(kugouSongCoverURL)。搜索词按 searchTitleVariants 逐个试,认出即停;认不出留空,不拿别的版本的封面顶上。
// 见 09 章决策 199。
func kugouLocalCoverURL(ctx context.Context, artist, title, hash string) string {
	if hash == "" {
		return ""
	}
	for _, q := range searchTitleVariants(title) {
		songs, ok := kugouSearchSongs(ctx, artist+" "+q)
		if !ok {
			continue
		}
		if s := kugouSongByHash(songs, hash); s != nil {
			return kugouSongCoverURL(ctx, s)
		}
	}
	return ""
}

// kugouSongByHash 在搜索结果里找文件 hash 对得上的那一条:三种音质的 hash 都算、不分大小写,同一首歌挂在别的专辑下的
// 条目(Group)也找。纯函数,便于单测。
func kugouSongByHash(songs []kugouSong, hash string) *kugouSong {
	for i := range songs {
		if songs[i].hasFileHash(hash) {
			return &songs[i]
		}
		for j := range songs[i].Group {
			if songs[i].Group[j].hasFileHash(hash) {
				return &songs[i].Group[j]
			}
		}
	}
	return nil
}

func (s *kugouSong) hasFileHash(hash string) bool {
	for _, h := range []string{s.Hash, s.Hash320, s.HashSQ} {
		if h != "" && strings.EqualFold(h, hash) {
			return true
		}
	}
	return false
}

// kugouSongCoverURL:搜索结果自带的封面(trans_param.union_cover)在 stdmusic 路径下就是专辑封面,跟 album/info
// 给的是同一张,直接用;别的(没有专辑封面的歌常给 singerimg 下的歌手头像)或者没有,才按专辑 ID 问 album/info。
func kugouSongCoverURL(ctx context.Context, s *kugouSong) string {
	if u := s.TransParam.UnionCover; strings.Contains(u, "/stdmusic/") {
		return kugouCoverFromTemplate(u)
	}
	return kugouAlbumCoverURL(ctx, s.AlbumID)
}

// kugouAlbumCoverURL 按专辑 ID 查 album/info 接口拿封面。响应的
// imgurl 字段是个带 "{size}" 占位符的模板(如
// "http://imge.kugou.com/stdmusic/{size}/…/….jpg"),换成具体像素数才是能直接访问的
// URL。尺寸填 0 拿原图(实测 1477 / 2048);填具体像素数会按要求缩放,比原图大时是放大出来的。
// albumID 为空(有些搜索结果确实没有)或请求失败都返回空串,调用方(enrich.go 的
// coverOrFallback)会自然退到 Apple 封面,不是致命错误。
func kugouAlbumCoverURL(ctx context.Context, albumID string) string {
	if albumID == "" {
		return ""
	}
	var out struct {
		Data struct {
			ImgURL string `json:"imgurl"`
		} `json:"data"`
	}
	u := "http://mobilecdn.kugou.com/api/v3/album/info?albumid=" + neturl.QueryEscape(albumID)
	if err := kugouGet(ctx, u, &out); err != nil || out.Data.ImgURL == "" {
		return ""
	}
	return kugouCoverFromTemplate(out.Data.ImgURL)
}

// kugouCoverFromTemplate 把酷狗的封面模板换成能直接访问的地址:{size} 填 0 拿原图,http 换成 https。
func kugouCoverFromTemplate(tmpl string) string {
	cover := strings.ReplaceAll(tmpl, "{size}", "0")
	// 现象是"酷狗的没有返回封面"(截图里酷狗那条候选是空白占位图,
	// netease 那条却有缩略图):酷我/acg 的这个接口原样返回的是 "http://" 前缀,引擎
	// 这边发请求不受影响(没有 ATS 限制),但这个 URL 之后会原样进 lyricCandidate.cover、
	// 一路传到 Swift 侧的 AsyncImage——macOS App Transport Security 默认拒绝纯 HTTP 的
	// 网络请求,图片静默加载失败、退回占位图标,不会报错也不会抛异常,只在真机 UI 上才
	// 看得出来(拿 CLI 直查 cover_url 字符串本身看不出这个问题)。同一张图换成 https
	// 也是 200,强制换成 https 就地修好,不需要额外配置 ATS 例外域名(改 Info.plist 加
	// 白名单域名是更大范围的例外,没必要为一张图开这个口子)。
	return strings.Replace(cover, "http://", "https://", 1)
}
