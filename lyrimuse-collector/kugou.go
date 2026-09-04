// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
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
	"net/http"
	neturl "net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// kugouLyric 是歌词第四个候选来源(酷狗音乐,非官方接口:搜索→KRC 歌词库搜索→下载,三步)。
// 只缓存成功(拿到逐行 LRC)的结果,跟 qqLyric/lrclibLyric 的缓存策略一致。是否采用交给
// enrich.go 里统一的 scoreLyricCandidate 打分决定,这里只负责"尽力拿一份候选"。
type kugouResult struct {
	lrc string
	yrc string // 归一化成 YRCParser 语法后的逐字数据,没有则空串
	// tr/roma:KRC 里 `[language:<base64>]` 内嵌的中文译文 / 罗马音两轨,已按 KRC 行始
	// 时间戳拼成逐行 LRC(2026-09-02 加,见 krcLanguageTracks);没有则空串。
	tr, roma string
	// durationSecs:酷狗曲库自报的这首歌时长(秒),0=没给。透传用,见 lyricCandidate 同名字段。
	durationSecs float64
	// title/artist/album 是酷狗曲库里这首歌实际匹配到的歌名/歌手/专辑——纯粹给"搜索
	// 候选歌词"弹窗展示用,不参与任何匹配/打分逻辑,取自搜索结果本身(本来就已经查到,
	// 只是原来没往外传)。
	title, artist, album string
	// cover:2026-08-31 加。搜索接口本身没有可靠的封面图字段(AlbumImage 实测经常是空
	// 字符串,这一点没变),但搜索结果带的 album_id 能换一次 album/info 接口拿到
	// imgurl——多一次请求,只在拿到候选(chosen != nil)之后才发,查不到/请求失败就留空,
	// 交给 enrich.go 的 coverOrFallback 退到 Apple 封面,不影响歌词本身的可用性。
	cover string
	// language:酷狗搜索接口 trans_param.language 字段折算出的
	// songLanguageMandarin/songLanguageCantonese,见 kugouCanonicalLanguage。透传用,
	// 跟 lyricCandidate.language 同一个模式,不参与打分。
	language string
}

var (
	kugouMu    sync.Mutex
	kugouCache = map[string]kugouResult{}
)

func kugouLyric(ctx context.Context, artist, title, album string, durationSecs float64) kugouResult {
	if title == "" {
		return kugouResult{}
	}
	// album 进 key:它现在参与采纳判定(见 resolveKugouLyric 里的
	// lyricRecordingTriangleMatches 档),同一个 (artist,title) 配不同专辑标签可能得出
	// 不同结果,不能共用一份缓存。
	key := artist + "|" + title + "|" + album
	kugouMu.Lock()
	if v, ok := kugouCache[key]; ok {
		kugouMu.Unlock()
		return v
	}
	kugouMu.Unlock()

	r := resolveKugouLyric(ctx, artist, title, album, durationSecs)
	if r.lrc != "" {
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
	if err != nil || len(raw) <= 4 {
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
	out, err := io.ReadAll(zr)
	if err != nil {
		return ""
	}
	return string(out)
}

var (
	krcLineRegex = regexp.MustCompile(`^(\[(\d+),\d+\])(.*)$`)
	krcWordRegex = regexp.MustCompile(`<(\d+),(\d+),(\d+)>`)
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
			wordStart, _ := strconv.Atoi(wm[1]) // 已经过 \d+ 校验,不会解析失败
			return fmt.Sprintf("(%d,%s,%s)", lineStart+wordStart, wm[2], wm[3])
		})
		lines[i] = m[1] + body
	}
	return strings.Join(lines, "\n")
}

