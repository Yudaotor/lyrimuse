package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	neturl "net/url"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"unicode"
)

// vibeLyric 是 Naver VIBE 这一路:搜索 → 按元数据重新打分排序 → 并发拉前几条的歌词 → 按名次挑第一份带同步时间轴的。
// 两个接口都是 VIBE 网页端在用的 `apis.naver.com/vibeWeb/musicapiweb`,不要账号、不签名,回 JSON。
//
// 只有逐行(`syncLyric.startTimeIndex` 秒数 + `contents[].text`),没有逐字。外语歌多一轨韩文译文(`languageType`
// 为 "ko" 的那份 contents,跟原文逐句对齐,没译的句子是空串),译文语言设成韩文时用得上。没有同步歌词、只有
// `normalLyric` 纯文本时交 plainOnly。
//
// 曲库是全球的,但写法按韩国习惯:中文歌用繁体、歌手名是韩文音译(周杰伦 →「주걸륜」),外语歌名后面常挂一段
// 韩文读音 / 译名的括号(「晴天(청천)」「夜に駆ける (밤을 달리다, Into The Night / Yoru ni Kakeru)」),韩国歌手
// 写成「아이유(IU)」(歌手闸本来就认这种「本名(别名)」)。歌名的括号由 vibeSongTitle 去掉;歌手对不上时
// 走「同名 + 专辑对得上 + 时长吻合」的三角验证兜底,同网易云 / 酷狗 / 汽水。时间轴的实测见 09 章决策 279。
//
// 网页端接口、没有公开文档,跟 kuwo.go / migu.go 同一类风险(可能随时改形状或要求验证)。
type vibeResult struct {
	lyrics, title, artist, album, cover string
	// tr:韩文译文轨,时间戳跟正文同一份;原文就是韩文或没有译文时为空。
	tr string
	// durationSecs:搜索结果自报的时长(`playTime`,精确到秒),0 = 没给。
	durationSecs float64
	plainOnly    bool
}

const (
	vibeAPIBase = "https://apis.naver.com/vibeWeb/musicapiweb"
	// vibeSearchDisplay:一次搜索取几条。同名的 MR(伴奏)、翻唱、Live 常排在原版后面几位,10 条够把原版留在里面。
	vibeSearchDisplay = 10
	// vibeMaxCandidatesToFetch:过了身份闸之后最多并发拉几条歌词。VIBE 的排序基本可信,原版通常在前两位。
	vibeMaxCandidatesToFetch = 3
	// vibeScoreDurationTolerance 跟别的源的时长闸(match.go 的 0.25)取同一个值。
	vibeScoreDurationTolerance = 0.25
	// vibeMaxDurationDiffSecs:两边时长都知道时差多少秒就不是同一版。VIBE 的 playTime 精确到秒,同一版跟播放器报的差
	// 不过一两秒;差十几秒的是另一个剪辑(Remix、节目现场版),时间轴整体错开(09 章决策 283)。
	vibeMaxDurationDiffSecs = 8.0
	// vibeTranslationLang:VIBE 只给韩文译文。
	vibeTranslationLang = "ko"
)

var (
	vibeMu    sync.Mutex
	vibeCache = map[string]vibeResult{}
)

func vibeLyric(ctx context.Context, artist, title, album string, durationSecs float64) vibeResult {
	if title == "" {
		return vibeResult{}
	}
	// 带上时长:选候选要过时长闸,同名的不同剪辑(~durN 变体)不能共用一份结果。
	key := artist + "|" + title + "|" + album + "|" + strconv.Itoa(int(math.Round(durationSecs)))
	vibeMu.Lock()
	if v, ok := vibeCache[key]; ok {
		vibeMu.Unlock()
		return v
	}
	vibeMu.Unlock()

	ctx, sub := withLyricSubFetch(ctx)
	r := resolveVibeLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" && sub.complete(ctx) {
		vibeMu.Lock()
		vibeCache[key] = r
		vibeMu.Unlock()
	}
	return r
}

type vibeArtist struct {
	Name string `json:"artistName"`
}

// vibeSearchItem 是搜索结果里用得上的字段。
type vibeSearchItem struct {
	TrackID      int64        `json:"trackId"`
	Title        string       `json:"trackTitle"`
	Artists      []vibeArtist `json:"artists"`
	PlayTime     string       `json:"playTime"` // "mm:ss",不知道时是 "00:00"
	HasLyric     bool         `json:"hasLyric"`
	HasSyncLyric bool         `json:"hasSyncLyric"`
	// IsAdult:19 禁曲目,取词要成人认证(不登录回 403 NO_PERMISSON),拿不到。
	IsAdult bool `json:"isAdult"`
	Album   struct {
		Title    string `json:"albumTitle"`
		ImageURL string `json:"imageUrl"`
	} `json:"album"`
}

