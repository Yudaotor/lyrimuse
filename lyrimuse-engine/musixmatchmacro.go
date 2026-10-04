package main

import (
	"context"
	"encoding/json"
	"math"
	neturl "net/url"
	"regexp"
	"strconv"
	"strings"
)

// ---- macro.subtitles.get:一次请求拿回匹配 + 逐行 + 逐字 + 纯文本 + 译文可用状态 ----
//
// 服务器在一次调用里依次跑 matcher.track.get、track.subtitles.get、track.lyrics.get,optional_calls
// 带上 track.richsync 时连逐字一起给;part 里的 track_lyrics_translation_status 让匹配到的曲目带上各语言
// 译文的覆盖率,track_performer_tagging 带上演唱者标注(lyricspeakers.go)。原来的 track.search → track.subtitle.get → track.richsync.get 要三个请求,这个源
// 被限流的首要诱因就是请求频率(见 musixmatchTokenFetchMu 头注)。
//
// 三种认曲目的方式,同一个接口:
//   - Spotify 曲目 ID / Apple 目录 ID(track_spotify_id / track_itunes_id)与 ISRC(track_isrc):不过名称闸 ——
//     Musixmatch 对不少日文 / 韩文歌只登记罗马字写法,名称对不上是常态;但时长必须对得很紧
//     (musixmatchIDDurationFits)。ID 先取播放器这一拍给的(platformtrackid.go),没有就取缓存条目里存的
//     (musixmatchCachedTrackIDs),所以全量扫库与手动搜索同样用得上;
//   - 歌名 + 歌手 + 时长(q_track / q_artist / q_duration / f_subtitle_length):服务器按时长挑
//     逐行歌词的版本,返回的曲目仍过 pickMusixmatchTrackRow 的名称闸与 sourceDurationFits。
//
// 任何一步不满足就返回 ok=false,调用方退回原来的搜索流程:服务器端匹配偶尔认不出繁体 / 罗马字
// 别名写法,这时 track.search 反而找得到(09 章决策 135 的实测)。

// musixmatchMacro 是一次 macro.subtitles.get 里用得上的部分。
type musixmatchMacro struct {
	match musixmatchTrackMatch
	lrc   string // 逐行 LRC;受限(restricted)或不是真同步的留空
	yrc   string // 逐字,已转成 YRC
	// subLength:这份逐行歌词对应的曲长(秒)。matcher 回的 track_length 常是 0,这个字段有值。
	subLength float64
	// trTo:有社区译文的语言(Musixmatch 的三字母代码,如 zht)。只当「有」的证据用:实测这份列表
	// 不全(列了二十多种语言却没有 zho 的曲目,按 zh 照样取得到中文译文),不能拿「没列」当「没有」。
	trTo []string
	// subFailed:逐字这一块服务器说没问成(不是 404),整份结果不该缓存,见 lyricsubfetch.go。
	subFailed bool
	// performers:演唱者标注的片段(performer_tagging.content),没有标注时为空。
	performers []musixmatchPerformerSpan
}

// musixmatchMacroGet 发一次 macro.subtitles.get。请求本身没成、matcher 没认出曲目都返回 ok=false。
func musixmatchMacroGet(ctx context.Context, params neturl.Values) (musixmatchMacro, bool) {
	params.Set("namespace", "lyrics_richsynched")
	params.Set("subtitle_format", "lrc")
	params.Set("optional_calls", "track.richsync")
	params.Set("part", "track_lyrics_translation_status,track_performer_tagging")
	params.Set("format", "json")
	body, err := musixmatchDo(ctx, "macro.subtitles.get", params)
	if err != nil {
		return musixmatchMacro{}, false
	}
	return parseMusixmatchMacro(body)
}

// parseMusixmatchPerformerTagging:performer_tagging 里的片段,按给出的顺序。只收 type 为 artist、带歌手 ID 的演唱者;
// 字段缺失或形状不对时返回空。单独解析:它坏了不该连累同一次应答里的匹配结果。
func parseMusixmatchPerformerTagging(raw json.RawMessage) []musixmatchPerformerSpan {
	var pt struct {
		Content []struct {
			Snippet    string `json:"snippet"`
			Performers []struct {
				Type string `json:"type"`
				Fqid string `json:"fqid"`
			} `json:"performers"`
		} `json:"content"`
	}
	if len(raw) == 0 || json.Unmarshal(raw, &pt) != nil {
		return nil
	}
	var out []musixmatchPerformerSpan
	for _, c := range pt.Content {
		sp := musixmatchPerformerSpan{text: c.Snippet}
		for _, p := range c.Performers {
			if p.Type == "artist" && p.Fqid != "" {
				sp.performers = append(sp.performers, p.Fqid)
			}
		}
		out = append(out, sp)
	}
	return out
}

