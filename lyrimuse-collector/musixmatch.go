// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// musixmatchLyric 是歌词第五个候选来源。Musixmatch 是 Spotify 官方合作的歌词供应商，
// 对欧美/日韩等非中文曲库的覆盖明显强于网易云/QQ/酷狗——这几个平台的曲库/搜索索引
// 都是按中文舞台名/中文曲库编的,对纯西文/日韩曲目常常查不到或版本不对。用的是
// apic-desktop.musixmatch.com 这个非官方逆向接口(没有官方文档,但被 syncedlyrics
// 等大量开源项目复用,是"公开的秘密"),固定身份标识 app_id=web-desktop-app-v1.0。
//
// 三段式:①token.get 匿名拿一个临时 usertoken(10 分钟有效,不需要用户任何操作,
// 401 时按官方样例退避 10 秒重试一次);②track.search 按歌手+歌名搜出 track_id(挑
// has_subtitles==1 的结果,没有逐行歌词的候选后面必然 404,不值得白跑一趟);
// ③用 track_id 查 track.subtitle.get(逐行 LRC,当作候选正文)+ track.richsync.get
// (逐字,词级,归一化成 YRCParser 语法,查不到不影响逐行结果)+ 可选的
// crowd.track.translations.get(社区翻译,按 features.LyricsTranslationLanguage
// 指定目标语言——netease/QQ 的译文固定是中文,这是目前唯一能自选语言的译文来源)。
//
// 用 apic-appmobile(mac-ios-v2.0)这组 host+app_id,不是网上大多数参考实现
// (syncedlyrics 等)默认用的 apic-desktop(web-desktop-app-v1.0)——开发时实测
// apic-desktop 在这台机器的网络环境下 token.get 稳定返回 401 hint=captcha(被
// Musixmatch 的反爬风控拦了,不是我方请求有误),换成 apic-appmobile+mac-ios-v2.0
// 立刻能拿到正常 200 的 token,后续 search/subtitle/richsync/translations 四个
// 端点在这组 host+app_id 下逐一实测全部通过。两组 host+app_id 分别对应 Musixmatch
// 桌面网页版/iOS App 客户端,接口形状完全一致,只是反爬策略不同,选哪组纯粹是"哪个
// 实测不被拦"的问题。
const (
	musixmatchAppID   = "mac-ios-v2.0"
	musixmatchBaseURL = "https://apic-appmobile.musixmatch.com/ws/1.1/"
)

type musixmatchResult struct {
	lrc string
	yrc string // 归一化成 YRCParser 语法后的逐字数据,没有则空串
	tr  string // 译文(逐行 LRC),语言取决于调用时传入的 features.LyricsTranslationLanguage,没有则空串
	// title/artist/album/cover 是 Musixmatch 曲库里这首歌实际匹配到的信息——纯粹给
	// "搜索候选歌词"弹窗展示用,不参与任何匹配/打分逻辑,取自 track.search 响应本身
	// (本来就已经查到,只是原来没往外传)。cover 用 500x500 这档,跟网易云封面挑的
	// 尺寸量级接近,不用最大的 800x800(候选列表里的小图不需要)。
	title, artist, album, cover string
}

var (
	musixmatchMu    sync.Mutex
	musixmatchCache = map[string]musixmatchResult{} // artist|title|trLang -> result

	musixmatchTokenMu     sync.Mutex
	musixmatchToken       string
	musixmatchTokenExpiry time.Time
)

func musixmatchLyric(artist, title string, durationSecs float64, trLang string) musixmatchResult {
	if title == "" {
		return musixmatchResult{}
	}
	key := artist + "|" + title + "|" + trLang
	musixmatchMu.Lock()
	if v, ok := musixmatchCache[key]; ok {
		musixmatchMu.Unlock()
		return v
	}
	musixmatchMu.Unlock()

	r := resolveMusixmatchLyric(artist, title, durationSecs, trLang)
	if r.lrc != "" {
		musixmatchMu.Lock()
		musixmatchCache[key] = r
		musixmatchMu.Unlock()
	}
	return r
}

