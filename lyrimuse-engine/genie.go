package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// genieLyric 是 Genie(지니뮤직)这一路:搜索 → 按元数据重新打分排序 → 并发拉前几条的歌词 → 按名次挑第一份带同步时间轴的。
// 搜索是 App 端的 `app.genie.co.kr/search/category/songs.json`,一条结果里带齐歌名、歌手、专辑、时长、封面和纯文本歌词;
// 同步歌词是 `dn.genie.co.kr/app/purchase/get_msl.asp`,回 JSONP「起点毫秒 → 一句」的对照表。都不要账号、不签名。
//
// 只有逐行,没有逐字和译文。没有同步歌词时取词回 200「NOT FOUND LYRICS」,这时用搜索结果自带的纯文本交 plainOnly。
// 19 禁曲目照样取得到词,不跳过。写法跟 VIBE 一样按韩国习惯(歌名的韩文读音括号、「本名 (别名)」歌手),歌名清理和
// 检索词清理沿用 vibeSongTitle / vibeQueryText。同步歌词开头有时多出歌名、歌手各一行(geniePrefixHeaderLines 去掉)。
//
// App 端接口、没有公开文档,跟 vibe.go / kuwo.go 同一类风险。
type genieResult struct {
	lyrics, title, artist, album, cover string
	// durationSecs:搜索结果自报的时长(`duration.time`,秒),0 = 没给。
	durationSecs float64
	plainOnly    bool
}

const (
	genieSearchURL = "https://app.genie.co.kr/search/category/songs.json"
	genieLyricURL  = "https://dn.genie.co.kr/app/purchase/get_msl.asp"
	genieImageBase = "https://image.genie.co.kr"
	// genieSearchSize:一次搜索取几条。同名的 MR(伴奏)、Inst.、翻唱常排在原版后面,10 条够把原版留在里面。
	genieSearchSize = 10
	// genieMaxCandidatesToFetch:过了身份闸之后最多并发拉几条歌词。
	genieMaxCandidatesToFetch = 3
	// genieScoreDurationTolerance / genieMaxDurationDiffSecs:时长闸,口径同 VIBE(09 章决策 283)。
	genieScoreDurationTolerance = 0.25
	genieMaxDurationDiffSecs    = 8.0
	// genieNoLyrics:取词接口对没有同步歌词的曲目回的正文。
	genieNoLyrics = "NOT FOUND LYRICS"
	// genieHeaderLineMax:同步歌词开头最多看几行是不是歌名 / 歌手。
	genieHeaderLineMax = 3
)

var (
	genieMu    sync.Mutex
	genieCache = map[string]genieResult{}
)

func genieLyric(ctx context.Context, artist, title, album string, durationSecs float64) genieResult {
	if title == "" {
		return genieResult{}
	}
	key := artist + "|" + title + "|" + album
	genieMu.Lock()
	if v, ok := genieCache[key]; ok {
		genieMu.Unlock()
		return v
	}
	genieMu.Unlock()

	ctx, sub := withLyricSubFetch(ctx)
	r := resolveGenieLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" && sub.complete(ctx) {
		genieMu.Lock()
		genieCache[key] = r
		genieMu.Unlock()
	}
	return r
}

type genieText struct {
	Original string `json:"original"`
}

// genieSearchItem 是搜索结果里用得上的字段。
type genieSearchItem struct {
	SongID   int64     `json:"song_id"`
	Name     genieText `json:"song_name"`
	Artist   genieText `json:"artist_name"`
	Album    genieText `json:"album_name"`
	Duration struct {
		Time float64 `json:"time"`
	} `json:"duration"`
	ImagePath string `json:"image_path"`
	// Lyrics:纯文本歌词。没有同步歌词时就用它。
	Lyrics  string `json:"lyrics"`
	Service struct {
		Lyrics string `json:"lyrics_service_yn"`
	} `json:"service_available"`
}

func (it genieSearchItem) hasLyrics() bool { return it.Service.Lyrics == "Y" }