// parseMusixmatchMacro 解析 macro.subtitles.get 的应答。纯函数,便于单测。
func parseMusixmatchMacro(body []byte) (musixmatchMacro, bool) {
	var out struct {
		Message struct {
			Body struct {
				MacroCalls map[string]json.RawMessage `json:"macro_calls"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil {
		return musixmatchMacro{}, false
	}
	call := func(name string, v any) int {
		var w struct {
			Message struct {
				Header struct {
					StatusCode int `json:"status_code"`
				} `json:"header"`
				Body json.RawMessage `json:"body"`
			} `json:"message"`
		}
		raw, ok := out.Message.Body.MacroCalls[name]
		if !ok || json.Unmarshal(raw, &w) != nil {
			return 0
		}
		if w.Message.Header.StatusCode == 200 {
			_ = json.Unmarshal(w.Message.Body, v)
		}
		return w.Message.Header.StatusCode
	}
	var matched struct {
		Track struct {
			musixmatchTrackRow
			TranslationStatus []struct {
				To string `json:"to"`
			} `json:"track_lyrics_translation_status"`
			PerformerTagging json.RawMessage `json:"performer_tagging"`
		} `json:"track"`
	}
	if call("matcher.track.get", &matched) != 200 || matched.Track.TrackID == 0 {
		return musixmatchMacro{}, false
	}
	m := musixmatchMacro{match: musixmatchMatchFromRow(matched.Track.musixmatchTrackRow),
		performers: parseMusixmatchPerformerTagging(matched.Track.PerformerTagging)}
	for _, s := range matched.Track.TranslationStatus {
		if s.To != "" {
			m.trTo = append(m.trTo, s.To)
		}
	}
	var subs struct {
		SubtitleList []struct {
			Subtitle struct {
				Body       string  `json:"subtitle_body"`
				Length     float64 `json:"subtitle_length"`
				Restricted int     `json:"restricted"`
			} `json:"subtitle"`
		} `json:"subtitle_list"`
	}
	if call("track.subtitles.get", &subs) == 200 && len(subs.SubtitleList) > 0 {
		s := subs.SubtitleList[0].Subtitle
		if s.Restricted == 0 && isTimedLRC(s.Body) {
			m.lrc, m.subLength = s.Body, s.Length
		}
	}
	var rs struct {
		Richsync struct {
			Body string `json:"richsync_body"`
		} `json:"richsync"`
	}
	switch code := call("track.richsync.get", &rs); {
	case code == 200:
		m.yrc = musixmatchRichsyncBodyToYRC(rs.Richsync.Body)
	case musixmatchSubStatusFailed(code) && m.match.hasRichsync:
		m.subFailed = true
	}
	return m, true
}

// musixmatchIDDurationFits:按 ID 认出来的曲目,时长差在 3 秒或 2% 以内(取大)才算同一条录音。
// 比 sourceDurationFits 的 25% 紧得多:ID 这条不过名称闸,时长是唯一挡得住「ID 本身错了」的证据
// (实测一个按歌名搜出来的 Apple ID 指向了另一位歌手的同名歌,时长差 6%)。本地时长未知不放行。
func musixmatchIDDurationFits(localSecs, sourceSecs float64) bool {
	if localSecs <= 0 || sourceSecs <= 0 {
		return false
	}
	return math.Abs(localSecs-sourceSecs) <= math.Max(3, 0.02*localSecs)
}

// musixmatchMacroByID 按录音级身份取。ids 里一个都没有就不发请求。
func musixmatchMacroByID(ctx context.Context, ids musixmatchTrackIDs, artist, title string, durationSecs float64) (musixmatchMacro, bool) {
	// Spotify 在前:缓存里的 Apple ID 是按歌名在 iTunes 搜出来的,Spotify 的是播放时客户端给的。
	p := neturl.Values{}
	switch {
	case ids.spotifyTrackID != "":
		p.Set("track_spotify_id", ids.spotifyTrackID)
	case ids.appleCatalogID != "":
		p.Set("track_itunes_id", ids.appleCatalogID)
	case ids.isrc != "":
		p.Set("track_isrc", ids.isrc)
	default:
		return musixmatchMacro{}, false
	}
	m, ok := musixmatchMacroGet(ctx, p)
	if !ok || m.lrc == "" || !musixmatchIDDurationFits(durationSecs, m.subLength) {
		return musixmatchMacro{}, false
	}
	return m, true
}

// musixmatchMacroByName 按歌名 + 歌手 + 时长取,返回的曲目过跟 track.search 那条同一道名称闸。
func musixmatchMacroByName(ctx context.Context, artist, title, album string, durationSecs float64) (musixmatchMacro, bool) {
	p := neturl.Values{"q_track": {title}, "q_artist": {artist}}
	if album != "" {
		p.Set("q_album", album)
	}
	if durationSecs > 0 {
		d := strconv.Itoa(int(math.Round(durationSecs)))
		p.Set("q_duration", d)
		p.Set("f_subtitle_length", d)
	}
	m, ok := musixmatchMacroGet(ctx, p)
	if !ok || m.lrc == "" {
		return musixmatchMacro{}, false
	}
	row := musixmatchTrackRow{TrackName: m.match.title, ArtistName: m.match.artist, HasSubtitles: 1}
	if _, pass := pickMusixmatchTrackRow([]musixmatchTrackRow{row}, artist, title); !pass {
		return musixmatchMacro{}, false
	}
	if !sourceDurationFits(durationSecs, m.subLength) {
		return musixmatchMacro{}, false
	}
	return m, true
}

// musixmatchHasTranslation:译文可用状态里列了这个语言。只用来决定要不要多发一次请求,见 trTo 的注释。
func (m musixmatchMacro) musixmatchHasTranslation(lang string) bool {
	for _, to := range m.trTo {
		if strings.EqualFold(to, lang) {
			return true
		}
	}
	return false
}

// ---- 录音级身份经 ctx 传进来 ----

// musixmatchTrackIDs:这次播放的这条录音在各平台上的身份。都可能为空。
type musixmatchTrackIDs struct {
	appleCatalogID, spotifyTrackID, isrc string
}

func (ids musixmatchTrackIDs) cacheKey() string {
	return ids.appleCatalogID + "|" + ids.spotifyTrackID + "|" + ids.isrc
}

type musixmatchPlaybackIDsKey struct{}

// withMusixmatchPlaybackIDs 挂上这首歌的 Apple 目录 ID / Spotify 曲目 ID(来源见 musixmatchTrackIDsFor)。
// 不改 musixmatchLyric 的签名:单测里好几处按原签名换掉 musixmatchResolve。
func withMusixmatchPlaybackIDs(ctx context.Context, appleCatalogID, spotifyTrackID string) context.Context {
	if appleCatalogID == "" && spotifyTrackID == "" {
		return ctx
	}
	return context.WithValue(ctx, musixmatchPlaybackIDsKey{}, musixmatchTrackIDs{appleCatalogID: appleCatalogID, spotifyTrackID: spotifyTrackID})
}

func musixmatchPlaybackIDsFrom(ctx context.Context) musixmatchTrackIDs {
	ids, _ := ctx.Value(musixmatchPlaybackIDsKey{}).(musixmatchTrackIDs)
	return ids
}

// musixmatchTrackIDsFor:这一拍播放器给的 ID 优先(platformtrackid.go playbackTrackIDsFor,只对正在播的那首
// 有),都没有再取缓存条目里存的(musixmatchCachedTrackIDs)。
func musixmatchTrackIDsFor(artist, title, album string) (appleCatalogID, spotifyTrackID string) {
	if a, s := playbackTrackIDsFor(artist, title, album); a != "" || s != "" {
		return a, s
	}
	return musixmatchCachedTrackIDs(artist, title, album)
}

// musixmatchCachedTrackIDs:缓存条目里存着的身份 —— SpotifyTrackID 是 Spotify 客户端放这首时记下的(录音级),
// AppleURL 里的目录 ID 有已校验锚点时就是锚点那一条(appleCatalogLinkFor),否则是按歌名在 iTunes 搜出来的(不是播放器给的,
// 靠 musixmatchIDDurationFits 兜住)。
// 手动搜索那个一次性进程以只读方式加载了同一份缓存(searchcli.go)。
// 精确 key 查不到再按宽松 key 找(canonicalEnrichKey):手动搜索把查询词统一成简体(searchQueryFields),
// 缓存里的 key 却可能留着繁体专辑名。
// 会取 enrichMu,调用方必须在锁外(取词流程是,同 amazonCachedASIN)。
func musixmatchCachedTrackIDs(artist, title, album string) (appleCatalogID, spotifyTrackID string) {
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		if k, found := canonicalEnrichKey(key); found {
			e, ok = enrichCache[k], true
		}
	}
	enrichMu.Unlock()
	if !ok {
		return "", ""
	}
	return appleCatalogIDFromURL(e.AppleURL), e.SpotifyTrackID
}

// appleTrackParamRe:Apple Music 单曲链接里的曲目参数(…/album/<名>/<专辑 id>?i=<曲目 id>)。
var appleTrackParamRe = regexp.MustCompile(`[?&]i=(\d+)`)

// appleCatalogIDFromURL 从 Apple Music 单曲链接里取曲目目录 ID,不是这个形状返回空串。纯函数,便于单测。
func appleCatalogIDFromURL(u string) string {
	if m := appleTrackParamRe.FindStringSubmatch(u); m != nil {
		return m[1]
	}
	return ""
}