func resolveMusixmatchLyric(artist, title string, durationSecs float64, trLang string) musixmatchResult {
	_ = durationSecs // 时长匹配交给 enrich.go 统一的 scoreLyricCandidate,这里不用
	match, ok := musixmatchSearchTrack(artist, title)
	if !ok {
		return musixmatchResult{}
	}
	lrc := musixmatchSubtitleLRC(match.trackID)
	if lrc == "" {
		return musixmatchResult{}
	}
	yrc := musixmatchRichsync(match.trackID)
	tr := musixmatchTranslationLRC(match.trackID, lrc, trLang)
	return musixmatchResult{lrc: lrc, yrc: yrc, tr: tr, title: match.title, artist: match.artist, album: match.album, cover: match.cover}
}

// musixmatchEnsureToken 返回一个可用的 usertoken——已缓存且未过期直接复用,否则重新
// 获取。10 分钟官方有效期,提前 1 分钟当作过期主动换新,避免临界点上请求刚发出就失效。
func musixmatchEnsureToken() string {
	musixmatchTokenMu.Lock()
	if musixmatchToken != "" && time.Now().Before(musixmatchTokenExpiry) {
		t := musixmatchToken
		musixmatchTokenMu.Unlock()
		return t
	}
	musixmatchTokenMu.Unlock()
	return musixmatchFetchToken(0)
}

// musixmatchFetchToken 请求一个新 token。401 表示这次匿名请求被限流/拒绝,官方样例
// (syncedlyrics)的做法是退避 10 秒重试一次——这里只重试一次(retry>=1 就放弃),不
// 无限重试卡住调用方。
func musixmatchFetchToken(retry int) string {
	if retry > 1 {
		return ""
	}
	body, err := musixmatchDo("token.get", neturl.Values{"user_language": {"en"}})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				UserToken string `json:"user_token"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil {
		return ""
	}
	if out.Message.Header.StatusCode == 401 {
		time.Sleep(10 * time.Second)
		return musixmatchFetchToken(retry + 1)
	}
	token := out.Message.Body.UserToken
	if token == "" {
		return ""
	}
	musixmatchTokenMu.Lock()
	musixmatchToken = token
	musixmatchTokenExpiry = time.Now().Add(9 * time.Minute)
	musixmatchTokenMu.Unlock()
	return token
}

// musixmatchDo 发起一次带统一身份参数(app_id/usertoken/t)的请求。action=="token.get"
// 时不附带 usertoken(避免 musixmatchEnsureToken→musixmatchDo→musixmatchEnsureToken
// 递归),其余 action 都需要先有一个可用 token。
func musixmatchDo(action string, params neturl.Values) ([]byte, error) {
	if action != "token.get" {
		if token := musixmatchEnsureToken(); token != "" {
			params.Set("usertoken", token)
		}
	}
	params.Set("app_id", musixmatchAppID)
	params.Set("t", strconv.FormatInt(time.Now().UnixMilli(), 10))
	req, err := http.NewRequest(http.MethodGet, musixmatchBaseURL+action+"?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 8 * time.Second}, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("musixmatch %s: status %d", action, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// musixmatchTrackMatch 是 musixmatchSearchTrack 选中的候选——title/artist/album/cover
// 是 track.search 响应本身自带的字段(album_name/album_coverart_500x500,实测坐实真的
// 存在,不是猜的),本来就已经查到,只是原来只取了 trackID 就把其余字段丢了。
type musixmatchTrackMatch struct {
	trackID                     int64
	title, artist, album, cover string
}

// musixmatchSearchTrack 按歌手+歌名分字段搜索(q_artist/q_track,不是拼成一个字符串的
// q——实测同一首歌用分字段搜索时,官方原唱排第一;拼成一个字符串搜索,排在前面的经常是
// 同名翻唱/伴奏/合集这类噪音,即使歌手歌名都对得上字符串也不是真正想要的那个版本)。
// s_track_rating=desc 让热门/权威版本排前面,进一步降低选到冷门错误版本的概率。取第一条
// 歌手/歌名都对上、且 has_subtitles==1(没有逐行歌词的候选后面 track.subtitle.get 必然
// 404,不必跑这一趟)的结果。
func musixmatchSearchTrack(artist, title string) (musixmatchTrackMatch, bool) {
	body, err := musixmatchDo("track.search", neturl.Values{
		"q_artist":       {artist},
		"q_track":        {title},
		"s_track_rating": {"desc"},
		"page_size":      {"5"},
		"page":           {"1"},
	})
	if err != nil {
		return musixmatchTrackMatch{}, false
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				TrackList []struct {
					Track struct {
						TrackID              int64  `json:"track_id"`
						TrackName            string `json:"track_name"`
						ArtistName           string `json:"artist_name"`
						AlbumName            string `json:"album_name"`
						AlbumCoverart500x500 string `json:"album_coverart_500x500"`
						HasSubtitles         int    `json:"has_subtitles"`
					} `json:"track"`
				} `json:"track_list"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return musixmatchTrackMatch{}, false
	}
	for _, t := range out.Message.Body.TrackList {
		if t.Track.HasSubtitles != 1 {
			continue
		}
		if lyricTitleAccepted(t.Track.TrackName, title) && artistMatches(t.Track.ArtistName, artist) {
			return musixmatchTrackMatch{
				trackID: t.Track.TrackID,
				title:   t.Track.TrackName,
				artist:  t.Track.ArtistName,
				album:   t.Track.AlbumName,
				cover:   t.Track.AlbumCoverart500x500,
			}, true
		}
	}
	return musixmatchTrackMatch{}, false
}