func genieSearch(ctx context.Context, query string) ([]genieSearchItem, error) {
	u := genieSearchURL + "?query=" + neturl.QueryEscape(query) + "&pg=1&pgsize=" + strconv.Itoa(genieSearchSize)
	body, err := genieGet(ctx, u)
	if err != nil {
		return nil, err
	}
	var out struct {
		SearchResult struct {
			Result struct {
				Songs struct {
					Items []genieSearchItem `json:"items"`
				} `json:"songs"`
			} `json:"result"`
		} `json:"searchResult"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return out.SearchResult.Result.Songs.Items, nil
}

// genieStatusError:Genie 回了非 200。曲目 ID 不存在时取词接口回 500,一律算没问成。
type genieStatusError int

func (e genieStatusError) Error() string { return fmt.Sprintf("status %d", int(e)) }

func genieGet(ctx context.Context, u string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "curl/8.7.1")
	resp, err := doHTTPTracked(lyricHTTPClient(genieHTTPTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, genieStatusError(resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, lyricSourceResponseMaxBytes))
}

// genieLine 是同步歌词的一句。
type genieLine struct {
	ms   int
	text string
}

// genieParseSyncLyric 解析取词接口的正文:`GenieCallback({"7340":"…","13110":"…"});`。没有同步歌词(「NOT FOUND LYRICS」)
// 时 found 为 false、err 为 nil;形状认不出来时返回 err。按起点排序。纯函数,便于单测。
func genieParseSyncLyric(body string) (lines []genieLine, found bool, err error) {
	s := strings.TrimSpace(body)
	if s == genieNoLyrics {
		return nil, false, nil
	}
	lp, rp := strings.Index(s, "("), strings.LastIndex(s, ")")
	if lp < 0 || rp <= lp {
		return nil, false, fmt.Errorf("genie lyric: unexpected body")
	}
	var m map[string]string
	if err := json.Unmarshal([]byte(s[lp+1:rp]), &m); err != nil {
		return nil, false, err
	}
	for k, v := range m {
		ms, err := strconv.Atoi(strings.TrimSpace(k))
		if err != nil || ms < 0 {
			continue
		}
		lines = append(lines, genieLine{ms, strings.TrimSpace(v)})
	}
	sort.Slice(lines, func(i, j int) bool { return lines[i].ms < lines[j].ms })
	return lines, len(lines) > 0, nil
}

// geniePrefixHeaderLines:开头几行里有多少行是歌名 / 歌手抬头(Genie 有时把这两行写在正文前头)。整行就是 Genie 自己给的
// 歌名或歌手(去掉括号、大小写和标点之后相同)、或者是「歌名 - 歌手」那种抬头才算,碰到第一句别的就停;这几行里至少有一行
// 是歌手名或「歌名 - 歌手」才去 —— 只有一行跟歌名相同的,可能就是唱出来的第一句。纯函数,便于单测。
func geniePrefixHeaderLines(lines []genieLine, name, artist string) int {
	key := func(s string) []string { return []string{normLoose(s), normLoose(stripHeaderBrackets(s))} }
	titleKeys, artistKeys := map[string]bool{}, map[string]bool{}
	for _, k := range append(key(name), key(vibeSongTitle(name))...) {
		if k != "" {
			titleKeys[k] = true
		}
	}
	for _, k := range key(artist) {
		if k != "" {
			artistKeys[k] = true
		}
	}
	n, sure := 0, false
	for n < len(lines) && n < genieHeaderLineMax {
		ks := key(lines[n].text)
		switch {
		case artistKeys[ks[0]] || artistKeys[ks[1]] || looksLikeLyricHeaderLine(lines[n].text, name, artist):
			sure = true
		case titleKeys[ks[0]] || titleKeys[ks[1]]:
		default:
			if sure {
				return n
			}
			return 0
		}
		n++
	}
	if !sure {
		return 0
	}
	return n
}

// genieBuildLRC 把同步歌词拼成 LRC,去掉开头的歌名 / 歌手行。空句写成只有时间戳的行(一句唱完、后面是间奏)。
// 起点原样用,别按源加固定偏移:Genie 多数歌偏早、少数准或偏晚,整体后移会把那部分推成歌词晚于人声(09 章决策 294)。
func genieBuildLRC(lines []genieLine, name, artist string) string {
	lines = lines[geniePrefixHeaderLines(lines, name, artist):]
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(formatLRCStamp(l.ms) + l.text + "\n")
	}
	return b.String()
}

// genieCoverURL:搜索结果的 `image_path` 是站内路径(600×600 那一档),拼上图片主机。
func genieCoverURL(path string) string {
	path = strings.TrimSpace(path)
	if !strings.HasPrefix(path, "/") {
		return ""
	}
	return genieImageBase + path
}

// genieCandidateScore 给一条搜索结果打分,越高越像本地这首;负数 = 淘汰。口径同 vibeCandidateScore。纯函数,便于单测。
func genieCandidateScore(item genieSearchItem, artist, title, album string, durationSecs float64) int {
	if !item.hasLyrics() {
		return -1
	}
	name := vibeSongTitle(item.Name.Original)
	if !lyricTitleAccepted(name, title) {
		return -1
	}
	d := item.Duration.Time
	if !lyricSourceArtistMatches(item.Artist.Original, artist) &&
		!lyricRecordingTriangleMatchesGuarded(name, item.Album.Original, item.Artist.Original, d, title, album, artist, durationSecs) {
		return -1
	}
	if versionTagsMismatch(title, album, name, item.Album.Original) {
		return -1
	}
	score := 100
	if durationSecs > 0 && d > 0 {
		diff := math.Abs(d-durationSecs) / durationSecs
		if diff > genieScoreDurationTolerance || math.Abs(d-durationSecs) > genieMaxDurationDiffSecs {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

// resolveGenieLyric:检索词的顺序同 resolveVibeLyric(「歌名 第一位歌手」→ 只按歌名 → 歌名被清理过时按原样);过闸的按分数
// 取前几条并发拉同步歌词,按名次挑第一份;都没有同步歌词时交名次最高、带纯文本的那条。
func resolveGenieLyric(ctx context.Context, artist, title, album string, durationSecs float64) genieResult {
	type scoredItem struct {
		item  genieSearchItem
		score int
	}
	qTitle := vibeQueryText(lyricQueryTitle(title))
	queries := []string{strings.TrimSpace(qTitle + " " + vibeQueryText(firstCreditedArtist(artist))), qTitle}
	if raw := strings.TrimSpace(lyricQueryTitle(title)); raw != qTitle && raw != "" {
		queries = append(queries, raw)
	}
	var candidates []scoredItem
	for qi, q := range queries {
		items, err := genieSearch(ctx, q)
		if err != nil {
			return genieResult{}
		}
		for _, it := range items {
			if it.SongID == 0 {
				continue
			}
			if s := genieCandidateScore(it, artist, title, album, durationSecs); s >= 0 {
				candidates = append(candidates, scoredItem{it, s})
			}
		}
		if len(candidates) > 0 || qi == len(queries)-1 {
			break
		}
	}
	if len(candidates) == 0 {
		return genieResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > genieMaxCandidatesToFetch {
		candidates = candidates[:genieMaxCandidatesToFetch]
	}

	synced := make([][]genieLine, len(candidates))
	failed := make([]bool, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, id int64) {
			defer wg.Done()
			body, err := genieGet(ctx, genieLyricURL+"?songid="+strconv.FormatInt(id, 10)+"&callback=GenieCallback")
			if err != nil {
				failed[rank] = true
				return
			}
			lines, _, err := genieParseSyncLyric(string(body))
			if err != nil {
				failed[rank] = true
				return
			}
			synced[rank] = lines
		}(i, c.item.SongID)
	}
	wg.Wait()

	result := func(it genieSearchItem) genieResult {
		return genieResult{title: vibeSongTitle(it.Name.Original), artist: it.Artist.Original, album: it.Album.Original,
			cover: genieCoverURL(it.ImagePath), durationSecs: it.Duration.Time}
	}
	var plain *genieResult
	for rank, c := range candidates {
		if failed[rank] {
			noteLyricSubFetchFailure(ctx)
			continue
		}
		if lrc := genieBuildLRC(synced[rank], c.item.Name.Original, c.item.Artist.Original); isTimedLRC(lrc) {
			r := result(c.item)
			r.lyrics = lrc
			return r
		}
		if plain == nil && strings.TrimSpace(c.item.Lyrics) != "" {
			r := result(c.item)
			r.lyrics, r.plainOnly = strings.TrimSpace(c.item.Lyrics), true
			plain = &r
		}
	}
	if plain != nil {
		return *plain
	}
	return genieResult{}
}