// ---- 酷狗 KRC 内嵌的译文 / 罗马音轨(`[language:<base64>]`) ----
//
// 解密后的 KRC 正文里有一行 `[language:<base64>]`,base64 解出 JSON:
//
//	{"content":[{"type":1,"language":0,"lyricContent":[["要是这是场梦"],…]},
//	            {"type":0,"language":0,"lyricContent":[["yu ","me ","na ","ra ","ba"],…]}],"version":1}
//
// type 1 是中文译文、type 0 是音译;lyricContent 每一项对应 KRC 的一条计时行
// (`[行始,行长]<…>`),**按行序号对齐**,行数相等是格式契约(2026-09-02 直连实测 5 首:
// Lemon 57/57、Ditto 73/73、Cruel Summer 73/73、Pretender 78/78、夜に駆ける 88/88;晴天
// 这类中文歌没有这一行)。片段拼接后就是这一行的文字,片段自带空格;空片段对应署名行。
// 行始时间戳取 KRC 那一行的行始——App 侧把译文贴到酷狗 fmt=lrc 那份整行歌词上用的是
// 700ms 最近邻,实测两套时间戳最近邻差最大 9ms。
//
// ⚠️ 韩文歌的 type 0 轨**不是罗马音,是中文谐音**(Ditto 实测:「马列做 say it back」
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
// (对不齐宁可整体不要,跟假名标注同一口径);空行、`//` 占位行跳过;不够 3 行带戳当没有。
func krcLanguageTrackToLRC(content [][]string, starts []int) string {
	if len(content) == 0 || len(content) != len(starts) {
		return ""
	}
	var out []string
	for i, fragments := range content {
		text := strings.Join(strings.Fields(strings.Join(fragments, "")), " ")
		if text == "" || text == "//" {
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
	Hash       string  `json:"hash"`
	SongName   string  `json:"songname"`
	SingerName string  `json:"singername"`
	AlbumName  string  `json:"album_name"`
	AlbumID    string  `json:"album_id"`
	Duration   float64 `json:"duration"` // 秒
	// TransParam.Language:实测坐实酷狗搜索接口自带的语种标签,直接是人类可读字符串
	// ("国语"/"粤语"),交叉验证过周杰伦《稻香》→"国语"、Beyond《海阔天空》→"粤语"。
	TransParam struct {
		Language string `json:"language"`
	} `json:"trans_param"`
}

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

func kugouGet(ctx context.Context, u string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

// resolveKugouLyric:①搜索拿 hash/时长(歌手名+歌名都要对上,同 netease/qq 的身份校验);
// ②用 hash+时长 查 KRC 歌词库候选(krcs.kugou.com,官方推荐候选优先,取第一条);
// ③用候选的 id+accesskey 下载两次(lyrics.kugou.com,分别 fmt=lrc 整行、fmt=krc 逐字,
// 同一个 id/accesskey,只是 fmt 参数不同)。lrc 失败则整体放弃;krc 单独失败不影响 lrc
// (逐字数据本来就是"有更好、没有也不影响整行可用"的加分项)。任何一步
// 失败/拿不到都直接放弃,不重试(下次 enrich 短 TTL 到期自然再试)。
func resolveKugouLyric(ctx context.Context, artist, title, album string, durationSecs float64) kugouResult {
	// 搜索词逐个 variant 试,先命中先用(顺序由 searchTitleVariants 定,跟设置走)。带括号的标题在酷狗
	// 上不会返回空、而是回一串该歌手的热门歌,所以"搜砸了"表现为 pickKugouSearchCandidate
	// 一条都收不下,不是 kugouGet 报错——必须靠 chosen==nil 才能发现,不能只在 err != nil
	// 时才换词。详见 searchTitleVariants 的注释。第二跳(krcs 查 KRC 候选)不受影响:实测
	// 同一个 hash 下 keyword 带不带括号返回的候选完全一致,身份是 hash 认的。
	var chosen *kugouSong
	for _, q := range searchTitleVariants(title) {
		var sr struct {
			Data struct {
				Info []kugouSong `json:"info"`
			} `json:"data"`
		}
		if err := kugouGet(ctx, "http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword="+kugouEscape(artist+" "+q)+"&page=1&pagesize=10&showtype=1", &sr); err != nil {
			continue
		}
		if lyricSearchItemsTap != nil {
			lyricSearchItemsTap("kugou", artist, title, album, durationSecs, sr.Data.Info)
		}
		chosen = pickKugouSearchCandidate(sr.Data.Info, artist, title, album, durationSecs)
		if chosen != nil {
			break
		}
	}
	if chosen == nil {
		return kugouResult{}
	}
	durMs := int64(chosen.Duration * 1000)
	if durMs <= 0 && durationSecs > 0 {
		durMs = int64(durationSecs * 1000)
	}
	var kr struct {
		Candidates []struct {
			ID        string `json:"id"`
			AccessKey string `json:"accesskey"`
		} `json:"candidates"`
	}
	krcURL := fmt.Sprintf("http://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=%s&duration=%d&hash=%s",
		kugouEscape(artist+" - "+title), durMs, chosen.Hash)
	if err := kugouGet(ctx, krcURL, &kr); err != nil || len(kr.Candidates) == 0 {
		return kugouResult{}
	}
	c := kr.Candidates[0]
	if c.ID == "" || c.AccessKey == "" {
		return kugouResult{}
	}
	var dl struct {
		Content string `json:"content"`
	}
	dlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=lrc&charset=utf8", c.ID, c.AccessKey)
	if err := kugouGet(ctx, dlURL, &dl); err != nil || dl.Content == "" {
		return kugouResult{}
	}
	raw, err := base64.StdEncoding.DecodeString(dl.Content)
	if err != nil {
		return kugouResult{}
	}
	lrc := string(raw)
	if !isTimedLRC(lrc) {
		return kugouResult{}
	}

	var yrc, tr, roma string
	var krcDl struct {
		Content string `json:"content"`
	}
	krcDlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=krc&charset=utf8", c.ID, c.AccessKey)
	if err := kugouGet(ctx, krcDlURL, &krcDl); err == nil && krcDl.Content != "" {
		if decrypted := decryptKRC(krcDl.Content); decrypted != "" {
			// `[language:<base64>]` 那一行先摘出来(它是译文/罗马音两轨的载体,8~12KB 的
			// base64,原样留在逐字数据里只是一行 App 读不懂的垃圾、还会随 .yrc 导出),剩余
			// 正文才进 krcToYRC;两轨按 KRC 行序号对齐行始时间戳,见 krcLanguageTracks。
			lang, body := splitKRCLanguageLine(decrypted)
			yrc = krcToYRC(body)
			tr, roma = krcLanguageTracks(lang, body)
		}
	}
	return kugouResult{lrc: lrc, yrc: yrc, tr: tr, roma: roma, durationSecs: chosen.Duration, title: chosen.SongName, artist: chosen.SingerName, album: chosen.AlbumName, language: kugouCanonicalLanguage(chosen.TransParam.Language), cover: kugouAlbumCoverURL(ctx, chosen.AlbumID)}
}

// pickKugouSearchCandidate 从一页搜索结果里挑"这份歌词该跟谁走"。
//
// 2026-09-01 之前是**第一条过闸就收工**——闸门只有标题(lyricTitleAccepted)和歌手,完全
// 不看专辑和时长,于是排序靠前的杂项能把同页靠后的正主顶掉。真实案例(周杰伦《简单爱
// (Live)》/《The One 周杰伦演唱会》,本地 273.227s):酷狗对"周杰伦 简单爱 (Live)"返回的
// 第 1 条是「简单爱 (无与伦比演唱会 m 56s)」——一个 56 秒的片段、专辑名为空,剥括号后
// 标题也叫"简单爱"、歌手也对,先到先得直接定死;而第 2 条就是「简单爱 (Live)」《The One
// 演唱会》273s——**标题跟本地 normLoose 精确相等 + 专辑 token 对得上 + 时长只差 0.227s**,
// 三项证据全在,却永远轮不到。netease.go 的 queries 注释里早写过这个对比:"那三个源是取
// 第一条通过校验的候选就收工,搜索词一偏就直接定死在错版本上"——这里把酷狗从那个名单里
// 摘出来。
//
// 排序键(闸门原样保留,只改"过闸之后信谁"):
//  1. 标题档位:normLoose 精确同名 > 剥括号后相等 > 其它过闸形态(跟 QQ 专辑维度路线
//     resolveQQMatchViaAlbum 的三档完全同构);
//  2. 同档位比 albumScore(200 精确 / 100 包含 / token 数,见 match.go);
//  3. 再同分比时长贴近度(本地或候选缺时长的当 +Inf,排最后);
//  4. 全都打平保持原序(搜索相关性排序,= 改动前的行为)。
//
// 只有一条过闸时四个键全部无事发生,跟旧行为逐位一致。
func pickKugouSearchCandidate(songs []kugouSong, artist, title, album string, durationSecs float64) *kugouSong {
	const (
		tierExact = iota
		tierStripped
		tierAccepted
	)
	nt := normLoose(title)
	st := normLoose(stripParens(title))
	var best *kugouSong
	bestTier, bestAlbum := 0, 0
	bestDur := math.Inf(1)
	bestByTriangle, bestFits := false, false
	for i := range songs {
		s := &songs[i]
		// 判定用的始终是**本地原样标题** title,不是搜索词——放宽的只是"拿什么去搜",
		// 不是"什么算匹配"。
		// 歌手闸用 lyricSourceArtistMatches:酷狗的合唱署名固定用顿号("UMI、V"),
		// 本地标签是 "&" 或换了合作者语言写法("UMI & 金泰亨")时 artistMatches 会把
		// 服务端明明召回成功的正主原地拒掉——酷狗没有 loose 兜底,这一闸拒完整源就空了。
		if s.Hash == "" || !lyricTitleAccepted(s.SongName, title) {
			continue
		}
		byTriangle := false
		if !lyricSourceArtistMatches(s.SingerName, artist) {
			// 歌手闸不过 → 还有第二条依据:标题逐字同名 + 专辑对得上 + 时长紧密吻合
			// = 同一次录音。修的是"艺名↔本名 / 乐队名↔成员名"这类连分隔符都没有、
			// 段集交集档和别名轮都够不到的署名分歧(实测案例见
			// lyricRecordingTriangleMatches 的注释)。酷狗是各源里唯一**已经把正主
			// 排在搜索结果第 1 位、只差这一闸**的源,而且它带 YRC 逐字。
			if !lyricRecordingTriangleMatches(s.SongName, s.AlbumName, s.Duration,
				title, album, durationSecs) {
				continue
			}
			byTriangle = true
		}
		tier := tierAccepted
		switch {
		case normLoose(s.SongName) == nt:
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
	// 日志只报**最终选中**的那条(改成全页排序之前,triangle 一接受就等于选中,日志语义
	// 是一回事;现在 triangle 接受的候选也可能被排序比下去,不选中就不该说 accepted)。
	if best != nil && bestByTriangle {
		log.Printf("lyrics: kugou accepted %q by recording triangle (local artist %q vs source %q; album %q vs %q; dur %.3f vs %.3f)",
			best.SongName, artist, best.SingerName, album, best.AlbumName, durationSecs, best.Duration)
	}
	return best
}

// kugouAlbumCoverURL 按专辑 ID 查 album/info 接口拿封面(2026-08-31 加)。响应的
// imgurl 字段是个带 "{size}" 占位符的模板(如
// "http://imge.kugou.com/stdmusic/{size}/…/….jpg"),换成具体像素数才是能直接访问的
// URL——400/480/800 实测都能 200,这里用 480,跟 qqCoverMaxEdge 取的档位量级一致。
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
	cover := strings.ReplaceAll(out.Data.ImgURL, "{size}", "480")
	// ⚠️ 2026-08-31 真实bug(用户报"酷狗的没有返回封面",截图里酷狗那条候选是空白占位图,
	// netease 那条却有缩略图):酷我/acg 的这个接口原样返回的是 "http://" 前缀,collector
	// 这边发请求不受影响(没有 ATS 限制),但这个 URL 之后会原样进 lyricCandidate.cover、
	// 一路传到 Swift 侧的 AsyncImage——macOS App Transport Security 默认拒绝纯 HTTP 的
	// 网络请求,图片静默加载失败、退回占位图标,不会报错也不会抛异常,只在真机 UI 上才
	// 看得出来(拿 CLI 直查 cover_url 字符串本身看不出这个问题,之前用这个办法验证过、
	// 没发现是因为凑巧没测到走 http 这条路的场景)。实测坐实同一张图换成 https 也是 200,
	// 强制换成 https 就地修好,不需要额外配置 ATS 例外域名(改 Info.plist 加白名单域名是
	// 更大范围的例外,没必要为一张图开这个口子)。
	return strings.Replace(cover, "http://", "https://", 1)
}