func (it vibeSearchItem) artistName() string {
	names := make([]string, 0, len(it.Artists))
	for _, a := range it.Artists {
		if n := strings.TrimSpace(a.Name); n != "" {
			names = append(names, n)
		}
	}
	return strings.Join(names, ", ")
}

func vibeSearch(ctx context.Context, query string) ([]vibeSearchItem, error) {
	u := vibeAPIBase + "/v4/search/track?query=" + neturl.QueryEscape(query) +
		"&start=1&display=" + strconv.Itoa(vibeSearchDisplay)
	var out struct {
		Response struct {
			Result struct {
				Tracks []vibeSearchItem `json:"tracks"`
			} `json:"result"`
		} `json:"response"`
	}
	if err := vibeGetJSON(ctx, u, &out); err != nil {
		return nil, err
	}
	return out.Response.Result.Tracks, nil
}

type vibeLyricContent struct {
	LanguageType string   `json:"languageType"`
	Text         []string `json:"text"`
}

type vibeLyricBody struct {
	HasSyncLyric bool `json:"hasSyncLyric"`
	NormalLyric  struct {
		Text string `json:"text"`
	} `json:"normalLyric"`
	SyncLyric struct {
		StartTimeIndex []float64          `json:"startTimeIndex"`
		Contents       []vibeLyricContent `json:"contents"`
	} `json:"syncLyric"`
}

func vibeFetchLyric(ctx context.Context, trackID int64) (vibeLyricBody, error) {
	var out struct {
		Response struct {
			Result struct {
				Lyric vibeLyricBody `json:"lyric"`
			} `json:"result"`
		} `json:"response"`
	}
	err := vibeGetJSON(ctx, fmt.Sprintf("%s/vibe/v4/lyric/%d", vibeAPIBase, trackID), &out)
	return out.Response.Result.Lyric, err
}

// vibeStatusError:VIBE 回了非 200。取词的 403(19 禁要成人认证)、404(没有这首的词)是答了「没有」,不算没问成。
type vibeStatusError int

func (e vibeStatusError) Error() string { return fmt.Sprintf("status %d", int(e)) }

func vibeAnsweredNone(err error) bool {
	var se vibeStatusError
	return errors.As(err, &se) && (se == http.StatusForbidden || se == http.StatusNotFound)
}

// vibeFeatSegmentRe / vibeFeatTailRe:歌名里的合作者段(括号里带 feat / ft / with / prod 的,以及末尾不带括号的 feat. …)。
var (
	vibeFeatSegmentRe = regexp.MustCompile(`(?i)\s*[(\[（【][^()\[\]（）【】]*\b(?:feat|ft|featuring|with|prod)\b[^()\[\]（）【】]*[)\]）】]`)
	vibeFeatTailRe    = regexp.MustCompile(`(?i)\s+(?:feat|ft|featuring)\b.*$`)
)

// vibeQueryText 把歌名 / 歌手整理成 VIBE 搜得动的检索词。VIBE 的搜索碰到这几样就一条都不回:「feat」这个词(带不带括号都一样)、
// 撇号(「I Don't Love You」0 条、「I Dont Love You」5 条)、「&」(换成空格才有);括号本身不碍事。纯函数,便于单测。
func vibeQueryText(s string) string {
	s = vibeFeatSegmentRe.ReplaceAllString(s, "")
	s = vibeFeatTailRe.ReplaceAllString(s, "")
	s = strings.NewReplacer("'", "", "’", "", "‘", "", "`", "", "&", " ", "＆", " ").Replace(s)
	return strings.Join(strings.Fields(s), " ")
}

func vibeGetJSON(ctx context.Context, u string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(vibeHTTPTimeout), req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return vibeStatusError(resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, lyricSourceResponseMaxBytes)).Decode(out)
}