// musixmatchSubtitleLRC 取该 track_id 官方的逐行 LRC 歌词,当作候选正文。
func musixmatchSubtitleLRC(trackID int64) string {
	body, err := musixmatchDo("track.subtitle.get", neturl.Values{
		"track_id":        {strconv.FormatInt(trackID, 10)},
		"subtitle_format": {"lrc"},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				Subtitle struct {
					SubtitleBody string `json:"subtitle_body"`
				} `json:"subtitle"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return ""
	}
	lrc := out.Message.Body.Subtitle.SubtitleBody
	if !isTimedLRC(lrc) {
		return ""
	}
	return lrc
}

type musixmatchRichsyncWord struct {
	C string  `json:"c"` // 词文本
	O float64 `json:"o"` // 相对所在行行始的偏移,秒
}

type musixmatchRichsyncLine struct {
	Ts float64                  `json:"ts"` // 行始,绝对秒数(从曲目开头算起)
	Te float64                  `json:"te"` // 行末,绝对秒数——实测该字段总是有值,优先用它
	L  []musixmatchRichsyncWord `json:"l"`
}

// musixmatchRichsync 取该 track_id 的逐字(词级)时间轴,归一化成 YRCParser
// (desktop-lyrics)认识的语法。查不到/该曲目没有逐字数据都返回空串,不影响
// musixmatchSubtitleLRC 已经拿到的逐行结果——跟 kugouLyric 的"逐字是加分项,没有不影响
// 整行可用"策略一致。
func musixmatchRichsync(trackID int64) string {
	body, err := musixmatchDo("track.richsync.get", neturl.Values{
		"track_id": {strconv.FormatInt(trackID, 10)},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				Richsync struct {
					RichsyncBody string `json:"richsync_body"`
				} `json:"richsync"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return ""
	}
	raw := out.Message.Body.Richsync.RichsyncBody
	if raw == "" {
		return ""
	}
	var lines []musixmatchRichsyncLine
	if json.Unmarshal([]byte(raw), &lines) != nil || len(lines) == 0 {
		return ""
	}
	return richsyncToYRC(lines)
}

// richsyncToYRC 把 Musixmatch richsync 的行/词绝对时间戳(ts+o,单位秒)转换成
// YRCParser 语法"[行始ms,行长ms](词始ms,词长ms,flag)词"——跟网易云原生 YRC 一样,
// 词始时间戳本来就是绝对值,不需要像酷狗 KRC 那样做相对转绝对的换算(见 krcToYRC
// 注释)。行末优先用 richsync 自带的 te 字段(实测总是有值,行末的绝对秒数);词长
// 则按"到下一个词开始"反推(richsync 不直接给词长)——最后一个词没有下一个词可以
// 反推,退到这一行的行末(te)兜底,只影响 fillFraction 的上限,不影响已经唱到的
// 部分对不对得上。
func richsyncToYRC(lines []musixmatchRichsyncLine) string {
	var b strings.Builder
	for _, ln := range lines {
		lineStartMs := int64(ln.Ts * 1000)
		lineEndMs := int64(ln.Te * 1000)
		if lineEndMs < lineStartMs {
			lineEndMs = lineStartMs
		}
		fmt.Fprintf(&b, "[%d,%d]", lineStartMs, lineEndMs-lineStartMs)
		for j, w := range ln.L {
			wordStartMs := lineStartMs + int64(w.O*1000)
			var wordEndMs int64
			if j+1 < len(ln.L) {
				wordEndMs = lineStartMs + int64(ln.L[j+1].O*1000)
			} else {
				wordEndMs = lineEndMs
			}
			if wordEndMs < wordStartMs {
				wordEndMs = wordStartMs
			}
			fmt.Fprintf(&b, "(%d,%d,0)%s", wordStartMs, wordEndMs-wordStartMs, w.C)
		}
		b.WriteByte('\n')
	}
	return b.String()
}

type musixmatchTranslationItem struct {
	Translation struct {
		SubtitleMatchedLine string `json:"subtitle_matched_line"`
		Description         string `json:"description"`
	} `json:"translation"`
}

var musixmatchLRCLineRe = regexp.MustCompile(`^(\[\d{1,2}:\d{2}[.:]\d{1,3}\])(.*)$`)

// musixmatchTranslationLRC 取该 track_id 的社区翻译(crowd.track.translations.get),
// 目标语言由 lang 指定(ISO 639-1 两位小写代码,如 "en"/"es"/"ja"——见
// FeatureSettingsStore.swift 的 MusixmatchTranslationLanguage)。lang 为空(用户没有
// 启用 Musixmatch 或没配置译文语言)直接跳过,不发这次请求。
func musixmatchTranslationLRC(trackID int64, originalLRC, lang string) string {
	if lang == "" {
		return ""
	}
	body, err := musixmatchDo("crowd.track.translations.get", neturl.Values{
		"track_id":               {strconv.FormatInt(trackID, 10)},
		"subtitle_format":        {"lrc"},
		"translation_fields_set": {"minimal"},
		"selected_language":      {lang},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Body struct {
				TranslationsList []musixmatchTranslationItem `json:"translations_list"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || len(out.Message.Body.TranslationsList) == 0 {
		return ""
	}
	tr := buildTranslatedLRC(originalLRC, out.Message.Body.TranslationsList)
	if !isTimedLRC(tr) {
		return ""
	}
	return tr
}

// buildTranslatedLRC 把 crowd.track.translations.get 返回的"原文行→译文"逐条映射,
// 拼成一份跟原文歌词时间轴对齐的独立 LRC——用原文歌词自己的时间戳(Swift 侧
// LyricsSyncEngine 用 nearestText 按时间戳就近匹配展示译文,不是按行号对应,见
// enrich.go scoredLyricCandidates 里网易云 tr/roma 的同一套用法)。翻译覆盖不全(有些
// 行没有社区翻译)是正常情况,缺的行译文那里就没有对应时间戳,不强行补全。
//
// 外层按原文歌词的时间顺序遍历(不是按 items 本来的顺序)——重复的副歌歌词在原文里
// 会出现好几次,每次出现独立去找一条能对上的翻译,而不是"翻译列表里同一条译文命中了
// 原文第一次出现的位置就不再找第二次"。实测遇到过反过来遍历(items 在外层)会导致
// 多条翻译条目都模糊匹配到原文同一次出现、生成好几行时间戳重复的译文;这样写从根上
// 避免这个问题,顺带让输出天然按时间戳升序(nearestText 的匹配结果不依赖顺序,但升序
// 更符合一份 LRC 文件该有的样子)。
func buildTranslatedLRC(originalLRC string, items []musixmatchTranslationItem) string {
	var parsed []struct{ ts, text string }
	for _, l := range strings.Split(strings.ReplaceAll(originalLRC, "\r\n", "\n"), "\n") {
		m := musixmatchLRCLineRe.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		parsed = append(parsed, struct{ ts, text string }{ts: m[1], text: strings.TrimSpace(m[2])})
	}
	var b strings.Builder
	for _, p := range parsed {
		if p.text == "" {
			continue
		}
		for _, item := range items {
			matched := strings.TrimSpace(item.Translation.SubtitleMatchedLine)
			tr := strings.TrimSpace(item.Translation.Description)
			if matched == "" || tr == "" {
				continue
			}
			if p.text == matched || strings.Contains(p.text, matched) || strings.Contains(matched, p.text) {
				b.WriteString(p.ts)
				b.WriteString(tr)
				b.WriteByte('\n')
				break
			}
		}
	}
	return b.String()
}
