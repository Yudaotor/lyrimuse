package main

import (
	"math"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// songIDLevel:一个 id(或 ISRC)从哪来的。播放器给的就是用户耳朵里那一条;检索配的可能配到别的版本、别的曲目。
type songIDLevel int

const (
	songIDSearched songIDLevel = 1 // 检索配的
	songIDVerified songIDLevel = 2 // 过了时长闸、版本词对得上
	songIDPlayer   songIDLevel = 3 // 播放器给的
)

func (l songIDLevel) String() string {
	switch l {
	case songIDPlayer:
		return "player"
	case songIDVerified:
		return "verified"
	default:
		return "searched"
	}
}

// 各种 id 的命名空间。
const (
	songIDISRC         = "isrc"
	songIDSpotifyTrack = "spotify_track"
	songIDAmazonASIN   = "amazon_asin"
	songIDKKBOXSong    = "kkbox_song"
	songIDSodaTrack    = "soda_track"
	songIDYouTubeVideo = "youtube_video"
	songIDAppleSong    = "apple_song"
	songIDNeteaseSong  = "netease_song"
	songIDQQSong       = "qq_song"
)

type songGradedID struct {
	ns, id string
	level  songIDLevel
}

// songVocals:有没有人声。不当合并证据,只给否决用。
type songVocals int

const (
	songVocalsUnknown songVocals = iota
	songVocalsNone
	songVocalsPresent
)

// songVariant:建实体表要用的一条写法(enrich 缓存的一条)的字段,锁内从条目摘出来,建表在锁外算。
type songVariant struct {
	key                  string
	artist, title, album string // 键里的三段;歌名去掉了 ~durN 变体位标记
	primary              string // 主歌手:合唱、feat. 取第一位(artistCreditPrimary)
	family               string // 写法族歌名键(songFamilyTitle)
	han                  bool   // 主标题含汉字 / 假名(songCoreTitle)
	tailed               bool   // 主标题之外还带括号 / 方括号 / 破折号尾巴(目录噪音不算)
	durationSecs         float64
	resolvedSecs         float64
	versionTags          map[string]bool
	instrumentalVersion  bool // 歌名或专辑带伴奏 / 纯音乐 / Instrumental 限定词
	instrumental         bool // 条目标了纯音乐
	ids                  []songGradedID
	albums               map[string]string // 平台 → 专辑 id;跟 ids 里同一平台的曲目 id 配对,给「同一张专辑里歌曲 id 不同」用
	lyrics, yrc          string
	lyricsSource         string
	lyricsTrusted        bool
	manual               bool
	pinned               bool
	// latest / applied:解析决策的两槽(只有顶层字段,候选明细在旁路文件里)。
	latest, applied *lyricsDecision

	// 建表时按需算、算一次留着。
	// registered:检索 id(「netease_song:<id>」)→ 平台给这个 id 登记的歌名;对不上号的不在里面。winnerTitle:当前这份
	// 歌词的候选在源那边的歌名,不知道为空。都从解析决策的候选里取(loadDecisionTitles)。
	titlesDone   bool
	registered   map[string]string
	winnerTitle  string
	vocalsDone   bool
	vocals       songVocals
	shinglesDone bool
	shingles     songHashSet // 正文三元组;正文够不上 songLyricsMinTokens 时为 nil
	words        songHashSet // 正文词元集合
	timelineDone bool
	timeline     []timelineLine
}

var songDurVariantRe = regexp.MustCompile(`~dur\d+$`)

// songVariantOf 从一条缓存条目摘出建表要用的字段。
func songVariantOf(key string, e enrichEntry, pinned bool) songVariant {
	artist, title, album := splitEnrichKey(key)
	title = songDurVariantRe.ReplaceAllString(title, "")
	core := songCoreTitle(title)
	v := songVariant{
		key:                 key,
		artist:              artist,
		title:               title,
		album:               album,
		primary:             artistCreditPrimary(artist),
		family:              songFamilyTitle(title),
		han:                 songContainsHanLike(core),
		durationSecs:        math.Max(e.DurationSecs, 0),
		resolvedSecs:        math.Max(e.ResolvedDurationSecs, 0),
		versionTags:         recordingVersionTags(title, album),
		instrumentalVersion: localIsInstrumentalVersion(title, album),
		instrumental:        e.Instrumental,
		albums:              map[string]string{},
		lyrics:              e.Lyrics,
		yrc:                 e.LyricsYRC,
		lyricsSource:        e.LyricsSource,
		manual:              e.ManualLyrics,
		pinned:              pinned,
		latest:              e.LyricsDecision,
		applied:             e.LyricsDecisionApplied,
	}
	v.tailed = songFamilyTitle(core) != v.family
	// 只有署名的歌词剥完不够 songLyricsMinTokens,到比对时自然不参与,这里不另判。
	v.lyricsTrusted = strings.TrimSpace(e.Lyrics) != "" &&
		(v.durationSecs <= 0 || v.resolvedSecs <= 0 || math.Abs(v.durationSecs-v.resolvedSecs) <= songLyricsTrustToleranceSecs)
	v.ids = songVariantIDs(e, len(v.versionTags) == 0)
	if s := strconv.FormatInt(motionCoverAlbumIDFromAppleURL(e.AppleURL), 10); s != "0" {
		v.albums[songIDAppleSong] = s
	}
	for ns, album := range map[string]string{
		songIDSpotifyTrack: e.SpotifyAlbumID, songIDQQSong: e.QQAlbumMid, songIDAmazonASIN: e.AmazonAlbumASIN,
		songIDKKBOXSong: e.KKBOXAlbumID, songIDSodaTrack: e.SodaAlbumID,
	} {
		if album != "" {
			v.albums[ns] = album
		}
	}
	return v
}

// songVariantIDs:条目上的各种 id,带来源级别。存量没有来路记录,按字段的写入点定级:Spotify 曲目 id、Amazon ASIN、
// KKBOX、汽水、YouTube 的 id 只由用那个播放器放时写入,算 player;Apple、网易云、QQ 的链接是检索配的(Apple 那一栏
// 也会被换成播放时核对过的目录锚点,存量分不出来),算 searched。ISRC 也不记来路:写法没有版本词时,检索配上的号
// 多半就是它这一版的,算 verified;有版本词的(Live、Remix、伴奏……)常被配上原版的号,算 searched,不当证据。
// plainVersion:写法的歌名、专辑没有版本词。
func songVariantIDs(e enrichEntry, plainVersion bool) []songGradedID {
	var out []songGradedID
	add := func(ns, id string, level songIDLevel) {
		if id != "" {
			out = append(out, songGradedID{ns: ns, id: id, level: level})
		}
	}
	isrcLevel := songIDSearched
	if plainVersion {
		isrcLevel = songIDVerified
	}
	seen := map[string]bool{}
	for _, raw := range e.ISRCs {
		if code := normalizeISRC(raw); code != "" && !seen[code] {
			seen[code] = true
			add(songIDISRC, code, isrcLevel)
		}
	}
	if len(e.SpotifyTrackID) == 22 {
		add(songIDSpotifyTrack, e.SpotifyTrackID, songIDPlayer)
	}
	add(songIDAmazonASIN, amazonASINFromTrackURL(e.AmazonURL), songIDPlayer)
	add(songIDKKBOXSong, songKKBOXSongID(e.KKBOXURL), songIDPlayer)
	add(songIDSodaTrack, songSodaTrackID(e.SodaURL), songIDPlayer)
	if !e.YouTubeMusicMV {
		add(songIDYouTubeVideo, songYouTubeVideoID(e.YouTubeMusicURL), songIDPlayer)
	}
	add(songIDAppleSong, appleCatalogIDFromURL(e.AppleURL), songIDSearched)
	add(songIDNeteaseSong, neteaseSongIDFromURL(e.NeteaseURL), songIDSearched)
	add(songIDQQSong, qqMidFromURL(e.QQURL), songIDSearched)
	return out
}

// id:这条写法在某个命名空间下的 id(取第一个),没有返回空串。
func (v *songVariant) id(ns string) string {
	id, _ := v.gradedID(ns)
	return id
}

// gradedID:同 id,带上来源级别。
func (v *songVariant) gradedID(ns string) (string, songIDLevel) {
	for _, g := range v.ids {
		if g.ns == ns {
			return g.id, g.level
		}
	}
	return "", 0
}

// songKKBOXSongID:`https://www.kkbox.com/<地区>/<语言>/song/<id>` 里的 id。
func songKKBOXSongID(u string) string {
	if !strings.Contains(u, "kkbox.com") {
		return ""
	}
	_, after, ok := strings.Cut(u, "/song/")
	if !ok {
		return ""
	}
	id, _, _ := strings.Cut(after, "?")
	return strings.Trim(id, "/")
}

// songSodaTrackID:汽水分享页 `…?track_id=<id>` 里的 id。
func songSodaTrackID(u string) string {
	if u == "" {
		return ""
	}
	p, err := url.Parse(u)
	if err != nil {
		return ""
	}
	return p.Query().Get("track_id")
}

// songYouTubeVideoID:`https://music.youtube.com/watch?v=<id>` 里的 videoId。
func songYouTubeVideoID(u string) string {
	if !strings.Contains(u, "youtube.com") {
		return ""
	}
	p, err := url.Parse(u)
	if err != nil {
		return ""
	}
	return p.Query().Get("v")
}

// songFamilyTitle:写法族歌名键。剥掉结尾的目录噪音副题(feat. / with 署名、Remaster、Bonus Track、Explicit,
// 括号、方括号与破折号三种形态交替剥),再按 normLoose 折(繁简、大小写、变音,只留字母数字)。Live、Remix、
// 伴奏这类版本词留着。
func songFamilyTitle(title string) string {
	return normLoose(songStripTitleNoise(title))
}

var songDashSuffixRe = regexp.MustCompile(`\s+[-\x{2013}\x{2014}]\s+`)

// songStripTitleNoise:循环剥掉结尾的目录噪音副题。括号与方括号那一形态同 stripCatalogNoiseSubtitle;破折号尾巴
// (`Bad - 2012 Remaster`)两侧必须有空白、取最后一个分隔符,同 App 侧 PlayCountVariants.dashSuffixSplit。
func songStripTitleNoise(title string) string {
	t := stripCatalogNoiseSubtitle(title)
	for {
		base, sub, ok := songDashSplit(t)
		if !ok || !isCatalogNoiseSubtitle(sub) {
			return t
		}
		next := stripCatalogNoiseSubtitle(strings.TrimRight(base, " -–—:,、"))
		if next == "" || next == t {
			return t
		}
		t = next
	}
}

// songDashSplit:按最后一个两侧带空白的破折号切成主体与尾巴。
func songDashSplit(t string) (base, sub string, ok bool) {
	locs := songDashSuffixRe.FindAllStringIndex(t, -1)
	if len(locs) == 0 {
		return "", "", false
	}
	last := locs[len(locs)-1]
	base, sub = strings.TrimSpace(t[:last[0]]), strings.TrimSpace(t[last[1]:])
	return base, sub, base != "" && sub != ""
}

// songCoreTitle:剥掉结尾的括号 / 方括号 / 破折号副题(最多四层)之后的主标题。只给「这是不是中文名」「带不带尾巴」用。
// 同 App 侧 EnrichTitleAliases.coreTitle。
func songCoreTitle(title string) string {
	t := strings.TrimSpace(title)
	for range 4 {
		if base, ok := songSuffixSplit(t, ")）", "(（"); ok {
			t = base
			continue
		}
		if base, ok := songSuffixSplit(t, "]】", "[【"); ok {
			t = base
			continue
		}
		if base, _, ok := songDashSplit(t); ok {
			t = base
			continue
		}
		break
	}
	return t
}

// songSuffixSplit:t 以 closers 里的字符结尾时,按最后一个 openers 字符切出主体。主体或副题为空不算。
func songSuffixSplit(t, closers, openers string) (string, bool) {
	r := []rune(t)
	if len(r) == 0 || !strings.ContainsRune(closers, r[len(r)-1]) {
		return "", false
	}
	for i := len(r) - 2; i >= 0; i-- {
		if strings.ContainsRune(openers, r[i]) {
			base, sub := strings.TrimSpace(string(r[:i])), strings.TrimSpace(string(r[i+1:len(r)-1]))
			if base == "" || sub == "" {
				return "", false
			}
			return base, true
		}
	}
	return "", false
}

func songContainsHanLike(s string) bool {
	for _, r := range s {
		if songHanLike(r) {
			return true
		}
	}
	return false
}

// songLyricsShingles:这条写法正文的三元组与词元集合,第一次用到时才剥。正文不可信或太短时两个都是 nil。
func (v *songVariant) lyricsShingles() (songHashSet, songHashSet) {
	if v.shinglesDone {
		return v.shingles, v.words
	}
	v.shinglesDone = true
	if !v.lyricsTrusted || v.instrumental {
		return nil, nil
	}
	tokens := songLyricsTokens(songLyricsBody(v.lyrics))
	if len(tokens) < songLyricsMinTokens {
		return nil, nil
	}
	v.shingles, v.words = songShingles(tokens), songWordSet(tokens)
	return v.shingles, v.words
}

// displayedLines:这条写法显示的那条时间轴(displayedTimeline),第一次用到时才算。
func (v *songVariant) displayedLines() []timelineLine {
	if !v.timelineDone {
		v.timelineDone = true
		if v.lyricsTrusted && !v.instrumental {
			v.timeline = displayedTimeline(v.lyrics, v.yrc)
		}
	}
	return v.timeline
}

// vocalsKind:有没有人声。标了纯音乐、或歌名 / 专辑带伴奏类限定词的算没有;有可信的、带时间轴、够长的正文的算有。
// 两样都占时按没有算。存量写法没记是哪个播放器放的,「有自家歌词的播放器」这一路判不了。
func (v *songVariant) vocalsKind() songVocals {
	if v.vocalsDone {
		return v.vocals
	}
	v.vocalsDone = true
	switch {
	case v.instrumental || v.instrumentalVersion:
		v.vocals = songVocalsNone
	case len(v.displayedLines()) >= timelineOffsetMinMatched:
		if s, _ := v.lyricsShingles(); s != nil {
			v.vocals = songVocalsPresent
		}
	}
	return v.vocals
}

// loadDecisionTitles:从解析决策的候选里取网易云给这条写法的 id 登记的歌名(两槽里网易云候选只有一种歌名时才对得上号),
// 和当前歌词那个候选在源那边的歌名。QQ、Apple 的链接是另外单独查的,跟歌词候选对不上号,不取。dir 是旁路文件的目录,
// 空串时都当不知道。
func (v *songVariant) loadDecisionTitles(dir string) {
	if v.titlesDone {
		return
	}
	v.titlesDone = true
	if dir == "" || (v.latest == nil && v.applied == nil) {
		return
	}
	pool := readDecisionSidecar(filepath.Join(dir, decisionSidecarName(v.key))).slots()
	netease := map[string]bool{}
	for _, d := range []*lyricsDecision{v.latest, v.applied} {
		if det := resolveSlot(d, pool); det != nil {
			for _, c := range det.Candidates {
				if t := strings.TrimSpace(c.Title); c.Source == "netease" && t != "" {
					netease[t] = true
				}
			}
		}
	}
	if id := v.id(songIDNeteaseSong); id != "" && len(netease) == 1 {
		for t := range netease {
			v.registered = map[string]string{songIDNeteaseSong + ":" + id: t}
		}
	}
	if d := v.applied; d != nil && d.Winner != "" {
		if det := resolveSlot(d, pool); det != nil {
			for _, c := range det.Candidates {
				if c.Source == d.Winner {
					v.winnerTitle = strings.TrimSpace(c.Title)
					break
				}
			}
		}
	}
}

// songTitlesCompatible:平台登记的歌名跟写法歌名是不是同一首。同一种文字时按写法族键相等或互相包含;
// 文字不同(一边含汉字 / 假名、一边不含)时判不了,crossScript 为 true。
func songTitlesCompatible(registered, title string) (ok, crossScript bool) {
	a, b := songFamilyTitle(registered), songFamilyTitle(title)
	if a == "" || b == "" {
		return false, false
	}
	if songContainsHanLike(songCoreTitle(registered)) != songContainsHanLike(songCoreTitle(title)) {
		return false, true
	}
	return a == b || strings.Contains(a, b) || strings.Contains(b, a), false
}