// vibeBuildLRC 把 startTimeIndex 和同序号的一份 contents 拼成 LRC。空句写成只有时间戳的行(那是一句唱完、
// 后面是间奏的标记);两边长度不一致时按短的那份;时间倒退的句子丢掉。纯函数,便于单测。
func vibeBuildLRC(starts []float64, text []string) string {
	var b strings.Builder
	last := -1
	for i := 0; i < len(starts) && i < len(text); i++ {
		ms := int(math.Round(starts[i] * 1000))
		if ms < 0 || ms < last {
			continue
		}
		last = ms
		b.WriteString(formatLRCStamp(ms) + strings.TrimSpace(text[i]) + "\n")
	}
	return b.String()
}

// vibeLyricTracks 取出原文和韩文译文两份 contents。原文是 languageType 不为 "ko" 的第一份;原文本身就是韩文时
// 只有 "ko" 那一份,它就是原文、没有译文。
func vibeLyricTracks(contents []vibeLyricContent) (orig, ko []string) {
	var koTrack []string
	for _, c := range contents {
		if c.LanguageType == vibeTranslationLang {
			if koTrack == nil {
				koTrack = c.Text
			}
			continue
		}
		if orig == nil {
			orig = c.Text
		}
	}
	if orig == nil {
		return koTrack, nil
	}
	return orig, koTrack
}

// vibeBuildTranslation 只留有字的句子:没译的句子(空串)不写,免得译文轨里出现一行行空白。
func vibeBuildTranslation(starts []float64, ko []string) string {
	var b strings.Builder
	for _, line := range strings.Split(vibeBuildLRC(starts, ko), "\n") {
		if i := strings.Index(line, "]"); i >= 0 && strings.TrimSpace(line[i+1:]) != "" {
			b.WriteString(line + "\n")
		}
	}
	return b.String()
}

// vibePlayTimeSecs 解析 "mm:ss" / "h:mm:ss";"00:00"(VIBE 不知道时长时这么写)和解析不动的都是 0。纯函数,便于单测。
func vibePlayTimeSecs(s string) float64 {
	parts := strings.Split(strings.TrimSpace(s), ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0
	}
	total := 0
	for _, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return 0
		}
		total = total*60 + n
	}
	return float64(total)
}

// vibeCoverURL:专辑图去掉缩放参数(`?type=r480Fll&v=…`)就是原图(实测 3000 像素)。
func vibeCoverURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if i := strings.Index(raw, "?"); i >= 0 {
		raw = raw[:i]
	}
	if !strings.HasPrefix(raw, "https://") {
		return ""
	}
	return raw
}

// vibeReadingSuffixRe:歌名末尾的一段括号。
var vibeReadingSuffixRe = regexp.MustCompile(`^(.*\S)\s*[(（]([^()（）]*)[)）]$`)

// vibeVersionWords:括号里有这些词就是版本说明,不是读音 / 译名,得留着给版本闸看。
var vibeVersionWords = []string{"live", "remix", "ver", "inst", "mr", "acoustic", "cover", "edit", "mix",
	"라이브", "리믹스", "버전", "커버", "반주", "어쿠스틱"}

// vibeSongTitle 去掉 VIBE 给外语歌名附加的韩文读音 / 译名括号(「晴天(청천)」→「晴天」)。只在括号里有韩文、括号前
// 一个韩文字都没有、括号里也没有版本词时去:韩文歌名自己的括号(「밤편지 (Through the Night)」)和版本说明都留着。
// 纯函数,便于单测。
func vibeSongTitle(name string) string {
	m := vibeReadingSuffixRe.FindStringSubmatch(strings.TrimSpace(name))
	if m == nil || !containsHangul(m[2]) || containsHangul(m[1]) {
		return name
	}
	inner := strings.ToLower(m[2])
	for _, w := range vibeVersionWords {
		if strings.Contains(inner, w) {
			return name
		}
	}
	return m[1]
}

func containsHangul(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Hangul, r) {
			return true
		}
	}
	return false
}

// vibeCandidateScore 给一条搜索结果打分,越高越像本地这首;负数 = 淘汰。身份判定用跟别的源一致的函数,
// 歌手对不上时退到三角验证(lyricRecordingTriangleMatchesGuarded)。纯函数,便于单测。
func vibeCandidateScore(item vibeSearchItem, artist, title, album string, durationSecs float64) int {
	if item.IsAdult || (!item.HasLyric && !item.HasSyncLyric) {
		return -1
	}
	name := vibeSongTitle(item.Title)
	if !lyricTitleAccepted(name, title) {
		return -1
	}
	d := vibePlayTimeSecs(item.PlayTime)
	if !lyricSourceArtistMatches(item.artistName(), artist) &&
		!lyricRecordingTriangleMatchesGuarded(name, item.Album.Title, item.artistName(), d, title, album, artist, durationSecs) {
		return -1
	}
	if versionTagsMismatch(title, album, name, item.Album.Title) {
		return -1
	}
	score := 100
	if item.HasSyncLyric {
		score += 20
	}
	if durationSecs > 0 && d > 0 {
		diff := math.Abs(d-durationSecs) / durationSecs
		if diff > vibeScoreDurationTolerance || math.Abs(d-durationSecs) > vibeMaxDurationDiffSecs {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

// vibeQueries:按顺序要搜的检索词(「歌名 第一位歌手」、只按歌名、原样的歌名),去掉空的和重复的 —— 没有歌手时前两条是同一个串,
// 歌名没被清理过时第三条跟第二条相同。VIBE 和 Genie 共用。
func vibeQueries(qTitle, withArtist, raw string) []string {
	var out []string
	for _, q := range []string{withArtist, qTitle, raw} {
		if q != "" && !slices.Contains(out, q) {
			out = append(out, q)
		}
	}
	return out
}

// resolveVibeLyric:先按「歌名 第一位歌手」搜(都过一遍 vibeQueryText),一条都没过闸再只按歌名搜一次(歌手在 VIBE 上常是另一种写法,
// 写进检索词反而搜不到),还没有且歌名被清理过时再按原样的歌名搜一次;过闸的按分数取前几条并发拉歌词,按名次挑第一份带同步时间轴的。全都只有纯文本时交名次最高的那份。
func resolveVibeLyric(ctx context.Context, artist, title, album string, durationSecs float64) vibeResult {
	type scoredItem struct {
		item  vibeSearchItem
		score int
	}
	qTitle := vibeQueryText(lyricQueryTitle(title))
	// 合作者写法跟 VIBE 一致时,带着 feat 段反而搜得到(歌名跟专辑同名时,只按歌名搜,前 10 条全是这张专辑的别的歌)。
	queries := vibeQueries(qTitle, strings.TrimSpace(qTitle+" "+vibeQueryText(firstCreditedArtist(artist))),
		strings.TrimSpace(lyricQueryTitle(title)))
	var candidates []scoredItem
	for qi, q := range queries {
		items, err := vibeSearch(ctx, q)
		if err != nil {
			return vibeResult{}
		}
		for _, it := range items {
			if it.TrackID == 0 {
				continue
			}
			if s := vibeCandidateScore(it, artist, title, album, durationSecs); s >= 0 {
				candidates = append(candidates, scoredItem{it, s})
			}
		}
		if len(candidates) > 0 || qi == len(queries)-1 {
			break
		}
	}
	if len(candidates) == 0 {
		return vibeResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > vibeMaxCandidatesToFetch {
		candidates = candidates[:vibeMaxCandidatesToFetch]
	}

	bodies := make([]*vibeLyricBody, len(candidates))
	failed := make([]bool, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, id int64) {
			defer wg.Done()
			body, err := vibeFetchLyric(ctx, id)
			if err != nil {
				failed[rank] = !vibeAnsweredNone(err)
				return
			}
			bodies[rank] = &body
		}(i, c.item.TrackID)
	}
	wg.Wait()

	result := func(it vibeSearchItem) vibeResult {
		return vibeResult{title: vibeSongTitle(it.Title), artist: it.artistName(), album: it.Album.Title,
			cover: vibeCoverURL(it.Album.ImageURL), durationSecs: vibePlayTimeSecs(it.PlayTime)}
	}
	var plain *vibeResult
	for rank, body := range bodies {
		if body == nil {
			if failed[rank] {
				noteLyricSubFetchFailure(ctx)
			}
			continue
		}
		orig, ko := vibeLyricTracks(body.SyncLyric.Contents)
		if lrc := vibeBuildLRC(body.SyncLyric.StartTimeIndex, orig); body.HasSyncLyric && isTimedLRC(lrc) {
			r := result(candidates[rank].item)
			r.lyrics = lrc
			r.tr = vibeBuildTranslation(body.SyncLyric.StartTimeIndex, ko)
			return r
		}
		if plain == nil && strings.TrimSpace(body.NormalLyric.Text) != "" {
			r := result(candidates[rank].item)
			r.lyrics, r.plainOnly = strings.TrimSpace(body.NormalLyric.Text), true
			plain = &r
		}
	}
	if plain != nil {
		return *plain
	}
	return vibeResult{}
}
